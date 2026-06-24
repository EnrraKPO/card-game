class_name ScreenUI
extends RefCounted

# Shared chrome for the code-built full-screen menus (Decks, Shop, Forge, …). Removes the
# repeated "background + header bar + body + footer" boilerplate, plus the standard exit
# affordances (top-right ✕ / bottom-left Back) wired to the OS go-back gesture (see Nav).
# Usage:
#   var s := ScreenUI.scaffold(self, "Decks")
#   s.root.add_child(my_body)                          # screen content (between header & footer)
#   ScreenUI.attach_exits(self, _go_back, s.header, s.footer)

const BG_COLOR := Color(0.07, 0.07, 0.12)
const CLOSE_GLYPH := "✕"


# Builds the standard chrome on `host` and returns { root, header, footer }. Add body content to
# `root` (the expand-fill middle, between header and footer); add trailing buttons / labels to
# `header` (the title fills the left, so they align right); the `footer` is the bottom bar that
# holds the Back button (see attach_exits) and is hidden until something is added to it.
static func scaffold(host: Control, title: String) -> Dictionary:
	var compact := UIScale.is_compact()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = BG_COLOR
	host.add_child(bg)

	var outer := VBoxContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.add_theme_constant_override("separation", 0)
	host.add_child(outer)

	var header := PanelContainer.new()
	header.custom_minimum_size.y = 104.0 if compact else 56.0
	outer.add_child(header)

	var header_hbox := HBoxContainer.new()
	header.add_child(header_hbox)

	var title_lbl := Label.new()
	title_lbl.text = "  " + title
	title_lbl.add_theme_font_size_override("font_size", 34 if compact else 22)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_hbox.add_child(title_lbl)

	# Persistent experience readout in the top bar of every menu/run screen that uses this
	# chrome (combat builds its own crowded HUD and is intentionally excluded). Omitted only
	# before a profile exists (slot picker). attach_exits later docks the ✕ to its right.
	var profile := GameData.current_profile
	if profile != null:
		header_hbox.add_child(experience_bar_compact(profile, compact))

	# Body fills the middle; callers add their content here.
	var body := VBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	outer.add_child(body)

	# Footer bar pinned at the bottom; holds the Back button (see attach_exits).
	var footer := PanelContainer.new()
	outer.add_child(footer)
	var footer_pad := MarginContainer.new()
	footer_pad.add_theme_constant_override("margin_left", 8)
	footer.add_child(footer_pad)
	var footer_hbox := HBoxContainer.new()
	footer_pad.add_child(footer_hbox)

	return {"root": body, "header": header_hbox, "footer": footer_hbox}


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


# A single-row experience widget sized to live in a header bar: tag + thin bar + count, with a
# gold spendable-points nudge when any are banked. A static snapshot (experience only changes
# in-run), mirroring how the hub and Upgrades screen read the profile. See experience_bar.
static func experience_bar_compact(profile: ProfileData, compact: bool = false) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var pts := profile.upgrade_points
	row.tooltip_text = "Experience — %d / %d to next upgrade point · %d available" % [
		profile.experience, ProfileData.EXP_PER_UPGRADE_POINT, pts]

	var tag := Label.new()
	tag.text = "EXP"
	tag.add_theme_font_size_override("font_size", 18 if compact else 12)
	tag.modulate = Color(0.7, 0.72, 0.8)
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(tag)

	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = ProfileData.EXP_PER_UPGRADE_POINT
	bar.value = profile.experience
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(150.0 if compact else 120.0, 18.0 if compact else 14.0)
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(bar)

	var val := Label.new()
	val.text = "%d/%d" % [profile.experience, ProfileData.EXP_PER_UPGRADE_POINT]
	val.add_theme_font_size_override("font_size", 16 if compact else 11)
	val.modulate = Color(0.7, 0.72, 0.8)
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val)

	if pts > 0:
		var pt := Label.new()
		pt.text = "  %d pt%s" % [pts, "" if pts == 1 else "s"]
		pt.add_theme_font_size_override("font_size", 18 if compact else 13)
		pt.add_theme_color_override("font_color", Color(0.95, 0.84, 0.34))
		pt.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(pt)
	return row


