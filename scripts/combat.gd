extends Control

# Selectable battle speeds the HUD toggle cycles through (applied as Engine.time_scale). Shown as
# multipliers; every fight starts at x1 — the dial is per-combat, not remembered. Ordered so the
# cycle climbs from normal through the speed-ups and only then offers slow-motion, since that is
# the rare pick: x1 → x1.5 → x2 → x0.5 → x1.
const BATTLE_SPEEDS: Array[float] = [1.0, 1.5, 2.0, 0.5]

# The pacing glyphs, slowest first — one chevron per step up in overlap, indexed by Vfx.PACING
# (which is likewise ordered slowest first). The play/fast-forward convention, so the button reads
# without a label.
const PACE_ICONS := [
	preload("res://assets/ui/icons/pace_1.svg"),
	preload("res://assets/ui/icons/pace_2.svg"),
	preload("res://assets/ui/icons/pace_3.svg"),
	preload("res://assets/ui/icons/pace_4.svg"),
	preload("res://assets/ui/icons/pace_5.svg"),
]

# Combat holds NO animation timing of its own. It declares what happens and in what causal order;
# each cue's own span and the global `vfx.overlap` dial decide the clock (see the "Sequencing"
# section in Vfx). The fixed sleeps that used to live here — SHIELD_LEAD, RELIC_CUE_LEAD, the flat
# post-strike beat — were dead air between finished animations; awaiting the cue itself now returns
# at its handoff, so the next beat starts under the previous one's tail instead of after it.
# (RELIC_CHIP_SPAN moved to LivePresenter with the relic-glint body.)
const BOARD_HALVES_GAP := 24.0   # the TOTAL gulf between the halves: divider + flanking gaps
const HALVES_DIVIDER_W := 4.0   # the visible rule standing in the middle of that gulf
const COL_SEP := 14.0   # board↔hand breathing room; also a term in _resize_board's height budget
const TOP_MARGIN := 12.0   # the body's top inset; another _resize_board height-budget term

# Turn structure ONLY. "What is the player's gesture doing" (targeting, placing, moving,
# aiming an autocast) lives in the Interaction session, not here — see INTERACTION_DESIGN.md.
enum Phase { CPU_PLACE, PLAYER_PLACE, COMBAT }

var _phase: Phase = Phase.CPU_PLACE
var _turn: int    = 0
# Whether a MODAL aiming session currently locks placement input (the old TARGETING phase's
# job) — tracked so _on_interaction_changed only toggles the lock on transitions.
var _modal_lock: bool = false

# The two sides' resource state (mana / hand / draw pile) — one object each, mutated ONLY
# through Resolver.submit (side stats: draw/discard/mana/max_mana). The player's Hand bar
# and the mana gauge subscribe to the player side's signals; the enemy side has no watchers.
var _player_side: CombatSide
var _enemy_side: CombatSide

var _mana_label: Label              # current-mana number on the vertical gauge
var _mana_chunks_box: VBoxContainer  # one chunk per max-mana point; lit=available, dim=spent
var _gold_bag: GoldBag       # the purse coins fly into, atop the relic strip (see _pay_bounty)
var _exp_gauge: ExpGauge     # the narrow experience column outboard of that strip
var _reward_chest: TreasureChest   # dropped by a falling enemy King; the gate into the rewards
var _relic_tray: RelicTray   # read-only vertical relic strip on the screen's left edge (see
							  # _build_relic_strip); a firing relic glints its chip
var _presenter: CombatPresenter   # the cascade's presentation surface — LivePresenter here;
								   # the null base class in a simulation (see CombatPresenter)
var _world: CombatWorld           # THE cohesive rules-state context: the board's grids
								   # (aliased), the sides, run modifiers, world policy
var _cascade: CombatCascade       # the event cascade, hosted on (world, presenter); the
								   # _broadcast/_fire/… methods below are delegating wrappers
var _consumable_busy := false   # a consumable's use is resolving — no second use may start
								 # under its awaits (the chips' usability check reads this)
var _done_btn: Button        # the chunky vertical "Ready" button (right of the board)
var _done_label: Label       # the Ready button's caption — bottom-anchored inside the button so
							  # the word sits on the hand band, aligned with Inspect Abilities
							  # (Button has no vertical text alignment; see _build_action_column)
var _speed_btn: Button
var _pacing_btn: Button
var _battle_speed: float = 1.0   # 100%; reset each combat, cycled by the HUD dial

var _board_row: HBoxContainer   # the two board halves; drives responsive slot sizing on resize
var _arena_chrome_w: float = 0.0   # side margins + left rail + action column + separations —
									# the fixed width around the board, _resize_board's width basis

var _hand: Hand
var _board: CombatBoard
var _animator: CombatAnimator
var _spell_caster: SpellCaster
var _vfx: VFXPlayer
var _interaction: Interaction   # THE owner of the current player gesture (see Interaction)
var _ctx: CombatContext         # the declared surface cards consult — installed in _ready


# While a melee attacker is lunging, its real card is concealed and a ghost duplicate does the
# travelling. That mapping is DECLARED STATE, not combat's private bookkeeping — it lives in
# CombatContext.stand_in_for, because two different readers consult it: the VFX layer (so the
# attacker's own glints play on the card the player is watching) and the concealed card itself
# (which hides on its own derivation). See CombatContext's stand-in section.
# Units currently IN MOTION across the board, CardInstance -> the tween carrying them. A unit in
# flight is not a valid stage for a cue about it: every combat number and glint stamps its position
# once, at spawn, onto the combat root — so a badge glint on a moving card is left behind the moment
# it appears — and the card-level reactions (the grey drain's tremble, the dodge sidestep) tween the
# very `position` the move is already driving, so the two fight and the loser snaps.
#
# The presentation layer therefore SETTLES a unit before cueing on it (see _await_settled, lent to
# VFXPlayer at setup). This is a presentation gate only: the Resolver wrote the mutation long before
# any of this draws, so waiting changes what the player SEES, never what resolved or in what order.
# One rule, no per-effect authoring — an on-attack self-buff, a retaliation striking the attacker
# mid-withdrawal, and anything authored later all read correctly by construction.
var _transit: Dictionary = {}   # CardInstance -> Tween


# Combat shows NO Shell header at all — every vertical pixel goes to the board and hand so the
# cards read bigger (the whole point on mobile). Run info the header carried is redundant here
# (King HP lives on the King's card; Gold/EXP don't matter mid-fight); relics move to the vertical
# strip on the left edge (_build_relic_strip); the debug end-combat ✕ moves into the action
# column. OS-back stays inert — there's no fleeing a fight.
func get_chrome() -> Dictionary:
	return {"show_header": false, "back": Callable()}


func _ready() -> void:
	_battle_speed = 1.0                  # every fight starts at 100%
	Engine.time_scale = _battle_speed

	_player_side  = CombatSide.make(0)
	_enemy_side   = CombatSide.make(1)
	_hand         = Hand.new()
	_board        = CombatBoard.new()
	_animator     = CombatAnimator.new()
	_spell_caster = SpellCaster.new()
	_vfx          = VFXPlayer.new()
	_interaction  = Interaction.new()
	add_child(_hand)
	add_child(_board)
	add_child(_animator)
	add_child(_spell_caster)
	add_child(_vfx)
	add_child(_interaction)

	# The declared-state surface cards consult (selection / inspection / preview world) —
	# see CombatContext + CardUI.derive_presentation. Cleared in _exit_tree.
	_ctx = CombatContext.install(_hand, _board, _interaction, _player_side)

	_board.setup_grids()
	_board.interaction  = _interaction   # before _build_ui — build_section hands it to every slot
	_board.player_side  = _player_side
	_board.enemy_side   = _enemy_side
	_board.is_hand_card = func(cu: CardUI) -> bool: return _hand.contains(cu)
	_board.get_mana     = func() -> int:            return _player_side.mana

	var _get_card_ui: Callable = func(inst: CardInstance) -> CardUI:
		var stand_in := _ctx.stand_in_for(inst)
		return stand_in if stand_in != null else _board.get_card_ui(inst)
	_vfx.setup(self, _get_card_ui)
	_vfx.await_settled = _await_settled
	# Relic-owned interception cues glint the tray chip; the tray lives in combat's chrome,
	# so combat lends the presenter this one reach into it.
	_vfx.relic_glint = func(relic_id: String) -> void:
		if _relic_tray != null:
			_relic_tray.glint(relic_id)
	_animator.setup(self, _get_card_ui, _vfx)
	# The cascade's injected presentation surface (see CombatPresenter): the live fight
	# animates; a simulation would hand the same cascade the null base class instead. The
	# tray is fetched through a Callable because it is built after this wiring block.
	_presenter = LivePresenter.make(_animator, get_tree(), _board,
			func() -> RelicTray: return _relic_tray, _king_fall, _fade_out)
	# The live WORLD: the one cohesive context the rules read (COMBAT_DECOUPLING_REFACTOR.md).
	# Its grids ARE the board's grid arrays — one state, two vantage points — and the board
	# gets the world back for the state halves it forwards (retire, contexts, enumeration).
	_world = CombatWorld.new()
	_world.player_grid = _board.player_grid
	_world.enemy_grid = _board.enemy_grid
	_world.player_side = _player_side
	_world.enemy_side = _enemy_side
	_world.modifiers = GameData.current_modifiers
	_world.rewards_live = GameData.current_run != null   # the old _rewards_live() predicate
	_world.view_board = _board
	_board.world = _world
	_cascade = CombatCascade.make(_world, _presenter)

	_spell_caster.setup(_board, _animator, func() -> int: return _player_side.mana, _interaction)
	_hand.bind_side(_player_side)
	_player_side.mana_changed.connect(_refresh_mana)
	# Mana changing shifts which abilities are affordable, so re-derive the Inspect Abilities glow
	# (spending on a hand spell can leave nothing usable; a refill can revive it). Glow only — the
	# inspect tray can't be open while hand spells cast, and ability casts rebuild it themselves.
	_player_side.mana_changed.connect(_hand.refresh_nav)
	# Mana also gates which hand cards are affordable — re-derive their play-me glow / 3% dim.
	_player_side.mana_changed.connect(_hand.refresh_playable)
	_hand.wire_spell_card = _spell_caster.wire_spell_card
	_hand.wire_unit_card = _board.wire_unit_card   # hand-unit drags light the board's place cues
	_hand.selection_changed.connect(_on_hand_selection_changed)
	_hand.token_hovered.connect(_highlight_building)
	_hand.inspect_changed.connect(_on_inspect_changed)
	_hand.autocast_changed.connect(_on_autocast_changed)
	# Feeds the hand's level-2 Abilities view: the fielded player units whose abilities are
	# currently offerable (same rule as CardUI's amber ability cue).
	# Every fielded player unit that HAS an activated ability — payable this moment or not. The
	# inspect tray shows the full roster (unpayable ones greyed), so this gate is "has an ability
	# to inspect", not "can act"; usable_glow below is what tracks payability.
	_hand.get_ability_units = func() -> Array:
		var out: Array = []
		for r in BoardData.ROWS:
			for c in BoardData.COLS:
				var inst: CardInstance = _board.player_grid[r][c]
				if inst != null and not inst.ability_list().is_empty():
					out.append(inst)
		return out

	# Whether an ability is castable RIGHT NOW — THE rule lives on AbilityData (usable_by), so the
	# Inspect Abilities glow here, the tray widget's own derivation and the cast gate all read one
	# definition and can never drift apart.
	_hand.is_ability_usable = func(holder: CardInstance, ab: AbilityData) -> bool:
		return ab.usable_by(holder, _player_side.mana)

	# Combat's own designed looks, registered as library entries like every other: the call
	# sites name an id and every number in them stays tunable in data/vfx/vfx.json.
	Vfx.register_custom("coin_flight", CoinFlightFx.play)
	Vfx.register_custom("king_fall", KingFallFx.play)
	Vfx.register_custom("reward_orb", RewardOrbFx.play)

	_board.can_autocast = _spell_caster.autocast_drop_ok
	# Every death, from any cause, pays its bounty through this one wire (see
	# CombatWorld.unit_retired — a world copy has no subscribers, so simulated deaths
	# structurally cannot pay).
	_world.unit_retired.connect(_pay_bounty)
	_board.unit_placed.connect(_on_board_unit_placed)
	_board.slot_pressed.connect(_on_board_slot_pressed)
	_board.autocast_dropped.connect(_on_autocast_dropped)
	# Order matters: the orchestrator's gating runs FIRST (a modal session locking placement
	# input resets cues via set_open_hints), THEN the board paints the action's cues over the
	# freshly-reset board.
	_interaction.changed.connect(_on_interaction_changed)
	# The board renders the LIVE session, not the event's payload. The handler above may BEGIN
	# a follow-up action inside this very emission (the end-of-action re-derive: a no-op drag
	# ends, the still-picked unit's static action begins right back) — the nested emission has
	# already painted that action, and this outer, now-stale event must render the same living
	# action again rather than stomp it with its own null. Pulling current() makes every
	# emission converge on the truth, whatever order the emissions unwind in.
	_interaction.changed.connect(func(_action: Interaction.Action) -> void:
		_board.present(_interaction.current()))
	_spell_caster.spell_consumed.connect(_on_spell_consumed)
	_spell_caster.ability_autocast.connect(_on_ability_autocast)

	# A practice bout runs the REAL economy and rolls it back on the way out (see _rewards_live):
	# the snapshot is taken before a single coin can be paid.
	if GameData.current_encounter != null and GameData.current_encounter.practice \
			and GameData.current_run != null:
		_practice_gold = GameData.current_run.gold
	_init_player_deck(GameData.current_run.deck)
	_init_enemy_deck()
	_build_ui()
	var enemy_king_id := "king"
	var enemy_power := 0.0
	if GameData.current_encounter != null and not GameData.current_encounter.enemy_king.is_empty():
		enemy_king_id = GameData.current_encounter.enemy_king
		enemy_power   = GameData.current_encounter.power
	_board.place_kings(
		GameData.current_run.king_id if GameData.current_run != null else "king",
		enemy_king_id, enemy_power)
	_apply_king_persistence()
	# The opening hand: a system-channel draw on the side (single-writer rule — every side
	# write rides submit, so even opening draws are interceptable by channel-aware effects).
	Resolver.submit(StatMutation.make(_player_side, StatMutation.DRAW,
			GameData.value("hand.size.initial"), null, StatMutation.CH_SYSTEM))
	var is_boss_fight := GameData.current_encounter != null \
			and GameData.current_encounter.type == EncounterData.Type.BOSS
	var is_elite_fight := GameData.current_encounter != null \
			and GameData.current_encounter.type == EncounterData.Type.ELITE
	Sfx.play("combat_boss_intro" if is_boss_fight else "combat_start")
	Sfx.music("music_boss" if is_boss_fight else ("music_elite" if is_elite_fight else "music_combat"))
	Sfx.ambience("amb_combat_battlefield")
	_refresh()
	_begin_round()


