class_name SlotUI
extends Panel

signal pressed

var row: int = -1
var col: int = -1
var owner_id: int = -1
# The combat-wide interaction session (see Interaction): the drop gate and drop commit ask it
# for this slot's ROLE under the current action — the SAME predicate that lit this slot's cue,
# so the visuals and the drop verdict can never disagree. Null outside combat (tooling shots).
var interaction: Interaction = null

var _card_ui: CardUI = null
var _targetable: bool = false   # presentation only (the highlight border) — set via present()
# Cursor-hover during a STATIC moving/placing selection (see CombatBoard's hover tracking):
# a strong white outline on whatever the cursor points at, and — when this slot wears the MOVE
# cue — the arrow bobs while hovered, exactly as it does during a live drag.
var _hovered: bool = false

# ── Slot cue overlay ────────────────────────────────────────────────────────────
# A small icon layer drawn ABOVE any occupant, communicating what this slot means right now:
# it's open to place, a valid spot to reposition onto (ring + a bobbing arrow), or — during a
# targeted spell/ability — a valid (green reticle) or invalid (red X) target. Icons are SVG
# placeholders swappable for PNGs (see BoardGlyphs). The board drives the state; SlotUI just
# renders it. `_targetable` above stays the pure drop-accept gate — the cue is presentation.
enum Cue { NONE, OPEN, MOVE, TARGET_OK, TARGET_BAD }

var _cue: int = Cue.NONE
var _open_hints: bool = false   # while true, empty own slots show the idle "open" marker
var _icon: TextureRect          # the centred glyph (open / ring / reticle / X)
var _arrow: TextureRect         # the reposition arrow, shown above the ring in MOVE cues
var _arrow_top_y: float = 0.0
var _arrow_bottom_y: float = 0.0
var _arrow_tween: Tween
# MOVE-cue composition (set by _apply_icon_geometry, read by the arrow layout): the spot pool's
# top edge and the arrow box side, so the chunky arrow can be parked just above the pool.
var _spot_top: float = 0.0
var _arrow_side: float = 0.0
# The attack-target crosshair — an INDEPENDENT overlay (not part of the Cue state machine): it
# marks the enemy a selected/dragged friendly unit will strike, and coexists with that unit's
# own move cues. The red glow that pairs with it rides the target CARD via Vfx (see CombatBoard).
var _attack_icon: TextureRect
# A preview of the unit that would land in THIS slot if the drag were released now (see
# CombatBoard's drag phantom). Rendered as a holographic PROJECTION — cooler, brighter and less
# saturated than the card really is — so it reads clearly apart from the warm, dim, translucent
# ghost the cursor drags (DragGhost.GHOST_TINT). The look comes from a cool near-white WASH laid over
# the card: mixing toward a bright cool colour lowers saturation, raises brightness and biases the
# hue all at once, without a per-node shader (which blanks the card's clipped, COVER-fit art node).
# Mounted/unmounted by the board.
var _phantom: CardUI = null

# The projection wash: colour is the cool near-white the card is mixed toward; its alpha is how far.
const PHANTOM_WASH := Color(0.70, 0.84, 1.05, 0.5)
const PHANTOM_ALPHA := 0.9   # the card itself — more present than the see-through drag ghost

# The valid-target cue on an OCCUPIED slot: instead of stamping the green reticle glyph over the
# unit, the card itself lights up from within with a warm golden glow (see "target_valid_glow").
# An inner light, chosen so it never collides with the red OUTER menace glow (attack_target_glow)
# or the corner crosshair that may share the same card. Empty valid slots (MANUAL_SLOT spawn spots)
# have no card to light, so they fall back to the reticle glyph. Tracked so we detach from the exact
# card that was lit, even if occupancy shifts before the gesture clears.
const TARGET_VALID_GLOW := "target_valid_glow"
var _glow_card: CardUI = null


func _ready() -> void:
	custom_minimum_size = Vector2(165, 216)
	_apply_style()
	_build_cue_layer()


func set_targetable(enabled: bool) -> void:
	_targetable = enabled
	_apply_style()


