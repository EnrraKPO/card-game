class_name CardUI
extends Control


signal pressed
# Unit drag lifecycle — any non-spell drag, from the hand (a PLACE) or fielded (a MOVE).
# The fight wires both to the board's cues through the Interaction session; the signal is
# inert on screens that don't listen (collection/deck/reward never connect it).
signal unit_drag_started(card_ui: CardUI)
signal unit_drag_ended(card_ui: CardUI)

# Drag-and-drop is a combat affordance (hand → board). Off by default — otherwise a touch
# tap that drifts a pixel starts a drag on screens where dragging means nothing; the
# surfaces that own a drag gesture (the hand's unit cards) turn it on.
var draggable: bool = false

# The card this view renders (the authoring data — the new core's live entities render
# through the fight screen; this view serves the collection, deck, and reward screens).
var card_data: CardData
var _show_cost: bool
# Charm pips shown on the left edge — handed by screens that render a DeckCard.
var charm_ids: Array = []
# Left-edge column of charm pips, built lazily (mirrors the composition chips on the right).
var _charm_col: VBoxContainer = null

# Touch card inspection: hover tooltips don't fire on a touchscreen, so a long-press
# (hold still ~0.4s) opens the full-screen CardInspector instead. Desktop keeps the
# hover tooltip and is left untouched (the timer only arms when a touchscreen exists).
# Both gesture windows are tunable (Tool 🎛 Tuning → UX, keys ux.hold.*) and read once per
# card at _ready. Fingers are never still: Godot starts a drag at ~10px of drift — well under
# what a real "hold" wobbles — so a tight tolerance meant most touch holds got eaten by an
# accidental drag and the inspector never opened. The hold TOLERATES drift up to the
# tolerance: a drag may start underneath it, and if the finger then settles, the timeout
# cancels that drag and opens the inspector anyway (see _on_long_press).
var _long_press_sec := 0.4
var _long_press_move := 44.0
var _hold_timer: Timer = null
var _press_origin := Vector2.ZERO   # viewport coords, to match InputEventMouse.global_position
var _did_inspect := false
var _touch_inspect := false
var _hold_dragging := false   # a drag started while the hold was still viable

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
@onready var _status_row: BoxContainer = %StatusRow   # authored under Canvas; position it in the editor
@onready var _border: Panel     = %Border
@onready var _canvas: Control   = $Canvas

# Status badge scene — its size/fonts/style are authored in the editor (status_pip.tscn).
const STATUS_PIP_SCENE := preload("res://scenes/status_pip.tscn")

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


static func create(data: CardData, show_cost: bool = false) -> CardUI:
	if _scene == null:
		_scene = load("res://scenes/card_ui.tscn")
	var ui: CardUI = _scene.instantiate()
	ui.card_data = data
	ui._show_cost = show_cost
	return ui


func _ready() -> void:
	_apply_asset_textures()
	_apply_label_style()
	_apply_border_style()
	_apply_ground_tint()   # a card can be dealt a tint before it is in the tree
	refresh()
	resized.connect(_apply_scale)
	# The selection self-poll: the pick is DERIVED, and with no pusher the view re-asks on a
	# slow beat so no stale ring can outlive the facts (see Selection).
	var poll := Timer.new()
	poll.wait_time = 0.75
	poll.autostart = true
	poll.timeout.connect(derive_presentation)
	add_child(poll)
	mouse_entered.connect(_on_pointer_entered)
	mouse_exited.connect(_on_pointer_exited)
	# The intent wait. One-shot and cancellable, hence a Timer node rather than an awaited
	# SceneTreeTimer: a card can be freed while the pointer is crossing it, and resuming a coroutine
	# on a dead object is an error, whereas a child Timer dies quietly with its card.
	_hover_delay = Timer.new()
	_hover_delay.one_shot = true
	_hover_delay.timeout.connect(func() -> void: _set_hovered(true))
	add_child(_hover_delay)
	# Defining _physics_process turns it ON by default; it must idle until a hover arms it.
	set_physics_process(false)
	_apply_scale()
	# Arm long-press inspection only on touch devices; desktop relies on the hover tooltip.
	_touch_inspect = DisplayServer.is_touchscreen_available()
	set_process(false)   # only polls while a drag is racing a pending hold (see _get_drag_data)
	if _touch_inspect:
		_long_press_sec = GameData.value_f("ux.hold.duration")
		_long_press_move = GameData.value_f("ux.hold.tolerance")
		_hold_timer = Timer.new()
		_hold_timer.one_shot = true
		_hold_timer.wait_time = _long_press_sec
		_hold_timer.timeout.connect(_on_long_press)
		add_child(_hold_timer)


# Uniformly scales the fixed-size Canvas to fill the CardUI's current size. Textures resample
# cleanly under that transform, but FONTS don't — glyphs rasterize once at their integer point
# size, so an upscaled canvas stretches glyph bitmaps and the text goes soft. The companion
# fix: whenever the canvas is displayed ABOVE native size, every label on it re-renders through
# a font duplicate whose `oversampling` matches the scale — denser rasterization at identical
# metrics, so layout never moves and the text is truly drawn at its on-screen size.
func _apply_scale() -> void:
	if _canvas == null or size.x <= 0.0:
		return
	var s := size.x / NATIVE_SIZE.x
	_canvas.scale = Vector2.ONE * s
	# Snap UP in half steps so text is never under-sampled and the cache stays small.
	var factor: float = maxf(1.0, ceilf(s * 2.0) / 2.0)
	if factor != _font_factor:
		_font_factor = factor
		_apply_font_oversampling()


# One shared duplicate of the theme's card font per oversampling factor (glyph caches are per
# resource, so a handful of duplicates serve every card in the game).
static var _oversampled_fonts: Dictionary = {}   # factor -> FontFile

var _font_factor := 1.0   # the factor currently applied to this card's labels


# Points every label under the Canvas at the font matching _font_factor (or back at the plain
# theme font at 1.0). Called when the scale factor changes AND after refresh() — refresh
# rebuilds dynamic labels (composition chips, status pips) that must inherit the factor too.
func _apply_font_oversampling() -> void:
	if _canvas == null:
		return
	for lbl: Label in _canvas.find_children("*", "Label", true, false):
		if _font_factor <= 1.0:
			lbl.remove_theme_font_override("font")
			continue
		var base := lbl.get_theme_default_font() as FontFile
		if base == null:
			continue
		if not _oversampled_fonts.has(_font_factor):
			var dup: FontFile = base.duplicate()
			dup.oversampling = _font_factor
			_oversampled_fonts[_font_factor] = dup
		lbl.add_theme_font_override("font", _oversampled_fonts[_font_factor])



func _apply_asset_textures() -> void:
	_name_bg.texture = NAMEPLATE
	_cost_bg.texture = BADGE_COST
	_spd_bg.texture = BADGE_SPEED
	_atk_bg.texture = BADGE_ATTACK
	_shield_bg.texture = BADGE_SHIELD
	_hp_bg.texture = BADGE_HEALTH
	# Per-card material: the fill level differs card to card, so the shader params can't be shared.
	var mat := ShaderMaterial.new()
	mat.shader = HEALTH_BADGE_SHADER
	_hp_bg.material = mat


