class_name CombatBoard
extends Node

# Emitted when a player unit is placed; combat handles mana deduction + animation.
signal unit_placed(inst: CardInstance, card_ui: CardUI, from_hand: bool, cost: int, on_play_results: Array)
# Emitted for any slot press; combat listens (and routes to the Interaction session first).
signal slot_pressed(slot: SlotUI)
# The two halves as grids, FORWARDED from the world — the board stores no occupancy of its
# own. It used to hold the arrays and lend them to the world, which made two owners of one
# fact kept in step by hand; placement has exactly one home now (see LocationManager) and
# these are a reading of it. Empty before the world is injected.
var player_grid: Array:
	get: return [] if world == null else world.grid_of(0)
var enemy_grid: Array:
	get: return [] if world == null else world.grid_of(1)
# The cohesive rules-state context (CombatWorld) — placement, retirement, the spawn queue,
# contexts and the play moment all live on IT; the board keeps the view halves, reacting to
# the world's unit_swept/unit_spawned cues for deaths and arrivals the rules decide on.
var world: CombatWorld = null:
	set(v):
		world = v
		if world != null:
			world.unit_swept.connect(_on_world_unit_swept)
			world.unit_spawned.connect(_on_world_unit_spawned)


# A swept effect-kill: the state is already gone; drop the card where it stands.
#
# EXCEPT a KING. A king dying is the fight ending, and that ending is a SCENE — the fall, the
# blast, the treasure chest thrown clear of it — and a scene needs the body. The anonymous sweep
# therefore leaves a fallen king's card standing exactly where it stood, and whoever presents the
# ending claims it (Combat._settle_if_decided). Before this, a captain killed by a spell was
# thrown away by the sweep like any bystander, so the fight ended a whole turn later with nothing
# to show for it.
var _fallen_body: CardInstance = null

func _on_world_unit_swept(inst: CardInstance) -> void:
	if inst.data != null and inst.data.is_king:
		_fallen_body = inst
		return
	drop_card_view(inst, get_card_ui(inst))


# The body left standing, claimed exactly once — by the ending that owes it a send-off.
func claim_fallen_body() -> CardInstance:
	var body := _fallen_body
	_fallen_body = null
	return body


# A king that died and was REPLACED rather than ending the fight (a phase-change boss spawning
# its next form): nobody owes it a scene, so the body simply goes.
func discard_fallen_body() -> void:
	var body := claim_fallen_body()
	if body != null:
		drop_card_view(body, get_card_ui(body))


# A rules-driven arrival (queued spawn / hook spawn): build the card the state is owed.
func _on_world_unit_spawned(inst: CardInstance) -> void:
	var slot := slot_of(inst)
	if slot == null:
		return
	# The arrival may be landing on a body the sweep left standing — a phase-change boss reclaims
	# the very slot its previous form died on. The spot belongs to the newcomer: the body goes now
	# rather than being silently drawn over.
	var standing := slot.get_card()
	if standing != null and is_instance_valid(standing):
		if standing.card_instance == _fallen_body:
			_fallen_body = null
		drop_card_view(standing.card_instance, standing)
	var ui := CardUI.create(inst)
	slot.set_card(ui)
	if inst.owner == 0:
		_wire_unit_drag(ui)
	Vfx.play("summon_materialize", ui)
var player_slots: Array = []  # [row][col] -> SlotUI
var enemy_slots:  Array = []  # [row][col] -> SlotUI

# Set by the orchestrator during setup.
var placement_enabled: bool  = false
var is_hand_card: Callable        # func(CardUI) -> bool
var get_mana: Callable            # func() -> int
# The combat-wide interaction session owner (see Interaction / INTERACTION_DESIGN.md). The
# board renders WHATEVER the current action declares (present, connected to its `changed`) and
# begins/ends drag actions on it; injected by combat before build_section runs.
var interaction: Interaction = null
# The two CombatSides (player resources), injected by combat so every effect context built
# during a fight can resolve side targets ("draw 2").
var player_side: CombatSide = null
var enemy_side: CombatSide = null

