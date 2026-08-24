class_name DebugConfig
extends RefCounted

# The LOCAL launch config: whether this checkout launches in DEBUG MODE. Lives in
# debug.json at the project root — git-ignored and per-machine (never authored by the
# Tool, never shipped: it is export-excluded). Debug mode is ON by default: an absent or
# unreadable file means debug. Flip it off ({"enabled": false}) to preview the shipping
# experience; the file is seeded with its default on an editor launch when missing, so
# there is always a file to discover and edit.
#
# Consumers: EconomyConfig (the debug economy bag only applies in debug launches) and the
# map's Debug Items button. Gate any future dev-only surface on DebugConfig.enabled().

const PATH := "res://debug.json"

static var _enabled := true
static var _loaded := false
static var _override := -1   # test hook: -1 = none, 0 = forced off, 1 = forced on
static var _data: Dictionary = {}   # the parsed file, for the optional keys below


static func enabled() -> bool:
	if _override >= 0:
		return _override == 1
	if not _loaded:
		_load()
	return _enabled


# The fight seed this checkout forces ({"combat_seed": 12345}) — how a logged fight is
# REPLAYED: paste the seed from the log's header, relaunch, get the same fight (see
# the world's seeded rng). -1 = unset, the normal case: every fight rolls its own.
static func forced_seed() -> int:
	if not _loaded:
		_load()
	var v: Variant = _data.get("combat_seed", null)
	return int(v) if v is float or v is int else -1


static func _load() -> void:
	_loaded = true
	_enabled = true
	_data = {}
	if FileAccess.file_exists(PATH):
		var file := FileAccess.open(PATH, FileAccess.READ)
		var json := JSON.new()
		if file != null and json.parse(file.get_as_text()) == OK and json.data is Dictionary \
				and (json.data as Dictionary).get("enabled") is bool:
			_data = json.data as Dictionary
			_enabled = _data["enabled"]
		else:
			push_error("DebugConfig: bad debug.json — debug mode stays ON")
	elif OS.has_feature("editor"):
		# Seed the default file (dev checkouts only — an exported build can't write into
		# res:// and simply runs with the default).
		var out := FileAccess.open(PATH, FileAccess.WRITE)
		if out != null:
			out.store_string(JSON.stringify({"enabled": true}, "\t") + "\n")


# Test hooks: force debug mode regardless of the local file (the regression harness runs
# deterministically under set_override(true)); clear_override returns to the disk value.
static func set_override(v: bool) -> void:
	_override = 1 if v else 0


static func clear_override() -> void:
	_override = -1