# The health badge is the health gauge (see health_badge.gdshader): the heart drains top-down and
# recolours as the unit bleeds out, so "is this thing nearly dead?" is answerable without knowing
# its total — which is exactly what a board full of strangers won't tell you. The total itself is
# no longer written on the card at all; it lives in the inspector's stat column (CardTooltip).
const HEALTH_BADGE_SHADER := preload("res://assets/ui/cards/health_badge.gdshader")

# The two thresholds the whole readout is built on — the heart's colour ramp is anchored to the
# same stops the number's colour steps at, so the badge and its number never disagree.
const HEALTH_WARN := 2.0 / 3.0
const HEALTH_CRIT := 1.0 / 3.0

# Heart tints at full / warn / crit, interpolated between (the number steps, the art slides).
const HEALTH_RAMP_FULL := Color(0.32, 0.84, 0.34)
const HEALTH_RAMP_WARN := Color(0.96, 0.78, 0.18)
const HEALTH_RAMP_CRIT := Color(0.95, 0.16, 0.13)

const HEALTH_NUM_OK := Color(0.97, 0.95, 0.86)     # the shared badge-number colour
const HEALTH_NUM_WARN := Color(1.0, 0.85, 0.25)
const HEALTH_NUM_CRIT := Color(1.0, 0.30, 0.24)


# Feeds the badge-as-gauge from the live instance. Called from refresh.
func _refresh_health_badge() -> void:
	# The authoring view: a card at rest is whole — the gauge reads full and recolours only
	# in a live fight, which renders through the fight screen now.
	var ratio := 1.0
	var tint: Color
	if ratio >= HEALTH_WARN:
		tint = HEALTH_RAMP_WARN.lerp(HEALTH_RAMP_FULL,
			(ratio - HEALTH_WARN) / (1.0 - HEALTH_WARN))
	elif ratio >= HEALTH_CRIT:
		tint = HEALTH_RAMP_CRIT.lerp(HEALTH_RAMP_WARN,
			(ratio - HEALTH_CRIT) / (HEALTH_WARN - HEALTH_CRIT))
	else:
		tint = HEALTH_RAMP_CRIT
	var mat := _hp_bg.material as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("fill", ratio)
		mat.set_shader_parameter("tint", tint)
	var num := HEALTH_NUM_OK
	if ratio < HEALTH_CRIT:
		num = HEALTH_NUM_CRIT
	elif ratio < HEALTH_WARN:
		num = HEALTH_NUM_WARN
	_hp_lbl.add_theme_color_override("font_color", num)


func _apply_label_style() -> void:
	var labels := [_name_label, _cost_lbl, _spd_lbl, _atk_lbl, _shield_lbl, _hp_lbl]
	for label: Label in labels:
		label.add_theme_color_override("font_color", Color(0.97, 0.95, 0.86))
		label.add_theme_color_override("font_outline_color", Color(0.02, 0.02, 0.04, 1.0))
		label.add_theme_constant_override("outline_size", 6)
	var numbers := [_cost_lbl, _spd_lbl, _atk_lbl, _shield_lbl, _hp_lbl]
	for num: Label in numbers:
		if UIScale.is_compact():
			num.add_theme_font_size_override("font_size", 36)
		else:
			num.add_theme_font_size_override("font_size", 30)

	_name_label.add_theme_font_size_override("font_size", 22)
	_shield_lbl.add_theme_color_override("font_color", Color(0.58, 0.86, 1.0))


# The card's rounded corner, in NATIVE canvas units (the 260×340 Canvas is only ever scaled, so one
# number holds at every card size). Owned here because the border stroke draws the card's outline —
# anything that has to follow that outline reads it from here rather than guessing a radius.
const CORNER_RADIUS := 6


func _apply_border_style() -> void:
	var is_king := card_data != null and card_data.is_king
	var is_building := card_data != null and card_data.is_building()
	var style   := StyleBoxFlat.new()
	style.bg_color = Color.TRANSPARENT
	if is_king:
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
	style.set_corner_radius_all(CORNER_RADIUS)
	_border.add_theme_stylebox_override("panel", style)



# ── Phantom: a card that isn't real ─────────────────────────────────────────────
# THE treatment for a card the player is being SHOWN rather than given — a projection of what would
# land, what a pairing would produce, what a drag would drop. Desaturated, brightened and biased
# cool, all in one move, by laying a bright cool near-white WASH over the finished card as its last
# child: it lands above the art AND the badges and recolours them together, and it costs no shader
# (a per-node shader blanks the card's clipped, COVER-fit art node).
#
# The wash's alpha is how far the card is MIXED toward that colour, NOT transparency: a phantom card
# stays fully opaque, so whatever sits behind it never bleeds through and the two read as separate
# things instead of one muddled overlap. Callers wanting a different distance pass their own colour.
#
# The card REMEMBERS it is a phantom (is_phantom), so the treatment follows it wherever the card
# goes next — inspect a phantom and the inspector's enlarged copy is a phantom too, with no caller
# threading the fact through by hand.
# The treatment is a COLOUR TRANSFORM of the card's own pixels — lower saturation, raise brightness,
# tilt the hue cool (see phantom.gdshader) — not a tinted sheet laid over the card. That distinction
# is the whole design: a transform runs per drawn pixel and passes alpha through, so it lands on
# exactly what the card draws and nothing else. A sheet needs a SHAPE, and a card has no rectangular
# one — its frame art is inset from its rect with generous rounded corners, while its speed and
# attack badges hang OUTSIDE that rect. Every rectangle is wrong in both directions at once.
#
# Hung on the Canvas with the whole subtree set to use_parent_material, so frame, art, badges,
# glyphs and pips all transform together through one material.
const PHANTOM_SHADER := preload("res://assets/ui/shaders/phantom.gdshader")
var _phantom_mat: ShaderMaterial = null
# ── The ground's light (see SlotUI's ground layer) ──────────────────────────────
# The tint a claimed ground casts on whoever stands in it, handed here by the slot and
# multiplied over the ART ALONE (self_modulate on the art node): the stat badges are UI, not
# scenery, and stay unlit. A separate axis from the phantom shader and the root modulate
# (dim, exhaust, selection), so this composes with every one of them instead of fighting for
# the same property — the documented failure mode of every brightness cue here.
var _ground_tint := Color.WHITE


func set_ground_tint(c: Color) -> void:
	if _ground_tint == c:
		return
	_ground_tint = c
	_apply_ground_tint()


func _apply_ground_tint() -> void:
	# By name, not the @onready ref: slots dress cards that are built but not yet in the tree.
	var art: CanvasItem = _art if _art != null else get_node_or_null("%Art") as CanvasItem
	if art != null:
		art.self_modulate = _ground_tint


