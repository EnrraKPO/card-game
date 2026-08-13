class_name CardUI
extends Control

signal pressed
signal spell_drag_started(card_ui: CardUI)
signal spell_drag_ended(card_ui: CardUI)
# Fielded-unit drag lifecycle (row >= 0, non-spell) — the board listens to run the autocast
# drag affordance (drop card filters + light valid targets). See CombatBoard.
signal unit_drag_started(card_ui: CardUI)
signal unit_drag_ended(card_ui: CardUI)

# Status badge scene — its size/fonts/style are authored in the editor (status_pip.tscn).
const STATUS_PIP_SCENE := preload("res://scenes/status_pip.tscn")

var card_instance: CardInstance
var _show_cost: bool
# Drag-and-drop is a combat affordance (hand → board). Off-combat cards (forge, rewards,
# deck views) set this false: otherwise a touch tap that drifts a pixel starts a drag
# instead of firing `pressed`, so selection silently fails on touchscreens.
var draggable: bool = true
# Left-edge column of charm pips, built lazily (mirrors the composition chips on the right).
var _charm_col: VBoxContainer = null
# True for a rook-generated token shown in the hand's "generated" zone; gives
# the card a distinct glowing frame and a tooltip naming its source building.
var is_generated: bool = false

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
var _threat_tw: Tween = null   # looping pulse on the Attack badge while flagged an incoming threat
@onready var _border: Panel     = %Border
@onready var _canvas: Control   = $Canvas
# The status-aura overlay (see _refresh_aura) — created lazily, only for cards that carry an
# aura-declaring status (e.g. Barrier's "protected" ring).
var _aura: Panel = null
# The idle "click me, I have an ability" cue (see _refresh_ability_cue) — a dim pulsing outline,
# created lazily, only for a fielded player unit with a currently offerable ability.
var _ability_cue: Panel = null
var _ability_cue_tween: Tween = null

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
	_apply_ground_tint()   # a card can be dealt a tint before it is in the tree
	refresh()
	resized.connect(_apply_scale)
	# The self-derivation poll (see derive_presentation): every card re-consults its own
	# situation on a slow beat, so no state can outlive the facts it derives from even if
	# every cue is missed. Outside combat (CombatContext.current == null, no playable_check)
	# each tick is a no-op.
	_presentation_poll = Timer.new()
	_presentation_poll.wait_time = PRESENTATION_POLL_SECS
	_presentation_poll.autostart = true
	_presentation_poll.timeout.connect(derive_presentation)
	add_child(_presentation_poll)
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
	_apply_flip()   # honour a facing set before the nodes existed (see set_flipped)
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


# ── Combat facing ────────────────────────────────────────────────────────────────
# During combat the two armies face across the board (player half on the left facing right, enemy
# half on the right facing left). By default a card's stat badges sit fixed (Attack on the left
# edge, Shield/Health on the right), so both armies read as parallel rather than facing off. Setting
# a card "flipped" mirrors its stat cluster horizontally, so its Attack faces the opponent and the
# two sides become mirror images across the centre line. Only the badge POSITIONS mirror — the
# numbers and icons inside each badge are moved, never flipped, so everything still reads normally.

var _want_flipped := false
var _flip_applied := false

# EVERY positioned overlay node mirrors as one rigid reflection — not just the stat badges. The
# original layout is collision-free, so its full mirror is too; mirroring only some badges would
# drop them onto the ones left in place (e.g. Shield onto the charm column, Cost onto the comp
# chips). Art/Frame/Border are full-rect and symmetric, so they're deliberately excluded (and the
# art must never mirror). `_charm_col` is built lazily and may be null here — callers skip nulls,
# and _refresh_charms mirrors it on creation if the flip is already applied.
func _flip_nodes() -> Array:
	return [_cost_bg, _cost_lbl, _name_bg, _name_label, _comp_row,
		_atk_bg, _atk_lbl, _spd_bg, _spd_lbl, _shield_bg, _shield_lbl,
		_hp_bg, _hp_lbl, _status_row, _charm_col]


# The stat-badge background textures — mirrored in place (flip_h) so their asymmetric art faces the
# same way as the reflected layout. Just the badge assets, not the labels or the illustration.
func _badge_bgs() -> Array:
	return [_cost_bg, _name_bg, _spd_bg, _atk_bg, _shield_bg, _hp_bg]


# Sets the card's combat facing. `flipped` mirrors the stat cluster to the opposite edge. Idempotent
# and order-independent: safe to call before _ready (the flip is applied in _ready) and to call
# repeatedly (e.g. when a unit is moved between slots) — it tracks the applied state, never toggling.
func set_flipped(flipped: bool) -> void:
	_want_flipped = flipped
	_apply_flip()


func _apply_flip() -> void:
	if _atk_bg == null:            # nodes not ready yet — _ready() will call this again
		return
	if _flip_applied == _want_flipped:
		return
	_flip_applied = _want_flipped
	for node: Control in _flip_nodes():
		if node != null:   # _charm_col is built lazily; skip until it exists
			_mirror_x(node)
	# Also reflect the badge ART itself (not just its position): the badge textures are asymmetric
	# (e.g. the speed wing, the attack blade), so after the cluster mirrors they'd point the wrong
	# way. flip_h reflects each badge texture in place; the number Labels are left alone so they
	# still read normally. The card illustration is deliberately NOT flipped.
	for bg: TextureRect in _badge_bgs():
		bg.flip_h = _want_flipped


# Reflects a control's horizontal placement across the Canvas's vertical centre, leaving its
# vertical placement and its contents untouched. Its own inverse, so re-calling toggles cleanly.
# Works in Canvas pixels pinned to a zero anchor rather than mirroring the anchors themselves: the
# Canvas is a fixed native size (never resized, only scaled — see _apply_scale), so pixel offsets
# are stable, and this sidesteps the anchor-crossing clamp that stretches a badge when its left
# anchor is pushed past its still-old right anchor mid-update.
func _mirror_x(node: Control) -> void:
	var w := NATIVE_SIZE.x
	var cur_left := node.anchor_left * w + node.offset_left
	var cur_right := node.anchor_right * w + node.offset_right
	node.anchor_left = 0.0
	node.anchor_right = 0.0
	node.offset_left = w - cur_right
	node.offset_right = w - cur_left


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
	var maximum := int(card_instance.get_attribute("max_health"))
	var have := clampi(card_instance.current_health, 0, maxi(maximum, 0))
	# A unit with no max (shouldn't happen, but a card mid-construction can) reads as full rather
	# than as a corpse.
	var ratio := 1.0 if maximum <= 0 else float(have) / float(maximum)
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
	style.set_corner_radius_all(CORNER_RADIUS)
	_border.add_theme_stylebox_override("panel", style)


