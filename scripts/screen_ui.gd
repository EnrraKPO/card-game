class_name ScreenUI
extends RefCounted

# Shared header-chrome building blocks, owned and called by the persistent Shell (scripts/shell.gd)
# — NOT by individual screens. Screens are content mounted into the Shell's body; they declare their
# chrome via an optional `get_chrome() -> Dictionary` method (title/fields/exit/etc — see shell.gd's
# header comment for the schema) instead of building header nodes themselves. The header NEVER hosts
# screen-specific content (buttons, filters, counts) — those belong in a toolbar row inside the
# screen's own body content, same as any other body content.

const BG_COLOR := Color(0.07, 0.07, 0.12)
const CLOSE_GLYPH := "✕"

# THE bar height — header and footer are the same fixed row height, everywhere, always. Both
# build_header() and footer_bar() size themselves off this one pair of numbers. Includes BAR_V_PAD
# of breathing room above/below the buttons on top of their own fixed BUTTON_HEIGHT, so a button
# never looks compressed flush against the bar's edge.
const BAR_V_PAD := 6.0
const BUTTON_HEIGHT := 52.0
const BUTTON_HEIGHT_COMPACT := 88.0
const BAR_HEIGHT := BUTTON_HEIGHT + BAR_V_PAD * 2.0
const BAR_HEIGHT_COMPACT := BUTTON_HEIGHT_COMPACT + BAR_V_PAD * 2.0

# The fixed catalog of run-status fields any header can show. A screen names the keys it wants
# (in a header_bar definition); each field pulls its OWN data from the single canonical source
# (GameData.current_run / current_profile), so a screen never passes a value in and the same fact
# always renders identically everywhere. Turn/Mana are deliberately NOT here — they're combat
# gameplay state, not run status, and live in combat's own HUD.
enum Field { ACT, HP, GOLD, RELICS, EXP }

# WHERE each field sits is a property of the catalog, NOT of any screen — so the same field always
# lands in the same place, in the same order, in every header. A screen only chooses WHICH fields to
# show; these two ordered lists decide the rest (left cluster · flexible gap · right cluster · ✕).
const _LEFT_FIELDS := [Field.ACT, Field.HP, Field.GOLD, Field.RELICS]
const _RIGHT_FIELDS := [Field.EXP]


# THE header surface — a clearly distinct bar (lighter than the screen, with a thin accent underline)
# so a header always reads as a bar and its ✕ sits inside it rather than floating. Shared by every
# header (scaffold's menu header + header_bar's HUD header) so they're identical.
static func _header_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.13, 0.19)
	sb.border_width_bottom = 2
	sb.border_color = Color(0.30, 0.33, 0.44)
	return sb


# THE footer surface — same bg/accent treatment as the header (see _header_stylebox), just with
# the accent line on the TOP edge instead of the bottom (the edge facing the content either bar
# borders), so the footer reads as a matching bar of its own instead of fading into the page
# behind it under the default flat Panel style.
static func _footer_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.13, 0.19)
	sb.border_width_top = 2
	sb.border_color = Color(0.30, 0.33, 0.44)
	return sb


# A profile experience bar: progress toward the next upgrade point + the spendable balance.
# Reused by the hub and the Upgrades screen. Reads the given profile's experience snapshot.
static func experience_bar(profile: ProfileData, compact: bool = false) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)

	var pts := profile.upgrade_points
	var header := Label.new()
	header.text = "Experience   ·   %d upgrade point%s" % [pts, "" if pts == 1 else "s"]
	header.add_theme_font_size_override("font_size", 20 if compact else 15)
	box.add_child(header)

	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = ProfileData.EXP_PER_UPGRADE_POINT
	bar.value = profile.experience
	bar.show_percentage = false
	bar.custom_minimum_size.y = 22.0 if compact else 16.0
	box.add_child(bar)

	var sub := Label.new()
	sub.text = "%d / %d to next point" % [profile.experience, ProfileData.EXP_PER_UPGRADE_POINT]
	sub.add_theme_font_size_override("font_size", 14 if compact else 11)
	sub.modulate = Color(0.7, 0.7, 0.75)
	box.add_child(sub)
	return box


