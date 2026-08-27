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
# config>, "enemy": <...>}. Unconfigured, the screen runs A STUBBED REAL-CONTENT FIGHT
# (real_fight below — parity order step 2: the catalogue converted through
# CardCatalogue, stub decks in place of the run-originated ones that arrive with the
# loop hookup). The slice's fixed fight (data/slice_fight.json) remains authored and
# loadable — the scripted slice test consumes it.

const SLICE_FIGHT_PATH := "res://data/slice_fight.json"

# ── The salvaged combat frame (H2: the pre-swap surface, a9af8d6^) ────────────────────
# Geometry and styling lifted from the old combat screen; every behavioral wire below is
# re-terminated on the new command/read surface (H3).

# Selectable battle speeds the HUD toggle cycles through (applied as Engine.time_scale).
# Per-combat, not remembered: every fight starts at x1, and the cycle climbs through the
# speed-ups before offering the rare slow-motion pick.
const BATTLE_SPEEDS: Array[float] = [1.0, 1.5, 2.0, 0.5]

# The pacing glyphs, slowest first — one chevron per step up in overlap, indexed by
# Vfx.PACING (likewise ordered slowest first).
const PACE_ICONS := [
	preload("res://assets/ui/icons/pace_1.svg"),
	preload("res://assets/ui/icons/pace_2.svg"),
	preload("res://assets/ui/icons/pace_3.svg"),
	preload("res://assets/ui/icons/pace_4.svg"),
	preload("res://assets/ui/icons/pace_5.svg"),
]

# The gulf between the halves is a COLUMN, not a rule: the turn-order strip's home,
# dressed as a framed track like the relic strip and the mana gauge.
const HALVES_GUTTER_W := 58.0
const HALVES_GUTTER_W_COMPACT := 72.0
const HALVES_FLANK := 10.0   # breathing room either side of the gutter
const COL_SEP := 14.0    # board↔hand breathing room; also a term in _resize_board's budget
const TOP_MARGIN := 12.0   # the body's top inset; another _resize_board height-budget term
const HALF_PAD := 8.0    # inner inset between a zone panel's edge and its slot grid
const SLOT_ASPECT := 216.0 / 165.0   # card height / width (SlotUI's authored proportions)
const PLAYER_ZONE_BG := Color(0.36, 0.48, 0.78, 0.28)
const ENEMY_ZONE_BG := Color(0.72, 0.36, 0.42, 0.24)

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


# The stubbed real-content fight: the whole converted catalogue registered as the
# fight's content, stub decks of actual units (spells carry no effects yet — dead
# weight in a deck — so units only), the classic King against a tribe's captain and
# fodder. The decks are a working stand-in with no design authority; run-originated
# decks replace them at the loop hookup.
static func real_fight() -> Dictionary:
	var units: Array[CardData] = []
	var fodder: Dictionary = {}   # tribe → Array[CardData]
	var captains: Dictionary = {}   # tribe → CardData
	for entry: Variant in CardData.all():
		var card: CardData = entry
		if card.card_type != CardData.CardType.UNIT:
			continue
		if card.enemy_only:
			if card.is_king:
				if not captains.has(card.tribe):
					captains[card.tribe] = card
			else:
				var pool: Array = fodder.get(card.tribe, [])
				pool.append(card)
				fodder[card.tribe] = pool
		elif not card.is_king:
			units.append(card)
	# The player's deck: a deterministic cross-section of the catalogue's units,
	# cheapest to dearest.
	units.sort_custom(func(a: CardData, b: CardData) -> bool:
		return a.cost < b.cost if a.cost != b.cost else a.id < b.id)
	var deck: Array[String] = []
	var stride: int = maxi(1, units.size() / 12)
	for i: int in range(0, units.size(), stride):
		deck.append(units[i].id)
		if deck.size() == 12:
			break
	# The enemy: the first tribe (by name) fielding both a captain and enough fodder.
	var tribes: Array = captains.keys()
	tribes.sort()
	var enemy_deck: Array[String] = []
	var enemy_king := ""
	for tribe: Variant in tribes:
		var pool: Array = fodder.get(tribe, [])
		if pool.size() < 6:
			continue
		enemy_king = (captains[tribe] as CardData).id
		pool.sort_custom(func(a: CardData, b: CardData) -> bool:
			return a.cost < b.cost if a.cost != b.cost else a.id < b.id)
		for card: Variant in pool.slice(0, 8):
			enemy_deck.append((card as CardData).id)
		break
	if deck.is_empty() or enemy_king.is_empty():
		push_error("FightScreen: the catalogue yields no stub fight")
		return {}
	# The authored relic and status envelopes live in the slice file — the stub fight
	# borrows them until the content hookup gives them a catalogue road of their own.
	# The player tests the Contagion Stone (the dictionary's placeholder relic).
	var slice_content: Dictionary = slice_fight().get("content", {})
	return {
		"seed": 20260824,
		"content": {"cards": CardCatalogue.envelopes(),
				"statuses": slice_content.get("statuses", []),
				"relics": slice_content.get("relics", [])},
		"player": {"deck": deck, "units": [{"id": "king", "slot": [1, 0]}],
				"relics": ["contagion_stone"]},
		"enemy": {"deck": enemy_deck, "units": [{"id": enemy_king, "slot": [1, 0]}]},
	}

var world: World = null

var _round_label: Label = null
var _mana_label: Label = null
var _enemy_label: Label = null
var _state_label: Label = null
var _cue_log: Label = null
var _player_grid: GridContainer = null
var _enemy_grid: GridContainer = null
# The unit whose inspect read the hand's sidebar currently shows (identity token only —
# guards set_inspect against per-refresh recomposition churn).
var _inspected: Unit = null
var _cancel_pick: Button = null

# The salvaged chrome's handles (see _build_ui): the vertical mana gauge's chunk stack,
# the left rail's run readouts, the action column's dials, and the chunky Ready button —
# whose caption is a bottom-anchored child Label (Button has no vertical text alignment;
# _resize_board keeps the caption's band level with the hand bar).
var _mana_chunks_box: VBoxContainer = null
var _gold_bag: GoldBag = null
var _exp_gauge: ExpGauge = null
var _relic_tray: RelicTray = null
var _done_btn: Button = null
var _done_label: Label = null
var _speed_btn: Button = null
var _pacing_btn: Button = null
var _battle_speed: float = 1.0   # 100%; reset each combat, cycled by the HUD dial
var _board_row: HBoxContainer = null   # the two board halves; drives responsive sizing
var _arena_chrome_w: float = 0.0   # the fixed width flanking the board — _resize_board's basis
# The fight has ended: the Ready button became Leave, and the state machine's captions
# must not reclaim it.
var _fight_over: bool = false
# Where the enemy King's card stood when it fell — the treasure chest bursts out of that
# spot at the ending (the old king-fall band's blast seat). Zero until a king falls.
var _fallen_king_rect := Rect2()

var _slot_uis: Dictionary[Vector3i, SlotUI] = {}
# The board card faces, one per fielded unit, reused across refreshes so a unit's card is a
# stable node (reparented by the slots as the unit moves). Freed when the unit leaves play.
var _card_uis: Dictionary = {}
# The hand bar (the R7 bar slice) — renders the HandView composed each refresh; presses
# report back by index and this screen decides what a press means.
var _hand: Hand = null
# The salvaged combat VFX dispatcher (see VFXPlayer): the presenter's cues resolve here to
# designed looks on the recipients' cards.
var _vfx: VFXPlayer = null
# The salvaged motion choreographer (see CombatAnimator): attacker ghosts and shakes.
var _animator: CombatAnimator = null
# The salvaged turn-order strip in the halves gutter (see TurnOrderStrip).
var _turn_strip: TurnOrderStrip = null