# The DECLARED preview world (see CombatContext / INTERACTION_DESIGN.md): the pivot unit
# standing at a hypothetical spot. Everything threat-shaped DERIVES from this declaration —
# each card asks "does my targeting resolve to the pivot in that world?", slots ask "is my
# occupant the pivot's victim?" — recomputed wholesale on declaration change, never
# accumulated per-card (the old `_glow_cards`/`_preview_slot` residue lists are gone).
var _pivot: CardInstance = null
var _pivot_at: BoardLocation = null
# Derived once per declaration change: a HYPOTHETICAL PLACEMENT — the same units, arranged
# with the pivot standing at its declared spot (its real cell vacated, so a move preview
# reflects the freed lane) — plus the pivot's own target in that arrangement, memoized so
# every card's "am I the victim?" is a compare.
#
# This used to be a pair of duplicated grid arrays PLUS a mutate-the-pivot's-coordinates-and-
# put-them-back trick around every query, because targeting read a unit's position off the
# unit. Targeting reads a placement now, so a hypothetical is simply a second placement:
# nothing is moved, nothing is restored, and no query can observe a half-applied state.
var _preview_places: LocationManager = null
var _pivot_target: CardInstance = null
# Drag phantom: the unit being dragged for a move/place and the slot showing its landing preview.
var _drag_card: CardUI = null
var _phantom_slot: SlotUI = null
# Cursor-hover during a STATIC moving/placing selection (a click-selected hand card or fielded
# unit): the slot under the cursor wears a strong white outline, and a hovered MOVE cue bobs
# like a drag's. Tracked by polling in _process — occupant cards would swallow mouse_entered,
# so rect tests (the drag phantom's own technique) are the reliable read. Armed only while the
# live action actually OFFERS destinations (a pure preview — enemy/building selection — is not
# a moving/placing state).
var _hover_slot: SlotUI = null
var _hover_live: bool = false
# The slot showing the STATIC landing phantom — raised while the cursor is over that slot's
# MOVE BUTTON (and through its safety hold), the click-flow twin of the drag's _phantom_slot.
# Driven by the button's own hover (move_hover), never by slot-rect polling; present() clears
# it structurally like everything else it owns.
var _button_phantom_slot: SlotUI = null


# Zone dressing: each half sits on its own faintly tinted field so "my side / their side" reads
# at a glance — cool blue for the player, warm red for the enemy. Low alpha keeps the shared
# backdrop showing through.
const HALF_PAD := 8.0   # inner inset between a zone's edge and its slot grid (combat's
						 # _resize_board budgets for it — keep the two in sync)
const PLAYER_ZONE_BG := Color(0.36, 0.48, 0.78, 0.28)
const ENEMY_ZONE_BG  := Color(0.72, 0.36, 0.42, 0.24)


# ── Initialisation ─────────────────────────────────────────────────────────────

# The SLOT WIDGET matrices only — occupancy is the world's (see player_grid above).
func setup_grids() -> void:
	for r in BoardData.ROWS:
		player_slots.append([])
		enemy_slots.append([])
		for _c in BoardData.COLS:
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
			slot.location = BoardLocation.at(0 if is_player else 1, r, c)

			# Both sides share the exact same wiring: the slot's drop gate and drop commit ask
			# the Interaction session (the same predicate that lit its cue), and presses bubble
			# to combat, which routes them through the session first.
			slot.interaction = interaction
			# The ground lookup: the slot ASKS the world for its BoardSlot on every render —
			# resolved through `world` at call time (the world is injected after build).
			var gs := slot
			slot.ground_lookup = func() -> BoardSlot:
				return null if world == null else BoardFacade.peek_slot(world, gs.location)
			if is_player:
				player_slots[r][c] = slot
			else:
				enemy_slots[r][c] = slot
			var s := slot
			s.pressed.connect(func(): slot_pressed.emit(s))
			s.move_pressed.connect(func(): _on_move_button_pressed(s))
			s.move_hover.connect(func(on: bool): _on_move_button_hover(s, on))

			grid.add_child(slot)


func place_kings(player_king_id: String = "king", enemy_king_id: String = "king",
		enemy_power: float = 0.0) -> void:
	var back: int = BoardData.ROWS - 1

	var pk := CardInstance.from_data(CardData.get_card(player_king_id))
	world.place_unit(pk, back, 0, 0)
	var pk_ui := CardUI.create(pk)
	player_slots[back][0].set_card(pk_ui)
	_wire_unit_drag(pk_ui)

	# The enemy Captain scales with encounter power, like the rest of the deck.
	var ek := CardInstance.from_data(CardData.scaled(CardData.get_card(enemy_king_id), enemy_power))
	world.place_unit(ek, back, BoardData.COLS - 1, 1)
	enemy_slots[back][BoardData.COLS - 1].set_card(CardUI.create(ek))


# ── Card operations ────────────────────────────────────────────────────────────

func can_place_from_hand(card_ui: CardUI) -> bool:
	if card_ui.card_instance.is_spell:
		return false
	return card_ui.card_instance.get_attribute("cost") <= get_mana.call()


func place_enemy_card(inst: CardInstance, at: BoardLocation) -> Array:
	world.place_unit_at(inst, at, 1)
	var ui := CardUI.create(inst)
	slot_ui_for(at).set_card(ui)
	var results := world.play_dispatch(inst)
	cleanup_effect_deaths()
	refresh()
	return results


