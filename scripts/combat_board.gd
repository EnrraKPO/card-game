class_name CombatBoard
extends Node

# Emitted when a player unit is placed; combat handles mana deduction + animation.
signal unit_placed(inst: CardInstance, card_ui: CardUI, from_hand: bool, cost: int, on_play_results: Array)
# Emitted for any slot press; combat and spell_caster both listen.
signal slot_pressed(slot: SlotUI)
# Emitted when a spell is drag-dropped onto a slot; spell_caster handles.
signal spell_dropped(slot: SlotUI, card_ui: CardUI)
# Emitted when a fielded unit with an armed autocast ability is dropped onto a valid occupied
# slot (the drop already passed `can_autocast` via SlotUI.autocast_check); combat routes it
# to SpellCaster.activate_autocast. The dragged unit never moves.
signal autocast_dropped(slot: SlotUI, card_ui: CardUI)

var player_grid: Array = []   # [row][col] -> CardInstance or null
var enemy_grid:  Array = []   # [row][col] -> CardInstance or null
var player_slots: Array = []  # [row][col] -> SlotUI
var enemy_slots:  Array = []  # [row][col] -> SlotUI

# Set by the orchestrator during setup.
var placement_enabled: bool  = false
var is_hand_card: Callable        # func(CardUI) -> bool
var get_mana: Callable            # func() -> int
# Whether dropping this dragged unit onto this slot fires its armed autocast ability —
# SpellCaster.autocast_drop_ok (armed + payable + eligible occupant), injected like get_mana.
var can_autocast: Callable        # func(CardInstance, SlotUI) -> bool
# The two CombatSides (player resources), injected by combat so every effect context built
# during a fight can resolve side targets ("draw 2" — see TargetResolver.Side).
var player_side: CombatSide = null
var enemy_side: CombatSide = null
var _default_strategy := TargetingNearest.new()

# Attack-target preview. Two DISTINCT signals about a selected/dragged friendly unit at a spot:
#   • crosshair (`_preview_slot`) — the enemy OUR unit would strike (its outgoing target).
#   • glow (`_glow_cards`, `attack_target_glow`) — the enemies that would strike OUR unit AT THAT
#     spot (incoming threats); each enemy whose own targeting picks our unit if it stood there.
# Drag phantom: the unit being dragged for a move/place and the slot showing its landing preview.
var _preview_slot: SlotUI = null
var _glow_cards: Array = []   # CardUI[] currently wearing the incoming-threat glow
var _drag_card: CardUI = null
var _phantom_slot: SlotUI = null


# The one context builder for live-combat effect dispatch: grids + the sides. Every
# in-combat EffectContext comes through here so a side target is never silently missing.
func make_context(src: CardInstance) -> EffectContext:
	var ctx := EffectContext.make(src, player_grid, enemy_grid)
	ctx.player_side = player_side
	ctx.enemy_side = enemy_side
	# Board access rides every in-combat context (spawn payloads queue through it; CUSTOM
	# hooks board-procedure through it). SpellCaster's own injection becomes redundant but
	# harmless — this is the one context builder, so nothing in combat can miss it.
	ctx.board_node = self
	return ctx

# Zone dressing: each half sits on its own faintly tinted field so "my side / their side" reads
# at a glance — cool blue for the player, warm red for the enemy. Low alpha keeps the shared
# backdrop showing through.
const HALF_PAD := 8.0   # inner inset between a zone's edge and its slot grid (combat's
						 # _resize_board budgets for it — keep the two in sync)
const PLAYER_ZONE_BG := Color(0.36, 0.48, 0.78, 0.28)
const ENEMY_ZONE_BG  := Color(0.72, 0.36, 0.42, 0.24)


# ── Initialisation ─────────────────────────────────────────────────────────────

func setup_grids() -> void:
	for r in BoardData.ROWS:
		player_grid.append([])
		enemy_grid.append([])
		player_slots.append([])
		enemy_slots.append([])
		for _c in BoardData.COLS:
			player_grid[r].append(null)
			enemy_grid[r].append(null)
			player_slots[r].append(null)
			enemy_slots[r].append(null)