# ── The status badge row (injected — see StatusPipView) ─────────────────────────
# The card renders whatever status views were last injected (R4: the widget never asks who
# holds what) — one pip per view in the authored StatusRow, plus the aura ring and the
# aura_<id> library VFX for views that declare one. Whoever composes the views (CardViewModel
# for a fielded unit) re-injects when the facts move.
var _status_views: Array[StatusPipView] = []
# The status-aura overlay (see _refresh_aura) — created lazily, only for cards whose views
# declare an aura (e.g. a Barrier-style "protected" ring).
var _aura: Panel = null


func set_status_views(views: Array[StatusPipView]) -> void:
	_status_views = views
	_refresh_statuses()


func status_views() -> Array[StatusPipView]:
	return _status_views


# Fills the StatusRow node (authored in card_ui.tscn — move/anchor it in the editor) with one
# pip per view: its icon (or coloured glyph), count, and the status's own hover tooltip.
func _refresh_statuses() -> void:
	if _status_row == null:
		return
	for child in _status_row.get_children():
		_status_row.remove_child(child)
		child.queue_free()
	for view: StatusPipView in _status_views:
		var pip := STATUS_PIP_SCENE.instantiate() as StatusPip
		pip.setup(view)
		_status_row.add_child(pip)
	_refresh_aura()
	_sync_status_auras()


# The "a status just landed" flash on the badge row — the newest pip blooms in its own
# colour (StatusPip.flash_applied). Told by the presenter's status_applied cue; the row's
# CONTENT still arrives only by injection (set_status_views), this only flashes what is
# already worn. DECLARED APPROXIMATION (journaled): the cue carries no status identity
# (named visual + recipient + magnitude is the whole shape), so a stack landing on an
# EXISTING status flashes the row's last pip, not necessarily the stacked one — the old
# find-by-id flash needs the cue shape to grow an identity, the same contract limit as
# the missing source on the beats.
func flash_status_applied() -> void:
	if _status_row == null or _status_row.get_child_count() == 0:
		return
	var pip := _status_row.get_child(_status_row.get_child_count() - 1) as StatusPip
	if pip != null:
		pip.flash_applied()


# Library auras riding the card while statuses are held (aura_<status_id> entries, sustained):
# attached on gain, detached on loss — a loss the player can see also gets the expiry sound.
# Statuses without an aura entry still get the sound; the pip vanishing is their visual.
var _held_status_auras: Dictionary = {}


func _sync_status_auras() -> void:
	var present: Dictionary = {}
	for view: StatusPipView in _status_views:
		present[view.id] = true
	for sid: String in present:
		if not _held_status_auras.has(sid) and VFXData.get_vfx("aura_" + sid) != null:
			Vfx.attach("aura_" + sid, self)
		_held_status_auras[sid] = true
	for sid: String in _held_status_auras.keys():
		if not present.has(sid):
			_held_status_auras.erase(sid)
			Vfx.detach("aura_" + sid, self)
			Sfx.play("status_expire")


# A persistent "protected"-style frame over the whole card while an aura-declaring view is
# held, in that status's color: a thick soft ring plus a faint tint wash, so the protection
# reads at a glance without hunting for the pip. Lazily created; appears/disappears with the
# view on the next injection.
func _refresh_aura() -> void:
	var aura_view: StatusPipView = null
	for view: StatusPipView in _status_views:
		if view.aura:
			aura_view = view
			break
	if aura_view == null:
		if _aura != null:
			_aura.visible = false
		return
	if _aura == null:
		_aura = Panel.new()
		_aura.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_canvas.add_child(_aura)
		_aura.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var c := aura_view.color
	var style := StyleBoxFlat.new()
	style.bg_color = Color(c.r, c.g, c.b, 0.10)
	style.border_color = Color(c.r, c.g, c.b, 0.85)
	style.set_border_width_all(7)
	style.set_corner_radius_all(10)
	style.set_expand_margin_all(4.0)
	_aura.add_theme_stylebox_override("panel", style)
	_aura.visible = true


var is_phantom := false



func set_phantom(on: bool) -> void:
	is_phantom = on
	# Resolved by name, not through the @onready ref: set_phantom is legitimately called on a card
	# that is built but not yet in the tree (the inspector dresses its copy before mounting it).
	var canvas: CanvasItem = _canvas if _canvas != null else get_node_or_null("Canvas") as CanvasItem
	if canvas == null:
		return
	if on and _phantom_mat == null:
		_phantom_mat = ShaderMaterial.new()
		_phantom_mat.shader = PHANTOM_SHADER
	canvas.material = _phantom_mat if on else null
	for n: CanvasItem in canvas.find_children("*", "CanvasItem", true, false):
		n.use_parent_material = on




# An inspected ENEMY unit's ability tokens are shown for information only — not castable.
# IGNORE blocks click/hover/long-press-inspect entirely; the dimmed alpha (distinct from
# set_exhausted's opaque grey) reads as "look, don't touch".
var _noninteractive: bool = false
func set_noninteractive() -> void:
	_noninteractive = true   # excludes this view from selection derivation (it owns its dim)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	modulate = Color(1.0, 1.0, 1.0, 0.62)


func refresh() -> void:
	if card_data == null:
		return
	_art.texture = card_data.image

	var is_spell := card_data.card_type == CardData.CardType.SPELL
	_frame.texture = FRAME_KING if card_data.is_king else (FRAME_SPELL if is_spell else FRAME_UNIT)
	_name_label.text  = card_data.display_name
	_cost_lbl.text    = str(card_data.cost)
	# The King isn't cast from hand for mana, so its cost badge is meaningless — hide it.
	var show_cost := not card_data.is_king
	_cost_bg.visible  = show_cost
	_cost_lbl.visible = show_cost
	_atk_lbl.text       = str(card_data.attack)
	_hp_lbl.text        = str(card_data.health)
	_spd_lbl.text       = str(card_data.speed)
	var shld            := card_data.shield
	_shield_lbl.text    = str(shld)
	_atk_bg.visible     = not is_spell
	_atk_lbl.visible    = not is_spell
	_shield_bg.visible  = not is_spell and shld > 0
	_shield_lbl.visible = not is_spell and shld > 0
	_hp_bg.visible      = not is_spell
	_hp_lbl.visible     = not is_spell
	if not is_spell:
		_refresh_health_badge()
	_spd_bg.visible     = not is_spell
	_spd_lbl.visible    = not is_spell
	_refresh_composition()
	_refresh_charms()
	_refresh_statuses()
	# The lines above rebuild dynamic labels (chips/pips) — re-point them at the current
	# oversampled font so an enlarged card's WHOLE text stays crisp (see _apply_scale).
	if _font_factor > 1.0:
		_apply_font_oversampling()
	# NO NATIVE TOOLTIP ON A CARD, so nothing is assembled for one here any more. A card's details
	# are CardHoverPanel's now — it opens the rich CardTooltip on the same latch as the hover ring,
	# beside the card instead of at the cursor. What used to be built here was the plain-text
	# fallback (description + targeting line + rooted-building note, markup resolved to words); the
	# panel renders all three properly, icons included, and leaving tooltip_text set would pop a
	# second, plainer copy of the same words over it half a second later.
	# A phantom card re-hangs its treatment over whatever this rebuild just produced. The transform
	# reaches the subtree by flagging each node, so any node born after it was applied — the
	# composition chips and status pips built here, and in fact EVERY node when a caller dresses the
	# card before mounting it (CardInspector does) — would otherwise draw at full colour.
	if is_phantom:
		set_phantom(true)


