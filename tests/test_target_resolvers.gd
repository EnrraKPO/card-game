extends TestCase

# The TargetResolver contract (TARGETING_DESIGN.md §3/§12.1, signed
# ATTACK_SYSTEM_DESIGN.html): single-issue, stateless, pure over a passed-in world; and
# the auto-attack preference ordering preserved BIT-IDENTICAL through the demolition —
# column depth dominates, mirrored lane offset breaks ties within a column, deterministic
# row-then-col after that. Who attacks whom must not move. (Refusal checks intentionally
# print an ERROR line each — the loud-refusal contract under test.)


func suite_name() -> String:
	return "Target resolvers"


func run() -> void:
	_parse_and_roundtrip()
	_column_depth_dominates()
	_lane_offset_breaks_ties_in_column()
	_deterministic_tiebreak()
	_edges()
	_leap_prefers_past_the_front_column()
	_leap_prefers_landing_off_its_row()
	_leap_falls_back_to_nearest()
	_wounded_hunts_the_lowest_health()
	_tank_locks_the_highest_health()
	_threat_hunts_the_highest_attack()
	_executor_runs_the_attack_shape()


func _world() -> CombatWorld:
	var w := CombatWorld.make(GameData.current_modifiers)
	w.rewards_live = false
	return w


func _place(w: CombatWorld, card_id: String, side_owner: int, r: int, c: int) -> CardInstance:
	var inst := unit(card_id)
	inst.owner = side_owner
	w.place_unit(inst, r, c, side_owner)
	return inst


func _parse_and_roundtrip() -> void:
	var res := TargetResolver.parse({"kind": "nearest"})
	check(res is TargetResolver.Nearest, "nearest parses to its species")
	check_eq(res.to_dict(), {"kind": "nearest"}, "nearest round-trips its authored form")
	check(TargetResolver.parse({"kind": "leap"}) is TargetResolver.Leap, "leap parses to its species")
	check(TargetResolver.parse({"kind": "wounded"}) is TargetResolver.Wounded, "wounded parses to its species")
	check(TargetResolver.parse({"kind": "tank"}) is TargetResolver.Tank, "tank parses to its species")
	check(TargetResolver.parse({"kind": "threat"}) is TargetResolver.Threat, "threat parses to its species")
	for kind: String in ["leap", "wounded", "tank", "threat"]:
		check_eq(TargetResolver.parse({"kind": kind}).to_dict(), {"kind": kind},
				"%s round-trips its authored form" % kind)
	check(TargetResolver.parse({"kind": "everyone"}) == null, "an unknown kind is refused loudly")
	check(TargetResolver.parse("nearest") == null, "a bare string is refused (no permissive default)")


func _column_depth_dominates() -> void:
	# Attacker on the player front rank, facing lane occupied two columns deep; an
	# off-lane enemy stands one column nearer. The nearer COLUMN wins — always.
	var w := _world()
	var attacker := _place(w, "knight", 0, 1, 3)
	var facing_but_deep := _place(w, "pawn", 1, 1, 1)
	var off_lane_but_near := _place(w, "pawn", 1, 0, 0)
	var res := TargetResolver.parse({"kind": "nearest"})
	var got := res.resolve(w, attacker)
	check_eq(got.size(), 1, "nearest resolves to exactly one unit")
	check(got[0] == off_lane_but_near, "column depth dominates the lane offset")
	check(got[0] != facing_but_deep, "a facing unit in a farther column never outranks a nearer column")


func _lane_offset_breaks_ties_in_column() -> void:
	# Same column: the facing (mirrored) lane wins over an adjacent lane.
	var w := _world()
	var attacker := _place(w, "knight", 0, 1, 3)
	var facing := _place(w, "pawn", 1, 1, 0)    # enemy row 1 mirrors player row 1
	_place(w, "pawn", 1, 0, 0)                  # same column, one lane off
	var res := TargetResolver.parse({"kind": "nearest"})
	var got := res.resolve(w, attacker)
	check(got[0] == facing, "within a column, the facing lane is preferred")