# ── The strip's board-side seams ────────────────────────────────────────────────────────

# The standing fight screen — the authority board cards ask for the turn-order
# declarations (a static current handle; cards guard the null).
static var current: FightScreen = null


# Which half a unit fights for, as the strip's palette index: 0 = the player's,
# 1 = the enemy's. Allegiance is the birth fact (A4); the palette derives it here at
# the seam.
func owner_of(unit: Unit) -> int:
	return 0 if world != null and unit.allegiance == world.player_side() else 1


# The old board's derive_cards, on the screen's card faces: every declaration change
# re-asks the cards NOW rather than waiting out their slow self-poll.
func _derive_cards() -> void:
	for ui: Variant in _card_uis.values():
		if is_instance_valid(ui as CardUI):
			(ui as CardUI).derive_presentation()

# The unit whose moment is being resolved RIGHT NOW — the strip's gold entry. Derived from
# the §11 beat stream: the presenter records the acting holder at each AUTHORED windup and
# clears it at that source's conclusion (the machinery's unnamed beats — untap and its
# round-opening kin — name no actor and light nothing). The old CombatWorld.acting was the
# cascade's own pointer; the beats are where that fact reaches presentation now.
var acting: Unit = null

# ── The declared SPOTLIGHT ────────────────────────────────────────────────────────────
# "Which unit is being pointed AT from somewhere else on the screen" — the turn-order strip's
# hover (see TurnOrderStrip). A declaration, not a push: the screen holds the one answer
# and every card derives its own look from it, so a lit unit cannot outlive the gesture
# that lit it and no teardown path has to remember to unlight anything.
var _spotlight: Unit = null


func declare_spotlight(unit: Unit) -> void:
	if unit == _spotlight:
		return
	_spotlight = unit
	_derive_cards()


func is_spotlit(unit: Unit) -> bool:
	return unit != null and unit == _spotlight


# ── The declared TURN NUMBERS ─────────────────────────────────────────────────────────
# "Is the player reading the activation order right now, and if so what is it" — declared by
# the TurnOrderStrip while the cursor rests on it, so every unit can wear its own place in
# the order where it stands and the list stops being a thing you look BACK AND FORTH at.
#
# The screen does NOT sort: it is handed the order the strip already got from
# CombatCascade.turn_order (the one sort — see TurnOrderStrip), and only flattens it to a
# lookup so a card asking for its own number costs a hash rather than a sort.
var _turn_numbers: Dictionary = {}


func declare_turn_numbers(order: Array) -> void:
	var next: Dictionary = {}
	for i in order.size():
		next[order[i]] = i + 1
	if next == _turn_numbers:
		return
	_turn_numbers = next
	_derive_cards()


# This unit's place in the declared order, or 0 for "nothing is being declared" / not listed.
func turn_number(unit: Unit) -> int:
	return int(_turn_numbers.get(unit, 0))


# The UNIT under the cursor, or null — the board half of "what has the player's attention",
# asked by the turn-order strip so pointing at a card on the field lights its entry in the
# list (the mirror of pointing at an entry lighting the card; see TurnOrderStrip). ASKED,
# not declared: the screen has no reason to hold this and nothing else wants it, so a query
# costs the one caller its own rect tests rather than costing the screen a state to keep
# correct.
func unit_at_mouse() -> Unit:
	var at := get_global_mouse_position()
	for address: Vector3i in _slot_uis:
		var slot_ui: SlotUI = _slot_uis[address]
		if not slot_ui.get_global_rect().has_point(at):
			continue
		if slot_ui.get_card() == null:
			return null
		return SlotViewModel.occupant(world.board_manager.slot_at(address))
	return null


# "The player pressed this unit" — from somewhere that isn't the unit's own slot (the
# turn-order strip, whose entries stand for units the cursor never has to reach). Routed
# through the SAME slot-click path every real press takes, so the Interaction session still
# gets first refusal and the inspect/select behaviour is whatever clicking the card itself
# does, by construction rather than by a second implementation kept in step with the first.
func press_unit(unit: Unit) -> void:
	if unit == null or world == null:
		return
	var standing: Vector3i = TargetResolver.standing_address(unit)
	if standing.x >= 0 and _slot_uis.has(standing) \
			and (_slot_uis[standing] as SlotUI).get_card() != null:
		_on_slot_clicked(standing)

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
	FightScreen.current = self
	_build_ui()
	# The pick's consequences (preview, ability bar, cues) re-derive whenever the one
	# authority moves — the cards themselves re-derive their ring on their own poll.
	Selection.changed.connect(_on_selection_changed)
	if next_fight.is_empty():
		next_fight = real_fight()
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
	_turn_strip.world = world
	_turn_strip.screen = self
	if not Genesis.setup(world, fight.get("player", {}), fight.get("enemy", {})):
		_state_label.text = "Genesis refused the fight's configuration."
		return
	_register_relic_surfaces()
	# The looks this screen throws by id: the bounty's coin flight and the reward orb the
	# treasure chest hands over at the ending.
	Vfx.register_custom("coin_flight", CoinFlightFx.play)
	Vfx.register_custom("reward_orb", RewardOrbFx.play)
	# The fight's soundscape keys on the encounter's weight (the old screen's intro band).
	var enc: EncounterData = GameData.current_encounter
	var is_boss: bool = enc != null and enc.type == EncounterData.Type.BOSS
	var is_elite: bool = enc != null and enc.type == EncounterData.Type.ELITE
	Sfx.play("combat_boss_intro" if is_boss else "combat_start")
	Sfx.music("music_boss" if is_boss else ("music_elite" if is_elite else "music_combat"))
	Sfx.ambience("amb_combat_battlefield")
	refresh()
	_run.call_deferred()


func _run() -> void:
	var outcome: StringName = await world.clock.run_fight()
	refresh()
	_state_label.text = "VICTORY" if outcome == &"victory" else "DEFEAT"
	_fight_over = true
	# A run's fight consumes its own ending — rewards, map advance, navigation. Without a
	# run and its encounter (the shell's stub fight) the Ready button becomes Leave.
	if GameData.current_run != null and GameData.current_encounter != null:
		await _consume_ending(outcome == &"victory")
		return
	_done_label.text = "Leave"
	_done_label.modulate.a = 1.0
	_done_btn.disabled = false
	_done_btn.pressed.disconnect(_on_end_turn)
	_done_btn.pressed.connect(_leave)


func _leave() -> void:
	var destination := "res://scenes/map.tscn" if GameData.current_run != null \
			else "res://scenes/entry_screen.tscn"
	Nav.goto(destination)


