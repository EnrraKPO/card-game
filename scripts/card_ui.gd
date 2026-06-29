class_name CardUI
extends Control

signal pressed
signal spell_drag_started(card_ui: CardUI)
signal spell_drag_ended(card_ui: CardUI)

var card_instance: CardInstance
var _show_cost: bool
# Drag-and-drop is a combat affordance (hand → board). Off-combat cards (forge, rewards,
# deck views) set this false: otherwise a touch tap that drifts a pixel starts a drag
# instead of firing `pressed`, so selection silently fails on touchscreens.
var draggable: bool = true
# Left-edge column of charm pips, built lazily (mirrors the composition chips on the right).
var _charm_col: VBoxContainer = null
# Top-edge row of status pips (runtime buffs/debuffs), built lazily.
var _status_row: HBoxContainer = null
# True for a rook-generated token shown in the hand's "generated" zone; gives
# the card a distinct glowing frame and a tooltip naming its source building.
var is_generated: bool = false

# Touch card inspection: hover tooltips don't fire on a touchscreen, so a long-press
# (hold still ~0.4s) opens the full-screen CardInspector instead. Desktop keeps the
# hover tooltip and is left untouched (the timer only arms when a touchscreen exists).
const LONG_PRESS_SEC := 0.4
const LONG_PRESS_MOVE := 14.0   # px of drift that reclassifies the hold as a drag/scroll
var _hold_timer: Timer = null
var _press_origin := Vector2.ZERO
var _did_inspect := false
var _touch_inspect := false

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
const PIECE_ICONS := {
	"pawn": preload("res://assets/ui/icons/piece_pawn.png"),
	"knight": preload("res://assets/ui/icons/piece_knight.png"),
	"bishop": preload("res://assets/ui/icons/piece_bishop.png"),
	"rook": preload("res://assets/ui/icons/piece_rook.png"),
	"queen": preload("res://assets/ui/icons/piece_queen.png"),
	"king": preload("res://assets/ui/icons/piece_king.png"),
}

const ELEMENT_ICONS := {
	"fire": preload("res://assets/ui/icons/fire_icon.png"),
	"water": preload("res://assets/ui/icons/water_icon.png"),
	"air": preload("res://assets/ui/icons/air_icon.png"),
	"earth": preload("res://assets/ui/icons/earth_icon.png"),
	"darkness": preload("res://assets/ui/icons/darkness_icon.png"),
	"light": preload("res://assets/ui/icons/light_icon.png"),
}

# A rim around the (black) silhouette icons so they read on saturated chip colours. The rim is
# a pale, desaturated tint of the chip's own hue — pops against the icon without going stark
# white. One material per composition id (the rim is fixed per id). See icon_outline.gdshader.
const ICON_OUTLINE_SHADER := preload("res://assets/ui/icons/icon_outline.gdshader")
static var _icon_outline_mats: Dictionary = {}

# A washed-out, lightened version of `base` in the same hue — the icon rim colour.
static func _rim_color(base: Color) -> Color:
	return Color.from_hsv(base.h, base.s * 0.4, maxf(base.v, 0.88))

static func _icon_outline_material(comp_id: String, base: Color) -> ShaderMaterial:
	if not _icon_outline_mats.has(comp_id):
		var mat := ShaderMaterial.new()
		mat.shader = ICON_OUTLINE_SHADER
		mat.set_shader_parameter("outline_color", _rim_color(base))
		mat.set_shader_parameter("width", 0.055)
		_icon_outline_mats[comp_id] = mat
	return _icon_outline_mats[comp_id]

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

# Surface-level composition chips shown beneath the name. A card belongs to a
# composition group if it carries that element/piece at all (e.g. an "earth"
# effect hits every card with >=1 earth in its make-up), so these symbols are
# the primary at-a-glance identity of the card. Elements render as coloured
# circular chips, chess pieces as squarer steel chips with piece icons.
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
	# Arm long-press inspection only on touch devices; desktop relies on the hover tooltip.
	_touch_inspect = DisplayServer.is_touchscreen_available()
	if _touch_inspect:
		_hold_timer = Timer.new()
		_hold_timer.one_shot = true
		_hold_timer.wait_time = LONG_PRESS_SEC
		_hold_timer.timeout.connect(_on_long_press)
		add_child(_hold_timer)


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
	_refresh_charms()
	_refresh_statuses()
	# Non-empty tooltip_text is required for Godot to invoke _make_custom_tooltip;
	# fall back to the name so the enlarged preview shows even without a description.
	var desc := card_instance.data.description
	tooltip_text = desc if not desc.is_empty() else card_instance.data.display_name