# The standard top-right "✕" close button.
static func close_button(action: Callable) -> Button:
	var compact := UIScale.is_compact()
	var btn := Button.new()
	btn.text = CLOSE_GLYPH
	btn.tooltip_text = "Close"
	btn.add_theme_font_size_override("font_size", 32 if compact else 20)
	btn.custom_minimum_size = Vector2(84, 84) if compact else Vector2(44, 40)
	btn.pressed.connect(action)
	return btn


# The standard bottom-left "Back" button.
static func back_button(action: Callable) -> Button:
	var compact := UIScale.is_compact()
	var btn := Button.new()
	btn.text = "‹ Back"
	btn.add_theme_font_size_override("font_size", 30 if compact else 18)
	btn.custom_minimum_size = Vector2(200, 84) if compact else Vector2(120, 40)
	btn.pressed.connect(action)
	return btn


# Adds the two standard exit affordances — a top-right "✕" and a bottom-left "Back", both wired to
# the same `exit` — and registers `exit` as the OS go-back / Esc handler (see Nav). On a scaffold
# screen pass its `header` and `footer` so the buttons dock into the chrome (no overlap); on a
# hand-built / centered screen omit them and the buttons float in the corners of `host`.
static func attach_exits(host: Control, exit: Callable, header: HBoxContainer = null, footer: HBoxContainer = null, float_exp: bool = true) -> void:
	var close := close_button(exit)
	if header != null:
		header.add_child(close)
	else:
		_pin(host, close, Control.PRESET_TOP_RIGHT)

	var back := back_button(exit)
	if footer != null:
		footer.add_child(back)
	else:
		_pin(host, back, Control.PRESET_BOTTOM_LEFT)

	# Header-less screens (the in-run encounter popups) get the persistent exp readout pinned
	# top-left, clear of the ✕ (top-right) and Back (bottom-left). Scaffold screens already
	# carry it in their header; pass float_exp=false to opt out (e.g. the hub, which shows its
	# own larger bar). Combat builds its own HUD and never routes through here.
	if header == null and float_exp and GameData.current_profile != null:
		var exp := experience_bar_compact(GameData.current_profile, UIScale.is_compact())
		host.add_child(exp)
		exp.reset_size()
		var sz := exp.size
		exp.anchor_left = 0.0; exp.anchor_top = 0.0
		exp.anchor_right = 0.0; exp.anchor_bottom = 0.0
		exp.offset_left = 16.0; exp.offset_top = 14.0
		exp.offset_right = 16.0 + sz.x; exp.offset_bottom = 14.0 + sz.y

	Nav.set_back(exit)


# Anchors `btn` to a corner of `host` with a fixed inset, sized to its own minimum. Kept outside any
# container so the anchors/offsets fully determine the rect.
static func _pin(host: Control, btn: Button, preset: int) -> void:
	const INSET := 16.0
	var w: float = btn.custom_minimum_size.x
	var h: float = btn.custom_minimum_size.y
	match preset:
		Control.PRESET_TOP_RIGHT:
			btn.anchor_left = 1.0; btn.anchor_right = 1.0
			btn.anchor_top = 0.0; btn.anchor_bottom = 0.0
			btn.offset_right = -INSET; btn.offset_left = -INSET - w
			btn.offset_top = INSET; btn.offset_bottom = INSET + h
		Control.PRESET_BOTTOM_LEFT:
			btn.anchor_left = 0.0; btn.anchor_right = 0.0
			btn.anchor_top = 1.0; btn.anchor_bottom = 1.0
			btn.offset_left = INSET; btn.offset_right = INSET + w
			btn.offset_bottom = -INSET; btn.offset_top = -INSET - h
	host.add_child(btn)