# Attaches per-badge hover tooltips to THIS card's own stat badges — a stat→text map keyed
# "health", "shield", "attack", "speed". Used only by the CardInspector's enlarged card, so
# pointing at a number explains it (and NOT the board cards, which show the whole-card tooltip).
# Deferred to _ready when necessary: CardUI.create returns before _ready runs, so the @onready
# badge refs are null at build time — applying then would silently no-op (the bug that made the
# card's own full tooltip leak through instead).
var _pending_stat_tips: Dictionary = {}

func set_stat_tooltips(texts: Dictionary) -> void:
	_pending_stat_tips = texts
	if is_node_ready():
		_apply_stat_tooltips()
	else:
		ready.connect(_apply_stat_tooltips, CONNECT_ONE_SHOT)


# A StatBadgeTip overlay laid over each badge catches the hover and provides the rich, colour-named
# tooltip; the badge's number label is made mouse-transparent so the hover lands on the overlay
# beneath. Owning the tooltip per-badge also stops the lookup from walking up to the card root
# (whose tooltip is the whole-card panel). StatBadgeTip.attach routes through UIScale.tip, so touch
# stays clean. Each tip is a {title, color, body} from CardTooltip.stat_tips.
func _apply_stat_tooltips() -> void:
	var badges := {
		"health": [_hp_bg, _hp_lbl],
		"shield": [_shield_bg, _shield_lbl],
		"attack": [_atk_bg, _atk_lbl],
		"speed":  [_spd_bg, _spd_lbl],
	}
	for stat: String in badges:
		if not _pending_stat_tips.has(stat):
			continue
		var bg: Control = badges[stat][0]
		var lbl: Control = badges[stat][1]
		var tip: Dictionary = _pending_stat_tips[stat]
		if bg != null:
			StatBadgeTip.attach(bg, tip["title"], tip["color"], tip["body"])
		if lbl != null:
			lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE


func _refresh_composition() -> void:
	for child in _comp_row.get_children():
		child.queue_free()
	for el: String in card_data.elements:
		_comp_row.add_child(_make_comp_chip(el, true))
	for pc: String in card_data.chess_pieces:
		_comp_row.add_child(_make_comp_chip(pc, false))


# Static so the inline-text chip bake (dev/_chip_bake.gd) can render THE chip, not a replica.
static func _make_comp_chip(comp_id: String, is_element: bool) -> Control:
	var info: Dictionary = COMP_VISUALS.get(
		comp_id, { "color": Color(0.5, 0.5, 0.5), "letter": "?", "text": Color.WHITE })

	# Sizes are in native Canvas units (260x340); they scale down with the card.
	var chip := Panel.new()
	chip.custom_minimum_size = Vector2(36, 36)
	# Shrink on both axes so the chip stays square whether CompRow is a row or column.
	chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UIScale.tip(chip, comp_id.capitalize())

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


const CHARM_PIP_PX := 34.0

func _make_charm_pip(charm_id: String) -> Control:
	# The charm draws its own face (art when it has any, the coloured letter chip when it doesn't) —
	# see CharmData.badge. This used to hand-roll the letter chip and never consult the art, which is
	# why charms with painted assets still showed a placeholder glyph on the card.
	var charm := CharmData.get_charm(charm_id)
	if charm != null:
		return charm.badge(CHARM_PIP_PX)
	# An id with no definition behind it (stale save, removed content) still holds its slot.
	var pip := Panel.new()
	pip.custom_minimum_size = Vector2(CHARM_PIP_PX, CHARM_PIP_PX)
	pip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	pip.size_flags_vertical   = Control.SIZE_SHRINK_CENTER
	pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.7, 0.7, 0.75)
	style.set_corner_radius_all(17)
	style.set_border_width_all(3)
	style.border_color = Color(0.04, 0.04, 0.06, 0.9)
	pip.add_theme_stylebox_override("panel", style)
	return pip

func build_details_panel() -> Control:
	if card_data == null:
		return null
	# The card's injected status views ride into the read (R4: the tooltip renders what the
	# card was handed, it never asks who holds what).
	return CardTooltip.build(card_data, _show_cost, 1.0, false, true, is_phantom,
			_status_views)


# Hand-affordance: a card the player can play RIGHT NOW wears a soft outer glow; one that
# can't sits 7% dimmer. The dim rides `_canvas.modulate` (all the card art hangs under
# Canvas), NOT the root `modulate` — so it composes multiplicatively with the root-level
# selection/exhaust tints instead of overwriting them. The glow is a COMPOSITED GlowFx (see
# GlowFx/SilhouetteBaker): it reads the card's true silhouette and radiates on the overlay
# layer, so it never clips (escapes the hand ScrollContainer) and is hollow over every child
# — badges and status pips stay fully visible. Idempotent: safe to call every mana change
# (Vfx.attach/detach de-dupe, so no re-bake churn).
# ── Playability: DERIVED, never stored ──────────────────────────────────────────
# The card OWNS the question "should I wear the play-me glow?" and answers it by consulting
# live facts through `playable_check` (injected by the Hand: parented in the hand row +
# input enabled + affordable). Nothing pushes glow state in from outside — callers only
# ask for a re-derive (refresh_playable) — so a stale caller can affect WHEN the question is
# asked, never what the answer is.
var playable_check: Callable   # func(CardUI) -> bool


# Installs the playability rule. Hand-spawned cards only — CardUI serves many non-combat
# screens whose cards must never be dimmed by a false verdict, so without an installed check
# refresh_playable does nothing at all.
func set_playable_check(cb: Callable) -> void:
	playable_check = cb
	refresh_playable()


func refresh_playable() -> void:
	if not playable_check.is_valid():
		return
	_apply_playable(bool(playable_check.call(self)))


# Presentation ONLY — the single place the glow/dim lands; the verdict always arrives through
# refresh_playable's derivation, never as externally pushed state.
func _apply_playable(playable: bool) -> void:
	if _canvas == null:
		return
	if playable:
		Vfx.attach("card_playable_glow", self)
		_canvas.modulate = Color.WHITE
	else:
		Vfx.detach("card_playable_glow", self)
		_canvas.modulate = Color(0.93, 0.93, 0.93)


# Sheds every HAND-BOUND presentation state: the play-me glow, the unaffordable dim. Called
# by SlotUI.set_card — the one door every card passes through on its way onto the board —
# because these states are facts about hand life ("affordable to play", "selected to place")
# that no fielded card can truthfully wear. Cleared at the door rather than by whoever played
# the card, so no play path can leak them.
func shed_hand_state() -> void:
	playable_check = Callable()
	Vfx.detach("card_playable_glow", self)
	if _canvas != null:
		_canvas.modulate = Color.WHITE   # neutral — neither the glow'd nor the dimmed hand look


