class_name ScreenUI
extends RefCounted

# Shared header-chrome building blocks, owned and called by the persistent Shell (scripts/shell.gd)
# — NOT by individual screens. Screens are content mounted into the Shell's body; they declare their
# chrome via an optional `get_chrome() -> Dictionary` method (title/fields/exit/etc — see shell.gd's
# header comment for the schema) instead of building header nodes themselves. The header NEVER hosts
# screen-specific content (buttons, filters, counts) — those belong in a toolbar row inside the
# screen's own body content, same as any other body content.

# U+00D7 (multiplication sign), not U+2715 ("✕") — the bundled CHUNKY_FONT (Baloo2-ExtraBold)
# has no glyph for U+2715 at all. Desktop silently falls back to a system font so it looked fine
# there, but web/mobile builds have no such fallback and render a broken glyph. × is actually in
# the font (verified via Font.has_char), so it's guaranteed to render the same everywhere.
const CLOSE_GLYPH := "×"

# THE app-wide neutral palette — every screen's background/panel/dialog surface picks one of
# these, never invents its own. LIGHT AND WARM — matching the actual art-direction reference
# (D:\Godot\ArtDirection\styleguide.jpg, section 3 "Board UI & Buttons": a warm cream page with a
# tan/wood board panel, NOT a dark backdrop). A dark app background under these saturated glossy
# buttons reads as neon signage; the same buttons on a warm, light, low-saturation surface read as
# molded plastic toys on a table — the actual "Bold & Punchy" look this is meant to be. A screen
# with its own bespoke background hue — even a thematically-motivated one, like a victory/defeat
# tint — breaks the game's identity; carry that mood in text/accent color instead, the way
# run_success/run_over already do with their title.
#
# Backed by UIPalette (scripts/ui_palette.gd) — edit the Color() values in that script directly to
# retheme the whole app; these static vars just mirror it once at class-load time so every existing
# `ScreenUI.BG_COLOR`-style call site keeps working unchanged.
static var _palette: UIPalette = UIPalette.new()
static var BG_COLOR: Color = _palette.bg_color              # the app background — Shell, and nothing
															 # else (a full screen never overrides
															 # this) — ochre
static var SURFACE_COLOR: Color = _palette.surface_color   # header/footer/panel surfaces sitting on
															 # BG_COLOR — cream, lighter than BG_COLOR
static var SURFACE_BORDER: Color = _palette.surface_border # accent border on a SURFACE_COLOR panel
static var SURFACE_DEEP: Color = _palette.surface_deep     # inset panels sitting ON a surface
															 # (tooltips, dialogs, drop wells) — one
															 # step deeper/richer
static var SURFACE_DEEP_BORDER: Color = _palette.surface_deep_border
static var TEXT_COLOR: Color = _palette.text_color         # the default warm dark text color for a
															 # light background — see also theme.tres's
															 # Label default, which covers everything
															 # NOT built through ScreenUI's own helpers

# THE bar height — header and footer are the same fixed row height, everywhere, always. Both
# build_header() and footer_bar() size themselves off this one pair of numbers. Includes BAR_V_PAD
# of breathing room above/below the buttons on top of their own fixed BUTTON_HEIGHT, so a button
# never looks compressed flush against the bar's edge.
const BAR_V_PAD := 6.0
const BUTTON_HEIGHT := 52.0
# Mobile/compact chrome is deliberately much taller than desktop: the header/footer bars and their
# ✕ / Back buttons size off this, and touch targets need to be big and easy to hit. ~1.5x the old
# value so the bars and corner buttons are ~50% larger on mobile.
const BUTTON_HEIGHT_COMPACT := 80.0
const BAR_HEIGHT := BUTTON_HEIGHT + BAR_V_PAD * 2.0
const BAR_HEIGHT_COMPACT := BUTTON_HEIGHT_COMPACT + BAR_V_PAD * 2.0

# The fixed catalog of run-status fields any header can show. A screen names the keys it wants
# (in a header_bar definition); each field pulls its OWN data from the single canonical source
# (GameData.current_run / current_profile), so a screen never passes a value in and the same fact
# always renders identically everywhere. Turn/Mana are deliberately NOT here — they're combat
# gameplay state, not run status, and live in combat's own HUD.
enum Field { ACT, HP, GOLD, MINERAL, RELICS, EXP }

