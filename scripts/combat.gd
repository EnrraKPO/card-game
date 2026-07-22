extends Control

# Selectable battle speeds the HUD toggle cycles through (applied as Engine.time_scale). Shown as
# percentages; every fight starts at 100% (1.0) — the dial is per-combat, not remembered.
const BATTLE_SPEEDS: Array[float] = [0.5, 1.0, 1.5, 2.0]

# Beat between a shield absorbing part of a hit and the bleed-through HP damage landing, so the
# shield reads as taking the blow first (scaled by battle speed like every other combat beat).
const SHIELD_LEAD := 0.14
const RELIC_CUE_LEAD := 0.34   # let a firing relic's chip glint read before its effects' VFX
const BOARD_HALVES_GAP := 24.0   # the TOTAL gulf between the halves: divider + flanking gaps
const HALVES_DIVIDER_W := 4.0   # the visible rule standing in the middle of that gulf
const COL_SEP := 14.0   # board↔hand breathing room; also a term in _resize_board's height budget
const TOP_MARGIN := 12.0   # the body's top inset; another _resize_board height-budget term

enum Phase { CPU_PLACE, PLAYER_PLACE, COMBAT, TARGETING }

var _phase: Phase = Phase.CPU_PLACE
var _turn: int    = 0

# The two sides' resource state (mana / hand / draw pile) — one object each, mutated ONLY
# through Resolver.submit (side stats: draw/discard/mana/max_mana). The player's Hand bar
# and the mana gauge subscribe to the player side's signals; the enemy side has no watchers.
var _player_side: CombatSide
var _enemy_side: CombatSide

var _mana_label: Label              # current-mana number on the vertical gauge
var _mana_chunks_box: VBoxContainer  # one chunk per max-mana point; lit=available, dim=spent
var _relic_tray: RelicTray   # read-only vertical relic strip on the screen's left edge (see
							  # _build_relic_strip); a firing relic glints its chip
var _done_btn: Button        # the chunky vertical "Ready" button (right of the board)
var _done_label: Label       # the Ready button's caption — bottom-anchored inside the button so
							  # the word sits on the hand band, aligned with Inspect Abilities
							  # (Button has no vertical text alignment; see _build_action_column)
var _speed_btn: Button
var _battle_speed: float = 1.0   # 100%; reset each combat, cycled by the HUD dial

var _board_row: HBoxContainer   # the two board halves; drives responsive slot sizing on resize
var _arena_chrome_w: float = 0.0   # side margins + left rail + action column + separations —
									# the fixed width around the board, _resize_board's width basis

var _hand: Hand
var _board: CombatBoard
var _animator: CombatAnimator
var _spell_caster: SpellCaster
var _vfx: VFXPlayer

# The board CardUI currently highlighted as "inspected" (see _on_inspect_changed), tracked so
# it can be cleared when the inspection moves to a different unit or closes.
var _inspected_ui: CardUI = null

# While a melee attacker is lunging, its real card is hidden and a ghost duplicate does the
# travelling. This maps such an attacker → its ghost so the attacker's own VFX (the on-attack
# glint / self-buff) plays on the card the player is actually watching, not the hidden origin one.
var _ghost_ui: Dictionary = {}   # CardInstance -> CardUI


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
	add_child(_hand)
	add_child(_board)
	add_child(_animator)
	add_child(_spell_caster)
	add_child(_vfx)

	_board.setup_grids()
	_board.player_side  = _player_side
	_board.enemy_side   = _enemy_side
	_board.is_hand_card = func(cu: CardUI) -> bool: return _hand.contains(cu)
	_board.get_mana     = func() -> int:            return _player_side.mana

	var _get_card_ui: Callable = func(inst: CardInstance) -> CardUI:
		var ghost: CardUI = _ghost_ui.get(inst)
		if ghost != null and is_instance_valid(ghost):
			return ghost
		return _board.get_card_ui(inst)
	_vfx.setup(self, _get_card_ui)
	# Relic-owned interception cues glint the tray chip; the tray lives in combat's chrome,
	# so combat lends the presenter this one reach into it.
	_vfx.relic_glint = func(relic_id: String) -> void:
		if _relic_tray != null:
			_relic_tray.glint(relic_id)
	_animator.setup(self, _get_card_ui, _vfx)

	_spell_caster.setup(_board, _animator, func() -> int: return _player_side.mana)
	_hand.bind_side(_player_side)
	_player_side.mana_changed.connect(_refresh_mana)
	# Mana changing shifts which abilities are affordable, so re-derive the Inspect Abilities glow
	# (spending on a hand spell can leave nothing usable; a refill can revive it). Glow only — the
	# inspect tray can't be open while hand spells cast, and ability casts rebuild it themselves.
	_player_side.mana_changed.connect(_hand.refresh_nav)
	_hand.wire_spell_card = _spell_caster.wire_spell_card
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

	# Whether an ability is castable RIGHT NOW: its tap cost (if any) isn't already spent AND the
	# player can afford its mana. Feeds the tray's spent-token grey and the Inspect Abilities glow.
	_hand.is_ability_usable = func(holder: CardInstance, ab: AbilityData) -> bool:
		if ab.tap and holder.attack_exhausted:
			return false
		return ab.mana <= _player_side.mana

	_board.can_autocast = _spell_caster.autocast_drop_ok
	_board.unit_placed.connect(_on_board_unit_placed)
	_board.slot_pressed.connect(_on_board_slot_pressed)
	_board.autocast_dropped.connect(_on_autocast_dropped)
	_spell_caster.targeting_started.connect(_on_targeting_started)
	_spell_caster.targeting_ended.connect(_on_targeting_ended)
	_spell_caster.spell_consumed.connect(_on_spell_consumed)
	_spell_caster.ability_autocast.connect(_on_ability_autocast)

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


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed \
				and _spell_caster.is_targeting():
			_spell_caster.cancel_targeting()
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed:
			_maybe_dismiss_hand_view(mb.position)