# The one derived presentation left on this view: selection. The card ASKS Selection
# whether it is the pick and applies the answer — signals and reparents are only
# "re-check now" cues, and the applier is idempotent.
func derive_presentation() -> void:
	refresh_playable()
	_apply_selected(_pickable() and Selection.holds(subject()))


# The authority's move IS the re-check cue — without it the ring waits for the slow poll's
# next beat (up to 0.75s), which reads as lag on every click. The poll stays as the
# backstop for changes no signal announces (a freed pick, a reparent-shifted answer).
# Enter/exit rather than _ready: slots REPARENT cards as units move, and a connection
# left on a node outside the tree would error on the autoload's next emission.
func _enter_tree() -> void:
	if not Selection.changed.is_connected(_on_selection_moved):
		Selection.changed.connect(_on_selection_moved)


func _exit_tree() -> void:
	if Selection.changed.is_connected(_on_selection_moved):
		Selection.changed.disconnect(_on_selection_moved)


func _on_selection_moved(_subject: Variant) -> void:
	derive_presentation()


# HOW A CARD BEHAVES WHEN IT IS THE PICK — its own behaviour, never handed to it.
#
# Nothing outside can call this: the card ASKS Selection whether it is the pick (see
# derive_presentation) and applies the answer here. That is what makes re-picking harmless — the
# answer is the same as last time, this returns immediately, and there is no transition for a
# teardown to race. The old public setter was the bug: every caller was a chance to be told twice,
# and each telling rebuilt the visual, with the previous one's teardown landing after its
# replacement and dragging the card's resting size up with it.
#
# The look is the canonical `highlight` (one entry in data/vfx/vfx.json, tuned in one place, worn
# identically by the forge): the card grows in place — its OWN transform, applied by itself — under
# an outline and glow drawn on the overlay, which only track it.
var _selected_now := false

# WHAT THIS VIEW IS A VIEW OF — the thing Selection names when this card is the pick.
#
# A card view normally stands for its CardData, and several views can stand for the same one
# (a unit's board card, its tray entry): naming the subject rather than the widget is what lets
# them agree without anyone syncing them. Screens whose cards stand for something else say so —
# the Decks screen's cards stand for a DECK, and its id survives the rebuild that frees the card,
# which a widget reference would not.
var view_subject: Variant = null

func subject() -> Variant:
	return view_subject if view_subject != null else card_data


# ── Hover: "the cursor is addressing me" ────────────────────────────────────────
# TWO cues, and only one of them is universal.
#
# THE RING is the answer everywhere, on every surface in the game — see HoverFx, which owns it and
# the arbitration with the selection outline. A card gets it on the board, in hand and in the
# ability tray alike, and so does an empty slot; the player learns one thing and it holds.
#
# THE LIFT is an opt-in flourish for ONE surface (see `lift_check`). It used to apply everywhere, and
# on the board that was a mistake worth writing down: POSITION IS NOT A FREE CHANNEL THERE. Where a
# card stands means something — it is a unit occupying a slot — and cards already move for real
# reasons (being played, repositioned, killed). Spending the most semantically loaded channel on the
# least meaningful event made a card finish a MEANINGFUL motion and immediately start a meaningless
# one, which is exactly what "it drops, then it lifts" is. In hand nothing is lost by moving a card,
# because a hand card stands nowhere; easing one proud of the fan is a real gesture about a real
# intent. So the lift lives where position is free and nowhere else.
#
# Not a state anyone declares — unlike the spotlight or the pick, "the cursor is on me" is the
# WIDGET's own fact, and two views of one card can be hovered independently (a unit's board card and
# its tray copy) and both be right. So this is the one presentation on CardUI that is NOT derived
# from anything shared, and it needs no board declaration and nothing to un-push.
#
# WHAT THE CARD IS DOING: pulling out of the row a little, the way you ease one card proud of a
# real hand before deciding to play it. Not a pop. The first version of this used EASE_OUT, which
# puts peak velocity on the very first frame — the card left its resting place at ~160px/s and then
# stopped 6px later, and a launch that fast promises a much longer journey than it delivers. That
# mismatch is what read as violent. EASE_IN_OUT starts and ends at zero velocity, so the card
# *begins to drift* instead of being flicked.
#
# RESPONSIVENESS IS ONSET, NOT DURATION — the correction that produced these numbers. What makes an
# object feel alive is that it starts moving on the same frame the cursor arrives; how long it then
# takes is a separate question, and answering both with one short duration is what made it snap.
# So: no delay before it starts, and four times as long to get there.
#
# Position and nothing else: glow is the selection's, gold the acting unit's, red the threat's, grey
# the spent unit's, and the OUTLINE is now hover's own everywhere (HoverFx arbitrates it with the
# selection's white one, so the two compose instead of colliding). Rotation would have been the other
# candidate and is banned — GlowFx._sync assumes none, so tipping a card would break every composited
# glow it wears.
# EVERY NUMBER HERE IS DATA — the `card_hover_lift` entry in data/vfx/vfx.json, tunable in the
# Tool's ✨ editor like any other look. The constants below are FALLBACKS for a missing entry, not
# the authority. (The easing deliberately is NOT a knob — see the entry's own explanation.)
const HOVER_RISE := 0.06     # of the card's own height, so it reads the same on a big hand card
const HOVER_IN := 0.28       # and a small tray one
const HOVER_OUT := 0.34      # slower out than in — settling back, not dropping
const HOVER_DELAY := 0.12    # intent wait before committing (see _on_pointer_entered)


# THE LIFT IS OPT-IN, AND THE SURFACE OPTS IN — not the card by guessing where it lives. A widget
# inspecting its own parent to decide how to behave is how per-surface forks rot: every new place a
# card can appear has to be remembered here, and the one nobody remembers gets the wrong answer
# silently. The hand installs the rule for the cards it deals (see Hand._spawn_hand_card) because the
# hand is the surface that owns the "cards in a hand" metaphor; everywhere else — board slots, the
# ability tray, the inspector, previews — a card stays exactly where it was put.
#
# ⚠ IT IS A RULE, NOT A FLAG, for exactly the reason `playable_check` is (see set_playable_check).
# A stored bool is a fact the card remembers about ITSELF, and a card outlives the surface that set
# it: the very node dealt into the hand is the node reparented into a board slot when it is played,
# so a latched `true` walked onto the board and kept bobbing there — a unit standing in its slot
# lifting out of it on hover, which is precisely the channel the board may not spend. The card must
# never carry an answer it can't re-derive; it ASKS, every time it matters, and the rule the hand
# installed answers from the live tree ("am I still parented in the hand row?"). Reparenting alone
# then changes the answer, with nobody left to remember to clear anything.
var lift_check: Callable   # func(CardUI) -> bool


# Whether THIS card, right now, stands on a surface where position is free to spend. Unset check
# (every non-hand card in the game) means no: the lift is opt-in and silence is a "no".
func _lifts() -> bool:
	return lift_check.is_valid() and bool(lift_check.call(self))


