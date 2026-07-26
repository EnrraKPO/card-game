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
# The static "you are looking at this one" highlight (see set_inspected) — created lazily,
# externally driven, distinct from both _ability_cue (a fact about the card) and set_selected.
var _inspect_cue: Panel = null
# The armed-autocast echo on a fielded holder (see _refresh_autocast_brackets) — small corner
# brackets + the armed effects (glow pulse, orbiting sparkles), so "who is armed" reads on
# the board without inspecting. Lazily created like _aura.
var _autocast_fx: AutocastFX = null

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
	# The self-derivation poll (see derive_presentation): every card re-consults its own
	# situation on a slow beat, so no state can outlive the facts it derives from even if
	# every cue is missed. Outside combat (CombatContext.current == null, no playable_check)
	# each tick is a no-op.
	_presentation_poll = Timer.new()
	_presentation_poll.wait_time = PRESENTATION_POLL_SECS
	_presentation_poll.autostart = true
	_presentation_poll.timeout.connect(derive_presentation)
	add_child(_presentation_poll)
	# The near-subliminal hover tick, on the shared card class so every card everywhere
	# whispers the same way (placeholder-gated like all undesigned cues — F7 mutes it).
	mouse_entered.connect(func() -> void: Sfx.play("card_hover"))
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
	# An ENEMY unit's ability token is view-only — a fact of the token's OWN model (its
	# instance carries the holder's owner), derived here rather than pushed by the tray.
	if card_instance != null and card_instance.owner == 1:
		set_noninteractive()
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
#   • selection tint: only selectable card views (hand cards / tray tokens), never a
#     noninteractive enemy token (owns a dim), a drag-ghost view (owns its tint) or an
#     inspector/preview copy.
#   • board states (concealment / exhaust grey / inspect cue / threat glow): only a slot's
#     OCCUPANT — a landing phantom mounted in a slot is a projection, not the unit, and an
#     attacker's lunge ghost hangs off the combat root rather than a slot, so it can never
#     conceal itself for being its own stand-in.
func derive_presentation() -> void:
	refresh_playable()
	var slot := get_parent() as SlotUI
	if slot != null:
		set_flipped(slot.owner_id == 1)   # facing derives from which side's slot holds me
	var ctx := CombatContext.current
	if ctx == null:
		return
	if not _noninteractive and (playable_check.is_valid() or is_generated):
		set_selected(ctx.is_selected(self))
	var tags: Array[Dictionary] = []
	if slot != null and slot.get_card() == self and card_instance != null:
		# Concealment first: it decides whether this view is on screen AT ALL, so it can't be
		# expressed by any of the tints below and none of them can overrule it.
		set_concealed(ctx.is_concealed(card_instance))
		set_exhausted(card_instance.attack_exhausted)
		set_inspected(ctx.inspected_instance() == card_instance)
		var menacing := ctx.menaces_pivot(card_instance)
		set_threat_highlight(menacing)
		# The word for each visual cue, from the SAME verdict that lights the cue — so a tag can
		# never disagree with the glow/crosshair it explains. Both can apply at once (a unit that
		# attacks the pivot AND is the pivot's own victim wears both sets).
		#
		# Each flag also carries the ODDS of the exchange it names, asked of the Resolver — the same
		# functions the actual swing rolls against, so the preview cannot drift from the resolution
		# (they are pure queries: crit_chance/dodge_chance run a rewrite-only interception pass and
		# submit nothing). Both are speed-scaled, which is why they hang off the Speed badge.
		var pivot := ctx.pivot()
		if ctx.is_pivot_target(card_instance):
			# The pivot swings at ME: its crit chance, my chance to dodge it.
			tags.append({"id": "current_target"})
			tags.append({"id": "crit_taken",
				"params": {"n": _as_pct(Resolver.crit_chance(pivot, card_instance))}})
			tags.append({"id": "dodge_taken",
				"params": {"n": _as_pct(Resolver.dodge_chance(card_instance, pivot))}})
		if menacing:
			# I swing at the pivot: my crit chance, the pivot's chance to dodge me.
			tags.append({"id": "menacing"})
			tags.append({"id": "crit_dealt",
				"params": {"n": _as_pct(Resolver.crit_chance(card_instance, pivot))}})
			tags.append({"id": "dodge_dealt",
				"params": {"n": _as_pct(Resolver.dodge_chance(pivot, card_instance))}})
	_apply_tags(tags)


