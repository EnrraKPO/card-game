class_name StatBadgeTip
extends Control

# A transparent hover-catcher laid over one of the inspector card's stat badges, providing a RICH
# tooltip: the stat's name in its own colour (matching the glossary note) over the plain-language
# rule. Godot's built-in tooltip is a single-colour Label, so a coloured name needs a custom
# tooltip — this overlay owns the `_make_custom_tooltip` override the plain TextureRect badge can't.
# Attached only by CardUI.set_stat_tooltips (the inspector), so board cards keep their whole-card
# hover tooltip untouched.

const TIP_WIDTH := 300.0

var _title: String
var _title_color: Color
var _body: String


# Overlays `badge`, filling it, and routes its hover to this rich tooltip. Goes through UIScale.tip
# so touch stays tooltip-free (an empty trigger there suppresses _make_custom_tooltip entirely).
static func attach(badge: Control, title: String, title_color: Color, body: String) -> void:
	var o := StatBadgeTip.new()
	o._title = title
	o._title_color = title_color
	o._body = body
	o.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	o.mouse_filter = Control.MOUSE_FILTER_STOP
	badge.add_child(o)
	UIScale.tip(o, " ")   # non-empty trigger on desktop; "" on touch (no hover tooltips there)


func _make_custom_tooltip(_for_text: String) -> Object:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = CardTooltip.BG_COLOR
	style.set_border_width_all(1)
	style.border_color = CardTooltip.BORDER_COLOR
	style.set_corner_radius_all(6)
	style.set_content_margin_all(9.0)
	panel.add_theme_stylebox_override("panel", style)

	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.autowrap_mode = TextServer.AUTOWRAP_WORD
	rtl.custom_minimum_size.x = TIP_WIDTH
	rtl.add_theme_font_size_override("normal_font_size", 15)
	rtl.add_theme_color_override("default_color", CardTooltip.TEXT_MAIN)
	# The name in its stat colour, the rule beneath it in the normal body colour.
	rtl.text = "[color=#%s]%s[/color]\n%s" % [_title_color.to_html(false), _title, _body]
	panel.add_child(rtl)
	return panel
