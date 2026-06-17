class_name CardUI
extends Control

signal pressed
signal spell_drag_started(card_ui: CardUI)
signal spell_drag_ended(card_ui: CardUI)

var card_instance: CardInstance
var _show_cost: bool
# True for a rook-generated token shown in the hand's "generated" zone; gives
# the card a distinct glowing frame and a tooltip naming its source building.
var is_generated: bool = false

@onready var _frame: TextureRect = $Canvas/Frame
@onready var _art: TextureRect  = %Art
@onready var _name_bg: TextureRect = %NameBg
@onready var _name_label: Label = %NameLabel
@onready var _cost_bg: TextureRect = %CostBg
@onready var _cost_lbl: Label   = %CostLabel
@onready var _spd_bg: TextureRect = %SpdBg
@onready var _spd_lbl: Label    = %SpdLabel
@onready var _atk_bg: TextureRect = %AtkBg
@onready var _atk_lbl: Label    = %AtkLabel
@onready var _shield_bg: TextureRect = %ShieldBg
@onready var _shield_lbl: Label = %ShieldLabel
@onready var _hp_bg: TextureRect = %HpBg
@onready var _hp_lbl: Label     = %HpLabel
@onready var _comp_row: BoxContainer = %CompRow
@onready var _border: Panel     = %Border
@onready var _canvas: Control   = $Canvas

# The card is authored once at this fixed native resolution. Every visual lives
# under the Canvas node, which is uniformly scaled to fill whatever size the
# CardUI is given (hand, board slot, tooltip…). Because the whole card scales as
# one unit, child components can be positioned freely with offsets (drag them in
# the editor) without breaking at other sizes — relative positions and sizes are
# preserved exactly. Keep this in sync with the Canvas size in card_ui.tscn.
const NATIVE_SIZE := Vector2(260, 340)

const FRAME_UNIT := preload("res://assets/ui/cards/card_frame_unit.png")
const FRAME_SPELL := preload("res://assets/ui/cards/card_frame_spell.png")
const FRAME_KING := preload("res://assets/ui/cards/card_frame_king.png")
const NAMEPLATE := preload("res://assets/ui/cards/nameplate.png")
const BADGE_COST := preload("res://assets/ui/cards/badge_cost.png")
const BADGE_SPEED := preload("res://assets/ui/cards/badge_speed.png")
const BADGE_ATTACK := preload("res://assets/ui/cards/badge_attack.png")
const BADGE_SHIELD := preload("res://assets/ui/cards/badge_shield.png")
const BADGE_HEALTH := preload("res://assets/ui/cards/badge_health.png")

# All card text uses EB Garamond (an open-licensed OFL serif, so it's safe to
# embed in the web export — unlike a SystemFont, which the browser build can't
# resolve). It's a variable font; we render it heavier than its book default via
# a shared FontVariation so the small stat numbers stay legible, then lean on a
# thick dark outline for contrast against the card art.
const CARD_FONT: FontFile = preload("res://assets/ui/fonts/EBGaramond.ttf")
static var _serif_font: FontVariation = null


static func _card_serif() -> FontVariation:
	if _serif_font == null:
		_serif_font = FontVariation.new()
		_serif_font.base_font = CARD_FONT
		# 0x77676874 == the packed ASCII tag for "wght" (the weight axis); 700 is
		# a bold-ish instance of EB Garamond's 400-800 range.
		_serif_font.variation_opentype = { 0x77676874: 700.0 }
	return _serif_font

# Size of the enlarged card rendered inside the hover tooltip.
const TOOLTIP_PREVIEW_SIZE := Vector2(260, 340)

# Surface-level composition chips shown beneath the name. A card belongs to a
# composition group if it carries that element/piece at all (e.g. an "earth"
# effect hits every card with >=1 earth in its make-up), so these symbols are
# the primary at-a-glance identity of the card. Elements render as coloured
# circular chips, chess pieces as squarer steel chips. To upgrade to real icon
# art later, add a "texture" to an entry and have _make_comp_chip prefer it.
const COMP_VISUALS := {
	"fire":     { "color": Color(0.86, 0.28, 0.16), "letter": "F", "text": Color(1.0, 0.95, 0.9) },
	"water":    { "color": Color(0.22, 0.5, 0.92),  "letter": "W", "text": Color(0.95, 0.98, 1.0) },
	"air":      { "color": Color(0.62, 0.83, 0.93), "letter": "A", "text": Color(0.1, 0.2, 0.3) },
	"earth":    { "color": Color(0.45, 0.62, 0.26), "letter": "E", "text": Color(0.97, 1.0, 0.9) },
	"darkness": { "color": Color(0.42, 0.26, 0.55), "letter": "D", "text": Color(0.95, 0.9, 1.0) },
	"light":    { "color": Color(0.95, 0.84, 0.34), "letter": "L", "text": Color(0.3, 0.25, 0.05) },
	"pawn":     { "color": Color(0.62, 0.66, 0.74), "letter": "P", "text": Color(0.1, 0.12, 0.16) },
	"bishop":   { "color": Color(0.62, 0.66, 0.74), "letter": "B", "text": Color(0.1, 0.12, 0.16) },
	"knight":   { "color": Color(0.62, 0.66, 0.74), "letter": "N", "text": Color(0.1, 0.12, 0.16) },
	"rook":     { "color": Color(0.62, 0.66, 0.74), "letter": "R", "text": Color(0.1, 0.12, 0.16) },
	"queen":    { "color": Color(0.85, 0.72, 0.35), "letter": "Q", "text": Color(0.2, 0.15, 0.02) },
	"king":     { "color": Color(0.9, 0.78, 0.3),   "letter": "K", "text": Color(0.2, 0.15, 0.02) },
}

