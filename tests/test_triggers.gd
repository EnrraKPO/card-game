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
	_kill_event()
	_dodge_event()
	_crit_event()


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
	for ev_id: StringName in [&"play", &"death", &"attack", &"struck", &"act", &"turn_start", &"turn_end"]:
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

	# (The Transient kind and its applies_on_use gate died in the effect-cleanse demolition —
	# activation is a mechanism, not a trigger wearing a cost. TARGETING_DESIGN.md §7/§10.)


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
	# The relation form is DISSOLVED: ally/enemy are ALLEGIANCE predicates against the
	# effect's OWNER side (no holder needed — they work in holderless run-scope
	# containers); identity ("self") is STRUCTURAL (the self target kind / the trigger
	# participant gate) and never becomes a condition.
	var ally := _unit(2, 0)
	var enemy := _unit(2, 1)
	var ally_c := EffectCondition.from_dict({"allegiance": "ally"})
	var enemy_c := EffectCondition.from_dict({"allegiance": "enemy"})
	check(ally_c.evaluate(ally, 0) and not ally_c.evaluate(enemy, 0),
			"allegiance ally = same side as the effect's owner")
	check(enemy_c.evaluate(enemy, 0) and not enemy_c.evaluate(ally, 0),
			"allegiance enemy = opposite side")
	check(not ally_c.evaluate(ally) and not enemy_c.evaluate(enemy),
			"allegiance with no owner side fails closed")

	# Legacy {"relation": ...} parses onto allegiance; serialization converges canonical.
	var legacy_c := EffectCondition.from_dict({"relation": "ally"})
	check(legacy_c.evaluate(ally, 0) and legacy_c.to_dict() == {"allegiance": "ally"},
			"legacy relation ally maps to allegiance (canonical out)")

	# TARGETING REMOVED (targeting-cleanup demolition): the identity-normalization cases that
	# stood here (targets all + relation self consumed into the SELF kind; the native self kind
	# parsing and serializing canonically) belong to the rebuilt targeting authority's suite.
	# What remains testable now: a native targets dict round-trips VERBATIM through parse.
	var native_self := Effect.from_dict({"trigger": {"kind": "while"},
			"targets": {"kind": "self"}, "attribute": "speed", "amount": 1})
	check(native_self.to_dict().get("targets") == {"kind": "self"},
			"a native targets dict is held and re-emitted verbatim")


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
	# Run-level (relic-style) effects go through the same resolvers, anchored to the PLAYER:
	# they fire for ANY unit's event, and "ally"/"enemy" read relative to the player (0), not
	# the event's subject. context.source stays the subject (the spatial anchor).
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
			"run-level effect fires from the subject's perspective")

	# An UNSCOPED run-level effect now fires for enemy-side events too (the old blanket
	# player-side gate is gone — scoping is the effect's own job).
	var enemy_ctx := EffectContext.make(struck, [[striker]], [[struck]])
	enemy_ctx.subject = struck
	var enemy_res := EffectSystem.trigger_global(GameEvent.make(&"attack", struck, striker), enemy_ctx)
	check(not enemy_res.is_empty() and struck.get_attribute("attack") == 3,
			"run-level tier now fires for enemy-side events (no blanket side gate)")

	# An ally-scoped run-level effect anchors "ally" to the PLAYER even for an enemy event:
	# an enemy attacking is NOT an ally, so it does not fire; a player attacking does.
	GameData.current_modifiers = ModifierSet.new()
	GameData.current_modifiers.add(Effect.from_dict({
		"kind": "triggered", "trigger": "on_attack", "subject": "ally",
		"targeting_policy": "subject", "attribute": "attack", "amount": 1,
	}))
	var p2 := _unit(3, 0)
	var e2 := _unit(2, 1)
	var ally_ctx := EffectContext.make(e2, [[p2]], [[e2]])
	ally_ctx.subject = e2
	var on_enemy := EffectSystem.trigger_global(GameEvent.make(&"attack", e2, p2), ally_ctx)
	check(on_enemy.is_empty(), "ally-scoped run effect ignores an enemy's event (anchored to player)")
	var ally_ctx2 := EffectContext.make(p2, [[p2]], [[e2]])
	ally_ctx2.subject = p2
	var on_ally := EffectSystem.trigger_global(GameEvent.make(&"attack", p2, e2), ally_ctx2)
	check(not on_ally.is_empty(), "ally-scoped run effect fires for a player unit's event")
	GameData.current_modifiers = ModifierSet.new()


