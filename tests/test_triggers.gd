extends TestCase

# The trigger-resolver system: effects hold an injected TriggerResolver that alone decides
# activation, from a GameEvent's origin/destination and the effect's holder. Covers the
# legacy schema mapping (zero-migration), native-form parsing, dual origin/destination
# gating, relation conditions, round-trip fidelity, and dispatch through EffectSystem.


func suite_name() -> String:
	return "Trigger resolvers"


func run() -> void:
	_legacy_mapping()
	_native_form()
	_dual_gating()
	_relation_conditions()
	_round_trip()
	_dispatch()
	_run_level_dispatch()


# A throwaway unit with known stats/composition, placed on a side.
func _unit(atk: int, owner: int, elements: Array = [], pieces: Array = ["pawn"]) -> CardInstance:
	var inst := CardInstance.from_data(CardData.build_from_dict({
		"id": "_trig_test", "display_name": "T",
		"cost": 1, "attack": atk, "health": 5, "speed": 1,
		"elements": elements, "chess_pieces": pieces,
	}))
	inst.owner = owner
	return inst


func _legacy_mapping() -> void:
	# Default subject (SELF) on a simple event → SimpleEventTrigger with a self relation.
	var e := Effect.from_dict({"trigger": "on_death", "targeting_policy": "all_allies",
			"attribute": "attack", "amount": 1})
	var r := e.trigger_resolver()
	check(r is TriggerResolver.Simple, "legacy on_death maps to a simple event resolver")
	check((r as TriggerResolver.Simple).event == &"death", "…on the death event")
	var holder := _unit(2, 0)
	var other := _unit(2, 0)
	check(r.fires(GameEvent.make(&"death", holder), holder), "self-gated: fires for its own death")
	check(not r.fires(GameEvent.make(&"death", other), holder), "self-gated: silent for another unit's death")
	check(not r.fires(GameEvent.make(&"turn_end", holder), holder), "wrong event never fires")

	# on_attack → dual event, subject conditions land on the ORIGIN.
	var ea := Effect.from_dict({"trigger": "on_attack", "targeting_policy": "attack_target",
			"status": {"id": "poison", "stacks": 1}})
	var ra := ea.trigger_resolver()
	check(ra is TriggerResolver.Dual and (ra as TriggerResolver.Dual).event == &"attack",
			"legacy on_attack maps to the dual attack event")
	check(ra.fires(GameEvent.make(&"attack", holder, other), holder), "attack fires when the holder strikes")
	check(not ra.fires(GameEvent.make(&"attack", other, holder), holder), "attack silent when the holder is struck")

	# on_damage_taken → dual struck event, subject conditions land on the DESTINATION.
	var ed := Effect.from_dict({"trigger": "on_damage_taken", "targeting_policy": "attacker",
			"attribute": "damage_taken", "amount": 2})
	var rd := ed.trigger_resolver()
	check(rd is TriggerResolver.Dual and (rd as TriggerResolver.Dual).event == &"struck",
			"legacy on_damage_taken maps to the dual struck event")
	check(rd.fires(GameEvent.make(&"struck", other, holder), holder), "struck fires when the holder is hit")
	check(not rd.fires(GameEvent.make(&"struck", holder, other), holder), "struck silent when the holder strikes")

	# subject "ally" + subject_elements → relation + composition conditions on the subject side.
	var light_ally := _unit(2, 0, ["light"])
	var dark_enemy := _unit(2, 1, ["darkness"])
	var ew := Effect.from_dict({"trigger": "on_attack", "subject": "ally",
			"subject_elements": ["light"], "targeting_policy": "attack_target",
			"status": {"id": "blind", "stacks": 1}})
	var rw := ew.trigger_resolver()
	check(rw.fires(GameEvent.make(&"attack", light_ally, dark_enemy), holder),
			"ally+elements gate passes a light ally's attack")
	check(not rw.fires(GameEvent.make(&"attack", dark_enemy, light_ally), holder),
			"ally+elements gate rejects an enemy's attack")
	check(not rw.fires(GameEvent.make(&"attack", holder, dark_enemy), holder),
			"ally+elements gate rejects a non-light ally's attack")

	# permanent stays inert: listens to an event nothing ever emits.
	var ep := Effect.from_dict({"trigger": "permanent", "targeting_policy": "self",
			"attribute": "attack", "amount": 1})
	for ev_id: StringName in [&"play", &"death", &"attack", &"struck", &"activate", &"turn_start", &"turn_end"]:
		if ep.trigger_resolver().listens(ev_id):
			check(false, "permanent must stay inert (listened to %s)" % ev_id)
			return
	check(true, "permanent stays inert for every emitted event")


