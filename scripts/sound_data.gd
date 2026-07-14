class_name SoundData
extends RefCounted

# One entry per SOUND EVENT the game will ever make — the data half of the SFX pipeline.
# The library is deliberately exhaustive: every eventual sound already has a definition here,
# playable TODAY through Sfx (a missing asset plays a procedural placeholder — see Sfx._placeholder),
# so hooking a new game moment is always a one-liner against an id that already exists.
#
# Each entry carries authoring METADATA alongside playback config: `concept` records the design
# intent (what the moment is and how it should feel), `prompt` is ready-to-use text for AI sound
# generation. Both are managed in the Tool's Sounds tab. Data-driven from data/sounds/*.json,
# same registry pattern as RelicData/StatusData.

var id: String
var display_name: String
var category: String = "ui"     # ui|card|combat|magic|resource|map|economy|lab|meta|ambient|music
var concept: String = ""        # design intent — what this moment is, how it should feel
var prompt: String = ""         # AI sound-generation prompt for producing the real asset
var file: String = ""           # filename inside assets/sound/ — empty = placeholder synth
var volume_db: float = 0.0      # per-moment loudness trim (0 = as authored, negative = gentler)
var loop: bool = false          # looped bed (drones/ambience/music) vs one-shot

static var _all: Dictionary = {}


static func _static_init() -> void:
	var dir := DirAccess.open("res://data/sounds/")
	if dir == null:
		return   # sounds are optional content; an absent folder is fine
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/sounds/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		push_error("SoundData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = json.data if json.data is Array else [json.data]
	for d: Dictionary in entries:
		if not bool(d.get("enabled", true)):
			continue
		var s := SoundData.new()
		s.id           = d.get("id", "")
		s.display_name = d.get("display_name", "")
		s.category     = d.get("category", "ui")
		s.concept      = d.get("concept", "")
		s.prompt       = d.get("prompt", "")
		s.file         = d.get("file", "")
		s.volume_db    = float(d.get("volume_db", 0.0))
		s.loop         = bool(d.get("loop", false))
		if not s.id.is_empty():
			_all[s.id] = s


static func get_sound(p_id: String) -> SoundData:
	return _all.get(p_id, null)


static func all() -> Array:
	return _all.values()


# Whether this event has a real authored asset on disk (vs the placeholder synth).
func has_asset() -> bool:
	return not file.is_empty() and ResourceLoader.exists("res://assets/sound/" + file)


func stream() -> AudioStream:
	if not has_asset():
		return null
	return load("res://assets/sound/" + file)