func build_section(parent: BoxContainer, is_player: bool) -> void:
	# A board half: a tinted zone panel (see the ZONE_BG consts) holding the slot grid, centred
	# in whatever area it's given so leftover space (after combat sizes the slots to fill) sits
	# as balanced margins rather than a lopsided gap. No "Player"/"Enemy" label — the tints and
	# the near/far halves read for themselves and a label only stole vertical room.
	var zone := Panel.new()
	zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zone.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	var zone_style := StyleBoxFlat.new()
	zone_style.bg_color = PLAYER_ZONE_BG if is_player else ENEMY_ZONE_BG
	zone_style.set_corner_radius_all(12)
	zone.add_theme_stylebox_override("panel", zone_style)
	parent.add_child(zone)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", int(HALF_PAD))
	pad.add_theme_constant_override("margin_right", int(HALF_PAD))
	pad.add_theme_constant_override("margin_top", int(HALF_PAD))
	pad.add_theme_constant_override("margin_bottom", int(HALF_PAD))
	zone.add_child(pad)

	var center := CenterContainer.new()
	pad.add_child(center)

	var grid := GridContainer.new()
	grid.columns = BoardData.COLS
	grid.add_theme_constant_override("h_separation", BoardData.SLOT_GAP)
	grid.add_theme_constant_override("v_separation", BoardData.SLOT_GAP)
	center.add_child(grid)

	var row_order: Array = range(BoardData.ROWS) if is_player \
		else range(BoardData.ROWS - 1, -1, -1)

	for r in row_order:
		for c in BoardData.COLS:
			var slot := SlotUI.new()
			slot.row      = r
			slot.col      = c
			slot.owner_id = 0 if is_player else 1

			if is_player:
				player_slots[r][c]   = slot
				slot.accept_check    = _can_drop_on_player_slot
				slot.autocast_check  = _can_autocast_on_slot
				var s := slot
				s.card_dropped.connect(func(cu: CardUI): _on_player_slot_dropped(s, cu))
				s.pressed.connect(func(): slot_pressed.emit(s))
			else:
				enemy_slots[r][c] = slot
				var s := slot
				s.card_dropped.connect(func(cu: CardUI): _on_enemy_slot_dropped(s, cu))
				s.pressed.connect(func(): slot_pressed.emit(s))

			grid.add_child(slot)


func place_kings(player_king_id: String = "king", enemy_king_id: String = "king",
		enemy_power: float = 0.0) -> void:
	var back: int = BoardData.ROWS - 1

	var pk := CardInstance.from_data(CardData.get_card(player_king_id))
	pk.row = back; pk.col = 0; pk.owner = 0
	player_grid[back][0] = pk
	var pk_ui := CardUI.create(pk)
	player_slots[back][0].set_card(pk_ui)
	_wire_unit_drag(pk_ui)

	# The enemy Captain scales with encounter power, like the rest of the deck.
	var ek := CardInstance.from_data(CardData.scaled(CardData.get_card(enemy_king_id), enemy_power))
	ek.row = back; ek.col = BoardData.COLS - 1; ek.owner = 1
	enemy_grid[back][BoardData.COLS - 1] = ek
	enemy_slots[back][BoardData.COLS - 1].set_card(CardUI.create(ek))
	LiveEffects.invalidate_compositions()   # owners set — allegiance-gated grants may now reach


# ── Card operations ────────────────────────────────────────────────────────────

func can_place_from_hand(card_ui: CardUI) -> bool:
	if card_ui.card_instance.is_spell:
		return false
	return card_ui.card_instance.get_attribute("cost") <= get_mana.call()


func place_enemy_card(inst: CardInstance, r: int, c: int) -> Array:
	inst.row = r; inst.col = c; inst.owner = 1
	LiveEffects.invalidate_compositions()   # owner set — allegiance-gated grants may now reach
	enemy_grid[r][c] = inst
	var ui := CardUI.create(inst)
	enemy_slots[r][c].set_card(ui)
	var results := EffectSystem.trigger(
		GameEvent.make(&"play", inst), inst, make_context(inst))
	cleanup_effect_deaths()
	refresh()
	return results


