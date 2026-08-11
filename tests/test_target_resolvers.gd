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


func _executor_runs_the_attack_shape() -> void:
	# The whole phase-1 machine in one pass: the authored attack shape parses, the
	# executor serves the plate, the mutator derives the holder's attack fresh, and the
	# strike lands through the Arbitrator. (The act wiring into combat is phase 2; this
	# pins the machinery it will call.)
	var effect := TriggeredEffect.parse({
		"id": "melee_attack",
		"trigger": {"kind": "event", "event": "act", "of": "self"},
		"targets": {"kind": "nearest"},
		"payloads": [{"kind": "attack", "amount": {"kind": "holder_stat", "stat": "attack"}}],
	})
	check(effect != null, "the melee-attack shape parses whole")
	check_eq(effect.to_dict().get("id", ""), "melee_attack", "the named id survives the round-trip")

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