static var _scene: PackedScene = null


static func create(inst: CardInstance, show_cost: bool = false) -> CardUI:
	if _scene == null:
		_scene = load("res://scenes/card_ui.tscn")
	var ui: CardUI = _scene.instantiate()
	ui.card_instance = inst
	ui._show_cost = show_cost
	return ui


func _ready() -> void:
	_apply_asset_textures()
	_apply_label_style()
	_apply_border_style()
	refresh()
	resized.connect(_apply_scale)
	_apply_scale()


# Uniformly scales the fixed-size Canvas to fill the CardUI's current size.
func _apply_scale() -> void:
	if _canvas == null or size.x <= 0.0:
		return
	_canvas.scale = Vector2.ONE * (size.x / NATIVE_SIZE.x)


func _apply_asset_textures() -> void:
	_name_bg.texture = NAMEPLATE
	_cost_bg.texture = BADGE_COST
	_spd_bg.texture = BADGE_SPEED
	_atk_bg.texture = BADGE_ATTACK
	_shield_bg.texture = BADGE_SHIELD
	_hp_bg.texture = BADGE_HEALTH


func _apply_label_style() -> void:
	var labels := [_name_label, _cost_lbl, _spd_lbl, _atk_lbl, _shield_lbl, _hp_lbl]
	for label: Label in labels:
		label.add_theme_color_override("font_color", Color(0.97, 0.95, 0.86))
		label.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.04, 1.0))
		label.add_theme_constant_override("outline_size", 6)
	# Only the stat numbers use the Garamond serif; the name keeps the default
	# sans face, which the user found more readable for words.
	var numbers := [_cost_lbl, _spd_lbl, _atk_lbl, _shield_lbl, _hp_lbl]
	for num: Label in numbers:
		num.add_theme_font_override("font", _card_serif())
		num.add_theme_font_size_override("font_size", 26)
	_name_label.add_theme_font_size_override("font_size", 22)
	_shield_lbl.add_theme_color_override("font_color", Color(0.58, 0.86, 1.0))


func _apply_border_style() -> void:
	var is_king := card_instance != null and card_instance.data.is_king
	var is_building := card_instance != null and card_instance.data.is_building()
	var style   := StyleBoxFlat.new()
	style.bg_color = Color.TRANSPARENT
	if is_generated:
		# A bright cyan frame marks a freshly conjured token in the hand.
		style.set_border_width_all(3)
		style.border_color = Color(0.35, 0.95, 1.0, 0.95)
	elif is_king:
		style.set_border_width_all(1)
		style.border_color = Color(1.0, 0.82, 0.2, 0.45)
	elif is_building:
		# Buildings read as stone structures: a heavier, cooler slate frame that
		# sets them apart from mobile units and signals they root in place.
		style.set_border_width_all(3)
		style.border_color = Color(0.52, 0.64, 0.74, 0.7)
	else:
		style.set_border_width_all(1)
		style.border_color = Color(0.45, 0.45, 0.55, 0.35)
	style.set_corner_radius_all(6)
	_border.add_theme_stylebox_override("panel", style)


# Marks this card as a rook-generated token and refreshes its glowing frame.
# The source building is stored on the instance (card_instance.source_building).
func set_generated() -> void:
	is_generated = true
	if _border != null:
		_apply_border_style()


# Once a token is actually played it becomes an ordinary board unit: drop the
# glow and sever the source-building link.
func clear_generated() -> void:
	is_generated = false
	if card_instance != null:
		card_instance.source_building = null
	if _border != null:
		_apply_border_style()


# Dims a building whose attack was spent generating a card this round, so it
# reads as "tapped". Reset to normal at the start of the next round.
func set_exhausted(exhausted: bool) -> void:
	modulate = Color(0.6, 0.6, 0.68) if exhausted else Color.WHITE


func refresh() -> void:
	if card_instance == null:
		return
	_art.texture = card_instance.data.image

	var is_spell := card_instance.is_spell
	_frame.texture = FRAME_KING if card_instance.data.is_king else (FRAME_SPELL if is_spell else FRAME_UNIT)
	_name_label.text  = card_instance.data.display_name
	_cost_lbl.text    = str(card_instance.get_attribute("cost"))
	_atk_lbl.text       = str(card_instance.get_attribute("attack"))
	_hp_lbl.text        = str(card_instance.current_health)
	_spd_lbl.text       = str(card_instance.get_attribute("speed"))
	var shld            := card_instance.current_shield
	_shield_lbl.text    = str(shld)
	_atk_bg.visible     = not is_spell
	_atk_lbl.visible    = not is_spell
	_shield_bg.visible  = not is_spell and shld > 0
	_shield_lbl.visible = not is_spell and shld > 0
	_hp_bg.visible      = not is_spell
	_hp_lbl.visible     = not is_spell
	_spd_bg.visible     = not is_spell
	_spd_lbl.visible    = not is_spell
	_refresh_composition()
	# Non-empty tooltip_text is required for Godot to invoke _make_custom_tooltip;
	# fall back to the name so the enlarged preview shows even without a description.
	var desc := card_instance.data.description
	tooltip_text = desc if not desc.is_empty() else card_instance.data.display_name


