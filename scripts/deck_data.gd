class_name DeckData
extends RefCounted

const FALLBACK_ID := "starter"

static var _all: Dictionary = {}  # id -> Array[String] (card ids)


static func _static_init() -> void:
	var dir := DirAccess.open("res://data/decks/")
	if dir == null:
		push_error("DeckData: cannot open res://data/decks/")
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/decks/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("DeckData: cannot open " + path)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("DeckData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = []
	if json.data is Array:
		entries = json.data
	else:
		entries = [json.data]
	for d: Dictionary in entries:
		var id: String = d.get("id", "")
		if id.is_empty():
			push_error("DeckData: deck in %s is missing an 'id'" % path)
			continue
		_all[id] = Array(d.get("cards", []), TYPE_STRING, "", null)


# Returns a fresh copy of the named deck's card-id list. Falls back to an
# empty deck (with an error logged) if the id isn't found, so a missing/typo'd
# file fails loudly instead of silently giving the player no cards at all.
static func get_deck(id: String) -> Array:
	if not _all.has(id):
		push_error("DeckData: unknown deck id '%s'" % id)
		return []
	return _all[id].duplicate()