# The verdict LATCHED for the duration of one hover — asked when the hover commits, and obeyed by
# the paths that undo it. Not a second home for the fact: it is the same question, answered once so
# the rise and the fall can't be governed by two different answers. A card that lifted must run the
# hit test and drop again even if the rule flipped underneath it mid-hover; the alternative is a
# card left floating with nothing watching for the pointer to leave.
var _lift_now := false


func _hover_travel() -> float:
	return size.y * Vfx.param_of("card_hover_lift", "rise", HOVER_RISE)

var _hover_now := false

# Whether the pointer is resting on this card RIGHT NOW. THIS VIEW'S OWN ANSWER ABOUT ITS OWN RECT,
# which is the right scope for the ring and the lift — two views of one unit (its board card and its
# tray copy) can each be pointed at, and each is entitled to answer for itself.
func is_hovered() -> bool:
	return _hover_now


# ── THE HOVERED VIEW: one card, game-wide ───────────────────────────────────────────────────
# `_hover_now` above is a fact a view is genuinely the authority on. "WHICH view the pointer is
# addressing" is not — another card taking the pointer invalidates it, and the card it was taken from
# has no way to know. So it is not stored per-card at all. It lives here, once, and the details panel
# is a picture of it (see CardHoverPanel.follow).
#
# ⚠ THE ABSENCE OF THIS IS WHAT MADE HOVERING CARD-TO-CARD SHOW NOTHING. With the answer scattered
# across N private booleans, the panel had to be MESSAGED by cards — and then arbitrate which of them
# owned it, a question no one could answer while a panel was still pending. One fact, one owner, no
# arbitration.
static var _hovered_view: CardUI = null


# The card view the pointer is addressing, or null. Validity-checked, because the holder can be freed
# between the claim and the question (a unit dying under the cursor).
static func hovered_view() -> CardUI:
	return _hovered_view if is_instance_valid(_hovered_view) else null


# Claims or releases the title, and tells the panel — the ONLY place either happens.
#
# The release is conditional and that is not defensive arbitration, it is what makes the fact
# single-valued: a view that never held the title has nothing to give up. It is also what makes the
# PREDELETE path harmless. Every CardUI announces its own death here, and the details panel is FULL
# of CardUIs (its enlarged preview, an AbilityWidget per ability) — none of which were ever the
# hovered view, so none of them can disturb it. Under the old message-passing design those same
# children cancelled the next card's pending panel, which was the bug.
func _own_hover(on: bool) -> void:
	if on:
		_hovered_view = self
	elif _hovered_view == self:
		_hovered_view = null
	else:
		return   # not mine to release
	CardHoverPanel.follow(_hovered_view)

var _hover_rest := Vector2.ZERO
var _hover_rest_valid := false   # `_hover_rest` names a real floor (see _set_hovered)
var _hover_tw: Tween = null
var _hover_delay: Timer = null   # the intent wait (see _on_pointer_entered)


# A hover is only ever ANSWERED where a press would do something — `_pickable` already means
# exactly that ("something is wired to my press, or I stand in a slot"), so portraits, tooltips,
# the inspector's copy, a drag ghost and a landing phantom stay silent rather than advertising an
# interactivity they do not have. And touch has no hover at all: what Godot's emulated mouse leaves
# behind is a ghost cursor parked where you last tapped, which would leave a card floating for no
# reason (the same reasoning that gates tooltips — see UIScale.is_touch).
func _hoverable() -> bool:
	return _pickable() and not UIScale.is_touch()


# Rests the cursor on this card as far as the cue is concerned, and LATCHES it: the render harness
# has no real pointer (warp_mouse does not reach a SubViewport), so the per-frame hit test would
# answer "not on the card" and undo the hover on the next frame. Exactly the problem, and the same
# fix, as TurnOrderStrip.point_at.
var _hover_forced := false

func force_hover(on: bool) -> void:
	_hover_forced = on
	_set_hovered(on)


# ── Hover intent ────────────────────────────────────────────────────────────────
# A pointer crossing a row on its way somewhere else is not hovering the cards it passes over, and
# a cue that answers every crossing produces a wake of half-started movements behind the cursor.
# So the card waits a beat before committing, and DOES NOT MOVE AT ALL while it waits — a cancelled
# intent must leave no trace, or the flutter is merely smaller instead of gone.
#
# This is the one place a delay belongs. Once the card has decided you meant it, the motion itself
# still begins on that very frame — the wait is about reading intent, not about being slow to react,
# and the two must not be confused (the first version of this cue confused them the other way).
#
# `mouse_exited` is TRUSTWORTHY HERE and nowhere else: during the wait the card has not moved, so an
# exit really is the pointer leaving. Once lifted, the card has moved out from under the pointer and
# leaving becomes the hit test's job (see _physics_process).
func _on_pointer_entered() -> void:
	if not _hoverable() or _hover_now:
		return
	var wait := Vfx.param_of("card_hover_lift", "delay_secs", HOVER_DELAY)
	if wait <= 0.0:
		_set_hovered(true)
		return
	_hover_delay.start(wait)


func _on_pointer_exited() -> void:
	if not _hover_now:
		_hover_delay.stop()   # cancels a PENDING intent
		return
	# A card that DOESN'T lift never moves out from under the pointer, so Godot's exit means what it
	# says and is the whole story: no hit test, no hysteresis, no per-frame work. Only the lifting
	# card has to ignore this and hit-test instead (see _physics_process for why).
	if not _lift_now:
		_set_hovered(false)


func _set_hovered(on: bool) -> void:
	if on and not _hoverable():
		return
	if not on and _hover_delay != null:
		_hover_delay.stop()   # a pending intent must not fire after the hover has ended
	if on == _hover_now:
		return
	_hover_now = on
	# THE ONE PLACE THE RULE IS ASKED. On the way in it decides whether this hover moves the card at
	# all; on the way out the latched answer stands, so a hover that lifted always lowers.
	if on:
		_lift_now = _lifts()
	# The near-subliminal hover tick, on the shared card class so every card everywhere whispers
	# the same way. It rides THIS applier rather than its own signal so the sound and the movement
	# are one cue with one set of rules — the sound used to fire on every card view in the game,
	# including the ones no press can reach.
	if on:
		Sfx.play("card_hover")
	# THE RING, on every surface — the half of this cue that is not optional.
	_apply_hover_outline()
	# THE HOVERED VIEW, and through it the details panel. On the same latch as the ring, so a view too
	# inert to wear the ring is too inert to explain itself and the two can never disagree about which
	# card the pointer is addressing. The panel is not told to open or close — it is a picture of the
	# fact this line sets (see _own_hover).
	_own_hover(on)
	# THE LIFT, only where position is free to spend (see `lift_check`). Leaving early here means a
	# board card never records a floor, never claims `position` and never runs the per-frame hit test
	# — and `mouse_exited` is trustworthy for it precisely because it does not move (the oscillation
	# the hit test exists to prevent is caused by the card sliding out from under the pointer).
	if not _lift_now:
		return
	if _hover_tw != null and _hover_tw.is_valid():
		_hover_tw.kill()
	if on and not _hover_rest_valid:
		# THE FLOOR IS RECORDED ONCE AND HELD until the card is actually home again — not on every
		# entry. Swiping in and out fast re-enters while the drop is still in flight, and sampling
		# `position` then treats a card that is still 9px up as if that were the floor, so the next
		# lift targets 9px higher: "move up by this much" instead of "move onto this position", and
		# it creeps a little further every time. Exactly the accumulation HighlightFx.set_grown's own
		# comment describes for the selection grow, arrived at by the same mistake.
		#
		# `_hover_rest_valid` is cleared only where the card is known to be at rest: when the drop
		# completes (_hover_settle) or when a reparent hands it to a new layout.
		_hover_rest = position
		_hover_rest_valid = true
	# The cue MOVES THE CARD OUT FROM UNDER THE CURSOR, so it cannot be driven by mouse_exited: the
	# rising card's own bottom edge passes the stationary pointer, Godot reports a legitimate exit,
	# the card drops, which puts it back under the pointer, which enters again. That oscillation is
	# the "snaps back instead of staying up" in the hand. Leaving is therefore HIT-TESTED per frame
	# against the union of where the card is and where it rests — the same answer other hover owners and
	# TurnOrderStrip reached for the same reason (see their own notes on not trusting enter/exit).
	set_physics_process(on)
	var to := _hover_rest - Vector2(0.0, _hover_travel()) if on else _hover_rest
	if not is_inside_tree():
		position = to
		return
	var secs := Vfx.param_of("card_hover_lift", "rise_secs" if on else "fall_secs",
			HOVER_IN if on else HOVER_OUT)
	_hover_tw = create_tween()
	_hover_tw.tween_property(self, "position", to, secs) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if not on:
		_hover_tw.finished.connect(_hover_settle)