# The fight's ending pays the run — the old combat screen's _handle_combat_end,
# re-terminated on the clock's outcome: the ending dressing, the enemy King's treasure
# chest as the gate into the rewards, the encounter's automatic rewards and outcome, the
# King's wounds carried back, the map advanced and saved, and the flow routed onward —
# reward screen on a win, straight to the map on a boss win (→ Stage Cleared / Run
# Successful), Run Over on a loss.
func _consume_ending(player_won: bool) -> void:
	var enc: EncounterData = GameData.current_encounter
	var run: RunData = GameData.current_run
	Sfx.play("combat_victory" if player_won else "combat_defeat")
	# The screen-level dressing plays out BEFORE navigation (awaited — Nav.goto would cut
	# it off mid-swell); target is the whole combat screen.
	await Vfx.play("screen_victory_rays" if player_won else "screen_defeat_shroud", self)
	# The enemy King left a chest where it fell, and it is a real gate: the rewards are
	# what is inside it, so nothing is applied and no screen changes until the player
	# opens it.
	var chest: TreasureChest = null
	if player_won:
		var seat: Rect2 = _fallen_king_rect if _fallen_king_rect.size != Vector2.ZERO \
				else _enemy_grid.get_global_rect()
		chest = TreasureChest.pop_from(self, seat.get_center(), seat)
		await chest.opened
	# Everything the fight's kills earned in experience banks HERE, once, in a single
	# profile save — win or loss, because a unit killed in a fight that was then lost was
	# still killed. The gauge has been showing this total all along (see _pay_bounty).
	if _pending_exp > 0:
		GameData.grant_experience(_pending_exp)
		_pending_exp = 0
	# One-time milestone checks fire for any real match completion — win OR loss.
	Achievements.record_match_completed()
	if player_won:
		# The encounter's automatic rewards (gold + crafting materials + experience) in
		# one place, uniformly for boss and normal wins; the card pick is the reward
		# screen's. Then the King's wounds carry back into the run (it survived, so
		# health > 0).
		GameData.apply_encounter_rewards(enc)
		var king: Unit = _fielded_king(world.player_side())
		if king != null:
			run.king_damage = maxi(0, run.king_max_health() - roundi(king.get_stat(&"health")))
		enc.outcome = EncounterData.Outcome.WIN
		# Advance map state now that the battle is won.
		var state: MapState = GameData.current_map_state
		if state != null:
			if enc.completing_node_id >= 0 \
					and enc.completing_node_id not in state.visited_nodes:
				state.visited_nodes.append(enc.completing_node_id)
			if enc.destination_node_id >= 0:
				state.current_node_id = enc.destination_node_id
		var is_boss: bool = enc.type == EncounterData.Type.BOSS
		GameData.save_run()
		# When the chest handed over, the reward orb is hanging mid-screen right now —
		# the screen it leads to GROWS out of that spot instead of cutting to it.
		var arrival: String = "screen_grow_in" if chest != null else ""
		if is_boss:
			Nav.goto("res://scenes/map.tscn", arrival)
		else:
			Nav.goto("res://scenes/reward_screen.tscn", arrival)
	else:
		enc.outcome = EncounterData.Outcome.LOSE
		# Defeat ends the run (meta-progression kept) and shows the Run Over screen.
		GameData.end_run()
		Nav.goto("res://scenes/run_over.tscn")


# ── Kill bounties (the old screen's _pay_bounty, re-terminated on the paint pass) ─────
#
# Every enemy that dies hands over gold and experience on the spot (GameData.kill_bounty
# owns the numbers; nothing here knows the rates), and the two halves are cued
# differently ON PURPOSE:
#
#   GOLD  is loud — one coin per gold flies out of the corpse and into the bag on the
#         left rail, so the amount is a countable thing crossing the screen.
#   EXP   is quiet — no number, no coin; the narrow gauge beside the strip just grows.
#
# Gold lands in the run's purse immediately (spendable the moment the fight ends); the
# experience is HELD and banked once at the ending, because every grant writes the
# profile to disk and a save per corpse is a save too many. The arrival wire is the
# retirement pass in refresh() — the one seam every death's face crosses; the live world
# is the only world this screen paints, so a simulated kill can never reach it.
var _pending_exp: int = 0
var _paid: Dictionary = {}   # Unit → true; a corpse pays exactly once


func _pay_bounty(unit: Unit, ui: CardUI) -> void:
	# The bounty needs a run to pay INTO, and that is the whole test. A living unit
	# leaving the field (a burial road) is not a kill.
	var run: RunData = GameData.current_run
	if run == null or unit == null or unit.allegiance != world.enemy_side() \
			or unit.get_stat(&"health") > 0.0 or _paid.has(unit):
		return
	_paid[unit] = true
	var bounty: Dictionary = GameData.kill_bounty(CardData.get_card(String(unit.id).get_slice("~", 0)))
	var gold: int = bounty["gold"]
	var xp: int = bounty["exp"]   # not `exp` — that shadows the GDScript global
	if xp > 0:
		_pending_exp += xp   # the screen holds the debt; the gauge only draws it
		if _exp_gauge != null:
			_exp_gauge.add_exp(xp)
	if gold <= 0 or _gold_bag == null:
		return
	# The bag is told coins are coming BEFORE the purse moves: it mirrors RunData whenever
	# nothing is in flight, so granting first would snap its number to the total and leave
	# the coins arriving at a figure that already counted them.
	_gold_bag.expect_coins(gold)
	run.gold += gold   # spendable at once; the coins are the RECEIPT (GoldBag)
	# Thrown from where the unit stood: the card is being disposed of this very frame, so
	# the flight carries a position, not a node.
	var from: Vector2 = ui.get_global_rect().get_center() if ui != null and is_instance_valid(ui) \
			else _gold_bag.drop_point()
	Vfx.play("coin_flight", _gold_bag,
			{"origin": from, "count": gold, "on_land": _gold_bag.land_coin})


# The side's fielded King — the clock's own scan (CombatClock._king_fallen), aimed at the
# survivor: the ending reads its health to carry the run's wounds.
func _fielded_king(side: Side) -> Unit:
	for entity: GameEntity in world.all_entities():
		if entity is Unit and (entity as Unit).is_king and entity.allegiance == side:
			return entity as Unit
	return null


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


# One procedure cue, resolved to its designed look on the recipient's card (R13: the
# presenter tells, the dispatch table answers; a recipient without a card face — a Side, a
# Game, a hand card — keeps the log line only). Sounds ride the same names, data-gated:
# an authored sounds.json entry named like the cue plays, silence otherwise. The optional
# variant (MSD §10) rides into the looks that use it — buff/debuff land on the named stat's
# badge; heal's variant is always the health stat, which its look already anchors on.
#
# PACING is the old solution's, verbatim: no fixed sleeps — every beat awaits its own
# cue, which returns at that cue's handoff (the one global `vfx.overlap` dial; the spans
# live in the library data). The pip flash is the exception the old code named: a cue
# drawn by somebody else, held for its span (VFXPlayer.PIP_SPAN). Await this call to
# hold presentation for the show; call without await to fire-and-forget.
func play_cue(visual: StringName, recipient: GameEntity, magnitude: float,
		variant: StringName = &"") -> void:
	show_cue(visual, recipient, magnitude)
	# A status application's recipient is the STATUS entity itself — its pip is its
	# registered surface (R14), so the bloom lands on exactly the status that changed;
	# no card face is involved. The contact's refresh composed the pip before the burst.
	if visual == &"status_applied":
		if SoundData.get_sound(String(visual)) != null:
			Sfx.play(String(visual))
		var pip := surface_of(recipient) as StatusPip
		if pip != null:
			pip.flash_applied()
			await beat(&"", [], Vfx.handoff(VFXPlayer.PIP_SPAN))
		return
	var ui := card_of(recipient)
	if ui == null:
		return
	if SoundData.get_sound(String(visual)) != null:
		Sfx.play(String(visual))
	match visual:
		&"health_damage":
			_animator.shake_card(ui)   # the impact shake rides the hit, struck cards only
			await _vfx.play(VFXEvent.health_damage(ui, roundi(magnitude)))
		&"shield_hit":
			_animator.shake_card(ui)
			await _vfx.play(VFXEvent.shield_hit(ui, roundi(magnitude)))
		&"heal":
			await _vfx.play(VFXEvent.heal(ui, roundi(magnitude)))
		&"shield_restored":
			await _vfx.play(VFXEvent.shield_restored(ui, roundi(magnitude)))
		&"buff":
			await _vfx.play(VFXEvent.buff(ui, String(variant), roundi(magnitude)))
		&"debuff":
			await _vfx.play(VFXEvent.debuff(ui, String(variant), roundi(magnitude)))
		&"dodge":
			await _vfx.play(VFXEvent.dodge(ui))
		&"crit":
			await _vfx.play(VFXEvent.crit(ui))
		&"card_placed":
			await _vfx.play(VFXEvent.card_placed(ui))
		_:
			pass   # an unmapped cue keeps its log line — authoring the look is the fix