# Spawns a unit into an empty PLAYER slot outside the hand-placement flow (material
# delivery's empty-slot case — see EffectHooks.deliver_material). Mirrors place_enemy_card:
# occupies the grid, creates the CardUI, fires the unit's ON_PLAY effects.
func spawn_player_card(inst: CardInstance, r: int, c: int) -> Array:
	if player_grid[r][c] != null:
		return []
	inst.row = r; inst.col = c; inst.owner = 0
	LiveEffects.invalidate_compositions()   # owner set — allegiance-gated grants may now reach
	player_grid[r][c] = inst
	var ui := CardUI.create(inst)
	(player_slots[r][c] as SlotUI).set_card(ui)
	_wire_unit_drag(ui)
	var results := EffectSystem.trigger(
		GameEvent.make(&"play", inst), inst, make_context(inst))
	cleanup_effect_deaths()
	refresh()
	return results


# Relocates an already-placed enemy unit to an empty slot (the CPU's reposition
# action). Carries the existing CardUI across so no ON_PLAY re-triggers.
func move_enemy_card(inst: CardInstance, r: int, c: int) -> void:
	var ui: CardUI = (enemy_slots[inst.row][inst.col] as SlotUI).clear_card()
	enemy_grid[inst.row][inst.col] = null
	inst.row = r; inst.col = c
	enemy_grid[r][c] = inst
	(enemy_slots[r][c] as SlotUI).set_card(ui)


func remove_card(inst: CardInstance) -> void:
	var slots := player_slots if inst.owner == 0 else enemy_slots
	var board := player_grid  if inst.owner == 0 else enemy_grid
	var card_ui: CardUI = (slots[inst.row][inst.col] as SlotUI).clear_card()
	board[inst.row][inst.col] = null
	if card_ui:
		card_ui.queue_free()


func get_card_ui(inst: CardInstance) -> CardUI:
	if inst.owner == 0:
		return (player_slots[inst.row][inst.col] as SlotUI).get_card()
	return (enemy_slots[inst.row][inst.col] as SlotUI).get_card()


func get_all_units() -> Array:
	var all: Array = []
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if player_grid[r][c] != null:
				all.append(player_grid[r][c])
			if enemy_grid[r][c] != null:
				all.append(enemy_grid[r][c])
	return all


func find_target(attacker: CardInstance) -> CardInstance:
	var target_board: Array = enemy_grid if attacker.owner == 0 else player_grid
	var strategy: TargetingStrategy = attacker.data.targeting_strategy \
		if attacker.data != null else _default_strategy
	return strategy.find_target(attacker, target_board)


func any_king_dead() -> bool:
	var p_alive := false
	var e_alive := false
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if player_grid[r][c] != null and player_grid[r][c].data.is_king:
				p_alive = true
			if enemy_grid[r][c] != null and enemy_grid[r][c].data.is_king:
				e_alive = true
	return not p_alive or not e_alive


func get_player_king() -> CardInstance:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardInstance = player_grid[r][c]
			if p != null and p.data.is_king:
				return p
	return null


func player_king_alive() -> bool:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if player_grid[r][c] != null and player_grid[r][c].data.is_king:
				return true
	return false


func cleanup_effect_deaths() -> void:
	_sweep_dead()
	# Flush queued effect spawns now that corpses have left their slots (an on-death split
	# reclaims where its parent stood). A spawn fires ON_PLAY effects, which may kill units
	# and queue further spawns — the loop drains it all; the guard keeps reentrant cleanup
	# calls (from a spawn's own play trigger) from recursing into a second flush.
	if _flushing_spawns:
		return
	_flushing_spawns = true
	while not _pending_spawns.is_empty():
		var s: Dictionary = _pending_spawns.pop_front()
		for _i in int(s["count"]):
			if not _spawn_from_queue(s):
				break   # that side's board is full — the surplus fizzles
		_sweep_dead()
	_flushing_spawns = false