# Clicking anywhere OUTSIDE the hand panel while it's past its base level dismisses back to
# the plain hand view (clearing any inspected card). A geometric test in _input, NOT
# _unhandled_input: background panels/gauges consume clicks they do nothing with (STOP mouse
# filters), so unhandled-input never fires over most of the screen. _input runs BEFORE GUI
# delivery, so a click on a board unit dismisses and then the slot's own handler re-inspects
# that unit in the same frame — the "switch inspection" behavior falls out for free. Fires on
# RELEASE (where slots/cards act); skipped during spell targeting (which owns stray clicks)
# and mid-drag (a failed drop must not also close the view).
func _maybe_dismiss_hand_view(point: Vector2) -> void:
	if _hand.nav_level() == Hand.NavLevel.HAND:
		return
	if _spell_caster.is_targeting():
		return
	if get_viewport().gui_is_dragging():
		return
	if _hand.panel_contains(point):
		return
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
	await _do_cpu_placement()
	Sfx.play("combat_turn_start")
	Vfx.play("mana_refill_surge", _mana_chunks_box)   # the gauge blooms as it refills
	_phase = Phase.PLAYER_PLACE
	_board.placement_enabled = true
	_set_placement_input(true)
	_reset_exhaustion()
	_refresh()


func _do_cpu_placement() -> void:
	_phase = Phase.CPU_PLACE
	_board.placement_enabled = false
	_set_placement_input(false)
	_refresh_done_btn()

	var ai: EnemyAI = EnemyAI.new()
	if GameData.current_encounter != null and GameData.current_encounter.ai != null:
		ai = GameData.current_encounter.ai

	for action: Dictionary in ai.decide_actions(_enemy_side.hand, _board, _enemy_side.mana):
		await _execute_enemy_action(action)


# Carries out one planned CPU action. The AI guarantees each is legal in sequence
# (mana + slot occupancy), so this just applies the effect and animates it.
func _execute_enemy_action(action: Dictionary) -> void:
	match action["type"]:
		EnemyAI.Action.PLACE:
			var inst: CardInstance = action["inst"]
			_pay_mana(_enemy_side, inst.data.cost)
			_enemy_side.remove_from_hand(inst)
			var results := _board.place_enemy_card(inst, action["row"], action["col"])
			Sfx.play("combat_enemy_place")
			_vfx.play(VFXEvent.card_placed(_board.get_card_ui(inst)))
			await _animator.show_effect_results(results, inst)
		EnemyAI.Action.CAST:
			var inst: CardInstance = action["inst"]
			_pay_mana(_enemy_side, inst.data.cost)
			_enemy_side.remove_from_hand(inst)
			await _show_enemy_spell(inst, action["target"])
		EnemyAI.Action.GENERATE:
			# An enemy unit activates an ability. Pay the cost (mana + tap if the ability
			# carries it), then resolve per v1 policy: a material ability always takes its
			# SPAWN half onto the planned slot (functionally the old unit generation; merge
			# smarts later); any other ability casts at the AI-picked target.
			var holder: CardInstance = action["unit"]
			var ab: AbilityData = action["ability"]
			_pay_mana(_enemy_side, ab.mana)
			if ab.tap:
				holder.attack_exhausted = true
				var b_ui := _board.get_card_ui(holder)
				if b_ui != null:
					b_ui.set_exhausted(true)
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
		EnemyAI.Action.MOVE:
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
	banner.text = "Enemy casts %s" % inst.data.display_name
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
		inst.attack_exhausted = false
		var ui := _board.get_card_ui(inst)
		if ui != null:
			ui.set_exhausted(false)