# The `kill` event: a dual event (killer unit → corpse) with an extra structural CAUSE gate,
# so "when I kill" and "when a unit dies from poison" are both authorable.
func _kill_event() -> void:
	var killer := _unit(3, 0)
	var corpse := _unit(2, 1)

	# "When I kill someone" — origin_of self, no cause filter (any cause counts).
	var mine := Effect.from_dict({"trigger": {"kind": "dual_event", "event": "kill",
			"origin_of": "self"}, "targeting_policy": "self", "attribute": "attack", "amount": 1})
	var rm := mine.trigger_resolver()
	check(rm is TriggerResolver.Dual and (rm as TriggerResolver.Dual).event == &"kill",
			"native kill parses to a dual kill resolver")
	check(rm.fires(GameEvent.kill(killer, corpse, &"attack", &""), killer),
			"kill fires for the unit that landed the fatal blow")
	check(not rm.fires(GameEvent.kill(corpse, killer, &"attack", &""), killer),
			"kill silent when someone else did the killing")
	# A causeless-unit kill (poison: killer unit null) can't satisfy origin_of self.
	check(not rm.fires(GameEvent.kill(null, corpse, &"effect", &"poison"), killer),
			"origin-self kill never fires when no unit is credited (poison)")

	# "When a unit dies from poison" — a cause filter, no origin gate.
	var pz := Effect.from_dict({"trigger": {"kind": "dual_event", "event": "kill",
			"cause": "poison"}, "targeting_policy": "self", "attribute": "attack", "amount": 1})
	var rp := pz.trigger_resolver()
	var watcher := _unit(1, 0)
	check(rp.fires(GameEvent.kill(null, corpse, &"effect", &"poison"), watcher),
			"poison-cause kill fires regardless of who watches")
	check(not rp.fires(GameEvent.kill(killer, corpse, &"attack", &""), watcher),
			"poison-gated kill silent for an attack kill")
	# The cause gate also matches a KIND ("attack"), not just a specific id.
	var atk := Effect.from_dict({"trigger": {"kind": "dual_event", "event": "kill",
			"cause": "attack"}, "targeting_policy": "self", "attribute": "attack", "amount": 1})
	check(atk.trigger_resolver().fires(GameEvent.kill(killer, corpse, &"attack", &""), watcher),
			"cause gate matches the attack kind")

	# Round-trip: the cause survives a to_dict/parse cycle.
	check_eq((rp.to_dict() as Dictionary).get("cause", ""), "poison",
			"kill cause round-trips through to_dict")


