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
var _ability_bar: HBoxContainer = null
var _end_turn: Button = null
var _cancel_pick: Button = null

var _slot_uis: Dictionary[Vector3i, SlotUI] = {}
# The board card faces, one per fielded unit, reused across refreshes so a unit's card is a
# stable node (reparented by the slots as the unit moves). Freed when the unit leaves play.
var _card_uis: Dictionary = {}
# The hand bar (the R7 bar slice) — renders the HandView composed each refresh; presses
# report back by index and this screen decides what a press means.
var _hand: Hand = null

var _span_active: bool = false
var _awaiting_command: bool = false
var _picking: bool = false
var _pick_candidates: Array[GameEntity] = []
var _cue_lines: PackedStringArray = []

# THE single owner of "what is the player doing right now" (the old combat's session,
# imported whole — see Interaction). The screen builds unit actions; slots consult roles.
var _interaction: Interaction = null
# The destination the committed place gesture already chose — consumed by pick_one so the
# core's destination ask is answered by the click that committed, not a second prompt. The
# seam between the old click-to-place gesture and the core's ask road.
var _pending_destination: Vector3i = Vector3i(-1, -1, -1)

signal commanded(ask: Event)
signal picked(choice: GameEntity)


func _ready() -> void:
	_build_ui()
	# The pick's consequences (preview, ability bar, cues) re-derive whenever the one
	# authority moves — the cards themselves re-derive their ring on their own poll.
	Selection.changed.connect(_on_selection_changed)
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
	_hand.set_input_enabled(true)
	_state_label.text = "Your command"
	refresh()


func end_player_span() -> void:
	_span_active = false
	_hand.set_input_enabled(false)
	_interaction.end_action()
	Selection.clear()
	_state_label.text = ""
	refresh()


func next_command() -> Event:
	_awaiting_command = true
	refresh()
	var ask: Event = await commanded
	_awaiting_command = false
	Selection.clear()
	return ask


func _on_end_turn() -> void:
	if _awaiting_command and not _picking:
		commanded.emit(null)


# ── The pick (UiPicker's surface) ─────────────────────────────────────────────────────

func pick_one(candidates: Array[GameEntity]) -> GameEntity:
	# The committed place gesture already chose its slot — answer the core's destination ask
	# with it and never open the prompt (see _pending_destination).
	if _pending_destination.x >= 0:
		var chosen: Vector3i = _pending_destination
		_pending_destination = Vector3i(-1, -1, -1)
		for candidate: GameEntity in candidates:
			if candidate is Slot and world.board_manager.address_of(candidate as Slot) == chosen:
				return candidate
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
	# A live click session (a selected hand unit's placement) gets the press first — the
	# same routing the old combat ran; a consumed press goes no further.
	if _interaction.handle_slot_press(_slot_uis[address]):
		return
	var slot: Slot = world.board_manager.slot_at(address)
	var occupant: Unit = SlotViewModel.occupant(slot)
	if _picking:
		if _pick_candidates.has(slot):
			picked.emit(slot)
		elif occupant != null and _pick_candidates.has(occupant):
			picked.emit(occupant)
		return
	if occupant != null:
		# ANY fielded unit is selectable at ANY time, both sides — as the original UI had
		# it (enemy units inspectable for information); only COMMANDS are window-gated.
		# The toggle writes THE one authority (R9); everything that shows a consequence —
		# the card's own ring, the preview, the ability bar — derives from it on the
		# changed-triggered refresh.
		if Selection.holds(occupant):
			Selection.clear()
		else:
			Selection.select(occupant)


func _on_hand_clicked(card: Card) -> void:
	if _picking:
		if _pick_candidates.has(card):
			picked.emit(card)
		return
	if _span_active and _awaiting_command:
		commanded.emit(Event.new(&"play", card))


func _on_ability_clicked(ability_name: StringName) -> void:
	var selected: Unit = _selected_unit()
	if _span_active and _awaiting_command and selected != null \
			and selected.allegiance == world.player_side():
		var ask := Event.new(&"use_ability", selected)
		ask.components.append(NameEventData.new(&"ability", ability_name))
		commanded.emit(ask)


# The fight's read of the one selection authority: the pick, when it is a unit of this
# fight (any other screen's leftover pick reads as nothing).
func _selected_unit() -> Unit:
	return Selection.current() as Unit


func _on_selection_changed(_subject: Variant) -> void:
	# The pick moving on ends a click session that was ABOUT the old pick (the old
	# session's own modal cleanup, generalized): a placement whose card is no longer
	# selected has no gesture left to finish.
	if _interaction != null and _interaction.active() and not _interaction.current().is_drag:
		var source: CardUI = _interaction.current().source
		if source == null or not is_instance_valid(source) 				or not Selection.holds(source.subject()):
			_interaction.end_action()
	if world != null:
		refresh()


func _exit_tree() -> void:
	Selection.changed.disconnect(_on_selection_changed)
	# A fight unit must not outlive the fight as the game-wide pick.
	if _selected_unit() != null:
		Selection.clear()


