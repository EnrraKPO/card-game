class_name EnemyIntel
extends PanelContainer

# What the CPU still has to spend, said out loud — the enemy's half of the two readouts the
# player already trusts for their own side (the mana gauge in the hand bar, the cards in it).
# Sits at the TOP of combat's action column, level with the enemy's half of the board, and
# takes its height out of the Ready button below it.
#
# Two numbers, both live:
#   · MANA — current / max, with the same lit-and-dim chunk strip the player's gauge uses, so
#     the two read as one instrument. The CPU refills at the start of every round and spends
#     during its own turn, so through the player's turn this shows what it did NOT spend.
#   · CARDS — how many plays it is holding. The enemy really does have a hand and a draw pile
#     (CombatSide, same object the player has); this is its size, which is exactly "what it
#     could still bring to bear". Nothing here judges whether a given card is affordable right
#     now — that is what the mana strip above it is for.
#
# In DEBUG BUILDS the widget is clickable and opens the actual list (see EnemyHandOverlay).
# That is a development affordance, not a game mechanic: in a normal build the panel is inert
# and the player only ever gets the two counts.
#
# SELF-POLLING (the CardUI.derive_presentation pattern): the widget diffs its own three
# numbers every frame and redraws only when one moves. A card leaving the enemy hand by being
# PLAYED emits no signal at all (CombatSide.remove_from_hand is deliberately silent — the play
# flow removes its own UI), so a push-based version would go stale exactly when the player is
# watching the CPU spend. Nothing outside needs to remember to refresh this.

const PAD := 10
const CHUNK_H := 18.0        # the mana strip's height
const CHUNK_MIN_W := 3.0     # chunks thin out rather than overflow — the ramp is uncapped
const TAG_COLOR := Color(0.94, 0.74, 0.78)    # the enemy zone's rose, lifted to label weight
const VALUE_COLOR := Color(0.97, 0.94, 0.96)

var _side: CombatSide = null
var _chunks: HBoxContainer
var _mana_value: Label
var _cards_value: Label
# The last state drawn — the poll's whole memory. -1 forces the first pass to build.
var _seen := Vector3i(-1, -1, -1)


static func make(side: CombatSide) -> EnemyIntel:
	var w := EnemyIntel.new()
	w._side = side
	return w


func _ready() -> void:
	var compact := UIScale.is_compact()
	size_flags_horizontal = SIZE_EXPAND_FILL
	size_flags_vertical = SIZE_SHRINK_BEGIN   # exactly as tall as it needs; the rest is Ready's
	# Only debug builds take the click; otherwise the panel is scenery and must never eat a
	# press meant for the board behind it.
	mouse_filter = Control.MOUSE_FILTER_STOP if DebugConfig.enabled() else Control.MOUSE_FILTER_PASS
	_refresh_tip()

	# A PanelContainer, not a Panel with an anchored child: the frame then takes its height from
	# the rows inside it, at whatever font size the form factor asks for, instead of from a
	# hand-tuned constant that clips the last row the moment a label grows.
	var track := StyleBoxFlat.new()
	track.bg_color = ScreenUI.MANA_TRACK_BG
	track.set_corner_radius_all(12)
	track.set_border_width_all(2)
	track.border_color = ScreenUI.MANA_TRACK_BORDER
	track.set_content_margin_all(PAD)
	add_theme_stylebox_override("panel", track)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(col)

	var title := Label.new()
	title.text = Loc.t("combat.enemy_tag")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 26 if compact else 20)
	title.add_theme_color_override("font_color", TAG_COLOR)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(title)

	_mana_value = _stat_row(col, Loc.t("combat.mana_tag"), compact)

	# The chunk strip: one segment per point of max mana, lit up to what is left. Horizontal
	# here (the player's gauge stacks vertically) because this widget is wide and short — the
	# instrument is the same, the axis follows the space it lives in.
	_chunks = HBoxContainer.new()
	_chunks.custom_minimum_size.y = CHUNK_H
	_chunks.add_theme_constant_override("separation", 2)
	_chunks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_chunks)

	_cards_value = _stat_row(col, Loc.t("combat.enemy_cards_tag"), compact)


# One "TAG ..... value" line: the name on the left, the number hard right, the gap between
# them doing the work of an alignment guide. Returns the value label for the poll to write.
func _stat_row(parent: VBoxContainer, tag_text: String, compact: bool) -> Label:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(row)

	var tag := Label.new()
	tag.text = tag_text
	tag.add_theme_font_size_override("font_size", 20 if compact else 15)
	tag.add_theme_color_override("font_color", TAG_COLOR.darkened(0.25))
	tag.size_flags_horizontal = SIZE_EXPAND_FILL
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(tag)

	var value := Label.new()
	value.add_theme_font_size_override("font_size", 34 if compact else 26)
	value.add_theme_color_override("font_color", VALUE_COLOR)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(value)
	return value


# The poll (see the header): three numbers in, a redraw only when one of them moved.
func _process(_delta: float) -> void:
	if _side == null or _mana_value == null:
		return
	var now := Vector3i(_side.mana, _side.max_mana, _side.hand.size())
	if now == _seen:
		return
	_seen = now
	_render(now)


func _render(state: Vector3i) -> void:
	_mana_value.text = "%d/%d" % [state.x, state.y]
	_cards_value.text = str(state.z)

	var want := maxi(state.y, 0)
	if _chunks.get_child_count() != want:
		for ch in _chunks.get_children():
			_chunks.remove_child(ch)
			ch.queue_free()
		for _i in want:
			_chunks.add_child(_make_chunk())
	# Lit from the LEFT: the enemy spends left to right, so the dim tail is what it used.
	var chunks := _chunks.get_children()
	for i in chunks.size():
		var sb := StyleBoxFlat.new()
		sb.bg_color = ScreenUI.MANA_LIT if i < state.x else ScreenUI.MANA_DIM
		sb.set_corner_radius_all(3)
		(chunks[i] as Panel).add_theme_stylebox_override("panel", sb)
	_refresh_tip()


func _make_chunk() -> Panel:
	var chunk := Panel.new()
	chunk.custom_minimum_size = Vector2(CHUNK_MIN_W, CHUNK_H)
	chunk.size_flags_horizontal = SIZE_EXPAND_FILL
	chunk.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return chunk


func _refresh_tip() -> void:
	var mana := _side.mana if _side != null else 0
	var max_mana := _side.max_mana if _side != null else 0
	var held := _side.hand.size() if _side != null else 0
	var text := Loc.t("combat.enemy_tip", {"mana": mana, "max": max_mana, "n": held})
	if DebugConfig.enabled():
		text += "\n" + Loc.t("combat.enemy_tip_debug")
	UIScale.tip(self, text)


# Debug only: the actual cards. Guarded here as well as by mouse_filter, so no future layout
# change can turn a normal build's panel into a peek at the CPU's hand.
func _gui_input(event: InputEvent) -> void:
	if not DebugConfig.enabled() or _side == null:
		return
	var pressed := (event is InputEventMouseButton and (event as InputEventMouseButton).pressed) \
		or (event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed)
	if pressed:
		accept_event()
		EnemyHandOverlay.open(self, _side)
