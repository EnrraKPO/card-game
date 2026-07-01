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


# THE header surface — a clearly distinct bar (lighter than the screen, with a thin accent underline)
# so a header always reads as a bar and its ✕ sits inside it rather than floating. Shared by every
# header (scaffold's menu header + header_bar's HUD header) so they're identical.
static func _header_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.13, 0.19)
	sb.border_width_bottom = 2
	sb.border_color = Color(0.30, 0.33, 0.44)
	return sb


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
	# Touch-safe inset PLUS a base outer margin, so the whole frame breathes off the screen edges
	# (and the corner ✕ / Back aren't jammed against them). The header gets its own padding below.
	var margin := UIScale.safe_inset() + 36.0
	var outer := VBoxContainer.new()
	outer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	outer.offset_left = margin
	outer.offset_top = margin
	outer.offset_right = -margin
	outer.offset_bottom = -margin
	# Vertical gaps between header / body / footer so the corner ✕ and Back aren't jammed against
	# the body's top/bottom rows (e.g. the ✕ vs the first meta button).
	outer.add_theme_constant_override("separation", 24)
	host.add_child(outer)

	var header := PanelContainer.new()
	header.custom_minimum_size.y = 104.0 if compact else 56.0
	header.add_theme_stylebox_override("panel", _header_stylebox())
	outer.add_child(header)

	# Horizontal padding inside the header + spacing between its items, so the title and the docked
	# ✕ (added by attach_exits) have breathing room instead of being jammed against the edges.
	var header_pad := MarginContainer.new()
	header_pad.add_theme_constant_override("margin_left", 16)
	header_pad.add_theme_constant_override("margin_right", 16)
	header.add_child(header_pad)

	var header_hbox := HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 16)
	header_pad.add_child(header_hbox)

	var title_lbl := Label.new()
	title_lbl.text = title
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
# instead of the framed scaffold(). Same chrome as the menu header — a PanelContainer bar with the
# standard docked ✕ (right) and a left content slot the screen fills with shared widgets (stat(),
# experience_bar_compact(), RelicTray…) — and it wires `exit` to the OS go-back gesture (Nav), so
# every screen's header is built here rather than hand-rolled. Caller anchors `bar` (e.g. TOP_WIDE)
# and adds it to the screen; `content` is where the screen's header items go.
static func header_bar(exit: Callable) -> Dictionary:
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
	row.add_theme_constant_override("separation", 16)
	pad.add_child(row)

	# The content slot fills the left; the ✕ docks at the far right (same placement as every menu).
	var content := HBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 16)
	row.add_child(content)
	row.add_child(close_button(exit))

	Nav.set_back(exit)
	return {"bar": bar, "content": content}


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
