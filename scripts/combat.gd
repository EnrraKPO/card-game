extends Control

const HUD_HEIGHT := 72.0

# Selectable battle speeds the HUD toggle cycles through (applied as Engine.time_scale). Shown as
# percentages; every fight starts at 100% (1.0) — the dial is per-combat, not remembered.
const BATTLE_SPEEDS: Array[float] = [0.5, 1.0, 1.5, 2.0]

# Beat between a shield absorbing part of a hit and the bleed-through HP damage landing, so the
# shield reads as taking the blow first (scaled by battle speed like every other combat beat).
const SHIELD_LEAD := 0.14

enum Phase { CPU_PLACE, PLAYER_PLACE, COMBAT, TARGETING }

var _phase: Phase = Phase.CPU_PLACE
var _mana: int    = 0
var _max_mana: int = 0
var _enemy_mana: int = 0
var _turn: int    = 0

var _enemy_hand: Array = []       # Array[CardInstance]
var _enemy_draw_pile: Array = []  # Array[CardInstance]

var _turn_label: Label
var _mana_label: Label
var _done_btn: Button
var _speed_btn: Button
var _battle_speed: float = 1.0   # 100%; reset each combat, cycled by the HUD dial

var _hand: Hand
var _board: CombatBoard
var _animator: CombatAnimator
var _spell_caster: SpellCaster
var _vfx: VFXPlayer

# While a melee attacker is lunging, its real card is hidden and a ghost duplicate does the
# travelling. This maps such an attacker → its ghost so the attacker's own VFX (the on-attack
# glint / self-buff) plays on the card the player is actually watching, not the hidden origin one.
var _ghost_ui: Dictionary = {}   # CardInstance -> CardUI


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	Nav.clear_back()   # mid-fight — the OS back gesture stays inert so it can't quit the app
	_battle_speed = 1.0                  # every fight starts at 100%
	Engine.time_scale = _battle_speed

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
	_board.is_hand_card = func(cu: CardUI) -> bool: return _hand.contains(cu)
	_board.get_mana     = func() -> int:            return _mana

	var _get_card_ui: Callable = func(inst: CardInstance) -> CardUI:
		var ghost: CardUI = _ghost_ui.get(inst)
		if ghost != null and is_instance_valid(ghost):
			return ghost
		return _board.get_card_ui(inst)
	_vfx.setup(self, _get_card_ui)
	_animator.setup(self, _get_card_ui, _vfx)

	_spell_caster.setup(_board, _animator, func() -> int: return _mana)
	_hand.wire_spell_card = _spell_caster.wire_spell_card
	_hand.token_hovered.connect(_highlight_building)

	_board.unit_placed.connect(_on_board_unit_placed)
	_board.slot_pressed.connect(_on_board_slot_pressed)
	_spell_caster.targeting_started.connect(_on_targeting_started)
	_spell_caster.targeting_ended.connect(_on_targeting_ended)
	_spell_caster.spell_consumed.connect(_on_spell_consumed)

	_hand.populate_draw_pile(GameData.current_run.deck)
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
	_hand.draw_initial()
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


# ── Enemy deck / hand ──────────────────────────────────────────────────────────

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
			_enemy_draw_pile.append(inst)
	var opening := mini(4, _enemy_draw_pile.size())
	for i in opening:
		_enemy_hand.append(_enemy_draw_pile[i])
	_enemy_draw_pile = _enemy_draw_pile.slice(opening)


func _enemy_draw_one() -> void:
	if _enemy_draw_pile.is_empty():
		return
	_enemy_hand.append(_enemy_draw_pile[0])
	_enemy_draw_pile = _enemy_draw_pile.slice(1)


# ── Round flow ─────────────────────────────────────────────────────────────────