func _deterministic_tiebreak() -> void:
	# Equal preference (same column, both one lane off the mirror): lowest row wins, so
	# equally-near targets never flicker between runs — sort_custom is not stable.
	var w := _world()
	var attacker := _place(w, "knight", 0, 1, 3)
	var row0 := _place(w, "pawn", 1, 0, 0)
	_place(w, "pawn", 1, 2, 0)
	var res := TargetResolver.parse({"kind": "nearest"})
	var got := res.resolve(w, attacker)
	check(got[0] == row0, "equal preference breaks deterministically by row")


func _edges() -> void:
	var w := _world()
	var nowhere := unit("pawn")   # never placed
	var res := TargetResolver.parse({"kind": "nearest"})
	check_eq(res.resolve(w, nowhere).size(), 0, "an attacker standing nowhere reaches nobody")
	var attacker := _place(w, "knight", 0, 1, 3)
	check_eq(res.resolve(w, attacker).size(), 0, "an empty opposite half is a legal empty resolution")
	check_eq(res.resolve(null, attacker).size(), 0, "a null world resolves to empty, never crashes")


# ── The variant species (signed §8.3): each recovered verbatim from its razed original.
# Fixture stats (attack/health, frozen in TestCase.FIXTURE_DEFS): pawn 1/3 · bishop 1/4 ·
# knight 2/3 · rook 4/6 · queen 5/5. ──

func _leap_prefers_past_the_front_column() -> void:
	# The frontmost occupied enemy column is leapt OVER: a unit standing behind it wins
	# even against a nearer, facing front-liner (the razed TargetingKnight's first filter).
	var w := _world()
	var attacker := _place(w, "knight", 0, 1, 3)
	var front_and_facing := _place(w, "pawn", 1, 1, 0)
	var behind := _place(w, "pawn", 1, 1, 1)
	var got := TargetResolver.parse({"kind": "leap"}).resolve(w, attacker)
	check_eq(got.size(), 1, "leap resolves to exactly one unit")
	check(got[0] == behind, "leap jumps the frontmost occupied column")
	check(got[0] != front_and_facing, "the facing front-liner is exactly what a leaper ignores")


func _leap_prefers_landing_off_its_row() -> void:
	# Among what stands behind the front column, a landing OFF the mirrored lane beats a
	# facing one (the second filter).
	var w := _world()
	var attacker := _place(w, "knight", 0, 1, 3)
	_place(w, "pawn", 1, 1, 0)                     # the front column, leapt over
	_place(w, "pawn", 1, 1, 1)                     # behind, but facing (rows mirror: 1+1)
	var off_row := _place(w, "pawn", 1, 0, 1)      # behind AND off the mirrored lane
	var got := TargetResolver.parse({"kind": "leap"}).resolve(w, attacker)
	check(got[0] == off_row, "behind the front column, an off-lane landing is preferred")


func _leap_falls_back_to_nearest() -> void:
	# Each preference applies only while it leaves a candidate: with ONLY the front column
	# occupied, the leaper degrades gracefully to a plain nearest pick — and an empty half
	# is a legal empty resolution.
	var w := _world()
	var attacker := _place(w, "knight", 0, 1, 3)
	var res := TargetResolver.parse({"kind": "leap"})
	check_eq(res.resolve(w, attacker).size(), 0, "an empty opposite half resolves empty for leap too")
	var only_front := _place(w, "pawn", 1, 1, 0)
	check(res.resolve(w, attacker)[0] == only_front,
			"with nothing to leap to, the leaper strikes the front like anyone else")


func _wounded_hunts_the_lowest_health() -> void:
	# Lowest current health wins regardless of distance; equal health falls back to the
	# full nearest preference (the razed TargetingBishop, deterministic where it wasn't).
	var w := _world()
	var attacker := _place(w, "knight", 0, 1, 3)
	_place(w, "rook", 1, 1, 0)                      # near, 6 health
	var frail := _place(w, "pawn", 1, 1, 2)         # far, 3 health
	var res := TargetResolver.parse({"kind": "wounded"})
	check(res.resolve(w, attacker)[0] == frail, "the most wounded is hunted past nearer, healthier targets")
	var w2 := _world()
	var attacker2 := _place(w2, "knight", 0, 1, 3)
	var near_pawn := _place(w2, "pawn", 1, 1, 0)
	_place(w2, "pawn", 1, 1, 2)                     # same health, farther
	check(res.resolve(w2, attacker2)[0] == near_pawn, "equal health falls back to the nearest preference")


