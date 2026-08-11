class_name RelicData
extends RefCounted

# A relic is a run-long item — a run-scope effect container (TARGETING_DESIGN.md §1), the
# counterpart to a profile Upgrade node (see UpgradeNode). What a relic DOES was razed with
# the effect layer (2026-08-11) and re-authors in the new schema when the rebuild reaches
# this container (each relic's description is its brief). Held on RunData (run.relics, by
# id), acquired through the unified ItemKind/Grant layer, and discardable at will.
# Data-driven from data/relics/*.json.

var id: String
# Localized text (Loc `relic.<id>.name`/`.desc`), not read from the data file. See CardData.
var _name_override := ""
var display_name: String:
	get:
		var s := Loc.opt("relic.%s.name" % id)
		return s if s != "" else _name_override
	set(value):
		_name_override = value
var _desc_override := ""
var description: String:
	get:
		var s := Loc.opt("relic.%s.desc" % id)
		return s if s != "" else _desc_override
	set(value):
		_desc_override = value
var color: Color = Color(0.80, 0.74, 0.45)   # chip colour in the relic tray / offers
var letter: String = "✦"                      # short glyph shown on the chip when there's no icon
var icon: Texture2D = null                     # optional illustration; when present it replaces the
											   # coloured letter chip everywhere the relic is shown
var price: int = 80                            # gold cost when offered in a shop
# A CONSUMABLE relic is an item the player SPENDS, not a passive: used from combat by
# holding its chip (see ConsumableChip), and discarded by the use. It still holds a normal
# relic slot until spent.
var consumable: bool = false

static var _all: Dictionary = {}


static func _static_init() -> void:
	var dir := DirAccess.open("res://data/relics/")
	if dir == null:
		return   # relics are optional content; an absent folder is fine
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/relics/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("RelicData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = json.data if json.data is Array else [json.data]
	for d: Dictionary in entries:
		if not bool(d.get("enabled", true)):
			continue
		var r := RelicData.new()
		r.id           = d.get("id", "")
		# display_name/description resolve through Loc by id (see the property getters).
		r.color        = Color.html(str(d.get("color", "ccbc72")))
		r.letter       = d.get("letter", "✦")
		# Art is by-convention (assets/relics/<id>.png), same pattern card_data uses for card art —
		# no path in the JSON. Absent art is fine: the letter+colour chip is the fallback everywhere.
		var art_path := "res://assets/relics/%s.png" % r.id
		if ResourceLoader.exists(art_path):
			r.icon = load(art_path)
		r.price        = int(d.get("price", 80))
		r.consumable   = bool(d.get("consumable", false))
		if not (d.get("effects", []) as Array).is_empty():
			push_error("RelicData %s: 'effects' is the deleted schema (effect-cleanse 2026-08-11) — dropped; re-author in the new schema" % r.id)
		if not r.id.is_empty():
			_all[r.id] = r


static func get_relic(p_id: String) -> RelicData:
	return _all.get(p_id, null)


static func all() -> Array:
	return _all.values()