func _native_form() -> void:
	var e := Effect.from_dict({
		"trigger": {"kind": "dual_event", "event": "death",
			"origin_conditions": [{"composition": ["darkness", "pawn"]}, {"attribute": "attack", "comparator": "gt", "value": 2}]},
		"targeting_policy": "self", "attribute": "attack", "amount": 1,
	})
	# (death is a simple event authored as dual here on purpose: the parser honors the kind,
	# and a destination-less death event still fires when only origin conditions are set.)
	var holder := _unit(2, 0)
	var weak_dark_pawn := _unit(2, 1, ["darkness"], ["pawn"])
	var strong_dark_pawn := _unit(4, 1, ["darkness"], ["pawn"])
	var strong_knight := _unit(4, 1, [], ["knight"])
	check(e.trigger_resolver().fires(GameEvent.make(&"death", strong_dark_pawn), holder),
			"native form: strong darkness pawn's death fires it")
	check(not e.trigger_resolver().fires(GameEvent.make(&"death", weak_dark_pawn), holder),
			"native form: stat gate rejects attack <= 2")
	check(not e.trigger_resolver().fires(GameEvent.make(&"death", strong_knight), holder),
			"native form: composition gate rejects a knight")

	var t := Effect.from_dict({"trigger": {"kind": "transient"}, "targeting_policy": "manual",
			"attribute": "health", "amount": -2})
	check(t.trigger_resolver() is TriggerResolver.Transient, "native transient parses")
	check(t.trigger_resolver().applies_on_use(), "transient applies on use")
	check(not t.trigger_resolver().fires(GameEvent.make(&"play", holder), holder),
			"transient never fires from events")
	check(t.trigger == Effect.Trigger.ON_PLAY, "transient derives the ON_PLAY compat trigger")


func _dual_gating() -> void:
	# Both sides gate at once: "an ally of mine is struck by a darkness unit".
	var e := Effect.from_dict({
		"trigger": {"kind": "dual_event", "event": "struck",
			"origin_conditions": [{"relation": "enemy"}, {"composition": ["darkness"]}],
			"destination_conditions": [{"relation": "ally"}]},
		"targeting_policy": "attacker", "status": {"id": "blind", "stacks": 1},
	})
	var holder := _unit(2, 0)
	var ally := _unit(2, 0)
	var dark_enemy := _unit(3, 1, ["darkness"])
	var plain_enemy := _unit(3, 1)
	var r := e.trigger_resolver()
	check(r.fires(GameEvent.make(&"struck", dark_enemy, ally), holder),
			"dual gate: darkness enemy striking an ally fires")
	check(not r.fires(GameEvent.make(&"struck", plain_enemy, ally), holder),
			"dual gate: origin composition must pass")
	check(not r.fires(GameEvent.make(&"struck", dark_enemy, plain_enemy), holder),
			"dual gate: destination relation must pass")
	# The agreed ruling: a non-empty condition list on a MISSING participant fails.
	check(not r.fires(GameEvent.make(&"struck", dark_enemy, null), holder),
			"conditions on a missing destination fail closed")


func _relation_conditions() -> void:
	var holder := _unit(2, 0)
	var ally := _unit(2, 0)
	var enemy := _unit(2, 1)
	var self_c := EffectCondition.from_dict({"relation": "self"})
	var ally_c := EffectCondition.from_dict({"relation": "ally"})
	var enemy_c := EffectCondition.from_dict({"relation": "enemy"})
	check(self_c.evaluate(holder, holder) and not self_c.evaluate(ally, holder),
			"relation self = the holder itself")
	check(ally_c.evaluate(ally, holder) and ally_c.evaluate(holder, holder) and not ally_c.evaluate(enemy, holder),
			"relation ally = same side (holder included)")
	check(enemy_c.evaluate(enemy, holder) and not enemy_c.evaluate(ally, holder),
			"relation enemy = opposite side")
	check(not self_c.evaluate(holder), "relation without a holder fails closed")


