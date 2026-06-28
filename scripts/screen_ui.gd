class_name ScreenUI
extends RefCounted

# THE shared chrome for every code-built full-screen menu/overlay (Decks, Shop, Forge, Reward,
# Rest, the hub, …). One frame for all of them — standard "background + header bar (title + EXP +
# ✕) + body + footer (Back)" with the exits wired to the OS go-back gesture (see Nav) — so the
# chrome, and the ✕/Back placement, is identical everywhere by construction.
# Usage (preferred):
#   var body := ScreenUI.frame(self, "Decks", _go_back)   # returns the body container to fill
#   body.add_child(my_content)
# Centered overlays use frame_centered() instead. Screens that must add their own header buttons
# drop to scaffold + attach_exits:
#   var s := ScreenUI.scaffold(self, "Decks")
#   s.header.add_child(my_button)
#   ScreenUI.attach_exits(_go_back, s.header, s.footer)

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

	# The background (above) stays full-bleed; the chrome + body inset off the edges so no
	# button (the ✕ in the header, Back in the footer, any content) sits in the touch-hostile
	# border zone. One inset, bigger on touch — see UIScale.safe_inset.
	var inset := UIScale.safe_inset()
	var outer := VBoxContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.offset_left = inset
	outer.offset_top = inset
	outer.offset_right = -inset
	outer.offset_bottom = -inset
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
	btn.add_theme_font_size_override("font_size", 34 if compact else 24)
	btn.custom_minimum_size = Vector2(88, 88) if compact else Vector2(56, 52)
	btn.pressed.connect(action)
	return btn


# The standard bottom-left "Back" button.
static func back_button(action: Callable) -> Button:
	var compact := UIScale.is_compact()
	var btn := Button.new()
	btn.text = "‹ Back"
	btn.add_theme_font_size_override("font_size", 30 if compact else 22)
	btn.custom_minimum_size = Vector2(210, 88) if compact else Vector2(150, 54)
	btn.pressed.connect(action)
	return btn


# THE canonical full-screen frame. Builds the standard chrome (header: title + EXP + ✕; footer:
# Back), wires `exit` to both buttons and the OS go-back / Esc gesture (see Nav), and returns the
# body container for the caller to fill. Every menu/overlay screen comes through here, so the
# chrome — and crucially the ✕/Back placement — is identical everywhere by construction. Callers
# that need the header/footer refs (e.g. to drop an extra title-bar button) can use scaffold +
# attach_exits directly; everyone else should prefer frame().
static func frame(host: Control, title: String, exit: Callable) -> VBoxContainer:
	var s := scaffold(host, title)
	attach_exits(exit, s.header, s.footer)
	return s.root


# Centered-content variant of frame for sparse "hero" screens (Reward, Rest, Shrine…). Returns the
# body column directly: it FILLS the width (children stretch full-width, so centered labels/rows
# span the screen instead of huddling in a thin strip) and centers its content vertically. This is
# the anti-"tiny island in empty space" layout — add content straight to the returned VBox.
static func frame_centered(host: Control, title: String, exit: Callable) -> VBoxContainer:
	var body := frame(host, title, exit)
	body.alignment = BoxContainer.ALIGNMENT_CENTER
	return body


# Docks the two standard exits — top-right ✕ into `header`, bottom-left Back into `footer` — and
# registers `exit` as the OS go-back / Esc handler. There is no floating fallback: every screen has
# the standard chrome, so the exits always land in the same place.
static func attach_exits(exit: Callable, header: HBoxContainer, footer: HBoxContainer) -> void:
	header.add_child(close_button(exit))
	footer.add_child(back_button(exit))
	Nav.set_back(exit)
