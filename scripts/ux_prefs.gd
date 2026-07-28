extends Node

# Player-facing UX preferences — interaction-feel choices the settings overlay exposes, the
# way AudioSettings owns the mixer. Persisted per device (user://), no shipped-defaults file:
# the code defaults ARE the shipped defaults, and the player's choices win over them.
#
# move_hold_enabled — the move button's safety hold (see MoveButton): ON means the button must
# be held while its progress fill completes before the move commits (release early to back
# out); OFF commits the instant it is pressed. Ships ON — the deliberate-confirm default that
# motivated bringing click-to-move back at all.

signal changed

const _USER_PATH := "user://ux_prefs.json"

var move_hold_enabled := true


func _ready() -> void:
	_load()


func set_move_hold(on: bool) -> void:
	if on == move_hold_enabled:
		return
	move_hold_enabled = on
	_save()
	changed.emit()


func _load() -> void:
	var f := FileAccess.open(_USER_PATH, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK or not (json.data is Dictionary):
		return
	var d: Dictionary = json.data
	move_hold_enabled = bool(d.get("move_hold_enabled", move_hold_enabled))


func _save() -> void:
	var f := FileAccess.open(_USER_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"move_hold_enabled": move_hold_enabled}))
