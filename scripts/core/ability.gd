class_name Ability
extends RefCounted

# The ability expansion (Core System Design §7). An ability is its holder's capability
# to have an event fired at it at will; every ability shares the one pair — the ask
# `use_ability` and the engagement `ability_used` — with the asked ability's name riding
# both as NameEventData role `ability`. Appointing an ability expands at construction
# into the ask capability and the USE effect — payload the pay mutator, then the
# substantive mutators, routed through the effect's target resolver. The
# ability-name condition and the route-source + is_holder entry are made by the
# expansion — two units bearing Heal share the event names and are told apart by them.
#
# The authored markup form (fields per §7; detail under A7's delegation — B29):
#   {"name": "heal", "cost": {"mana": 2, "tap": 0}?, "targeting": {...},
#    "effect": {"payload": [...], "windup": ""?, "contact": ""?}}
# cost absent = free (Move's form, A3); the one targeting is the use effect's resolver,
# and every part downstream of the ask rides that one effect — a "trigger" or a second
# "targeting" inside the effect is a stranger.


static func appoint(holder: GameEntity, markup: Dictionary) -> bool:
	for key: String in markup:
		if not ["name", "cost", "targeting", "effect"].has(key):
			push_error("Ability: markup key '%s' is a stranger — refused" % key)
			return false
	if not (markup.get("name") is String):
		push_error("Ability: an ability without a name — refused")
		return false
	var name := StringName(markup.name as String)
	var mana: int = 0
	var tap: int = 0
	if markup.has("cost"):
		var cost: Variant = markup.cost
		if not (cost is Dictionary):
			push_error("Ability: '%s' cost must be an object — refused" % name)
			return false
		for key: String in (cost as Dictionary):
			if not ["mana", "tap"].has(key):
				push_error("Ability: '%s' cost key '%s' is a stranger — refused" % [name, key])
				return false
		mana = int((cost as Dictionary).get("mana", 0))
		tap = int((cost as Dictionary).get("tap", 0))
	if not (markup.get("targeting") is Dictionary):
		push_error("Ability: '%s' without its targeting — refused" % name)
		return false
	var targeting: TargetResolver = MarkupParse.parse_targeting(markup.targeting)
	if targeting == null:
		return false
	if not (markup.get("effect") is Dictionary):
		push_error("Ability: '%s' without its substantive effect — refused" % name)
		return false
	var body: Dictionary = markup.effect
	for key: String in body:
		if not ["payload", "windup", "contact"].has(key):
			push_error("Ability: '%s' effect key '%s' is a stranger — refused" % [name, key])
			return false
	var payload: Array[Mutator] = MarkupParse.parse_payload(body.get("payload", []))
	if payload.size() != (body.get("payload", []) as Array).size():
		return false

	expand(holder, name, mana, tap, targeting, payload,
			StringName(body.get("windup", "") as String),
			StringName(body.get("contact", "") as String))
	return true


# The expansion itself — also the machinery's road (Move appoints through here in code).
static func expand(holder: GameEntity, name: StringName, mana: int, tap: int,
		targeting: TargetResolver, payload: Array[Mutator],
		windup: StringName = &"", contact: StringName = &"") -> void:
	# The use effect: same structure as the play effect (Core §7) — the pay mutator,
	# then the substantive mutators, routed through the effect's target resolver.
	var use_trigger := Trigger.new()
	use_trigger.event = &"use_ability"
	use_trigger.eventdata_conditions.append(_name_condition(name))
	use_trigger.entity_entries.append(source_is_holder())
	var afford_entry := Trigger.EntityEntry.new()
	afford_entry.route = &"holder"
	afford_entry.conditions.append(BakedConditions.Affordability.new(mana, tap))
	use_trigger.entity_entries.append(afford_entry)
	var use_payload: Array[Mutator] = []
	use_payload.append(PayMutator.new(mana, tap))
	use_payload.append_array(payload)
	var use := Effect.new(use_trigger, targeting, use_payload)
	use.windup_presentation = windup
	use.contact_presentation = contact
	holder.effects.append(use)

	# The ask capability: the borne name — what may be fired at the holder.
	holder.abilities.append(name)


# The Move ability (A3, A9): machinery appoints it on every non-building unit at
# construction — free, hand-picked vacant ally slot, the MoveUnitMutator carrying the
# move (A17). Rooted buildings do not receive it. The use effect is built once and
# shared (Mutation §4's lifecycle).
static var _move_effects: Array[Effect] = []

static func appoint_move(unit: Unit) -> void:
	if _move_effects.is_empty():
		var conditions: Array[EntityCondition] = []
		conditions.append(BakedConditions.IsSlot.new())
		conditions.append(IsAllyCondition.new())
		conditions.append(BakedConditions.SlotVacant.new())
		var carrier: Array[Mutator] = []
		carrier.append(MoveUnitMutator.new())
		var probe := GameEntity.new()
		expand(probe, &"move", 0, 0,
				TargetResolver.new(conditions, HandPickDecision.new()), carrier)
		_move_effects = probe.effects
	unit.effects.append_array(_move_effects)
	unit.abilities.append(&"move")


static func _name_condition(name: StringName) -> NameIsCondition:
	var condition := NameIsCondition.new()
	condition.role = &"ability"
	condition.name = name
	return condition


static func source_is_holder() -> Trigger.EntityEntry:
	var entry := Trigger.EntityEntry.new()
	entry.route = &"source"
	entry.conditions.append(IsHolderCondition.new())
	return entry
