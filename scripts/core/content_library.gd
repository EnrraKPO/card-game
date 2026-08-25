class_name ContentLibrary
extends RefCounted

# The registry of authored content in the A7 envelope: one object per card — identity
# (id, display name); kind (`unit` or `spell`, deciding the constructed type); stats as
# a name→value map seeding construction, validated against the type's declared lists;
# birth facts where the type bears them (`building`, `king`, `elements` — A7, T1); `effects` — a list of the
# bible's effect markup; `abilities` — a list of the Core §7 ability form. Relics and
# statuses use the same envelope minus kind. Strangers refused loudly.
#
# Registration parses ONCE — the parsed effects and expanded ability effects are shared
# across every copy built and every simulated world (the Mutation §4 lifecycle); build
# seeds a fresh entity from the parsed definition. The StatusProcedure consults this
# registry when minting: a registered status carries its authored rules, an unregistered
# id mints bare (a plain marker) — B33.

static var _cards: Dictionary = {}
static var _relics: Dictionary = {}
static var _statuses: Dictionary = {}


static func clear() -> void:
	_cards.clear()
	_relics.clear()
	_statuses.clear()


# ── Registration: parse once, refuse loudly ────────────────────────────────────────────

static func register_card(envelope: Dictionary) -> bool:
	return _register(envelope, _cards, true)


static func register_relic(envelope: Dictionary) -> bool:
	return _register(envelope, _relics, false)


static func register_status(envelope: Dictionary) -> bool:
	return _register(envelope, _statuses, false)


static func _register(envelope: Dictionary, into: Dictionary, carded: bool) -> bool:
	var allowed: Array = ["id", "name", "stats", "building", "king", "elements", "effects", "abilities"]
	if carded:
		allowed.append("kind")
	for key: String in envelope:
		if not allowed.has(key):
			push_error("ContentLibrary: envelope key '%s' is a stranger — refused" % key)
			return false
	if not (envelope.get("id") is String):
		push_error("ContentLibrary: an envelope without an id — refused")
		return false
	var id := StringName(envelope.id as String)
	if carded and not ["unit", "spell"].has(envelope.get("kind")):
		push_error("ContentLibrary: card '%s' needs kind 'unit' or 'spell' — refused" % id)
		return false
	var parsed: Dictionary = {
		"id": id,
		"name": String(envelope.get("name", envelope.id)),
		"kind": envelope.get("kind", ""),
		"stats": envelope.get("stats", {}),
		"building": bool(envelope.get("building", false)),
		"king": bool(envelope.get("king", false)),
		"effects": [] as Array[Effect],
		"abilities": envelope.get("abilities", []),
		"elements": [] as Array[StringName],
	}
	for element: Variant in envelope.get("elements", []):
		if not (element is String):
			push_error("ContentLibrary: '%s': an element must be a string — refused" % id)
			return false
		(parsed.elements as Array[StringName]).append(StringName(element))
	for markup: Variant in envelope.get("effects", []):
		if not (markup is Dictionary):
			push_error("ContentLibrary: '%s': an effect must be an object — refused" % id)
			return false
		var effect: Effect = MarkupParse.parse_effect(markup)
		if effect == null:
			return false
		(parsed.effects as Array[Effect]).append(effect)
	# Abilities expand per build (the expansion binds nothing holder-specific — its
	# parts are stateless — but appointment appends to a holder, so it runs at build
	# against a template's parse done here for refusal's sake).
	var probe := GameEntity.new()
	for markup: Variant in envelope.get("abilities", []):
		if not (markup is Dictionary) or not Ability.appoint(probe, markup):
			push_error("ContentLibrary: '%s': an ability failed its parse — refused" % id)
			return false
	parsed["ability_effects"] = probe.effects
	parsed["ability_names"] = probe.abilities
	into[id] = parsed
	return true


# ── Build: a fresh entity from the parsed definition ───────────────────────────────────

static func build_card(id: StringName, side: Side) -> Card:
	var parsed: Dictionary = _cards.get(id, {})
	if parsed.is_empty():
		push_error("ContentLibrary: no card '%s' is registered" % id)
		return null
	var card: Card
	if parsed.kind == "unit":
		var unit := Unit.new(side, parsed.building)
		unit.is_king = parsed.king
		card = unit
	else:
		card = Spell.new(side)
	_dress(card, parsed)
	return card


static func build_relic(id: StringName, side: Side) -> Relic:
	var parsed: Dictionary = _relics.get(id, {})
	if parsed.is_empty():
		push_error("ContentLibrary: no relic '%s' is registered" % id)
		return null
	var relic := Relic.new(side)
	_dress(relic, parsed)
	return relic


# Null when the id is unregistered — the StatusProcedure then mints bare (B33).
static func build_status(id: StringName, side: Side) -> Status:
	var parsed: Dictionary = _statuses.get(id, {})
	if parsed.is_empty():
		return null
	var status := Status.new(id, side)
	_dress(status, parsed)
	return status


static func _dress(entity: GameEntity, parsed: Dictionary) -> void:
	entity.id = parsed.id
	entity.display_name = parsed.name
	for stat: String in (parsed.stats as Dictionary):
		entity.seed_stat(StringName(stat), float(parsed.stats[stat]))
	if entity is Card:
		(entity as Card).elements = (parsed.elements as Array[StringName]).duplicate()
	entity.effects.append_array(parsed.effects as Array[Effect])
	entity.effects.append_array(parsed.ability_effects as Array[Effect])
	for ability_name: StringName in (parsed.ability_names as Array[StringName]):
		entity.abilities.append(ability_name)
