class_name CandidateApply
extends RefCounted

# The apply seam: simulate one candidate and return the BoardState the position becomes
# (design decision 17 — evaluate the resulting STATE, never classify the action). The
# caller's state is never touched.
#
# Two tiers since the decoupling refactor (COMBAT_DECOUPLING_REFACTOR.md Step 5):
#   · place / move — pure geometry, applied to a BoardState copy (cheap, no rules; a
#     placement's ON_PLAY effects are deliberately not simulated yet — widening that is a
#     scoring decision, not plumbing).
#   · cast / ability — THE REAL RULES: copy the live CombatWorld, replay this turn's
#     already-accepted candidates onto the copy (reconstructing the working world at this
#     point of the plan), run the candidate through the same EffectSystem/Resolver path
#     the live game casts through, and capture the result back into the scorer's
#     read-model. The SimEffects shadow interpreter is DELETED — statuses, conditions,
#     interceptors and content edits reach simulations by construction now.
#
# `sim` is the per-turn simulation context the engine threads through:
#   { "world":    CombatWorld — the LIVE world; never mutated, only copied,
#     "accepted": Array — this turn's accepted candidate dicts, in acceptance order }


static func apply(state: BoardState, cand: Dictionary, sim: Dictionary = {}) -> BoardState:
	match String(cand["kind"]):
		"place":
			var placed := state.copy()
			var inst: CardInstance = cand["inst"]
			var u := BoardState.UnitState.from_instance(inst)
			u.owner = 1   # hand cards haven't been assigned a side yet
			placed.place(u, int(cand["row"]), int(cand["col"]))
			return placed
		"move":
			var moved := state.copy()
			var from_r := int(cand["from_row"])
			var from_c := int(cand["from_col"])
			var mover: BoardState.UnitState = moved.unit_at(1, from_r, from_c)
			moved.grid_of(1)[from_r][from_c] = null
			moved.place(mover, int(cand["row"]), int(cand["col"]))
			return moved
		"cast", "ability":
			return _apply_real(state, cand, sim)
	push_error("CandidateApply: unknown candidate kind '%s'" % String(cand["kind"]))
	return state.copy()


# ── The sim-support gate, inverted (decision 18 under the real rules) ─────────────────

# The real rules run in simulation now, so the refuse-list holds only the genuinely
# unknowable-or-unsafe:
#   · probabilistic effects — the sim would have to guess the roll;
#   · random discards — a nondeterministic pick;
#   · CUSTOM code hooks — several embed player-side board procedures (material delivery
#     spawns for owner 0); allowing them is a per-hook decision later, not a blanket yes.
# A cast still needs at least one ON_PLAY effect — a castable no-op isn't a candidate.
static func can_simulate_cast(effects: Array) -> bool:
	var any := false
	for e: Effect in effects:
		if e.trigger != Effect.Trigger.ON_PLAY:
			continue   # never fires at cast time — irrelevant to the simulation
		if e.chance < 1.0:
			return false
		if e.attribute == "discard":
			return false
		if e.kind == Effect.Kind.CUSTOM:
			return false
		any = true
	return any


# Whether any of the cast's effects needs a manually picked target — then the candidate
# generators enumerate one candidate per possible target ("tested against EVERY possible
# target", decision 17).
static func needs_manual(effects: Array) -> bool:
	for e: Effect in effects:
		if e.trigger == Effect.Trigger.ON_PLAY \
				and e.targeting_policy == Effect.TargetingPolicy.MANUAL:
			return true
	return false


# ── The real-rules path ────────────────────────────────────────────────────────────────

static func _apply_real(state: BoardState, cand: Dictionary, sim: Dictionary) -> BoardState:
	var live: CombatWorld = sim.get("world", null)
	if live == null:
		push_error("CandidateApply: a cast/ability simulation needs sim.world")
		return state.copy()
	var remap: Dictionary = {}
	var w := live.copy(remap)
	for a: Dictionary in (sim.get("accepted", []) as Array):
		_replay(w, remap, a)
	# Collect only THIS candidate's deaths — replayed casts' corpses already sit in the
	# working state's graveyard from the moment they were accepted.
	var swept: Array = []
	w.unit_swept.connect(func(inst: CardInstance) -> void: swept.append(inst))
	_run_cast(w, remap, cand)
	return _capture_back(w, state, remap, swept)


static func _replay(w: CombatWorld, remap: Dictionary, a: Dictionary) -> void:
	match String(a["kind"]):
		"place":
			# Geometry only — mirrors the BoardState place op above.
			w.place_unit(CardInstance.copied(a["inst"], remap), int(a["row"]), int(a["col"]), 1)
		"move":
			var mover := CardInstance.copied(a["inst"], remap)
			var from_row: Array = w.enemy_grid[int(a["from_row"])]
			from_row[int(a["from_col"])] = null
			w.place_unit(mover, int(a["row"]), int(a["col"]), 1)
		"cast", "ability":
			_run_cast(w, remap, a)


# The candidate's cast, run EXACTLY the way the live game runs an enemy cast
# (combat._cast_enemy_spell / SpellCaster._resolve_on_play): per ON_PLAY effect, a world
# context + the manual target, EffectSystem.apply_single, then the death sweep. The
# cascade's broadcasts stay out of casts live, so they stay out here — parity, not
# shortcut. Everything is synchronous by construction: nothing in this path awaits.
static func _run_cast(w: CombatWorld, remap: Dictionary, cd: Dictionary) -> void:
	var ab: AbilityData = cd.get("ability", null)
	var src := CardInstance.copied(cd["inst"], remap)
	var effects: Array = ab.effects if ab != null else src.data.effects
	if ab != null:
		if ab.tap:
			src.attack_exhausted = true   # the sim spends the tap, closing repeat windows
	else:
		w.enemy_side.remove_from_hand(src)   # a cast hand spell leaves the copied hand
	var target := CardInstance.copied(cd.get("target", null), remap)
	for effect: Effect in effects:
		if effect.trigger != Effect.Trigger.ON_PLAY:
			continue
		var ctx := w.make_context(src)
		ctx.manual_target = target
		ctx.ability = ab
		EffectSystem.apply_single(effect, src, ctx)
		w.cleanup_deaths()


# The scorer's read-model, captured from the simulated world. Sources map BACK to live
# identity tokens (candidates and executable actions must keep naming live objects); a
# unit born inside the simulation (a spawn) keeps its copy as token — it has no live
# original and is never executed.
static func _capture_back(w: CombatWorld, prev: BoardState, remap: Dictionary,
		swept: Array) -> BoardState:
	var reverse: Dictionary = {}
	for live_inst: CardInstance in remap:
		reverse[remap[live_inst]] = live_inst
	var s := BoardState.new()
	s.player_units = _capture_grid_back(w.player_grid, reverse)
	s.enemy_units = _capture_grid_back(w.enemy_grid, reverse)
	s.player_mana = prev.player_mana
	s.graveyard = prev.graveyard.duplicate()
	for corpse: CardInstance in swept:
		var dead := BoardState.UnitState.from_instance(corpse)
		dead.source = reverse.get(corpse, corpse)
		s.graveyard.append(dead)
	return s


static func _capture_grid_back(grid: Array, reverse: Dictionary) -> Array:
	var out: Array = []
	for grid_row: Array in grid:
		var row: Array = []
		for cell: CardInstance in grid_row:
			if cell == null:
				row.append(null)
				continue
			var u := BoardState.UnitState.from_instance(cell)
			u.source = reverse.get(cell, cell)
			row.append(u)
		out.append(row)
	return out