# Ends the hover when the pointer leaves the card's OWN ground — the union of its lifted rect and
# its resting one, so the strip of screen the card vacated by rising still counts as "on the card".
# Physics rather than idle process: _process is owned by the long-press drift check, which calls
# set_process(false) when it ends and would silently switch this off with it.
func _physics_process(_delta: float) -> void:
	if not _hover_now:
		set_physics_process(false)
		return
	if _hover_forced:
		return
	if not is_inside_tree() or not is_visible_in_tree():
		_set_hovered(false)
		return
	# Layout moved us while we were up (a card drawn or played into the same row re-sorts it). The
	# position we have just been handed IS the new resting place, so adopt it and lift again from
	# there — rather than dropping back to a remembered spot the card no longer belongs in. Checked
	# only once the tween has finished, since mid-tween the position is legitimately in motion.
	if _hover_tw == null or not _hover_tw.is_valid():
		var parked := _hover_rest.y - _hover_travel()
		if absf(position.y - parked) > 0.5:
			_hover_rest.y = position.y
			position.y = _hover_rest.y - _hover_travel()

	var here := get_global_rect()
	var lift := (_hover_rest.y - position.y) * get_global_transform().get_scale().y
	var ground := here.merge(Rect2(here.position + Vector2(0.0, lift), here.size))
	if not ground.has_point(get_global_mouse_position()):
		_set_hovered(false)


# Hands this card's position back to its slot once the drop finishes — cheap insurance against
# drift, and scoped to THIS card.
#
# ⚠ IT MUST NOT TOUCH THE PARENT. This used to call `queue_sort()` when the parent was a Container,
# to re-place a hand card whose layout had moved mid-hover. A sort re-places EVERY child, so the
# card you just LEFT reached the end of its 340ms drop and flattened the card you had already moved
# ON TO. That is why the snap only ever happened when swiping card-to-card, never on a first hover
# or after leaving the hand entirely — and never on the board, where this branch re-anchors one card
# and speaks for nobody else. A cue for one widget may not write another widget's layout.
func _hover_settle() -> void:
	if _hover_now:
		return                     # re-entered during the drop; the new lift owns the position
	# The drop finished, so the card IS home — and only now may the recorded floor be forgotten.
	# Forgetting it any earlier is what let a fast in-and-out sample a still-rising card as its rest.
	_hover_rest_valid = false


# A reparent moves the card to a layout that will place it itself — drop the claim without
# touching the position, or the old parent's rest would be restored inside the new one.
func _drop_hover_claim() -> void:
	if _hover_tw != null and _hover_tw.is_valid():
		_hover_tw.kill()
	_hover_now = false
	_lift_now = false              # the next hover asks the rule again, under the new parent
	_apply_hover_outline()         # the ring belongs to a hover that this reparent has just ended
	_hover_rest_valid = false      # the new layout will place it; the old floor means nothing here
	set_physics_process(false)
	if _hover_delay != null:
		_hover_delay.stop()


# ── The ring ────────────────────────────────────────────────────────────────────
# The one ring for "this is the one being addressed" — the cursor resting on this card.
func _apply_hover_outline() -> void:
	HoverFx.apply(self, _hover_now)


func _apply_selected(picked: bool) -> void:
	if picked == _selected_now:
		return
	_selected_now = picked
	# The grow factor is NAMED, not inherited from whatever effect happens to be riding this card.
	# A combat card can wear several HighlightFx entries at once (the turn-order spotlight sits on
	# it while the strip is read), they all share one grow slot on the widget, and the last one to
	# attach wins it — so a pick made while another entry was attached grew by that entry's factor
	# instead of the selection's. The pick's grow belongs to the `highlight` entry; say so.
	HighlightFx.set_grown(self, picked, Vfx.param_of("highlight", "scale", 1.15))
	if picked:
		Vfx.attach(HighlightFx.ENTRY, self)
	else:
		Vfx.detach(HighlightFx.ENTRY, self)
	# A pick made WHILE the pointer is resting here builds a fresh Highlight with its white outline at
	# full width, which silently undoes the hover's claim on the outline channel. The mute lives in
	# the effect, so it has to be re-stated after anything that replaces the effect.
	_apply_hover_outline()


# WHEN THE PRESS ISN'T THE CARD'S TO TAKE — a surface that answers for the card it wraps.
#
# `_pickable` below reads the wiring to decide whether a view is live, which is right wherever the
# card itself is the thing pressed. The Forge is not that: every deck card there is wrapped in a
# ForgeDragItem that takes the press on MOUSE_FILTER_STOP and starts the drag session (the screen
# owns the follower, the beam and the drop resolve), so the card underneath has nothing wired to it
# and stands in no slot — and so read as inert, with no hover ring and no details panel, while being
# fully draggable, tappable and inspectable. The proxy was wrong, not the card.
#
# ⚠ A RULE, NOT A FLAG, for exactly the reason `lift_check` is one (see its note). The very node a
# surface dressed can be reparented onto another — so the card must never carry a latched answer it
# cannot re-derive. It ASKS the live tree every time it matters, and reparenting alone then changes
# the answer with nobody left to remember to clear anything.
var interactive_check: Callable   # func(CardUI) -> bool


