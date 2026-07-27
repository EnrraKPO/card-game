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
#     header_actions: Array[{label: String, action: Callable, toggle: bool, pressed: bool,
#       tip: String}] (screen-scoped header buttons/toggles, sat left of the ⚙ — see
#       _apply_header_actions),
#     aid: String (the footer's text-aid line — "what do I do here?"; omitted/"" = no line.
#       Push later changes with Nav.set_aid, not a chrome re-read — see set_aid),
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
var _footer_aid: Label             # the footer's text-aid line — see set_aid
var _footer_custom: Array = []     # this screen's footer_actions nodes — the one per-mount exception

# Set to false (before adding Shell to the tree) to skip the real app's initial route — used by
# the render harness (dev/_render.gd), which mounts a specific scene itself instead.
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
	_footer_aid = fb.aid
	_footer_back = ScreenUI.back_button(Callable())
	_footer_hbox.add_child(_footer_back)
	# Back stays hard left; the aid takes the space after it, and `footer_actions` (appended later)
	# land to its right — so a screen using both reads Back · guidance · actions.
	_footer_hbox.move_child(_footer_back, 0)
	_footer_bar.visible = false
	_outer.add_child(_footer_bar)

	_wire_dev_toggles()
	(_header.gear as Button).pressed.connect(_open_settings)

	if auto_start:
		Nav.goto("res://scenes/entry_screen.tscn")


# ── The settings overlay (the header gear) ───────────────────────────────────────
# A Control overlay in the game's own art style — see SettingsOverlay.
func _open_settings() -> void:
	SettingsOverlay.open(self)


# The two placeholder mute/hide dev toggles live IN the header (built by ScreenUI.build_header,
# sat next to the ✕). Here we wire their behavior: each toggle's PRESSED state = the placeholder
# flag is ON (playing); OFF/unpressed = muted/hidden, the default. F7/F8 flip the same flags, and
# DevFlags.changed keeps the buttons in sync either way. Debug launches only (debug builds with
# debug mode on — DebugConfig / the local debug.json; placeholders are off in release
# regardless) — hidden otherwise.
var _dev_sfx_btn: GlossyButton
var _dev_vfx_btn: GlossyButton

func _wire_dev_toggles() -> void:
	_dev_sfx_btn = _header.dev_sfx
	_dev_vfx_btn = _header.dev_vfx
	if not OS.is_debug_build() or not DebugConfig.enabled():
		_dev_sfx_btn.visible = false
		_dev_vfx_btn.visible = false
		return
	_dev_sfx_btn.pressed.connect(_on_dev_sfx_toggled)
	_dev_vfx_btn.pressed.connect(_on_dev_vfx_toggled)
	DevFlags.changed.connect(_sync_dev_toggles)
	_sync_dev_toggles()


func _on_dev_sfx_toggled() -> void:
	# Pressed = placeholder SFX ON (playing); unpressed = muted.
	DevFlags.set_placeholder_sfx(_dev_sfx_btn.button_pressed)


func _on_dev_vfx_toggled() -> void:
	DevFlags.set_placeholder_vfx(_dev_vfx_btn.button_pressed)


func _sync_dev_toggles() -> void:
	_dev_sfx_btn.button_pressed = DevFlags.placeholder_sfx
	_dev_vfx_btn.button_pressed = DevFlags.placeholder_vfx
	_dev_sfx_btn.text = "DSFX:ON" if DevFlags.placeholder_sfx else "DSFX:OFF"
	_dev_vfx_btn.text = "DVFX:ON" if DevFlags.placeholder_vfx else "DVFX:OFF"


# Mounts the scene at `scene_path` as the current content and applies its declared chrome. Content
# itself is still swapped fresh each time (a genuinely different screen each navigation) — only the
# header/footer CHROME around it is persistent; see the header comment.
func mount(scene_path: String, arrival: String = "") -> void:
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

	var stage := _rebuild_lower(content, inset)
	_apply_header(def)
	_apply_footer(def)
	if content.has_method("on_chrome_applied"):
		content.on_chrome_applied({"fields": _header.refs, "close": _active_close(def)})
	_apply_back(def)

	_current_content = content
	# THE app-wide screen-transition cue: every navigation arrives through this one hook
	# (the entry carries the open sound) — no screen wires its own arrival. A caller that wants
	# a different entrance names it (Nav.goto's `arrival`); everything else gets the sweep.
	#
	# Played on the STAGE, not on `content`: an inset screen's content is a child of the margin
	# wrap, and Godot's Container.fit_child_in_rect resets a child's scale (and rotation) to
	# identity on EVERY layout pass — so a transform animation on it is silently erased frame by
	# frame while an alpha one survives. The stage is the outermost node in the content row and
	# is never a container child, so it can actually be transformed. Same rect either way, so
	# nothing else about a cue changes.
	Vfx.play(arrival if not arrival.is_empty() else "screen_transition_sweep", stage)


