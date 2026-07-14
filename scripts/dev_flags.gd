extends Node

# Development toggles that must survive restarts — currently the two PLACEHOLDER switches:
# whether placeholder SFX (synth blips for sound events without a real asset) and placeholder
# VFX (library entries not yet given a designed look) actually play. Both default ON — the
# placeholders exist to prove hookups — and can be muted at will when their noise gets in the
# way of judging the real content:
#
#   F7 toggles placeholder SFX          F8 toggles placeholder VFX
#
# Persisted to user://dev_flags.json. Consulted by Sfx (see Sfx.play/_placeholder path) and
# Vfx (see Vfx.play/attach) — the flags only gate PLACEHOLDERS; events with real assets or
# designed looks always play.

signal changed

const _PATH := "user://dev_flags.json"

var placeholder_sfx: bool = true
var placeholder_vfx: bool = true


func _ready() -> void:
	_load()


func _load() -> void:
	var f := FileAccess.open(_PATH, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK or not (json.data is Dictionary):
		return
	var d: Dictionary = json.data
	placeholder_sfx = bool(d.get("placeholder_sfx", true))
	placeholder_vfx = bool(d.get("placeholder_vfx", true))


func _save() -> void:
	var f := FileAccess.open(_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"placeholder_sfx": placeholder_sfx,
		"placeholder_vfx": placeholder_vfx,
	}))


func set_placeholder_sfx(on: bool) -> void:
	placeholder_sfx = on
	_save()
	changed.emit()


func set_placeholder_vfx(on: bool) -> void:
	placeholder_vfx = on
	_save()
	changed.emit()


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F7:
		set_placeholder_sfx(not placeholder_sfx)
		print("DevFlags: placeholder SFX ", "ON" if placeholder_sfx else "OFF")
	elif key.keycode == KEY_F8:
		set_placeholder_vfx(not placeholder_vfx)
		print("DevFlags: placeholder VFX ", "ON" if placeholder_vfx else "OFF")