func _round_trip() -> void:
	# Legacy in → legacy out, byte-shape preserved (subject omitted when SELF).
	var legacy := {"trigger": "on_damage_taken", "subject": "ally", "subject_elements": ["water"],
			"targeting_policy": "attacker", "attribute": "damage_taken", "amount": 2, "conditions": []}
	var d := Effect.from_dict(legacy).to_dict()
	check(str(d.get("trigger")) == "on_damage_taken" and str(d.get("subject")) == "ally"
			and d.get("subject_elements") == ["water"],
			"legacy trigger schema round-trips unchanged")
	var d2 := Effect.from_dict({"trigger": "on_play", "targeting_policy": "self",
			"attribute": "attack", "amount": 1}).to_dict()
	check(str(d2.get("trigger")) == "on_play" and not d2.has("subject"),
			"default subject stays omitted on round-trip")

	# Native in → native out, then re-parses to an equivalent resolver.
	var native := {"trigger": {"kind": "dual_event", "event": "attack",
			"origin_conditions": [{"relation": "ally"}]},
			"targeting_policy": "self", "attribute": "attack", "amount": 1}
	var nd := Effect.from_dict(native).to_dict()
	var trig: Variant = nd.get("trigger")
	check(trig is Dictionary and str((trig as Dictionary).get("kind")) == "dual_event",
			"native trigger schema round-trips as a dictionary")
	var reparsed := Effect.from_dict(nd)
	var holder := _unit(2, 0)
	var ally := _unit(2, 0)
	var enemy := _unit(2, 1)
	check(reparsed.trigger_resolver().fires(GameEvent.make(&"attack", ally, enemy), holder)
			and not reparsed.trigger_resolver().fires(GameEvent.make(&"attack", enemy, ally), holder),
			"re-parsed native resolver behaves identically")
	check(reparsed.trigger == Effect.Trigger.ON_ATTACK, "native form derives the compat trigger enum")


func _dispatch() -> void:
	# End-to-end through EffectSystem.trigger: a bystander watcher fires on another unit's
	# death (the new capability), while a legacy self-gated effect stays silent.
	var watcher := CardInstance.from_data(CardData.build_from_dict({
		"id": "_watcher", "display_name": "W", "cost": 1, "attack": 2, "health": 5, "speed": 1,
		"effects": [{
			"trigger": {"kind": "event", "event": "death",
				"conditions": [{"relation": "ally"}, {"composition": ["pawn"]}]},
			"targeting_policy": "self", "attribute": "attack", "amount": 2,
		}],
	}))
	watcher.owner = 0
	var legacy_bystander := CardInstance.from_data(CardData.build_from_dict({
		"id": "_legacy_bystander", "display_name": "L", "cost": 1, "attack": 2, "health": 5, "speed": 1,
		"effects": [{"trigger": "on_death", "targeting_policy": "self", "attribute": "attack", "amount": 2}],
	}))
	legacy_bystander.owner = 0
	var dying_pawn := _unit(1, 0)   # pawn composition, player side

	var ctx := EffectContext.make(watcher, [[watcher, legacy_bystander, dying_pawn]], [[]])
	var ev := GameEvent.make(&"death", dying_pawn)
	var res := EffectSystem.trigger(ev, watcher, ctx)
	check_eq(watcher.get_attribute("attack"), 4, "bystander watcher fires on an ally pawn's death")
	check(not res.is_empty(), "watcher dispatch produced a result")

	var ctx2 := EffectContext.make(legacy_bystander, [[watcher, legacy_bystander, dying_pawn]], [[]])
	EffectSystem.trigger(ev, legacy_bystander, ctx2)
	check_eq(legacy_bystander.get_attribute("attack"), 2,
			"legacy self-gated effect stays silent for another unit's death")

	var enemy_pawn := _unit(1, 1)
	watcher.modifiers.clear()
	EffectSystem.trigger(GameEvent.make(&"death", enemy_pawn), watcher, ctx)
	check_eq(watcher.get_attribute("attack"), 2, "watcher's ally gate rejects an enemy death")


func _run_level_dispatch() -> void:
	# Run-level (relic-style) effects go through the same resolvers, keeping the legacy
	# perspective trick: the event's subject is both perspective and holder.
	var striker := _unit(3, 0)
	var struck := _unit(2, 1)
	GameData.current_modifiers = ModifierSet.new()
	GameData.current_modifiers.add(Effect.from_dict({
		"kind": "triggered", "trigger": "on_attack",
		"targeting_policy": "subject", "attribute": "attack", "amount": 1,
	}))
	var ctx := EffectContext.make(striker, [[striker]], [[struck]])
	ctx.subject = striker
	var res := EffectSystem.trigger_global(GameEvent.make(&"attack", striker, struck), ctx)
	check(not res.is_empty() and striker.get_attribute("attack") == 4,
			"run-level legacy effect fires from the subject's perspective")
	# Enemy-side events never feed the player's run-level tier.
	var enemy_ctx := EffectContext.make(struck, [[striker]], [[struck]])
	enemy_ctx.subject = struck
	var enemy_res := EffectSystem.trigger_global(GameEvent.make(&"attack", struck, striker), enemy_ctx)
	check(enemy_res.is_empty(), "run-level tier stays player-side only")
	GameData.current_modifiers = ModifierSet.new()
