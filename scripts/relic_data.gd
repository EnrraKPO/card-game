class_name RelicData
extends RefCounted

# A relic is a run-long item that grants run-wide Effects — the run-scoped counterpart to a
# profile Upgrade node (see UpgradeNode). Mechanically identical: a relic just carries an
# Array[Effect] that gets folded into the run's ModifierSet (see ModifierSet.for_run), so relic
# effects flow through the SAME Effect/modifier system as upgrades and cards. Held on RunData
# (run.relics, by id), acquired through the unified ItemKind/Grant layer, and discardable at will.
# Data-driven from data/relics/*.json.

var id: String
var display_name: String
var description: String
var color: Color = Color(0.80, 0.74, 0.45)   # chip colour in the relic tray / offers
var letter: String = "✦"                      # short glyph shown on the chip
var price: int = 80                            # gold cost when offered in a shop
var effects: Array = []                        # Array[Effect] — the run-wide effects this relic grants

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
		var r := RelicData.new()
		r.id           = d.get("id", "")
		r.display_name = d.get("display_name", "")
		r.description  = d.get("description", "")
		r.color        = Color.html(str(d.get("color", "ccbc72")))
		r.letter       = d.get("letter", "✦")
		r.price        = int(d.get("price", 80))
		for e: Dictionary in d.get("effects", []):
			r.effects.append(Effect.from_dict(e))
		if not r.id.is_empty():
			_all[r.id] = r


static func get_relic(p_id: String) -> RelicData:
	return _all.get(p_id, null)


static func all() -> Array:
	return _all.values()