# Marks this card as an ability-tray token view and refreshes its glowing frame.
# Tokens are INFORMATIONAL while the effect system is demolished — the activation flow
# returns with the rebuilt ActivatedEffect (TARGETING_DESIGN.md §7).
func set_generated() -> void:
	is_generated = true
	# An ENEMY unit's ability token is view-only — a fact of the token's OWN model (its
	# instance carries the holder's owner), derived here rather than pushed by the tray.
	if card_instance != null and card_instance.owner == 1:
		set_noninteractive()
	if _border != null:
		_apply_border_style()


# THE look of "spent" — shared, because the turn-order strip greys a tapped unit's entry with it
# too (see TurnOrderStrip._dress) and two definitions of tapped would drift apart.
const EXHAUST_TINT := Color(0.6, 0.6, 0.68)


# Dims a building whose attack was spent generating a card this round, so it
# reads as "tapped". Reset to normal at the start of the next round.
func set_exhausted(exhausted: bool) -> void:
	modulate = EXHAUST_TINT if exhausted else Color.WHITE


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
var is_phantom := false


# ── The ground's light on this unit (pushed by the SlotUI it stands on) ─────────────────────────
# A unit standing on burning ground is lit by it, so the ground MULTIPLIES its colour over the
# card's picture. `modulate` on a TextureRect IS a multiply, so no blend material is needed.
#
# ⚠ THE PICTURE ONLY, NEVER THE WHOLE CARD. This started as a multiply layer over the card's rect
# and was wrong twice over (user's call): the stat badges are the numbers read fastest in combat and
# are UI rather than scenery — a fire lighting the scene has no business recolouring them — AND they
# OVERFLOW the card's rect, so a rect-shaped tint cannot even cover them consistently. Tinting the
# art node sidesteps both: it is exactly the picture, whatever the badges do around it.
#
# `self_modulate`, not `modulate`: it touches this node's own drawing and nothing below it, and it
# is a channel with exactly ONE writer. The card's other tint appliers all ride `_canvas.modulate`
# or the root `modulate` (dim, exhaust, selection), so this composes with every one of them instead
# of fighting for the same property — the documented failure mode of every brightness cue here.
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


# Hand-affordance: a card the player can play RIGHT NOW wears a soft outer glow; one that can't
# sits 7% dimmer. The dim rides `_canvas.modulate` (all the card art hangs under Canvas), NOT the
# root `modulate` — so it composes multiplicatively with the root-level selection/exhaust tints
# instead of overwriting them. The glow is a COMPOSITED GlowFx (see GlowFx/SilhouetteBaker): it reads
# the card's true silhouette and radiates on the overlay layer, so it never clips (escapes the hand
# ScrollContainer) and is hollow over every child — badges and status pips stay fully visible.
# Idempotent: safe to call every mana change (Vfx.attach/detach de-dupe, so no re-bake churn).
# ── Playability: DERIVED, never stored ──────────────────────────────────────────
# The card OWNS the question "should I wear the play-me glow?" and answers it by consulting
# live facts through `playable_check` (injected by the Hand: parented in the hand row +
# selection enabled + affordable). Nothing pushes glow state in from outside — callers only
# ask for a re-derive (refresh_playable) — so a stale caller can affect WHEN the question is
# asked, never what the answer is. The card re-derives PROACTIVELY: on any reparent (played,
# moved — see NOTIFICATION_PARENTED) and on the presentation self-poll, so even a missed cue
# self-corrects within a beat instead of persisting until someone remembers it.
var playable_check: Callable   # func(CardUI) -> bool
var _presentation_poll: Timer = null

const PRESENTATION_POLL_SECS := 0.75


# Installs the playability rule. Hand-spawned cards only — CardUI serves many non-combat
# screens whose cards must never be dimmed by a false verdict, so without an installed check
# refresh_playable does nothing at all.
func set_playable_check(cb: Callable) -> void:
	playable_check = cb
	refresh_playable()


# ── Presentation derivation ─────────────────────────────────────────────────────
# EVERY combat presentation state the card can wear is DERIVED here from declared facts —
# CombatContext (selection / inspection / the preview world) and the card's own situation
# (parent slot, its instance's flags). Nothing outside pushes verdicts; signals are only
# "re-check now" cues, and the poll + reparent hooks make the derivation self-correcting.
# Each applier is idempotent, so re-deriving is always safe.
#
# Eligibility guards (they decide which states CAN apply, preventing the appliers — several
# share `modulate` — from stomping presentations owned by other contexts):
#   • selection: only a view the player can actually pick — see _pickable.
#   • board states (concealment / exhaust grey / threat glow): only a slot's OCCUPANT — a landing
#     phantom mounted in a slot is a projection, not the unit, and an attacker's lunge ghost hangs
#     off the combat root rather than a slot, so it can never conceal itself for being its own
#     stand-in.
func derive_presentation() -> void:
	refresh_playable()
	var slot := get_parent() as SlotUI
	if slot != null:
		set_flipped(slot.location != null and slot.location.side == 1)   # facing derives from which side's slot holds me
	# SELECTION, asked rather than told, and asked FIRST — before the combat-context guard below,
	# because a card is pickable on every screen that shows one, not just in combat. An ABILITY
	# view asks the ability question: it stands for "this ability, of this holder", never for a
	# card of its own — so it lights while its ability is the aimed sub-pick, and its holder's
	# board card (whose subject is the holder itself) never mistakes that pick for its own.
	var ctx := CombatContext.current
	# The SPOTLIGHT: something elsewhere on the screen is pointing at this unit (the turn-order
	# strip's hover — see CombatBoard.declare_spotlight). Deliberately NOT the selection treatment:
	# a pick is something the player did to this card, a spotlight is a question asked ABOUT it
	# somewhere else, and the answer is the TURN NUMBER — so the card only gets the shared hover ring
	# while the number badge takes the loud cue (see _apply_spotlight). Guarded to a
	# slot's real occupant like the other board states — a landing phantom or a lunge ghost is a
	# projection of the unit, not the unit being pointed at.
	var occupant: bool = card_instance != null and slot != null and slot.get_card() == self
	var spotlit: bool = ctx != null and occupant and ctx.is_spotlit(card_instance)
	# The whole activation order, written on the units themselves while the player reads the strip
	# (see CombatBoard.declare_turn_numbers). Same guard as the spotlight: a landing phantom or a
	# lunge ghost stands FOR a unit, it does not hold that unit's place in the round.
	_refresh_turn_number(ctx.turn_number(card_instance) if ctx != null and occupant else 0)
	# Ordered AFTER the number: the spotlight lights the plate, so the plate has to exist first.
	_apply_spotlight(spotlit)
	_apply_selected(_pickable() and Selection.holds(subject()))
	if ctx == null:
		return
	var tags: Array[Dictionary] = []
	if slot != null and slot.get_card() == self and card_instance != null:
		# Concealment first: it decides whether this view is on screen AT ALL, so it can't be
		# expressed by any of the tints below and none of them can overrule it.
		set_concealed(ctx.is_concealed(card_instance))
		set_exhausted(card_instance.attack_exhausted)
		var menacing := ctx.menaces_pivot(card_instance)
		set_threat_highlight(menacing)
		# The word for each visual cue, from the SAME verdict that lights the cue — so a tag can
		# never disagree with the glow/crosshair it explains. Both can apply at once (a unit that
		# attacks the pivot AND is the pivot's own victim wears both sets).
		#
		# NUKED (2026-08-13 ruling): each flag used to carry the ODDS of the exchange it names
		# (crit_taken / dodge_taken / crit_dealt / dodge_dealt), asked of the nuked single
		# writer. The naming flags survive; the odds went with the rolls.
		if ctx.is_pivot_target(card_instance):
			tags.append({"id": "current_target"})
		if menacing:
			tags.append({"id": "menacing"})
	_apply_tags(tags)