# Rebuilds the composition chip strip from the card's elements + chess pieces.
func _refresh_composition() -> void:
	for child in _comp_row.get_children():
		child.queue_free()
	for el: String in card_instance.data.elements:
		_comp_row.add_child(_make_comp_chip(el, true))
	for pc: String in card_instance.data.chess_pieces:
		_comp_row.add_child(_make_comp_chip(pc, false))


func _make_comp_chip(comp_id: String, is_element: bool) -> Control:
	var info: Dictionary = COMP_VISUALS.get(
		comp_id, { "color": Color(0.5, 0.5, 0.5), "letter": "?", "text": Color.WHITE })

	# Sizes are in native Canvas units (260x340); they scale down with the card.
	var chip := Panel.new()
	chip.custom_minimum_size = Vector2(36, 36)
	# Shrink on both axes so the chip stays square whether CompRow is a row or column.
	chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.tooltip_text = comp_id.capitalize()

	var style := StyleBoxFlat.new()
	style.bg_color = info.color
	# Circular for elements, rounded-square for chess pieces — two visual axes.
	style.set_corner_radius_all(18 if is_element else 8)
	style.set_border_width_all(3)
	style.border_color = Color(0.04, 0.04, 0.06, 0.85)
	chip.add_theme_stylebox_override("panel", style)

	var lbl := Label.new()
	lbl.text = info.letter
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.add_theme_color_override("font_color", info.text)
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.6))
	lbl.add_theme_constant_override("outline_size", 2)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_child(lbl)
	return chip


func _make_custom_tooltip(for_text: String) -> Object:
	if card_instance == null:
		return null

	var panel := PanelContainer.new()
	var style  := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.08, 0.14, 0.97)
	style.set_border_width_all(1)
	style.border_color = Color(0.45, 0.45, 0.6)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 14)
	panel.add_child(hbox)

	# Enlarged visual of the card itself (art + frame + badges).
	# SHRINK_CENTER (not the default FILL) keeps the card at TOOLTIP_PREVIEW_SIZE
	# instead of being stretched vertically when the description column is taller,
	# which would blow up the COVERED art far past its window.
	var preview := CardUI.create(card_instance, _show_cost)
	preview.custom_minimum_size = TOOLTIP_PREVIEW_SIZE
	preview.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(preview)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size.x = 240.0
	vbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	vbox.add_theme_constant_override("separation", 6)
	hbox.add_child(vbox)

	var name_lbl := Label.new()
	name_lbl.text = card_instance.data.display_name
	name_lbl.add_theme_font_size_override("font_size", 22)
	vbox.add_child(name_lbl)

	vbox.add_child(HSeparator.new())

	# Generated tokens explain their hidden cost: playing one taps the rook.
	if is_generated and card_instance.source_building != null:
		var note := Label.new()
		note.text = "⚒ Generated by %s — playing it spends that Rook's attack this turn." \
			% card_instance.source_building.data.display_name
		note.autowrap_mode = TextServer.AUTOWRAP_WORD
		note.add_theme_font_size_override("font_size", 15)
		note.add_theme_color_override("font_color", Color(0.45, 0.95, 1.0))
		vbox.add_child(note)

	if not for_text.is_empty() and for_text != card_instance.data.display_name:
		var desc_lbl := Label.new()
		desc_lbl.text          = for_text
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
		desc_lbl.add_theme_font_size_override("font_size", 18)
		desc_lbl.modulate = Color(0.82, 0.82, 0.9)
		vbox.add_child(desc_lbl)

	return panel


func set_selected(selected: bool) -> void:
	modulate = Color(0.65, 1.0, 1.5) if selected else Color.WHITE


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			pressed.emit()
			accept_event()


func _get_drag_data(at_position: Vector2) -> Variant:
	if card_instance == null:
		return null
	# Buildings root in place: a unit with a rook can be dropped from the hand,
	# but once it's on the board (row >= 0) it can no longer be picked up to move.
	if card_instance.row >= 0 and card_instance.data.is_building():
		return null
	if card_instance.is_spell:
		spell_drag_started.emit(self)
	modulate.a = 0.0
	var preview := CardUI.create(card_instance, _show_cost)
	preview.custom_minimum_size = custom_minimum_size
	preview.modulate.a = 0.7
	var wrapper := Control.new()
	wrapper.add_child(preview)
	preview.position = -at_position
	set_drag_preview(wrapper)
	return self


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		modulate.a = 1.0
		if card_instance != null and card_instance.is_spell:
			spell_drag_ended.emit(self)
