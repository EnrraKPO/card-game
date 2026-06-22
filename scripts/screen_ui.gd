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
static func attach_exits(host: Control, exit: Callable, header: HBoxContainer = null, footer: HBoxContainer = null) -> void:
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