func _begin_round() -> void:
	_turn      += 1
	# Every number resolves through GameData.value: the player gets the upgraded values, the
	# enemy reads the raw registry defaults so player upgrades never buff the CPU.
	# Ramp climbs to the mana.max ceiling (turn-1 start is mana.initial); mana.per_turn is a
	# flat bonus stacked on top every turn (so it can exceed the soft cap).
	var ramp := GameData.value("mana.initial") if _turn == 1 else _turn
	_max_mana   = mini(ramp, GameData.value("mana.max")) + GameData.value("mana.per_turn")
	_mana       = _max_mana
	_enemy_mana = mini(_turn, int(GameAttributes.default_value("mana.max")))
	for _i in GameData.value("draw.per_turn"):
		_hand.draw_one()
	_enemy_draw_one()
	await _do_cpu_placement()
	_phase = Phase.PLAYER_PLACE
	_board.placement_enabled = true
	_set_placement_input(true)
	_reset_exhaustion()
	_hand.generate_tokens(_player_buildings())
	_refresh()


func _do_cpu_placement() -> void:
	_phase = Phase.CPU_PLACE
	_board.placement_enabled = false
	_set_placement_input(false)
	_refresh_done_btn()

	var ai: EnemyAI = EnemyAI.new()
	if GameData.current_encounter != null and GameData.current_encounter.ai != null:
		ai = GameData.current_encounter.ai

	for action: Dictionary in ai.decide_actions(_enemy_hand, _board, _enemy_mana):
		await _execute_enemy_action(action)


# Carries out one planned CPU action. The AI guarantees each is legal in sequence
# (mana + slot occupancy), so this just applies the effect and animates it.
func _execute_enemy_action(action: Dictionary) -> void:
	match action["type"]:
		EnemyAI.Action.PLACE:
			var inst: CardInstance = action["inst"]
			_enemy_mana -= inst.data.cost
			_enemy_hand.erase(inst)
			var results := _board.place_enemy_card(inst, action["row"], action["col"])
			_vfx.play(VFXEvent.card_placed(_board.get_card_ui(inst)))
			await _animator.show_effect_results(results, inst)
		EnemyAI.Action.CAST:
			var inst: CardInstance = action["inst"]
			_enemy_mana -= inst.data.cost
			_enemy_hand.erase(inst)
			await _show_enemy_spell(inst, action["target"])
		EnemyAI.Action.GENERATE:
			var building: CardInstance = action["building"]
			var token := CardInstance.from_data(building.data.generated_card())
			_enemy_mana -= token.data.cost
			building.attack_exhausted = true
			var b_ui := _board.get_card_ui(building)
			if b_ui != null:
				b_ui.set_exhausted(true)
			var results := _board.place_enemy_card(token, action["row"], action["col"])
			_vfx.play(VFXEvent.card_placed(_board.get_card_ui(token)))
			await _animator.show_effect_results(results, token)
		EnemyAI.Action.MOVE:
			_board.move_enemy_card(action["inst"], action["row"], action["col"])
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
	for effect: Effect in inst.data.effects:
		if effect.trigger != Effect.Trigger.ON_PLAY:
			continue
		var ctx := EffectContext.make(inst, _board.player_grid, _board.enemy_grid)
		ctx.manual_target = target
		await _animator.show_effect_results(EffectSystem.apply_single(effect, inst, ctx), inst)
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


func _player_buildings() -> Array:
	var out: Array = []
	for inst: CardInstance in _board.get_all_units():
		if inst.owner == 0 and inst.data.is_building():
			out.append(inst)
	return out


# Toggles the gold targeting glow on a building's board slot, used to point out
# which rook a hovered/selected token belongs to.
func _highlight_building(inst: CardInstance, on: bool) -> void:
	if inst == null or inst.owner != 0 or inst.row < 0 or inst.col < 0:
		return
	(_board.player_slots[inst.row][inst.col] as SlotUI).set_targetable(on)


func _on_done_pressed() -> void:
	_hand.deselect()
	_hand.clear_tokens()
	_phase = Phase.COMBAT
	_board.placement_enabled = false
	_set_placement_input(false)
	_refresh()
	await _resolve_event(Effect.Trigger.ON_TURN_START)
	if _board.any_king_dead():
		_handle_combat_end()
		return
	await _run_combat()
	if _board.any_king_dead():
		_handle_combat_end()
		return
	await _resolve_event(Effect.Trigger.ON_TURN_END)
	if _board.any_king_dead():
		_handle_combat_end()
		return
	await get_tree().create_timer(0.8).timeout
	for inst: CardInstance in _board.get_all_units():
		var prev_shield := inst.current_shield
		inst.restore_shield()
		var gained := inst.current_shield - prev_shield
		if gained > 0:
			var shield_ui := _board.get_card_ui(inst)
			if shield_ui != null:
				shield_ui.refresh()   # show the restored shield badge as the glint points at it
				_vfx.play(VFXEvent.shield_restored(shield_ui, gained))
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
		await _resolve_event(Effect.Trigger.ON_ACTIVATE, attacker)
		if not attacker.is_alive():
			continue
		# A building that spent its attack generating a card sits this round out.
		if attacker.attack_exhausted:
			continue
		await _resolve_attack(attacker)


