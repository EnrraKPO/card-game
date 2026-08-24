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

# ── The declared preview (the old board's declare_preview, on the core) ───────────────
# SIDE-NEUTRAL: the pivot may belong to either army. The declaration is "pivot standing
# HERE"; everything threat-shaped derives from one world copy built per declaration — the
# pivot's would-be victim (the crosshair) and every unit whose own targeting resolves to
# the pivot (the red menace read).
var _declared_pivot: Unit = null
var _declared_at: Vector3i = Vector3i(-1, -1, -1)
var _preview_crosshair: Vector3i = Vector3i(-1, -1, -1)
var _menacing: Array[Unit] = []
# Hover tracking during a live session (rect tests rather than mouse_entered — occupant
# cards would swallow the enter/exit events): the hovered DESTINATION slot carries the
# landing phantom (drag) or the white outline (static), and declares the preview from it.
var _hover_slot: SlotUI = null
var _phantom_slot: SlotUI = null

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


func _on_selection_changed(subject: Variant) -> void:
	# The pick moving on ends a click session that was ABOUT the old pick (the old
	# session's own modal cleanup, generalized): a placement whose card is no longer
	# selected has no gesture left to finish.
	if _interaction != null and _interaction.active() and not _interaction.current().is_drag:
		var source: CardUI = _interaction.current().source
		if source == null or not is_instance_valid(source) \
				or not Selection.holds(source.subject()):
			_interaction.end_action()
	# Selecting an OWN fielded unit during the command window begins the move session —
	# destination cues light, the commit is drag or MoveButton only (click_commit false:
	# a stray tap on a slot must never move a fielded unit; the old rule).
	if world != null and _interaction != null and not _interaction.active() \
			and subject is Unit and _span_active and _awaiting_command:
		var unit := subject as Unit
		if unit.allegiance == world.player_side() and not unit.is_building \
				and TargetResolver.standing_address(unit).x >= 0 \
				and _card_uis.has(unit):
			_interaction.begin(_make_unit_action(_card_uis[unit], false, false))
	if world != null:
		refresh()


func _exit_tree() -> void:
	Selection.changed.disconnect(_on_selection_changed)
	# A fight unit must not outlive the fight as the game-wide pick.
	if _selected_unit() != null:
		Selection.clear()


# ── The declared preview ──────────────────────────────────────────────────────────────
# Polled at interactive idle on a world COPY (Core §4; the coverage's simulation row): the
# twin's polls map back by address. Idempotent on an unchanged declaration.

func declare_preview(pivot: Unit, at: Vector3i) -> void:
	if pivot == _declared_pivot and at == _declared_at:
		return
	_declared_pivot = pivot
	_declared_at = at
	_rebuild_preview()


func clear_preview() -> void:
	declare_preview(null, Vector3i(-1, -1, -1))


# The hypothetical: the real world with one change — the pivot stands at its declared spot
# (a hand pivot enters the board; a fielded pivot moves; anything sitting there is evicted,
# since destinations are normally empty and the hypothetical is "INSTEAD"). All writes land
# on the throwaway copy through the authority's bare primitives, no events.
func _rebuild_preview() -> void:
	_preview_crosshair = Vector3i(-1, -1, -1)
	_menacing = []
	if _declared_pivot == null or world == null:
		return
	var twin_world: World = world.copy()
	var pivot_twin: Unit = _twin_of(_declared_pivot, twin_world)
	if pivot_twin == null:
		return
	if _declared_at.x >= 0:
		var declared_slot: Slot = twin_world.board_manager.slot_at(_declared_at)
		var seat: EntityContainer = declared_slot.get_container(&"slotted_unit")
		if not seat.members.has(pivot_twin):
			var sitting: Unit = SlotViewModel.occupant(declared_slot)
			if sitting != null:
				WriteAuthority.remove(seat, sitting)
			if pivot_twin.housing != null:
				WriteAuthority.remove(pivot_twin.housing, pivot_twin)
			WriteAuthority.insert(seat, pivot_twin)
	var targets: Array[GameEntity] = pivot_twin.main_action_targets()
	if not targets.is_empty():
		_preview_crosshair = TargetResolver.standing_address(targets[0])
	# Every fielded unit whose OWN targeting resolves to the pivot in that world menaces it —
	# mapped back to the live units by address (addresses are identical across the copy).
	for side_index: int in 2:
		for row: int in BoardGeometry.ROWS:
			for col: int in BoardGeometry.COLS:
				var address := Vector3i(side_index, row, col)
				var twin_unit: Unit = SlotViewModel.occupant(
						twin_world.board_manager.slot_at(address))
				if twin_unit == null or twin_unit == pivot_twin:
					continue
				if twin_unit.main_action_targets().has(pivot_twin):
					var live: Unit = SlotViewModel.occupant(
							world.board_manager.slot_at(address))
					if live != null:
						_menacing.append(live)


