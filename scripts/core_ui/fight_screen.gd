class_name FightScreen
extends Control

# The fight, driven from the shell on the new core (IMPLEMENTATION_PLAN §2 Phase 5): the
# world and its clock behind the screen; the player's span served by clicks through the
# PlayerCommander; hand-picks consulting the player through the UiPicker; payability and
# the target poll read from resolve for the previews — the poll runs on a world COPY, as
# the slice's coverage demands. This first iteration presents functionally — chips,
# highlights, and a cue log; the full visual language re-enters at the parity pass
# (A10: partial functionality through iteration).
#
# The launcher states the fight: FightScreen.next_fight = {"seed": int, "content":
# {"cards": [envelopes], "statuses": [...], "relics": [...]}, "player": <Genesis side
# config>, "enemy": <...>}. Unconfigured, the screen runs THE SLICE'S FIXED FIGHT
# (data/slice_fight.json — IMPLEMENTATION_PLAN §1: the slice runs as a fixed fight
# launched from the existing shell; wiring into real runs is parity work). A missing
# slice file refuses loudly and stands empty.

const SLICE_FIGHT_PATH := "res://data/slice_fight.json"

static var next_fight: Dictionary = {}


static func slice_fight() -> Dictionary:
	var text := FileAccess.get_file_as_string(SLICE_FIGHT_PATH)
	if text.is_empty():
		push_error("FightScreen: %s is missing or empty" % SLICE_FIGHT_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		push_error("FightScreen: %s does not parse" % SLICE_FIGHT_PATH)
		return {}
	return parsed

var world: World = null

var _round_label: Label = null
var _mana_label: Label = null
var _enemy_label: Label = null
var _state_label: Label = null
var _cue_log: Label = null
var _player_grid: GridContainer = null
var _enemy_grid: GridContainer = null
var _hand_row: HBoxContainer = null
var _ability_bar: HBoxContainer = null
var _end_turn: Button = null
var _cancel_pick: Button = null

var _slot_buttons: Dictionary[Vector3i, Button] = {}
var _hand_buttons: Dictionary = {}

var _span_active: bool = false
var _awaiting_command: bool = false
var _picking: bool = false
var _pick_candidates: Array[GameEntity] = []
var _selected: Unit = null
var _cue_lines: PackedStringArray = []

signal commanded(ask: Event)
signal picked(choice: GameEntity)


func _ready() -> void:
	_build_ui()
	if next_fight.is_empty():
		next_fight = slice_fight()
	if next_fight.is_empty():
		_state_label.text = "No fight configured."
		return
	var fight: Dictionary = next_fight
	next_fight = {}
	ContentLibrary.clear()
	var content: Dictionary = fight.get("content", {})
	for envelope: Variant in content.get("cards", []):
		ContentLibrary.register_card(envelope)
	for envelope: Variant in content.get("statuses", []):
		ContentLibrary.register_status(envelope)
	for envelope: Variant in content.get("relics", []):
		ContentLibrary.register_relic(envelope)
	world = World.new(int(fight.get("seed", 1)))
	world.outlet = FightPresenter.new(self)
	world.picker = UiPicker.new(self)
	world.clock.player_commander = PlayerCommander.new(self)
	world.clock.enemy_commander = EnemyCommander.new()
	if not Genesis.setup(world, fight.get("player", {}), fight.get("enemy", {})):
		_state_label.text = "Genesis refused the fight's configuration."
		return
	refresh()
	_run.call_deferred()


func _run() -> void:
	var outcome: StringName = await world.clock.run_fight()
	refresh()
	_state_label.text = "VICTORY" if outcome == &"victory" else "DEFEAT"
	_end_turn.text = "Leave"
	_end_turn.disabled = false
	_end_turn.pressed.disconnect(_on_end_turn)
	_end_turn.pressed.connect(_leave)


func _leave() -> void:
	var destination := "res://scenes/map.tscn" if GameData.current_run != null \
			else "res://scenes/entry_screen.tscn"
	Nav.goto(destination)


# ── The command span (PlayerCommander's surface) ──────────────────────────────────────

func begin_player_span() -> void:
	_span_active = true
	_state_label.text = "Your command"
	refresh()


func end_player_span() -> void:
	_span_active = false
	_select(null)
	_state_label.text = ""
	refresh()


func next_command() -> Event:
	_awaiting_command = true
	refresh()
	var ask: Event = await commanded
	_awaiting_command = false
	_select(null)
	return ask


func _on_end_turn() -> void:
	if _awaiting_command and not _picking:
		commanded.emit(null)


# ── The pick (UiPicker's surface) ─────────────────────────────────────────────────────

func pick_one(candidates: Array[GameEntity]) -> GameEntity:
	_picking = true
	_pick_candidates = candidates
	_cancel_pick.visible = true
	_state_label.text = "Pick a target"
	refresh()
	var choice: GameEntity = await picked
	_picking = false
	_pick_candidates = []
	_cancel_pick.visible = false
	_state_label.text = "Your command" if _span_active else ""
	refresh()
	return choice


func _on_cancel_pick() -> void:
	if _picking:
		picked.emit(null)


# ── The presenter's surface ───────────────────────────────────────────────────────────

func beat(_visual: StringName, _recipients: Array[GameEntity], seconds: float) -> void:
	if is_inside_tree():
		await get_tree().create_timer(seconds).timeout


func show_cue(visual: StringName, recipient: GameEntity, magnitude: float) -> void:
	var who: String = recipient.display_name if recipient != null else ""
	var line := "%s %s" % [visual, who]
	if magnitude != 0.0:
		line += " (%d)" % roundi(magnitude)
	_cue_lines.append(line)
	while _cue_lines.size() > 5:
		_cue_lines.remove_at(0)
	_cue_log.text = "\n".join(_cue_lines)


# ── Clicks ────────────────────────────────────────────────────────────────────────────

func _on_slot_clicked(address: Vector3i) -> void:
	var slot: Slot = world.board_manager.slot_at(address)
	var occupant: Unit = _occupant(slot)
	if _picking:
		if _pick_candidates.has(slot):
			picked.emit(slot)
		elif occupant != null and _pick_candidates.has(occupant):
			picked.emit(occupant)
		return
	if _span_active and _awaiting_command and occupant != null \
			and occupant.allegiance == world.player_side():
		_select(occupant if _selected != occupant else null)


func _on_hand_clicked(card: Card) -> void:
	if _picking:
		if _pick_candidates.has(card):
			picked.emit(card)
		return
	if _span_active and _awaiting_command:
		commanded.emit(Event.new(&"play", card))


func _on_ability_clicked(ability_name: StringName) -> void:
	if _span_active and _awaiting_command and _selected != null:
		var ask := Event.new(&"use_ability", _selected)
		ask.components.append(NameEventData.new(&"ability", ability_name))
		commanded.emit(ask)


func _select(unit: Unit) -> void:
	_selected = unit
	refresh()


# ── The previews ──────────────────────────────────────────────────────────────────────
# The selected unit's would-be target, polled at interactive idle on a world COPY
# (Core §4; the coverage's simulation row): the twin's poll maps back by address.

func _preview_target_address() -> Vector3i:
	if _selected == null:
		return Vector3i(-1, -1, -1)
	var standing: Vector3i = TargetResolver.standing_address(_selected)
	if standing.x < 0:
		return Vector3i(-1, -1, -1)
	var twin: World = world.copy()
	var twin_slot: Slot = twin.board_manager.slot_at(standing)
	var twin_unit: Unit = _occupant(twin_slot)
	if twin_unit == null:
		return Vector3i(-1, -1, -1)
	var targets: Array[GameEntity] = twin_unit.main_action_targets()
	if targets.is_empty():
		return Vector3i(-1, -1, -1)
	return TargetResolver.standing_address(targets[0])


# ── Rendering ─────────────────────────────────────────────────────────────────────────

func refresh() -> void:
	if world == null:
		return
	_round_label.text = "Round %d" % roundi(world.game.get_stat(&"round"))
	_mana_label.text = "Mana %d/%d" % [roundi(world.player_side().get_stat(&"mana")),
			roundi(world.player_side().get_stat(&"mana_capacity"))]
	_enemy_label.text = "Enemy %d/%d" % [roundi(world.enemy_side().get_stat(&"mana")),
			roundi(world.enemy_side().get_stat(&"mana_capacity"))]
	var preview: Vector3i = _preview_target_address()
	for address: Vector3i in _slot_buttons:
		_paint_slot(address, _slot_buttons[address], preview)
	_rebuild_hand()
	_rebuild_abilities()
	_end_turn.disabled = not (_span_active and _awaiting_command and not _picking)


func _paint_slot(address: Vector3i, button: Button, preview: Vector3i) -> void:
	var slot: Slot = world.board_manager.slot_at(address)
	var unit: Unit = _occupant(slot)
	if unit == null:
		button.text = "·"
	else:
		var marks := ""
		if unit.is_king:
			marks += "K"
		if unit.is_building:
			marks += "B"
		if unit.get_stat(&"tapped") > 0.0:
			marks += "T"
		var statuses := ""
		for member: GameEntity in unit.get_container(&"contained").members:
			if member is Status:
				statuses += "\n%s x%d" % [(member as Status).status_id,
						roundi(member.get_stat(&"stacks"))]
		button.text = "%s %s\nA%d H%d+%d%s" % [unit.display_name, marks,
				roundi(unit.get_stat(&"attack")), roundi(unit.get_stat(&"health")),
				roundi(unit.get_stat(&"shield")), statuses]
	var highlighted: bool = _picking and (_pick_candidates.has(slot)
			or (unit != null and _pick_candidates.has(unit)))
	if highlighted:
		button.modulate = Color(0.6, 1.0, 0.6)
	elif unit != null and unit == _selected:
		button.modulate = Color(1.0, 1.0, 0.5)
	elif address == preview:
		button.modulate = Color(1.0, 0.6, 0.6)
	else:
		button.modulate = Color.WHITE


func _rebuild_hand() -> void:
	for child: Node in _hand_row.get_children():
		child.queue_free()
	_hand_buttons.clear()
	for member: GameEntity in world.player_side().get_container(&"hand").members:
		var card := member as Card
		var button := Button.new()
		button.text = "%s (%d)\nA%d H%d" % [card.display_name, roundi(card.get_stat(&"cost")),
				roundi(card.get_stat(&"attack")) if card is Unit else 0,
				roundi(card.get_stat(&"health")) if card is Unit else 0]
		if card is Spell:
			button.text = "%s (%d)\nspell" % [card.display_name, roundi(card.get_stat(&"cost"))]
		var pickable: bool = _picking and _pick_candidates.has(card)
		button.disabled = not pickable and not (_span_active and _awaiting_command
				and not _picking and card.payable())
		if pickable:
			button.modulate = Color(0.6, 1.0, 0.6)
		button.pressed.connect(_on_hand_clicked.bind(card))
		_hand_row.add_child(button)
		_hand_buttons[card] = button


func _rebuild_abilities() -> void:
	for child: Node in _ability_bar.get_children():
		child.queue_free()
	if _selected == null:
		return
	for ability_name: StringName in _selected.abilities:
		var button := Button.new()
		button.text = String(ability_name)
		button.disabled = not (_span_active and _awaiting_command and not _picking)
		button.pressed.connect(_on_ability_clicked.bind(ability_name))
		_ability_bar.add_child(button)


func _occupant(slot: Slot) -> Unit:
	if slot == null:
		return null
	var members: Array[GameEntity] = slot.get_container(&"slotted_unit").members
	return members[0] as Unit if not members.is_empty() else null


# ── Construction ──────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var top := HBoxContainer.new()
	root.add_child(top)
	_round_label = _label(top, "Round 0")
	_enemy_label = _label(top, "")
	_state_label = _label(top, "")
	_state_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_state_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_cue_log = _label(top, "")
	_cue_log.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	var mid := HBoxContainer.new()
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mid.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(mid)
	_player_grid = _grid(mid)
	var line := VSeparator.new()
	mid.add_child(line)
	_enemy_grid = _grid(mid)
	for side_index: int in 2:
		for row: int in BoardGeometry.ROWS:
			for col: int in BoardGeometry.COLS:
				var address := Vector3i(side_index, row, col)
				var button := Button.new()
				button.custom_minimum_size = Vector2(110, 84)
				button.pressed.connect(_on_slot_clicked.bind(address))
				(_player_grid if side_index == 0 else _enemy_grid).add_child(button)
				_slot_buttons[address] = button

	_ability_bar = HBoxContainer.new()
	_ability_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(_ability_bar)

	var bottom := HBoxContainer.new()
	root.add_child(bottom)
	_mana_label = _label(bottom, "Mana 0/0")
	_hand_row = HBoxContainer.new()
	_hand_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(_hand_row)
	_cancel_pick = Button.new()
	_cancel_pick.text = "Cancel"
	_cancel_pick.visible = false
	_cancel_pick.pressed.connect(_on_cancel_pick)
	bottom.add_child(_cancel_pick)
	_end_turn = Button.new()
	_end_turn.text = "End Turn"
	_end_turn.disabled = true
	_end_turn.pressed.connect(_on_end_turn)
	bottom.add_child(_end_turn)


func _label(parent: Control, text: String) -> Label:
	var label := Label.new()
	label.text = text
	parent.add_child(label)
	return label


func _grid(parent: Control) -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = BoardGeometry.COLS
	parent.add_child(grid)
	return grid
