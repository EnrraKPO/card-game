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
# Localized text lives in Loc under `ability.<id>.name`/`.desc`, not the data file. Getter reads
# Loc at access time; `_override` is the fallback for runtime-composed abilities (e.g. "Material"
# abilities) that have no Loc key. See CardData for the same pattern.
var _name_override := ""
var display_name: String:
	get:
		var s := Loc.opt("ability.%s.name" % id)
		return s if s != "" else _name_override
	set(value):
		_name_override = value
var _desc_override := ""
var description: String:
	get:
		var s := Loc.opt("ability.%s.desc" % id)
		return s if s != "" else _desc_override
	set(value):
		_desc_override = value
var mana: int = 0
var tap: bool = true
# (The `autocast` flag, the `material` delivery key, and the carried `effects` array were
# deleted 2026-08-11 with the effect layer: their mechanisms are razed and nothing may
# exist on round-trip life-support. The rebuilt ActivatedEffect (TARGETING_DESIGN.md §7)
# is the runtime body abilities have been missing; what an ability DOES is re-authored in
# the new schema when the rebuild reaches this container.)

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
		if not bool(d.get("enabled", true)):
			continue
		var ab := AbilityData.from_dict(d)
		if not ab.id.is_empty():
			_all[ab.id] = ab


static func from_dict(d: Dictionary) -> AbilityData:
	var ab := AbilityData.new()
	ab.id           = str(d.get("id", ""))
	# display_name/description resolve through Loc by id (see the property getters) — not read here.
	var cost: Dictionary = d.get("cost", {})
	ab.mana         = int(cost.get("mana", 0))
	ab.tap          = bool(cost.get("tap", true))
	if d.has("effects"):
		push_error("AbilityData %s: 'effects' is the deleted schema (effect-cleanse 2026-08-11) — dropped; re-author in the new schema" % ab.id)
	return ab


static func get_ability(p_id: String) -> AbilityData:
	return _all.get(p_id, null)


static func all() -> Array:
	return _all.values()


# FALLBACK synthesis for a rook building whose material delivery no one has authored (e.g.
# a forge-derived elemental rook): registers a cost-and-text shell so the building still
# PRESENTS its delivery ability. What it DOES is razed with the effect layer — the
# material-merge semantics become an authored payload species in the new schema (the
# deliver_material NEED recorded at the hook burn), and this synthesis then authors it
# natively. Authoring the id in data/abilities/ replaces the fallback either way.
static func material_ability(elems: Array, chess: Array) -> AbilityData:
	var key := CardData.composition_key(elems, chess)
	var ab_id := "deliver_" + key
	if _all.has(ab_id):
		return _all[ab_id]
	var remainder := CardData.get_card(key)
	if remainder == null:
		return null
	var ab := from_dict({"id": ab_id, "cost": {"mana": remainder.cost, "tap": true}})
	# Runtime-composed ability (no Loc key): its text lives only in the override. Uses the
	# remainder card's localized name; the English scaffolding is the parked derived-string case.
	ab.display_name = remainder.display_name + " Material"
	ab.description = "Adds %s to one of your units, merging their compositions - or spawns a new %s on one of your empty slots." \
			% [remainder.display_name, remainder.display_name]
	_all[ab_id] = ab
	return ab


# THE usability rule — one definition, consulted by everything that presents or gates an
# ability (today the Inspect Abilities button's ready-glow via CombatContext.ability_usable;
# the rebuilt activation gate joins it). Pure query of live facts, so no two consumers can
# ever disagree about whether an ability is castable this moment.
#
# Its READINESS half stands alone below because two consumers legitimately ask it apart
# from affordability: the tray offer defers mana to cast time (CardInstance.
# has_available_abilities), and the enemy engine's sim asks against its own planned
# `exhausted` snapshot rather than the live holder. Neither may re-spell the clause.
func usable_by(holder: CardInstance, mana_available: int) -> bool:
	if holder == null:
		return false
	return ready(holder.attack_exhausted) and self.mana <= mana_available


# The readiness half of THE usability rule: a tap-costed ability needs an unspent tap.
# `exhausted` is passed in rather than read off a holder so a simulation can ask about
# its hypothetical state through the same one clause.
func ready(exhausted: bool) -> bool:
	return not (tap and exhausted)


# The card-shaped VIEW of this ability for the tray (interim UX: abilities present alongside
# cards). Purely presentational — never registered, in no pool. Art: assets/abilities/<id>.png,
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
	# Art: assets/abilities/<id>.png preferred; assets/cards/<id>.png accepted too (the material
	# art predates the ability migration and lives there); placeholder otherwise.
	var art := ABILITY_ART_DIR + id + ".png"
	if not ResourceLoader.exists(art):
		art = "res://assets/cards/%s.png" % id
	c.image = load(art) if ResourceLoader.exists(art) \
			else load("res://assets/cards/placeholder.png")
	_display = c
	return c