# Combat owns the global time_scale only while it's on screen — always restore real-time on the
# way out (win, loss, or back) so menus/map/other scenes are never left running fast.
func _exit_tree() -> void:
	Engine.time_scale = 1.0
	CombatContext.clear()   # card derivations no-op outside combat


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			if _interaction.modal_active():
				# Aiming session: right-click is its cancel.
				_interaction.end_action()
				get_viewport().set_input_as_handled()
			elif not get_viewport().gui_is_dragging() and not _click_engages(true):
				# The universal back-out: a right-click that does NOT itself engage anything
				# (a card's details view, an ability token's autocast toggle) clears the
				# selection, the inspection, and whatever selection action was live.
				_hand.dismiss_to_hand()
				_interaction.end_action()
				get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_maybe_dismiss_hand_view(mb.position)


# Whether a click at the cursor's position ENGAGES an interactive control rather than landing
# on dead panel/background space — walked up from the GUI's actual hovered control, so it
# needs no registry of rects. Left clicks engage cards, buttons and scrollbars; right clicks
# only cards (the details view / autocast toggle — buttons don't respond to right-click).
func _click_engages(right_click: bool = false) -> bool:
	var c := get_viewport().gui_get_hovered_control()
	while c != null:
		if c is CardUI:
			return true
		if not right_click and (c is BaseButton or c is ScrollBar):
			return true
		c = c.get_parent() as Control   # a non-Control ancestor ends the walk
	return false


# THE non-interactive-click rule: a click that engages nothing clears the CARD pick (the ability
# sub-pick and the panel go with it, by derivation) — at any nav level, aiming or not. What
# "engages" means, walked in order below: a click that will commit the live action; a slot with a
# unit on it (its own press names the new pick — naming it is all that switching takes, so the
# same unit re-picked is a no-op rather than a clear/re-pick round-trip); anything interactive
# under the cursor (card, button, scrollbar). An EMPTY slot engages nothing — it is board-shaped
# dead space, exactly the "click on nothing" this exists to catch.
#
# A geometric test in _input, NOT _unhandled_input: background panels/gauges consume clicks they
# do nothing with (STOP mouse filters), so unhandled-input never fires over most of the screen.
# Fires on RELEASE (where slots/cards act); skipped mid-drag (a failed drop must not also close
# the view).
func _maybe_dismiss_hand_view(point: Vector2) -> void:
	if get_viewport().gui_is_dragging():
		return
	var slot := _board.slot_at_mouse()
	# A click that will COMMIT the live action is not a click on nothing: clicking a landing spot
	# while a hand card is selected must engage the placement, not dismiss it (this _input runs
	# BEFORE GUI delivery — clearing here would leave the slot press nothing to commit). Only for
	# actions that accept click commits: a drag-only destination cue (repositioning) eats no taps.
	if _interaction.active() and slot != null and _interaction.current().click_commit:
		var role := _interaction.role_of(slot)
		if role == Interaction.Role.DESTINATION or role == Interaction.Role.TARGET_VALID:
			return
	if slot != null and slot.get_card() != null:
		return   # an occupied slot's press names the new pick itself
	if _interaction.modal_active():
		# An aiming session owns presses ON slots: an invalid pick stays in the session
		# (handle_slot_press) rather than reading as a dismissal.
		if slot != null:
			return
		# Clicking the thing being AIMED again means "never mind the aim" — the same one-level
		# back-out as pressing a picked hand card again (Hand._toggle_select). Tested by RECT, not
		# by _click_engages: the modal lock mouse-IGNOREs the hand's cards and tokens
		# (set_input_enabled), so the aimed token can't answer for itself while aiming.
		var src := _interaction.current().source
		if src != null and is_instance_valid(src) and src.get_global_rect().has_point(point):
			_interaction.end_action()
			return
		if _click_engages():
			return
		# A click on NOTHING while aiming clears the CARD pick like any other click on nothing;
		# the aim — riding a pick that no longer exists — ends with it, not before it.
		_hand.dismiss_to_hand()
		_interaction.end_action()
		return
	if _click_engages():
		return   # the control under the cursor acts on its own behalf, whatever the level
	_hand.dismiss_to_hand()


# ── Deck construction (each side's draw pile; draws themselves ride the Resolver) ──

# Builds the player's draw pile from the run deck (shuffled DeckCard instances). Kings
# never ride the pile; fresh units fill to their run-resolved max health.
func _init_player_deck(deck_cards: Array) -> void:
	var cards := deck_cards.duplicate()
	cards.shuffle()
	for dc: DeckCard in cards:
		var inst := dc.make_instance()
		if inst != null and not inst.data.is_king:
			inst.owner = 0
			# Fill to the run-resolved max (read-time card modifiers add to max_health once
			# owner is set), so a fresh unit enters at full HP including any unit.health buff.
			Resolver.fill_health(inst)
			_player_side.draw_pile.append(inst)


# Builds the enemy draw pile (spells included now — the AI casts them) and deals an
# opening hand. The CPU then draws one card per round like the player, so it keeps
# applying pressure all match instead of emptying its hand early.
func _init_enemy_deck() -> void:
	var ids: Array = []
	if GameData.current_encounter != null:
		ids = GameData.current_encounter.enemy_deck.duplicate()
	else:
		ids = ["strike", "strike", "strike", "defender", "defender", "swift", "warrior", "archer"]
	var power: float = GameData.current_encounter.power if GameData.current_encounter != null else 0.0
	ids.shuffle()
	for id in ids:
		var data := CardData.scaled(CardData.get_card(id), power)
		if data and not data.is_king:
			var inst := CardInstance.from_data(data)
			inst.owner = 1
			_enemy_side.draw_pile.append(inst)
	Resolver.submit(StatMutation.make(_enemy_side, StatMutation.DRAW, 4,
			null, StatMutation.CH_SYSTEM))


# Paying a card/ability cost: a COST-channel mana mutation — its own provenance so a
# "mana gains doubled" interceptor can never touch spending. Legality (can afford) is
# checked at the call sites / by the AI planner, as before.
func _pay_mana(side: CombatSide, cost: int) -> void:
	Resolver.submit(StatMutation.make(side, StatMutation.MANA, -cost,
			null, StatMutation.CH_COST))


# ── Round flow ─────────────────────────────────────────────────────────────────

func _begin_round() -> void:
	_turn      += 1
	# Every number resolves through GameData.value: the player gets the upgraded values, the
	# enemy reads the raw registry defaults so player upgrades never buff the CPU.
	# The ramp is UNCAPPED by design — mana keeps growing every turn, the whole fight, for both
	# sides (turn-1 start is mana.initial); mana.per_turn is a flat bonus stacked on top.
	var ramp := GameData.value("mana.initial") if _turn == 1 else _turn
	Resolver.set_side_max_mana(_player_side, ramp + GameData.value("mana.per_turn"))
	Resolver.set_side_mana(_player_side, _player_side.max_mana)
	Resolver.set_side_max_mana(_enemy_side, _turn)
	Resolver.set_side_mana(_enemy_side, _turn)
	# Turn draws are DRAW mutations on each side (system channel), so "your draws are
	# doubled" interceptors catch them like any effect-driven draw.
	Resolver.submit(StatMutation.make(_player_side, StatMutation.DRAW,
			GameData.value("draw.per_turn"), null, StatMutation.CH_SYSTEM))
	Resolver.submit(StatMutation.make(_enemy_side, StatMutation.DRAW, 1,
			null, StatMutation.CH_SYSTEM))
	# Fresh taps BEFORE the CPU turn: the enemy engine plans ability activations against
	# attack_exhausted, so last round's spent attacks must be cleared by the time it
	# captures the board — and a tap the CPU pays must survive into this round's combat
	# (resetting after its turn silently refunded it).
	_reset_exhaustion()
	await _do_cpu_placement()
	Sfx.play("combat_turn_start")
	Vfx.play("mana_refill_surge", _mana_chunks_box)   # the gauge blooms as it refills
	_phase = Phase.PLAYER_PLACE
	_board.placement_enabled = true
	_set_placement_input(true)
	_refresh()