# The windup's target mark on one recipient — the reticle that leads the hit.
func play_beat_mark(recipient: GameEntity) -> void:
	var ui := _card_uis.get(recipient) as CardUI
	if ui != null and is_instance_valid(ui):
		_vfx.play(VFXEvent.target_mark(ui, Color(1.0, 0.85, 0.2)))


# The presenter's lookups: an entity's card face (null for the un-carded — a Side, the
# Game, a hand card), the VFX dispatcher, and the motion choreographer.
func card_of(entity: GameEntity) -> CardUI:
	var ui := _card_uis.get(entity) as CardUI
	return ui if ui != null and is_instance_valid(ui) else null


# ── Entity surface resolution (R14) ───────────────────────────────────────────────────
# One screen-side lookup answers what on screen stands for an entity. Every
# surface-creating site registers what it made, keyed by the entity reference (status
# pips at _paint_slot's composition, relic chips at tray build); the card map above is
# the table's first entry, populated by the paint pass as it always was. A standing
# stand-in override outranks the table; a freed surface leaves it (the validity guard
# refuses the dead node on resolve); an entity that resolves to nothing shows nothing.
var _surfaces: Dictionary = {}
var _stand_ins: Dictionary = {}


func register_surface(entity: GameEntity, surface: Control) -> void:
	_surfaces[entity] = surface


func stand_in(entity: GameEntity, surface: Control) -> void:
	_stand_ins[entity] = surface


func clear_stand_in(entity: GameEntity) -> void:
	_stand_ins.erase(entity)


func surface_of(entity: GameEntity) -> Control:
	var stand := _stand_ins.get(entity) as Control
	if stand != null and is_instance_valid(stand):
		return stand
	var card: CardUI = card_of(entity)
	if card != null:
		return card
	var surface := _surfaces.get(entity) as Control
	if surface != null and is_instance_valid(surface):
		return surface
	return null


func vfx() -> VFXPlayer:
	return _vfx


func animator() -> CombatAnimator:
	return _animator


func relic_tray() -> RelicTray:
	return _relic_tray


# The relic chips: combat's tray reads the GAME WORLD — the player Side's `relics`
# container, the entities actually governing the fight — injected here once the world
# stands (the tray's world mode; the map HUD keeps the run list). Then the R14
# registration keys each Relic entity to its chip. A relic the catalogue has no look
# for builds no chip and lawfully shows nothing; an enemy relic has no chip either.
func _register_relic_surfaces() -> void:
	if _relic_tray == null or world == null:
		return
	var ids: Array[String] = []
	for member: GameEntity in world.player_side().get_container(&"relics").members:
		if member is Relic:
			ids.append(String(member.id))
	_relic_tray.world_mode = true
	_relic_tray.world_relic_ids = ids
	_relic_tray.refresh()
	for member: GameEntity in world.player_side().get_container(&"relics").members:
		var relic := member as Relic
		if relic == null:
			continue
		var chip: Control = _relic_tray.chip_of(String(relic.id))
		if chip != null:
			register_surface(relic, chip)


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
		commanded.emit(Event.new(&"play", card, world.game))


# ── The idle click (the old combat's _input road, on the new surfaces) ────────────────

func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		if _picking:
			# The core's pick prompt is the aiming session now: right-click is its cancel.
			_on_cancel_pick()
			get_viewport().set_input_as_handled()
		elif _interaction.modal_active():
			_interaction.end_action()
			get_viewport().set_input_as_handled()
		elif not get_viewport().gui_is_dragging() and not _click_engages(true):
			# The universal back-out: a right-click that does NOT itself engage anything
			# (a card's details view) clears the selection, the inspection, and whatever
			# selection action was live.
			_hand.dismiss_to_hand()
			_interaction.end_action()
			get_viewport().set_input_as_handled()
	elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
		_maybe_dismiss_idle_click()


# Whether a click at the cursor's position ENGAGES an interactive control rather than landing
# on dead panel/background space — walked up from the GUI's actual hovered control, so it
# needs no registry of rects. Left clicks engage cards, buttons, scrollbars and the
# turn-order strip (its entries press the units they stand for — see press_unit; a strip
# press this rule dismissed FIRST turned "toggle off" into clear-then-reselect); right
# clicks only cards (the details view — the others don't respond to right-click).
func _click_engages(right_click: bool = false) -> bool:
	var c := get_viewport().gui_get_hovered_control()
	while c != null:
		if c is CardUI:
			return true
		if not right_click and (c is BaseButton or c is ScrollBar or c is TurnOrderStrip):
			return true
		c = c.get_parent() as Control   # a non-Control ancestor ends the walk
	return false


# THE non-interactive-click rule: a click that engages nothing clears the pick (the inspect
# panel goes with it, by derivation) — at any nav level, pick prompt open or not. What
# "engages", walked in order below: a click that will commit the live action; a slot with a
# unit on it (its own press names the new pick); anything interactive under the cursor
# (card, button, scrollbar). An EMPTY slot engages nothing — it is board-shaped dead space,
# exactly the "click on nothing" this exists to catch.
#
# A geometric test in _input, NOT _unhandled_input: background panels/gauges consume clicks
# they do nothing with (STOP mouse filters), so unhandled-input never fires over most of the
# screen. Fires on RELEASE (where slots/cards act); skipped mid-drag (a failed drop must not
# also close the view).
func _maybe_dismiss_idle_click() -> void:
	if get_viewport().gui_is_dragging():
		return
	var slot := _slot_ui_at_mouse()
	# A click that will COMMIT the live action is not a click on nothing: clicking a landing
	# spot while a hand card is selected must engage the placement, not dismiss it (this
	# _input runs BEFORE GUI delivery — clearing here would leave the slot press nothing to
	# commit). Only for actions that accept click commits: a drag-only destination cue
	# (repositioning) eats no taps.
	if _interaction.active() and slot != null and _interaction.current().click_commit:
		var role := _interaction.role_of(slot)
		if role == Interaction.Role.DESTINATION or role == Interaction.Role.TARGET_VALID:
			return
	if slot != null and slot.get_card() != null:
		return   # an occupied slot's press names the new pick itself
	if _picking:
		# The pick prompt owns presses ON slots: an invalid pick stays in the prompt
		# (_on_slot_clicked) rather than reading as a dismissal.
		if slot != null or _click_engages():
			return
		# A click on NOTHING while the prompt is open cancels the ask exactly as its Cancel
		# button does; the pick — whose consequence the prompt was — clears with it.
		_on_cancel_pick()
		_hand.dismiss_to_hand()
		return
	if _click_engages():
		return   # the control under the cursor acts on its own behalf, whatever the level
	_hand.dismiss_to_hand()


func _slot_ui_at_mouse() -> SlotUI:
	var at := get_global_mouse_position()
	for address: Vector3i in _slot_uis:
		if (_slot_uis[address] as SlotUI).get_global_rect().has_point(at):
			return _slot_uis[address]
	return null