func _sweep_dead() -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardInstance = player_grid[r][c]
			if p != null and not p.is_alive():
				remove_card(p)
			var e: CardInstance = enemy_grid[r][c]
			if e != null and not e.is_alive():
				remove_card(e)


# ── Effect-driven spawning (the `spawn` payload — see EffectSystem._apply) ─────

# Units conjured by effects, pending placement. Queued rather than placed immediately so an
# on-death spawn resolves AFTER the corpse leaves the board; cleanup_effect_deaths flushes.
var _pending_spawns: Array = []   # [{ "id": String, "count": int, "owner": int, "row": int, "col": int }]
var _flushing_spawns := false


func queue_spawn(card_id: String, count: int, anchor: CardInstance) -> void:
	_pending_spawns.append({"id": card_id, "count": maxi(1, count),
			"owner": anchor.owner, "row": anchor.row, "col": anchor.col})


# Places one queued spawn into its anchor slot if free, else the nearest empty slot on that
# side. Fires the arrival's ON_PLAY effects like any other placement. False = side full.
func _spawn_from_queue(s: Dictionary) -> bool:
	var data := CardData.get_card(str(s["id"]))
	if data == null:
		push_error("CombatBoard: spawn payload names unknown card '%s'" % s["id"])
		return true   # a bad id is handled (loudly), not a full board
	var owner := int(s["owner"])
	var slot := _nearest_empty(owner, int(s["row"]), int(s["col"]))
	if slot.is_empty():
		return false
	var inst := CardInstance.from_data(data)
	inst.owner = owner
	Resolver.fill_health(inst)   # after owner is set, so run-wide unit bonuses fold in
	inst.row = slot[0]; inst.col = slot[1]
	var grid: Array = player_grid if owner == 0 else enemy_grid
	var slots: Array = player_slots if owner == 0 else enemy_slots
	grid[slot[0]][slot[1]] = inst
	LiveEffects.invalidate_compositions()   # owner set — allegiance-gated grants may now reach
	var ui := CardUI.create(inst)
	(slots[slot[0]][slot[1]] as SlotUI).set_card(ui)
	if owner == 0:
		_wire_unit_drag(ui)
	Vfx.play("summon_materialize", ui)
	EffectSystem.trigger(GameEvent.make(&"play", inst), inst, make_context(inst))
	refresh()
	return true


# The nearest empty slot to (row, col) on `owner`'s side by Manhattan distance (the anchor
# itself when free). [] = that side is full.
func _nearest_empty(owner: int, row: int, col: int) -> Array:
	var grid: Array = player_grid if owner == 0 else enemy_grid
	var best: Array = []
	var best_d := 999
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if grid[r][c] != null:
				continue
			var d := absi(r - row) + absi(c - col)
			if d < best_d:
				best_d = d
				best = [r, c]
	return best


func refresh() -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardUI = (player_slots[r][c] as SlotUI).get_card()
			if p:
				p.refresh()
			var e: CardUI = (enemy_slots[r][c] as SlotUI).get_card()
			if e:
				e.refresh()


# `eligible` (optional, func(CardInstance) -> bool) narrows targeting to slots whose occupant
# passes — used by spell targeting so only valid picks light up and accept drops (e.g. Castling
# can't target a unit that already has a Barrier). Without it, every slot toggles as before.
func set_slots_targetable(enabled: bool, eligible: Callable = Callable()) -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			_set_slot_targetable(player_slots[r][c] as SlotUI, player_grid[r][c] as CardInstance, enabled, eligible)
			_set_slot_targetable(enemy_slots[r][c] as SlotUI, enemy_grid[r][c] as CardInstance, enabled, eligible)