# Toggles the gold targeting glow on a building's board slot, used to point out
# which rook a hovered/selected token belongs to.
func _highlight_building(inst: CardInstance, on: bool) -> void:
	if inst == null or inst.owner != 0 or inst.row < 0 or inst.col < 0:
		return
	(_board.player_slots[inst.row][inst.col] as SlotUI).set_targetable(on)


# Mirrors Hand's inspected card as a board highlight (see CardUI.set_inspected).
func _on_inspect_changed(inst: CardInstance) -> void:
	if _inspected_ui != null and is_instance_valid(_inspected_ui):
		_inspected_ui.set_inspected(false)
	_inspected_ui = null
	if inst == null:
		return
	var ui := _board.get_card_ui(inst)
	if ui != null:
		ui.set_inspected(true)
		_inspected_ui = ui


func _on_done_pressed() -> void:
	_hand.deselect()
	_hand.clear_inspected()
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
		# attack position beside it, and HOLD there while the strike's damage + triggered effects (e.g.
		# bishop_pawn's heal-on-attack) resolve next to the target — only then retreat home. The lunge
		# and rebound chain with no pause at the overshoot, so the hit keeps its momentum on impact.
		var a_home := a_card.global_position
		var gap := 12.0
		var beside_x: float = (t_card.global_position.x - a_card.size.x - gap) if attacker.owner == 0 \
			else (t_card.global_position.x + t_card.size.x + gap)
		var beside := Vector2(beside_x, t_card.global_position.y)
		# Overshoot PAST the attack position along the approach line (beside, pushed further from
		# home), so the rebound retraces the exact vector the lunge came in on — a real recoil off the
		# hit, not a step to the side.
		var overshoot := beside + (beside - a_home).normalized() * (a_card.size.x * 0.3)
		var ghost := _animator.spawn_ghost(a_card)
		a_card.modulate.a = 0.0
		# Route the attacker's own VFX onto the ghost while it travels (see _ghost_ui).
		_ghost_ui[attacker] = ghost
		Vfx.play("attack_swing_arc", ghost)   # the swing reads over the lunge, concurrent
		await _animator.play_lunge(ghost, overshoot)
		_animator.shake_card(t_card)               # impact shake at the apex, over the rebound
		await _animator.play_rebound(ghost, beside)
		await _apply_attack_damage(attacker, target, t_card)
		await _animator.play_retreat(ghost, a_home)
		_ghost_ui.erase(attacker)
		ghost.queue_free()
		a_card.modulate.a = 1.0

	if not target.is_alive():
		await _emit_kill(target)
		await _broadcast(GameEvent.make(&"death", target))
		await _vfx.play(VFXEvent.death(t_card))
		_board.remove_card(target)
	else:
		t_card.refresh()
		await get_tree().create_timer(0.2).timeout

	# A triggered/run-level effect resolved during this attack (e.g. an upgrade's on-death
	# retaliation) may have killed a bystander; sweep any secondary deaths off the board.
	_board.cleanup_effect_deaths()


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
	if outcome.dodged:
		# The target's speed slipped the blow outright — an ACTIVE evade (sidestep + "Dodge!"),
		# distinct from the grey whiff of a miss. Both land 0 damage; the cause differs.
		_vfx.play(VFXEvent.dodge(t_card))
		# The `dodge` event fires after `struck` (a dodged unit was still attacked): origin = the
		# attacker whose blow was slipped, destination = the dodger. Lets "when an ally dodges…"
		# reactions run (the dodger is the subject).
		await _broadcast(GameEvent.make(&"dodge", attacker, target))
	elif dmg <= 0:
		# A 0-damage strike (blocked, or <=0 Attack) reads as "Miss" rather than a number.
		_vfx.play(VFXEvent.miss(t_card))
	else:
		if outcome.crit:
			# A critical landed: the hot "Critical!" label plays ALONGSIDE the damage numbers below
			# (real damage still lands — never instead of them), and the ATTACKER's Speed badge
			# glints (speed drives crit, mirroring how a dodge glints the dodger's Speed). The
			# attacker's live presentation may be its lunge ghost mid-melee — same routing as
			# _get_card_ui in _ready.
			_vfx.play(VFXEvent.crit(t_card, dmg))
			var a_ui: CardUI = _ghost_ui.get(attacker)
			if a_ui == null or not is_instance_valid(a_ui):
				a_ui = _board.get_card_ui(attacker)
			if a_ui != null and is_instance_valid(a_ui):
				a_ui.flash_stat_proc("speed")
		# Shield reads FIRST: it takes the blow on its own badge (and only the badge — a held shield
		# leaves the card unwounded). When the hit also bleeds through to HP, a brief halt lets the
		# absorb land before the wound, so the shield is legible as the first thing that happened.
		# Hit sounds ride the VFX entries (combat_shield_hit/combat_health_damage carry their
		# sfx in data) — only the shield BREAK layer is contextual and fires here.
		if outcome.shield_absorbed > 0:
			if target.current_shield <= 0:
				Sfx.play("shield_break")
			_vfx.play(VFXEvent.shield_hit(t_card, outcome.shield_absorbed))
		if outcome.health_damage > 0:
			if outcome.shield_absorbed > 0:
				await get_tree().create_timer(SHIELD_LEAD).timeout
			_vfx.play(VFXEvent.health_damage(t_card, outcome.health_damage))
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