# Spawns a unit into an empty PLAYER slot outside the hand-placement flow (material
# delivery's empty-slot case — see EffectHooks.deliver_material). Mirrors place_enemy_card:
# occupies the grid, creates the CardUI, fires the unit's ON_PLAY effects.
func spawn_player_card(inst: CardInstance, at: BoardLocation) -> Array:
	if BoardFacade.unit_at(world, at) != null:
		return []
	world.place_unit_at(inst, at, 0)
	var ui := CardUI.create(inst)
	slot_ui_for(at).set_card(ui)
	_wire_unit_drag(ui)
	var results := world.play_dispatch(inst)
	cleanup_effect_deaths()
	refresh()
	return results


# Relocates an already-placed enemy unit to an empty slot (the CPU's reposition
# action). Carries the existing CardUI across so no ON_PLAY re-triggers.
#
# Returns WHERE THE CARD STOOD, in global coordinates, for whoever presents the move — the slide
# that makes the reposition readable has to be told where the unit came from, and this is the only
# moment anyone can still see it. The board hands the fact over rather than animating: state and
# view are separate here, exactly as they are for a death (see retire_unit), so the grid, the
# targeting and the next attacker are all correct the instant this returns whether or not anybody
# plays the cue.
func move_enemy_card(inst: CardInstance, at: BoardLocation) -> Vector2:
	# Read BEFORE the card is taken out of its slot: clear_card reparents it out of the tree, and an
	# orphaned Control's global position is just its local one — the origin, wherever it stood.
	var old_slot := slot_of(inst)
	var standing := old_slot.get_card()
	var from := standing.global_position if standing != null else old_slot.global_position
	var ui: CardUI = old_slot.clear_card()
	# ONE move, on the one authority — no vacate-then-occupy pair to get out of step.
	world.locations.move(inst, at)
	slot_ui_for(at).set_card(ui)
	return from


# A unit leaves PLAY — state only, and instantly. Targeting, the king checks and the next attacker
# stop seeing it the moment this returns. Its card is deliberately left standing exactly where it
# is, untouched, for whoever is presenting the death to dispose of once they're done (see
# drop_card_view); the returned CardUI is that card, still parented and laid out by its slot.
#
# State and view are separate on purpose. Bundling them — clearing the grid AND destroying the card
# in one call — is what used to force a death animation to block: the only way to keep the card on
# screen was to delay the state change. Nothing about the board waits on an animation now.
func retire_unit(inst: CardInstance) -> CardUI:
	var card := get_card_ui(inst)
	# State (grid clear) + the unit_retired bounty wire live on the world now; the card is
	# still standing when its signal fires, so listeners may read its rect.
	world.retire(inst)
	return card


# Disposes of a retired unit's card, once its send-off has played. The slot is found BY THE
# CARD, never by the unit: everything that reaches here has already left play, and "is this
# card still the one standing there" is the check that was always meant — if anything has
# moved in since, the newcomer is not ours to remove. The card is always freed.
func drop_card_view(inst: CardInstance, card_ui: CardUI) -> void:
	var card := card_ui
	if card == null or not is_instance_valid(card):
		card = get_card_ui(inst)   # a caller holding only the unit
	if card == null:
		return
	var slot := _slot_holding(card)
	if slot != null:
		slot.clear_card()
	card.queue_free()


# State and view together, with no send-off: the unit leaves play and its card vanishes on the spot.
func remove_card(inst: CardInstance) -> void:
	drop_card_view(inst, retire_unit(inst))


# The card VIEW standing for a unit — asked of the SLOT WIDGETS, which are the authority on
# what they are drawing, and deliberately NOT routed through placement.
#
# ⚠ A DEATH IS THE WINDOW WHERE THOSE TWO DIVERGE, and it is the whole reason this is not a
# placement lookup. Retiring a unit undocks it instantly — the rules must stop seeing it —
# while its card stays standing for exactly as long as its send-off takes (see retire_unit:
# state and view are separate on purpose). Ask placement here and every consumer of that
# window comes up empty: the fade never plays, the corpse is never disposed of, no damage
# number lands on the killing blow, and the body stands on the board at negative health.
#
# Where a unit STANDS and where its card is BEING DRAWN are two facts with two lifetimes.
# One authority each — the board for the first, the widgets for the second.
func get_card_ui(inst: CardInstance) -> CardUI:
	var slot := card_slot_of(inst)
	return null if slot == null else slot.get_card()


# The slot widget currently DRAWING this unit's card, or null. Survives the unit leaving play.
func card_slot_of(inst: CardInstance) -> SlotUI:
	if inst == null:
		return null
	return _find_slot(func(slot: SlotUI) -> bool:
		var card := slot.get_card()
		return card != null and is_instance_valid(card) and card.card_instance == inst)


func _slot_holding(card_ui: CardUI) -> SlotUI:
	return _find_slot(func(slot: SlotUI) -> bool: return slot.get_card() == card_ui)


func _find_slot(matches: Callable) -> SlotUI:
	for slots: Array in [player_slots, enemy_slots]:
		for slot_row: Array in slots:
			for slot: SlotUI in slot_row:
				if slot != null and bool(matches.call(slot)):
					return slot
	return null


