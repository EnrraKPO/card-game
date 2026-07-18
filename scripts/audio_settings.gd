extends Node

# The player-facing AUDIO SETTINGS layer — two mixer channels (Music and SFX) the settings
# dialog exposes as mute + volume slider each. Owns the "Music"/"SFX" audio buses (created
# here at startup; Sfx routes every player onto one of them — the music+ambience beds onto
# Music, everything else onto SFX).
#
# Slider model: percent 0..1, anchored so UNITY_PCT plays exactly as-authored (0 dB) and
# 1.0 is a slight boost above it — "100% is actually 100%", with the shipped default sitting
# below it. DEFAULTS are game data (data/audio.json, tool-tunable in the Tool's 🔊 Audio
# panel); the player's own choices persist to user://audio_settings.json and win over
# defaults. Mutes are always the player's (they default off, never shipped).

signal changed

const _USER_PATH := "user://audio_settings.json"
const _DEFAULTS_PATH := "res://data/audio.json"
# The slider position that equals as-authored loudness: 0.8 → 0 dB, 1.0 → ~+2 dB boost.
const UNITY_PCT := 0.8
const _BUS_OF := {"music": "Music", "sfx": "SFX"}

var volumes := {"music": 0.5, "sfx": 0.8}
var mutes := {"music": false, "sfx": false}


func _ready() -> void:
	# The buses are DEFINED in default_bus_layout.tres — web exports silently ignore buses
	# created at runtime (Godot bug, all audio routed to them is dead in the browser). This
	# loop is only a fallback guard for contexts that skip the default layout, keeping the
	# render harness and headless tests safe. Must precede Sfx's player creation in autoload
	# order (players name their bus at construction).
	for bus_name: String in _BUS_OF.values():
		if AudioServer.get_bus_index(bus_name) == -1:
			var idx := AudioServer.bus_count
			AudioServer.add_bus(idx)
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")
	_load_json(_DEFAULTS_PATH, false)
	_load_json(_USER_PATH, true)
	_apply()


func volume(kind: String) -> float:
	return float(volumes.get(kind, 1.0))


func muted(kind: String) -> bool:
	return bool(mutes.get(kind, false))


func set_volume(kind: String, pct: float) -> void:
	if not volumes.has(kind):
		return
	volumes[kind] = clampf(pct, 0.0, 1.0)
	_apply()
	_save()
	changed.emit()


func set_muted(kind: String, on: bool) -> void:
	if not mutes.has(kind):
		return
	mutes[kind] = on
	_apply()
	_save()
	changed.emit()


func _apply() -> void:
	for kind: String in _BUS_OF:
		var idx := AudioServer.get_bus_index(_BUS_OF[kind])
		if idx == -1:
			continue
		AudioServer.set_bus_mute(idx, bool(mutes[kind]))
		var pct := float(volumes[kind])
		# Slider 0 is genuine silence, not "-∞ approached from a log curve".
		var db := linear_to_db(pct / UNITY_PCT) if pct > 0.0 else -80.0
		AudioServer.set_bus_volume_db(idx, db)


# `user_prefs` distinguishes the two sources: defaults ship volumes only; the user file
# carries the player's volumes AND mutes.
func _load_json(path: String, user_prefs: bool) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK or not (json.data is Dictionary):
		return
	var d: Dictionary = json.data
	for kind: String in volumes:
		var key := kind + "_volume"
		if d.has(key):
			volumes[kind] = clampf(float(d[key]), 0.0, 1.0)
	if user_prefs:
		for kind: String in mutes:
			mutes[kind] = bool(d.get(kind + "_muted", mutes[kind]))


func _save() -> void:
	var f := FileAccess.open(_USER_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"music_volume": volumes["music"], "sfx_volume": volumes["sfx"],
		"music_muted": mutes["music"], "sfx_muted": mutes["sfx"],
	}))