# Builds a dispatch context for one holder reacting to an event. The context carries the
# legacy single-subject view (SUBJECT/ATTACKER/ATTACK_TARGET targeting still read it); the
# activation decision itself lives entirely in each effect's TriggerResolver.
func _event_ctx(event: GameEvent, holder: CardInstance) -> EffectContext:
	var ctx := _board.make_context(holder)
	ctx.subject = event.subject()
	if event.id == &"attack" or event.id == &"crit":
		ctx.attack_target = event.destination   # attack/crit: subject is the striker, expose who got hit
	elif event.id == &"struck" or event.id == &"dodge":
		ctx.attacker = event.origin             # struck/dodge: the unit that struck (the dodger is the subject)
	return ctx


# The per-holder dispatch-and-present point: resolves `event` for `holder` in board context AND
# forwards the results to the animator, inseparably — a dispatch path shows its results BY
# CONSTRUCTION, not by each call site remembering to forward them.
func _fire(event: GameEvent, holder: CardInstance) -> void:
	var ctx := _event_ctx(event, holder)
	# Walk the holder's containers one at a time — its card, then each status — cueing each before its
	# (container-blind) effects land: card glint / pip glint → that container's effect VFX.
	for group: Dictionary in EffectSystem.trigger_grouped(event, holder, ctx):
		var gres: Array = group["results"]
		var sid: String = group["status_id"]
		await _animator.show_effect_results(gres, holder, sid)


# Run-level (relic/upgrade) effects for an event, fired ONCE from the perspective of the
# event's subject, grouped by their owning item: glint the owner's chip (relics only for now)
# before its effects' VFX, so a relic proc reads as cause -> effect.
func _fire_run_level(event: GameEvent) -> void:
	var persp := event.subject()
	if persp == null:
		return
	var ctx := _event_ctx(event, persp)
	for grp: Dictionary in EffectSystem.trigger_global_grouped(event, ctx):
		var rres: Array = grp["results"]
		if rres.is_empty():
			continue
		if str(grp["owner_kind"]) == "relic" and _relic_tray != null:
			_relic_tray.glint(str(grp["owner_id"]))
			await get_tree().create_timer(RELIC_CUE_LEAD).timeout
		await _animator.show_effect_results(rres, persp, "", false)


# BROADCASTS one event to the whole board: the participants first (the origin fires even when
# it is dead-but-on-board — a dying unit's own death effects), then every other alive unit as
# a watcher, then the run-level tier once. Any watcher a proc kills goes through the normal
# death path (itself a broadcast). Legacy content is self-gated by its parsed resolver
# conditions, so only participants ever produce results from it — bystander watching is the
# new capability this opens (e.g. "whenever a darkness pawn dies…" on a fielded card).
# Fires the `kill` event for a just-dead unit, immediately before its `death` — reading the
# provenance the Resolver stamped at the fatal blow (CardInstance.killed_by_*). `kill` names
# the killer (a unit for attacks; the cause id, e.g. "poison", otherwise) so "when I kill" and
# "when a unit dies from poison" are authorable; `death` stays the corpse's own perspective.
# A death with no recorded cause (killed_by_channel == "") fires `death` only.
func _emit_kill(corpse: CardInstance) -> void:
	if corpse.killed_by_channel == &"":
		return
	await _broadcast(GameEvent.kill(corpse.killed_by_unit, corpse,
			corpse.killed_by_channel, corpse.killed_by_cause))