func _active_close(def: Dictionary) -> Button:
	return _header.debug_close if def.get("debug_close", false) else _header.close


# Content ALWAYS lives in `_lower_area`, its own row — the footer is a separate row, never nested
# in here. `inset` just decides whether content gets the shared side/top margin (menu screens) or
# fills its row edge-to-edge (HUD screens, or a screen with full-bleed background art that still
# wants the real footer below it).
#
# Returns the STAGE: the outermost node this put into the content row (the margin wrap, or the
# content itself). Whatever transforms the whole screen animates that, never the content inside
# a container — see the note at the arrival cue in mount().
func _rebuild_lower(content: Control, inset: bool) -> Control:
	if not inset:
		content.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		return content

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
	return wrap


# Re-reads the MOUNTED screen's chrome declaration and re-applies it, without remounting the screen
# or touching its body. For chrome that mirrors state the screen owns (a header toggle reflecting a
# persisted setting), this is how a change gets pushed: the screen keeps declaring its chrome from
# its own state in get_chrome(), and asks for a re-read — it never reaches into the header itself,
# which is the invariant the whole persistent-chrome design rests on.
func refresh_chrome() -> void:
	if _current_content == null or not _current_content.has_method("get_chrome"):
		return
	var def: Dictionary = _current_content.get_chrome()
	_apply_header(def)
	_apply_footer(def)


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

	_apply_header_actions(def.get("header_actions", []))

	var exit: Callable = def.get("exit", Callable())
	var debug: bool = def.get("debug_close", false)

	_rebind_button(_header.close, exit if exit.is_valid() and not debug else Callable())
	_header.close.visible = exit.is_valid() and not debug

	_rebind_button(_header.debug_close, exit if exit.is_valid() and debug else Callable())
	_header.debug_close.visible = exit.is_valid() and debug

	if exit.is_valid():
		Nav.set_back(exit)


# A screen's own header controls, built into the persistent actions box and cleared on the next
# mount — the header's counterpart to `footer_actions`, and legitimate for the same reason: there
# is no fixed catalog to pre-build when the labels are arbitrary. Kept deliberately small (a
# labelled button, optionally a toggle); anything richer belongs in the screen's own body, not in
# chrome every other screen shares.
#   { label: String, action: Callable, toggle: bool, pressed: bool, tip: String }
# A toggle's action receives the NEW state; a plain button's takes no argument. The action is
# invoked from the button press only — setting `pressed` never fires it, so a screen reflecting
# its own persisted state here can't loop.
func _apply_header_actions(actions: Array) -> void:
	var box: HBoxContainer = _header.actions
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()
	box.visible = not actions.is_empty()

	for a: Dictionary in actions:
		var is_toggle: bool = a.get("toggle", false)
		var on: bool = a.get("pressed", false)
		var action: Callable = a.get("action", Callable())
		var btn := ScreenUI.action_button(str(a.get("label", "")), Callable(),
			Vector2(0, ScreenUI.side_dev()), 20,
			ScreenUI.CHROME_CONFIRM if (is_toggle and on) else ScreenUI.CHROME_NEUTRAL)
		btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if str(a.get("tip", "")) != "":
			UIScale.tip(btn, str(a.get("tip", "")))
		if is_toggle:
			btn.toggle_mode = true
			btn.button_pressed = on
			# The chrome IS the state read — a toggle that only reported through its own pressed
			# styling would be indistinguishable from a plain button on this bar.
			btn.toggled.connect(func(pressed: bool) -> void:
				btn.base_color = ScreenUI.CHROME_CONFIRM if pressed else ScreenUI.CHROME_NEUTRAL
				if action.is_valid():
					action.call(pressed))
		elif action.is_valid():
			btn.pressed.connect(action)
		box.add_child(btn)


# Toggles the persistent footer for this screen. The standard Back button is a fixed piece like
# the header's — rebound, shown/hidden, never recreated. `footer_actions` is the one exception:
# genuinely custom, screen-specific buttons that don't belong to any shared catalog, so they're
# built fresh here and cleared by mount() next time (see header comment for why that's legitimate).
func _apply_footer(def: Dictionary) -> void:
	# Clear here, not only in mount(): refresh_chrome() re-applies without a remount, and custom
	# actions that only got cleared on navigation would stack up a duplicate set each refresh.
	for c in _footer_custom:
		c.queue_free()
	_footer_custom = []

	set_aid(str(def.get("aid", "")))

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


# THE text aid: the footer's guidance line. A screen declares its opening line via the `aid` chrome
# key and then pushes changes here (Nav.set_aid) as its state moves — this is deliberately NOT
# routed through refresh_chrome(), because guidance changes with every selection while a chrome
# re-read rebuilds header action buttons; a per-frame poll must be able to call this for free.
# Empty text hides the label outright, so it costs nothing on screens that never set one.
func set_aid(text: String) -> void:
	if _footer_aid.text == text:
		return
	_footer_aid.text = text
	_footer_aid.visible = text != ""


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
