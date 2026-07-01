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


# THE shared header bar for full-bleed HUD screens (map, later combat) that manage their own body
# instead of the framed scaffold(). Fully declarative: the screen says only WHAT it wants shown, and
# the bar decides WHERE everything sits — identically to every other screen. It wires `exit` to the
# docked ✕ and the OS go-back gesture (Nav). Caller only anchors `bar` (e.g. TOP_WIDE) and adds it.
#   definition = {
#     name   : String          # optional title (the ONE view-supplied string), "" for none
#     fields : Array[Field]     # WHICH fields to show — an unordered set. Order/side are NOT the
#                               #   screen's call: the catalog (_LEFT_FIELDS/_RIGHT_FIELDS) fixes
#                               #   them, so the same field is always in the same spot everywhere.
#   }
# Every field also pulls its own data from the canonical source (see header_field / Field), so a
# screen never feeds values OR placement in. Layout: [title · left fields] — gap — [right fields · ✕].
# `exit` is optional: pass a valid Callable for the standard docked ✕ + OS-back wiring (menus, map);
# pass an empty Callable() for screens with no exit (combat mid-fight) — then no ✕ is shown and Nav
# is left untouched. Returns { bar, fields, close } where `fields` maps each shown Field to its live
# widget (e.g. the RelicTray) so a view can poke a component it needs a handle on (glint, read-only…),
# and `close` is the docked ✕ Button (or null when no exit) so a view can restyle it (combat's debug ✕).
static func header_bar(exit: Callable, definition: Dictionary = {}) -> Dictionary:
	var compact := UIScale.is_compact()
	var bar := PanelContainer.new()
	bar.custom_minimum_size.y = 104.0 if compact else 56.0
	bar.add_theme_stylebox_override("panel", _header_stylebox())

	var pad := MarginContainer.new()
	var inset := int(UIScale.safe_inset() + 8.0)   # keep content out of the touch-hostile edge
	pad.add_theme_constant_override("margin_left", inset)
	pad.add_theme_constant_override("margin_right", inset)
	bar.add_child(pad)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16 if compact else 12)
	pad.add_child(row)

	# Optional title — the single string a view supplies (an accepted exception to "no view data").
	var title: String = definition.get("name", "")
	if title != "":
		var title_lbl := Label.new()
		title_lbl.text = title
		title_lbl.add_theme_font_size_override("font_size", 34 if compact else 22)
		title_lbl.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0))
		title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(title_lbl)

	# The screen supplies an unordered SET of fields; the catalog decides order + side. We walk the
	# canonical lists (not the screen's) and place whatever it asked for, so placement is identical
	# across screens by construction. `fields` collects each built field's live widget for the caller.
	var wanted: Array = definition.get("fields", [])
	var fields := {}
	for key in _LEFT_FIELDS:
		if key in wanted:
			var f := header_field(key, fields)
			if f != null:
				row.add_child(f)

	# The open middle: the last left field grows into it, so newly-earned content (e.g. relics)
	# expands rightward rather than the header staying half-empty.
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)

	# Right cluster.
	for key in _RIGHT_FIELDS:
		if key in wanted:
			var rf := header_field(key, fields)
			if rf != null:
				row.add_child(rf)

	# The docked ✕ (same placement as every menu header) — only for screens that HAVE an exit.
	# Combat passes none, so it shows no ✕ and we don't touch the OS-back gesture it cleared.
	var close: Button = null
	if exit.is_valid():
		close = close_button(exit)
		row.add_child(close)
		Nav.set_back(exit)

	return {"bar": bar, "fields": fields, "close": close}


# The catalog builder: turns a Field key into its self-pulling widget, reading only the canonical
# run/profile source so the same fact renders identically in every header. Returns null when the
# backing data isn't present (e.g. no active run / profile yet), so callers can list a field
# unconditionally and the bar just omits it. If `refs` is given, a field that a view may need a
# live handle on registers itself there under its Field key (e.g. RELICS → the RelicTray).
static func header_field(key: int, refs: Dictionary = {}) -> Control:
	var compact := UIScale.is_compact()
	var run := GameData.current_run
	match key:
		Field.ACT:
			if run == null:
				return null
			# The prominent run label (not a chip) — reads as the header's headline, per the map look.
			var act := Label.new()
			act.text = "Act %d" % run.act
			act.add_theme_font_size_override("font_size", 34 if compact else 22)
			act.add_theme_color_override("font_color", Color(0.92, 0.94, 1.0))
			act.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			return act
		Field.HP:
			if run == null:
				return null
			var hp := stat("HP", "%d / %d" % [run.king_health(), run.king_max_health()], Color(0.62, 0.9, 0.66))
			refs[key] = hp   # so a view can refresh_field() it if HP can change while the screen stays open
			return hp
		Field.GOLD:
			if run == null:
				return null
			var gold := stat("Gold", str(run.gold), Color(0.98, 0.85, 0.35))
			refs[key] = gold   # so a view can refresh_field() it (e.g. Shop, which spends gold in place)
			return gold
		Field.RELICS:
			if run == null:
				return null
			var tray := RelicTray.new()
			refs[key] = tray   # so a view can glint a firing relic / set the strip read-only
			return header_chip(tray)
		Field.EXP:
			var profile := GameData.current_profile
			if profile == null:
				return null
			return header_chip(experience_bar_compact(profile, compact, false))
	return null


# Re-pulls a header field's value from the canonical source and updates it in place — for the rare
# screen where that value changes while the screen itself stays open (e.g. Shop spending gold),
# unlike map/combat's static per-visit snapshot. No-op if the field wasn't shown (not in `fields`).
static func refresh_field(key: int, fields: Dictionary) -> void:
	if not fields.has(key):
		return
	var run := GameData.current_run
	if run == null:
		return
	match key:
		Field.HP:
			_refresh_stat(fields[key], "%d / %d" % [run.king_health(), run.king_max_health()])
		Field.GOLD:
			_refresh_stat(fields[key], str(run.gold))


# Swaps the value text inside a stat() chip in place (chip -> [tag, value] row -> value label).
static func _refresh_stat(chip: Control, value: String) -> void:
	var row: HBoxContainer = chip.get_child(0)
	var value_lbl: Label = row.get_child(1)
	value_lbl.text = value


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


# The standard top-right "✕" close button.
static func close_button(action: Callable) -> Button:
	var compact := UIScale.is_compact()
	var btn := Button.new()
	btn.text = CLOSE_GLYPH
	btn.tooltip_text = "Close"
	btn.add_theme_font_size_override("font_size", 34 if compact else 24)
	btn.custom_minimum_size = Vector2(88, 88) if compact else Vector2(56, 52)
	btn.pressed.connect(action)
	return btn


# The standard bottom-left "Back" button — chunky, not a tiny outlier next to the page's content.
static func back_button(action: Callable) -> Button:
	var compact := UIScale.is_compact()
	var btn := Button.new()
	btn.text = "‹ Back"
	btn.add_theme_font_size_override("font_size", 40 if compact else 30)
	btn.custom_minimum_size = Vector2(340, 130) if compact else Vector2(260, 96)
	btn.pressed.connect(action)
	return btn