func _set_slot_targetable(slot: SlotUI, occupant: CardInstance, enabled: bool, eligible: Callable) -> void:
	if not enabled:
		slot.set_targetable(false)
		slot.reset_cue()
		return
	var ok := true
	if eligible.is_valid():
		ok = occupant != null and bool(eligible.call(occupant))
	slot.set_targetable(ok)
	# A targeted spell/effect: valid picks show the green reticle, everything else a red X.
	slot.set_cue(SlotUI.Cue.TARGET_OK if ok else SlotUI.Cue.TARGET_BAD)


# Slot-level variant for MANUAL_SLOT effects (material delivery): `eligible` judges the SLOT
# itself — side, emptiness, occupant — so EMPTY slots can be valid picks (the spawn case),
# which the occupant-based filter above can never express.
func set_slots_targetable_by_slot(enabled: bool, eligible: Callable) -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			_set_slot_targetable_by(player_slots[r][c] as SlotUI, enabled, eligible)
			_set_slot_targetable_by(enemy_slots[r][c] as SlotUI, enabled, eligible)


func _set_slot_targetable_by(slot: SlotUI, enabled: bool, eligible: Callable) -> void:
	if not enabled:
		slot.set_targetable(false)
		slot.reset_cue()
		return
	var ok := bool(eligible.call(slot))
	slot.set_targetable(ok)
	slot.set_cue(SlotUI.Cue.TARGET_OK if ok else SlotUI.Cue.TARGET_BAD)


# Resets every slot to its resting look (idle "open" marker on empty own slots, else nothing) —
# the one-shot clear used when a move/selection gesture ends.
func refresh_idle_cues() -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			(player_slots[r][c] as SlotUI).reset_cue()
			(enemy_slots[r][c] as SlotUI).reset_cue()


# Toggles the idle "open here" marker on empty player slots — combat turns it on only while
# unit placement input is live (see Combat._set_placement_input).
func set_open_hints(enabled: bool) -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			(player_slots[r][c] as SlotUI).set_open_hints(enabled)
			(enemy_slots[r][c] as SlotUI).set_open_hints(enabled)


# A fielded PLAYER unit that can be repositioned (not a rooted building). Selecting one lights
# the board's move cues — see Combat._on_board_slot_pressed.
func is_movable_unit(inst: CardInstance) -> bool:
	return inst != null and inst.owner == 0 and inst.row >= 0 and not inst.data.is_building()


# Reposition/place mode: empty valid destinations on the player's side show the ring + arrow
# (bobbing while `animated`, parked for a static selection); every other slot stays at rest. No
# red X here — a move isn't a targeted effect, so irrelevant slots read neutral.
func show_move_cues(card_ui: CardUI, animated: bool) -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var ps := player_slots[r][c] as SlotUI
			if ps.get_card() == null and _can_drop_on_player_slot(card_ui, ps):
				ps.set_cue(SlotUI.Cue.MOVE, animated)
			else:
				ps.reset_cue()
			(enemy_slots[r][c] as SlotUI).reset_cue()


# Dragging a unit that has an armed autocast ability: the drop can either MOVE it (empty own slot)
# or CAST on a valid unit, so both readings show at once, with MOVE taking priority — empty valid
# destinations get the ring+arrow, valid cast targets the green reticle, every other slot the red X.
func show_move_and_cast_cues(card_ui: CardUI, animated: bool) -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			_cue_hybrid_slot(player_slots[r][c] as SlotUI, card_ui, animated, true)
			_cue_hybrid_slot(enemy_slots[r][c] as SlotUI, card_ui, animated, false)


func _cue_hybrid_slot(slot: SlotUI, card_ui: CardUI, animated: bool, is_player: bool) -> void:
	if slot.get_card() == null:
		# Empty: a move destination (own side, droppable) wins; anything else is an invalid target.
		if is_player and _can_drop_on_player_slot(card_ui, slot):
			slot.set_cue(SlotUI.Cue.MOVE, animated)
		else:
			slot.set_cue(SlotUI.Cue.TARGET_BAD)
	elif _can_autocast_on_slot(card_ui, slot):
		slot.set_cue(SlotUI.Cue.TARGET_OK)
	else:
		slot.set_cue(SlotUI.Cue.TARGET_BAD)