# WHERE each field sits is a property of the catalog, NOT of any screen — so the same field always
# lands in the same place, in the same order, in every header. A screen only chooses WHICH fields to
# show; these two ordered lists decide the rest (left cluster · flexible gap · right cluster · ✕).
const _LEFT_FIELDS := [Field.ACT, Field.HP, Field.GOLD, Field.MINERAL, Field.RELICS]
const _RIGHT_FIELDS := [Field.EXP]


# THE header surface — a clearly distinct bar (lighter than the screen, with a thin accent underline)
# so a header always reads as a bar and its ✕ sits inside it rather than floating. Shared by every
# header (scaffold's menu header + header_bar's HUD header) so they're identical.
static func _header_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = SURFACE_COLOR
	sb.border_width_bottom = 2
	sb.border_color = SURFACE_BORDER
	return sb


# THE footer surface — same bg/accent treatment as the header (see _header_stylebox), just with
# the accent line on the TOP edge instead of the bottom (the edge facing the content either bar
# borders), so the footer reads as a matching bar of its own instead of fading into the page
# behind it under the default flat Panel style.
static func _footer_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = SURFACE_COLOR
	sb.border_width_top = 2
	sb.border_color = SURFACE_BORDER
	return sb


# A profile experience bar: progress toward the next upgrade point + the spendable balance.
# Reused by the hub and the Upgrades screen. Reads the given profile's experience snapshot.
static func experience_bar(profile: ProfileData, compact: bool = false) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)

	var pts := profile.upgrade_points
	var header := Label.new()
	header.text = Loc.t("screen_ui.exp_header_one") if pts == 1 \
		else Loc.t("screen_ui.exp_header_many", {"n": pts})
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
	sub.text = Loc.t("screen_ui.exp_to_next", {"cur": profile.experience, "max": ProfileData.EXP_PER_UPGRADE_POINT})
	sub.add_theme_font_size_override("font_size", 14 if compact else 11)
	sub.add_theme_color_override("font_color", Color("5a4a38"))   # muted warm brown — this widget
															 # sits directly on the light app
															 # background, not a dark chip
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
	var tip := Loc.t("screen_ui.exp_tip", {"cur": profile.experience, "max": ProfileData.EXP_PER_UPGRADE_POINT})
	if pts > 0:
		tip += "\n" + (Loc.t("screen_ui.exp_tip_points_one") if pts == 1 \
			else Loc.t("screen_ui.exp_tip_points_many", {"n": pts}))
	UIScale.tip(row, tip)

	var tag := Label.new()
	tag.text = Loc.t("screen_ui.exp_tag")
	tag.add_theme_font_size_override("font_size", 18 if compact else 15)
	tag.add_theme_color_override("font_color", Color("6b5636"))   # sits on the header_chip's cream
																	# capsule (ScreenUI.SURFACE_DEEP)
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
		# "•" not "●" — the app's default font (Baloo2-ExtraBold) has no glyph for U+25CF; see
		# CLOSE_GLYPH for the same issue and why it matters specifically on web/mobile.
		pip.text = "•"
		pip.add_theme_font_size_override("font_size", 18 if compact else 14)
		pip.add_theme_color_override("font_color", Color(0.95, 0.84, 0.34))
		pip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		UIScale.tip(pip, tip)
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
	title_lbl.add_theme_color_override("font_color", TEXT_COLOR)   # sits directly on the light
																	 # header bar, not a dark chip
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

	# The settings gear — the header's one always-available action (audio settings today).
	# A persistent piece like everything else; the Shell wires what pressing it opens.
	var gear := action_button("", Callable(), Vector2(side_dev(), side_dev()), 26)
	gear.icon = preload("res://assets/ui/icons/settings.png")
	gear.expand_icon = true
	gear.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	UIScale.tip(gear, Loc.t("settings.title"))
	gear.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(gear)

	# The two placeholder mute/hide dev toggles, sat just left of the ✕. Built once as part of the
	# persistent header (like every other piece); the Shell wires their behavior and DevFlags sync.
	# Their visibility is the Shell's call (debug builds only) — see Shell._wire_dev_toggles.
	var dev_sfx := action_button("", Callable(), Vector2(140, side_dev()), 15, CHROME_DEBUG)
	dev_sfx.toggle_mode = true
	UIScale.tip(dev_sfx, "Placeholder SFX (F7) — OFF = the synth blips are muted")
	row.add_child(dev_sfx)

	var dev_vfx := action_button("", Callable(), Vector2(140, side_dev()), 15, CHROME_DEBUG)
	dev_vfx.toggle_mode = true
	UIScale.tip(dev_vfx, "Placeholder VFX (F8) — OFF = the procedural sketches are hidden")
	row.add_child(dev_vfx)

	var close := close_button(Callable())
	close.visible = false
	row.add_child(close)

	var debug_close := close_button(Callable(), true)
	UIScale.tip(debug_close, "Debug: end combat")
	debug_close.visible = false
	row.add_child(debug_close)

	return {"bar": bar, "title": title_lbl, "fields": fields, "refs": refs, "gear": gear,
		"close": close, "debug_close": debug_close, "dev_sfx": dev_sfx, "dev_vfx": dev_vfx}


