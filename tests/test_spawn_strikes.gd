extends TestCase

# The two enemy-set engine additions (branch enemy-sets):
#   • the `spawn` payload — {"spawn": {"id": ..., "count": n}} on any triggered effect queues
#     units onto the target's side (CombatBoard flushes after death sweeps; splits, summons,
#     phase-change bosses all ride it — see EffectSystem._apply / CombatBoard.queue_spawn).
#   • the `strikes` stat — attacks per round (base 1), foldable like any stat so statuses and
#     standing effects can grant extra strikes (combat._resolve_attack loops it).
# The board-flush half of spawning needs a live CombatBoard (SlotUI/CardUI); that path is
# covered by live combat QA — here we prove the schema, the fold, and the no-board no-op.


func suite_name() -> String:
	return "Spawn payload & multi-strike"


func run() -> void:
	_spawn_parse()
	_spawn_no_board_noop()
	_strikes_base()
	_strikes_fold()


func _spawn_parse() -> void:
	var e := Effect.from_dict({"trigger": "on_death", "targeting_policy": "self",
			"spawn": {"id": "goblin_cutter", "count": 2}})
	check_eq(e.spawn_id, "goblin_cutter", "spawn id parses")
	check_eq(e.spawn_count, 2, "spawn count parses")
	check_eq(e.kind, Effect.Kind.TRIGGERED, "a spawn effect is an ordinary triggered effect")

	var d := e.to_dict()
	check(d.has("spawn"), "to_dict serialises the spawn payload")
	check_eq(d["spawn"]["id"], "goblin_cutter", "round-trip keeps the id")
	check_eq(d["spawn"]["count"], 2, "round-trip keeps the count")
	var e2 := Effect.from_dict(d)
	check_eq(e2.spawn_id, "goblin_cutter", "re-parse matches")

	var defaults := Effect.from_dict({"trigger": "on_death", "targeting_policy": "self",
			"spawn": {"id": "goblin_cutter"}})
	check_eq(defaults.spawn_count, 1, "count defaults to 1")
	check_eq(Effect.from_dict({"trigger": "on_play", "targeting_policy": "self",
			"attribute": "attack", "amount": 1}).spawn_id, "",
			"no spawn key = no spawn payload")


func _spawn_no_board_noop() -> void:
	# Outside combat there is no board in the context — the payload must be inert, not crash.
	var holder := unit("goblin_fanatic")
	var e := Effect.from_dict({"trigger": "on_play", "targeting_policy": "self",
			"spawn": {"id": "goblin_cutter", "count": 2}})
	var results := EffectSystem.apply_single(e, holder, ctx_for(holder))
	check_eq(results.size(), 0, "spawn without a board is a silent no-op")


func _strikes_base() -> void:
	var plain := unit("goblin_cutter")
	check_eq(plain.get_attribute("strikes"), 1, "every card defaults to 1 strike")

	var d := CardData.get_card("goblin_cutter").to_dict()
	check(not d.has("strikes"), "single-strike cards serialise without the key (byte-stable)")

	var flurry := CardData.build_from_dict({"id": "_t_flurry", "display_name": "T",
			"cost": 1, "attack": 2, "health": 3, "speed": 4, "strikes": 3})
	check_eq(flurry.strikes, 3, "authored strikes parse")
	check_eq(flurry.to_dict().get("strikes", 0), 3, "authored strikes serialise")
	var scaled := CardData.scaled(flurry, 5.0)
	check_eq(scaled.strikes, 3, "power scaling preserves strikes")
	check_eq(CardInstance.from_data(flurry).get_attribute("strikes"), 3,
			"an instance reads its card's strikes")


func _strikes_fold() -> void:
	var inst := unit("goblin_cutter")
	inst.apply_modifier("strikes", 1)   # storage-level write, as the Resolver would land it
	check_eq(inst.get_attribute("strikes"), 2, "written modifiers fold into strikes")
	inst.apply_modifier("strikes", -5)
	check_eq(inst.get_attribute("strikes"), 1, "strikes floor at 1 — the basic attack survives")

	# A status carrying a standing +1 strikes (the harpy-frenzy shape) folds at read time
	# and leaves with the status.
	StatusData._all["_t_flurry_status"] = StatusData.from_dict({"id": "_t_flurry_status",
			"decay": "none", "effects": [{"trigger": {"kind": "while"},
			"targets": {"kind": "self"}, "attribute": "strikes", "amount": 1}]})
	var fresh := unit("goblin_cutter")
	StatusEngine.apply(fresh, "_t_flurry_status", Effect.STATUS_DURATION_DEFAULT, 1, null)
	check_eq(fresh.get_attribute("strikes"), 2, "a standing status effect grants an extra strike")
	fresh.remove_status("_t_flurry_status")
	check_eq(fresh.get_attribute("strikes"), 1, "and it leaves with the status")
