class_name AbilityWidget
extends CardUI

# The tray VIEW of an ACTIVATED ABILITY (see AbilityData): a card-shaped presentation with
# its own procedurally-drawn frame so it reads "ability", not "card". Real frame art can
# replace the procedural panels later without touching behavior.
#
# This widget is purely informational — it wires no cast, no usability derivation, no
# autocast toggle. When activation presentation returns, usability re-derives from the one
# usability rule, never from state pushed at build time.

# Procedural frame palette — deliberately not the card frames' gold/parchment: a cool dark
# slab with an arcane violet edge, so an ability is instantly tellable from a card.
const FRAME_BG := Color(0.115, 0.10, 0.16)
const FRAME_EDGE := Color(0.66, 0.52, 0.92)

static var _widget_scene: PackedScene = null


static func create_for(token_data: CardData) -> AbilityWidget:
	if _widget_scene == null:
		_widget_scene = load("res://scenes/ability_widget.tscn")
	var ui: AbilityWidget = _widget_scene.instantiate()
	ui.card_data = token_data
	ui._show_cost = true
	return ui


func _ready() -> void:
	super()
	_build_ability_chrome()


# ── Procedural frame ───────────────────────────────────────────────────────────────

func _build_ability_chrome() -> void:
	# Replace the card-frame art with the widget's own frame: a full-rect background slab
	# behind the art plus an edge ring above it. Border (the type-coded card outline) is
	# retired too — the widget's edge ring is its outline.
	_frame.visible = false
	_border.visible = false

	var bg := Panel.new()
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg_style := StyleBoxFlat.new()
	bg_style.bg_color = FRAME_BG
	bg_style.set_corner_radius_all(12)
	bg.add_theme_stylebox_override("panel", bg_style)
	_canvas.add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_canvas.move_child(bg, 0)   # behind the art and every badge

	var edge := Panel.new()
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var edge_style := StyleBoxFlat.new()
	edge_style.bg_color = Color.TRANSPARENT
	edge_style.border_color = FRAME_EDGE
	edge_style.set_border_width_all(4)
	edge_style.set_corner_radius_all(12)
	edge.add_theme_stylebox_override("panel", edge_style)
	_canvas.add_child(edge)
	edge.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)