func _apply_style() -> void:
	# Deliberately NOT ScreenUI.SURFACE_DEEP — that's an app-chrome tone (now light, to match the
	# app's plastic-toy palette), but an empty battlefield slot is the game board, not UI chrome; it
	# needs to stay a dark, receding "empty" surface so cards read clearly against it either way.
	# Still themeable via ScreenUI.SLOT_* (backed by UIPalette's own "Combat board" group).
	var style := StyleBoxFlat.new()
	style.bg_color = ScreenUI.SLOT_EMPTY
	if _hovered:
		# The pointing-at-it read outranks the other borders while it lasts.
		style.set_border_width_all(5)
		style.border_color = Color.WHITE
	elif _targetable:
		style.set_border_width_all(3)
		style.border_color = ScreenUI.SLOT_BORDER_HIGHLIGHT
	else:
		style.set_border_width_all(1)
		style.border_color = ScreenUI.SLOT_BORDER_IDLE
	style.set_corner_radius_all(5)
	add_theme_stylebox_override("panel", style)


# ── Cue overlay ─────────────────────────────────────────────────────────────────

func _build_cue_layer() -> void:
	_icon = TextureRect.new()
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.z_index = 1               # above any occupant card (which draws at z 0)
	_icon.visible = false
	add_child(_icon)

	_arrow = TextureRect.new()
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arrow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_arrow.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_arrow.texture = BoardGlyphs.tex("move_arrow")
	_arrow.z_index = 1
	_arrow.visible = false
	add_child(_arrow)

	_attack_icon = TextureRect.new()
	_attack_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_attack_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_attack_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_attack_icon.texture = BoardGlyphs.tex("attack")
	_attack_icon.z_index = 3        # above the cue glyphs AND any phantom
	_attack_icon.visible = false
	add_child(_attack_icon)

	_layout_cue()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _icon != null:
		_layout_cue()


# The round glyphs (ring / reticle / X) sit in a centred square this fraction of the slot's
# shorter side. The OPEN marker is the exception — it fills half the slot to echo its shape.
const ICON_FACTOR := 0.44

# MOVE cue ("reposition here") composition. The spot is a foreshortened ellipse — a spotlight pool
# seen in perspective — biased toward the slot's lower edge, with the chunky arrow bobbing just
# above it. All relative to the slot so it reads at any board scale.
const SPOT_W := 0.58          # pool width as a fraction of the slot width
const SPOT_ASPECT := 0.30     # pool height / width — very slender, a strong perspective foreshorten
const ARROW_W := 0.46         # arrowhead box side as a fraction of the pool width
const ARROW_GAP := 0.30       # gap between arrowhead base and pool, as a fraction of pool height
const SPOT_BIAS := 0.06       # nudge the whole composition down so the pool hugs the lower edge
const MOVE_CUE_ALPHA := 0.85  # the whole move cue rides a touch of transparency so it reads as a
                              # gentle, non-intrusive hint rather than a bright call to attention


# Sizes/positions the glyphs relative to the slot's current size (combat resizes slots to fill
# the board), so the cue reads at any board scale. Keeps the MOVE arrow's bob endpoints current.
func _layout_cue() -> void:
	_apply_icon_geometry()   # sets the pool box AND, for MOVE, _spot_top / _arrow_side
	_layout_arrow()          # size/position the arrow relative to the pool just laid out
	if _arrow_tween == null or not _arrow_tween.is_valid():
		_arrow.position.y = _arrow_top_y
	elif _cue == Cue.MOVE:
		_restart_arrow_bob()   # endpoints moved — rebuild the loop around them

	_position_attack_icon()
	_fit_phantom()


# Sizes the arrow and sets its bob endpoints from the pool position (_spot_top) computed by
# _apply_icon_geometry — so it always parks its base just above the current pool. Must run AFTER
# _apply_icon_geometry, since a stale _spot_top (e.g. from the NONE state) would fling it off-slot.
func _layout_arrow() -> void:
	var s := size
	var a := _arrow_side if _cue == Cue.MOVE else minf(s.x, s.y) * 0.24
	_arrow.size = Vector2(a, a)
	_arrow.position.x = (s.x - a) * 0.5
	_arrow_top_y = _spot_top - a               # parked, base sitting just above the pool
	_arrow_bottom_y = _arrow_top_y + a * 0.28  # a gentle dip toward the pool