# A single-row experience widget for a header bar: an "EXP" tag + a clearly-styled progress bar
# (reads as a bar — coloured fill on a dark track) + a subtle gold pip when upgrade points are
# banked (the hint that there's something to spend at the hub; the exact count lives on the
# Upgrades screen, not here). `expand` makes the whole widget (and its bar) fill available width —
# used as the header's flexible element that soaks up space freed when other content is hidden.
# A static snapshot (experience only changes between screens). See experience_bar.
static func experience_bar_compact(profile: ProfileData, compact: bool = false, expand: bool = false) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if expand:
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var pts := profile.upgrade_points
	var tip := "Experience — %d / %d to the next upgrade point" % [profile.experience, ProfileData.EXP_PER_UPGRADE_POINT]
	if pts > 0:
		tip += "\n%d upgrade point%s available — spend them at the hub." % [pts, "" if pts == 1 else "s"]
	row.tooltip_text = tip

	var tag := Label.new()
	tag.text = "EXP"
	tag.add_theme_font_size_override("font_size", 18 if compact else 15)
	tag.modulate = Color(0.72, 0.74, 0.82)
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(tag)

	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = ProfileData.EXP_PER_UPGRADE_POINT
	bar.value = profile.experience
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0.0 if expand else (240.0 if compact else 180.0), 20.0 if compact else 16.0)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if expand:
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Style it so it unmistakably reads as a progress bar: coloured fill on a dark rounded track.
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.05, 0.05, 0.09)
	track.set_corner_radius_all(6)
	track.set_border_width_all(1)
	track.border_color = Color(0.30, 0.32, 0.42)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.42, 0.72, 0.98)
	fill.set_corner_radius_all(6)
	bar.add_theme_stylebox_override("background", track)
	bar.add_theme_stylebox_override("fill", fill)
	row.add_child(bar)

	# Minor "you have upgrade points" nudge — a gold pip, details in the tooltip.
	if pts > 0:
		var pip := Label.new()
		pip.text = "●"
		pip.add_theme_font_size_override("font_size", 18 if compact else 14)
		pip.add_theme_color_override("font_color", Color(0.95, 0.84, 0.34))
		pip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		pip.tooltip_text = tip
		row.add_child(pip)
	return row


# THE header — built ONCE by Shell (shell.gd's _ready(), never again). Every piece it can ever
# show (title, the 5 catalog fields, the normal ✕, the debug ✕) is constructed here, up front, and
# lives for the whole app session. Nothing about the header is ever destroyed or rebuilt when you
# navigate between screens — a screen only toggles which of these fixed pieces are visible right
# now (Shell._apply_header does the toggling, reading a screen's get_chrome()). Two separate close
# buttons exist so neither one's styling/behavior ever has to branch per screen — a screen picks
# which of the two to show, the normal ✕ never changes.
# Returns { bar, title, fields: {Field -> Control}, refs: {Field -> Control}, close, debug_close }.
# `fields[key]` is the widget Shell shows/hides; `refs[key]` is the live handle a screen may want
# (e.g. RELICS's raw RelicTray, for combat's .glint()) — see on_chrome_applied users.
static func build_header() -> Dictionary:
	var compact := UIScale.is_compact()
	var bar := PanelContainer.new()
	bar.custom_minimum_size.y = BAR_HEIGHT_COMPACT if compact else BAR_HEIGHT
	bar.add_theme_stylebox_override("panel", _header_stylebox())

	var pad := MarginContainer.new()
	var inset := int(UIScale.safe_inset() + 8.0)   # keep content out of the touch-hostile edge
	pad.add_theme_constant_override("margin_left", inset)
	pad.add_theme_constant_override("margin_right", inset)
	pad.add_theme_constant_override("margin_top", int(BAR_V_PAD))
	pad.add_theme_constant_override("margin_bottom", int(BAR_V_PAD))
	bar.add_child(pad)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16 if compact else 12)
	pad.add_child(row)

	var title_lbl := Label.new()
	title_lbl.add_theme_font_size_override("font_size", 34 if compact else 22)
	title_lbl.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0))
	title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title_lbl.visible = false
	row.add_child(title_lbl)

	var fields := {}
	var refs := {}
	for key in _LEFT_FIELDS:
		var built := _build_field(key)
		built.widget.visible = false   # starts hidden — Shell's first _apply_header call is what
		                                 # detects "just became visible" and pulls real data in
		fields[key] = built.widget
		refs[key] = built.ref
		row.add_child(built.widget)

	# The open middle: the last left field grows into it, so newly-earned content (e.g. relics)
	# expands rightward rather than the header staying half-empty.
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)

	for key in _RIGHT_FIELDS:
		var built := _build_field(key)
		built.widget.visible = false
		fields[key] = built.widget
		refs[key] = built.ref
		row.add_child(built.widget)

	var close := close_button(Callable())
	close.visible = false
	row.add_child(close)

	var debug_close := close_button(Callable())
	debug_close.modulate = Color(1.0, 0.55, 0.2)
	debug_close.tooltip_text = "Debug: end combat"
	debug_close.visible = false
	row.add_child(debug_close)

	return {"bar": bar, "title": title_lbl, "fields": fields, "refs": refs,
		"close": close, "debug_close": debug_close}