# Plays out a single attacker's strike: target lookup, delivery (melee lunge or ranged
# bolt), damage + triggered effects, and the target's death or survival.
func _resolve_attack(attacker: CardInstance) -> void:
	var target := _board.find_target(attacker)
	if target == null:
		return

	var a_card := _board.get_card_ui(attacker)
	var t_card := _board.get_card_ui(target)

	if attacker.data.ranged:
		# Ranged: hold position and fire a bolt; the hit lands when it arrives.
		await _vfx.play(VFXEvent.projectile(
			a_card, t_card, attacker.get_attribute("attack"),
			Color(0.65, 0.9, 1.0), VFXEvent.Projectile.BOLT, false))
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
		await _animator.play_lunge(ghost, overshoot)
		_animator.shake_card(t_card)               # impact shake at the apex, over the rebound
		await _animator.play_rebound(ghost, beside)
		await _apply_attack_damage(attacker, target, t_card)
		await _animator.play_retreat(ghost, a_home)
		_ghost_ui.erase(attacker)
		ghost.queue_free()
		a_card.modulate.a = 1.0

	if not target.is_alive():
		await _fire(Effect.Trigger.ON_DEATH, target)
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
	var dmg := attacker.get_attribute("attack")
	await _fire(Effect.Trigger.ON_ATTACK, attacker, null, target)
	var dmg_split := target.take_damage(dmg)
	await _fire(Effect.Trigger.ON_DAMAGE_TAKEN, target)
	# Shield reads FIRST: it takes the blow on its own badge (and only the badge — a held shield
	# leaves the card unwounded). When the hit also bleeds through to HP, a brief halt lets the
	# absorb land before the wound, so the shield is legible as the first thing that happened.
	if dmg_split.shield_absorbed > 0:
		_vfx.play(VFXEvent.shield_hit(t_card, dmg_split.shield_absorbed))
	if dmg_split.health_damage > 0:
		if dmg_split.shield_absorbed > 0:
			await get_tree().create_timer(SHIELD_LEAD).timeout
		_vfx.play(VFXEvent.health_damage(t_card, dmg_split.health_damage))


# The SINGLE dispatch-and-present point for a combat trigger: it resolves `event` for `holder` in
# board context AND forwards the results to the animator, inseparably. Routing every trigger through
# here is what makes resolution and its VFX impossible to drift apart — a dispatch path shows its
# results BY CONSTRUCTION, not by each call site remembering to forward them (the omission that made
# the status path silent). `subject` is the unit the event is about; it defaults to the holder (an
# actor reacting to its own action). `run_level` also fires run-level (upgrade/relic) effects once —
# true for per-actor events (attack/death), false for the per-holder status fan-out, where firing
# the run-level effects once per holder would multiply them.
func _fire(event: Effect.Trigger, holder: CardInstance, subject: CardInstance = null,
		atk_target: CardInstance = null, run_level: bool = true) -> void:
	var ctx := EffectContext.make(holder, _board.player_grid, _board.enemy_grid)
	ctx.subject = subject if subject != null else holder
	ctx.attack_target = atk_target   # lets an ON_ATTACK effect target the unit being struck
	# Walk the holder's containers one at a time — its card, then each status — cueing each before its
	# (container-blind) effects land: card glint / pip glint → that container's effect VFX.
	for group: Dictionary in EffectSystem.trigger_grouped(event, holder, ctx):
		var gres: Array = group["results"]
		var sid: String = group["status_id"]
		await _animator.show_effect_results(gres, holder, sid)
	# Run-level (relic/upgrade) effects have no on-board container to cue yet — play them un-cued.
	if run_level:
		var rl := EffectSystem.trigger_global(event, ctx)
		if not rl.is_empty():
			await _animator.show_effect_results(rl, holder, "", false)