# ── The turn number, worn on the card ───────────────────────────────────────────
# While the player reads the turn-order strip, every listed unit says its own place in the round
# right where it stands. Big and central on purpose: it is a TRANSIENT reading aid, alive only for
# the length of the gesture that asked for it, so it may cover art the rest of the game needs — a
# discreet corner pip would just be a second thing to hunt for, which is the problem this solves.
# Styled from the strip's own constants so the tab in the list and the number on the board are
# visibly the same statement.
var _turn_plate: Panel = null
var _turn_lbl: Label = null
var _turn_plate_sb: StyleBoxFlat = null   # the plate's own skin — the spotlight opens its alpha

const TURN_PLATE_SIZE := Vector2(120.0, 96.0)   # native card units (see NATIVE_SIZE)
const TURN_FONT := 72
const TURN_LINE_W := 7          # heavy, like the strip's own panels
const PLATE_ALPHA := 0.5


func _refresh_turn_number(n: int) -> void:
	if n <= 0:
		if _turn_plate != null:
			_turn_plate.visible = false
			# The plate is the loud half of the spotlight — a lit badge on a hidden badge is a
			# glow radiating around nothing (GlowFx mirrors visibility, but the state would linger).
			_apply_number_spotlight(false)
		return
	if _turn_plate == null:
		var fill := TurnOrderStrip.fill_color(card_instance.owner)
		var line := TurnOrderStrip.line_color(card_instance.owner)
		_turn_plate = Panel.new()
		_turn_plate.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# Born hidden so its first show is an ARRIVAL like every later one (see the fade below) —
		# a Panel is visible by default, and the plate would otherwise skip the fade exactly once,
		# on the one showing the player is most likely to be watching for.
		_turn_plate.visible = false
		var ps := StyleBoxFlat.new()
		# The plate is SEE-THROUGH — the unit it names has to stay recognisable underneath it (the
		# player is reading the order OF units, not of numbers). The numeral itself stays fully
		# opaque, which is what its heavy outline is for.
		ps.bg_color = Color(fill.r, fill.g, fill.b, PLATE_ALPHA)
		ps.set_corner_radius_all(14)
		ps.set_border_width_all(TURN_LINE_W)
		ps.border_color = Color(line.r, line.g, line.b, 0.92)
		_turn_plate.add_theme_stylebox_override("panel", ps)
		# Kept: the spotlight makes the plate OPAQUE while it lights it (see _apply_number_spotlight).
		_turn_plate_sb = ps
		_canvas.add_child(_turn_plate)

		# The numeral is a CHILD of the plate, not its sibling. The two are one object as far as the
		# player is concerned, and the spotlight treats them as one: HighlightFx grows the plate and
		# the number rides that transform, and the baked silhouette the outline/glow hug is the
		# plate's whole subtree. As siblings the plate would have grown out from under its own digit.
		_turn_lbl = Label.new()
		_turn_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_turn_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		# TOP — the vertical placement is TurnOrderStrip.baseline_offset's job (see below).
		_turn_lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		_turn_lbl.add_theme_color_override("font_color", TurnOrderStrip.NUM_COLOR)
		_turn_lbl.add_theme_color_override("font_outline_color", line)
		_turn_lbl.add_theme_font_size_override("font_size", TURN_FONT)
		_turn_lbl.add_theme_constant_override("outline_size",
				int(TURN_FONT * TurnOrderStrip.NUM_OUTLINE))
		_turn_plate.add_child(_turn_lbl)

		# Centred in the card's native box — the one place no stat badge, nameplate or status pip
		# can be, and immune to the flip that mirrors the badge layout (see _apply_mirror).
		_turn_plate.position = (NATIVE_SIZE - TURN_PLATE_SIZE) * 0.5
		_turn_plate.size = TURN_PLATE_SIZE
		# The digits, not the line box, sit centred in the plate — the SAME baseline placement the
		# strip uses on its own numerals, so the two can't disagree about what centred means.
		# Placed in the PLATE's space now that the label hangs off it.
		_turn_lbl.position = Vector2(0.0,
				TurnOrderStrip.baseline_offset(_turn_lbl, TURN_PLATE_SIZE.y))
		_turn_lbl.size = TURN_PLATE_SIZE
	# ARRIVAL, not appearance — but only on the frame the number actually arrives. This runs on every
	# re-derivation, and a plate that is already being read must not restart its fade because the
	# order behind it was recomputed; the number would flicker for as long as the player looked at it.
	var arriving := not _turn_plate.visible
	_turn_lbl.text = str(n)
	_turn_plate.visible = true
	_turn_lbl.visible = true
	if arriving:
		Vfx.play("turn_number_arrive", _turn_plate)
	# The plate may have been BUILT under a spotlight that was already on. The strip declares its
	# hover and its numbers in two steps (see TurnOrderStrip.point_at), so the frame the card learns
	# it is spotlit is the frame BEFORE it has a plate to light — and _apply_spotlight's own guard
	# would then never come back to it. The plate half owns its own guard and is re-asserted here,
	# every time the plate exists, which is a fact this function is the only one to know.
	_apply_number_spotlight(_spotlit_now)