# The SLOT a unit OCCUPIES — placement, straight from the one authority. Null when the unit is
# not on the board, which is the honest answer for a corpse. Input questions ask this ("which
# widget speaks for the unit standing here"); view questions ask card_slot_of above.
func slot_of(inst: CardInstance) -> SlotUI:
	return slot_ui_for(BoardFacade.location_of(world, inst))


# The slot WIDGET at a board address (null for no address) — the one coordinates-to-widget
# lookup, so nothing else indexes the matrices by hand.
func slot_ui_for(loc: BoardLocation) -> SlotUI:
	if loc == null:
		return null
	var slots: Array = player_slots if loc.side == 0 else enemy_slots
	var slot_row: Array = slots[loc.row]
	return slot_row[loc.col] as SlotUI


# The slot widget under a GROUND cell (a BoardSlot) — presentation's route from a rules-side
# ground object back to the widget drawing it.
func slot_ui_of(ground: BoardSlot) -> SlotUI:
	return slot_ui_for(BoardFacade.location_of(world, ground))


# "The player pressed this unit" — from somewhere that isn't the unit's own slot (the turn-order
# strip, whose entries stand for units the cursor never has to reach). Routed through the SAME
# `slot_pressed` every real press takes, so the Interaction session still gets first refusal and
# the inspect/select behaviour is whatever clicking the card itself does, by construction rather
# than by a second implementation kept in step with the first.
func press_unit(inst: CardInstance) -> void:
	var slot := slot_of(inst)
	if slot != null and slot.get_card() != null:
		slot_pressed.emit(slot)


func get_all_units() -> Array:
	return world.get_all_units()


# TARGETING REMOVED (targeting-cleanup demolition). NEEDS: the auto-attack target authority.
# Given an attacker and a PLACEMENT (LocationManager — so the same question works in the live
# world and in any hypothetical arrangement), answer which enemy unit its auto-attack hits.
#   · The candidate pool is the units on the OPPOSITE half of the board.
#   · The pick follows the unit's AUTHORED ATTACK EFFECT's target resolver (the attack
#     family of named effects — nearest_attack et al.; target_policy is deleted), each
#     flavor a different ordering over candidates.
#   · "Nearest" is a PREFERENCE ORDERING, not a distance: column depth dominates, mirrored
#     lane offset breaks ties within a column, deterministic address tie-break after that
#     (this is the most playtested rule in the game — its behaviour is a design constant).
#   · An attacker standing nowhere reaches nobody; an empty pool is a legal "no target".
func find_target(_attacker: CardInstance) -> CardInstance:
	return null


func any_king_dead() -> bool:
	return get_player_king() == null or get_enemy_king() == null


# The king standing on a HALF of the board. Spatial, as it always was — these read the grid,
# and a grid is a half — so a king fighting from the wrong side would still be found where it
# is rather than where its loyalty says it should be.
func _king_on(side: int) -> CardInstance:
	for unit: CardInstance in BoardFacade.units_on_side(world, side):
		if unit.data.is_king:
			return unit
	return null


func get_player_king() -> CardInstance:
	return _king_on(0)


func get_enemy_king() -> CardInstance:
	return _king_on(1)


func player_king_alive() -> bool:
	return get_player_king() != null


# The sweep + spawn-queue drain lives on the world now (state); the board hears about each
# swept corpse / arrival through unit_swept / unit_spawned and answers with the view halves.
# One refresh after the drain re-derives whatever the drained spawns' own triggers changed.
func cleanup_effect_deaths() -> void:
	world.cleanup_deaths()
	refresh()


func refresh() -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var ps := player_slots[r][c] as SlotUI
			var es := enemy_slots[r][c] as SlotUI
			var p: CardUI = ps.get_card()
			if p:
				p.refresh()
			var e: CardUI = es.get_card()
			if e:
				e.refresh()
			# Ground state re-derives with every board refresh — decay/expiry needs no push.
			ps.render_ground()
			es.render_ground()


func slot_ui_at(side: int, r: int, c: int) -> SlotUI:
	return slot_ui_for(BoardLocation.at(side, r, c))


# ── Interaction presentation ────────────────────────────────────────────────────
# The ONE board renderer: draws whatever the current action declares, slot by slot, and resets
# to idle on `null`. Connected to Interaction.changed — no gesture path drives cues directly
# any more, so ending an action structurally clears everything it raised.