# Connects a hand unit card's drag so it lights move/place cues like a fielded unit does. Injected
# into Hand as `wire_unit_card`; _wire_unit_drag's guard makes re-entry harmless.
func wire_unit_card(card_ui: CardUI) -> void:
	_wire_unit_drag(card_ui)


# ── Attack-target preview ───────────────────────────────────────────────────────
# Shows the combat consequences of standing a friendly unit at a spot, as two separate signals:
#   • a red crosshair on the enemy OUR unit would strike (outgoing target), and
#   • a red glow on every enemy that would strike OUR unit there (incoming threats).
# So the player reads "who I hit" and "who hits me" independently before committing.

# Previews for `attacker` FROM ITS CURRENT POSITION (a selected fielded unit). For a hypothetical
# landing spot, see _preview_target_at.
func show_attack_preview(attacker: CardInstance) -> void:
	_preview_target_at(attacker, attacker.row, attacker.col)


func clear_attack_preview() -> void:
	if _preview_slot != null:
		_preview_slot.set_attack_marker(false)
		_preview_slot = null
	for card: CardUI in _glow_cards:
		if card != null and is_instance_valid(card):
			Vfx.detach("attack_target_glow", card)
			card.set_threat_highlight(false)
	_glow_cards = []


func _preview_target_at(attacker: CardInstance, row: int, col: int) -> void:
	clear_attack_preview()
	if attacker == null:
		return
	# Outgoing: crosshair on the enemy our unit would hit from (row, col).
	_mark_crosshair(_projected_target(attacker, row, col))
	# Incoming: glow on every enemy that would hit our unit if it stood at (row, col).
	for e: CardInstance in _incoming_attackers(attacker, row, col):
		var card := (enemy_slots[e.row][e.col] as SlotUI).get_card()
		if card != null:
			Vfx.attach("attack_target_glow", card)
			card.set_threat_highlight(true)
			_glow_cards.append(card)


# The unit `attacker` would strike if it stood at (row, col) — its own targeting strategy run over
# the enemy grid. Restores the real position afterward (find_target only READS row/col, so the
# temporary move is invisible to everything else on this synchronous call).
func _projected_target(attacker: CardInstance, row: int, col: int) -> CardInstance:
	if attacker == null:
		return null
	var save_r := attacker.row
	var save_c := attacker.col
	attacker.row = row
	attacker.col = col
	var strategy: TargetingStrategy = attacker.data.targeting_strategy \
		if attacker.data != null else _default_strategy
	var t: CardInstance = strategy.find_target(attacker, enemy_grid)   # friendly unit → enemy grid
	attacker.row = save_r
	attacker.col = save_c
	return t


# The enemies that would auto-attack `defender` if it stood at (row, col): each enemy whose own
# targeting strategy, run over the player grid, resolves to `defender`. We install `defender` into
# a hypothetical player grid at (row, col) — clearing its old cell so a MOVE preview reflects the
# vacated spot, and a hand placement adds it where it isn't yet — then restore the grid exactly.
func _incoming_attackers(defender: CardInstance, row: int, col: int) -> Array:
	var result: Array = []
	if defender == null:
		return result
	var save_r := defender.row
	var save_c := defender.col
	var was_on_board: bool = player_grid[save_r][save_c] == defender
	if was_on_board:
		player_grid[save_r][save_c] = null
	var displaced: CardInstance = player_grid[row][col]
	player_grid[row][col] = defender
	defender.row = row
	defender.col = col
	for r in range(enemy_grid.size()):
		for c in range(enemy_grid[r].size()):
			var e: CardInstance = enemy_grid[r][c]
			if e == null:
				continue
			var strategy: TargetingStrategy = e.data.targeting_strategy \
				if e.data != null else _default_strategy
			if strategy.find_target(e, player_grid) == defender:
				result.append(e)
	# Restore (order matters when (row, col) == the old cell).
	player_grid[row][col] = displaced
	defender.row = save_r
	defender.col = save_c
	if was_on_board:
		player_grid[save_r][save_c] = defender
	return result