# The single entry point for a combat MOMENT: combat BROADCASTS the event (with the `subject` — the
# unit it is about, or null for a subject-less phase moment like a turn boundary) and every holder on
# the board decides for itself whether it reacts. Two ordered tiers:
#   1. Effects PROC — the event fans to every holder; each of its effects (native + status) self-
#      selects via trigger + subject_filter (default SELF → only the subject's own effects fire, so
#      current content is unchanged). A holder a proc kills is swept through the normal death path.
#   2. Statuses DECAY — statuses progress, self-scoped: a subject event decays only the subject's
#      statuses; a phase event decays everyone's. Run as a second tier so all effects land first.
# Decay is just another reactor (same self gate), kept in its own tier purely for ordering. New
# per-moment lookups slot in here. Each holder's proc goes through _fire, so the status path shows
# its results through the same animator as every other trigger — no special path, no silent effects.
func _resolve_event(event: Effect.Trigger, subject: CardInstance = null) -> void:
	var units := _board.get_all_units()
	for holder: CardInstance in units:
		if not holder.is_alive():
			continue
		# Per-holder fan-out: don't fire the run-level effects here (they'd fire once per holder).
		await _fire(event, holder, subject, null, false)
		if not holder.is_alive():
			await _fire(Effect.Trigger.ON_DEATH, holder)
			var ui := _board.get_card_ui(holder)
			if ui != null:
				await _vfx.play(VFXEvent.death(ui))
			_board.remove_card(holder)
	for holder: CardInstance in units:
		if subject == null or subject == holder:
			StatusEngine.advance(holder, event)
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
		pk.apply_modifier("max_health", hp_bonus)
	pk.current_health = run.king_health()
	_board.refresh()


func _handle_combat_end() -> void:
	var player_won := _board.player_king_alive()
	var enc := GameData.current_encounter
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
			get_tree().change_scene_to_file("res://scenes/map.tscn")
		else:
			get_tree().change_scene_to_file("res://scenes/reward_screen.tscn")
	else:
		if enc != null:
			enc.outcome = EncounterData.Outcome.LOSE
		# Defeat ends the run (meta-progression kept) and shows the Run Over screen.
		GameData.end_run()
		get_tree().change_scene_to_file("res://scenes/run_over.tscn")


# ── Board event handlers ───────────────────────────────────────────────────────

func _on_board_unit_placed(inst: CardInstance, card_ui: CardUI, from_hand: bool, cost: int, results: Array) -> void:
	if from_hand:
		_mana -= cost
		if card_ui.is_generated:
			_consume_generated_token(card_ui)
		else:
			_hand.remove_card(card_ui)
		_refresh_mana()
	_vfx.play(VFXEvent.card_placed(card_ui))
	await _animator.show_effect_results(results, inst)


# A generated token was just played: tap its source rook (no attack this round)
# and turn the token into an ordinary board unit.
func _consume_generated_token(card_ui: CardUI) -> void:
	_hand.remove_token(card_ui)
	var rook: CardInstance = card_ui.card_instance.source_building
	if rook != null:
		rook.attack_exhausted = true
		_highlight_building(rook, false)
		var rook_ui := _board.get_card_ui(rook)
		if rook_ui != null:
			rook_ui.set_exhausted(true)
	card_ui.clear_generated()


func _on_board_slot_pressed(slot: SlotUI) -> void:
	if _spell_caster.is_targeting():
		return  # spell_caster handles via its own slot_pressed connection
	var card := _hand.selected()
	if _phase != Phase.PLAYER_PLACE or card == null:
		return
	if slot.get_card() != null:
		return
	if not _board.can_place_from_hand(card):
		return
	_hand.deselect()
	_board.do_place_unit(slot, card)


# ── Spell phase bridging ───────────────────────────────────────────────────────

func _on_targeting_started() -> void:
	_phase = Phase.TARGETING
	_set_placement_input(false)
	_refresh_done_btn()