func present(action: Interaction.Action) -> void:
	# Hover teardown FIRST — set_hovered(false) tweaks a MOVE cue's arrow, so it must not run
	# after the walk below has already drawn the new action's cues. The button phantom clears
	# here too (its button may be about to hide without ever seeing a mouse_exited).
	_set_hover_slot(null)
	_hover_live = false
	_set_button_phantom(null)
	# Occupant cards swallow drops; during any drag they must let the slot receive them (the
	# reason both the old spell and unit drags dropped the filters).
	set_board_card_filters(action == null or not action.is_drag)
	var destinations := 0
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			if _present_slot(player_slots[r][c] as SlotUI, action) == Interaction.Role.DESTINATION:
				destinations += 1
			if _present_slot(enemy_slots[r][c] as SlotUI, action) == Interaction.Role.DESTINATION:
				destinations += 1
	# Attack projection: the action DECLARES whose consequences preview (a fielded unit, from
	# its current spot); the drag phantom re-declares from hovered landing spots on top of
	# this baseline (_set_phantom_slot). Cards/slots derive from the declaration.
	if action != null and action.preview_instance != null:
		var p := action.preview_instance
		declare_preview(p, BoardFacade.location_of(world, p))
	else:
		clear_preview()
	if action != null and action.is_drag:
		_begin_drag_phantom(action.source)
	else:
		_end_drag_phantom()
	# Hover tracking: live only for the STATIC HAND-PLACEMENT flow (click_commit — pick a card,
	# tap a spot), whose destination slots are themselves the tap targets. A fielded unit's
	# static selection gets NO slot-level hover at all: its destinations react solely through
	# their move buttons (arrow, phantom, preview all ride move_hover), and the rest of each
	# slot is non-interactive dead space. Drags own the cursor via the drag phantom.
	_hover_live = action != null and not action.is_drag and action.click_commit \
			and destinations > 0
	if _hover_live:
		set_process(true)


# Role → this slot's visuals. The mapping lives HERE and nowhere else: DESTINATION wears the
# move ring (bobbing while dragging), TARGET_VALID the golden target treatment + drop border,
# TARGET_INVALID the red X, NONE the resting look (which is the idle OPEN marker when hints
# are on). What each slot IS comes solely from the action's role_of; the role is returned so
# present() can tally destinations (its hover-tracking arm condition).
func _present_slot(slot: SlotUI, action: Interaction.Action) -> int:
	if action == null:
		slot.set_targetable(false)
		slot.reset_cue()
		return Interaction.Role.NONE
	var role := int(action.role_of(slot))
	match role:
		Interaction.Role.DESTINATION:
			slot.set_targetable(false)
			slot.set_cue(SlotUI.Cue.MOVE, action.animated)
			# The move BUTTON: the explicit commit entry for a static selection whose plain
			# click is closed (a fielded unit — click_commit false). Hand placement commits
			# on any slot click already; drags own the cursor. See MoveButton.
			slot.set_move_button(not action.is_drag and not action.click_commit)
		Interaction.Role.TARGET_VALID:
			slot.set_targetable(true)
			slot.set_cue(SlotUI.Cue.TARGET_OK)
		Interaction.Role.TARGET_INVALID:
			slot.set_targetable(false)
			slot.set_cue(SlotUI.Cue.TARGET_BAD)
		_:
			slot.set_targetable(false)
			slot.reset_cue()
	return role


# ── Action factories (the board's rules: move legality + placement) ─────────────

# Place-from-hand and reposition, drag or static selection — one action. Roles: empty own
# droppable slots are DESTINATIONS; everything else stays NEUTRAL (a move isn't a targeted
# effect, so irrelevant slots show no red X — deliberate policy, see INTERACTION_DESIGN.md).
func make_unit_action(card_ui: CardUI, animated: bool, is_drag: bool) -> Interaction.Action:
	var act := Interaction.Action.new()
	act.kind = Interaction.Action.Kind.UNIT
	act.source = card_ui
	act.animated = animated
	act.is_drag = is_drag
	# A fielded unit previews its attack consequences from where it stands; a hand card has no
	# origin to preview from until it hovers a landing slot.
	var from_hand: bool = is_hand_card.is_valid() and bool(is_hand_card.call(card_ui))
	if not from_hand:
		act.preview_instance = card_ui.card_instance
	# Where the gesture may be FINISHED with a tap: playing a card out of hand, yes; moving a unit
	# that is already fielded, no — that one is drag-only (see Action.click_commit). The
	# destination cues still light on selection, because they are what teaches that the unit can
	# be repositioned at all; only the tap is refused.
	act.click_commit = from_hand
	act.role_check = func(slot: SlotUI) -> int:
		if slot.location.side != 0 or slot.get_card() != null:
			return Interaction.Role.NONE
		if _can_drop_on_player_slot(card_ui, slot):
			return Interaction.Role.DESTINATION
		return Interaction.Role.NONE
	act.on_commit = func(slot: SlotUI) -> void:
		if placement_enabled:
			do_place_unit(slot, card_ui)
	return act


