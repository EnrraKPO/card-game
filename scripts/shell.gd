extends Control

# THE persistent app shell (main_scene). Owns chrome — background, header, footer — as ONE
# instance that never gets destroyed or re-embedded (see [[header-system]] memory for why the old
# per-screen scaffold()/header_bar() split couldn't guarantee that). Screens are no longer
# independent scenes swapped via change_scene_to_file; they're content mounted into `_lower_area`
# via Nav.goto(), and declare their chrome via an optional `get_chrome() -> Dictionary` method read
# AFTER the content is added to the tree (so its own _ready() has already run):
#   { title: String, fields: Array[ScreenUI.Field] (omitted = just EXP, the menu convention; [] = none),
#     exit: Callable, back: Variant ("same" | Callable — OS-back routing, defaults to `exit`),
#     show_footer: bool, inset: bool (whether CONTENT gets the shared side/top margin — defaults to
#       show_footer's value; override for a screen that wants full-bleed content but still needs
#       the footer, e.g. Lab/Map set inset: false alongside show_footer: true),
#     footer_actions: Array[{label: String, action: Callable, align: "left"|"right"}] (custom
#       footer buttons, in order; omitted + a valid `exit` = the standard single Back button;
#       "right"-aligned entries float to the far side via one shared spacer),
#     debug_close: bool (combat's orange debug ✕ instead of the normal one) }
# No get_chrome() (or an empty dict) collapses the header entirely — the body takes the full rect.
#
# THE HEADER AND FOOTER ARE GENUINELY PERSISTENT — not just the Shell node, the header/footer bars
# themselves. ScreenUI.build_header() constructs every piece the header can ever show (title, the 5
# catalog fields, the normal ✕, the debug ✕) exactly ONCE, in _ready(). Navigating between screens
# never destroys or recreates any of that; it only toggles which pieces are visible right now
# (_apply_header) and rebinds what a button does when clicked (_rebind_button) — the button node
# itself, its styling, its position never change. Two separate close buttons exist so neither one's
# appearance/behavior ever branches per screen (a screen picks which of the two to show; the normal
# ✕ never mutates). The footer's standard Back button gets the identical treatment. The ONE
# legitimate exception is a screen's `footer_actions` — genuinely one-off buttons with arbitrary
# labels that don't belong to any fixed catalog (Map's Save & Quit / Debug Items, the save-picker's
# Reset profile) — those are the only pieces created/cleared per mount, because there's nothing to
# pre-build for an unbounded set of custom labels.
#
# STRUCTURE: header, content (_lower_area), and footer are three fixed sibling rows in `_outer`,
# added once in _ready() and never reordered or removed — a screen's content occupies only its own
# row (optionally inset-margined), never the header or footer, so overlap is structurally
# impossible and there is exactly one instance of each row for the whole app session.
#
# Header fields update themselves live via the GameSignals bus (see [[header-system]]) while
# visible. A screen that needs a live handle on a field's widget (combat's RelicTray, for .glint())
# implements `on_chrome_applied(handles: Dictionary)` — handles = {fields: ScreenUI.build_header()'s
# `refs`, close: whichever close button is currently active}.

var _outer: VBoxContainer
var _lower_area: Control
var _current_content: Control = null

var _header: Dictionary = {}   # ScreenUI.build_header()'s return — built once, see _ready()
var _footer_bar: PanelContainer
var _footer_hbox: HBoxContainer
var _footer_back: Button           # the ONE persistent Back button — see header comment
var _footer_custom: Array = []     # this screen's footer_actions nodes — the one per-mount exception

# Set to false (before adding Shell to the tree) to skip the real app's initial route — used by
# the render harness (_render.gd), which mounts a specific scene itself instead.
var auto_start := true


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

	_header = ScreenUI.build_header()
	_header.bar.visible = false
	_outer.add_child(_header.bar)

	_lower_area = Control.new()
	_lower_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_outer.add_child(_lower_area)

	var fb := ScreenUI.footer_bar()
	_footer_bar = fb.bar
	_footer_hbox = fb.hbox
	_footer_back = ScreenUI.back_button(Callable())
	_footer_hbox.add_child(_footer_back)
	_footer_bar.visible = false
	_outer.add_child(_footer_bar)

	if auto_start:
		Nav.goto("res://scenes/entry_screen.tscn")


# Mounts the scene at `scene_path` as the current content and applies its declared chrome. Content
# itself is still swapped fresh each time (a genuinely different screen each navigation) — only the
# header/footer CHROME around it is persistent; see the header comment.
func mount(scene_path: String) -> void:
	if _current_content != null:
		_current_content.queue_free()
		_current_content = null
	for c in _lower_area.get_children():
		c.queue_free()
	for c in _footer_custom:
		c.queue_free()
	_footer_custom = []

	var content: Control = load(scene_path).instantiate()
	_lower_area.add_child(content)   # in the tree now — content's own _ready() has run
	var def: Dictionary = content.get_chrome() if content.has_method("get_chrome") else {}
	var inset: bool = def.get("inset", def.get("show_footer", false))

	_rebuild_lower(content, inset)
	_apply_header(def)
	_apply_footer(def)
	if content.has_method("on_chrome_applied"):
		content.on_chrome_applied({"fields": _header.refs, "close": _active_close(def)})
	_apply_back(def)

	_current_content = content


