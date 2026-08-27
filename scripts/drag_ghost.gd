class_name DragGhost
extends Control

# The drag preview for every card drag: a clearly-distinct GHOST copy that follows the cursor
# while the real card stays fully visible in its slot/hand.
#
# When quick-cast returns, the ghost presents what the drop would DO — an ability view
# swapped in over valid cast targets, red-shaded elsewhere — driven by the zone-report
# machinery below.
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
# The live ghost of the drag in progress (there is at most one drag at a time).
static var current: DragGhost = null

var _unit_view: CardUI = null
var _state: State = State.UNIT
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


# A drop zone's live verdict for the cursor's current position (the Forge's drags).
static func report(verdict: State, zone: Control) -> void:
	if current != null:
		current._on_report(verdict, zone)


func _build(source: CardUI, at_position: Vector2) -> void:
	_unit_view = source.make_ghost_view()
	_unit_view.custom_minimum_size = source.custom_minimum_size
	_unit_view.size = source.size
	add_child(_unit_view)
	_unit_view.position = -at_position
	modulate = GHOST_TINT
	_apply_state(State.UNIT)


func _exit_tree() -> void:
	if current == self:
		current = null


func _process(_delta: float) -> void:
	if _report_zone == null:
		return
	if not is_instance_valid(_report_zone) or not _report_zone.get_global_rect() \
			.has_point(_report_zone.get_global_mouse_position()):
		_report_zone = null
		_apply_state(State.UNIT)


func _on_report(verdict: State, zone: Control) -> void:
	_report_zone = zone
	# CAST verdicts have no truthful preview without a castable view — fall back to the
	# unit copy (the only view there is while casting is demolished).
	if verdict != State.UNIT:
		verdict = State.UNIT
	_apply_state(verdict)


func _apply_state(state: State) -> void:
	_state = state
	_unit_view.visible = true