func _broadcast(event: GameEvent, run_level: bool = true) -> void:
	var holders: Array = []
	if event.origin != null:
		holders.append(event.origin)
	if event.destination != null and not holders.has(event.destination):
		holders.append(event.destination)
	for u: CardInstance in _board.get_all_units():
		if u.is_alive() and not holders.has(u):
			holders.append(u)
	for holder: CardInstance in holders:
		var was_alive := holder.is_alive()
		await _fire(event, holder)
		# Swept only if this broadcast's procs killed it; a participant that ENTERED dead (the
		# struck unit after a lethal hit) is the call site's death to handle, not ours.
		if was_alive and not holder.is_alive() and event.id != &"death":
			await _emit_kill(holder)
			await _broadcast(GameEvent.make(&"death", holder))
			var ui := _board.get_card_ui(holder)
			if ui != null:
				await _vfx.play(VFXEvent.death(ui))
			_board.remove_card(holder)
	if run_level:
		await _fire_run_level(event)


# The entry point for a combat PHASE moment (turn boundaries, a unit's activation): fans the
# moment to every alive holder, then runs the decay tier. A phase moment with no subject is
# each holder's OWN moment (the event fans per-holder, origin = the holder), so "everyone's
# turn-end effects fire" stays true; a subject moment (activation) is one event about that
# unit which every holder may watch. Two ordered tiers:
#   1. Effects PROC — each holder's resolver decides if it reacts; a holder a proc kills is
#      swept through the normal death path.
#   2. Statuses DECAY — self-scoped: a subject event decays only the subject's statuses; a
#      phase event decays everyone's. A second tier so all effects land first.
func _resolve_event(event_id: StringName, subject: CardInstance = null) -> void:
	var units := _board.get_all_units()
	for holder: CardInstance in units:
		if not holder.is_alive():
			continue
		var ev := GameEvent.make(event_id, subject if subject != null else holder)
		# Per-holder fan-out: no run-level tier here (phase moments never fed it, and firing it
		# per holder would multiply it).
		await _fire(ev, holder)
		if not holder.is_alive():
			await _emit_kill(holder)
			await _broadcast(GameEvent.make(&"death", holder))
			var ui := _board.get_card_ui(holder)
			if ui != null:
				await _vfx.play(VFXEvent.death(ui))
			_board.remove_card(holder)
	for holder: CardInstance in units:
		if subject == null or subject == holder:
			StatusEngine.advance(holder, event_id)
	_board.cleanup_effect_deaths()
	_board.refresh()


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
	# A practice (Combat Gym) fight leaves no footprint: no rewards, no king-damage carry, no
	# map advance, no save, and defeat does NOT end the run — straight back to the gym.
	if enc != null and enc.practice:
		GameData.current_encounter = null
		Nav.goto("res://scenes/combat_gym.tscn")
		return
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
		if is_boss:
			Nav.goto("res://scenes/map.tscn")
		else:
			Nav.goto("res://scenes/reward_screen.tscn")
	else:
		if enc != null:
			enc.outcome = EncounterData.Outcome.LOSE
		# Defeat ends the run (meta-progression kept) and shows the Run Over screen.
		GameData.end_run()
		Nav.goto("res://scenes/run_over.tscn")


# ── Board event handlers ───────────────────────────────────────────────────────

func _on_board_unit_placed(inst: CardInstance, card_ui: CardUI, from_hand: bool, cost: int, results: Array) -> void:
	if from_hand:
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
	holder.attack_exhausted = true
	_highlight_building(holder, false)
	var holder_ui := _board.get_card_ui(holder)
	if holder_ui != null:
		holder_ui.set_exhausted(true)
	_hand.prune_tapped(holder)


# ── Autocast (armed ability fired by dragging the holder onto a target) ─────────