func _do_cpu_placement() -> void:
	_phase = Phase.CPU_PLACE
	_board.placement_enabled = false
	_set_placement_input(false)
	_refresh_done_btn()

	# The enemy engine plans the whole CPU turn (see ENCOUNTER_ENGINE_DESIGN.md); the old
	# EnemyAI placeholder is no longer consulted. All four action kinds are planned:
	# placements, moves, spell casts and ability activations (the latter two only when
	# SimEffects can evaluate them — see the legality gate in CandidateMoves).
	var engine := EnemyEngine.new()
	if GameData.current_encounter != null:
		engine.weight_overrides = GameData.current_encounter.survival_weights
	for action: Dictionary in engine.decide_actions(_enemy_side.hand,
			_board.player_grid, _board.enemy_grid, _enemy_side.mana, _player_side.mana):
		await _execute_enemy_action(action)


# Carries out one planned CPU action. The AI guarantees each is legal in sequence
# (mana + slot occupancy), so this just applies the effect and animates it.
func _execute_enemy_action(action: Dictionary) -> void:
	match action["type"]:
		EnemyEngine.Action.PLACE:
			var inst: CardInstance = action["inst"]
			_pay_mana(_enemy_side, inst.data.cost)
			_enemy_side.remove_from_hand(inst)
			var results := _board.place_enemy_card(inst, action["row"], action["col"])
			Sfx.play("combat_enemy_place")
			_vfx.play(VFXEvent.card_placed(_board.get_card_ui(inst)))
			await _animator.show_effect_results(results, inst)
		EnemyEngine.Action.CAST:
			var inst: CardInstance = action["inst"]
			_pay_mana(_enemy_side, inst.data.cost)
			_enemy_side.remove_from_hand(inst)
			await _show_enemy_spell(inst, action["target"])
		EnemyEngine.Action.GENERATE:
			# An enemy unit activates an ability. Pay the cost (mana + tap if the ability
			# carries it), then resolve per v1 policy: a material ability always takes its
			# SPAWN half onto the planned slot (functionally the old unit generation; merge
			# smarts later); any other ability casts at the AI-picked target.
			var holder: CardInstance = action["unit"]
			var ab: AbilityData = action["ability"]
			_pay_mana(_enemy_side, ab.mana)
			if ab.tap:
				holder.attack_exhausted = true   # the fact; the card derives its grey from it
				var b_ui := _board.get_card_ui(holder)
				if b_ui != null:
					b_ui.derive_presentation()   # re-check cue — instant instead of a poll beat
			if not ab.material.is_empty():
				var mat := CardData.get_card(ab.material)
				var m_inst := CardInstance.from_data(mat)
				var m_results := _board.place_enemy_card(m_inst, action["row"], action["col"])
				# A conjured unit MATERIALIZES (distinct from a card landing from a hand).
				Vfx.play("summon_materialize", _board.get_card_ui(m_inst))
				await _animator.show_effect_results(m_results, m_inst)
			else:
				# Present via the card-shaped ability view, like an enemy spell cast. source_building
				# + ability mirror the player's ability tokens (see Hand._rebuild_inspect_view) so
				# _cast_enemy_spell resolves the holder as the effect source (glint included).
				var display := CardInstance.from_data(ab.display_card())
				display.owner = 1
				display.source_building = holder
				display.ability = ab
				var spell_target: CardInstance = action.get("target", null)
				await _show_enemy_spell(display, spell_target)
		EnemyEngine.Action.MOVE:
			_board.move_enemy_card(action["inst"], action["row"], action["col"])
			Vfx.play("unit_move_dash", _board.get_card_ui(action["inst"]))
	await get_tree().create_timer(0.35).timeout


# Makes a CPU spell legible: the enemy has no visible hand, so a cast would otherwise
# land as unexplained damage during the CPU phase. We pop the spell card up, name it,
# fly it into its target, THEN resolve the effect (which plays the on-target VFX).
const _ENEMY_SPELL_HOLD := 0.55

func _show_enemy_spell(inst: CardInstance, target: CardInstance) -> void:
	var card := CardUI.create(inst)
	card.custom_minimum_size = Vector2(150, 200)
	card.z_index      = 40
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(card)
	var origin := Vector2(size.x * 0.5 - 75.0, size.y * 0.28)
	card.global_position = origin

	var banner := Label.new()
	banner.text = Loc.t("combat.enemy_casts", {"name": inst.data.display_name})
	banner.add_theme_font_size_override("font_size", 22)
	banner.modulate         = Color(1.0, 0.55, 0.3)
	banner.z_index          = 40
	banner.mouse_filter     = Control.MOUSE_FILTER_IGNORE
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(banner)
	banner.global_position = Vector2(size.x * 0.5 - 150.0, origin.y - 44.0)
	banner.custom_minimum_size.x = 300.0

	Sfx.play("spell_cast")   # the enemy's cast sounds like the player's
	# Pop in, then hold so the player can read what was cast.
	card.scale = Vector2(0.5, 0.5)
	var pop := create_tween()
	pop.set_trans(Tween.TRANS_BACK); pop.set_ease(Tween.EASE_OUT)
	pop.tween_property(card, "scale", Vector2.ONE, 0.18)
	await pop.finished
	await get_tree().create_timer(_ENEMY_SPELL_HOLD).timeout
	banner.queue_free()

	# Single-target spells fly into the victim; area spells just resolve in place.
	if target != null:
		var t_ui := _board.get_card_ui(target)
		if t_ui != null:
			var fly := create_tween()
			fly.set_trans(Tween.TRANS_QUAD); fly.set_ease(Tween.EASE_IN)
			fly.tween_property(card, "global_position", t_ui.global_position, 0.22)
			await fly.finished

	await _cast_enemy_spell(inst, target)
	await get_tree().create_timer(0.25).timeout
	card.queue_free()


# Applies an enemy spell's ON_PLAY effects against the AI-chosen target (mirrors
# SpellCaster._execute_spell, minus the player-facing targeting UI).
func _cast_enemy_spell(inst: CardInstance, target: CardInstance) -> void:
	# An ability's display card acts AS its holder — same resolution as SpellCaster._execute_spell.
	var src := inst
	if inst.ability != null and inst.source_building != null:
		src = inst.source_building
	for effect: Effect in inst.data.effects:
		if effect.trigger != Effect.Trigger.ON_PLAY:
			continue
		var ctx := _board.make_context(src)
		ctx.manual_target = target
		await _animator.show_effect_results(EffectSystem.apply_single(effect, src, ctx), src)
		_board.cleanup_effect_deaths()
	_board.refresh()


# ── Rook / building card generation ──────────────────────────────────────────────

# At the start of each round every unit can attack again; un-dim any building
# that spent its attack generating a card last round.
func _reset_exhaustion() -> void:
	for inst: CardInstance in _board.get_all_units():
		inst.attack_exhausted = false   # the fact; cards derive their grey from it
	_board.derive_cards()   # re-check cue for the whole board


# Toggles the gold targeting glow on a building's board slot, used to point out
# which rook a hovered/selected token belongs to.
func _highlight_building(inst: CardInstance, on: bool) -> void:
	if inst == null or inst.owner != 0 or inst.row < 0 or inst.col < 0:
		return
	(_board.player_slots[inst.row][inst.col] as SlotUI).set_targetable(on)


# The inspection DECLARATION changed (Hand._inspected is the fact; board cards derive their
# cyan highlight from it — no tracked "_inspected_ui" to remember and un-push).
func _on_inspect_changed(inst: CardInstance) -> void:
	if inst == null:
		# Inspection ended (a unit was DESELECTED). The static selection cues were raised by a
		# click-session action (see _on_board_slot_pressed) — end it and the board resets
		# structurally. Never touches a modal aiming session or a live drag (those own the board).
		if _interaction.active() and not _interaction.current().modal \
				and not _interaction.current().is_drag:
			_interaction.end_action()
	_refresh_card_presentation()   # re-check cue for the new declaration


func _on_done_pressed() -> void:
	_hand.dismiss_to_hand()
	_phase = Phase.COMBAT
	_board.placement_enabled = false
	_set_placement_input(false)
	_refresh()
	await _resolve_event(&"turn_start")
	if _board.any_king_dead():
		_handle_combat_end()
		return
	await _run_combat()
	if _board.any_king_dead():
		_handle_combat_end()
		return
	await _resolve_event(&"turn_end")
	if _board.any_king_dead():
		_handle_combat_end()
		return
	await get_tree().create_timer(0.8).timeout
	var any_shield_regen := false
	for inst: CardInstance in _board.get_all_units():
		var prev_shield := inst.current_shield
		Resolver.restore_shield(inst)
		var gained := inst.current_shield - prev_shield
		if gained > 0:
			any_shield_regen = true
			var shield_ui := _board.get_card_ui(inst)
			if shield_ui != null:
				shield_ui.refresh()   # show the restored shield badge as the glint points at it
				_vfx.play(VFXEvent.shield_restored(shield_ui, gained))
	if any_shield_regen:
		Sfx.play("shield_regen")   # ONE sound for the whole board's regen, not one per unit
	_board.refresh()
	await _begin_round()


# ── Combat resolution ──────────────────────────────────────────────────────────

func _run_combat() -> void:
	var all_cards := _board.get_all_units()
	all_cards.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		var sa := a.get_attribute("speed")
		var sb := b.get_attribute("speed")
		if sa != sb:
			return sa > sb
		if a.owner != b.owner:
			return a.owner < b.owner
		var pa: int = a.col if a.owner == 0 else BoardData.COLS - 1 - a.col
		var pb: int = b.col if b.owner == 0 else BoardData.COLS - 1 - b.col
		if pa != pb:
			return pa > pb
		return a.row > b.row
	)

	for attacker: CardInstance in all_cards:
		if not attacker.is_alive():
			continue
		# The unit's turn has come up: broadcast its ON_ACTIVATE moment (subject = this unit). Its own
		# effects proc (e.g. poison) then its statuses decay. This can kill it before it acts, so
		# re-check life before its attack.
		await _resolve_event(&"activate", attacker)
		if not attacker.is_alive():
			continue
		# A building that spent its attack generating a card sits this round out.
		if attacker.attack_exhausted:
			continue
		await _resolve_attack(attacker)


# Plays out a single attacker's turn: `strikes` full strike sequences (base 1 — the
# multi-strike stat; standing effects can add more). Each strike re-acquires its target,
# so a slain victim doesn't soak the follow-ups; the attacker dying mid-flurry (retaliation,
# a deathrattle) or a king falling ends the flurry immediately.
func _resolve_attack(attacker: CardInstance) -> void:
	var strikes := attacker.get_attribute("strikes")
	for _i in strikes:
		# A re-entrant effect from an earlier strike (an on-death/on-attack trigger) can pull the
		# attacker OFF the board without killing it (a bounce, push, or relocation leaves health > 0),
		# so "still alive" isn't enough — it must still hold a slot to swing from.
		if not attacker.is_alive() or attacker.attack_exhausted or _board.get_card_ui(attacker) == null:
			break
		var target := _board.find_target(attacker)
		if target == null:
			break
		await _perform_strike(attacker, target)
		if _board.any_king_dead():
			break