# The attack crosshair COMPOSES with any centre cue instead of colliding with it — a slot can show
# several states at once. Alone, the crosshair sits centred (the classic "this is the target"
# read). When a centre glyph is ALSO up (e.g. the green autocast reticle on an enemy that is also
# this unit's auto-attack target), it shrinks into the top-right corner so both states read
# together. Driven from set_cue / set_attack_marker / _layout_cue so it re-solves on any change.
func _position_attack_icon() -> void:
	var s := size
	var m := minf(s.x, s.y)
	if _icon.visible:
		var xs := m * 0.34
		_attack_icon.size = Vector2(xs, xs)
		_attack_icon.position = Vector2(s.x - xs - m * 0.05, m * 0.05)
	else:
		var xs := m * 0.52
		_attack_icon.size = Vector2(xs, xs)
		_attack_icon.position = Vector2((s.x - xs) * 0.5, (s.y - xs) * 0.5)


# The centred glyph's box depends on the cue: OPEN fills half the slot (stretched to the slot's
# own portrait shape), the round glyphs stay a centred aspect-locked square.
func _apply_icon_geometry() -> void:
	var s := size
	if _cue == Cue.OPEN:
		_icon.stretch_mode = TextureRect.STRETCH_SCALE
		var w := s.x * 0.5
		var h := s.y * 0.5
		_icon.size = Vector2(w, h)
		_icon.position = Vector2((s.x - w) * 0.5, (s.y - h) * 0.5)
	elif _cue == Cue.MOVE:
		# Spotlight pool (foreshortened ellipse) + the chunky arrow above it, laid out as one
		# vertically-centred composition — with the arrow up top, the pool naturally lands in the
		# lower half; SPOT_BIAS nudges it a touch further toward the slot's bottom edge.
		_icon.stretch_mode = TextureRect.STRETCH_SCALE
		var w := s.x * SPOT_W
		var h := w * SPOT_ASPECT
		_arrow_side = w * ARROW_W
		var gap := h * ARROW_GAP
		var total := _arrow_side + gap + h
		var top := (s.y - total) * 0.5 + s.y * SPOT_BIAS
		_spot_top = top + _arrow_side + gap
		_icon.size = Vector2(w, h)
		_icon.position = Vector2((s.x - w) * 0.5, _spot_top)
	else:
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var side := minf(s.x, s.y) * ICON_FACTOR
		_icon.size = Vector2(side, side)
		_icon.position = Vector2((s.x - side) * 0.5, (s.y - side) * 0.5)


# `animated` bobs the reposition arrow (a live drag); false parks it (a static selection).
func set_cue(cue: int, animated: bool = false) -> void:
	_cue = cue
	_stop_arrow_bob()
	# Any cue change ends the previous valid-target glow; the TARGET_OK branch re-lights it if it
	# still applies. Idempotent (Vfx de-dupes), so a TARGET_OK→TARGET_OK refresh doesn't churn.
	_clear_valid_glow()
	_apply_icon_geometry()   # glyph box depends on the cue (OPEN fills half the slot)
	# Only the move cue is deliberately softened; the other glyphs stay at full strength.
	_icon.modulate = Color(1.0, 1.0, 1.0, MOVE_CUE_ALPHA) if cue == Cue.MOVE else Color.WHITE
	_arrow.modulate = Color(1.0, 1.0, 1.0, MOVE_CUE_ALPHA)
	match cue:
		Cue.OPEN:
			_icon.texture = BoardGlyphs.tex("open")
			_icon.visible = true
			_arrow.visible = false
		Cue.MOVE:
			_icon.texture = BoardGlyphs.tex("move_ring")
			_icon.visible = true
			# The arrow belongs to MOTION: a live drag (animated) or a hover on a static
			# selection (set_hovered) shows it bobbing; a resting static cue is just the
			# spotlight pool. Geometry is laid out either way so the arrow can appear on
			# hover without the pool shifting.
			_arrow.visible = animated
			_layout_arrow()   # _apply_icon_geometry (above) just set _spot_top — place the arrow to it
			_arrow.position.y = _arrow_top_y
			if animated:
				_restart_arrow_bob()
		Cue.TARGET_OK:
			# An occupied valid target lights the CARD from within (golden inner glow) rather than
			# stamping the reticle over it; an empty valid slot (MANUAL_SLOT spawn spot) has nothing
			# to light, so it keeps the reticle glyph.
			if _card_ui != null:
				_light_valid_glow()
				_icon.visible = false
			else:
				_icon.texture = BoardGlyphs.tex("target_ok")
				_icon.visible = true
			_arrow.visible = false
		Cue.TARGET_BAD:
			_icon.texture = BoardGlyphs.tex("target_bad")
			_icon.visible = true
			_arrow.visible = false
		_:
			_icon.visible = false
			_arrow.visible = false
	_position_attack_icon()   # a centre glyph appearing/leaving moves the crosshair to compose