func _on_ability_clicked(ability_name: StringName) -> void:
	var selected: Unit = _selected_unit()
	if _span_active and _awaiting_command and selected != null \
			and selected.allegiance == world.player_side():
		var ask := Event.new(&"use_ability", selected, world.game)
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
	if FightScreen.current == self:
		FightScreen.current = null
	Engine.time_scale = 1.0   # the speed dial is per-combat — never outlives the fight
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
	_refresh_mana()
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
				# The enemy King's fall leaves its spot behind — the ending's treasure
				# chest bursts out of it (_consume_ending).
				if (unit as Unit).is_king and (unit as Unit).allegiance == world.enemy_side():
					_fallen_king_rect = ui.get_global_rect()
				_pay_bounty(unit as Unit, ui)
				ui.queue_free()
			_card_uis.erase(unit)
	_rebuild_hand()
	_refresh_inspect()
	_refresh_done_btn()
	_derive_king_peril()


# The header's HP field and the critical heartbeat, derived from the King's live board
# health on every paint (the old screen's _on_king_health_changed, re-terminated on the
# paint pass — the core's stats carry no signals): RunData only finalizes king_damage at
# the ending, so the header is wired to the LIVE health to tick during the fight; the
# King in its last quarter is the run itself in peril — a heartbeat glow rides the card
# while critical, attached/detached on the threshold crossings (with one warning sting).
const KING_CRITICAL_RATIO := 0.25
var _king_critical := false
var _king_hp_shown: int = -1   # last health the header was told; -1 = not yet derived

func _derive_king_peril() -> void:
	var run: RunData = GameData.current_run
	if run == null:
		return
	var king: Unit = _fielded_king(world.player_side())
	if king == null:
		return
	var current: int = roundi(king.get_stat(&"health"))
	if current == _king_hp_shown:
		return
	_king_hp_shown = current
	GameSignals.hp_changed.emit(current, run.king_max_health())
	var critical := current > 0 \
			and current <= int(ceil(run.king_max_health() * KING_CRITICAL_RATIO))
	if critical != _king_critical:
		_king_critical = critical
		var king_ui := _card_uis.get(king) as CardUI
		if king_ui != null:
			if critical:
				Sfx.play("combat_king_low")
				Vfx.attach("king_critical_pulse", king_ui)
			else:
				Vfx.detach("king_critical_pulse", king_ui)


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
		# The row's pips just re-composed: register each as its status's surface (R14) —
		# the fresh generation's registration replaces the freed one's.
		for pip: StatusPip in ui.status_pips():
			if pip.view.subject != null:
				register_surface(pip.view.subject, pip)
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
		# A tapped (exhausted) unit dims — the shared spent grey the strip's entries wear too.
		ui.set_exhausted(unit.get_stat(&"tapped") > 0.0)
		# The menace read: this unit's own targeting resolves to the previewed pivot.
		ui.set_threat_highlight(_menacing.has(unit))
	slot_ui.set_ground(SlotViewModel.ground_view(slot))
	# The ground's tabs likewise (R14); a duplicates pile registers in row order, so the
	# newest tab stands — the same choice find_ground_pip makes.
	for pip: StatusPip in slot_ui.ground_pips():
		if pip.view.subject != null:
			register_surface(pip.view.subject, pip)
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
	commanded.emit(Event.new(&"play", card, world.game))


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
	var ask := Event.new(&"use_ability", unit, world.game)
	ask.components.append(NameEventData.new(&"ability", &"move"))
	commanded.emit(ask)


# The hand's inspect sidebar + ability tray derive from the one selection authority: a
# FIELDED pick (either side) is the inspected unit; the composition is this screen's (the
# engine-reading layer), the bar renders what it is handed. The Abilities roster rides
# along so the fuchsia door gates itself.
func _refresh_inspect() -> void:
	var selected: Unit = _selected_unit()
	if selected != null and TargetResolver.standing_address(selected).x < 0:
		selected = null   # a hand pick is a selection, not an inspection
	if selected != _inspected:
		_inspected = selected
		_hand.set_inspect(HandViewModel.inspect_view(selected, world.player_side())
				if selected != null else null)
	_hand.set_ability_roster(HandViewModel.ability_roster(world))


# ── Construction ──────────────────────────────────────────────────────────────────────

# The salvaged combat frame (H2). The screen owns the full rect with no Shell header;
# margins are pared to the bone — cards read bigger for every pixel reclaimed: sides keep
# a tight inset, the top keeps token breathing room, and the BOTTOM is pulled BELOW the
# screen edge so the hand bar bleeds off it (only dead card frame is cropped — see
# Hand.BOTTOM_BLEED).
func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_battle_speed = 1.0   # every fight starts at 100%
	Engine.time_scale = _battle_speed
	_interaction = Interaction.new()
	add_child(_interaction)
	_vfx = VFXPlayer.new()
	add_child(_vfx)
	_vfx.setup(self)
	_animator = CombatAnimator.new()
	add_child(_animator)
	_animator.setup(self)
	# Cue rendering derives from the one `changed` signal — a gesture ending resets
	# everything structurally, with no per-path cleanup to forget.
	_interaction.changed.connect(_on_interaction_changed)

	var side := 16 if UIScale.is_compact() else 8
	var body := MarginContainer.new()
	body.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	body.add_theme_constant_override("margin_left", side)
	body.add_theme_constant_override("margin_right", side)
	body.add_theme_constant_override("margin_bottom", -int(Hand.BOTTOM_BLEED))
	body.add_theme_constant_override("margin_top", int(TOP_MARGIN))
	add_child(body)

	# The body splits into the MAIN column (arena over hand bar) and the full-height
	# ACTION column on the right — so the Ready button spans BOTH bands, from under the
	# dial row all the way down through the hand bar's height.
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	body.add_child(root)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", int(COL_SEP))
	root.add_child(col)

	# The arena row: the relic strip hugs the LEFT of the board, the two board halves fill
	# the middle around the gutter, and the action column hugs the RIGHT. All stretch to
	# the same height, so the row reads as one balanced band. The mana gauge lives in the
	# HAND bar below (its leftmost column) — mana is what the hand spends.
	var arena := HBoxContainer.new()
	arena.size_flags_vertical = Control.SIZE_EXPAND_FILL
	arena.add_theme_constant_override("separation", 12)
	col.add_child(arena)

	# Outboard of everything on the left: the experience column — the quiet half of a
	# kill's payment. Seated only under a loaded profile (the slice launches without one).
	var exp_w := 0.0
	if GameData.current_profile != null:
		_exp_gauge = ExpGauge.new()
		arena.add_child(_exp_gauge)
		exp_w = _exp_gauge.custom_minimum_size.x

	var relic_strip := _build_relic_strip()
	arena.add_child(relic_strip)

	_board_row = HBoxContainer.new()
	_board_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_board_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# The halves' gulf is the gutter plus two flanking separations, totalling
	# _halves_gap() (the width _resize_board budgets for).
	_board_row.add_theme_constant_override("separation", int(HALVES_FLANK))
	arena.add_child(_board_row)

	_player_grid = _build_half(_board_row, true)
	_board_row.add_child(_build_halves_gutter())
	_enemy_grid = _build_half(_board_row, false)

	# The action column: the main column's full-height SIBLING (not part of the arena).
	# Its own bottom margin swallows the body's below-screen bleed — the Ready button is
	# interactive, so it must end at the real screen edge.
	var action_wrap := MarginContainer.new()
	action_wrap.add_theme_constant_override("margin_bottom", int(Hand.BOTTOM_BLEED))
	var actions := _build_action_column()
	action_wrap.add_child(actions)
	root.add_child(action_wrap)

	# The fixed width flanking the board — _resize_board's width basis (it must come from
	# here and not from live container sizes; see _resize_board).
	_arena_chrome_w = side * 2.0 + relic_strip.custom_minimum_size.x \
		+ exp_w + actions.custom_minimum_size.x + 3.0 * 12.0

	_hand = Hand.new()
	add_child(_hand)
	# The mana gauge rides INSIDE the bar as its leftmost column (the bar's authored
	# left_widget seat).
	_hand.build_into(col, _build_mana_gauge())
	_hand.set_card_size(Vector2(110, 144))   # the slots' size — one card scale per screen
	_hand.card_pressed.connect(_on_hand_index_pressed)
	_hand.selection_changed.connect(_on_hand_selection_changed)
	_hand.ability_pressed.connect(_on_ability_clicked)
	_hand.wire_unit_card = _wire_unit_drag

	# The board fills its area with the biggest cards that fit (recomputed on any resize),
	# instead of a fixed grid marooned in empty space.
	_board_row.resized.connect(_resize_board)
	call_deferred("_resize_board")