# Resolver rates are 0..1; the tags speak in whole percent.
func _as_pct(rate: float) -> int:
	return int(round(rate * 100.0))


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


# Whether this view may BEGIN an activation right now, on grounds OTHER than its mana cost
# (which every caster checks separately). Ordinary card views always may; AbilityWidget
# overrides it with the usability it derives, so the cast gate and the spent grey always
# answer from the same derivation.
func castable_now() -> bool:
	return true


# Sheds every HAND-BOUND presentation state: the play-me glow, the unaffordable dim, the
# selection tint. Called by SlotUI.set_card — the one door every card passes through on its
# way onto the board — because these states are facts about hand life ("affordable to play",
# "selected to place") that no fielded card can truthfully wear. Cleared at the door rather
# than by whoever played the card, so no play path can leak them (Hand.refresh_playable only
# walks cards still IN the hand — it can never reach a card that already left).
func shed_hand_state() -> void:
	Vfx.detach("card_playable_glow", self)
	if _canvas != null:
		_canvas.modulate = Color.WHITE   # neutral — neither the glow'd nor the dimmed hand look
	set_selected(false)


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
	_spd_bg.visible     = not is_spell
	_spd_lbl.visible    = not is_spell
	_refresh_composition()
	_refresh_charms()
	_refresh_statuses()
	_refresh_ability_cue()
	_refresh_autocast_brackets()
	# The lines above rebuild dynamic labels (chips/pips) — re-point them at the current
	# oversampled font so an enlarged card's WHOLE text stays crisp (see _apply_scale).
	if _font_factor > 1.0:
		_apply_font_oversampling()
	# Fall back to the name so the enlarged hover preview shows even without a description.
	# UIScale.tip suppresses it entirely on touch (no hover there — long-press inspect instead).
	var desc := card_instance.data.description
	# The auto-attack targeting line rides after the authored text here too (units only), so the
	# native tooltip matches the rich CardTooltip.
	var targeting := card_instance.data.targeting_line()
	if not targeting.is_empty():
		desc = (desc + "\n" + targeting) if not desc.is_empty() else targeting
	# The rooted-building note rides after the authored/targeting text too (buildings only).
	var building := card_instance.data.building_line()
	if not building.is_empty():
		desc = (desc + "\n" + building) if not desc.is_empty() else building
	# The card's native fallback tooltip can't render icons/BBCode — resolve markup to words.
	UIScale.tip(self, TextIcons.plain(desc) if not desc.is_empty() else card_instance.data.display_name)


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
		"ol": TAG_GOLD_OL, "place": "below_name"},
	# Worn by a unit whose auto-attack resolves ONTO the pivot — the red menace glow's caption.
	"menacing": {"loc": "combat.tag_menacing", "bg": TAG_RED, "fg": Color.WHITE,
		"ol": TAG_RED_OL, "place": "left_of_name"},
	# The odds of the exchange, beside the Speed badge — the stat both quantities are driven by
	# (Resolver.crit_chance / dodge_chance are speed-scaled), so the number sits next to its cause.
	# Gold pair: the pivot ATTACKS this card. Red pair: this card attacks the pivot.
	#
	# Whose number is it? One rule, applied everywhere: an UNQUALIFIED label is the card the chip
	# hangs off, "Your …" is the selected unit. So the gold pair reads "Your Crit" (your unit's crit
	# on this victim) + "Dodge" (this victim's own dodge), and the red pair reads "Crit" (this
	# attacker's crit) + "Your Dodge" (your unit's dodge against it) — each chip names its owner.
	"crit_taken": {"loc": "combat.tag_crit_own", "bg": TAG_GOLD, "fg": Color.BLACK,
		"ol": TAG_GOLD_OL, "place": "beside_speed"},
	"dodge_taken": {"loc": "combat.tag_dodge", "bg": TAG_GOLD, "fg": Color.BLACK,
		"ol": TAG_GOLD_OL, "place": "beside_speed"},
	"crit_dealt": {"loc": "combat.tag_crit", "bg": TAG_RED, "fg": Color.WHITE,
		"ol": TAG_RED_OL, "place": "beside_speed"},
	"dodge_dealt": {"loc": "combat.tag_dodge_own", "bg": TAG_RED, "fg": Color.WHITE,
		"ol": TAG_RED_OL, "place": "beside_speed"},
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
const NAME_LEFT := 50.0        # nameplate's left edge
const NAME_MID_Y := 19.8       # nameplate's vertical centre — fallback for _name_band_mid()
const TAG_TOP := 49.0          # first row of the below-name stack, clearing the nameplate