# Returns the slot to its resting look: the "open" marker on an empty own slot while placement
# hints are on, otherwise nothing. Called whenever a targeting/move gesture ends or occupancy
# changes.
func reset_cue() -> void:
	if _open_hints and _card_ui == null and owner_id == 0:
		set_cue(Cue.OPEN)
	else:
		set_cue(Cue.NONE)


func set_open_hints(enabled: bool) -> void:
	_open_hints = enabled
	reset_cue()


# Cursor-hover presentation during a static moving/placing selection: the strong white outline,
# plus — on a MOVE-cue slot — the arrow APPEARING and bobbing while hovered (the same animation
# a live drag shows; the resting static cue is spotlight-only). Driven by CombatBoard's hover
# tracking; reversible and cue-preserving.
func set_hovered(on: bool) -> void:
	if on == _hovered:
		return
	_hovered = on
	_apply_style()
	if _cue == Cue.MOVE:
		_arrow.visible = on
		if on:
			_restart_arrow_bob()
		else:
			_stop_arrow_bob()
			_arrow.position.y = _arrow_top_y


# Lights the current occupant from within as a valid target (golden inner glow). Tracks the exact
# card lit so _clear_valid_glow detaches from that node even if the slot's occupant later changes.
func _light_valid_glow() -> void:
	if _card_ui == null or _card_ui == _glow_card:
		return
	_clear_valid_glow()
	_glow_card = _card_ui
	Vfx.attach(TARGET_VALID_GLOW, _glow_card)


func _clear_valid_glow() -> void:
	if _glow_card != null and is_instance_valid(_glow_card):
		Vfx.detach(TARGET_VALID_GLOW, _glow_card)
	_glow_card = null


func _restart_arrow_bob() -> void:
	_stop_arrow_bob()
	_arrow.position.y = _arrow_top_y
	_arrow_tween = create_tween().set_loops()
	_arrow_tween.tween_property(_arrow, "position:y", _arrow_bottom_y, 0.65) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_arrow_tween.tween_property(_arrow, "position:y", _arrow_top_y, 0.65) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_arrow_bob() -> void:
	if _arrow_tween != null and _arrow_tween.is_valid():
		_arrow_tween.kill()
	_arrow_tween = null


# Shows/hides the red attack-target crosshair over this slot's occupant. Independent of the cue
# state — the board turns it on for the enemy a selected/dragged friendly unit will strike.
func set_attack_marker(enabled: bool) -> void:
	_attack_icon.visible = enabled
	if enabled:
		_position_attack_icon()   # centred alone, cornered when a centre cue shares the slot


# Mounts the landing PROJECTION of the unit that would drop here on release (drag phantom), or
# clears it when `ghost` is null. Display-only — it never intercepts input. The projected look is a
# cool near-white wash (PHANTOM_WASH) laid over the whole card as its last child, so it sits above
# the art AND the badges and recolours them together — cooler, brighter, less saturated.
func mount_phantom(ghost: CardUI) -> void:
	unmount_phantom()
	_phantom = ghost
	if ghost == null:
		return
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.z_index = 0
	ghost.modulate = Color(1.0, 1.0, 1.0, PHANTOM_ALPHA)
	add_child(ghost)   # facing derives from the slot on reparent (CardUI NOTIFICATION_PARENTED)
	ghost.custom_minimum_size = Vector2.ZERO
	ghost.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var wash := ColorRect.new()
	wash.name = "_PhantomWash"
	wash.color = PHANTOM_WASH
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.add_child(wash)   # last child → drawn over every card layer
	wash.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _fit_phantom() -> void:
	if _phantom != null and is_instance_valid(_phantom):
		_phantom.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func unmount_phantom() -> void:
	if _phantom != null and is_instance_valid(_phantom):
		if _phantom.get_parent() == self:
			remove_child(_phantom)
		_phantom.queue_free()
	_phantom = null