# The `dodge` event: a dual event (attacker → dodger) whose subject is the DODGER (destination),
# powering "when an ally dodges…" reactions like the Zephyr Charm relic (air ally → Barrier).
func _dodge_event() -> void:
	var attacker := _unit(3, 1)               # enemy striker whose blow is slipped
	var air_ally := _unit(2, 0, ["air"])      # the player's air dodger
	var fire_ally := _unit(2, 0, ["fire"])    # a non-air ally

	var ev := GameEvent.make(&"dodge", attacker, air_ally)
	check_eq(ev.subject(), air_ally, "dodge subject is the dodger (the destination)")

	# The Zephyr Charm resolver: dual dodge gated on the destination being an allied air unit,
	# targeting that same dodger.
	var relic := Effect.from_dict({
		"kind": "triggered",
		"trigger": {"kind": "dual_event", "event": "dodge",
			"destination_conditions": [{"composition": ["air"]}, {"allegiance": "ally"}]},
		"targets": {"kind": "participant", "participant": "destination"},
		"status": {"id": "barrier", "stacks": 1},
	})
	var r := relic.trigger_resolver()
	check(r is TriggerResolver.Dual and (r as TriggerResolver.Dual).event == &"dodge",
			"native dodge parses to a dual dodge resolver")
	# Anchored to the player (0): fires for an allied air dodger, not for a non-air ally, and not
	# for an enemy air unit (ally is relative to the player).
	check(r.fires(ev, null, 0), "dodge fires when an allied air unit dodges")
	check(not r.fires(GameEvent.make(&"dodge", attacker, fire_ally), null, 0),
			"dodge silent when the dodger isn't an air unit")
	check(not r.fires(GameEvent.make(&"dodge", air_ally, _unit(2, 1, ["air"])), null, 0),
			"dodge silent when the dodger is an enemy (ally anchored to the player)")

	# End-to-end run-level dispatch: the relic hangs a Barrier on the dodging air ally.
	GameData.current_modifiers = ModifierSet.new()
	GameData.current_modifiers.add(relic)
	var ctx := EffectContext.make(air_ally, [[air_ally]], [[attacker]])
	ctx.subject = air_ally
	var res := EffectSystem.trigger_global(ev, ctx)
	check(not res.is_empty(), "run-level dodge reaction fires")
	check(air_ally.find_status("barrier") != null, "the dodging air ally gains a Barrier")
	GameData.current_modifiers = ModifierSet.new()


# The `crit` dual event — the one dual event whose subject is the ORIGIN (the attacker who
# landed the crit), matching `attack`'s acting-party framing, NOT the struck/kill/dodge
# destination convention. The Berserker's Momentum relic rides it: origin_conditions +
# participant "origin", the mirror image of Zephyr Charm's destination wiring.
func _crit_event() -> void:
	var fire_ally := _unit(2, 0, ["fire"])    # the player's fire attacker
	var plain_ally := _unit(2, 0)             # a non-fire ally
	var enemy_tgt := _unit(3, 1)              # the unit being crit

	var ev := GameEvent.make(&"crit", fire_ally, enemy_tgt)
	check_eq(ev.subject(), fire_ally, "crit subject is the ATTACKER (the origin)")

	# The Berserker's Momentum resolver: dual crit gated on the ORIGIN being an allied fire
	# unit, targeting that same attacker.
	var relic := Effect.from_dict({
		"kind": "triggered",
		"trigger": {"kind": "dual_event", "event": "crit",
			"origin_conditions": [{"composition": ["fire"]}, {"allegiance": "ally"}]},
		"targets": {"kind": "participant", "participant": "origin"},
		"attribute": "attack", "amount": 1,
	})
	var r := relic.trigger_resolver()
	check(r is TriggerResolver.Dual and (r as TriggerResolver.Dual).event == &"crit",
			"native crit parses to a dual crit resolver")
	# Anchored to the player (0): fires for an allied fire attacker's crit, not for a non-fire
	# ally's, and not for an enemy fire unit's (ally is relative to the player).
	check(r.fires(ev, null, 0), "crit fires when an allied fire unit lands one")
	check(not r.fires(GameEvent.make(&"crit", plain_ally, enemy_tgt), null, 0),
			"crit silent when the attacker isn't a fire unit")
	check(not r.fires(GameEvent.make(&"crit", _unit(2, 1, ["fire"]), fire_ally), null, 0),
			"crit silent when the attacker is an enemy (ally anchored to the player)")

	# End-to-end run-level dispatch: the relic bumps the critting attacker's Attack by 1.
	GameData.current_modifiers = ModifierSet.new()
	GameData.current_modifiers.add(relic)
	var ctx := EffectContext.make(fire_ally, [[fire_ally]], [[enemy_tgt]])
	ctx.subject = fire_ally
	var before := int(fire_ally.get_attribute("attack"))
	var res := EffectSystem.trigger_global(ev, ctx)
	check(not res.is_empty(), "run-level crit reaction fires")
	check_eq(int(fire_ally.get_attribute("attack")), before + 1,
			"the critting fire ally gains 1 Attack")
	GameData.current_modifiers = ModifierSet.new()
