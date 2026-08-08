class_name DragGhost
extends Control

# The drag preview for every card drag: a clearly-distinct GHOST copy that follows the cursor
# while the real card stays fully visible in its slot/hand. For a fielded unit with an ARMED
# autocast ability the ghost is context-sensitive — it presents what the drop would DO:
#
#   over a valid move spot      → the unit copy            (movable units only)
#   over a valid cast target    → the armed ability view
#   anything else (default)     → the ability view RED-shaded ("not appliable");
#                                 with nothing armed, the plain unit copy
#
# Buildings only drag while armed (see CardUI._get_drag_data) and no move spot is ever valid
# for them, so their ghost always presents the ability. Hand cards and spells carry no armed
# ability, so their ghost is simply the static unit/spell copy.
#
# Hover feed: drop zones report a verdict (plus themselves) from _can_drop_data through the
# static `current` handle. _can_drop_data only fires on mouse MOTION, so a report can't be
# decayed on a timer — a stationary cursor gets no fresh reports and would flicker back to
# default between movements. Instead a report stays authoritative while the cursor remains
# inside the reporting zone's rect; leaving it (slot gaps, off-board, non-reporting zones)
# reverts the ghost to its default presentation.

enum State { UNIT, CAST_OK, CAST_INVALID }

# The ghost fade over whichever view is shown: dimmer + translucent + slightly cool, so the
# copy can't be mistaken for the real card sitting in place. (A desaturation shader can
# replace this later without structural change.)
const GHOST_TINT := Color(0.72, 0.72, 0.80, 0.62)
# The "not appliable" shade layered onto the ability view in CAST_INVALID.
const INVALID_TINT := Color(1.0, 0.38, 0.38)
# The live ghost of the drag in progress (there is at most one drag at a time).
static var current: DragGhost = null

var _unit_view: CardUI = null
var _ability_view: AbilityWidget = null
var _state: State = State.UNIT
var _default_state: State = State.UNIT
# The zone whose verdict currently drives the state — authoritative while the cursor stays
# inside its global rect (see _process).
var _report_zone: Control = null


# Builds the preview for `source`'s drag, anchored so the ghost sits where the card was
# grabbed. Registers itself as the live ghost; NOTIFICATION_DRAG_END on the source frees the
# preview automatically (Godot owns it), and _exit_tree clears the handle.
static func make(source: CardUI, at_position: Vector2) -> DragGhost:
	var ghost := DragGhost.new()
	ghost._build(source, at_position)
	current = ghost
	return ghost


# A drop zone's live verdict for the cursor's current position (see SlotUI / HandDropZone).
static func report(verdict: State, zone: Control) -> void:
	if current != null:
		current._on_report(verdict, zone)


func _build(source: CardUI, at_position: Vector2) -> void:
	var inst := source.card_instance
	_unit_view = source.make_ghost_view()
	_unit_view.custom_minimum_size = source.custom_minimum_size
	_unit_view.size = source.size
	add_child(_unit_view)
	_unit_view.position = -at_position

	# The context views only exist for a fielded player unit with an armed autocast ability —
	# built exactly like the tray builds its tokens (see Hand._rebuild_inspect_view).
	var ab: AbilityData = inst.armed_autocast() \
			if CombatContext.fielded(inst) and inst.owner == 0 and not inst.is_spell else null
	if ab != null:
		var tok := CardInstance.from_data(ab.display_card())
		tok.owner = inst.owner
		tok.source_building = inst
		tok.ability = ab
		_ability_view = AbilityWidget.create_for(tok)
		_ability_view.custom_minimum_size = source.custom_minimum_size
		_ability_view.size = source.size
		add_child(_ability_view)
		_ability_view.position = -at_position
		_default_state = State.CAST_INVALID

	modulate = GHOST_TINT
	_apply_state(_default_state)


func _exit_tree() -> void:
	if current == self:
		current = null


func _process(_delta: float) -> void:
	if _report_zone == null:
		return
	if not is_instance_valid(_report_zone) or not _report_zone.get_global_rect() \
			.has_point(_report_zone.get_global_mouse_position()):
		_report_zone = null
		_apply_state(_default_state)


func _on_report(verdict: State, zone: Control) -> void:
	_report_zone = zone
	# CAST verdicts without an ability view fall back to the unit copy (nothing armed = the
	# drop can't cast, so there is nothing truthful to preview).
	if _ability_view == null:
		_apply_state(State.UNIT)
		return
	_apply_state(verdict)


func _apply_state(state: State) -> void:
	_state = state
	_unit_view.visible = state == State.UNIT
	if _ability_view != null:
		_ability_view.visible = state != State.UNIT
		_ability_view.modulate = INVALID_TINT if state == State.CAST_INVALID else Color.WHITE
