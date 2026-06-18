class_name ScreenUI
extends RefCounted

# Shared chrome for the code-built full-screen menus (Decks, Shop, Forge, …). Removes the
# repeated "background + root VBox + header bar with a title and a nav button" boilerplate.
# Usage:
#   var s := ScreenUI.scaffold(self, "Decks")
#   s.header.add_child(ScreenUI.nav_button("Back  ", _go_back))   # trailing header items
#   s.root.add_child(my_body)                                     # screen content

const BG_COLOR := Color(0.07, 0.07, 0.12)


# Builds the standard chrome on `host` and returns { root: VBoxContainer, header: HBoxContainer }.
# Add body content to `root` (below the header); add trailing buttons / labels to `header`
# (the title already fills the left, so they align right).
static func scaffold(host: Control, title: String) -> Dictionary:
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = BG_COLOR
	host.add_child(bg)

	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	host.add_child(root)

	var header := PanelContainer.new()
	header.custom_minimum_size.y = 56.0
	root.add_child(header)

	var header_hbox := HBoxContainer.new()
	header.add_child(header_hbox)

	var title_lbl := Label.new()
	title_lbl.text = "  " + title
	title_lbl.add_theme_font_size_override("font_size", 22)
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header_hbox.add_child(title_lbl)

	return {"root": root, "header": header_hbox}


# A header nav button (Back / Leave / Cancel) wired to `action`.
static func nav_button(text: String, action: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", 18)
	btn.pressed.connect(action)
	return btn