# The pivot's twin in the copy: a fielded pivot stands at the same address; a hand pivot
# holds the same index in the copy's hand container.
func _twin_of(pivot: Unit, twin_world: World) -> Unit:
	var standing: Vector3i = TargetResolver.standing_address(pivot)
	if standing.x >= 0:
		return SlotViewModel.occupant(twin_world.board_manager.slot_at(standing))
	if pivot.housing != null and pivot.housing.name == &"hand":
		var index: int = pivot.housing.members.find(pivot)
		var twin_hand: Array[GameEntity] = twin_world.player_side() \
				.get_container(&"hand").members
		if index >= 0 and index < twin_hand.size():
			return twin_hand[index] as Unit
	return null


# The baseline declaration when no destination is hovered: a selected fielded unit previews
# from where it stands; a hand card has no origin to preview from until it hovers a landing
# slot (the old board's exact policy).
func _derive_baseline_preview() -> void:
	if _hover_slot != null or _phantom_slot != null:
		return
	var selected: Unit = _selected_unit()
	if selected != null and TargetResolver.standing_address(selected).x >= 0:
		declare_preview(selected, TargetResolver.standing_address(selected))
	else:
		clear_preview()


# ── The hover engine (rect polling while a session is live) ───────────────────────────

func _process(_delta: float) -> void:
	if not _interaction.active():
		return
	var act: Interaction.Action = _interaction.current()
	var slot: SlotUI = _hovered_destination()
	if act.is_drag:
		if slot != _phantom_slot:
			_set_phantom_slot(slot)
	else:
		if slot != _hover_slot:
			_set_hover_slot(slot)


func _hovered_destination() -> SlotUI:
	var mouse: Vector2 = get_global_mouse_position()
	for address: Vector3i in _slot_uis:
		var slot_ui: SlotUI = _slot_uis[address]
		if slot_ui.get_global_rect().has_point(mouse) \
				and _interaction.role_of(slot_ui) == Interaction.Role.DESTINATION:
			return slot_ui
	return null


# The move button's commit — routed through the session's commit_press: the same role
# re-validation and end-then-commit order as clicks and drops, minus the click_commit gate
# (the button is an explicit control that exists only to commit; a press on it is not
# stray).
func _on_move_button_pressed(slot_ui: SlotUI) -> void:
	_interaction.commit_press(slot_ui)


# The move button's hover: mount the landing phantom in its slot and declare the targeting
# preview from that spot — the same information the drag phantom carries, for exactly as
# long as the cursor sits on the button.
func _on_move_button_hover(on: bool, slot_ui: SlotUI) -> void:
	if not _interaction.active() or _interaction.current().is_drag:
		return
	if on and _interaction.role_of(slot_ui) == Interaction.Role.DESTINATION:
		_set_phantom_slot(slot_ui)
	elif not on and slot_ui == _phantom_slot:
		_set_phantom_slot(null)