# AUTOCAST ACTION REMOVED (effect-cleanse demolition): the armed-autocast drag (a pure
# move+cast composition, move first, the cast judging every other slot including empty
# ones) died with the ability costume. When quick-cast returns on the rebuilt
# ActivatedEffect, its action composes the same way — one role predicate, so cue /
# drop-accept / execution cannot disagree — with eligibility asked OF the activation's
# target resolver (TARGETING_DESIGN.md §3), never a second judge.


# Toggles the idle "open here" marker on empty player slots — combat turns it on only while
# unit placement input is live (see Combat._set_placement_input).
func set_open_hints(enabled: bool) -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			(player_slots[r][c] as SlotUI).set_open_hints(enabled)
			(enemy_slots[r][c] as SlotUI).set_open_hints(enabled)


# Connects a hand unit card's drag so it lights move/place cues like a fielded unit does. Injected
# into Hand as `wire_unit_card`; _wire_unit_drag's guard makes re-entry harmless.
func wire_unit_card(card_ui: CardUI) -> void:
	_wire_unit_drag(card_ui)


# ── The declared preview world ──────────────────────────────────────────────────
# SIDE-NEUTRAL: the pivot may belong to either army — a selected enemy reads identically
# (crosshair on the player unit it targets, menace on the player units targeting it).

# Declares "pivot standing HERE" as the world threat questions are answered in, rebuilds the
# derived placement, and cues a re-derive. Idempotent on an unchanged declaration.
func declare_preview(pivot: CardInstance, at_loc: BoardLocation) -> void:
	if pivot == _pivot and at_loc == _pivot_at:
		return
	_pivot = pivot
	_pivot_at = at_loc
	_rebuild_preview_world()
	derive_cards()


func clear_preview() -> void:
	declare_preview(null, null)


# The derived arrangement: the real placement with one change — the pivot stands at its
# declared spot. Built once per declaration, so cards consulting at ANY later moment (a poll
# tick, a cue) answer in the same world a synchronous computation would have used.
func _rebuild_preview_world() -> void:
	_pivot_target = null
	_preview_places = null
	if _pivot == null or _pivot_at == null or world == null:
		return
	# A copy of the placement over the SAME units — the identity map is every dockable mapped
	# to itself, so "is this card the pivot's target?" stays a compare against the very object
	# the caller holds. Only the arrangement is hypothetical.
	var identity: Dictionary = {}
	for unit: CardInstance in world.get_all_units():
		identity[unit] = unit
	for ground: BoardSlot in world.locations.docked(BoardFacade.GROUND):
		identity[ground] = ground
	identity[_pivot] = _pivot   # a hand card is not on the board yet, and still lands somewhere
	_preview_places = world.locations.copy(identity)
	# The declared spot is normally empty (destinations are). If something does stand there,
	# the hypothetical is that the pivot stands there INSTEAD — so evict it from the copy
	# rather than let the collision rule refuse a placement that is not really a move.
	var sitting: Object = _preview_places.at(_pivot_at, BoardFacade.PIECES)
	if sitting != null and sitting != _pivot:
		_preview_places.undock(sitting)
	_preview_places.move(_pivot, _pivot_at)
	# TARGETING REMOVED. NEEDS: the pivot's own victim in the declared arrangement, memoized —
	# every card's "am I the target?" is then a compare, not a redundant rerun of the pivot's
	# targeting. Ask the auto-attack authority against _preview_places (the hypothetical
	# placement), NOT the live world — that is what makes the landing preview honest.
	_pivot_target = null


# The declared pivot itself — the OTHER party in every exchange a threat cue describes, so a card
# can quantify that exchange (its crit/dodge odds against the pivot) rather than only flag it.
func pivot() -> CardInstance:
	return _pivot


# ── The declared SPOTLIGHT ──────────────────────────────────────────────────────
# "Which unit is being pointed AT from somewhere else on the screen" — the turn-order strip's
# hover today (see TurnOrderStrip). A declaration, not a push: the board holds the one answer
# and every card derives its own look from it (CardUI.derive_presentation wears the canonical
# pick treatment for it), so a lit unit cannot outlive the gesture that lit it and no teardown
# path has to remember to unlight anything.
var _spotlight: CardInstance = null


func declare_spotlight(inst: CardInstance) -> void:
	if inst == _spotlight:
		return
	_spotlight = inst
	derive_cards()


func is_spotlit(inst: CardInstance) -> bool:
	return inst != null and inst == _spotlight


# ── The declared TURN NUMBERS ───────────────────────────────────────────────────
# "Is the player reading the activation order right now, and if so what is it" — declared by the
# TurnOrderStrip while the cursor rests on it, so every unit can wear its own place in the order
# where it stands and the list stops being a thing you look BACK AND FORTH at.
#
# The board does NOT sort: it is handed the order the strip already got from CombatWorld.turn_order
# (the one sort — see TurnOrderStrip), and only flattens it to a lookup so a card asking for its
# own number costs a hash rather than a sort.
var _turn_numbers: Dictionary = {}