# The drop passed the eligibility gate (SlotUI.autocast_check → SpellCaster.autocast_drop_ok);
# hand it to the caster, which re-validates and emits ability_autocast for payment below.
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
	if _spell_caster.is_targeting():
		return  # spell_caster handles via its own slot_pressed connection
	if _phase != Phase.PLAYER_PLACE:
		return
	var occupant := slot.get_card()
	if occupant != null:
		# Clicking any fielded unit — either side — makes it the inspected card: the hand row
		# shows its description and abilities (see Hand.set_inspected) instead of anything
		# placement-related.
		_hand.deselect()
		_hand.set_inspected(occupant.card_instance)
		return
	var card := _hand.selected()
	if card == null:
		return
	if not _board.can_place_from_hand(card):
		# When the block is the mana pool, say so: the gauge flickers "present but empty".
		if card.card_instance.get_attribute("cost") > _player_side.mana:
			Vfx.play("mana_insufficient_flicker", _mana_chunks_box)
		return
	_hand.deselect()
	_board.do_place_unit(slot, card)


# ── Spell phase bridging ───────────────────────────────────────────────────────

func _on_targeting_started() -> void:
	Sfx.play("spell_targeting")
	_phase = Phase.TARGETING
	_set_placement_input(false)
	_refresh_done_btn()


func _on_targeting_ended() -> void:
	_phase = Phase.PLAYER_PLACE
	_set_placement_input(true)
	_refresh_done_btn()


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
		+ actions.custom_minimum_size.x + 2.0 * 12.0

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
	UIScale.tip(strip, "Relics")
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

	_relic_tray = RelicTray.new()
	_relic_tray.vertical = true
	_relic_tray.interactive = false   # info-only: tapping a chip opens its detail overlay
									   # (the touch reading path), but never offers Discard
	pad.add_child(_relic_tray)
	return strip


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
	UIScale.tip(gauge, "Mana")
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
	tag.text = "MANA"
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

	# Battle-speed toggle — cycles the BATTLE_SPEEDS percentages, applied live as
	# Engine.time_scale — thin, beside the debug ✕ (which fixes the row's height).
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	col.add_child(top_row)

	_speed_btn = ScreenUI.action_button("", _on_speed_pressed, Vector2.ZERO, 26 if compact else 20)
	_speed_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	_speed_btn.size_flags_vertical = SIZE_EXPAND_FILL
	top_row.add_child(_speed_btn)
	_refresh_speed_btn()

	# The ✕ normally fixes this row's height — pin the height explicitly so the layout stays
	# identical when the ✕ is absent (non-debug launches).
	top_row.custom_minimum_size.y = ScreenUI.BUTTON_HEIGHT_COMPACT - 16.0
	if DebugConfig.enabled():
		var debug_close := ScreenUI.close_button(_handle_combat_end, true)
		UIScale.tip(debug_close, "Debug: end combat")
		top_row.add_child(debug_close)

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
# not persisted, so the next fight starts back at 100%.
func _on_speed_pressed() -> void:
	var i := BATTLE_SPEEDS.find(_battle_speed)
	_battle_speed = BATTLE_SPEEDS[(i + 1) % BATTLE_SPEEDS.size()]
	Engine.time_scale = _battle_speed
	_refresh_speed_btn()


func _refresh_speed_btn() -> void:
	if _speed_btn:
		_speed_btn.text = "%d%%" % roundi(_battle_speed * 100.0)


func _refresh_done_btn() -> void:
	if _done_btn == null or _done_label == null:
		return
	match _phase:
		Phase.PLAYER_PLACE:
			_done_label.text   = "Ready"
			_done_btn.disabled = false
		Phase.CPU_PLACE:
			_done_label.text   = "CPU\nplacing…"
			_done_btn.disabled = true
		Phase.COMBAT:
			_done_label.text   = "Battle…"
			_done_btn.disabled = true
		Phase.TARGETING:
			_done_label.text   = "Select\na target…"
			_done_btn.disabled = true
	# The caption is a child Label, outside the button's own disabled styling — dim it manually.
	_done_label.modulate.a = 0.55 if _done_btn.disabled else 1.0


# ── Placement input gating ───────────────────────────────────────────────────────

# The hand owns its own cards/tokens; here we only toggle the board-side units that
# can be repositioned during placement.
func _set_placement_input(enabled: bool) -> void:
	_hand.set_input_enabled(enabled)
	var filter := Control.MOUSE_FILTER_STOP if enabled else Control.MOUSE_FILTER_IGNORE
	for r in BoardData.ROWS:
		for c in BoardData.COLS:
			var p: CardUI = (_board.player_slots[r][c] as SlotUI).get_card()
			if p:
				p.mouse_filter = filter