# The catalog builder: constructs ONE Field's widget, once, unconditionally (never returns null —
# unlike the old per-mount version, there's no "skip if no run yet" case, because this widget will
# sit hidden until a screen actually wants it shown; see sync_field for what fills it with real
# data at that point). Connects GameSignals immediately so it stays live thereafter regardless of
# visibility. Returns {widget, ref}: `widget` is what Shell shows/hides; `ref` is the live handle a
# screen may want (RELICS' raw RelicTray) — for every other field ref == widget.
static func _build_field(key: int) -> Dictionary:
	var compact := UIScale.is_compact()
	match key:
		Field.ACT:
			# The prominent run label (not a chip) — reads as the header's headline, per the map look.
			var act := Label.new()
			act.add_theme_font_size_override("font_size", 34 if compact else 22)
			act.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0))
			act.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			GameSignals.act_changed.connect(func(a: int) -> void: act.text = "Act %d" % a)
			return {"widget": act, "ref": act}
		Field.HP:
			var hp := stat("HP", "", Color(0.62, 0.9, 0.66))
			GameSignals.hp_changed.connect(func(cur: int, mx: int) -> void: _refresh_stat(hp, "%d / %d" % [cur, mx]))
			return {"widget": hp, "ref": hp}
		Field.GOLD:
			var gold := stat("Gold", "", Color(0.98, 0.85, 0.35))
			GameSignals.gold_changed.connect(func(v: int) -> void: _refresh_stat(gold, str(v)))
			return {"widget": gold, "ref": gold}
		Field.RELICS:
			var tray := RelicTray.new()
			GameSignals.relics_changed.connect(tray.refresh)   # full rebuild — tray already does this
			return {"widget": header_chip(tray), "ref": tray}
		Field.EXP:
			var chip := header_chip(Control.new())
			GameSignals.exp_changed.connect(func() -> void: _refresh_exp_chip(chip))
			return {"widget": chip, "ref": chip}
	return {"widget": null, "ref": null}


# Pulls this field's CURRENT value from the canonical source into its already-built widget — called
# by Shell exactly once, the moment a field transitions from hidden to shown (a screen might mount
# while GameSignals hasn't fired since app start, e.g. right after loading a save), and harmlessly
# thereafter (the live signal connections from _build_field keep it correct while shown). No-op for
# fields with no backing data yet (no active run / profile) — they just stay at their built default.
static func sync_field(key: int, widget: Control) -> void:
	var run := GameData.current_run
	match key:
		Field.ACT:
			if run != null:
				(widget as Label).text = "Act %d" % run.act
		Field.HP:
			if run != null:
				_refresh_stat(widget, "%d / %d" % [run.king_health(), run.king_max_health()])
		Field.GOLD:
			if run != null:
				_refresh_stat(widget, str(run.gold))
		Field.RELICS:
			widget.get_child(0).refresh()   # the chip's one child is the RelicTray
		Field.EXP:
			_refresh_exp_chip(widget)


# Swaps the value text inside a stat() chip in place (chip -> [tag, value] row -> value label).
static func _refresh_stat(chip: Control, value: String) -> void:
	var row: HBoxContainer = chip.get_child(0)
	var value_lbl: Label = row.get_child(1)
	value_lbl.text = value


# Rebuilds the EXP chip's inner content (a fresh experience_bar_compact each time — it's cheap and
# has no state worth preserving) from the current profile. No-op if there's no profile yet.
static func _refresh_exp_chip(chip: Control) -> void:
	for c in chip.get_children():
		c.queue_free()
	var p := GameData.current_profile
	if p != null:
		chip.add_child(experience_bar_compact(p, UIScale.is_compact(), false))


# A subtle rounded container ("chip") for a header element, so each stat reads as its own tidy
# capsule instead of muddy free-floating text. Wrap any header widget (stat, RelicTray, EXP…) in one
# for a consistent, structured look.
static func header_chip(inner: Control) -> PanelContainer:
	var chip := PanelContainer.new()
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.18, 0.19, 0.27)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 5
	sb.content_margin_bottom = 5
	chip.add_theme_stylebox_override("panel", sb)
	chip.add_child(inner)
	return chip


# ONE consistent header stat readout — a dim tag + a coloured value in a chip — so a given piece of
# run info (HP, Gold, …) looks identical in every view that shows it. Used in the header content slot.
static func stat(tag: String, value: String, value_color: Color) -> Control:
	var compact := UIScale.is_compact()
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 7)
	h.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var t := Label.new()
	t.text = tag
	t.add_theme_font_size_override("font_size", 20 if compact else 15)
	t.add_theme_color_override("font_color", Color(0.6, 0.62, 0.72))
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(t)
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 28 if compact else 22)
	v.add_theme_color_override("font_color", value_color)
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(v)
	return header_chip(h)