func _on_targeting_ended() -> void:
	_phase = Phase.PLAYER_PLACE
	_set_placement_input(true)
	_refresh_done_btn()


func _on_spell_consumed(card_ui: CardUI, cost: int) -> void:
	_mana -= cost
	_hand.remove_card(card_ui)
	_refresh_mana()


# ── UI building ────────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Inset the whole stack off the screen edges so the top-bar buttons (notably "Done
	# placing", far right) and the hand stay clear of the touch-hostile borders. See
	# UIScale.safe_inset.
	var inset := UIScale.safe_inset()
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	root.offset_left = inset
	root.offset_top = inset
	root.offset_right = -inset
	root.offset_bottom = -inset
	add_child(root)

	_build_hud(root)

	var boards := HBoxContainer.new()
	boards.size_flags_vertical = SIZE_EXPAND_FILL
	boards.add_theme_constant_override("separation", 0)
	root.add_child(boards)

	_board.build_section(boards, true)
	boards.add_child(VSeparator.new())
	_board.build_section(boards, false)

	_hand.build_into(root)


func _build_hud(parent: VBoxContainer) -> void:
	var compact := UIScale.is_compact()
	var label_font := 30 if compact else 17

	var panel := PanelContainer.new()
	panel.custom_minimum_size.y = 124.0 if compact else HUD_HEIGHT
	parent.add_child(panel)

	var hbox := HBoxContainer.new()
	panel.add_child(hbox)
	hbox.add_child(RunHUD.new())

	# Read-only relic strip, inline in the top bar so the player can recall their relics mid-fight.
	var relic_tray := RelicTray.new()
	relic_tray.interactive = false
	hbox.add_child(relic_tray)

	_turn_label = Label.new()
	_turn_label.add_theme_font_size_override("font_size", label_font)
	_turn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_turn_label.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(_turn_label)

	_mana_label = Label.new()
	_mana_label.add_theme_font_size_override("font_size", label_font)
	_mana_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_mana_label.size_flags_horizontal = SIZE_EXPAND_FILL
	hbox.add_child(_mana_label)

	# Battle-speed toggle — cycles 1x → 2x → 4x, persisted and applied live as Engine.time_scale.
	_speed_btn = Button.new()
	_speed_btn.custom_minimum_size = Vector2(120 if compact else 76, 88 if compact else 0)
	_speed_btn.add_theme_font_size_override("font_size", 30 if compact else 16)
	_speed_btn.pressed.connect(_on_speed_pressed)
	hbox.add_child(_speed_btn)
	_refresh_speed_btn()

	# The key touch target — "Done placing". Make it big on compact.
	_done_btn = Button.new()
	_done_btn.custom_minimum_size = Vector2(320 if compact else 200, 88 if compact else 0)
	_done_btn.add_theme_font_size_override("font_size", 34 if compact else 18)
	_done_btn.pressed.connect(_on_done_pressed)
	hbox.add_child(_done_btn)

	var dbg_win := Button.new()
	dbg_win.text = "[debug] win"
	dbg_win.add_theme_font_size_override("font_size", 20 if compact else 13)
	dbg_win.modulate = Color(1.0, 0.65, 0.1)
	dbg_win.pressed.connect(_handle_combat_end)
	hbox.add_child(dbg_win)


# ── Display refresh ────────────────────────────────────────────────────────────

func _refresh() -> void:
	if _turn_label:
		_turn_label.text = "Turn %d" % _turn
	_refresh_mana()
	_board.refresh()
	_hand.refresh()
	_refresh_done_btn()


func _refresh_mana() -> void:
	if _mana_label:
		_mana_label.text = "Mana  %d / %d  " % [_mana, _max_mana]


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
	if _done_btn == null:
		return
	match _phase:
		Phase.PLAYER_PLACE:
			_done_btn.text     = "Done Placing"
			_done_btn.disabled = false
		Phase.CPU_PLACE:
			_done_btn.text     = "CPU is placing..."
			_done_btn.disabled = true
		Phase.COMBAT:
			_done_btn.text     = "Combat..."
			_done_btn.disabled = true
		Phase.TARGETING:
			_done_btn.text     = "Select a target..."
			_done_btn.disabled = true


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