# Where each placement hangs. Every tag box sizes to ITS OWN TEXT and is then positioned outright
# in native canvas coords, so a longer translation widens the tag instead of truncating it.
#   • "below_name"    — centred under the nameplate. Its mirror image is itself, which is why it's
#                       absent from _flip_nodes.
#   • "left_of_name"  — on the name's own band, right edge tucked against the nameplate and growing
#                       leftwards. It is NOT clamped to the card: the nameplate is authored centred,
#                       leaving only ~50px of the 260px card to its left, so any tag wider than that
#                       hangs off the card's left edge. That is deliberate — the tag sits BESIDE the
#                       name, never over it, and the card's own art and nameplate stay untouched.
#   • "beside_speed"  — stacked against the Speed badge, on the badge's OUTWARD side (away from the
#                       card's centre), so it follows the badge when a flipped card mirrors its
#                       stat cluster instead of needing its own mirrored copy.
const PLACEMENTS := {
	"below_name": {"align": "centre_below"},
	"left_of_name": {"align": "right_edge_at_name"},
	"beside_speed": {"align": "outward_of_speed"},
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
	if align == "centre_below":
		# The below-name stack DOES stay on the card (it has the full width to sit in).
		w = minf(w, NATIVE_SIZE.x - 6.0)
		holder.position = Vector2((NATIVE_SIZE.x - w) * 0.5, TAG_TOP)
	elif align == "outward_of_speed":
		# Hard against the Speed badge, on whichever side faces AWAY from the card's centre — so a
		# flipped card's mirrored badge takes its numbers with it, no mirrored placement rule needed.
		var r := _badge_rect(_spd_bg, Rect2(-9.0, 253.0, 68.0, 73.0))
		var outward_left := r.position.x + r.size.x * 0.5 < NATIVE_SIZE.x * 0.5
		var x := (r.position.x - TAG_GAP - w) if outward_left else (r.end.x + TAG_GAP)
		holder.position = Vector2(x, r.position.y + r.size.y * 0.5 - h * 0.5)
	else:
		# Right edge against the nameplate, growing left — x goes negative, and that's the point.
		# Vertically it centres on the NAME's own band, so tag and name share a baseline and read
		# as one sentence: "Targeted by: <name>".
		holder.position = Vector2(NAME_LEFT - TAG_GAP - w, _name_band_mid() - h * 0.5)
	holder.size = Vector2(w, h)


# A badge's live rect in Canvas coords, falling back to its authored rect before layout resolves it
# (or if the badge is momentarily scaled — see set_threat_highlight — the position still holds).
func _badge_rect(badge: Control, authored: Rect2) -> Rect2:
	if badge != null and is_instance_valid(badge) and badge.size != Vector2.ZERO:
		return Rect2(badge.position, badge.size)
	return authored


# The vertical centre of the NAME's text, read off the live label (which is centre-aligned in its
# own rect) rather than hardcoded — so if the nameplate is ever re-authored the tag follows it.
# Falls back to the authored constant before layout has resolved the label's rect.
func _name_band_mid() -> float:
	if _name_label != null and is_instance_valid(_name_label) and _name_label.size.y > 0.0:
		return _name_label.position.y + _name_label.size.y * 0.5
	return NAME_MID_Y


func _build_holder(place: String) -> VBoxContainer:
	var holder := VBoxContainer.new()
	holder.name = "TagCol_" + place
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE   # pure caption; never eats a card click
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
	var active := card_instance != null and card_instance.row >= 0 and card_instance.col >= 0 \
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


# Builds the autocast FX bundle (corner brackets + armed glow/sparkles — see AutocastFX)
# full-rect under the Canvas, sized/inset in native units. Shared by the board echo below
# and the AbilityWidget's capability display — same visuals at two scales, so the tray
# widget and its board holder visually rhyme.
func build_autocast_fx(bracket_size: Vector2, inset: float) -> AutocastFX:
	var fx := AutocastFX.new()
	_canvas.add_child(fx)
	fx.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	fx.setup(bracket_size, inset, NATIVE_SIZE)
	return fx


# The board-side echo of an ARMED autocast ability: small corner brackets + the armed
# effects on the fielded holder, so the player can see who is armed without opening the
# inspect tray. Derivable from card_instance (like _refresh_ability_cue), so it lives in
# refresh(). armed_autocast() already validates the id against the current ability list —
# a stale arm just disappears.
func _refresh_autocast_brackets() -> void:
	var active := card_instance != null and card_instance.row >= 0 and card_instance.col >= 0 \
			and card_instance.owner == 0 and card_instance.armed_autocast() != null
	if not active:
		if _autocast_fx != null:
			_autocast_fx.visible = false
			_autocast_fx.set_armed(false)
		return
	if _autocast_fx == null:
		_autocast_fx = build_autocast_fx(Vector2(48.0, 42.0), 6.0)
	_autocast_fx.visible = true
	_autocast_fx.set_armed(true)


# A solid, non-pulsing highlight marking "this is the board unit the hand panel is currently
# showing" (see Hand.set_inspected / Combat._on_inspect_changed). Unlike _refresh_ability_cue,
# this is externally-driven UI selection state, not a fact derivable from card_instance — so it's
# NOT called from refresh(), only from the orchestrator. Deliberately a distinct cool cyan from
# both the amber ability-cue and the blue-white set_selected tint, and a separate Panel sibling
# (not a modulate change) so all three compose without visual collision.
func set_inspected(active: bool) -> void:
	if _inspect_cue == null:
		if not active:
			return
		_inspect_cue = Panel.new()
		_inspect_cue.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_canvas.add_child(_inspect_cue)
		_inspect_cue.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.35, 0.85, 1.0, 0.10)
		style.border_color = Color(0.35, 0.9, 1.0, 0.95)
		style.set_border_width_all(5)
		style.set_corner_radius_all(10)
		style.set_expand_margin_all(4.0)
		_inspect_cue.add_theme_stylebox_override("panel", style)
	_inspect_cue.visible = active


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