# Whether this VIEW is one the player can pick at all. Structural, not a flag to be
# maintained: a view is pickable if a press on it is wired to anything, or if the surface
# it stands on says it answers presses for it (see interactive_check). Portraits,
# tooltips, and the inspector's copy are views of a card that nobody can click — so they
# show no pick, even while the card they depict IS the pick.
func _pickable() -> bool:
	return not _noninteractive \
			and (not pressed.get_connections().is_empty()
				or (interactive_check.is_valid() and bool(interactive_check.call(self))))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# Begin a potential long-press; a quick release fires `pressed` as before.
				_press_origin = mb.global_position
				_did_inspect = false
				if _hold_timer != null:
					_hold_timer.start()
			else:
				_end_hold()
				if not _did_inspect:   # a long-press already opened the inspector — don't also select
					pressed.emit()
				accept_event()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			# The desktop path to the in-depth view (touch reaches it via long-press).
			CardInspector.open(self, card_data, _show_cost, is_phantom)
			accept_event()
	elif event is InputEventMouseMotion:
		_check_hold_drift((event as InputEventMouseMotion).global_position)


# Drift past the tolerance means a real drag/scroll, not an inspect — abandon the hold.
func _check_hold_drift(where: Vector2) -> void:
	if _hold_timer != null and not _hold_timer.is_stopped() \
			and where.distance_to(_press_origin) > _long_press_move:
		_end_hold()


# Once a drag is in flight the motion events go to the drag machinery, not to _gui_input, so
# the drift check has to poll instead. Only runs while a tolerated drag is pending.
func _process(_delta: float) -> void:
	_check_hold_drift(get_viewport().get_mouse_position())


func _end_hold() -> void:
	_hold_dragging = false
	set_process(false)
	if _hold_timer != null:
		_hold_timer.stop()


# Long-press fired with the finger settled inside the tolerance: open the full-screen detail
# inspector. If a drag had already started under the tolerance it loses the gesture and is
# cancelled here. The pending release is then swallowed (see _gui_input) so the hold doesn't
# also select/play.
func _on_long_press() -> void:
	_did_inspect = true
	var was_dragging := _hold_dragging
	_end_hold()
	if was_dragging:
		get_viewport().gui_cancel_drag()
	Sfx.play("card_inspect_open")
	CardInspector.open(self, card_data, _show_cost, is_phantom)


# ── The menace read ─────────────────────────────────────────────────────────────
# "This unit will strike the previewed pivot": the red outer glow plus a pulsing flare on
# the Attack badge — one derived verdict, one applier; the change-guard makes re-derivation
# free (repeated same-verdict calls don't churn the tween or the glow bake).
var _threat_on: bool = false
var _threat_tw: Tween = null   # looping pulse on the Attack badge while flagged


func set_threat_highlight(on: bool) -> void:
	if on == _threat_on:
		return
	_threat_on = on
	if on:
		Vfx.attach("attack_target_glow", self)
	else:
		Vfx.detach("attack_target_glow", self)
	if _atk_bg == null or not is_instance_valid(_atk_bg):
		return
	if _threat_tw != null and _threat_tw.is_valid():
		_threat_tw.kill()
		_threat_tw = null
	# Pulse between a SUSTAINED warm tint and a hotter peak — never back to plain white, so
	# the badge always reads as flagged (a dip to white would look like the highlight blinked
	# off). The badge art is ALREADY red, so a red tint barely reads — pulse toward a bright
	# warm FLARE (over-bright, gold-white) that visibly lights the badge up.
	var has_lbl := _atk_lbl != null and is_instance_valid(_atk_lbl)
	var warm := Color(1.7, 1.15, 0.8) if on else Color.WHITE
	var hot := Color(2.6, 2.2, 1.3)
	_atk_bg.modulate = warm
	if has_lbl:
		_atk_lbl.modulate = warm
	# Bump the badge 10% larger while flagged — icon AND number about their shared centre so
	# they scale as one rigid unit. Sustained; reset to authored size on clear so the fixed
	# Canvas layout is never permanently disturbed.
	var scl := Vector2(1.1, 1.1) if on else Vector2.ONE
	_atk_bg.pivot_offset = _atk_bg.size * 0.5
	_atk_bg.scale = scl
	if has_lbl:
		_atk_lbl.pivot_offset = (_atk_bg.position + _atk_bg.size * 0.5) - _atk_lbl.position
		_atk_lbl.scale = scl
	# The badge is part of the card's SHAPE, so a 10% bump really does change the silhouette —
	# say so, and let the glows decide whether it moved enough to matter.
	Vfx.shape_changed(self)
	if not on:
		return
	_threat_tw = create_tween().set_loops()
	_threat_tw.tween_property(_atk_bg, "modulate", hot, 0.55)
	if has_lbl:
		_threat_tw.parallel().tween_property(_atk_lbl, "modulate", hot, 0.55)
	_threat_tw.tween_property(_atk_bg, "modulate", warm, 0.55)
	if has_lbl:
		_threat_tw.parallel().tween_property(_atk_lbl, "modulate", warm, 0.55)


# The ghost copy of this card a DragGhost preview shows.
func make_ghost_view() -> CardUI:
	return CardUI.create(card_data, _show_cost)


func _get_drag_data(at_position: Vector2) -> Variant:
	if not draggable or card_data == null:
		return null
	# A drag beginning does NOT settle the gesture: while the finger is still inside the hold
	# tolerance the drag is provisional, and a completed hold takes it back.
	if _hold_timer != null and not _hold_timer.is_stopped():
		if get_viewport().get_mouse_position().distance_to(_press_origin) > _long_press_move:
			_end_hold()
		else:
			_hold_dragging = true
			set_process(true)
	unit_drag_started.emit(self)
	# The real card stays fully visible in place; the cursor carries a clearly-distinct ghost
	# copy (see DragGhost).
	set_drag_preview(DragGhost.make(self, at_position))
	return self


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# A card can be destroyed while the pointer is still on it — a unit dying under the cursor,
		# a hand rebuilt as a card is played — and a freed card emits no exit. Its details panel
		# would be left describing a card that is no longer on the board.
		#
		# Every CardUI runs this, including the ones nobody can point at, so it must say nothing
		# unless this view actually held the hover — which is exactly what _own_hover(false) checks.
		# It used to speak unconditionally, and the panel's OWN CardUI children (its preview, its
		# ability widgets) then cancelled the next card's pending panel as they were freed.
		_own_hover(false)
	elif what == NOTIFICATION_DRAG_END:
		modulate.a = 1.0   # a safety reset after any surface-owned drag (the Forge's)
		_end_hold()
		if draggable:
			unit_drag_ended.emit(self)
	elif what == NOTIFICATION_PARENTED:
		# A reparent (mounted, moved between layouts) changes the answers to the derived
		# questions. The hover lift is a claim on the position, and the position now
		# belongs to a different layout — release it rather than tweening the card back to
		# where it stood in the old one.
		_drop_hover_claim()
		# Reparenting destroyed any sustained Vfx attachment (Vfx.attach auto-detaches on
		# tree_exiting) while the widget-side guard flags survive — re-attach what the
		# flags say is worn, then re-derive.
		if _selected_now:
			Vfx.attach.call_deferred("highlight", self)
		derive_presentation.call_deferred()