# One full strike sequence against an acquired target: delivery (melee lunge or ranged
# bolt), damage + triggered effects, and the target's death or survival.
func _perform_strike(attacker: CardInstance, target: CardInstance) -> void:
	var a_card := _board.get_card_ui(attacker)
	var t_card := _board.get_card_ui(target)
	# Either combatant can be yanked off the board between target acquisition and impact by a
	# re-entrant effect (an on-death trigger from a prior strike bouncing/relocating a live unit,
	# or a spawn reshuffle). With no slot to read a global_position from, there is nothing to swing:
	# skip this strike rather than crash. The flurry's own liveness re-check ends the sequence next.
	if a_card == null or t_card == null:
		return

	if attacker.data.ranged:
		# Ranged: hold position and fire a bolt; the hit lands when it arrives. The bolt
		# carries the attacker's composition so the library can fly its element-variant look.
		var shot := VFXEvent.projectile(
			a_card, t_card, attacker.get_attribute("attack"),
			Color(0.65, 0.9, 1.0), VFXEvent.Projectile.BOLT, false)
		shot.composition = attacker.data.elements
		await _vfx.play(shot)
		await _apply_attack_damage(attacker, target, t_card)
	else:
		# Melee: lunge across and plunge INTO the target (overlapping from the side it approaches —
		# player units from the target's left, enemy units from its right), bounce back out to the
		# attack position beside it, and LEAVE — the strike's damage + triggered effects (numbers,
		# glints, the target's death) all play out while the attacker is already gliding home. The
		# lunge and rebound chain with no pause at the overshoot, so the hit keeps its momentum on
		# impact, and the withdrawal keeps that same momentum instead of parking the attacker beside
		# its victim to watch it suffer. One continuous move-hit-leave, with the consequences
		# unfolding underneath it.
		var a_home := a_card.global_position
		var gap := 12.0
		var beside_x: float = (t_card.global_position.x - a_card.size.x - gap) if attacker.owner == 0 \
			else (t_card.global_position.x + t_card.size.x + gap)
		var beside := Vector2(beside_x, t_card.global_position.y)
		# Overshoot PAST the attack position along the approach line (beside, pushed further from
		# home), so the rebound retraces the exact vector the lunge came in on — a real recoil off the
		# hit, not a step to the side.
		var overshoot := beside + (beside - a_home).normalized() * (a_card.size.x * 0.3)
		# A unit must be standing still before it can start another move. Without this, the second
		# swing of a multi-strike flurry spawns a ghost while the first is still gliding home, and
		# the two fight over the attacker's card.
		await _await_settled(attacker)
		var ghost := _animator.spawn_ghost(a_card)
		# Declaring the stand-in IS the hide: the original card consults this on its next derivation
		# and conceals itself, and the attacker's own VFX routes onto the ghost (see CombatContext).
		# The re-derive that follows is a "re-check now" cue carrying no verdict — the card still
		# decides for itself — but it makes the concealment land on THIS frame rather than whenever
		# the 0.75s presentation poll next comes round, which is what keeps the swap seamless.
		_ctx.declare_stand_in(attacker, ghost)
		a_card.derive_presentation()
		Vfx.play("attack_swing_arc", ghost)   # the swing reads over the lunge, concurrent
		await _animator.play_lunge(ghost, overshoot)
		_animator.shake_card(t_card)               # impact shake at the apex, over the rebound
		await _animator.play_rebound(ghost, beside)
		# The withdrawal and the consequences run CONCURRENTLY: the retreat starts on the rebound's
		# heel while the damage, its numbers and every triggered glint resolve underneath it.
		var retreat := _animator.start_retreat(ghost, a_home)
		_transit[attacker] = retreat
		# MOVEMENT IS A BEAT: the withdrawal hands off through the same `vfx.overlap` dial as every
		# cue, so it obeys the player's pacing setting instead of being unconditionally concurrent.
		# At Flowing the next unit winds up while this one is still gliding; at Step by step the
		# handoff equals the full span, so the attacker is home before anything else begins. The
		# timer starts WITH the retreat and is awaited at the end of the strike — the damage
		# resolving usually outlasts it, in which case there is nothing left to wait for.
		var withdraw := get_tree().create_timer(Vfx.handoff(CombatAnimator.RETREAT_DUR))
		# Teardown rides the tween's own completion rather than the await chain, so the ghost is
		# never freed early no matter how the handoff and the damage race.
		retreat.finished.connect(func() -> void:
			_transit.erase(attacker)
			# Withdrawing the stand-in is the whole of un-hiding: the card re-derives and finds
			# itself on screen again, wearing whatever it should be wearing NOW — an exhaust grey it
			# earned by swinging, a threat glow the exchange just changed — instead of the opacity
			# it happened to have when it left.
			_ctx.clear_stand_in(attacker)
			if is_instance_valid(ghost):
				ghost.queue_free()
			if is_instance_valid(a_card):
				a_card.derive_presentation())
		await _apply_attack_damage(attacker, target, t_card)
		if withdraw.time_left > 0.0:
			await withdraw.timeout

	if not target.is_alive():
		await _emit_kill(target)
		await _broadcast(GameEvent.make(&"death", target))
		await _bury(target)   # the death BEAT; the fade itself plays on past it
	else:
		# No trailing beat: the strike's own damage cues were awaited to their handoffs above and
		# are still playing. The next attacker winds up under them rather than after them.
		t_card.refresh()

	# A triggered/run-level effect resolved during this attack (e.g. an upgrade's on-death
	# retaliation) may have killed a bystander; sweep any secondary deaths off the board.
	_board.cleanup_effect_deaths()


# A unit LEAVES PLAY the instant it dies — slot free, targeting blind to it, sequence carrying
# straight on — and its card then fades in place, owing nothing to anyone. Death used to be a hard
# 0.4s stop mid-combat purely because board state and card disposal were one operation
# (CombatBoard.remove_card), so the only way to keep the card visible was to delay the state change.
# Splitting the two removes the stall without moving a single node.
#
# Deliberately NOT awaited by its callers (it is a coroutine only so it can dispose of the card when
# the fade ends). The single death-presentation path — every site that used to hand-roll
# "await the death VFX, then remove_card" now calls this.
func _bury(inst: CardInstance) -> void:
	await _cascade.bury(inst)


# ── Kill bounties: what a fallen enemy pays, the moment it falls ───────────────────
#
# A fight no longer pays only at the end. Every enemy that dies hands over gold and experience
# on the spot (GameData.kill_bounty owns the numbers; nothing here knows the rates), and the two
# halves are cued differently ON PURPOSE:
#
#   GOLD  is loud — one coin per gold flies out of the corpse and into the bag on the left rail,
#         so the amount is a countable thing crossing the screen.
#   EXP   is quiet — no number, no coin; the narrow gauge beside the strip just grows.
#
# Gold lands in the run's purse immediately (it is spendable the moment the fight ends); the
# experience is HELD and banked once at combat end, because every grant writes the profile to
# disk and a save per corpse is a save too many. The gauge shows the running total meanwhile.
var _pending_exp: int = 0
var _paid: Dictionary = {}   # instance id -> true; a corpse pays exactly once, whichever
							  # removal path retires it


# Whether this fight pays at all: it needs a run to pay INTO, and that is the whole test.
#
# A practice bout in the Combat Gym still leaves no footprint — but that promise is kept where it
# belongs, at the EXIT (see _handle_combat_end / _practice_gold), not by suppressing the payment
# everywhere it happens. Practice used to fail this predicate, which switched off the coins, the
# gauge and the chest as a side effect: the one place in the game built for testing a fight was
# the one place its payment cues never played. A rehearsal that skips the payment isn't a
# rehearsal of the fight.
func _rewards_live() -> bool:
	return GameData.current_run != null


# The purse as it stood when a practice fight began, so the fight can spend and earn for real and
# still leave the run exactly where it found it. -1 = not a practice bout, nothing to restore.
var _practice_gold: int = -1


# CombatBoard.unit_retired — the one wire every death arrives on. Reads the bounty, banks the
# gold, holds the experience, and throws the coins from where the body stood.
func _pay_bounty(inst: CardInstance) -> void:
	if inst == null or inst.owner != 1 or inst.is_alive() or not _rewards_live():
		return
	var key := inst.get_instance_id()
	if _paid.has(key):
		return
	_paid[key] = true
	var bounty := GameData.kill_bounty(inst)
	var gold: int = bounty["gold"]
	var xp: int = bounty["exp"]   # not `exp` — that shadows the GDScript global
	if xp > 0:
		_pending_exp += xp   # combat holds the debt; the gauge only draws it
		if _exp_gauge != null:
			_exp_gauge.add_exp(xp)
	if gold <= 0 or _gold_bag == null:
		return
	# The bag is told coins are coming BEFORE the purse moves: it mirrors RunData whenever
	# nothing is in flight, so granting first would snap its number to the total and leave the
	# coins arriving at a figure that already counted them.
	_gold_bag.expect_coins(gold)
	GameData.current_run.gold += gold   # spendable at once; the coins are the RECEIPT, and the
										 # bag's own tally follows them rather than this (GoldBag)
	# Thrown from where the unit stood, not from wherever its card ends up: the card is being
	# disposed of on some paths this very frame, so the flight carries a position, not a node.
	var card := _board.get_card_ui(inst)
	var from: Vector2 = card.get_global_rect().get_center() if card != null \
			else _gold_bag.drop_point()
	Vfx.play("coin_flight", _gold_bag,
			{"origin": from, "count": gold, "on_land": _gold_bag.land_coin})


# ── The enemy King's fall ──────────────────────────────────────────────────────────

# A King's death is the fight ending, so it gets none of a unit's grim dissolve. The card swells,
# trembles, and detonates (KingFallFx owns that whole build) — and the fight's reward is thrown
# clear of the blast: a treasure chest bursting out of the explosion like a piñata and landing in
# the slot the King left empty. That chest is the fight's rewards made into an object; combat
# waits on the player opening it before the reward screen exists at all (see _handle_combat_end).
# No bounty is paid here; the chest IS the payment.
# Raised for the length of the fall, because the chest does not EXIST until the explosion has
# finished throwing it: an end-of-combat that arrives mid-fall would otherwise find no chest and
# skip the gate entirely. Every normal path awaits _bury and can't hit this, but the debug ✕ can,
# and a future caller shouldn't have to know the ordering to be correct.
var _king_falling := false
signal _chest_ready


func _king_fall(inst: CardInstance, corpse: CardUI) -> void:
	var slot_rect := corpse.get_global_rect()
	var blast := slot_rect.get_center()
	_king_falling = true
	await Vfx.play("king_fall", corpse)   # awaited IN FULL — the chest is thrown BY this
	_board.drop_card_view(inst, corpse)
	# The slot is empty and the explosion has happened: out comes the chest.
	_reward_chest = TreasureChest.pop_from(self, blast, slot_rect)
	_king_falling = false
	_chest_ready.emit()


# Debug only: fell the enemy captain on the spot, so the whole "captain defeated" sequence — the
# kill/death broadcasts, the fall, the chest and the end-of-combat gate — can be replayed without
# fighting the fight for it. Deliberately NOT a shortcut past that sequence (the debug ✕ beside it
# already is one): the lethal blow goes through the Resolver like any other, and everything after it
# is the same path a killing strike takes, so what gets polished here is the real thing.
#
# The blow is a signed SYSTEM-channel HEALTH mutation: shield-bypassing (a shielded King would
# otherwise survive a damage-form hit) and killer-less, so the death reads as "died to the engine"
# rather than crediting some unit that never swung.
var _debug_killing := false


func _debug_kill_captain() -> void:
	var king := _board.get_enemy_king()
	if _debug_killing or king == null or not king.is_alive():
		return
	_debug_killing = true
	Resolver.submit(StatMutation.make(king, StatMutation.HEALTH, -king.current_health,
			null, StatMutation.CH_SYSTEM))
	await _emit_kill(king)
	await _broadcast(GameEvent.make(&"death", king))
	await _bury(king)
	_board.cleanup_effect_deaths()
	_debug_killing = false
	# Mid-combat the resolution loop is already watching for a fallen king and will end the fight at
	# its next checkpoint — ending it here too would run the whole end sequence twice. Outside combat
	# (the placement phases, where this button is most useful) nothing else is watching, so end it.
	if _phase != Phase.COMBAT and _board.any_king_dead():
		_handle_combat_end()