# A board half: a tinted zone panel holding the slot grid, centred in whatever area it's
# given so leftover space sits as balanced margins rather than a lopsided gap. No
# "Player"/"Enemy" label — the tints and the near/far halves read for themselves. The
# enemy half reverses its ROW order: lane-sharing rows (BoardGeometry — rows mirror, two
# cells share a lane when their rows sum to ROWS − 1) sit level across the gutter.
func _build_half(parent: BoxContainer, is_player: bool) -> GridContainer:
	var zone := Panel.new()
	zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	zone.size_flags_vertical = Control.SIZE_EXPAND_FILL
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
	grid.columns = BoardGeometry.COLS
	# The gutter is the widget's own constant — the ground frames (half a gap each) only
	# tile into one field when the layout honours the same number.
	grid.add_theme_constant_override("h_separation", SlotUI.SLOT_GAP)
	grid.add_theme_constant_override("v_separation", SlotUI.SLOT_GAP)
	center.add_child(grid)

	var side_index := 0 if is_player else 1
	var row_order: Array = range(BoardGeometry.ROWS) if is_player \
			else range(BoardGeometry.ROWS - 1, -1, -1)
	for row: int in row_order:
		for colm: int in BoardGeometry.COLS:
			var address := Vector3i(side_index, row, colm)
			var slot_ui := SlotUI.new()
			slot_ui.own_side = is_player
			slot_ui.interaction = _interaction   # the drop gate's authority (drag's atom)
			slot_ui.pressed.connect(_on_slot_clicked.bind(address))
			slot_ui.move_pressed.connect(_on_move_button_pressed.bind(slot_ui))
			slot_ui.move_hover.connect(_on_move_button_hover.bind(slot_ui))
			slot_ui.custom_minimum_size = Vector2(110, 144)
			grid.add_child(slot_ui)
			_slot_uis[address] = slot_ui
	return grid


func _halves_gutter_w() -> float:
	return HALVES_GUTTER_W_COMPACT if UIScale.is_compact() else HALVES_GUTTER_W


# The width _resize_board must keep out of the board's own budget: the gutter and its flanks.
func _halves_gap() -> float:
	return _halves_gutter_w() + HALVES_FLANK * 2.0


# The column standing between the player and enemy halves: the hard line the two fields
# meet at, and the turn-order strip's home (salvaged — see TurnOrderStrip). Framed like the
# relic strip and the mana gauge so the three read as one family of side rails. The strip
# fills the frame behind a small padding; its world/screen handles are injected once the
# world exists (see _ready).
func _build_halves_gutter() -> Control:
	var gutter := Panel.new()
	gutter.custom_minimum_size.x = _halves_gutter_w()
	gutter.size_flags_vertical = Control.SIZE_EXPAND_FILL
	UIScale.tip(gutter, Loc.t("combat.turn_order_tip"))
	var track := StyleBoxFlat.new()
	track.bg_color = ScreenUI.MANA_TRACK_BG
	track.set_corner_radius_all(12)
	track.set_border_width_all(2)
	track.border_color = ScreenUI.MANA_TRACK_BORDER
	gutter.add_theme_stylebox_override("panel", track)
	_turn_strip = TurnOrderStrip.new()
	_turn_strip.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Tight on purpose (the old gutter's own margins): every pixel the padding gives
	# back is thumbnail — the entries out-dent past even this (BLEED).
	_turn_strip.offset_left = 2.0
	_turn_strip.offset_right = -2.0
	_turn_strip.offset_top = 4.0
	_turn_strip.offset_bottom = -4.0
	gutter.add_child(_turn_strip)
	return gutter


# The vertical relic strip, owning the whole left rail: with no header during combat this
# is where the fight's relics live — a full-height column of big chips, framed like the
# mana gauge so the two read as one family. Read-only here (discarding is the map HUD's
# job); the world's relic ids are injected at _register_relic_surfaces once Genesis runs.
func _build_relic_strip() -> Control:
	var strip := Panel.new()
	strip.custom_minimum_size.x = 122.0 if UIScale.is_compact() else 92.0
	strip.size_flags_vertical = Control.SIZE_EXPAND_FILL
	UIScale.tip(strip, Loc.t("combat.relics_tip"))
	var track := StyleBoxFlat.new()
	track.bg_color = ScreenUI.MANA_TRACK_BG
	track.set_corner_radius_all(12)
	track.set_border_width_all(2)
	track.border_color = ScreenUI.MANA_TRACK_BORDER
	strip.add_theme_stylebox_override("panel", track)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", 4)
	pad.add_theme_constant_override("margin_right", 4)
	pad.add_theme_constant_override("margin_top", 8)
	pad.add_theme_constant_override("margin_bottom", 8)
	strip.add_child(pad)

	# One column inside the padding: the purse, then a hairline, then the relics. The bag
	# heads the strip because it is the same kind of thing as what follows — a run-long
	# possession combat only reports on.
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	pad.add_child(column)

	_gold_bag = GoldBag.new()
	column.add_child(_gold_bag)
	column.add_child(_strip_rule())

	_relic_tray = RelicTray.new()
	_relic_tray.vertical = true
	_relic_tray.interactive = false   # info-only: a chip opens its detail overlay,
									   # never offers Discard
	# Consumable use has no road into the new command surface yet (H3: the seat renders,
	# armed never) — recovered with the relics' own hookup pass.
	_relic_tray.consumable_check = func() -> bool: return false
	column.add_child(_relic_tray)
	return strip


# The hairline separating the purse from the relics below it — the strip holds two kinds
# of thing, and one rule is cheaper than a gap wide enough to say so.
func _strip_rule() -> Control:
	var rule := Panel.new()
	rule.custom_minimum_size.y = 2.0
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = ScreenUI.MANA_TRACK_BORDER
	sb.set_corner_radius_all(1)
	rule.add_theme_stylebox_override("panel", sb)
	return rule


# The vertical mana gauge, anchoring the LEFT end of the hand bar (full bar height — mana
# is what the hand spends, so the readout sits with the cards it pays for): a "MANA"
# header cell at the TOP, the chunk stack in the middle (one chunk per point of capacity —
# spent chunks dim, available ones lit, filling from the bottom), and the current/max
# count in a matching footer cell at the BOTTOM. _refresh_mana rebuilds the chunk count
# when capacity ramps and recolours them as mana is spent.
func _build_mana_gauge() -> Control:
	var compact := UIScale.is_compact()
	var gauge := Panel.new()
	gauge.custom_minimum_size.x = 122.0 if compact else 92.0
	gauge.size_flags_vertical = Control.SIZE_EXPAND_FILL
	UIScale.tip(gauge, Loc.t("combat.mana_tip"))
	var track := StyleBoxFlat.new()
	track.bg_color = ScreenUI.MANA_TRACK_BG
	track.set_corner_radius_all(12)
	track.set_border_width_all(2)
	track.border_color = ScreenUI.MANA_TRACK_BORDER
	gauge.add_theme_stylebox_override("panel", track)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", 6)
	pad.add_theme_constant_override("margin_right", 6)
	pad.add_theme_constant_override("margin_top", 6)
	# The hand bar's last BOTTOM_BLEED px hang off-screen — keep the footer clear of them.
	pad.add_theme_constant_override("margin_bottom", 6 + int(Hand.BOTTOM_BLEED))
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gauge.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(col)

	var tag := Label.new()
	tag.text = Loc.t("combat.mana_tag")
	tag.add_theme_font_size_override("font_size", 22 if compact else 16)
	tag.add_theme_color_override("font_color", Color(0.72, 0.78, 0.92))
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(tag)

	col.add_child(_gauge_divider())

	_mana_chunks_box = VBoxContainer.new()
	_mana_chunks_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_mana_chunks_box.add_theme_constant_override("separation", 2)
	_mana_chunks_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_mana_chunks_box)

	col.add_child(_gauge_divider())

	_mana_label = Label.new()
	_mana_label.add_theme_font_size_override("font_size", 28 if compact else 22)
	_mana_label.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	_mana_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mana_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	col.add_child(_mana_label)
	return gauge