# Drag: the hovered landing slot mounts the translucent projection of the dragged unit and
# declares the targeting preview from that spot.
func _set_phantom_slot(slot_ui: SlotUI) -> void:
	if slot_ui == _phantom_slot:
		return
	if _phantom_slot != null and is_instance_valid(_phantom_slot):
		_phantom_slot.unmount_phantom()
	_phantom_slot = slot_ui
	if slot_ui != null and _interaction.active():
		var source: CardUI = _interaction.current().source
		if source != null and is_instance_valid(source):
			slot_ui.mount_phantom(source.make_ghost_view())
			declare_preview(source.subject() as Unit, _address_of_slot_ui(slot_ui))
			refresh()
			return
	clear_preview()
	_derive_baseline_preview()
	refresh()


# Static selection: the hovered destination wears the white outline (and its MOVE arrow
# bobs — SlotUI.set_hovered) and declares the same landing preview a drag phantom would.
func _set_hover_slot(slot_ui: SlotUI) -> void:
	if slot_ui == _hover_slot:
		return
	if _hover_slot != null and is_instance_valid(_hover_slot):
		_hover_slot.set_hovered(false)
	_hover_slot = slot_ui
	if slot_ui != null and _interaction.active():
		slot_ui.set_hovered(true)
		var source: CardUI = _interaction.current().source
		if source != null and is_instance_valid(source):
			declare_preview(source.subject() as Unit, _address_of_slot_ui(slot_ui))
			refresh()
			return
	clear_preview()
	_derive_baseline_preview()
	refresh()


func _address_of_slot_ui(slot_ui: SlotUI) -> Vector3i:
	for address: Vector3i in _slot_uis:
		if _slot_uis[address] == slot_ui:
			return address
	return Vector3i(-1, -1, -1)


# ── Rendering ─────────────────────────────────────────────────────────────────────────

func refresh() -> void:
	if world == null:
		return
	_round_label.text = "Round %d" % roundi(world.game.get_stat(&"round"))
	_mana_label.text = "Mana %d/%d" % [roundi(world.player_side().get_stat(&"mana")),
			roundi(world.player_side().get_stat(&"mana_capacity"))]
	_enemy_label.text = "Enemy %d/%d" % [roundi(world.enemy_side().get_stat(&"mana")),
			roundi(world.enemy_side().get_stat(&"mana_capacity"))]
	_derive_baseline_preview()
	var preview: Vector3i = _preview_crosshair
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
		# An own fielded non-building unit can be picked up to reposition (buildings root
		# in place; the opponent's units are not the player's to lift) — the old drag
		# refusals, structural on the paint pass instead of queried mid-drag.
		ui.draggable = unit.allegiance == world.player_side() and not unit.is_building
		if ui.draggable:
			_wire_unit_drag(ui)
		# A tapped (exhausted) unit dims.
		ui.modulate = Color(0.55, 0.55, 0.6) if unit.get_stat(&"tapped") > 0.0 else Color.WHITE
		# The menace read: this unit's own targeting resolves to the previewed pivot.
		ui.set_threat_highlight(_menacing.has(unit))
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


# Session lifecycle: the hover engine polls only while a session is live; a session ending
# tears its hover furniture down structurally (phantom, outline, declaration) — no per-path
# cleanup to forget (the old present-null teardown, imported).
func _on_interaction_changed(action: Interaction.Action) -> void:
	set_process(action != null)
	if action == null:
		if _phantom_slot != null and is_instance_valid(_phantom_slot):
			_phantom_slot.unmount_phantom()
		_phantom_slot = null
		if _hover_slot != null and is_instance_valid(_hover_slot):
			_hover_slot.set_hovered(false)
		_hover_slot = null
		clear_preview()
	if world != null:
		refresh()