# ── The spotlight: "the list is pointing at THIS unit" ──────────────────────────
# Two cues, on two different things, because they answer two different questions. The CARD wears THE
# HOVER RING — not a cue of its own: pointing at a unit from the gutter and pointing at it with the
# cursor are the same statement about the same unit, so they share one look and the spotlight is
# simply hover arriving from the other end of the screen (see _apply_hover_outline). It does not
# grow and does not glow, so it can never be misread as a pick the player made. The TURN NUMBER is
# what the gesture actually asked
# about, so it takes the loud cue: the plate grows and burns gold (see the turn_number_spotlight
# entry), which has to survive a board full of cards, damage numbers and threat glows.
#
# Idempotent through the same change-guard the other appliers use, since derive_presentation runs
# this on every re-derivation.
var _spotlit_now := false

func _apply_spotlight(on: bool) -> void:
	if on == _spotlit_now:
		return
	_spotlit_now = on
	_apply_hover_outline()
	_apply_number_spotlight(on)


# The loud half, on the number plate — separately guarded because the plate outlives neither the
# card nor the spotlight in step with it (see the call in _refresh_turn_number).
var _num_spotlit_now := false

func _apply_number_spotlight(on: bool) -> void:
	# No plate yet (a card that has never worn a number): nothing to light. Not recorded either —
	# the plate's arrival re-asks, and recording it would swallow that.
	if _turn_plate == null or not is_instance_valid(_turn_plate):
		return
	if on == _num_spotlit_now:
		return
	_num_spotlit_now = on
	# THE PLATE GOES OPAQUE while it is lit, and not only because a solid plate reads louder: the
	# glow shader hollows itself wherever the silhouette is opaque, so a half-transparent plate lets
	# its own halo wash across its face and drown the digit. At rest it goes back to see-through —
	# an unlit number must not hide the unit it names (see PLATE_ALPHA).
	if _turn_plate_sb != null:
		_turn_plate_sb.bg_color.a = 0.97 if on else PLATE_ALPHA
	# The grow factor comes from the entry EXPLICITLY: set_grown's own lookup reads the meta the
	# attached effect leaves behind, which on the very first spotlight isn't there yet (this runs
	# before the attach below) and would silently fall back to the generic `highlight` scale.
	HighlightFx.set_grown(_turn_plate, on,
			Vfx.param_of("turn_number_spotlight", "scale", 1.18))
	if on:
		Vfx.attach("turn_number_spotlight", _turn_plate)
	else:
		Vfx.detach("turn_number_spotlight", _turn_plate)


# NUKED (2026-08-13 ruling): _as_pct converted the nuked writer's 0..1 rates for the odds
# tags; both the rates and the tags are gone.


# Re-derives the glow/dim from current facts. Safe to call from anywhere at any time.
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


# Sheds every HAND-BOUND presentation state: the play-me glow, the unaffordable dim, the
# selection highlight. Called by SlotUI.set_card — the one door every card passes through on its
# way onto the board — because these states are facts about hand life ("affordable to play",
# "selected to place") that no fielded card can truthfully wear. Cleared at the door rather
# than by whoever played the card, so no play path can leak them (Hand.refresh_playable only
# walks cards still IN the hand — it can never reach a card that already left).
func shed_hand_state() -> void:
	Vfx.detach("card_playable_glow", self)
	if _canvas != null:
		_canvas.modulate = Color.WHITE   # neutral — neither the glow'd nor the dimmed hand look


# An inspected ENEMY unit's ability tokens are shown for information only — not castable.
# IGNORE blocks click/hover/long-press-inspect entirely; the dimmed alpha (distinct from
# set_exhausted's opaque grey) reads as "look, don't touch".
var _noninteractive: bool = false
func set_noninteractive() -> void:
	_noninteractive = true   # excludes this view from selection derivation (it owns its dim)
	draggable = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	modulate = Color(1.0, 1.0, 1.0, 0.62)


func refresh() -> void:
	if card_instance == null:
		return
	_art.texture = card_instance.data.image

	var is_spell := card_instance.is_spell
	_frame.texture = FRAME_KING if card_instance.data.is_king else (FRAME_SPELL if is_spell else FRAME_UNIT)
	_name_label.text  = card_instance.data.display_name
	_cost_lbl.text    = str(card_instance.get_attribute("cost"))
	# The King isn't cast from hand for mana, so its cost badge is meaningless — hide it.
	var show_cost := not card_instance.data.is_king
	_cost_bg.visible  = show_cost
	_cost_lbl.visible = show_cost
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
	if not is_spell:
		_refresh_health_badge()
	_spd_bg.visible     = not is_spell
	_spd_lbl.visible    = not is_spell
	_refresh_composition()
	_refresh_charms()
	_refresh_statuses()
	_refresh_ability_cue()
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


# A stat badge's PROC glint — the "this stat just fired" cue, for when a stat directly caused
# something (a dodge is the unit's Speed at work). The SAME effect a relic chip uses when it
# fires (RelicTray.glint): a scale pop plus a brightness flash on the badge itself — no overlay,
# so it reads on the badge's own (non-rectangular) art. Purely transient; the badge returns to
# its authored scale and colour.
func flash_stat_proc(attr: String) -> void:
	var bg: Control = null
	var lbl: Control = null
	match attr:
		"attack":               bg = _atk_bg;    lbl = _atk_lbl
		"health", "max_health": bg = _hp_bg;     lbl = _hp_lbl
		"shield":               bg = _shield_bg; lbl = _shield_lbl
		"speed":                bg = _spd_bg;    lbl = _spd_lbl
		"cost":                 bg = _cost_bg;   lbl = _cost_lbl
	if bg == null or not is_instance_valid(bg) or bg.size == Vector2.ZERO:
		return
	pulse_stat(attr, true)   # the scale pop (icon + number about their shared centre)
	_brighten(bg)            # + the relic-chip brightness flash on the badge's own art
	if lbl != null and is_instance_valid(lbl):
		_brighten(lbl)


# Sustained "this unit threatens the preview pivot" cue: the incoming-threat card glow + a
# slow warm-red pulse on the Attack badge and its number, so the eye lands on WHICH stat is
# the threat. Derived (see derive_presentation: "does MY targeting resolve to the pivot in the
# declared world?"); the change-guard makes re-derivation free — repeated same-verdict calls
# don't churn the tween or the glow bake.
var _threat_on: bool = false