func declare_turn_numbers(order: Array) -> void:
	var next: Dictionary = {}
	for i in order.size():
		next[order[i]] = i + 1
	if next == _turn_numbers:
		return
	_turn_numbers = next
	derive_cards()


# This unit's place in the declared order, or 0 for "nothing is being declared" / not listed.
func turn_number(inst: CardInstance) -> int:
	return int(_turn_numbers.get(inst, 0))


# "Am I the pivot's victim?" — a compare against the memoized answer.
func is_pivot_target(inst: CardInstance) -> bool:
	return inst != null and inst == _pivot_target


# "Does MY OWN targeting resolve to the pivot in the declared world?" — one strategy run for
# the asking card, the same total work the old central loop did, distributed to its owners.
func menaces_pivot(inst: CardInstance) -> bool:
	if _pivot == null or inst == null or inst == _pivot:
		return false
	if inst.owner == _pivot.owner or _preview_places == null:
		return false
	if _preview_places.location_of(inst) == null:
		return false
	# TARGETING REMOVED. NEEDS: "does MY OWN auto-attack resolve to the pivot in the declared
	# world?" — one targeting run for the asking card, asked IN the declared arrangement
	# (_preview_places), which is what makes a hand card hovering a landing slot answer as
	# though it already stood there (the "menace never updates to the landing spot" defect,
	# structurally impossible when the hypothetical is a placement rather than a temporary
	# edit to the pivot).
	return false


# The "re-check now" cue: every slot re-derives its attack marker from the declaration and
# every occupant card re-derives its presentation (threat, inspect, exhaust — see
# CardUI.derive_presentation). A wholesale walk from declared state, carrying no verdicts.
func derive_cards() -> void:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			_derive_slot(player_slots[r][c] as SlotUI)
			_derive_slot(enemy_slots[r][c] as SlotUI)


func _derive_slot(slot: SlotUI) -> void:
	var occ := slot.get_card()
	slot.set_attack_marker(occ != null and is_pivot_target(occ.card_instance))
	if occ != null:
		occ.derive_presentation()


# ── Drag phantom ────────────────────────────────────────────────────────────────
# While a unit is dragged for a move/place, the slot under the cursor shows a translucent preview
# of where it would land, and that landing spot drives the attack preview above.

func _begin_drag_phantom(card_ui: CardUI) -> void:
	_drag_card = card_ui
	set_process(true)


func _end_drag_phantom() -> void:
	set_process(false)
	# Clear _drag_card BEFORE tearing down the phantom slot. _set_phantom_slot(null) has a fallback
	# that RE-DECLARES the preview from the drag unit's standing position whenever _drag_card is
	# still set (so a fielded unit's map info survives moving OFF a landing slot mid-drag) — but at
	# teardown that fallback would immediately undo the clear_preview() present() just ran, stranding
	# the menace/crosshair cues on the board after the drop. Nulling first makes the teardown inert.
	_drag_card = null
	_set_phantom_slot(null)


func _process(_delta: float) -> void:
	if _drag_card != null:
		if not is_instance_valid(_drag_card):
			return
		var slot := _hovered_move_slot()
		if slot != _phantom_slot:
			_set_phantom_slot(slot)
		return
	if _hover_live:
		_set_hover_slot(slot_at_mouse())


func _set_hover_slot(slot: SlotUI) -> void:
	if slot == _hover_slot:
		return
	if _hover_slot != null and is_instance_valid(_hover_slot):
		_hover_slot.set_hovered(false)
	_hover_slot = slot
	if slot != null:
		slot.set_hovered(true)
	_declare_hover_preview()


# The move button's hover: mount the landing phantom in its slot and declare the targeting
# preview from that spot — the same information the drag phantom carries, granted for exactly
# as long as the cursor sits on the button (the safety hold keeps the cursor there, so the
# whole read persists through the hold). The button draws above the phantom by its fixed z.
func _on_move_button_hover(slot: SlotUI, on: bool) -> void:
	if interaction == null or not interaction.active():
		return
	var act := interaction.current()
	if act == null or act.is_drag or act.source == null or not is_instance_valid(act.source):
		return
	if on and interaction.role_of(slot) == Interaction.Role.DESTINATION:
		_set_button_phantom(slot)
	elif not on and slot == _button_phantom_slot:
		_set_button_phantom(null)


func _set_button_phantom(slot: SlotUI) -> void:
	if slot == _button_phantom_slot:
		return
	if _button_phantom_slot != null and is_instance_valid(_button_phantom_slot):
		_button_phantom_slot.unmount_phantom()
	_button_phantom_slot = slot
	if slot != null:
		var act := interaction.current()
		slot.mount_phantom(act.source.make_ghost_view())
		declare_preview(act.source.card_instance, slot.location)
	elif interaction != null and interaction.active():
		# Hover ended mid-action — the declaration falls back to the action's baseline (the
		# unit's standing spot). On action teardown present() re-declares/clears on its own.
		var act := interaction.current()
		if act.preview_instance != null:
			declare_preview(act.preview_instance,
					BoardFacade.location_of(world, act.preview_instance))
		else:
			clear_preview()


