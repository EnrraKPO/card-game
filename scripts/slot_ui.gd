class_name SlotUI
extends Panel

signal card_dropped(card_ui: CardUI)
signal pressed

var row: int = -1
var col: int = -1
var owner_id: int = -1
var accept_check: Callable
# Gate for the AUTOCAST drop gesture — a fielded unit with an armed autocast ability dropped
# onto this slot's occupant (see CombatBoard). Occupied slots reject unit drops otherwise.
var autocast_check: Callable   # func(CardUI, SlotUI) -> bool

var _card_ui: CardUI = null
var _targetable: bool = false

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
# The attack-target crosshair — an INDEPENDENT overlay (not part of the Cue state machine): it
# marks the enemy a selected/dragged friendly unit will strike, and coexists with that unit's
# own move cues. The red glow that pairs with it rides the target CARD via Vfx (see CombatBoard).
var _attack_icon: TextureRect
# A translucent preview of the unit that would land in THIS slot if the drag were released now
# (see CombatBoard's drag phantom). Mounted/unmounted by the board.
var _phantom: CardUI = null


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
	if _targetable:
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


# Sizes/positions the glyphs relative to the slot's current size (combat resizes slots to fill
# the board), so the cue reads at any board scale. Keeps the MOVE arrow's bob endpoints current.
func _layout_cue() -> void:
	_apply_icon_geometry()
	var s := size
	var side := minf(s.x, s.y) * ICON_FACTOR   # the (square) ring the arrow bobs above
	var ring_top := s.y * 0.5 - side * 0.5
	var a := side * 0.55
	_arrow.size = Vector2(a, a)
	_arrow.position.x = (s.x - a) * 0.5
	_arrow_top_y = ring_top - a * 1.15      # parked, clear above the ring
	_arrow_bottom_y = ring_top - a * 0.55   # dipped toward the ring
	if _arrow_tween == null or not _arrow_tween.is_valid():
		_arrow.position.y = _arrow_top_y
	elif _cue == Cue.MOVE:
		_restart_arrow_bob()   # endpoints moved — rebuild the loop around them

	_position_attack_icon()
	if _phantom != null and is_instance_valid(_phantom):
		_phantom.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


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
	else:
		_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var side := minf(s.x, s.y) * ICON_FACTOR
		_icon.size = Vector2(side, side)
		_icon.position = Vector2((s.x - side) * 0.5, (s.y - side) * 0.5)


# `animated` bobs the reposition arrow (a live drag); false parks it (a static selection).
func set_cue(cue: int, animated: bool = false) -> void:
	_cue = cue
	_stop_arrow_bob()
	_apply_icon_geometry()   # glyph box depends on the cue (OPEN fills half the slot)
	match cue:
		Cue.OPEN:
			_icon.texture = BoardGlyphs.tex("open")
			_icon.visible = true
			_arrow.visible = false
		Cue.MOVE:
			_icon.texture = BoardGlyphs.tex("move_ring")
			_icon.visible = true
			_arrow.visible = true
			_arrow.position.y = _arrow_top_y
			if animated:
				_restart_arrow_bob()
		Cue.TARGET_OK:
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


func _restart_arrow_bob() -> void:
	_stop_arrow_bob()
	_arrow.position.y = _arrow_top_y
	_arrow_tween = create_tween().set_loops()
	_arrow_tween.tween_property(_arrow, "position:y", _arrow_bottom_y, 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_arrow_tween.tween_property(_arrow, "position:y", _arrow_top_y, 0.5) \
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


# Mounts a translucent preview of the unit that would land here on release (drag phantom), or
# clears it when `ghost` is null. The ghost is display-only — it never intercepts input.
func mount_phantom(ghost: CardUI) -> void:
	unmount_phantom()
	_phantom = ghost
	if ghost == null:
		return
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ghost.modulate = Color(0.85, 0.9, 1.0, 0.5)
	ghost.z_index = 0
	add_child(ghost)
	ghost.custom_minimum_size = Vector2.ZERO
	ghost.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	ghost.set_flipped(owner_id == 1)


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
	elif old_parent != null:
		old_parent.remove_child(card)
	add_child(card)
	card.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The card is anchored to fill this slot — clear its own minimum size so the anchors really
	# drive it. A carried-over minimum (the hand's card size, or card_ui.tscn's default on a King
	# placed directly) would overrule the anchors and overflow any slot smaller than it.
	card.custom_minimum_size = Vector2.ZERO
	# CardUI._gui_input calls accept_event() on every click release (long-press/tooltip handling),
	# which marks the event handled and stops it from ever bubbling to this slot's own _gui_input —
	# MOUSE_FILTER_PASS doesn't help, since Godot only forwards an event to the parent if the child
	# left it unhandled. So we listen to the card's `pressed` signal directly instead of relying on
	# GUI event propagation (see Combat._on_board_slot_pressed, the click-to-open-ability-tray path).
	if not card.pressed.is_connected(_on_card_pressed):
		card.pressed.connect(_on_card_pressed)
	# Face the opponent: the card is authored in the PLAYER's orientation, so player cards (and the
	# hand, which never flips) read identically with no change. Enemy cards (right half, facing
	# left) mirror that layout so the two armies read as mirror images across the board. See
	# CardUI.set_flipped.
	card.set_flipped(owner_id == 1)
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


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	if not (data is CardUI):
		return false
	var card_ui := data as CardUI
	if card_ui.card_instance.is_spell:
		# Spells drop only on ELIGIBLE slots: during a spell drag the board marks targetable
		# exactly the valid picks (occupied units passing the spell's conditions — and for
		# MANUAL_SLOT spells, eligible EMPTY own slots too), so an invalid drop is rejected at
		# hover time. See SpellCaster._on_spell_drag_started.
		return _targetable
	if _card_ui != null:
		# The one unit-onto-occupied-slot gesture: an armed autocast ability fired by dragging
		# its holder onto a valid target. Everything else stays rejected as before. Either way
		# the verdict feeds the drag ghost, which presents cast-vs-not-appliable accordingly.
		var can_cast := autocast_check.is_valid() and bool(autocast_check.call(card_ui, self))
		DragGhost.report(DragGhost.State.CAST_OK if can_cast else DragGhost.State.CAST_INVALID, self)
		return can_cast
	var can_move := true
	if accept_check.is_valid():
		can_move = bool(accept_check.call(card_ui, self))
	if can_move:
		# A valid move spot shows the unit itself on the ghost; an invalid empty slot reports
		# nothing and lets the ghost fall back to its default presentation.
		DragGhost.report(DragGhost.State.UNIT, self)
	return can_move


func _drop_data(_at: Vector2, data: Variant) -> void:
	card_dropped.emit(data as CardUI)