func set_threat_highlight(on: bool) -> void:
	if on == _threat_on:
		return
	_threat_on = on
	# The card-level menace glow rides the same verdict as the badge flare — one derived
	# state, one applier (this was a separate push pair on the board before).
	if on:
		Vfx.attach("attack_target_glow", self)
	else:
		Vfx.detach("attack_target_glow", self)
	if _atk_bg == null or not is_instance_valid(_atk_bg):
		return
	if _threat_tw != null and _threat_tw.is_valid():
		_threat_tw.kill()
		_threat_tw = null
	# Pulse between a SUSTAINED warm tint and a hotter peak — never back to plain white, so the
	# badge always reads as flagged (a dip to white would look like the highlight blinked off).
	var has_lbl := _atk_lbl != null and is_instance_valid(_atk_lbl)
	# The badge art is ALREADY red, so a red tint barely reads — pulse toward a bright warm FLARE
	# (over-bright, gold-white) that visibly lights the badge up against its own colour.
	var warm := Color(1.7, 1.15, 0.8) if on else Color.WHITE
	var hot := Color(2.6, 2.2, 1.3)
	_atk_bg.modulate = warm
	if has_lbl:
		_atk_lbl.modulate = warm
	# Bump the badge 10% larger while flagged — icon AND number about their shared centre so they
	# scale as one rigid unit (same pivot trick as pulse_stat). Sustained; reset to authored size
	# on clear so the fixed Canvas layout is never permanently disturbed.
	var scl := Vector2(1.1, 1.1) if on else Vector2.ONE
	_atk_bg.pivot_offset = _atk_bg.size * 0.5
	_atk_bg.scale = scl
	if has_lbl:
		_atk_lbl.pivot_offset = (_atk_bg.position + _atk_bg.size * 0.5) - _atk_lbl.position
		_atk_lbl.scale = scl
	# The badge is part of the card's SHAPE (unlike the tags), so a 10% bump really does change the
	# silhouette — say so, and let the glows decide whether it moved enough to matter.
	Vfx.shape_changed(self)
	if not on:
		return
	_threat_tw = create_tween().set_loops()
	# Step to the hot peak, then back to warm; the badge art and its number pulse together.
	_threat_tw.tween_property(_atk_bg, "modulate", hot, 0.55)
	if has_lbl:
		_threat_tw.parallel().tween_property(_atk_lbl, "modulate", hot, 0.55)
	_threat_tw.tween_property(_atk_bg, "modulate", warm, 0.55)
	if has_lbl:
		_threat_tw.parallel().tween_property(_atk_lbl, "modulate", warm, 0.55)


# ── Presentation tags ───────────────────────────────────────────────────────────
# The WORDS for the card's combat cues: a stack of small coloured labels under the nameplate that
# name what a visual state means ("Current Target" for the crosshair, "Targeted by:" for the red
# menace glow). A cue teaches its meaning once and then stands alone; until then the tag says it
# outright.
#
# GENERAL, not one-off: a tag is an id in TAGS (text key, its two colours, and WHERE it hangs) and
# the card wears a LIST of them, derived in derive_presentation from the same verdicts that light
# the cues. Adding a future tag (rooted, exhausted, silenced…) is one table entry plus one line in
# the derivation — no new node plumbing, no new push path. Like every other presentation state here
# the list is derived and never pushed, so a card that leaves the board (or the combat screen) sheds
# its tags on the next derive rather than needing anyone to remember to clear them.
#
# `place` picks one of the PLACEMENTS below; each is a holder built lazily on first use, so a tag
# added later can pick an existing spot or declare a new one without touching the appliers.
# `ol` is the text's outline — chosen AWAY from the font colour (a light halo behind dark text, a
# dark one behind light text) so the lettering holds its shape over both the tag's own fill and the
# busy card art a wide tag overhangs.
#
# The two hues are the two SIDES of the declared exchange, and every tag inherits the hue of the
# cue it elaborates: gold = what the pivot does to this card (it is the pivot's victim), red = what
# this card does to the pivot (it menaces the pivot). A card that is both wears both sets.
const TAG_GOLD := Color("f2c319")
const TAG_GOLD_OL := Color("fff4cc")
const TAG_RED := Color("c02a22")
const TAG_RED_OL := Color("360705")

const TAGS := {
	"current_target": {"loc": "combat.tag_current_target", "bg": TAG_GOLD, "fg": Color.BLACK,
		"ol": TAG_GOLD_OL, "place": "outward_top"},
	# Worn by a unit whose auto-attack resolves ONTO the pivot — the red menace glow's caption.
	"menacing": {"loc": "combat.tag_menacing", "bg": TAG_RED, "fg": Color.WHITE,
		"ol": TAG_RED_OL, "place": "outward_bottom"},
	# NUKED (2026-08-13 ruling): the four odds chips (crit_taken / dodge_taken / crit_dealt /
	# dodge_dealt) quoted the dodge and crit rates, which went with the cursed channel.
}

# Native-canvas geometry (the card is authored at NATIVE_SIZE and scaled as one unit, so these are
# plain authored coordinates). Both bands are read off the nameplate's authored anchors — see
# NameBg in card_ui.tscn: it spans x 50 → 216 and y -4 → 43.6.
const TAG_HEIGHT := 40.0
const TAG_SPACING := 4.0
const TAG_FONT_SIZE := 24
const TAG_OUTLINE := 10        # text outline, in native px — thick enough to read over card art
const TAG_BORDER := 4.0        # the tag's own rim
const TAG_CORNER := 9
const TAG_GAP := 4.0           # breathing room between a tag stack and the widget it hangs off
const TAG_Z := 60              # above the board's cards/slots, below full-screen overlay layers
const TAG_INSET_TOP := 6.0     # the gold stack's first chip, just inside the card's top edge
const TAG_INSET_BOTTOM := 14.0 # the red stack's last chip, clearing the stat gems' line

# Where each placement hangs. Every tag box sizes to ITS OWN TEXT and is then positioned outright
# in native canvas coords, so a longer translation widens the tag instead of truncating it.
# TWO STACKS, ONE PER RELATIONSHIP. Each colour is a headed sentence — who the exchange is with,
# then its two odds — so the six chips read as two statements instead of one list of six:
#
#       Current Target   ← gold: the pivot swings at this card
#       Your Crit: 6%
#       My Dodge 1%
#          (gap)
#       Attacker:        ← red: this card swings at the pivot
#       My Crit: 6%
#       Your Dodge 1%
#
# The gap is the whole point of the top/bottom split, which is why each stack anchors to an EDGE
# rather than sitting where the other one ended: with only one relationship live, the surviving
# stack still sits where its colour always sits, and never drifts into the other's half.
#
# Both hang OUTSIDE the card, and are never clamped to it — a tag sits BESIDE the card, never over
# its art or badges (the side rule is in _fill_holder).
const PLACEMENTS := {
	"outward_top": {"align": "outward_top"},
	"outward_bottom": {"align": "outward_bottom"},
}

