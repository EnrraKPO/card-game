extends TestCase

# PROVING NOTHING MOVED (LOCATION_MANAGER_DESIGN.md §6). The consolidation touched attack
# targeting — the most playtested behaviour in the game — and a refactor that is supposed to
# change nothing has to DEMONSTRATE it, not assert it.
#
# The instrument here is exhaustive rather than anecdotal: the pre-refactor formulas are
# written out below, literally, exactly as they read when they lived on the units, and every
# one of the 24 × 24 address pairs is checked against the migrated versions. A sampled fight
# can miss the one arrangement that changed; 576 pairs cannot.
#
# ⚠ THE FROZEN FORMULAS BELOW ARE HISTORY, NOT A SPEC. They are a copy of what shipped before
# the location layer existed. If the preference ordering is ever deliberately changed — a
# BALANCE decision, separately, later (§7) — these do not get "fixed" to match. They get
# deleted, along with this suite, because what they were guarding has been given up on
# purpose. Editing them to agree with new behaviour would turn a proof into a rubber stamp.


func suite_name() -> String:
	return "Location parity"


func run() -> void:
	_attack_preference_unmoved()
	_effect_preference_unmoved()
	_facing_unmoved()
	_geometry_is_not_preference()
	_nearest_empty_matches_the_old_search()


# ── The frozen originals ────────────────────────────────────────────────────────────────

# TargetingStrategy.dist, as it read when it took an attacker and a bare (r, c) on the
# opponent board — the attacker's HALF came from `attacker.owner`, which is the conflation
# this initiative separated. Reproduced here with the side passed explicitly, because the two
# always agreed and the point is to prove the arithmetic is untouched.
static func _old_attack_dist(from_side: int, from_row: int, from_col: int, r: int, c: int) -> int:
	var lane_offset: int = abs(from_row + r - (BoardData.ROWS - 1))
	var depth: int
	if from_side == 0:
		depth = BoardData.COLS + c - from_col
	else:
		depth = BoardData.COLS + from_col - c
	return depth * BoardData.ROWS + lane_offset


# TargetResolver.board_distance, as it read when it took two units and branched on
# `cand.owner == holder.owner`.
static func _old_effect_dist(h_side: int, h_row: int, h_col: int,
		c_side: int, c_row: int, c_col: int) -> int:
	if c_side == h_side:
		return (absi(h_row - c_row) + absi(h_col - c_col)) * BoardData.ROWS
	var lane_offset: int = absi(h_row + c_row - (BoardData.ROWS - 1))
	var depth: int
	if h_side == 0:
		depth = BoardData.COLS + c_col - h_col
	else:
		depth = BoardData.COLS + h_col - c_col
	return depth * BoardData.ROWS + lane_offset


# ── The proofs ──────────────────────────────────────────────────────────────────────────

func _attack_preference_unmoved() -> void:
	var strat := TargetingNearest.new()
	var mismatches := 0
	var pairs := 0
	for from: BoardLocation in BoardLocation.all():
		for to: BoardLocation in BoardLocation.all():
			if to.side == from.side:
				continue   # attack targeting only ever ranked the opposing half
			pairs += 1
			if strat.dist(from, to) != _old_attack_dist(from.side, from.row, from.col, to.row, to.col):
				mismatches += 1
	check_eq(mismatches, 0, "attack targeting's preference ordering is bit-identical")
	check_eq(pairs, BoardData.ROWS * BoardData.COLS * BoardData.ROWS * BoardData.COLS * 2,
			"…checked across every cross-half pair on the board")


func _effect_preference_unmoved() -> void:
	var mismatches := 0
	for from: BoardLocation in BoardLocation.all():
		for to: BoardLocation in BoardLocation.all():
			var got := TargetResolver.board_distance(from, to)
			var want := _old_effect_dist(from.side, from.row, from.col, to.side, to.row, to.col)
			if got != want:
				mismatches += 1
	check_eq(mismatches, 0, "effect targeting's preference ordering is bit-identical, both halves")

	# The two still AGREE on what "nearest" means across the line — the property the
	# hand-copied comment in TargetResolver claimed, now checked rather than claimed.
	var strat := TargetingNearest.new()
	var disagreements := 0
	for from: BoardLocation in BoardLocation.all():
		for to: BoardLocation in BoardLocation.all():
			if to.side == from.side:
				continue
			if strat.dist(from, to) != TargetResolver.board_distance(from, to):
				disagreements += 1
	check_eq(disagreements, 0, "attack and effect targeting agree on cross-half nearness")