# The close button's own square side — the dev toggles match it so the header row aligns.
static func side_dev() -> float:
	return BUTTON_HEIGHT_COMPACT - 16.0


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
			act.add_theme_color_override("font_color", TEXT_COLOR)   # not in a dark chip
			act.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			GameSignals.act_changed.connect(func(a: int) -> void: act.text = Loc.t("screen_ui.act", {"n": a}))
			return {"widget": act, "ref": act}
		Field.HP:
			var hp := stat(Loc.t("screen_ui.hp"), "", Color("1f7a35"))
			GameSignals.hp_changed.connect(func(cur: int, mx: int) -> void: _refresh_stat(hp, "%d / %d" % [cur, mx]))
			return {"widget": hp, "ref": hp}
		Field.GOLD:
			var gold := stat(Loc.t("screen_ui.gold"), "", Color("9c7a10"))
			GameSignals.gold_changed.connect(func(v: int) -> void: _refresh_stat(gold, str(v)))
			return {"widget": gold, "ref": gold}
		Field.MINERAL:
			# Magic Mineral — the run's forge-merge resource (a darker cut of Materials'
			# arcane teal, so the chip tag reads at header scale like Gold's does).
			var mineral := stat(Loc.t("screen_ui.mineral"), "", Color("1e6e5c"))
			GameSignals.mineral_changed.connect(func(v: int) -> void: _refresh_stat(mineral, str(v)))
			return {"widget": mineral, "ref": mineral}
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
				(widget as Label).text = Loc.t("screen_ui.act", {"n": run.act})
		Field.HP:
			if run != null:
				_refresh_stat(widget, "%d / %d" % [run.king_health(), run.king_max_health()])
		Field.GOLD:
			if run != null:
				_refresh_stat(widget, str(run.gold))
		Field.MINERAL:
			if run != null:
				_refresh_stat(widget, str(run.magic_mineral))
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
	sb.bg_color = SURFACE_DEEP        # on-palette — was a leftover dark-navy chip from the old
	sb.border_color = SURFACE_DEEP_BORDER    # dark-theme header, never updated with the rest
	sb.set_border_width_all(1)
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
	t.add_theme_color_override("font_color", Color("6b5636"))
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(t)
	var v := Label.new()
	v.text = value
	v.add_theme_font_size_override("font_size", 28 if compact else 22)
	v.add_theme_color_override("font_color", value_color)
	v.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(v)
	return header_chip(h)


# THE chrome-button look shared by every header/footer button — a procedural glossy "candy" cap
# (see D:\Godot\ArtDirection\Card game UI system\design_handoff_glossy_buttons) so it reads as a
# raised, punchy, pressable object sitting ON the bar, not text flush inside it. One shared builder
# so every close/footer button gets identical volume; only `base_color` ever varies.
#
# A deliberately SMALL button palette — three colors, not six. Most buttons (navigation, Back,
# secondary actions, "View"/"Edit"/"Active") are CHROME_NEUTRAL; the one primary action on a
# screen is CHROME_CONFIRM; a destructive/rare action is CHROME_DANGER. Every button everywhere
# picks one of these three — no screen introduces a new color, and no screen shows more than
# these three colors' worth of buttons at once. CHROME_DEBUG and CHROME_READY are the two
# exceptions, and both are contextually isolated (debug-only screens; combat's own HUD) so they
# never appear alongside the other three and don't add to the count a user sees at once.
static var CHROME_NEUTRAL: Color = _palette.chrome_neutral   # Matte blue — everyday/secondary
															   # actions (Back, navigate, …)