func _tank_locks_the_highest_health() -> void:
	# Highest current health wins regardless of distance (the razed TargetingRook).
	var w := _world()
	var attacker := _place(w, "knight", 0, 1, 3)
	_place(w, "pawn", 1, 1, 0)                      # near, 3 health
	var wall := _place(w, "rook", 1, 1, 2)          # far, 6 health
	var res := TargetResolver.parse({"kind": "tank"})
	check(res.resolve(w, attacker)[0] == wall, "the tankiest is locked past nearer, frailer targets")
	var w2 := _world()
	var attacker2 := _place(w2, "knight", 0, 1, 3)
	var near_rook := _place(w2, "rook", 1, 1, 0)
	_place(w2, "rook", 1, 1, 2)                     # same health, farther
	check(res.resolve(w2, attacker2)[0] == near_rook, "equal health falls back to the nearest preference")


func _threat_hunts_the_highest_attack() -> void:
	# Highest attack wins regardless of distance — read through get_attribute, so standing
	# bonuses would count (the razed TargetingQueen).
	var w := _world()
	var attacker := _place(w, "knight", 0, 1, 3)
	_place(w, "pawn", 1, 1, 0)                      # near, attack 1
	var menace := _place(w, "queen", 1, 1, 2)       # far, attack 5
	var res := TargetResolver.parse({"kind": "threat"})
	check(res.resolve(w, attacker)[0] == menace, "the greatest threat is hunted past nearer, weaker targets")
	var w2 := _world()
	var attacker2 := _place(w2, "knight", 0, 1, 3)
	var near_pawn := _place(w2, "pawn", 1, 1, 0)
	_place(w2, "pawn", 1, 1, 2)                     # same attack, farther
	check(res.resolve(w2, attacker2)[0] == near_pawn, "equal attack falls back to the nearest preference")


func _executor_runs_the_attack_shape() -> void:
	# The whole phase-1 machine in one pass: the authored attack shape parses, the
	# executor serves the plate, the mutator derives the holder's attack fresh, and the
	# strike lands through the Arbitrator. (The act wiring into combat is phase 2; this
	# pins the machinery it will call.)
	var effect := TriggeredEffect.parse({
		"id": "nearest_attack",
		"trigger": {"kind": "event", "event": "act", "of": "self"},
		"targets": {"kind": "nearest"},
		"payloads": [{"kind": "attack", "amount": {"kind": "holder_stat", "stat": "attack"}}],
	})
	check(effect != null, "the attack shape parses whole")
	check_eq(effect.to_dict().get("id", ""), "nearest_attack", "the named id survives the round-trip")

	var w := _world()
	var attacker := _place(w, "knight", 0, 1, 3)   # fixture knight: attack 2
	var victim := _place(w, "pawn", 1, 1, 0)       # fixture pawn: 3 health
	var ev := GameEvent.make(&"act", attacker)
	check(effect.trigger.fires(ev, attacker), "the act-of-self trigger gates its own act in")
	check(not effect.trigger.fires(GameEvent.make(&"act", victim), attacker),
			"someone else's act stays gated out")

	var outcomes := ActionExecutor.run(effect, ev, attacker, w)
	check_eq(outcomes.size(), 1, "one strike, one outcome")
	check_eq(victim.current_health, 1, "the strike lands the holder's attack stat through the Arbitrator")

	# A whiff: no enemies left standing anywhere — an empty resolution delivers nothing.
	var lonely := _world()
	var alone := _place(lonely, "knight", 0, 1, 3)
	var whiff := ActionExecutor.run(effect, GameEvent.make(&"act", alone), alone, lonely)
	check_eq(whiff.size(), 0, "an empty resolution is a legal whiff, not an error")