func _mark_crosshair(target: CardInstance) -> void:
	if target == null or target.owner != 1:
		return
	var slot := enemy_slots[target.row][target.col] as SlotUI
	slot.set_attack_marker(true)
	_preview_slot = slot


# ── Drag phantom ────────────────────────────────────────────────────────────────
# While a unit is dragged for a move/place, the slot under the cursor shows a translucent preview
# of where it would land, and that landing spot drives the attack preview above.

func _begin_drag_phantom(card_ui: CardUI) -> void:
	_drag_card = card_ui
	set_process(true)


func _end_drag_phantom() -> void:
	set_process(false)
	_set_phantom_slot(null)
	_drag_card = null


func _process(_delta: float) -> void:
	if _drag_card == null or not is_instance_valid(_drag_card):
		return
	var slot := _hovered_move_slot()
	if slot != _phantom_slot:
		_set_phantom_slot(slot)


func _set_phantom_slot(slot: SlotUI) -> void:
	if slot == _phantom_slot:
		return
	if _phantom_slot != null:
		_phantom_slot.unmount_phantom()
		# Restore the arrow the phantom replaced — but only if the slot is still an empty spot
		# (on drop it now holds the placed unit, and the drag-end reset will clear it anyway).
		if _phantom_slot.get_card() == null:
			_phantom_slot.set_cue(SlotUI.Cue.MOVE, true)
	_phantom_slot = slot
	if slot != null and _drag_card != null:
		slot.set_cue(SlotUI.Cue.NONE)                  # the phantom IS the "lands here" signal
		slot.mount_phantom(_drag_card.make_ghost_view())
		_preview_target_at(_drag_card.card_instance, slot.row, slot.col)
	elif _drag_card != null and not (is_hand_card.is_valid() and is_hand_card.call(_drag_card)):
		# Off any landing slot — fall back to previewing from where the unit actually stands, so a
		# fielded unit's map info persists through the whole drag, not just while over a new slot.
		show_attack_preview(_drag_card.card_instance)


# The empty player slot under the cursor that would accept the dragged unit ([] → none).
func _hovered_move_slot() -> SlotUI:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var ps := player_slots[r][c] as SlotUI
			if ps.get_card() != null:
				continue
			if not _can_drop_on_player_slot(_drag_card, ps):
				continue
			if ps.get_global_rect().has_point(ps.get_global_mouse_position()):
				return ps
	return null


func set_board_card_filters(enabled: bool) -> void:
	var filter := Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardUI = (player_slots[r][c] as SlotUI).get_card()
			if p:
				p.mouse_filter = filter
			var e: CardUI = (enemy_slots[r][c] as SlotUI).get_card()
			if e:
				e.mouse_filter = filter


# ── Internal drop handlers ─────────────────────────────────────────────────────

func _can_drop_on_player_slot(card_ui: CardUI, _slot: SlotUI) -> bool:
	var inst := card_ui.card_instance
	if inst.is_spell:
		return false
	if is_hand_card.call(card_ui):
		return inst.get_attribute("cost") <= get_mana.call()
	# Board-to-board MOVE legality (the accept-side twin of CardUI._get_drag_data's gates):
	# only the player's own fielded, non-building units relocate — a fielded building's drag
	# exists solely to cast its armed ability, and no move spot ever accepts it.
	if inst.owner != 0:
		return false
	if inst.row >= 0 and inst.data.is_building():
		return false
	return true


# The occupied-slot gate consulted by SlotUI._can_drop_data — occupied slots reject unit
# drops except the autocast gesture (see `can_autocast`).
func _can_autocast_on_slot(card_ui: CardUI, slot: SlotUI) -> bool:
	return placement_enabled and can_autocast.is_valid() \
			and bool(can_autocast.call(card_ui.card_instance, slot))