func _facing_unmoved() -> void:
	var strat := TargetingNearest.new()
	var mismatches := 0
	for from: BoardLocation in BoardLocation.all():
		for to: BoardLocation in BoardLocation.all():
			if to.side == from.side:
				continue
			# The original: attacker.row + target.row == ROWS - 1.
			var was: bool = from.row + to.row == BoardData.ROWS - 1
			if strat.is_facing(from, to) != was:
				mismatches += 1
	check_eq(mismatches, 0, "\"directly facing\" is unchanged across the line")


# The separation §2.10 settled: the manager's distance is a REAL distance and the targeting
# ordering is a PREFERENCE. If these two were ever the same function, one of them would be
# wrong — so the difference is asserted rather than left to be rediscovered.
func _geometry_is_not_preference() -> void:
	var strat := TargetingNearest.new()
	# The exact arrangement the preference ordering was written FOR (see TargetingStrategy.dist's
	# note): a front-column target one lane over, against a same-lane target two columns deep.
	var from := BoardLocation.at(0, 1, BoardData.COLS - 1)
	var near_column := BoardLocation.at(1, 0, 0)
	var same_lane_deep := BoardLocation.at(1, 1, 1)

	# Geometry calls these two EQUALLY far — and it is right to, as a distance.
	check_eq(BoardGeometry.distance(from, near_column),
			BoardGeometry.distance(from, same_lane_deep),
			"a real distance rates the two candidates equally far")
	# The game rule does not. COLUMN DEPTH DOMINATES: the nearer column wins outright, and the
	# lane only breaks ties inside it. That is a PREFERENCE, and it is why the two must be
	# separate functions rather than one shared "nearest" (§2.10).
	check(strat.dist(from, near_column) < strat.dist(from, same_lane_deep),
			"the targeting preference breaks that tie toward the nearer column")

	# And the shapes differ generally, not only here.
	check(BoardGeometry.distance(from, near_column) != strat.dist(from, near_column),
			"the two answer in different units — one counts cells, one ranks candidates")
	# Geometry is symmetric everywhere, which is the property that makes it usable by something
	# with no sense of forward (a bouncing effect leaping from a square).
	var asymmetries := 0
	for a: BoardLocation in BoardLocation.all():
		for b: BoardLocation in BoardLocation.all():
			if BoardGeometry.distance(a, b) != BoardGeometry.distance(b, a):
				asymmetries += 1
	check_eq(asymmetries, 0, "geometry's distance is symmetric across every pair")


# CombatWorld._nearest_empty was a Manhattan scan over one half, keeping the first strictly
# closer cell in reading order — i.e. the nearest empty cell, ties going to reading order.
# BoardFacade.nearest_empty walks geometry's ordered cells and stops at the first empty one.
# Same answer, from the shared ordering rather than a fourth hand-rolled search.
func _nearest_empty_matches_the_old_search() -> void:
	var w := CombatWorld.make()
	w.rewards_live = false
	# Fill a scattering of the player half, then check every origin agrees with the old scan.
	for cell: Array in [[0, 0], [1, 1], [2, 3], [0, 2]]:
		w.place_unit(unit("pawn"), int(cell[0]), int(cell[1]), 0)

	var mismatches := 0
	for origin: BoardLocation in BoardLocation.all():
		if origin.side != 0:
			continue
		var best: BoardLocation = null
		var best_d := 999
		for r in BoardData.ROWS:
			for c in BoardData.COLS:
				if w.unit_at(0, r, c) != null:
					continue
				var d := absi(r - origin.row) + absi(c - origin.col)
				if d < best_d:
					best_d = d
					best = BoardLocation.at(0, r, c)
		if BoardFacade.nearest_empty(w, origin, 0) != best:
			mismatches += 1
	check_eq(mismatches, 0, "the spawn search lands where the old scan landed, from every origin")

	# A full half has no landing spot — an absence, not a sentinel.
	var full := CombatWorld.make()
	full.rewards_live = false
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			full.place_unit(unit("pawn"), r, c, 1)
	check_eq(BoardFacade.nearest_empty(full, BoardLocation.at(1, 0, 0), 1), null,
			"a full half answers nowhere")