func _active_close(def: Dictionary) -> Button:
	return _header.debug_close if def.get("debug_close", false) else _header.close


# Content ALWAYS lives in `_lower_area`, its own row — the footer is a separate row, never nested
# in here. `inset` just decides whether content gets the shared side/top margin (menu screens) or
# fills its row edge-to-edge (HUD screens, or a screen with full-bleed background art that still
# wants the real footer below it).
func _rebuild_lower(content: Control, inset: bool) -> void:
	if not inset:
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

	content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	wrap.add_child(content)


# Toggles the persistent header's pieces for this screen — nothing here is ever created or freed.
func _apply_header(def: Dictionary) -> void:
	var show_header: bool = def.get("show_header", not def.is_empty())
	_header.bar.visible = show_header
	if not show_header:
		return

	_header.title.text = def.get("title", "")
	_header.title.visible = _header.title.text != ""

	# RelicTray.interactive defaults back to true here, every mount, WITH a rebuild — the RelicTray
	# is now the same persistent instance for every screen, so combat setting it read-only
	# (on_chrome_applied, AFTER this runs) would otherwise leak into whatever screen comes after
	# combat. refresh() must run even when RELICS was already visible on both screens (no
	# hidden→visible transition to trigger sync_field below) — interactive is baked into each
	# chip's tooltip/click-binding at refresh() time, so just flipping the flag isn't enough.
	var relic_tray: RelicTray = _header.refs[ScreenUI.Field.RELICS]
	relic_tray.interactive = true
	relic_tray.refresh()

	# A screen that omits "fields" entirely gets the menu-screen convention (just EXP) — the same
	# default the old scaffold() always applied. Passing an explicit [] shows none.
	var wanted: Array = def.get("fields", [ScreenUI.Field.EXP])
	for key in _header.fields:
		var w: Control = _header.fields[key]
		var show: bool = key in wanted
		if show and not w.visible:
			ScreenUI.sync_field(key, w)   # pull current data the moment it becomes visible
		w.visible = show

	var exit: Callable = def.get("exit", Callable())
	var debug: bool = def.get("debug_close", false)

	_rebind_button(_header.close, exit if exit.is_valid() and not debug else Callable())
	_header.close.visible = exit.is_valid() and not debug

	_rebind_button(_header.debug_close, exit if exit.is_valid() and debug else Callable())
	_header.debug_close.visible = exit.is_valid() and debug

	if exit.is_valid():
		Nav.set_back(exit)


# Toggles the persistent footer for this screen. The standard Back button is a fixed piece like
# the header's — rebound, shown/hidden, never recreated. `footer_actions` is the one exception:
# genuinely custom, screen-specific buttons that don't belong to any shared catalog, so they're
# built fresh here and cleared by mount() next time (see header comment for why that's legitimate).
func _apply_footer(def: Dictionary) -> void:
	var show_footer: bool = def.get("show_footer", false)
	_footer_bar.visible = show_footer
	if not show_footer:
		return

	var actions: Array = def.get("footer_actions", [])
	if actions.is_empty():
		var exit: Callable = def.get("exit", Callable())
		_rebind_button(_footer_back, exit)
		_footer_back.visible = exit.is_valid()
		return

	_footer_back.visible = false   # custom actions replace the standard Back for this screen
	var spacer_added := false
	for a: Dictionary in actions:
		if a.get("align", "left") == "right" and not spacer_added:
			var spacer := Control.new()
			spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_footer_hbox.add_child(spacer)
			_footer_custom.append(spacer)
			spacer_added = true
		var btn := ScreenUI.footer_button(a.get("label", ""), a.get("action", Callable()))
		_footer_hbox.add_child(btn)
		_footer_custom.append(btn)


# Rebinds a persistent button's click target without recreating it — disconnects whatever it was
# last bound to (tracked via metadata, since a fresh Callable() each mount isn't ==-comparable to
# the old one otherwise), then connects the new action if valid. Used for both header close buttons
# and the footer's Back button — every persistent, rebindable piece goes through this one function.
func _rebind_button(btn: Button, action: Callable) -> void:
	var prev: Callable = btn.get_meta("bound_action", Callable())
	if prev.is_valid() and btn.pressed.is_connected(prev):
		btn.pressed.disconnect(prev)
	if action.is_valid():
		btn.pressed.connect(action)
	btn.set_meta("bound_action", action)


# The active close button already wired Nav.set_back(exit) when exit is valid (see _apply_header) —
# this only overrides that when a screen's OS-back behavior needs to differ from its ✕ (combat:
# `exit` drives a debug-only ✕, but the OS-back gesture must stay inert, so it passes back=Callable()).
func _apply_back(def: Dictionary) -> void:
	var back = def.get("back", "same")
	if back is String:
		return
	if back is Callable:
		if back.is_valid():
			Nav.set_back(back)
		else:
			Nav.clear_back()
