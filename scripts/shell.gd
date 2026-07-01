extends Control

# THE persistent app shell (main_scene). Owns chrome — background, header, footer — as ONE
# instance that never gets destroyed or re-embedded, so the header sits in exactly the same place
# for every screen by construction (see [[header-system]] memory for why the old per-screen
# scaffold()/header_bar() split couldn't guarantee that). Screens are no longer independent scenes
# swapped via change_scene_to_file (that would destroy the Shell); they're content mounted into
# `_lower_area` via Nav.goto(), and declare their chrome via an optional `get_chrome() -> Dictionary`
# method read AFTER the content is added to the tree (so its own _ready() has already run):
#   { title: String, fields: Array[ScreenUI.Field] (omitted = just EXP, the menu convention; [] = none),
#     exit: Callable, back: Variant ("same" | Callable — OS-back routing, defaults to `exit`),
#     show_footer: bool (menu-style chrome: inset body + footer Back button; false = full-bleed
#       HUD body, no footer — map/combat/headerless screens),
#     debug_close: bool (combat's orange debug ✕) }
# No get_chrome() (or an empty dict) collapses the header entirely — the body takes the full rect.
# A screen that needs a live handle on a header field (Shop refreshing GOLD, combat's RelicTray)
# implements `on_chrome_applied(handles: Dictionary)` — handles = header_bar()'s {fields, close}.

var _outer: VBoxContainer
var _header_bar: Control = null   # the live header_bar() PanelContainer, a direct VBox row
var _lower_area: Control
var _current_content: Control = null
var _last_handles: Dictionary = {}

# Set to false (before adding Shell to the tree) to skip the real app's initial route — used by
# the render harness (_render.gd), which mounts a specific scene itself instead.
var auto_start := true

const DEBUG_CLOSE_COLOR := Color(1.0, 0.55, 0.2)


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Nav.register_shell(self)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = ScreenUI.BG_COLOR
	add_child(bg)

	_outer = VBoxContainer.new()
	_outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_outer.add_theme_constant_override("separation", 0)
	add_child(_outer)

	_lower_area = Control.new()
	_lower_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_outer.add_child(_lower_area)

	if auto_start:
		Nav.goto("res://scenes/entry_screen.tscn")


# Tears down the current content + chrome and mounts the scene at `scene_path` in its place.
func mount(scene_path: String) -> void:
	if _current_content != null:
		_current_content.queue_free()
		_current_content = null
	for c in _lower_area.get_children():
		c.queue_free()

	var content: Control = load(scene_path).instantiate()
	_lower_area.add_child(content)   # in the tree now — content's own _ready() has run
	var def: Dictionary = content.get_chrome() if content.has_method("get_chrome") else {}

	_rebuild_lower(def, content)
	_apply_header(def)
	if content.has_method("on_chrome_applied"):
		content.on_chrome_applied(_last_handles)
	_apply_back(def)

	_current_content = content


# Menu-style chrome (show_footer) wraps content in the shared inset margin + a footer Back button;
# HUD-style chrome (map/combat/headerless) leaves content full-bleed directly under the header.
func _rebuild_lower(def: Dictionary, content: Control) -> void:
	if not def.get("show_footer", false):
		content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		return

	_lower_area.remove_child(content)
	var margin := int(UIScale.safe_inset() + 36.0)

	var wrap := MarginContainer.new()
	wrap.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wrap.add_theme_constant_override("margin_left", margin)
	wrap.add_theme_constant_override("margin_right", margin)
	wrap.add_theme_constant_override("margin_top", 24)
	wrap.add_theme_constant_override("margin_bottom", margin)
	_lower_area.add_child(wrap)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 24)
	wrap.add_child(vbox)

	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(content)

	var footer := PanelContainer.new()
	vbox.add_child(footer)
	var footer_pad := MarginContainer.new()
	footer_pad.add_theme_constant_override("margin_left", 8)
	footer.add_child(footer_pad)
	var footer_hbox := HBoxContainer.new()
	footer_pad.add_child(footer_hbox)
	var exit: Callable = def.get("exit", Callable())
	if exit.is_valid():
		footer_hbox.add_child(ScreenUI.back_button(exit))


func _apply_header(def: Dictionary) -> void:
	if _header_bar != null:
		_header_bar.queue_free()
		_header_bar = null
	var show_header: bool = def.get("show_header", not def.is_empty())
	if not show_header:
		_last_handles = {}
		return

	# A screen that omits "fields" entirely gets the menu-screen convention (just EXP) — the same
	# default the old scaffold() always applied. Passing an explicit [] shows none.
	var hb := ScreenUI.header_bar(def.get("exit", Callable()),
		{"name": def.get("title", ""), "fields": def.get("fields", [ScreenUI.Field.EXP])})
	if def.get("debug_close", false) and hb.close != null:
		hb.close.modulate = DEBUG_CLOSE_COLOR
		hb.close.tooltip_text = "Debug: end combat"
	_header_bar = hb.bar
	_outer.add_child(_header_bar)
	_outer.move_child(_header_bar, 0)   # always the top row, ahead of _lower_area
	_last_handles = {"fields": hb.fields, "close": hb.close}


# header_bar() already wired Nav.set_back(exit) when exit is valid (see _apply_header) — this only
# overrides that when a screen's OS-back behavior needs to differ from its ✕ (combat: `exit` drives
# a debug-only ✕, but the OS-back gesture must stay inert, so it passes back=Callable()).
func _apply_back(def: Dictionary) -> void:
	var back = def.get("back", "same")
	if back is String:
		return
	if back is Callable:
		if back.is_valid():
			Nav.set_back(back)
		else:
			Nav.clear_back()