# A thin horizontal rule framing the mana gauge's header/footer cells against the stack.
func _gauge_divider() -> Panel:
	var divider := Panel.new()
	divider.custom_minimum_size.y = 2.0
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = ScreenUI.MANA_TRACK_BORDER
	divider.add_theme_stylebox_override("panel", sb)
	return divider


func _make_mana_chunk() -> Panel:
	var chunk := Panel.new()
	chunk.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chunk.custom_minimum_size.y = 2.0   # a floor so many chunks never collapse to nothing
	chunk.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return chunk


# The action column, hugging the RIGHT of the board: the enemy readout's seat at the TOP
# (level with the board it reports on), then the dial row (pacing / speed / settings),
# then the debug row, then the big "Ready" button filling everything below. Squashed as
# narrow as its labels allow — its width comes straight out of the board's card size.
func _build_action_column() -> Control:
	var compact := UIScale.is_compact()
	var col := VBoxContainer.new()
	# Width floor: a GlossyButton nine-patch can only STRETCH cleanly; compressing the
	# centre band squashes the baked rim/sheen into doubled-line artifacts.
	col.custom_minimum_size.x = 200.0 if compact else 192.0
	col.add_theme_constant_override("separation", 10)

	# The intel seat — until an enemy-intel widget lands, the frame hosts the working
	# readouts (round, enemy mana, state, and the cue log).
	var seat := Panel.new()
	seat.custom_minimum_size.y = 150.0
	var track := StyleBoxFlat.new()
	track.bg_color = ScreenUI.MANA_TRACK_BG
	track.set_corner_radius_all(12)
	track.set_border_width_all(2)
	track.border_color = ScreenUI.MANA_TRACK_BORDER
	seat.add_theme_stylebox_override("panel", track)
	var seat_pad := MarginContainer.new()
	seat_pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	seat_pad.add_theme_constant_override("margin_left", 8)
	seat_pad.add_theme_constant_override("margin_right", 8)
	seat_pad.add_theme_constant_override("margin_top", 6)
	seat_pad.add_theme_constant_override("margin_bottom", 6)
	seat.add_child(seat_pad)
	var seat_col := VBoxContainer.new()
	seat_pad.add_child(seat_col)
	_round_label = Label.new()
	_round_label.text = "Round 0"
	seat_col.add_child(_round_label)
	_enemy_label = Label.new()
	seat_col.add_child(_enemy_label)
	_state_label = Label.new()
	_state_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	seat_col.add_child(_state_label)
	_cue_log = Label.new()
	_cue_log.add_theme_font_size_override("font_size", 12)
	_cue_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_cue_log.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	seat_col.add_child(_cue_log)
	col.add_child(seat)

	# The dial row — the three dials the player may want mid-fight, side by side: how much
	# the animations overlap (pacing), how fast the clock runs (speed), and the full
	# settings panel. Near-square at the column's width, so they take GlossyButton's
	# square bake rather than a squashed nine-patch.
	var side := ScreenUI.BUTTON_HEIGHT_COMPACT - 16.0
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	top_row.custom_minimum_size.y = side
	col.add_child(top_row)

	_pacing_btn = ScreenUI.action_button("", _on_pacing_pressed, Vector2(0, side))
	_pacing_btn.expand_icon = true
	_pacing_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pacing_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(_pacing_btn)
	_refresh_pacing_btn()

	_speed_btn = ScreenUI.action_button("", _on_speed_pressed, Vector2(0, side),
			26 if compact else 20)
	_speed_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(_speed_btn)
	_refresh_speed_btn()

	# The panel carries the SAME pacing picker as the button beside it, so re-read it on
	# dismiss — otherwise a change made in the panel leaves a stale chevron count here.
	var open_settings := func() -> void:
		var overlay := SettingsOverlay.open(self)
		if overlay != null:
			overlay.closed.connect(_refresh_pacing_btn)
	var gear := ScreenUI.action_button("", open_settings, Vector2(0, side))
	gear.icon = preload("res://assets/ui/icons/settings.png")
	gear.expand_icon = true
	gear.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gear.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIScale.tip(gear, Loc.t("settings.title"))
	top_row.add_child(gear)

	# Debug tools get their OWN row, present only in debug builds — so a debug affordance
	# never takes width from a control the player actually uses. The old row's end-combat
	# ✕ and Kill have no road into the new core yet (H3) — seated dark until the debug
	# recovery pass.
	if DebugConfig.enabled():
		var debug_row := HBoxContainer.new()
		debug_row.add_theme_constant_override("separation", 8)
		debug_row.custom_minimum_size.y = side
		col.add_child(debug_row)

		var debug_close := ScreenUI.close_button(Callable(), true)
		debug_close.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		debug_close.size_flags_vertical = Control.SIZE_FILL
		debug_close.custom_minimum_size = Vector2(0, side)
		debug_close.disabled = true
		UIScale.tip(debug_close, "Debug: end combat (pending its road into the core)")
		debug_row.add_child(debug_close)

		var debug_kill := ScreenUI.action_button("Kill", Callable(),
				Vector2(0, side), 20, ScreenUI.CHROME_DEBUG)
		debug_kill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		debug_kill.size_flags_vertical = Control.SIZE_FILL
		debug_kill.disabled = true
		UIScale.tip(debug_kill, "Debug: kill the enemy captain (pending its road into the core)")
		debug_row.add_child(debug_kill)

	# The pick's escape hatch — visible only while a pick prompt is open (see pick_one).
	_cancel_pick = ScreenUI.action_button("Cancel", _on_cancel_pick,
			Vector2(0, side), 20, ScreenUI.CHROME_DANGER)
	_cancel_pick.visible = false
	col.add_child(_cancel_pick)

	# The key touch target — "Ready" — a chunky vertical button filling the rest of the
	# column, all the way down through the hand bar's band. The caption is NOT the
	# button's own text (which Godot can only centre vertically — mid-screen on a button
	# this tall): it's a bottom-anchored child Label whose band _resize_board keeps equal
	# to the hand bar's. Styled to match GlossyButton's own text treatment.
	_done_btn = ScreenUI.action_button("", _on_end_turn, Vector2.ZERO,
			44 if compact else 30, ScreenUI.CHROME_READY)
	_done_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_done_btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_done_btn)

	_done_label = Label.new()
	_done_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_done_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_done_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_done_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_done_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_done_label.add_theme_font_override("font", GlossyButton.CHUNKY_FONT)
	_done_label.add_theme_font_size_override("font_size", 44 if compact else 30)
	_done_label.add_theme_color_override("font_color", Color.WHITE)
	_done_label.add_theme_color_override("font_outline_color", ScreenUI.CHROME_READY.darkened(0.55))
	_done_label.add_theme_constant_override("outline_size", 8)
	_done_btn.add_child(_done_label)

	_refresh_done_btn()
	return col