var _tag_holders: Dictionary = {}   # place -> VBoxContainer, built on first use
var _tags_sig: String = ""          # id+params of what is currently mounted — the change guard


# The single place tags land. Each entry is {"id": <TAGS key>, "params": {…}}, params filling the
# {placeholders} in the tag's localized text. Idempotent: the guard compares ids AND their values,
# so a re-derive is free while a CHANGED number (a buff shifting the odds) still repaints.
func _apply_tags(specs: Array[Dictionary]) -> void:
	var sig := ""
	for s: Dictionary in specs:
		sig += String(s.get("id", "")) + str(s.get("params", {})) + ";"
	if sig == _tags_sig:
		return
	_tags_sig = sig
	# Group by placement first, so each holder is rebuilt once from the full list it owns.
	var by_place: Dictionary = {}
	for s: Dictionary in specs:
		var id: String = String(s.get("id", ""))
		if not TAGS.has(id):
			continue
		var place: String = (TAGS[id] as Dictionary)["place"]
		if not by_place.has(place):
			by_place[place] = [] as Array[Dictionary]
		(by_place[place] as Array[Dictionary]).append(s)
	for place: String in PLACEMENTS:
		var mine: Array[Dictionary] = by_place.get(place, [] as Array[Dictionary])
		if mine.is_empty() and not _tag_holders.has(place):
			continue   # never built, nothing to wear — don't build it just to hide it
		_fill_holder(place, mine)
	# The tags are labels under the Canvas like any other — keep them on this card's oversampled
	# font so an enlarged card's tag text stays as crisp as its name (see _apply_scale).
	if _font_factor > 1.0:
		_apply_font_oversampling()
	Vfx.shape_changed(self)   # the subtree moved — see GlowFx.shape_changed (measures before baking)


func _fill_holder(place: String, specs: Array[Dictionary]) -> void:
	var holder: VBoxContainer = _tag_holders.get(place, null)
	if holder == null:
		holder = _build_holder(place)
	for child in holder.get_children():
		holder.remove_child(child)
		child.queue_free()
	for s: Dictionary in specs:
		holder.add_child(_make_tag(s))
	holder.visible = not specs.is_empty()
	if specs.is_empty():
		return
	# Size the holder to exactly the stack it now carries, then place it per its placement rule.
	# The width is the widest tag's own text (capped at the card), never a fixed fraction; the
	# height is the SUM OF THE CHIPS' OWN minimums, not a constant — TAG_HEIGHT is only a floor, and
	# the real row height is taller (the thick text outline adds to the font's line height). Forcing
	# the constant here squashed every chip.
	var n := float(specs.size())
	var h := maxf(n - 1.0, 0.0) * TAG_SPACING
	for c in holder.get_children():
		h += maxf((c as Control).get_combined_minimum_size().y, TAG_HEIGHT)
	var w: float = holder.get_combined_minimum_size().x
	var align: String = (PLACEMENTS[place] as Dictionary)["align"]
	# WHICH SIDE: OUTWARD — away from the board's centre line, where the two armies face each other.
	# Your units hang their tags to the left, theirs to the right, so a stack always grows into the
	# open edge of the screen rather than across the enemy it is describing. Inward would put both
	# armies' stacks in the same contested gap, each covering the other's cards. Flipping is the
	# same signal the stat cluster mirrors on, so the tags travel with the card's facing.
	var x := (NATIVE_SIZE.x + TAG_GAP) if _flip_applied else (-TAG_GAP - w)
	# WHICH END: gold from the top, red from the bottom, each held inside the card's edges rather
	# than flush with them (the nameplate's band above, the stat gems' line below).
	var y: float = TAG_INSET_TOP if align == "outward_top" 			else NATIVE_SIZE.y - TAG_INSET_BOTTOM - h
	holder.position = Vector2(x, y)
	holder.size = Vector2(w, h)


func _build_holder(place: String) -> VBoxContainer:
	var holder := VBoxContainer.new()
	holder.name = "TagCol_" + place
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE   # pure caption; never eats a card click
	# ANNOTATION, NOT SHAPE. Tags hang off the card to describe it and come and go with the preview
	# world; a glow baked from a silhouette that included them wrapped the chips instead of the card
	# — and kept that outline after they were gone. See SilhouetteBaker.EXCLUDE_META.
	SilhouetteBaker.exclude(holder)
	holder.add_theme_constant_override("separation", int(TAG_SPACING))
	# A tag that hangs off the card lands in a NEIGHBOURING slot's airspace, and slots later in the
	# board's tree paint over it — the stack beside the Speed badge was being buried by the slot next
	# door. Lift the whole holder above the board's ordinary card/slot layer so an overhanging tag is
	# always readable, whichever direction it grows.
	holder.z_index = TAG_Z
	# Both placements keep the default top-left anchors and are positioned outright in _fill_holder,
	# because their size follows the TEXT, not a fraction of the card.
	# Added last so the tags sit above the frame and the art, like the badges do.
	_canvas.add_child(holder)
	_tag_holders[place] = holder
	return holder