# The corpse's send-off, deliberately outliving the death beat. Awaits the fade IN FULL — unlike the
# beat above — because the card is freed at the end of it.
func _fade_out(inst: CardInstance, corpse: CardUI) -> void:
	await _vfx.play(VFXEvent.death(corpse))
	_board.drop_card_view(inst, corpse)


# Blocks until `inst` is standing still, so a cue about it draws on a stage that won't move out from
# under it (see _transit). No-op for a unit that isn't travelling — which is every unit but the one
# attacker mid-withdrawal, since units act strictly one at a time.
#
# Gates on the TWEEN finishing, deliberately, NOT on the ghost being cleaned up: the ghost is freed
# after _apply_attack_damage returns, and the cues that need this gate run INSIDE it — waiting on
# the cleanup would deadlock. The tween runs on the scene clock, independent of the await chain.
func _await_settled(inst: CardInstance) -> void:
	if inst == null:
		return
	var tw: Variant = _transit.get(inst)
	if tw == null or not is_instance_valid(tw):
		return
	var tween := tw as Tween
	if not tween.is_valid() or not tween.is_running():
		return
	await tween.finished


# Applies a strike's damage at the moment of impact: ON_ATTACK trigger, the (shield-split)
# damage, ON_DAMAGE_TAKEN trigger, and the shield/health hit numbers. Attack value is read
# before ON_ATTACK fires so a self-buff on attack doesn't retroactively change this hit.
func _apply_attack_damage(attacker: CardInstance, target: CardInstance, t_card: CardUI) -> void:
	# The ON_ATTACK moment is an EVENT — it fires whether or not any damage follows (reactions
	# like on-hit poison ride it). The strike itself is just a mutation submitted to the
	# Resolver, which owns both the shield-first resolution form AND interception (Blind and
	# friends rewriting the amount inside the gate — see Effect.Kind.INTERCEPTOR). Combat never
	# learns WHY the number changed; it presents the outcome the Resolver reports.
	await _broadcast(GameEvent.make(&"attack", attacker, target))
	var outcome := Resolver.submit(
			StatMutation.damage(target, attacker.get_attribute("attack"), attacker))
	# Cue whatever intercepted (the Blind pip glint, a relic chip) BEFORE the damage readout —
	# resolution is already complete; this is pure playback in resolution order.
	await _vfx.play_interceptions(outcome.interceptions)
	var dmg := -outcome.delta
	# THE CRIT CUE IS PART OF THE BLOW, so it fires the moment the blow is known — here, not down in
	# the readout below. It used to sit with the damage numbers, on the far side of `struck`, so on
	# any strike carrying an on-hit reaction the "CRITICAL!" headline arrived after that reaction's
	# own cues had played: the hit landed, something else happened, and only then was the hit
	# announced as critical. Fired here it still overlaps the numbers (it is a long, unawaited cue
	# with a ~1s tail), but it can no longer drift away from the impact it belongs to.
	#
	# Still AFTER the interception cues, deliberately: the Resolver rolls crit only on what survives
	# interception (see Resolver._submit), so the rewriter reading first is the true causal order.
	if outcome.crit:
		# Real damage still lands — this cue sits ALONGSIDE the shield/health numbers, never
		# instead of them. The ATTACKER's Speed badge glints too (speed drives crit, mirroring how
		# a dodge glints the dodger's Speed); mid-melee its live presentation is its lunge ghost,
		# so the stand-in routing applies exactly as in _get_card_ui.
		_vfx.play(VFXEvent.crit(t_card, dmg))
		var a_ui := _ctx.stand_in_for(attacker)
		if a_ui == null:
			a_ui = _board.get_card_ui(attacker)
		if a_ui != null and is_instance_valid(a_ui):
			a_ui.flash_stat_proc("speed")
	# Resolve the attack-driven decay AFTER submit (the Resolver needs the status alive to query
	# its interceptors) and BEFORE the strike's on-hit reactions below. A charge is spent per
	# attack (hit or miss); a Blind that an effect applies in *reaction* to this attack (a relic
	# blinding the attacker on hit, via ON_DAMAGE_TAKEN) lands afterwards and survives, instead
	# of being eaten by this same attack.
	StatusEngine.advance(attacker, &"attack")

	# The strike is PERFORMED either way — even a whiff still attacks, it just deals 0. So damage
	# was applied (0 on a miss) and ON_DAMAGE_TAKEN fires regardless, so on-attacked reactions
	# (e.g. a relic blinding the attacker) run whether or not it connected. Only the readout
	# differs.
	await _broadcast(GameEvent.make(&"struck", attacker, target))
	# Each cue below is AWAITED — not to its last frame, but to its handoff, so the next beat of the
	# strike starts while it is still playing out. That await IS the pacing; there is no sleep.
	if outcome.dodged:
		# The target's speed slipped the blow outright — an ACTIVE evade (sidestep + "Dodge!"),
		# distinct from the grey whiff of a miss. Both land 0 damage; the cause differs.
		await _vfx.play(VFXEvent.dodge(t_card))
		# The `dodge` event fires after `struck` (a dodged unit was still attacked): origin = the
		# attacker whose blow was slipped, destination = the dodger. Lets "when an ally dodges…"
		# reactions run (the dodger is the subject).
		await _broadcast(GameEvent.make(&"dodge", attacker, target))
	elif dmg <= 0:
		# A 0-damage strike (blocked, or <=0 Attack) reads as "Miss" rather than a number.
		await _vfx.play(VFXEvent.miss(t_card))
	else:
		# (The crit cue itself fired at the moment of resolution above — see there for why.)
		# Shield reads FIRST: it takes the blow on its own badge (and only the badge — a held shield
		# leaves the card unwounded). When the hit also bleeds through to HP, a brief halt lets the
		# absorb land before the wound, so the shield is legible as the first thing that happened.
		# Hit sounds ride the VFX entries (combat_shield_hit/combat_health_damage carry their
		# sfx in data) — only the shield BREAK layer is contextual and fires here.
		if outcome.shield_absorbed > 0:
			if target.current_shield <= 0:
				Sfx.play("shield_break")
			# Awaited: the absorb's handoff is exactly the "shield took the blow FIRST" beat the old
			# SHIELD_LEAD sleep faked, except the badge is still visibly reacting as the wound lands.
			await _vfx.play(VFXEvent.shield_hit(t_card, outcome.shield_absorbed))
		if outcome.health_damage > 0:
			await _vfx.play(VFXEvent.health_damage(t_card, outcome.health_damage))
		if outcome.crit:
			# The `crit` event fires after the hit's cues are queued (hit → numbers → reaction
			# reads in causal order): origin = the attacker who landed it, destination = the unit
			# hit. Unlike dodge, the SUBJECT is the origin — "when I land a crit" reactions run
			# from the attacker's perspective (see GameEvent.subject).
			await _broadcast(GameEvent.make(&"crit", attacker, target))
	_board.refresh()


# (Interception playback lives in VFXPlayer.play_interceptions — the one presenter every
# path shares: the attack path plays its Outcome's records directly, and effect-path records
# ride the result dicts into play_results.)


# The cascade proper — _broadcast/_resolve_event/_fire/_fire_run_level/_emit_kill/_bury —
# lives on CombatCascade now, hosted on (_world, _presenter); these wrappers keep every
# combat call site (the attack loop, casts, the debug captain-kill) reading as before.
func _fire(event: GameEvent, holder: CardInstance) -> void:
	await _cascade.fire(event, holder)


func _fire_run_level(event: GameEvent) -> void:
	await _cascade.fire_run_level(event)


# A consumable relic's use (the tray chip's completed safety hold — see ConsumableChip): SPEND
# the relic, then cue the chip and apply the relic's transient effects anchored to the PLAYER
# (the same two-anchor read as run-level dispatch: the King is the spatial anchor, owner_anchor 0
# makes "ally"/"enemy" read from the player's side). The effects ride the same use-path as a
# spell cast (EffectSystem.apply_single + death sweep), so a consumable is authored exactly like
# transient spell effects.
#
# The discard happens FIRST, before a single await: a consumable is gone at the moment its hold
# commits, and everything after is just the telling of it. Spending at the END made the relic's
# destruction hostage to this coroutine reaching its last line — any interruption of the
# presentation (a use that ends the fight and tears the screen down mid-await, a VFX sequence
# that never drains) left a spent relic sitting in the run as a chip that can never fire again.
func _use_consumable(relic_id: String) -> void:
	if _phase != Phase.PLAYER_PLACE or _consumable_busy:
		return
	var relic := RelicData.get_relic(relic_id)
	if relic == null or GameData.current_run == null \
			or not GameData.current_run.relics.has(relic_id):
		return
	var src := _board.get_player_king()
	if src == null:
		return
	_consumable_busy = true
	GameData.current_run.discard_relic(relic_id)
	# The chip is still on screen for its own cue — it glints, and only then does the refresh
	# take it away, so the spend reads as "that relic fired and was used up".
	_relic_tray.glint(relic_id)
	await get_tree().create_timer(Vfx.handoff(LivePresenter.RELIC_CHIP_SPAN)).timeout
	_relic_tray.refresh()
	for effect: Effect in relic.effects:
		if not effect.trigger_resolver().applies_on_use():
			continue
		var ctx := _board.make_context(src)
		ctx.owner_anchor = 0   # run-scope item: "enemy" means the player's enemy, whoever acts
		ctx.board_node = _board
		var results := EffectSystem.apply_single(effect, src, ctx)
		await _animator.show_effect_results(results, src, "", false)
		_board.cleanup_effect_deaths()
	_consumable_busy = false
	# Outside COMBAT nothing else is watching for a fallen king (same reasoning as the debug
	# kill button) — if the use finished the fight, end it here.
	if _phase != Phase.COMBAT and _board.any_king_dead():
		_handle_combat_end()


func _emit_kill(corpse: CardInstance) -> void:
	await _cascade.emit_kill(corpse)


func _broadcast(event: GameEvent, run_level: bool = true) -> void:
	await _cascade.broadcast(event, run_level)


func _resolve_event(event_id: StringName, subject: CardInstance = null) -> void:
	await _cascade.resolve_event(event_id, subject)


# The player's King carries its health across the whole run, so it enters each
# fight at the run's current HP (max - accumulated damage) instead of full health.
# Current wounds are the King's own persistence axis; its MAX health (and any future
# upgrade to it) belongs in the card definition via DeckCard.override, not here.
# Shield is left alone — it refreshes per turn like every other unit.
func _apply_king_persistence() -> void:
	var run := GameData.current_run
	if run == null:
		return
	var pk := _board.get_player_king()
	if pk == null:
		return
	# Reflect any run-wide king.max_health bonus on the unit itself so its bar reads correctly
	# (the King is excluded from the blanket unit.* buffs — its HP has its own modifier axis).
	var hp_bonus := GameData.value("king.max_health")
	if hp_bonus != 0:
		Resolver.submit(StatMutation.make(pk, StatMutation.MAX_HEALTH, hp_bonus,
				null, StatMutation.CH_SYSTEM))
	Resolver.set_health(pk, run.king_health())
	_board.refresh()

	# The header's HP field mirrors RunData, which only finalizes king_damage at combat end (see
	# _handle_combat_end) — wire it to the King's LIVE board health instead, so it ticks during the
	# fight. This bypasses RunData entirely mid-fight; the persisted value still only ever gets
	# written once, at combat end, unchanged from before.
	pk.health_changed.connect(_on_king_health_changed)


# The player King in its last quarter is the run itself in peril: a heartbeat glow rides the
# card while critical, attached/detached on the threshold crossings (with one warning sting).
const KING_CRITICAL_RATIO := 0.25
var _king_critical := false