func get_card() -> CardUI:
	return _card_ui


func set_card(card: CardUI) -> void:
	if _card_ui != null and _card_ui.get_parent() == self:
		remove_child(_card_ui)
	_card_ui = card
	if card == null:
		reset_cue()   # emptied — may show the idle "open" marker again
		return
	# Clear old parent slot's reference before re-parenting
	var old_parent := card.get_parent()
	if old_parent is SlotUI:
		var old_slot := old_parent as SlotUI
		old_slot._card_ui = null
		if card.pressed.is_connected(old_slot._on_card_pressed):
			card.pressed.disconnect(old_slot._on_card_pressed)
		old_slot.remove_child(card)
		# The vacated slot re-derives its resting look (idle OPEN marker on an empty own slot)
		# like every other emptying path — without this, a click-move (which resets the board
		# BEFORE committing) leaves the old slot bare until the next full present.
		old_slot.reset_cue()
	elif old_parent != null:
		old_parent.remove_child(card)
	add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The card is anchored to fill this slot — clear its own minimum size so the anchors really
	# drive it. A carried-over minimum (the hand's card size, or card_ui.tscn's default on a King
	# placed directly) would overrule the anchors and overflow any slot smaller than it.
	card.custom_minimum_size = Vector2.ZERO
	# Becoming a board occupant sheds hand-bound presentation (play-me glow / dim / selection
	# tint) — hand states are re-derived by the Hand for cards IN the hand; a card that left
	# can't truthfully wear them, and nobody else is positioned to clear them.
	card.shed_hand_state()
	# CardUI._gui_input calls accept_event() on every click release (long-press/tooltip handling),
	# which marks the event handled and stops it from ever bubbling to this slot's own _gui_input —
	# MOUSE_FILTER_PASS doesn't help, since Godot only forwards an event to the parent if the child
	# left it unhandled. So we listen to the card's `pressed` signal directly instead of relying on
	# GUI event propagation (see Combat._on_board_slot_pressed, the click-to-open-ability-tray path).
	if not card.pressed.is_connected(_on_card_pressed):
		card.pressed.connect(_on_card_pressed)
	# Facing is DERIVED from which side's slot holds the card (CardUI's NOTIFICATION_PARENTED
	# hook fired during add_child above): player cards keep the authored orientation, enemy
	# cards mirror so the two armies read as mirror images across the board.
	reset_cue()   # now occupied — clear any lingering open/move marker


func _on_card_pressed() -> void:
	pressed.emit()


func clear_card() -> CardUI:
	var card := _card_ui
	if _card_ui != null and _card_ui.get_parent() == self:
		remove_child(_card_ui)
	if card != null and card.pressed.is_connected(_on_card_pressed):
		card.pressed.disconnect(_on_card_pressed)
	_card_ui = null
	reset_cue()   # emptied — may show the idle "open" marker again
	return card


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			pressed.emit()
			accept_event()


# The drop gate = "what is my ROLE under the current action?" — asked of the Interaction
# session, which is the same authority that lit this slot's cue. The role also feeds the drag
# ghost's verdict (DESTINATION → the unit copy, TARGET_VALID/INVALID → the cast views; the
# ghost's own no-ability fallback keeps spell drags on the plain copy).
func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	if not (data is CardUI):
		return false
	if interaction == null:
		return false
	match interaction.role_of(self):
		Interaction.Role.DESTINATION:
			DragGhost.report(DragGhost.State.UNIT, self)
			return true
		Interaction.Role.TARGET_VALID:
			DragGhost.report(DragGhost.State.CAST_OK, self)
			return true
		Interaction.Role.TARGET_INVALID:
			DragGhost.report(DragGhost.State.CAST_INVALID, self)
			return false
		_:
			return false


func _drop_data(_at: Vector2, _data: Variant) -> void:
	if interaction != null:
		interaction.commit_drop(self)   # re-validates via the same role predicate, then commits
