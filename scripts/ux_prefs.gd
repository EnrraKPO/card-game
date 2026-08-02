extends Node

# Player-facing UX preferences — interaction-feel choices the settings overlay exposes, the
# way AudioSettings owns the mixer. Persisted per device (user://), no shipped-defaults file:
# the code defaults ARE the shipped defaults, and the player's choices win over them.
#
# move_hold_enabled — the move button's safety hold (see MoveButton): ON means the button must
# be held while its progress fill completes before the move commits (release early to back
# out); OFF commits the instant it is pressed. Ships ON — the deliberate-confirm default that
# motivated bringing click-to-move back at all.
#
# tooltip_delay — seconds the pointer must rest on a card before its details panel opens (see
# CardHoverPanel). UNSET (-1) means "follow the game's own tuning" — the ux.tooltip.delay game
# attribute — rather than a number frozen at whatever shipped the day the player first looked at
# this screen. Only an explicit choice overrides it, which is what makes retuning still reach
# everyone who has no opinion. Same shape as Vfx's overlap preference.

signal changed

const _USER_PATH := "user://ux_prefs.json"

# What the settings slider may pick between, in seconds. The ceiling is a deliberate stop: past
# about a second a hover panel stops feeling slow and starts feeling broken.
const TOOLTIP_DELAY_MAX := 1.5

var move_hold_enabled := true
var tooltip_delay := -1.0   # < 0 = unset, follow ux.tooltip.delay


func _ready() -> void:
	_load()


func set_move_hold(on: bool) -> void:
	if on == move_hold_enabled:
		return
	move_hold_enabled = on
	_save()
	changed.emit()


# Seconds, or negative to hand the decision back to the game's tuning (see the note up top).
func set_tooltip_delay(seconds: float) -> void:
	var v := -1.0 if seconds < 0.0 else clampf(seconds, 0.0, TOOLTIP_DELAY_MAX)
	if is_equal_approx(v, tooltip_delay):
		return
	tooltip_delay = v
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
	tooltip_delay = float(d.get("tooltip_delay", tooltip_delay))


func _save() -> void:
	var f := FileAccess.open(_USER_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"move_hold_enabled": move_hold_enabled,
		"tooltip_delay": tooltip_delay,
	}))