# Global-space centre of the badge that displays a given stat, so combat VFX can pop a number
# right where its stat lives (position carries the meaning). Uses the badge's global transform so
# the Canvas's uniform scale is accounted for. Falls back to the card centre for unknown/hidden
# stats (e.g. a spell, or a shield badge that's currently empty).
func stat_anchor(attr: String) -> Vector2:
	var node: Control = null
	match attr:
		"attack":               node = _atk_bg
		"health", "max_health": node = _hp_bg
		"shield":               node = _shield_bg
		"speed":                node = _spd_bg
		"cost":                 node = _cost_bg
	# Don't require `visible`: a badge that's momentarily hidden (e.g. a shield badge at 0 about to
	# be restored) still has a valid anchored position, and we want the glint to land on it.
	if node != null and is_instance_valid(node):
		return node.get_global_transform() * (node.size * 0.5)
	return global_position + size * 0.5


# A focal "this stat just changed" pop: scales the named stat's badge — icon AND number together,
# about their shared centre — up and back, pulling the eye straight to the badge that moved. `grow`
# true springs a gain outward; false gives a loss a quick recoil dip. Purely transient — the badge
# returns to its authored scale, so the card's fixed Canvas layout is never disturbed.
func pulse_stat(attr: String, grow: bool = true) -> void:
	var bg: Control = null
	var lbl: Control = null
	match attr:
		"attack":               bg = _atk_bg;    lbl = _atk_lbl
		"health", "max_health": bg = _hp_bg;     lbl = _hp_lbl
		"shield":               bg = _shield_bg; lbl = _shield_lbl
		"speed":                bg = _spd_bg;    lbl = _spd_lbl
		"cost":                 bg = _cost_bg;   lbl = _cost_lbl
	if bg == null or not is_instance_valid(bg):
		return
	var peak: float = 1.32 if grow else 0.8
	# Both nodes pivot about the badge centre (the bg's centre) so they scale as one rigid unit
	# instead of drifting apart.
	var centre := bg.position + bg.size * 0.5
	_pop_node(bg, bg.size * 0.5, peak)
	if lbl != null and is_instance_valid(lbl):
		_pop_node(lbl, centre - lbl.position, peak)


func _pop_node(node: Control, pivot: Vector2, peak: float) -> void:
	node.pivot_offset = pivot
	# Pop out, HOLD at the peak a beat so the change registers, then settle — without the hold the
	# badge just blinks and the eye can't catch what moved.
	var tw := create_tween()
	tw.tween_property(node, "scale", Vector2(peak, peak), 0.14).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_interval(0.14)
	tw.tween_property(node, "scale", Vector2.ONE, 0.20).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)


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

	var icons: Dictionary = ELEMENT_ICONS if is_element else PIECE_ICONS
	if icons.has(comp_id):
		var icon := TextureRect.new()
		icon.texture = icons[comp_id]
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 3
		icon.offset_top = 3
		icon.offset_right = -3
		icon.offset_bottom = -3
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Clamp edge samples (no wrap) so the outline shader's halo doesn't bleed across edges.
		icon.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
		icon.material = _icon_outline_material(comp_id, info.color)
		chip.add_child(icon)
		return chip

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


# Builds the left-edge column of charm pips — one coloured glyph per attached charm,
# mirroring the composition chips on the right. The full detail lives in the tooltip.
func _refresh_charms() -> void:
	var charm_ids: Array = card_instance.charms if card_instance != null else []
	if _charm_col == null:
		if charm_ids.is_empty():
			return   # don't create the column until a charm needs it
		_charm_col = VBoxContainer.new()
		_charm_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_charm_col.add_theme_constant_override("separation", 7)
		# Left-edge band, mirroring CompRow's right-edge band (anchors in native units).
		_charm_col.anchor_left = 0.04
		_charm_col.anchor_top = 0.26
		_charm_col.anchor_right = 0.19
		_charm_col.anchor_bottom = 0.75
		_charm_col.offset_left = 0.0
		_charm_col.offset_top = 0.0
		_charm_col.offset_right = 0.0
		_charm_col.offset_bottom = 0.0
		_canvas.add_child(_charm_col)

	for child in _charm_col.get_children():
		child.queue_free()
	for charm_id: String in charm_ids:
		_charm_col.add_child(_make_charm_pip(charm_id))


func _make_charm_pip(charm_id: String) -> Control:
	var charm := CharmData.get_charm(charm_id)
	var color: Color = charm.color if charm != null else Color(0.7, 0.7, 0.75)
	var glyph: String = charm.letter if charm != null else "✦"

	var pip := Panel.new()
	pip.custom_minimum_size = Vector2(34, 34)
	pip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(17)   # circular, to read distinctly from the square piece chips
	style.set_border_width_all(3)
	style.border_color = Color(0.04, 0.04, 0.06, 0.9)
	pip.add_theme_stylebox_override("panel", style)

	var lbl := Label.new()
	lbl.text = glyph
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 20)
	lbl.add_theme_color_override("font_color", Color(0.98, 0.98, 1.0))
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.7))
	lbl.add_theme_constant_override("outline_size", 3)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pip.add_child(lbl)
	return pip