func _on_king_health_changed(current: int) -> void:
	var run := GameData.current_run
	if run != null:
		GameSignals.hp_changed.emit(current, run.king_max_health())
		var critical := current > 0 \
				and current <= int(ceil(run.king_max_health() * KING_CRITICAL_RATIO))
		if critical != _king_critical:
			_king_critical = critical
			var king_ui := _board.get_card_ui(_board.get_player_king())
			if king_ui != null:
				if critical:
					Sfx.play("combat_king_low")
					Vfx.attach("king_critical_pulse", king_ui)
				else:
					Vfx.detach("king_critical_pulse", king_ui)


func _handle_combat_end() -> void:
	var player_won := _board.player_king_alive()
	var enc := GameData.current_encounter
	Sfx.play("combat_victory" if player_won else "combat_defeat")
	# The screen-level dressing plays out BEFORE navigation (awaited — Nav.goto would cut it
	# off mid-swell); target is the whole combat screen.
	await Vfx.play("screen_victory_rays" if player_won else "screen_defeat_shroud", self)
	# The enemy King left a chest where it fell, and it is a real gate: the rewards are what is
	# inside it, so nothing is applied and no screen changes until the player opens it. (No
	# chest — a loss, or a King that died some way that left none — and this simply passes.)
	# A practice bout waits on it too: the chest is how a won fight ENDS, and the gym exists to
	# rehearse the fight, ending included.
	if player_won and _king_falling:
		await _chest_ready   # the explosion hasn't thrown it yet — see _king_fall
	if player_won and _reward_chest != null and is_instance_valid(_reward_chest):
		await _reward_chest.opened
	# A practice (Combat Gym) fight leaves no footprint: no rewards, no king-damage carry, no
	# map advance, no save, and defeat does NOT end the run — straight back to the gym. The gold
	# its kills paid was REAL while the fight ran (the coins are a receipt for a purse that
	# actually moved) and is handed straight back here; the held experience simply goes unbanked.
	if enc != null and enc.practice:
		if _practice_gold >= 0 and GameData.current_run != null:
			GameData.current_run.gold = _practice_gold   # setter re-emits gold_changed (RunData)
		_pending_exp = 0
		GameData.current_encounter = null
		Nav.goto("res://scenes/combat_gym.tscn")
		return
	# Everything the fight's kills earned in experience banks HERE, once, in a single profile
	# save — win or loss, because a unit killed in a fight that was then lost was still killed.
	# The gauge has been showing this total all along (see _pay_bounty / ExpGauge).
	if _pending_exp > 0:
		GameData.grant_experience(_pending_exp)
		_pending_exp = 0
	# One-time milestone checks fire for any real (non-practice) match completion — win OR loss.
	# The reward lands quietly here; any celebration is queued and shown at the next hub visit
	# (see Achievements / game_world), where its "visit the Lab" nudge is actually actionable.
	Achievements.record_match_completed()
	if player_won:
		# Apply the encounter's automatic rewards (gold + crafting materials) in one place,
		# uniformly for boss and normal wins. The card-pick reward is handled by reward_screen.
		GameData.apply_encounter_rewards(enc)
		# Carry the King's wounds back into the run (it survived, so health > 0).
		var run := GameData.current_run
		if run != null:
			var pk := _board.get_player_king()
			if pk != null:
				run.king_damage = maxi(0, run.king_max_health() - pk.current_health)
		if enc != null:
			enc.outcome = EncounterData.Outcome.WIN
			# Advance map state now that the battle is won.
			var state := GameData.current_map_state
			if state != null:
				if enc.completing_node_id >= 0 \
						and enc.completing_node_id not in state.visited_nodes:
					state.visited_nodes.append(enc.completing_node_id)
				if enc.destination_node_id >= 0:
					state.current_node_id = enc.destination_node_id
		# A boss skips the normal card reward and funnels straight back through the map (→
		# Stage Cleared / Run Successful); a normal win goes to the card-reward screen.
		var is_boss := enc != null and enc.type == EncounterData.Type.BOSS
		GameData.save_run()
		# When the chest handed over, the reward orb is hanging in the middle of the screen right
		# now — so the screen it leads to GROWS out of that spot instead of cutting to it. Without
		# a chest (nothing to hand over from) the standard sweep still applies.
		var arrival := "screen_grow_in" if _reward_chest != null else ""
		if is_boss:
			Nav.goto("res://scenes/map.tscn", arrival)
		else:
			Nav.goto("res://scenes/reward_screen.tscn", arrival)
	else:
		if enc != null:
			enc.outcome = EncounterData.Outcome.LOSE
		# Defeat ends the run (meta-progression kept) and shows the Run Over screen.
		GameData.end_run()
		Nav.goto("res://scenes/run_over.tscn")


# ── Board event handlers ───────────────────────────────────────────────────────

func _on_board_unit_placed(inst: CardInstance, card_ui: CardUI, from_hand: bool, cost: int, results: Array) -> void:
	# A REPOSITION of the picked unit: the selection outlives the move, so the unit's static
	# action must derive from the NEW spot. The generic end-of-action re-derive
	# (_on_interaction_changed) has already run by now — but it ran when the commit ENDED the
	# action, i.e. BEFORE the move executed, so everything it presented (destinations, the
	# attack projection) still described the old square. Beginning the action afresh here
	# re-presents from where the unit now stands.
	if not from_hand and _phase == Phase.PLAYER_PLACE and Selection.holds(inst):
		_interaction.begin(_board.make_unit_action(card_ui, false, false))
	if from_hand:
		# The placed card may still be the hand's live selection (the click-place path commits
		# through the Interaction session, which doesn't know the hand) — clear it before the
		# card leaves the hand so no stale selection survives the placement.
		_hand.deselect()
		Sfx.play("combat_place_building" if inst.data.is_building() else "combat_place_unit")
		_pay_mana(_player_side, cost)
		if cost > 0:
			# The mana paying for the play flies from the gauge into the placed card.
			Vfx.play("mana_spend_wisp", card_ui, {"source": _mana_chunks_box})
		if card_ui.is_generated:
			_consume_generated_token(card_ui)
		else:
			_player_side.remove_from_hand(inst)
			_hand.remove_card(card_ui)
	_vfx.play(VFXEvent.card_placed(card_ui))
	# A unit just entered (or an ability token left) the board, so the roster of ability-bearing
	# units changed — re-derive the Inspect Abilities button against the new composition.
	_hand.refresh_nav()
	await _animator.show_effect_results(results, inst)


# An ability token was just activated: pay its tap cost if it has one (the holder's action
# for the round — its other tap-costed offers leave the tray immediately).
func _consume_generated_token(card_ui: CardUI) -> void:
	_hand.remove_token(card_ui)
	var holder: CardInstance = card_ui.card_instance.source_building
	var ab: AbilityData = card_ui.card_instance.ability
	if holder != null:
		Vfx.play("ability_activate_flare", _board.get_card_ui(holder))
	if holder != null and (ab == null or ab.tap):
		_pay_tap(holder)
	card_ui.clear_generated()
	# Stay in the inspect view (no auto-pop): re-derive the tray so a tapped-out unit shows its
	# empty state in place. The Inspect Abilities button withdraws separately via _pay_tap's prune.
	_hand.refresh_inspect()


# Spends the holder's action for the round — the tap half of an ability's cost, shared by
# the tray-token path above and the autocast path (_on_ability_autocast).
func _pay_tap(holder: CardInstance) -> void:
	holder.attack_exhausted = true   # the fact; the card derives its grey from it
	_highlight_building(holder, false)
	var holder_ui := _board.get_card_ui(holder)
	if holder_ui != null:
		holder_ui.derive_presentation()   # re-check cue — instant instead of a poll beat
	_hand.prune_tapped(holder)


# ── Autocast (armed ability fired by dragging the holder onto a target) ─────────

# The AUTOCAST action committed on a valid occupied slot (role predicate →
# SpellCaster.autocast_drop_ok); hand it to the caster, which re-validates and emits
# ability_autocast for payment below.
func _on_autocast_dropped(slot: SlotUI, card_ui: CardUI) -> void:
	await _spell_caster.activate_autocast(card_ui.card_instance, slot)


# The autocast twin of _on_spell_consumed + _consume_generated_token: mana, then the tap.
func _on_ability_autocast(holder: CardInstance, ab: AbilityData) -> void:
	Vfx.play("ability_activate_flare", _board.get_card_ui(holder))
	_pay_mana(_player_side, ab.mana)
	if ab.tap:
		_pay_tap(holder)


# An ability widget toggled a holder's armed state: refresh that unit's board card so the
# armed-brackets echo (CardUI._refresh_autocast_brackets) tracks it.
func _on_autocast_changed(holder: CardInstance) -> void:
	var ui := _board.get_card_ui(holder)
	if ui != null:
		ui.refresh()
		if holder.armed_autocast() != null:
			Vfx.play("autocast_arm_brackets", ui)
		else:
			Sfx.play("autocast_disarm")


func _on_board_slot_pressed(slot: SlotUI) -> void:
	# The Interaction session gets every press first: a live click session commits on a valid
	# pick (spell target, placement spot); a modal session swallows invalid picks and stays
	# aiming. Only unconsumed presses fall through to inspection/selection below.
	if _interaction.handle_slot_press(slot):
		return
	if _phase != Phase.PLAYER_PLACE:
		return
	var occupant := slot.get_card()
	if occupant != null:
		# Clicking any fielded unit — either side — makes it the pick: the hand row shows its
		# description and abilities (the panel derives from the pick — Hand._on_selection_changed)
		# instead of anything placement-related. ONE write: a hand card that was selected stops
		# being the pick because the state no longer names it, not because anyone deselected it.
		_hand.set_inspected(occupant.card_instance)
		# Selecting ANY fielded unit begins a static UNIT action. What shows falls out of the
		# roles: a movable player unit gets ring+arrow destinations + its attack projection; an
		# enemy unit or rooted building yields no destinations (role_of returns NONE everywhere),
		# leaving just the projection — who it hits (crosshair) and who hits it (menace glow).
		_interaction.begin(_board.make_unit_action(occupant, false, false))
		return
	# Empty slot, nothing committed: placement itself went through handle_slot_press (the
	# selection began a UNIT action) — what's left is FEEDBACK for a blocked selection.
	var card := _hand.selected()
	if card == null:
		return
	if not _board.can_place_from_hand(card) \
			and card.card_instance.get_attribute("cost") > _player_side.mana:
		# When the block is the mana pool, say so: the gauge flickers "present but empty".
		Vfx.play("mana_insufficient_flicker", _mana_chunks_box)


# ── Interaction bridging ───────────────────────────────────────────────────────

# The orchestrator's whole stake in a gesture: a MODAL aiming session locks placement input
# (the old TARGETING phase's job) and re-derives the Ready button. Cue rendering is entirely
# the board's present(); cleanup is the session ending itself.
func _on_interaction_changed(action: Interaction.Action) -> void:
	var lock := action != null and action.modal
	if lock != _modal_lock:
		_modal_lock = lock
		if lock:
			Sfx.play("spell_targeting")
		if _phase == Phase.PLAYER_PLACE:
			_set_placement_input(not lock)
	# A selected fielded unit WEARS its static cues (move spots + attack projection) for as long
	# as it is the pick — so when an action ends while a fielded unit is still picked (an ability
	# aim backed out, a move committed), the unit's own action derives right back instead of the
	# cues vanishing under a selection that never went away. No-op when the pick isn't fielded,
	# and self-limiting: the begin below re-enters this handler with a non-null action.
	if action == null and _phase == Phase.PLAYER_PLACE:
		var inst := Selection.current() as CardInstance
		if inst != null and inst.row >= 0 and inst.col >= 0:
			var ui := _board.get_card_ui(inst)
			if ui != null:
				_interaction.begin(_board.make_unit_action(ui, false, false))
	_refresh_done_btn()
	_refresh_card_presentation()   # aiming-source selection etc. derive from the session