# The move button's commit — routed through the session's commit_press: the same role
# re-validation and end-then-commit order as clicks and drops, minus the click_commit gate
# (the button is an explicit control; the gate exists to stop STRAY taps, and a press on a
# control that exists only to commit is not stray).
func _on_move_button_pressed(slot: SlotUI) -> void:
	if interaction != null:
		interaction.commit_press(slot)


# Hovering a DESTINATION during a static selection declares the landing preview from that
# spot — the same "who I'd hit / who'd hit me" read the drag phantom declares from its
# hovered slot, so click-flow and drag-flow users get identical information. Off a
# destination, the declaration falls back to the action's baseline (the unit's current
# position, or nothing for a hand card yet to be placed).
func _declare_hover_preview() -> void:
	if interaction == null or not interaction.active():
		return
	var act := interaction.current()
	if act == null or act.source == null:
		return
	if _hover_slot != null and interaction.role_of(_hover_slot) == Interaction.Role.DESTINATION:
		declare_preview(act.source.card_instance, _hover_slot.location)
	elif act.preview_instance != null:
		declare_preview(act.preview_instance,
				BoardFacade.location_of(world, act.preview_instance))
	else:
		clear_preview()


# The slot (either side) whose rect the cursor is inside right now, or null. Rect tests rather
# than mouse_entered — occupant cards would swallow the enter/exit events.
func slot_at_mouse() -> SlotUI:
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var ps := player_slots[r][c] as SlotUI
			if ps.get_global_rect().has_point(ps.get_global_mouse_position()):
				return ps
			var es := enemy_slots[r][c] as SlotUI
			if es.get_global_rect().has_point(es.get_global_mouse_position()):
				return es
	return null


# The UNIT under the cursor, or null — the board half of "what has the player's attention", asked
# by the turn-order strip so pointing at a card on the field lights its entry in the list (the
# mirror of pointing at an entry lighting the card; see TurnOrderStrip). ASKED, not declared: the
# board has no reason to hold this and nothing else wants it, so a query costs the one caller its
# own rect tests rather than costing the board a state to keep correct.
#
# A slot's OCCUPANT, never its phantom — a landing projection stands for a unit that isn't there
# yet and holds no place in the round (the same guard CardUI's own board states use).
func unit_at_mouse() -> CardInstance:
	var slot := slot_at_mouse()
	if slot == null:
		return null
	var card := slot.get_card()
	return card.card_instance if card != null and is_instance_valid(card) else null


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
		declare_preview(_drag_card.card_instance, slot.location)
	elif _drag_card != null and not (is_hand_card.is_valid() and is_hand_card.call(_drag_card)):
		# Off any landing slot — fall back to declaring from where the unit actually stands, so
		# a fielded unit's map info persists through the whole drag, not just over a new slot.
		var inst := _drag_card.card_instance
		declare_preview(inst, BoardFacade.location_of(world, inst))


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
	# only the player's own fielded, non-building units relocate — a fielded building never
	# drags at all while the quick-cast gesture is demolished.
	if inst.owner != 0:
		return false
	if BoardFacade.is_on_board(world, inst) and inst.data.is_building():
		return false
	return true


# Every PLAYER board unit joins the drag affordance, whatever path fielded it (hand
# placement, move, material spawn, the king). Re-entry (a relocating unit) is guarded.
func _wire_unit_drag(card_ui: CardUI) -> void:
	if not card_ui.unit_drag_started.is_connected(_on_unit_drag_started):
		card_ui.unit_drag_started.connect(_on_unit_drag_started)
		card_ui.unit_drag_ended.connect(_on_unit_drag_ended)


# A unit drag BEGINS an Interaction action and nothing else — everything it used to set up
# piecemeal here (cues, card filters, attack preview, drag phantom) is now rendered by
# present() from the action.
func _on_unit_drag_started(card_ui: CardUI) -> void:
	if interaction == null:
		return
	interaction.begin(make_unit_action(card_ui, true, true))


func _on_unit_drag_ended(card_ui: CardUI) -> void:
	if interaction != null:
		interaction.end_drag(card_ui)   # present(null) resets cues/filters/preview/phantom


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

	# No vacate step: docking somewhere new IS leaving where it was (LocationManager.dock).
	world.place_unit_at(inst, slot.location, 0)
	slot.set_card(card_ui)

	_wire_unit_drag(card_ui)

	var results: Array = []
	if from_hand:
		card_ui._show_cost = false
		results = world.play_dispatch(inst)
		cleanup_effect_deaths()

	refresh()
	unit_placed.emit(inst, card_ui, from_hand, cost if from_hand else 0, results)
