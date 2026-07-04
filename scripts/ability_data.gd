class_name AbilityData
extends RefCounted

# An ACTIVATED ABILITY: effects with a COST instead of a trigger — the player (or AI) chooses
# to pay and fire it, where triggered effects fire on events. Abilities are authored as
# definitions here (like cards/statuses: data/abilities/*.json, referenced by id) and can be
# held by any effect container — cards today ("abilities": [ids] on the card), statuses/relics
# whenever a design wants it. They are transient: present while their holder is, or until
# removed. That's the whole model — see the abilities design memory; do NOT grow this into a
# container taxonomy.
#
# Cost: `mana` plus optionally `tap` (tap = the holder's action for the round — currently the
# existing attack_exhausted state; refreshed by the round reset). A tapped holder's tap-costed
# abilities are not offered at all.
#
# Presentation: abilities currently live alongside cards in the hand tray, rendered card-like
# (display_card) — a deliberate interim UX; the ability is the real thing, the card shape is a
# view. Display cards are never registered and exist in no pool.

const ABILITY_ART_DIR := "res://assets/abilities/"

var id: String
var display_name: String
var description: String = ""
var mana: int = 0
var tap: bool = true
# For material-delivery abilities: the composition key delivered (see EffectHooks.deliver_material).
var material: String = ""
var effects: Array = []   # Array[Effect] — the ordinary schema (targeting, conditions, payloads)

var _display: CardData = null

static var _all: Dictionary = {}


static func _static_init() -> void:
	var dir := DirAccess.open("res://data/abilities/")
	if dir == null:
		return   # abilities are optional content; an absent folder is fine
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/abilities/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("AbilityData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = json.data if json.data is Array else [json.data]
	for d: Dictionary in entries:
		var ab := AbilityData.from_dict(d)
		if not ab.id.is_empty():
			_all[ab.id] = ab


static func from_dict(d: Dictionary) -> AbilityData:
	var ab := AbilityData.new()
	ab.id           = str(d.get("id", ""))
	ab.display_name = str(d.get("display_name", ab.id.capitalize()))
	ab.description  = str(d.get("description", ""))
	var cost: Dictionary = d.get("cost", {})
	ab.mana         = int(cost.get("mana", 0))
	ab.tap          = bool(cost.get("tap", true))
	ab.material     = str(d.get("material", ""))
	for e_data: Dictionary in d.get("effects", []):
		var eff := Effect.from_dict(e_data)
		eff.owner_kind = "ability"
		eff.owner_id = ab.id
		ab.effects.append(eff)
	return ab


static func get_ability(p_id: String) -> AbilityData:
	return _all.get(p_id, null)


static func all() -> Array:
	return _all.values()


# FALLBACK synthesis for a rook building whose material delivery no one has authored (e.g. a
# forge-derived elemental rook): builds the same shape an authored definition would carry, from
# the same authored schema, and registers it — authoring the id in data/abilities/ replaces it.
static func material_ability(elems: Array, chess: Array) -> AbilityData:
	var key := CardData.composition_key(elems, chess)
	var ab_id := "deliver_" + key
	if _all.has(ab_id):
		return _all[ab_id]
	var remainder := CardData.get_card(key)
	if remainder == null:
		return null
	var ab := from_dict({
		"id": ab_id,
		"display_name": remainder.display_name + " Material",
		"description": "Adds %s to one of your units, merging their compositions - or spawns a new %s on one of your empty slots." \
				% [remainder.display_name, remainder.display_name],
		"cost": {"mana": remainder.cost, "tap": true},
		"material": key,
		"effects": [{
			"kind": "custom", "custom": "deliver_material",
			"trigger": "on_play", "targeting_policy": "manual_slot",
			"conditions": [
				{"composition": ["king", "rook"], "present": false},
				{"attribute": "piece_count", "comparator": "lte", "value": 2 - chess.size()},
				{"attribute": "element_count", "comparator": "lte", "value": 2 - elems.size()},
			],
		}],
	})
	_all[ab_id] = ab
	return ab


# The card-shaped VIEW of this ability for the tray (interim UX: abilities present alongside
# cards). Purely presentational — never registered, in no pool; shares this ability's effects
# so the targeting/eligibility flows read them unchanged. Art: assets/abilities/<id>.png,
# placeholder until authored.
func display_card() -> CardData:
	if _display != null:
		return _display
	var c := CardData.new()
	c.id = id
	c.display_name = display_name
	c.cost = mana
	c.card_type = CardData.CardType.SPELL
	c.description = description
	c.effects = effects
	c.targeting_strategy = TargetingNearest.new()
	# Art: assets/abilities/<id>.png preferred; assets/cards/<id>.png accepted too (the material
	# art predates the ability migration and lives there); placeholder otherwise.
	var art := ABILITY_ART_DIR + id + ".png"
	if not ResourceLoader.exists(art):
		art = "res://assets/cards/%s.png" % id
	c.image = load(art) if ResourceLoader.exists(art) \
			else load("res://assets/cards/placeholder.png")
	_display = c
	return c