# The one "re-check now" broadcast: every card view (board occupants, hand row, tray tokens)
# re-derives from the declarations. Carries no verdicts — a redundant call is always safe.
func _refresh_card_presentation() -> void:
	_board.derive_cards()
	_hand.derive_cards()


func _on_spell_consumed(card_ui: CardUI, cost: int) -> void:
	Sfx.play("spell_cast")
	_pay_mana(_player_side, cost)
	if cost > 0:
		Vfx.play("mana_spend_wisp", card_ui, {"source": _mana_chunks_box})
	# A rook-generated SPELL token (e.g. Castling) casts through this same path as a normal hand
	# spell — but it must exhaust its source rook like a generated UNIT token does, not just drop
	# out of the normal hand list (see _consume_generated_token).
	if card_ui.is_generated:
		_consume_generated_token(card_ui)
	else:
		_player_side.remove_from_hand(card_ui.card_instance)
		_hand.remove_card(card_ui)


# ── UI building ────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Combat declines the Shell header entirely (see get_chrome), so the body owns the full screen
	# rect. Margins are pared to the bone — cards read bigger for every pixel reclaimed: sides keep
	# the touch-safe inset, the top keeps token breathing room, and the BOTTOM is pulled BELOW the
	# screen edge so the hand bar bleeds off it (only dead card frame is cropped — see
	# Hand.BOTTOM_BLEED).
	# Sides run tighter than the app-wide safe inset: combat is starved for horizontal space (the
	# board is width-limited on 16:9), the left rail is display-only, and the right column's
	# buttons are big targets well clear of edge-gesture zones.
	var side := 16 if UIScale.is_compact() else 8
	var body := MarginContainer.new()
	body.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	body.add_theme_constant_override("margin_left", side)
	body.add_theme_constant_override("margin_right", side)
	body.add_theme_constant_override("margin_bottom", -int(Hand.BOTTOM_BLEED))
	body.add_theme_constant_override("margin_top", int(TOP_MARGIN))
	add_child(body)

	# The body splits into the MAIN column (arena over hand bar) and the full-height ACTION
	# column on the right — so the Ready button spans BOTH bands, from under the speed/✕ row all
	# the way down through the hand bar's height.
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	body.add_child(root)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", int(COL_SEP))   # a small visible breath between
	# the board and the hand bar — flush-to-flush read as one compressed block
	root.add_child(col)

	# The arena row: the relic strip hugs the LEFT of the board (full arena height — room for the
	# 10-relic capacity at big chip sizes), the two board halves fill the middle, and the action
	# column (speed + debug ✕ over Ready) hugs the RIGHT. Gameplay controls live around the board
	# they act on. All three stretch to the same height, so the row reads as one balanced band.
	# The mana gauge lives in the HAND bar below (its leftmost column) — mana is what the hand
	# spends, so the readout sits with the cards it pays for.
	var arena := HBoxContainer.new()
	arena.size_flags_vertical = SIZE_EXPAND_FILL
	arena.add_theme_constant_override("separation", 12)
	col.add_child(arena)

	# Outboard of everything on the left: the experience column. Narrow on purpose — it is the
	# quiet half of a kill's payment (see _pay_bounty) and must never compete with the board for
	# attention, only be there when the player looks.
	_exp_gauge = ExpGauge.new()
	arena.add_child(_exp_gauge)

	var relic_strip := _build_relic_strip()
	arena.add_child(relic_strip)

	_board_row = HBoxContainer.new()
	_board_row.size_flags_horizontal = SIZE_EXPAND_FILL
	_board_row.size_flags_vertical = SIZE_EXPAND_FILL
	# The halves' gulf is divider + two flanking separations, totalling BOARD_HALVES_GAP (the
	# width _resize_board budgets for).
	_board_row.add_theme_constant_override("separation",
		int((BOARD_HALVES_GAP - HALVES_DIVIDER_W) / 2.0))
	arena.add_child(_board_row)

	_board.build_section(_board_row, true)
	_board_row.add_child(_make_halves_divider())
	_board.build_section(_board_row, false)

	# The action column: the main column's full-height SIBLING (not part of the arena). Its own
	# bottom margin swallows the body's below-screen bleed — the Ready button is interactive, so
	# unlike the hand bar's dead card frame it must end at the real screen edge.
	var action_wrap := MarginContainer.new()
	action_wrap.add_theme_constant_override("margin_bottom", int(Hand.BOTTOM_BLEED))
	var actions := _build_action_column()
	action_wrap.add_child(actions)
	root.add_child(action_wrap)

	# The fixed width flanking the board — _resize_board's width basis (see there for why it must
	# come from here and not from live container sizes).
	_arena_chrome_w = side * 2.0 + relic_strip.custom_minimum_size.x \
		+ _exp_gauge.custom_minimum_size.x + actions.custom_minimum_size.x + 3.0 * 12.0

	_hand.build_into(col, _build_mana_gauge())

	# The board fills its area with the biggest cards that fit (recomputed on any resize), instead of
	# a fixed grid marooned in empty space.
	_board_row.resized.connect(_resize_board)
	call_deferred("_resize_board")


# The thin vertical rule between the player and enemy halves — with the zones now tinted in
# their own colours, this is the hard line the two fields meet at.
func _make_halves_divider() -> Control:
	var divider := Panel.new()
	divider.custom_minimum_size.x = HALVES_DIVIDER_W
	divider.size_flags_vertical = SIZE_EXPAND_FILL
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.18, 0.32, 0.85)
	sb.set_corner_radius_all(2)
	divider.add_theme_stylebox_override("panel", sb)
	return divider


# The vertical relic strip, owning the whole left rail: with no header during combat this is
# where the run's relics live — a full-height column of big chips, count at the top, framed like
# the mana gauge in the hand bar so the two read as one family. Read-only here (discarding is the
# map HUD's job), and combat keeps the handle to glint a firing relic's chip (see _fire_run_level).
func _build_relic_strip() -> Control:
	var strip := Panel.new()
	strip.custom_minimum_size.x = 122.0 if UIScale.is_compact() else 92.0
	strip.size_flags_vertical = SIZE_EXPAND_FILL
	UIScale.tip(strip, Loc.t("combat.relics_tip"))
	var track := StyleBoxFlat.new()
	track.bg_color = ScreenUI.MANA_TRACK_BG
	track.set_corner_radius_all(12)
	track.set_border_width_all(2)
	track.border_color = ScreenUI.MANA_TRACK_BORDER
	strip.add_theme_stylebox_override("panel", track)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", 4)
	pad.add_theme_constant_override("margin_right", 4)
	pad.add_theme_constant_override("margin_top", 8)
	pad.add_theme_constant_override("margin_bottom", 8)
	strip.add_child(pad)

	# One column inside the padding: the purse, then a hairline, then the relics. The bag heads
	# the strip because it is the same kind of thing as what follows — a run-long possession
	# combat only reports on — and because the coins need something to aim at (see _pay_bounty).
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	pad.add_child(column)

	_gold_bag = GoldBag.new()
	column.add_child(_gold_bag)
	column.add_child(_strip_rule())

	_relic_tray = RelicTray.new()
	_relic_tray.vertical = true
	_relic_tray.interactive = false   # info-only: tapping a chip opens its detail overlay
									   # (the touch reading path), but never offers Discard
	# Consumable relics ARE usable here — combat is the one surface that arms their hold.
	# Usable only while the player is placing (never mid-resolution, mid-aim, or while another
	# consumable's own use is still animating); the chips poll this, nothing pushes at them.
	_relic_tray.consumable_check = func() -> bool:
		return _phase == Phase.PLAYER_PLACE and not _modal_lock and not _consumable_busy
	_relic_tray.consume_requested.connect(_use_consumable)
	column.add_child(_relic_tray)
	return strip


# The hairline separating the purse from the relics below it — the strip holds two kinds of
# thing, and one rule is cheaper than a gap wide enough to say so.
func _strip_rule() -> Control:
	var rule := Panel.new()
	rule.custom_minimum_size.y = 2.0
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = ScreenUI.MANA_TRACK_BORDER
	sb.set_corner_radius_all(1)
	rule.add_theme_stylebox_override("panel", sb)
	return rule


# The vertical mana gauge, anchoring the LEFT end of the hand bar (full bar height — mana is
# what the hand spends, so the readout sits with the cards it pays for): one framed component
# with a "MANA" label in a header cell at the TOP, the chunk stack in the middle (one chunk per
# point of max mana — spent chunks dim, available ones lit, filling from the bottom), and the
# current/max count in a matching footer cell at the BOTTOM. Labels and chunks never overlap.
# _refresh_mana rebuilds the chunk count when max mana ramps and recolours them as mana is
# spent. The ramp is uncapped, so the chunk floor/separation run tiny — a deep late-game stack
# thins out instead of overflowing the gauge (the footer count stays the precise read).
func _build_mana_gauge() -> Control:
	var compact := UIScale.is_compact()
	var gauge := Panel.new()
	gauge.custom_minimum_size.x = 122.0 if compact else 92.0
	gauge.size_flags_vertical = SIZE_EXPAND_FILL
	UIScale.tip(gauge, Loc.t("combat.mana_tip"))
	var track := StyleBoxFlat.new()
	track.bg_color = ScreenUI.MANA_TRACK_BG
	track.set_corner_radius_all(12)
	track.set_border_width_all(2)
	track.border_color = ScreenUI.MANA_TRACK_BORDER
	gauge.add_theme_stylebox_override("panel", track)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", 6)
	pad.add_theme_constant_override("margin_right", 6)
	pad.add_theme_constant_override("margin_top", 6)
	# The hand bar's last BOTTOM_BLEED px hang off-screen — keep the footer count clear of them.
	pad.add_theme_constant_override("margin_bottom", 6 + int(Hand.BOTTOM_BLEED))
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	gauge.add_child(pad)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_child(col)

	# Header cell: the "MANA" label.
	var tag := Label.new()
	tag.text = Loc.t("combat.mana_tag")
	tag.add_theme_font_size_override("font_size", 22 if compact else 16)
	tag.add_theme_color_override("font_color", Color(0.72, 0.78, 0.92))
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(tag)

	col.add_child(_gauge_divider())

	# The chunk stack fills the middle of the gauge (one Panel per max-mana point).
	_mana_chunks_box = VBoxContainer.new()
	_mana_chunks_box.size_flags_vertical = SIZE_EXPAND_FILL
	_mana_chunks_box.add_theme_constant_override("separation", 2)
	_mana_chunks_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_mana_chunks_box)

	col.add_child(_gauge_divider())

	# Footer cell: the current/max count, in a matching zone at the bottom (never over the chunks).
	_mana_label = Label.new()
	_mana_label.add_theme_font_size_override("font_size", 28 if compact else 22)
	_mana_label.add_theme_color_override("font_color", Color(0.92, 0.96, 1.0))
	_mana_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mana_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	col.add_child(_mana_label)
	return gauge


# A thin horizontal rule that frames the mana gauge's header/footer cells against the chunk stack.
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
	chunk.size_flags_vertical = SIZE_EXPAND_FILL
	chunk.custom_minimum_size.y = 2.0   # a floor so many chunks never collapse to nothing —
	# tiny, because the uncapped ramp can stack dozens of chunks into the fixed-height gauge
	chunk.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return chunk