# THE chrome-button look shared by every header/footer button — a raised, shadowed capsule so it
# reads as a pressable object sitting ON the bar, not text flush inside it (same "give it volume"
# treatment as map.gd's big Forge button, just toned down for a bar-sized control). One shared
# builder so every close/footer button gets identical depth; states differ only by shade.
static func _apply_chrome_button_style(btn: Button, base: Color, radius: int) -> void:
	for state in ["normal", "hover", "pressed"]:
		var sb := StyleBoxFlat.new()
		var bg := base
		if state == "hover":   bg = base.lightened(0.15)
		if state == "pressed": bg = base.darkened(0.15)
		sb.bg_color = bg
		sb.set_corner_radius_all(radius)
		sb.border_color = base.lightened(0.4)
		sb.set_border_width_all(2)
		sb.shadow_color = Color(0.0, 0.0, 0.0, 0.35)
		sb.shadow_size = 6
		sb.shadow_offset = Vector2(0, 3)
		sb.anti_aliasing = true
		btn.add_theme_stylebox_override(state, sb)


# The standard top-right "✕" close button. `action` may be an empty Callable() — Shell builds
# both header close buttons once with no action bound yet, then rebinds them per screen (see
# Shell._rebind_button); an empty Callable here just means "not wired up yet."
static func close_button(action: Callable) -> Button:
	var compact := UIScale.is_compact()
	var btn := Button.new()
	btn.text = CLOSE_GLYPH
	btn.tooltip_text = "Close"
	btn.add_theme_font_size_override("font_size", 34 if compact else 24)
	btn.custom_minimum_size = Vector2(BUTTON_HEIGHT_COMPACT, BUTTON_HEIGHT_COMPACT) if compact \
		else Vector2(56, BUTTON_HEIGHT)
	_apply_chrome_button_style(btn, Color(0.24, 0.25, 0.33), 12)
	if action.is_valid():
		btn.pressed.connect(action)
	return btn


# THE footer button — identical everywhere a footer appears, and sized to fit inside the footer
# bar's fixed height (see footer_bar) — the same row height the header uses, so the two bars read
# as one consistent chrome band, just top and bottom. No caller may size/font a footer button
# itself; every footer action (Back, Save & Quit, Debug Items, …) goes through this one builder,
# so footers read as one component across the whole app instead of drifting per screen. `action`
# may be an empty Callable() — see close_button's note; the same applies here for Shell's
# persistent Back button, rebound per screen via Shell._rebind_button.
static func footer_button(text: String, action: Callable) -> Button:
	var compact := UIScale.is_compact()
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", 30 if compact else 20)
	btn.custom_minimum_size = Vector2(340, BUTTON_HEIGHT_COMPACT) if compact else Vector2(260, BUTTON_HEIGHT)
	_apply_chrome_button_style(btn, Color(0.24, 0.25, 0.33), 12)
	if action.is_valid():
		btn.pressed.connect(action)
	return btn


# The standard bottom-left "Back" button — just the common case of footer_button().
static func back_button(action: Callable) -> Button:
	return footer_button("‹ Back", action)


# THE footer bar shell — a PanelContainer wrapping a padded HBoxContainer, the same fixed height
# as the header (BAR_HEIGHT/BAR_HEIGHT_COMPACT) so the two read as one consistent chrome band, just
# top and bottom. Built ONLY by Shell (shell.gd's _apply_footer), as its own row alongside the
# header and content, never nested inside a screen's content, and never varying with whatever that
# content does. Same fixed safe_inset + 8 padding header_bar() uses, on every screen, every time —
# a screen's own inset choice has zero effect on where its footer buttons sit. Returns
# {bar: PanelContainer, hbox: HBoxContainer} — the caller adds footer_button()s to the hbox.
static func footer_bar() -> Dictionary:
	var compact := UIScale.is_compact()
	var left := int(UIScale.safe_inset() + 8.0)
	var bar := PanelContainer.new()
	bar.custom_minimum_size.y = BAR_HEIGHT_COMPACT if compact else BAR_HEIGHT
	bar.add_theme_stylebox_override("panel", _footer_stylebox())
	# Vertical margin is just BAR_V_PAD — same as the header's — centering footer_button()
	# (BUTTON_HEIGHT_COMPACT/BUTTON_HEIGHT tall) inside the bar so both bars read as one
	# consistent chrome band, top and bottom.
	var v_margin := int(BAR_V_PAD)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", left)
	pad.add_theme_constant_override("margin_right", left)
	pad.add_theme_constant_override("margin_top", v_margin)
	pad.add_theme_constant_override("margin_bottom", v_margin)
	bar.add_child(pad)
	var hbox := HBoxContainer.new()
	pad.add_child(hbox)
	return {"bar": bar, "hbox": hbox}