# ── The previews ──────────────────────────────────────────────────────────────────────
# The selected unit's would-be target, polled at interactive idle on a world COPY
# (Core §4; the coverage's simulation row): the twin's poll maps back by address.

func _preview_target_address() -> Vector3i:
	var selected: Unit = _selected_unit()
	if selected == null:
		return Vector3i(-1, -1, -1)
	var standing: Vector3i = TargetResolver.standing_address(selected)
	if standing.x < 0:
		return Vector3i(-1, -1, -1)
	var twin: World = world.copy()
	var twin_slot: Slot = twin.board_manager.slot_at(standing)
	var twin_unit: Unit = SlotViewModel.occupant(twin_slot)
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
	var seen: Array = []
	for address: Vector3i in _slot_uis:
		var unit: Unit = _paint_slot(address, _slot_uis[address], preview)
		if unit != null:
			seen.append(unit)
	# Card faces whose units left play (killed, buried) have no slot to stand in — free them.
	for unit: Variant in _card_uis.keys():
		if not seen.has(unit):
			var ui := _card_uis[unit] as CardUI
			if ui != null and is_instance_valid(ui):
				ui.queue_free()
			_card_uis.erase(unit)
	_rebuild_hand()
	_rebuild_abilities()
	_end_turn.disabled = not (_span_active and _awaiting_command and not _picking)


# Injects one slot widget's whole state — occupant card, ground view, cues — from the world's
# current facts, each concept through its own bridge (SlotViewModel for the cell, CardViewModel
# for the occupant's face; the widgets never read the engine). Returns the fielded unit so
# refresh() can retire the card faces of the departed.
func _paint_slot(address: Vector3i, slot_ui: SlotUI, preview: Vector3i) -> Unit:
	var slot: Slot = world.board_manager.slot_at(address)
	var unit: Unit = SlotViewModel.occupant(slot)
	if unit == null:
		if slot_ui.get_card() != null:
			slot_ui.clear_card()
	else:
		var ui := _card_uis.get(unit) as CardUI
		if ui == null:
			ui = CardUI.create(CardViewModel.unit_card(unit))
			_card_uis[unit] = ui
		else:
			ui.card_data = CardViewModel.unit_card(unit)
			ui.refresh()
		ui.set_status_views(CardViewModel.status_views(unit))
		if slot_ui.get_card() != ui:
			slot_ui.set_card(ui)
		# The card derives its own selection ring from the authority (CardUI's self-poll,
		# keyed by view_subject); this screen only states what the view is a view OF.
		ui.view_subject = unit
		# A tapped (exhausted) unit dims.
		ui.modulate = Color(0.55, 0.55, 0.6) if unit.get_stat(&"tapped") > 0.0 else Color.WHITE
	slot_ui.set_ground(SlotViewModel.ground_view(slot))
	# Cues: placement hints while the command is the player's to give; a pick's candidates wear
	# the valid-target cue; the selected unit's would-be victim wears the attack crosshair.
	slot_ui.set_open_hints(_span_active and _awaiting_command and not _picking)
	var highlighted: bool = _picking and (_pick_candidates.has(slot)
			or (unit != null and _pick_candidates.has(unit)))
	if highlighted:
		slot_ui.set_targetable(true)
		slot_ui.set_cue(SlotUI.Cue.TARGET_OK)
	else:
		# The live action's verdict for this slot — the old board's _present_slot, imported:
		# one role predicate drives cue, drop-accept and commit, so they cannot disagree.
		match _interaction.role_of(slot_ui):
			Interaction.Role.DESTINATION:
				slot_ui.set_targetable(false)
				slot_ui.set_cue(SlotUI.Cue.MOVE, _interaction.current().animated)
				slot_ui.set_move_button(not _interaction.current().is_drag
						and not _interaction.current().click_commit)
			Interaction.Role.TARGET_VALID:
				slot_ui.set_targetable(true)
				slot_ui.set_cue(SlotUI.Cue.TARGET_OK)
			Interaction.Role.TARGET_INVALID:
				slot_ui.set_targetable(false)
				slot_ui.set_cue(SlotUI.Cue.TARGET_BAD)
			_:
				slot_ui.set_targetable(false)
				slot_ui.reset_cue()
	slot_ui.set_attack_marker(address == preview)
	return unit


func _rebuild_hand() -> void:
	var candidates: Array[GameEntity] = []
	if _picking:
		candidates = _pick_candidates
	_hand.set_hand(HandViewModel.hand_view(world.player_side(), candidates))


# The bar reports where the press landed; the hand container's order IS the view's item
# order (HandViewModel walks it), so the index maps straight back to the card. A pick's
# candidate answers the pick; a spell plays; a unit toggles its selection (the old hand's
# gesture — placement then commits through the click session's cues).
func _on_hand_index_pressed(index: int) -> void:
	var members: Array[GameEntity] = world.player_side().get_container(&"hand").members
	if index < 0 or index >= members.size():
		return
	var card := members[index] as Card
	if _picking:
		if _pick_candidates.has(card):
			picked.emit(card)
		return
	if card is Spell:
		_on_hand_clicked(card)
		return
	_hand.toggle_select(index)