# The rich hover panel is the shared CardTooltip, so it matches everywhere a card is shown.
func _make_custom_tooltip(_for_text: String) -> Object:
	if UIScale.is_touch():
		return null   # belt-and-braces: UIScale.tip already blanks the text on touch
	return CardTooltip.build(card_instance, _show_cost)


func set_selected(selected: bool) -> void:
	modulate = Color(0.65, 1.0, 1.5) if selected else Color.WHITE


# Concealment: this unit is out on a stand-in — its lunge ghost is doing the travelling — so the
# original hides where it stands and the ghost is the only copy on screen.
#
# SHARP, never a fade. The swap is meant to be invisible machinery behind "the unit flew at its
# target"; any transition on it would show two copies of the unit for exactly as long as it lasted,
# which is the artefact this exists to prevent.
#
# `visible` rather than an alpha poke, deliberately: it is a channel of its own that no tint applier
# can stomp (set_exhausted / set_selected / set_noninteractive all write `modulate` wholesale, alpha
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
			# The desktop path to the in-depth view (touch reaches it via long-press). Note the
			# AbilityWidget override consumes right-click first for autocast-capable abilities.
			CardInspector.open(self, card_instance, _show_cost)
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
	CardInspector.open(self, card_instance, _show_cost)


# The ghost copy of this card a DragGhost preview shows — overridden by AbilityWidget so a
# tray token ghosts with its own widget frame, not a card frame.
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
	if card_instance.row >= 0 and card_instance.owner == 1:
		return null
	# Buildings root in place: a unit with a rook can be dropped from the hand, but once on the
	# board it can't be picked up to MOVE. With an autocast ability ARMED it drags anyway — the
	# drag can only cast (no move spot ever accepts it; see CombatBoard/_can_drop_on_player_slot),
	# and the DragGhost accordingly always presents the ability.
	if card_instance.row >= 0 and card_instance.data.is_building() \
			and card_instance.armed_autocast() == null:
		return null
	if card_instance.is_spell:
		spell_drag_started.emit(self)
	elif not card_instance.is_spell:
		# Any non-spell unit drag — fielded (a MOVE) or from the hand (a PLACE). Combat wires both
		# to the board's move/place cues (see CombatBoard.wire_unit_card). The signal is inert on
		# screens that don't listen (collection/deck/shop never connect it).
		unit_drag_started.emit(self)
	# The real card stays fully visible in place; the cursor carries a clearly-distinct ghost
	# copy (context-sensitive when an autocast ability is armed — see DragGhost).
	set_drag_preview(DragGhost.make(self, at_position))
	return self


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
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
			set_flipped(slot.owner_id == 1)
		derive_presentation.call_deferred()