# The action column, hugging the RIGHT of the board: a thin top row pairing the battle-speed
# toggle with the debug end-combat ✕ (homeless since the header left the screen), then the big
# "Ready" button filling everything below. Squashed as narrow as its labels allow — its width
# comes straight out of the board's card size.
func _build_action_column() -> Control:
	var compact := UIScale.is_compact()
	var col := VBoxContainer.new()
	# Width floor: the speed button (column − separation − the 48px ✕) must stay at or above its
	# GlossyButton bake's 136px width — a nine-patch can only STRETCH cleanly; compressing the
	# centre band squashes the baked rim/sheen into doubled-line artifacts.
	col.custom_minimum_size.x = 200.0 if compact else 192.0
	col.add_theme_constant_override("separation", 10)

	# The presentation row — the three dials the player may want mid-fight, side by side: how much
	# the animations overlap (pacing), how fast the clock runs (speed), and the full settings panel.
	# All three share the row equally; at the column's width that lands each of them near-square,
	# inside GlossyButton's icon-shape band, so they take the square bake rather than a squashed
	# nine-patch (see the width-floor note above — that floor is a LANDSCAPE-bake constraint and
	# doesn't apply to icon-shaped buttons).
	var side := ScreenUI.BUTTON_HEIGHT_COMPACT - 16.0
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	top_row.custom_minimum_size.y = side
	col.add_child(top_row)

	_pacing_btn = ScreenUI.action_button("", _on_pacing_pressed, Vector2(0, side))
	_pacing_btn.expand_icon = true
	_pacing_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pacing_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	top_row.add_child(_pacing_btn)
	_refresh_pacing_btn()

	_speed_btn = ScreenUI.action_button("", _on_speed_pressed, Vector2(0, side), 26 if compact else 20)
	_speed_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	top_row.add_child(_speed_btn)
	_refresh_speed_btn()

	# The panel carries the SAME pacing picker as the button beside it, so re-read it on dismiss —
	# otherwise a change made in the panel leaves this button showing a stale chevron count.
	var open_settings := func() -> void:
		var overlay := SettingsOverlay.open(self)
		if overlay != null:
			overlay.closed.connect(_refresh_pacing_btn)
	var gear := ScreenUI.action_button("", open_settings, Vector2(0, side))
	gear.icon = preload("res://assets/ui/icons/settings.png")
	gear.expand_icon = true
	gear.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	gear.size_flags_horizontal = SIZE_EXPAND_FILL
	UIScale.tip(gear, Loc.t("settings.title"))
	top_row.add_child(gear)

	# Debug tools get their OWN row, present only in debug builds — so a debug affordance never
	# takes width from a control the player actually uses. Full-width: the row exists or it doesn't.
	# Two ends of the same shortcut share it: ✕ skips straight to the combat-end bookkeeping, while
	# "Kill" fells the enemy captain and lets the real death sequence play (see _debug_kill_captain).
	if DebugConfig.enabled():
		var debug_row := HBoxContainer.new()
		debug_row.add_theme_constant_override("separation", 8)
		debug_row.custom_minimum_size.y = side
		col.add_child(debug_row)

		var debug_close := ScreenUI.close_button(_handle_combat_end, true)
		debug_close.size_flags_horizontal = SIZE_EXPAND_FILL
		debug_close.size_flags_vertical = Control.SIZE_FILL
		debug_close.custom_minimum_size = Vector2(0, side)
		UIScale.tip(debug_close, "Debug: end combat")
		debug_row.add_child(debug_close)

		var debug_kill := ScreenUI.action_button("Kill", _debug_kill_captain,
			Vector2(0, side), 20, ScreenUI.CHROME_DEBUG)
		debug_kill.size_flags_horizontal = SIZE_EXPAND_FILL
		debug_kill.size_flags_vertical = Control.SIZE_FILL
		UIScale.tip(debug_kill, "Debug: kill the enemy captain")
		debug_row.add_child(debug_kill)

	# The key touch target — "Ready" — a chunky vertical button filling the rest of the column,
	# all the way down through the hand bar's band. Green, from the glossy handoff's own "Ready"
	# palette entry. The caption is NOT the button's own text (which Godot can only centre
	# vertically — mid-screen on a button this tall): it's a bottom-anchored child Label whose
	# band _resize_board keeps equal to the hand bar's, so the word sits level with the Inspect
	# Abilities text beside it. Styled to match GlossyButton's own text treatment.
	_done_btn = ScreenUI.action_button("", _on_done_pressed, Vector2.ZERO,
		44 if compact else 30, ScreenUI.CHROME_READY)
	_done_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	_done_btn.size_flags_vertical = SIZE_EXPAND_FILL
	col.add_child(_done_btn)

	_done_label = Label.new()
	_done_label.set_anchors_and_offsets_preset(PRESET_BOTTOM_WIDE)
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


# Sizes every board slot AND the hand bar's cards to the largest shared card size that fits —
# one card size for the whole screen, keeping the card aspect, so the halves fill their space
# with big, tappable cards and even gaps. Runs on any resize (window / form factor).
#
# CRITICAL: the solve reads NOTHING the cards themselves influence — only the screen size and
# the fixed chrome around the board (_arena_chrome_w, margins, pads). Live container sizes are
# poisoned in both directions: the height feeds back through Hand.set_card_size (panel height →
# board area → here again; integer rounding can cycle that loop forever — a layout-recursion
# crash on combat entry at certain window sizes), and _board_row's width equals its CONTENT
# minimum whenever the slots overflow a narrow window, so the board could never shrink back to
# fit. From stable inputs, re-entry recomputes the identical target and stops.
func _resize_board() -> void:
	if size.x < 1.0 or size.y < 1.0 or _arena_chrome_w <= 0.0:
		return

	var cols := BoardData.COLS
	var rows := BoardData.ROWS
	var gap := float(BoardData.SLOT_GAP)
	# Width splits across the two halves (minus the gulf between them); each half holds `cols`
	# inside its zone panel's inner pad.
	var half_w := (size.x - _arena_chrome_w - BOARD_HALVES_GAP) / 2.0
	var slot_w_by_width := (half_w - 2.0 * CombatBoard.HALF_PAD - (cols - 1) * gap) / float(cols)
	# Height: the body's column carries the board's `rows` cards + the hand's one card (same
	# size), the row gaps, the zone panels' vertical pad, the column separation, and the hand
	# bar's top pad. The hand bar's bottom edge deliberately sits BOTTOM_BLEED below the screen
	# (see _build_ui).
	var avail_h := size.y - TOP_MARGIN + Hand.BOTTOM_BLEED
	var budget := avail_h - COL_SEP - Hand.PAD_TOP - 2.0 * CombatBoard.HALF_PAD \
		- (rows - 1) * gap
	var slot_h := budget / float(rows + 1)
	var slot_w := floorf(minf(slot_w_by_width, slot_h / BoardData.SLOT_ASPECT))
	if slot_w < 1.0:
		return
	var slot_size := Vector2(slot_w, floorf(slot_w * BoardData.SLOT_ASPECT))

	# Before the slot bail — the hand can be stale even when the slots are already correct
	# (it no-ops when unchanged).
	_hand.set_card_size(slot_size)
	# Keep the Ready caption's band equal to the hand bar's visible height (the button's bottom
	# already sits at the true screen edge), so the word stays level with Inspect Abilities.
	if _done_label != null:
		_done_label.offset_top = -(slot_size.y + Hand.PAD_TOP - Hand.BOTTOM_BLEED)
	if (_board.player_slots[0][0] as SlotUI).custom_minimum_size == slot_size:
		return   # already correct → stop before we trigger another resize
	for r in rows:
		for c in cols:
			(_board.player_slots[r][c] as SlotUI).custom_minimum_size = slot_size
			(_board.enemy_slots[r][c] as SlotUI).custom_minimum_size = slot_size


# ── Display refresh ────────────────────────────────────────────────────────────

func _refresh() -> void:
	_refresh_mana()
	_board.refresh()
	_hand.refresh()
	# Turn-start untap (and initial setup) change which units can offer abilities — the canonical
	# resync is also where the Inspect Abilities button gets its first/renewed evaluation.
	_hand.refresh_nav()
	_refresh_done_btn()


func _refresh_mana() -> void:
	if _mana_label:
		_mana_label.text = "%d/%d" % [_player_side.mana, _player_side.max_mana]
	if _mana_chunks_box == null:
		return

	# Rebuild the segment stack when max mana changes (it ramps up over the fight).
	var want := maxi(_player_side.max_mana, 0)
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
		sb.bg_color = ScreenUI.MANA_LIT if from_bottom < _player_side.mana else ScreenUI.MANA_DIM
		sb.set_corner_radius_all(4)
		(chunks[idx] as Panel).add_theme_stylebox_override("panel", sb)


# Advance to the next battle speed, applying it immediately (live time_scale). Per-combat only —
# not persisted, so the next fight starts back at x1.
func _on_speed_pressed() -> void:
	var i := BATTLE_SPEEDS.find(_battle_speed)
	_battle_speed = BATTLE_SPEEDS[(i + 1) % BATTLE_SPEEDS.size()]
	Engine.time_scale = _battle_speed
	_refresh_speed_btn()


# Advance to the next pacing preset. UNLIKE speed, this IS the player's persisted setting — the same
# value the settings panel writes (Vfx.set_overlap) — because it's a standing preference for how
# combat should read, not a per-fight scrub. The two dials are deliberately separate: speed changes
# how fast the clock runs, pacing changes how much the animations overlap.
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
	if _speed_btn:
		# "x1" / "x1.5" / "x2" / "x0.5" — one decimal, with a bare ".0" trimmed off so the whole
		# multipliers stay short in a button this narrow.
		_speed_btn.text = "x" + String.num(_battle_speed, 1).trim_suffix(".0")
		UIScale.tip(_speed_btn, Loc.t("settings.speed"))


func _refresh_done_btn() -> void:
	if _done_btn == null or _done_label == null:
		return
	match _phase:
		Phase.PLAYER_PLACE:
			if _interaction != null and _interaction.modal_active():
				# A modal aiming session owns the board — Ready waits for the pick/cancel.
				_done_label.text   = Loc.t("combat.select_target")
				_done_btn.disabled = true
			else:
				_done_label.text   = Loc.t("combat.ready")
				_done_btn.disabled = false
		Phase.CPU_PLACE:
			_done_label.text   = Loc.t("combat.cpu_placing")
			_done_btn.disabled = true
		Phase.COMBAT:
			_done_label.text   = Loc.t("combat.battle")
			_done_btn.disabled = true
	# The caption is a child Label, outside the button's own disabled styling — dim it manually.
	_done_label.modulate.a = 0.55 if _done_btn.disabled else 1.0


# ── Placement input gating ───────────────────────────────────────────────────────

# The hand owns its own cards/tokens; here we only toggle the board-side units that
# can be repositioned during placement.
func _set_placement_input(enabled: bool) -> void:
	_hand.set_input_enabled(enabled)
	_board.set_open_hints(enabled)   # idle "open here" markers only while placement is live
	if not enabled:
		_board.clear_preview()   # a leftover preview declaration can't outlive the placement phase
	var filter := Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardUI = (_board.player_slots[r][c] as SlotUI).get_card()
			if p:
				p.mouse_filter = filter


# A hand unit was selected (or deselected): a selection IS a static UNIT action — the board
# renders its "place here" cues from it, and deselection ends it. Never fights a modal aiming
# session (which owns the board) or a live drag (which owns the gesture).
func _on_hand_selection_changed(ui: CardUI) -> void:
	_refresh_card_presentation()   # the selection declaration changed — cards re-derive
	if _interaction.modal_active():
		return
	if ui != null and not ui.card_instance.is_spell:
		_interaction.begin(_board.make_unit_action(ui, false, false))
	elif _interaction.active() and not _interaction.current().is_drag:
		_interaction.end_action()