# A unit drag BEGINS an Interaction action and nothing else — cues, drop verdicts and
# commit all derive from the one action (the old board's drag wiring, imported).
func _wire_unit_drag(card_ui: CardUI) -> void:
	if not card_ui.unit_drag_started.is_connected(_on_unit_drag_started):
		card_ui.unit_drag_started.connect(_on_unit_drag_started)
		card_ui.unit_drag_ended.connect(_on_unit_drag_ended)


func _on_unit_drag_started(card_ui: CardUI) -> void:
	_interaction.begin(_make_place_action(card_ui, true, true))


func _on_unit_drag_ended(card_ui: CardUI) -> void:
	_interaction.end_drag(card_ui)   # the null present resets every cue structurally


# A hand unit's selection begins the placement session; deselection (or the pick moving on)
# ends it. Imported from the old combat's _on_hand_selection_changed.
func _on_hand_selection_changed(ui: CardUI) -> void:
	if ui != null:
		_interaction.begin(_make_place_action(ui, false, false))
	elif _interaction.active() and not _interaction.current().is_drag:
		_interaction.end_action()


# Place-from-hand, static selection — the old board's unit-action factory, its rules
# re-aimed at the core: empty own slots are DESTINATIONS while the command window is open;
# everything else stays NEUTRAL (a placement isn't a targeted effect, so irrelevant slots
# show no red X — deliberate policy). Commit hands the chosen slot to the play command.
func _make_place_action(card_ui: CardUI, animated: bool, is_drag: bool) -> Interaction.Action:
	var act := Interaction.Action.new()
	act.kind = Interaction.Action.Kind.UNIT
	act.source = card_ui
	act.animated = animated
	act.is_drag = is_drag
	act.click_commit = true
	act.role_check = func(slot_ui: SlotUI) -> int:
		if not slot_ui.own_side or slot_ui.get_card() != null:
			return Interaction.Role.NONE
		if _span_active and _awaiting_command:
			return Interaction.Role.DESTINATION
		return Interaction.Role.NONE
	act.on_commit = func(slot_ui: SlotUI) -> void:
		_commit_place(card_ui, slot_ui)
	return act


func _commit_place(card_ui: CardUI, slot_ui: SlotUI) -> void:
	if not (_span_active and _awaiting_command):
		return
	var card := card_ui.subject() as Card
	if card == null:
		return
	for address: Vector3i in _slot_uis:
		if _slot_uis[address] == slot_ui:
			_pending_destination = address
			break
	commanded.emit(Event.new(&"play", card))


func _rebuild_abilities() -> void:
	for child: Node in _ability_bar.get_children():
		child.queue_free()
	var selected: Unit = _selected_unit()
	if selected == null:
		return
	for ability_name: StringName in selected.abilities:
		var button := Button.new()
		button.text = String(ability_name)
		button.disabled = not (_span_active and _awaiting_command and not _picking)
		button.pressed.connect(_on_ability_clicked.bind(ability_name))
		_ability_bar.add_child(button)


# ── Construction ──────────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_interaction = Interaction.new()
	add_child(_interaction)
	# Cue rendering derives from the one `changed` signal — a gesture ending resets
	# everything structurally, with no per-path cleanup to forget.
	_interaction.changed.connect(func(_action: Interaction.Action) -> void:
		if world != null:
			refresh())
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
				var slot_ui := SlotUI.new()
				slot_ui.own_side = side_index == 0
				slot_ui.interaction = _interaction   # the drop gate's authority (drag's atom)
				slot_ui.pressed.connect(_on_slot_clicked.bind(address))
				(_player_grid if side_index == 0 else _enemy_grid).add_child(slot_ui)
				# Shrunk from the widget's authored size to fit the placeholder frame; the
				# widget's whole layout is size-relative, so it reads the same at any scale.
				slot_ui.custom_minimum_size = Vector2(110, 144)
				_slot_uis[address] = slot_ui

	_ability_bar = HBoxContainer.new()
	_ability_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(_ability_bar)

	var bottom := HBoxContainer.new()
	root.add_child(bottom)
	# The mana reading rides INSIDE the bar as its leftmost column — mana is what the hand
	# spends (the bar's authored left_widget seat).
	_mana_label = Label.new()
	_mana_label.text = "Mana 0/0"
	_hand = Hand.new()
	add_child(_hand)
	_hand.build_into(bottom, _mana_label)
	_hand.set_card_size(Vector2(110, 144))   # the slots' size — one card scale per screen
	_hand.card_pressed.connect(_on_hand_index_pressed)
	_hand.selection_changed.connect(_on_hand_selection_changed)
	_hand.wire_unit_card = _wire_unit_drag
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
	# The gutter is the widget's own constant — the ground frames (half a gap each) only tile
	# into one field when the layout honours the same number.
	grid.add_theme_constant_override("h_separation", SlotUI.SLOT_GAP)
	grid.add_theme_constant_override("v_separation", SlotUI.SLOT_GAP)
	parent.add_child(grid)
	return grid