static var CHROME_CONFIRM: Color = _palette.chrome_confirm   # Gold — THE primary/confirm action
static var CHROME_DANGER: Color = _palette.chrome_danger     # Red — destructive/reset actions
															   # (Delete, Reset, Abandon)
static var CHROME_READY: Color = _palette.chrome_ready       # Green — combat's Ready button only
static var CHROME_DEBUG: Color = _palette.chrome_debug       # Orange — the debug affordance
															   # (combat's debug ✕)
static var CHROME_INK: Color = _palette.chrome_ink           # Handoff's shared outline ink

# The combat board's own colors — separate from the chrome palette above (see UIPalette's "Combat
# board" group for why); combat.gd and slot_ui.gd read these instead of hardcoding their own.
static var SLOT_EMPTY: Color = _palette.slot_empty
static var SLOT_BORDER_IDLE: Color = _palette.slot_border_idle
static var SLOT_BORDER_HIGHLIGHT: Color = _palette.slot_border_highlight
static var MANA_TRACK_BG: Color = _palette.mana_track_bg
static var MANA_TRACK_BORDER: Color = _palette.mana_track_border
static var MANA_LIT: Color = _palette.mana_lit
static var MANA_DIM: Color = _palette.mana_dim

# THE button — every button anywhere in the app (not just header/footer chrome) goes through this
# one builder, so the whole UI reads as one consistent glossy "Bold & Punchy" system instead of a
# patchwork of ad hoc Button.new() styling per screen. `base_color` defaults to the neutral teal;
# pass CHROME_DEBUG for a debug-only action, or another handoff color for a screen that genuinely
# needs to distinguish an action (e.g. destructive vs constructive) — but default to CHROME_NEUTRAL
# unless there's a real reason not to.
static func action_button(text: String, action: Callable, min_size: Vector2 = Vector2(220, 64),
		font_size: int = 22, base_color: Color = CHROME_NEUTRAL) -> GlossyButton:
	var btn := GlossyButton.new()
	btn.text = text
	btn.custom_minimum_size = min_size
	btn.add_theme_font_size_override("font_size", font_size)
	btn.base_color = base_color
	btn.ink = CHROME_INK
	if action.is_valid():
		btn.pressed.connect(action)
	return btn


# THE modal cue wiring — the audio counterpart of every button being a GlossyButton: call once
# after creating any native ConfirmationDialog/AcceptDialog and it sounds its open and close.
# (Native dialogs are Windows, not Controls, so they can't take a Vfx overlay — sound carries
# the moment; Control-based overlays play ui_modal_open_bloom themselves.)
static func wire_modal_cues(dialog: Window) -> void:
	dialog.about_to_popup.connect(func() -> void: Sfx.play("ui_modal_open"))
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			Sfx.play("ui_modal_close"))


# The standard top-right "✕" close button. `action` may be an empty Callable() — Shell builds
# both header close buttons once with no action bound yet, then rebinds them per screen (see
# Shell._rebind_button); an empty Callable here just means "not wired up yet." `debug`: the
# orange debug-✕ variant (combat) — a separate fixed piece with its own color, never a mutation
# of the normal ✕ (see [[header-system]] — no chrome piece changes appearance per screen).
static func close_button(action: Callable, debug: bool = false) -> Button:
	# One large size in every case (desktop AND mobile) for now — a single size is easy to test.
	# SIZE_SHRINK_CENTER keeps the row from re-stretching it; GlossyButton.clip_contents keeps the
	# nine-patch art inside the box.
	var side := BUTTON_HEIGHT_COMPACT - 16.0
	var min_size := Vector2(side, side)
	var btn := action_button(CLOSE_GLYPH, action, min_size, 32,
		CHROME_DEBUG if debug else CHROME_NEUTRAL)
	UIScale.tip(btn, Loc.t("common.close"))
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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
	var min_size := Vector2(200, BUTTON_HEIGHT_COMPACT)
	return action_button(text, action, min_size, 60 if compact else 20, CHROME_NEUTRAL)


# The standard bottom-left "Back" button — just the common case of footer_button().
static func back_button(action: Callable) -> Button:
	return footer_button(Loc.t("common.back"), action)


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