func _make_tag(entry: Dictionary) -> Control:
	var spec: Dictionary = TAGS[String(entry["id"])]
	var params: Dictionary = entry.get("params", {})
	var bg: Color = spec["bg"]
	var fg: Color = spec["fg"]
	var ol: Color = spec["ol"]
	var loc_key: String = spec["loc"]
	var box := PanelContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.custom_minimum_size = Vector2(0.0, TAG_HEIGHT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(TAG_CORNER)
	sb.set_content_margin_all(4.0)
	sb.content_margin_left = 12.0
	sb.content_margin_right = 12.0
	# A THICK rim in the tag's own hue, darkened — the same "moulded chip" treatment the stat badges
	# wear, so a tag reads as part of the card's art rather than as a debug overlay. A near-black rim
	# would flatten it; a dark tint of the fill keeps the colour identity at a glance.
	sb.set_border_width_all(int(TAG_BORDER))
	sb.border_color = bg.darkened(0.62)
	# Lifted off the card with a soft drop shadow, so a tag overhanging busy art still reads.
	sb.shadow_size = 5
	sb.shadow_offset = Vector2(0.0, 2.0)
	sb.shadow_color = Color(0.0, 0.0, 0.0, 0.45)
	box.add_theme_stylebox_override("panel", sb)
	var lbl := Label.new()
	lbl.text = Loc.t(loc_key, params)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# NOT clip_text: a clipping Label reports a ~zero minimum width, which collapsed the whole tag
	# box to its margins. The box sizes to this text, so there is nothing to clip.
	lbl.add_theme_color_override("font_color", fg)
	lbl.add_theme_color_override("font_outline_color", ol)
	lbl.add_theme_constant_override("outline_size", TAG_OUTLINE)
	lbl.add_theme_font_size_override("font_size", TAG_FONT_SIZE)
	box.add_child(lbl)
	return box


# A quick over-bright flash back to normal — the relic chip's "fired" discharge (RelicTray.glint),
# applied to whatever node it's given so it works on any badge shape.
func _brighten(node: Control) -> void:
	var tw := create_tween()
	tw.tween_property(node, "modulate", Color(1.7, 1.7, 1.7), 0.12)
	tw.tween_property(node, "modulate", Color.WHITE, 0.22)


# Rebuilds the composition chip strip from the card's elements + chess pieces.
func _refresh_composition() -> void:
	for child in _comp_row.get_children():
		child.queue_free()
	for el: String in card_instance.data.elements:
		_comp_row.add_child(_make_comp_chip(el, true))
	for pc: String in card_instance.data.chess_pieces:
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
		# If this card was already flipped before it grew a charm column, mirror the new column to
		# match the rest of the reflected layout. (When the column already exists at flip time, the
		# _flip_nodes() loop handles it instead.)
		if _flip_applied:
			_mirror_x(_charm_col)

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


# Fills the StatusRow node (authored in card_ui.tscn — move/anchor it in the editor) with one pip
# per active Status: its icon (or coloured glyph), count, and a hover tooltip with the detail.
func _refresh_statuses() -> void:
	if _status_row == null:
		return
	for child in _status_row.get_children():
		_status_row.remove_child(child)
		child.queue_free()
	var stats: Array = card_instance.statuses if card_instance != null else []
	for si: StatusInstance in stats:
		_status_row.add_child(_make_status_pip(si))
	_refresh_aura(stats)
	_sync_status_auras(stats)


# Library auras riding the card while statuses are held (aura_<status_id> entries, sustained):
# attached on gain, detached on loss — a loss the player can see also gets the expiry sound.
# Statuses without an aura entry still get the sound; the pip vanishing is their visual.
var _held_status_auras: Dictionary = {}

func _sync_status_auras(stats: Array) -> void:
	var present: Dictionary = {}
	for si: StatusInstance in stats:
		present[str(si.data.id)] = true
	for sid: String in present:
		if not _held_status_auras.has(sid) and VFXData.get_vfx("aura_" + sid) != null:
			Vfx.attach("aura_" + sid, self)
		_held_status_auras[sid] = true
	for sid: String in _held_status_auras.keys():
		if not present.has(sid):
			_held_status_auras.erase(sid)
			Vfx.detach("aura_" + sid, self)
			Sfx.play("status_expire")


# A persistent "protected"-style frame over the whole card while an aura-declaring status
# (StatusData.aura — e.g. Barrier) is active, in that status's color: a thick soft ring plus a
# faint tint wash, so the protection reads at a glance without hunting for the pip. Lazily
# created; appears/disappears with the status on the next refresh (combat refreshes the board
# after every strike, so a spent Barrier's aura drops immediately).
func _refresh_aura(stats: Array) -> void:
	var aura_status: StatusData = null
	for si: StatusInstance in stats:
		if si.data.aura:
			aura_status = si.data
			break
	if aura_status == null:
		if _aura != null:
			_aura.visible = false
		return
	if _aura == null:
		_aura = Panel.new()
		_aura.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_canvas.add_child(_aura)
		_aura.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var c := aura_status.color
	var style := StyleBoxFlat.new()
	style.bg_color = Color(c.r, c.g, c.b, 0.10)
	style.border_color = Color(c.r, c.g, c.b, 0.85)
	style.set_border_width_all(7)
	style.set_corner_radius_all(10)
	style.set_expand_margin_all(4.0)
	_aura.add_theme_stylebox_override("panel", style)
	_aura.visible = true


# A dim, slowly-pulsing outline on a fielded player unit that currently has an ability worth
# clicking — the "dormant device, may turn on" affordance for the click-to-inspect view
# (see Hand.set_inspected). Placeholder styling until real art exists. Board units only
# (row/col set, owner 0); lazily created like _aura, torn down (tween killed) when inactive so
# refresh() — called often, e.g. every board.refresh() pass — never stacks tweens.
func _refresh_ability_cue() -> void:
	var active := CombatContext.fielded(card_instance) \
			and card_instance.owner == 0 and card_instance.has_available_abilities()
	if not active:
		if _ability_cue != null:
			_ability_cue.visible = false
		if _ability_cue_tween != null:
			_ability_cue_tween.kill()
			_ability_cue_tween = null
		return
	if _ability_cue == null:
		_ability_cue = Panel.new()
		_ability_cue.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_canvas.add_child(_ability_cue)
		_ability_cue.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		# Matched to _refresh_aura's visual weight (7px/0.85/0.10) — the previous 4px/0.55 border,
		# further diluted by a 0.35-1.0 modulate pulse (real alpha dipping to ~0.19), was too weak
		# to register against the card's own gold/parchment frame art at board-slot scale.
		var style := StyleBoxFlat.new()
		style.bg_color = Color(1.0, 0.78, 0.35, 0.10)
		style.border_color = Color(1.0, 0.78, 0.35, 0.85)
		style.set_border_width_all(6)
		style.set_corner_radius_all(10)
		style.set_expand_margin_all(4.0)
		_ability_cue.add_theme_stylebox_override("panel", style)
	_ability_cue.visible = true
	if _ability_cue_tween != null:
		_ability_cue_tween.kill()
	_ability_cue_tween = create_tween()
	_ability_cue_tween.set_loops()
	_ability_cue_tween.tween_property(_ability_cue, "modulate:a", 0.6, 0.9).set_ease(Tween.EASE_IN_OUT)
	_ability_cue_tween.tween_property(_ability_cue, "modulate:a", 1.0, 0.9).set_ease(Tween.EASE_IN_OUT)


# The badge node for a given active status (or null) — lets the VFX layer glint the right pip as
# that status's container cue before its effects land.
func find_status_pip(status_id: String) -> StatusPip:
	if _status_row == null:
		return null
	for child in _status_row.get_children():
		var pip := child as StatusPip
		if pip != null and pip.status != null and pip.status.data.id == status_id:
			return pip
	return null


func _make_status_pip(si: StatusInstance) -> Control:
	var pip := STATUS_PIP_SCENE.instantiate() as StatusPip
	pip.setup(si)
	return pip


# This card's details, as the shared CardTooltip builds them, so a card reads identically wherever
# it is shown. WHEN and WHERE the panel appears is CardHoverPanel's business; which options of the
# shared builder this particular view wants is ours, which is why the presenter asks rather than
# reaching in.
func build_details_panel() -> Control:
	if card_instance == null:
		return null
	return CardTooltip.build(card_instance, _show_cost, 1.0, false, true, is_phantom)


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
# A card view normally stands for its CardInstance, and several views can stand for the same one
# (a unit's board card, its tray entry): naming the subject rather than the widget is what lets
# them agree without anyone syncing them. Screens whose cards stand for something else say so —
# the Decks screen's cards stand for a DECK, and its id survives the rebuild that frees the card,
# which a widget reference would not.
var view_subject: Variant = null

func subject() -> Variant:
	return view_subject if view_subject != null else card_instance


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
# from CombatContext, and it needs no board declaration and nothing to un-push.
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
	# against the union of where the card is and where it rests — the same answer CombatBoard and
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
	if get_parent() is SlotUI:
		set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


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
# ONE outline for TWO facts that turn out to be the same fact: the cursor resting on this card, and
# something elsewhere on the screen pointing at the unit it shows (the turn-order strip's hover —
# see CombatBoard.declare_spotlight). Both mean "this is the one being addressed", they can never
# usefully disagree, and giving them one look is what makes the strip and the board read as a single
# surface rather than two widgets that happen to agree.
#
# Derived from both every time, never toggled from one of them, so whichever ends last leaves the
# ring in the state the OTHER still justifies — a cursor leaving a card the strip is pointing at
# must not take the strip's ring with it.
func _apply_hover_outline() -> void:
	HoverFx.apply(self, _hover_now or _spotlit_now)


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


# Whether this VIEW is one the player can pick at all. Structural, not a flag to be maintained: a
# view is pickable if a press on it is wired to anything, if it stands in a board slot (where the
# slot takes the press on its occupant's behalf), or if the surface it stands on says it answers
# presses for it (see interactive_check). Portraits, tooltips, the inspector's copy, the sidebar
# preview, a landing phantom and an attacker's lunge ghost are all views of a card that nobody can
# click — so they show no pick, even while the card they depict IS the pick.
func _pickable() -> bool:
	return not _noninteractive \
			and (not pressed.get_connections().is_empty() or get_parent() is SlotUI \
				or (interactive_check.is_valid() and bool(interactive_check.call(self))))


# Concealment: this unit is out on a stand-in — its lunge ghost is doing the travelling — so the
# original hides where it stands and the ghost is the only copy on screen.
#
# SHARP, never a fade. The swap is meant to be invisible machinery behind "the unit flew at its
# target"; any transition on it would show two copies of the unit for exactly as long as it lasted,
# which is the artefact this exists to prevent.
#
# `visible` rather than an alpha poke, deliberately: it is a channel of its own that no tint applier
# can stomp (set_exhausted / set_noninteractive write `modulate` wholesale, alpha
# included), and it takes any attached GlowFx with it — a threat glow left radiating around an empty
# slot would give the concealment away just as loudly as the card itself.
func set_concealed(concealed: bool) -> void:
	visible = not concealed


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
			CardInspector.open(self, card_instance, _show_cost, is_phantom)
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
	CardInspector.open(self, card_instance, _show_cost, is_phantom)


# The ghost copy of this card a DragGhost preview shows.
func make_ghost_view() -> CardUI:
	return CardUI.create(card_instance, _show_cost)


func _get_drag_data(at_position: Vector2) -> Variant:
	if not draggable or card_instance == null:
		return null
	# A drag beginning does NOT settle the gesture any more: while the finger is still inside
	# the hold tolerance the drag is provisional, and a completed hold takes it back.
	if _hold_timer != null and not _hold_timer.is_stopped():
		if get_viewport().get_mouse_position().distance_to(_press_origin) > _long_press_move:
			_end_hold()
		else:
			_hold_dragging = true
			set_process(true)
	# The opponent's fielded units are not the player's to pick up.
	if CombatContext.fielded(card_instance) and card_instance.owner == 1:
		return null
	# Buildings root in place: a unit with a rook can be dropped from the hand, but once on the
	# board it can't be picked up to MOVE. (The armed-autocast drag exception died with the
	# ability costume; the quick-cast gesture returns with the rebuilt ActivatedEffect.)
	if CombatContext.fielded(card_instance) and card_instance.data.is_building():
		return null
	if card_instance.is_spell:
		spell_drag_started.emit(self)
	elif not card_instance.is_spell:
		# Any non-spell unit drag — fielded (a MOVE) or from the hand (a PLACE). Combat wires both
		# to the board's move/place cues (see CombatBoard.wire_unit_card). The signal is inert on
		# screens that don't listen (collection/deck/shop never connect it).
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
		modulate.a = 1.0   # the source is no longer hidden during drags; kept as a safety reset
		_end_hold()
		if card_instance != null and card_instance.is_spell:
			spell_drag_ended.emit(self)
		elif card_instance != null and not card_instance.is_spell:
			unit_drag_ended.emit(self)
	elif what == NOTIFICATION_PARENTED:
		# A reparent (played onto the board, moved, mounted) changes the answer to most
		# derived questions. Facing derives IMMEDIATELY (a deferred flip would flash one
		# wrong-facing frame); the rest re-derives deferred, once the transition settles.
		var slot := get_parent() as SlotUI
		if slot != null:
			set_flipped(slot.location != null and slot.location.side == 1)
		# The hover lift is a claim on the position, and the position now belongs to a different
		# layout — release it rather than tweening the card back to where it stood in the old one.
		_drop_hover_claim()
		# Reparenting DESTROYED any sustained Vfx attachment (Vfx.attach auto-detaches on
		# tree_exiting, which remove_child fires) — but the widget-side state the appliers
		# guard with (_selected_now / _threat_on, the grow transform, the badge pulse)
		# SURVIVES the reparent, so the guarded appliers would truthfully answer "already
		# applied" and never restore the glow. Re-attach what the flags say is worn; the
		# deferred derivation below then keeps or sheds it against the current state as
		# usual (a moved unit that is still the pick keeps its highlight lit).
		if _selected_now:
			Vfx.attach.call_deferred("highlight", self)
		if _threat_on:
			Vfx.attach.call_deferred("attack_target_glow", self)
		derive_presentation.call_deferred()