# A unit drag BEGINS an Interaction action and nothing else — cues, drop verdicts and
# commit all derive from the one action (the old board's drag wiring, imported).
func _wire_unit_drag(card_ui: CardUI) -> void:
	if not card_ui.unit_drag_started.is_connected(_on_unit_drag_started):
		card_ui.unit_drag_started.connect(_on_unit_drag_started)
		card_ui.unit_drag_ended.connect(_on_unit_drag_ended)


func _on_unit_drag_started(card_ui: CardUI) -> void:
	_interaction.begin(_make_unit_action(card_ui, true, true))


func _on_unit_drag_ended(card_ui: CardUI) -> void:
	_interaction.end_drag(card_ui)   # the null present resets every cue structurally


# A hand unit's selection begins the placement session; deselection (or the pick moving on)
# ends it. Imported from the old combat's _on_hand_selection_changed.
func _on_hand_selection_changed(ui: CardUI) -> void:
	if ui != null:
		_interaction.begin(_make_unit_action(ui, false, false))
	elif _interaction.active() and not _interaction.current().is_drag:
		_interaction.end_action()


# Place-from-hand and reposition, drag or static selection — one action (the old board's
# make_unit_action, its rules re-aimed at the core): empty own slots are DESTINATIONS while
# the command window is open; everything else stays NEUTRAL (a move isn't a targeted
# effect, so irrelevant slots show no red X — deliberate policy). Playing out of hand may
# be FINISHED with a tap; moving a fielded unit is drag-or-button only (click_commit) — the
# destination cues still light on selection, because they are what teaches that the unit
# can be repositioned at all; only the stray tap is refused. NOTE (surfaced adaptation):
# the cues light every empty own slot — the Move road's own conditions re-validate at the
# commit through the core's ask, so an ineligible pick is refused there, never silently.
func _make_unit_action(card_ui: CardUI, animated: bool, is_drag: bool) -> Interaction.Action:
	var act := Interaction.Action.new()
	act.kind = Interaction.Action.Kind.UNIT
	act.source = card_ui
	act.animated = animated
	act.is_drag = is_drag
	var subject: Variant = card_ui.subject()
	var from_hand: bool = subject is Card and (subject as Card).housing != null \
			and (subject as Card).housing.name == &"hand"
	act.click_commit = from_hand
	act.role_check = func(slot_ui: SlotUI) -> int:
		if not slot_ui.own_side or slot_ui.get_card() != null:
			return Interaction.Role.NONE
		if _span_active and _awaiting_command:
			return Interaction.Role.DESTINATION
		return Interaction.Role.NONE
	act.on_commit = func(slot_ui: SlotUI) -> void:
		if from_hand:
			_commit_place(card_ui, slot_ui)
		else:
			_commit_move(card_ui, slot_ui)
	return act


func _commit_place(card_ui: CardUI, slot_ui: SlotUI) -> void:
	if not (_span_active and _awaiting_command):
		return
	var card := card_ui.subject() as Card
	if card == null:
		return
	_pending_destination = _address_of_slot_ui(slot_ui)
	commanded.emit(Event.new(&"play", card))


# The reposition commit: the chosen slot answers the Move ability's destination ask — the
# same seam the place commit uses, on the use_ability road (A3/A9: Move is machinery on
# every non-building unit, free).
func _commit_move(card_ui: CardUI, slot_ui: SlotUI) -> void:
	if not (_span_active and _awaiting_command):
		return
	var unit := card_ui.subject() as Unit
	if unit == null:
		return
	_pending_destination = _address_of_slot_ui(slot_ui)
	var ask := Event.new(&"use_ability", unit)
	ask.components.append(NameEventData.new(&"ability", &"move"))
	commanded.emit(ask)


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
	_interaction.changed.connect(_on_interaction_changed)
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
				slot_ui.move_pressed.connect(_on_move_button_pressed.bind(slot_ui))
				slot_ui.move_hover.connect(_on_move_button_hover.bind(slot_ui))
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
