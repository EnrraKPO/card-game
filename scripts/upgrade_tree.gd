class_name UpgradeTree
extends RefCounted

# A skill tree shown on the Upgrades screen: an authored set of UpgradeNodes the player will
# spend points in to customise a profile. Data-driven from data/upgrades/*.json (one tree per
# file, or an array of trees per file). The spend/effect rules are deliberately unspecified
# for now — this only loads and exposes the authored content for the screen to render.

var id: String
var display_name: String
var description: String
var color: Color = Color(0.55, 0.6, 0.85)   # tree accent (tabs, link lines)
var nodes: Array[UpgradeNode] = []

static var _all: Dictionary = {}
static var _order: Array[String] = []   # preserves load order so the tab strip is stable


static func _static_init() -> void:
	var dir := DirAccess.open("res://data/upgrades/")
	if dir == null:
		return   # upgrades are optional content; an absent folder is fine
	var files := dir.get_files()
	files.sort()   # deterministic order regardless of the filesystem's enumeration
	for fname: String in files:
		if fname.ends_with(".json"):
			_load_json("res://data/upgrades/" + fname)


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("UpgradeTree: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = json.data if json.data is Array else [json.data]
	for d: Dictionary in entries:
		var t := UpgradeTree.new()
		t.id           = d.get("id", "")
		t.display_name = d.get("display_name", "")
		t.description  = d.get("description", "")
		t.color        = Color.html(str(d.get("color", "8c99d9")))
		for nd: Dictionary in d.get("nodes", []):
			t.nodes.append(UpgradeNode.from_dict(nd))
		if t.id.is_empty():
			push_error("UpgradeTree: a tree in %s is missing an 'id'" % path)
			continue
		if not _all.has(t.id):
			_order.append(t.id)
		_all[t.id] = t


static func get_tree_def(p_id: String) -> UpgradeTree:
	return _all.get(p_id, null)


# All trees in authoring (filename) order — the screen renders them as tabs in this order.
static func all() -> Array[UpgradeTree]:
	var out: Array[UpgradeTree] = []
	for tid: String in _order:
		out.append(_all[tid])
	return out