# Sizes every board slot AND the hand bar's cards to the largest shared card size that
# fits — one card size for the whole screen, keeping the card aspect, so the halves fill
# their space with big, tappable cards and even gaps. Runs on any resize.
#
# CRITICAL: the solve reads NOTHING the cards themselves influence — only the screen size
# and the fixed chrome around the board (_arena_chrome_w, margins, pads). Live container
# sizes are poisoned in both directions: the height feeds back through Hand.set_card_size,
# and _board_row's width equals its CONTENT minimum whenever the slots overflow a narrow
# window. From stable inputs, re-entry recomputes the identical target and stops.
func _resize_board() -> void:
	if size.x < 1.0 or size.y < 1.0 or _arena_chrome_w <= 0.0:
		return

	var cols := BoardGeometry.COLS
	var rows := BoardGeometry.ROWS
	var gap := float(SlotUI.SLOT_GAP)
	# Width splits across the two halves (minus the gulf between them); each half holds
	# `cols` inside its zone panel's inner pad.
	var half_w := (size.x - _arena_chrome_w - _halves_gap()) / 2.0
	var slot_w_by_width := (half_w - 2.0 * HALF_PAD - (cols - 1) * gap) / float(cols)
	# Height: the body's column carries the board's `rows` cards + the hand's one card
	# (same size), the row gaps, the zone panels' vertical pad, the column separation, and
	# the hand bar's top pad. The bar's bottom edge sits BOTTOM_BLEED below the screen.
	var avail_h := size.y - TOP_MARGIN + Hand.BOTTOM_BLEED
	var budget := avail_h - COL_SEP - Hand.PAD_TOP - 2.0 * HALF_PAD \
		- (rows - 1) * gap
	var slot_h := budget / float(rows + 1)
	var slot_w := floorf(minf(slot_w_by_width, slot_h / SLOT_ASPECT))
	if slot_w < 1.0:
		return
	var slot_size := Vector2(slot_w, floorf(slot_w * SLOT_ASPECT))

	# Before the slot bail — the hand can be stale even when the slots are already correct
	# (it no-ops when unchanged).
	_hand.set_card_size(slot_size)
	# Keep the Ready caption's band equal to the hand bar's visible height, so the word
	# sits level with the bar beside it. Capped by the button itself: on a short window
	# the band could otherwise exceed the button and draw the caption up over the column.
	if _done_label != null:
		var band := slot_size.y + Hand.PAD_TOP - Hand.BOTTOM_BLEED
		if _done_btn != null and _done_btn.size.y > 1.0:
			band = minf(band, _done_btn.size.y)
		_done_label.offset_top = -band
	var sample := _slot_uis.get(Vector3i(0, 0, 0)) as SlotUI
	if sample == null or sample.custom_minimum_size == slot_size:
		return   # already correct → stop before we trigger another resize
	for slot_ui: SlotUI in _slot_uis.values():
		slot_ui.custom_minimum_size = slot_size


func _refresh_mana() -> void:
	if world == null:
		return
	var mana := roundi(world.player_side().get_stat(&"mana"))
	var capacity := roundi(world.player_side().get_stat(&"mana_capacity"))
	if _mana_label != null:
		_mana_label.text = "%d/%d" % [mana, capacity]
	if _mana_chunks_box == null:
		return

	# Rebuild the segment stack when capacity changes (it ramps up over the fight).
	var want := maxi(capacity, 0)
	if _mana_chunks_box.get_child_count() != want:
		for ch in _mana_chunks_box.get_children():
			_mana_chunks_box.remove_child(ch)
			ch.queue_free()
		for _i in want:
			_mana_chunks_box.add_child(_make_mana_chunk())

	# Light the bottom `mana` chunks (available), dim the rest (spent / not yet ramped).
	var chunks := _mana_chunks_box.get_children()
	for idx in chunks.size():
		var from_bottom := chunks.size() - 1 - idx
		var sb := StyleBoxFlat.new()
		sb.bg_color = ScreenUI.MANA_LIT if from_bottom < mana else ScreenUI.MANA_DIM
		sb.set_corner_radius_all(4)
		(chunks[idx] as Panel).add_theme_stylebox_override("panel", sb)


# Advance to the next battle speed, applying it immediately (live time_scale). Per-combat
# only — not persisted, so the next fight starts back at x1.
func _on_speed_pressed() -> void:
	var i := BATTLE_SPEEDS.find(_battle_speed)
	_battle_speed = BATTLE_SPEEDS[(i + 1) % BATTLE_SPEEDS.size()]
	Engine.time_scale = _battle_speed
	_refresh_speed_btn()


# Advance to the next pacing preset. UNLIKE speed, this IS the player's persisted setting —
# the same value the settings panel writes (Vfx.set_overlap): a standing preference for
# how combat should read, not a per-fight scrub.
func _on_pacing_pressed() -> void:
	Vfx.set_overlap(float(Vfx.PACING[(_pacing_index() + 1) % Vfx.PACING.size()]["overlap"]))
	_refresh_pacing_btn()


func _pacing_index() -> int:
	var key := Vfx.pacing_key()
	for i in Vfx.PACING.size():
		if str(Vfx.PACING[i]["key"]) == key:
			return i
	return 0


func _refresh_pacing_btn() -> void:
	if _pacing_btn == null:
		return
	var i := _pacing_index()
	_pacing_btn.icon = PACE_ICONS[i]
	UIScale.tip(_pacing_btn, "%s: %s" % [Loc.t("settings.pacing"),
			Loc.t("settings.pacing." + str(Vfx.PACING[i]["key"]))])


func _refresh_speed_btn() -> void:
	if _speed_btn != null:
		# "x1" / "x1.5" — one decimal, a bare ".0" trimmed so the whole multipliers stay
		# short in a button this narrow.
		_speed_btn.text = "x" + String.num(_battle_speed, 1).trim_suffix(".0")
		UIScale.tip(_speed_btn, Loc.t("settings.speed"))


# The Ready button's caption speaks the turn state (the old phase captions, mapped onto
# the command span): the player's open command window arms it; a pick prompt or anyone
# else's turn parks it.
func _refresh_done_btn() -> void:
	if _done_btn == null or _done_label == null or _fight_over:
		return
	if _picking:
		_done_label.text = Loc.t("combat.select_target")
		_done_btn.disabled = true
	elif _span_active and _awaiting_command:
		_done_label.text = Loc.t("combat.ready")
		_done_btn.disabled = false
	else:
		_done_label.text = Loc.t("combat.battle")
		_done_btn.disabled = true
	# The caption is a child Label, outside the button's own disabled styling — dim it
	# manually.
	_done_label.modulate.a = 0.55 if _done_btn.disabled else 1.0