func _on_player_slot_dropped(slot: SlotUI, card_ui: CardUI) -> void:
	if card_ui.card_instance.is_spell:
		spell_dropped.emit(slot, card_ui)
		return
	if not placement_enabled:
		return
	if slot.get_card() != null:
		# A drop onto an occupied slot only got here through the autocast gate
		# (SlotUI._can_drop_data → _can_autocast_on_slot): fire the ability, don't place.
		autocast_dropped.emit(slot, card_ui)
		return
	do_place_unit(slot, card_ui)


func _on_enemy_slot_dropped(slot: SlotUI, card_ui: CardUI) -> void:
	if card_ui.card_instance.is_spell:
		spell_dropped.emit(slot, card_ui)


# Every PLAYER board unit joins the autocast drag affordance, whatever path fielded it (hand
# placement, move, material spawn, the king). Re-entry (a relocating unit) is guarded.
func _wire_unit_drag(card_ui: CardUI) -> void:
	if not card_ui.unit_drag_started.is_connected(_on_unit_drag_started):
		card_ui.unit_drag_started.connect(_on_unit_drag_started)
		card_ui.unit_drag_ended.connect(_on_unit_drag_ended)


# A fielded unit's drag doubles as the autocast gesture. Card mouse filters must drop for the
# drag's duration regardless of armed state (an occupied slot's occupant CardUI would swallow
# the drop otherwise — same reason SpellCaster does this for spell drags); the target
# highlight only lights when something is actually armed.
func _on_unit_drag_started(card_ui: CardUI) -> void:
	set_board_card_filters(false)
	# An armed unit's drag can both move AND cast, so it shows the hybrid pass (move here / valid
	# target / invalid target); a plain unit's drag is a pure reposition. Either way the empty
	# valid spots carry a landing phantom + its attack preview.
	if card_ui.card_instance.armed_autocast() != null:
		show_move_and_cast_cues(card_ui, true)
	else:
		show_move_cues(card_ui, true)
	# Treat the drag as a SELECTION from frame one: light the unit's attack preview from where it
	# currently stands, so its map info (crosshair + incoming-threat glow) shows immediately on a
	# click-hold or a gentle drag — not only once the cursor reaches a different slot. Once the
	# cursor DOES hover a landing slot the phantom re-previews from there; off any slot it falls
	# back to this origin preview (see _set_phantom_slot).
	if is_hand_card.is_valid() and is_hand_card.call(card_ui):
		clear_attack_preview()   # a hand card isn't on the board yet — no origin to preview from
	else:
		show_attack_preview(card_ui.card_instance)
	_begin_drag_phantom(card_ui)


func _on_unit_drag_ended(_card_ui: CardUI) -> void:
	set_board_card_filters(true)
	_end_drag_phantom()
	clear_attack_preview()
	set_slots_targetable(false)   # clears both the targetable gate and every drag cue


func do_place_unit(slot: SlotUI, card_ui: CardUI) -> void:
	var inst      := card_ui.card_instance
	var from_hand: bool = is_hand_card.call(card_ui)
	var cost      := inst.get_attribute("cost")

	if from_hand and cost > get_mana.call():
		return

	# Buildings are rooted once placed — never relocate an already-placed one.
	# (CardUI._get_drag_data normally prevents the drag from even starting.)
	if not from_hand and inst.data.is_building():
		return

	if not from_hand and inst.row >= 0 and inst.col >= 0:
		player_grid[inst.row][inst.col] = null

	inst.row = slot.row; inst.col = slot.col; inst.owner = 0
	player_grid[slot.row][slot.col] = inst
	slot.set_card(card_ui)
	LiveEffects.invalidate_compositions()   # owner set — allegiance-gated grants may now reach

	_wire_unit_drag(card_ui)

	var results: Array = []
	if from_hand:
		card_ui._show_cost = false
		results = EffectSystem.trigger(
			GameEvent.make(&"play", inst), inst, make_context(inst))
		cleanup_effect_deaths()

	refresh()
	unit_placed.emit(inst, card_ui, from_hand, cost if from_hand else 0, results)