# Builds the top-edge row of status pips — one coloured glyph (or icon) per active Status, with
# its remaining duration and (when >1) stack count. The detail lives in the pip tooltip. Mirrors
# the charm column; built lazily so a status-free card costs nothing.
func _refresh_statuses() -> void:
	var stats: Array = card_instance.statuses if card_instance != null else []
	if _status_row == null:
		if stats.is_empty():
			return
		_status_row = HBoxContainer.new()
		_status_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_status_row.alignment = BoxContainer.ALIGNMENT_CENTER
		_status_row.add_theme_constant_override("separation", 5)
		# Horizontal band across the top, below the nameplate (anchors in native Canvas units).
		_status_row.anchor_left = 0.16
		_status_row.anchor_right = 0.84
		_status_row.anchor_top = 0.135
		_status_row.anchor_bottom = 0.215
		_status_row.offset_left = 0.0
		_status_row.offset_top = 0.0
		_status_row.offset_right = 0.0
		_status_row.offset_bottom = 0.0
		_canvas.add_child(_status_row)

	for child in _status_row.get_children():
		child.queue_free()
	for si: StatusInstance in stats:
		_status_row.add_child(_make_status_pip(si))


func _make_status_pip(si: StatusInstance) -> Control:
	var sd: StatusData = si.data
	var pip := Panel.new()
	pip.custom_minimum_size = Vector2(32, 32)
	pip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = sd.color
	style.set_corner_radius_all(8)   # rounded square, to read distinctly from round charm pips
	style.set_border_width_all(3)
	style.border_color = Color(0.04, 0.04, 0.06, 0.9)
	pip.add_theme_stylebox_override("panel", style)

	# Prefer the status's art; fall back to its coloured glyph.
	var art := sd.icon()
	if art != null:
		var tex := TextureRect.new()
		tex.texture = art
		tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		tex.offset_left = 2; tex.offset_top = 2; tex.offset_right = -2; tex.offset_bottom = -2
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.add_child(tex)
	else:
		var glyph := Label.new()
		glyph.text = sd.glyph
		glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		glyph.add_theme_font_size_override("font_size", 19)
		glyph.add_theme_color_override("font_color", Color(0.99, 0.99, 1.0))
		glyph.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.75))
		glyph.add_theme_constant_override("outline_size", 3)
		glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.add_child(glyph)

	# The headline count, bottom-right: the stack count for a count-decay status (e.g. poison's
	# value), otherwise the remaining turns. A whole-combat status shows none.
	var primary: int = si.stacks if sd.decay == StatusData.DECAY_STACKS else si.remaining
	if primary > 0:
		pip.add_child(_pip_corner(str(primary), HORIZONTAL_ALIGNMENT_RIGHT, VERTICAL_ALIGNMENT_BOTTOM))
	# Stack count, top-left, for a timed status that also stacks intensity (count-decay already
	# shows its stacks as the headline above).
	if sd.decay != StatusData.DECAY_STACKS and si.stacks > 1:
		pip.add_child(_pip_corner("x%d" % si.stacks, HORIZONTAL_ALIGNMENT_LEFT, VERTICAL_ALIGNMENT_TOP))
	return pip


# A small corner number on a status pip (remaining duration / stack count).
func _pip_corner(text: String, h_align: int, v_align: int) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lbl.horizontal_alignment = h_align
	lbl.vertical_alignment = v_align
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	lbl.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.95))
	lbl.add_theme_constant_override("outline_size", 4)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


# The rich hover panel is the shared CardTooltip, so it matches everywhere a card is shown.
func _make_custom_tooltip(_for_text: String) -> Object:
	return CardTooltip.build(card_instance, _show_cost)


func set_selected(selected: bool) -> void:
	modulate = Color(0.65, 1.0, 1.5) if selected else Color.WHITE


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# Begin a potential long-press; a quick release fires `pressed` as before.
				_press_origin = mb.position
				_did_inspect = false
				if _hold_timer != null:
					_hold_timer.start()
			else:
				if _hold_timer != null:
					_hold_timer.stop()
				if not _did_inspect:   # a long-press already opened the inspector — don't also select
					pressed.emit()
				accept_event()
	elif event is InputEventMouseMotion:
		# Drift past the threshold means a drag/scroll, not an inspect — abandon the hold.
		if _hold_timer != null and not _hold_timer.is_stopped() \
				and (event as InputEventMouseMotion).position.distance_to(_press_origin) > LONG_PRESS_MOVE:
			_hold_timer.stop()


# Long-press fired with the finger held still: open the full-screen detail inspector. The
# pending release is then swallowed (see _gui_input) so the hold doesn't also select/play.
func _on_long_press() -> void:
	_did_inspect = true
	CardInspector.open(self, card_instance, _show_cost)


func _get_drag_data(at_position: Vector2) -> Variant:
	if not draggable or card_instance == null:
		return null
	# A real drag won the gesture — cancel any pending long-press inspect.
	if _hold_timer != null:
		_hold_timer.stop()
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
