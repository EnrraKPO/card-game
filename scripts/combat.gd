extends Control

# Selectable battle speeds the HUD toggle cycles through (applied as Engine.time_scale). Shown as
# percentages; every fight starts at 100% (1.0) — the dial is per-combat, not remembered.
const BATTLE_SPEEDS: Array[float] = [0.5, 1.0, 1.5, 2.0]

# Beat between a shield absorbing part of a hit and the bleed-through HP damage landing, so the
# shield reads as taking the blow first (scaled by battle speed like every other combat beat).
const SHIELD_LEAD := 0.14
const RELIC_CUE_LEAD := 0.34   # let a firing relic's chip glint read before its effects' VFX
const BOARD_HALVES_GAP := 40.0   # the visual gulf between the player half and the enemy half

enum Phase { CPU_PLACE, PLAYER_PLACE, COMBAT, TARGETING }

var _phase: Phase = Phase.CPU_PLACE
var _mana: int    = 0
var _max_mana: int = 0
var _enemy_mana: int = 0
var _turn: int    = 0

var _enemy_hand: Array = []       # Array[CardInstance]
var _enemy_draw_pile: Array = []  # Array[CardInstance]

var _mana_label: Label              # current-mana number on the vertical gauge
var _mana_chunks_box: VBoxContainer  # one chunk per max-mana point; lit=available, dim=spent
var _relic_tray: RelicTray   # read-only relic strip in the header; a firing relic glints its chip
var _done_btn: Button        # the chunky vertical "Ready" button (right of the board)
var _speed_btn: Button
var _battle_speed: float = 1.0   # 100%; reset each combat, cycled by the HUD dial

var _board_row: HBoxContainer   # the two board halves; drives responsive slot sizing on resize

var _hand: Hand
var _board: CombatBoard
var _animator: CombatAnimator
var _spell_caster: SpellCaster
var _vfx: VFXPlayer

# While a melee attacker is lunging, its real card is hidden and a ghost duplicate does the
# travelling. This maps such an attacker → its ghost so the attacker's own VFX (the on-attack
# glint / self-buff) plays on the card the player is actually watching, not the hidden origin one.
var _ghost_ui: Dictionary = {}   # CardInstance -> CardUI


func get_chrome() -> Dictionary:
	return {"fields": [ScreenUI.Field.ACT, ScreenUI.Field.HP, ScreenUI.Field.GOLD,
		ScreenUI.Field.RELICS, ScreenUI.Field.EXP], "exit": _handle_combat_end,
		"back": Callable(), "debug_close": true}


# The relic strip is a live catalog field in the header; grab it here (once Shell has applied the
# chrome) to glint a firing relic's chip (see _fire) and make it read-only so it never eats combat
# input. The tray is now Shell's one persistent instance (see [[header-system]]) — Shell already
# reset interactive to true before this runs, so flipping it back to false here must also rebuild
# the chips (interactive is baked into each chip's tooltip/click-binding at refresh() time).
func on_chrome_applied(handles: Dictionary) -> void:
	_relic_tray = handles.get("fields", {}).get(ScreenUI.Field.RELICS)
	if _relic_tray != null:
		_relic_tray.interactive = false
		_relic_tray.refresh()


func _ready() -> void:
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
	# If any negated attacks are queued on this unit, consume one — this strike deals 0. We don't care
	# what queued it; the cause's own cue already fired. Each queued negation is honoured separately.
	if attacker.negate_next_attacks > 0:
		attacker.negate_next_attacks -= 1
		dmg = 0
	# Resolve the attack-driven decay NOW — right after the ON_ATTACK roll, BEFORE the strike's own
	# effects. A charge is spent per attack (hit or miss); doing it here means a Blind that an effect
	# applies in *reaction* to this attack (a relic blinding the attacker on hit, via ON_DAMAGE_TAKEN
	# below) lands afterwards and survives, instead of being eaten by this same attack.
	StatusEngine.advance(attacker, Effect.Trigger.ON_ATTACK)

	# The strike is PERFORMED either way — even a whiff still attacks, it just deals 0. So damage is
	# applied (0 on a miss) and ON_DAMAGE_TAKEN fires regardless, so on-attacked reactions (e.g. a
	# relic blinding the attacker) run whether or not it connected. Only the readout differs.
	var dmg_split := target.take_damage(dmg)
	await _fire(Effect.Trigger.ON_DAMAGE_TAKEN, target, null, null, attacker)
	if dmg <= 0:
		# A 0-damage strike (negated, or <=0 Attack) reads as "Miss" rather than a number.
		_vfx.play(VFXEvent.miss(t_card))
	else:
		# Shield reads FIRST: it takes the blow on its own badge (and only the badge — a held shield
		# leaves the card unwounded). When the hit also bleeds through to HP, a brief halt lets the
		# absorb land before the wound, so the shield is legible as the first thing that happened.
		if dmg_split.shield_absorbed > 0:
			_vfx.play(VFXEvent.shield_hit(t_card, dmg_split.shield_absorbed))
		if dmg_split.health_damage > 0:
			if dmg_split.shield_absorbed > 0:
				await get_tree().create_timer(SHIELD_LEAD).timeout
			_vfx.play(VFXEvent.health_damage(t_card, dmg_split.health_damage))
	_board.refresh()


# The SINGLE dispatch-and-present point for a combat trigger: it resolves `event` for `holder` in
# board context AND forwards the results to the animator, inseparably. Routing every trigger through
# here is what makes resolution and its VFX impossible to drift apart — a dispatch path shows its
# results BY CONSTRUCTION, not by each call site remembering to forward them (the omission that made
# the status path silent). `subject` is the unit the event is about; it defaults to the holder (an
# actor reacting to its own action). `run_level` also fires run-level (upgrade/relic) effects once —
# true for per-actor events (attack/death), false for the per-holder status fan-out, where firing
# the run-level effects once per holder would multiply them.
func _fire(event: Effect.Trigger, holder: CardInstance, subject: CardInstance = null,
		atk_target: CardInstance = null, attacker: CardInstance = null, run_level: bool = true) -> void:
	var ctx := EffectContext.make(holder, _board.player_grid, _board.enemy_grid)
	ctx.subject = subject if subject != null else holder
	ctx.attack_target = atk_target   # lets an ON_ATTACK effect target the unit being struck
	ctx.attacker = attacker          # lets an ON_DAMAGE_TAKEN effect target the unit that struck
	# Walk the holder's containers one at a time — its card, then each status — cueing each before its
	# (container-blind) effects land: card glint / pip glint → that container's effect VFX.
	for group: Dictionary in EffectSystem.trigger_grouped(event, holder, ctx):
		var gres: Array = group["results"]
		var sid: String = group["status_id"]
		await _animator.show_effect_results(gres, holder, sid)
	# Run-level (relic/upgrade) effects, grouped by their owning item: glint the owner's chip (relics
	# only for now) before its effects' VFX, so a relic proc reads as cause -> effect.
	if run_level:
		for grp: Dictionary in EffectSystem.trigger_global_grouped(event, ctx):
			var rres: Array = grp["results"]
			if rres.is_empty():
				continue
			if str(grp["owner_kind"]) == "relic" and _relic_tray != null:
				_relic_tray.glint(str(grp["owner_id"]))
				await get_tree().create_timer(RELIC_CUE_LEAD).timeout
			await _animator.show_effect_results(rres, holder, "", false)


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
		await _fire(event, holder, subject, null, null, false)
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

	# The header's HP field mirrors RunData, which only finalizes king_damage at combat end (see
	# _handle_combat_end) — wire it to the King's LIVE board health instead, so it ticks during the
	# fight. This bypasses RunData entirely mid-fight; the persisted value still only ever gets
	# written once, at combat end, unchanged from before.
	pk.health_changed.connect(_on_king_health_changed)


func _on_king_health_changed(current: int) -> void:
	var run := GameData.current_run
	if run != null:
		GameSignals.hp_changed.emit(current, run.king_max_health())


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
	# The shared header (Act/HP/Gold/Relics/EXP) is Shell chrome now, not this screen's concern —
	# see get_chrome(). This just builds the body: inset off the screen edges, holding the arena + hand.
	var inset := int(UIScale.safe_inset())
	var body := MarginContainer.new()
	body.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	body.add_theme_constant_override("margin_left", inset)
	body.add_theme_constant_override("margin_right", inset)
	body.add_theme_constant_override("margin_bottom", inset)
	body.add_theme_constant_override("margin_top", 14)
	add_child(body)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	body.add_child(col)

	# The arena row: mana gauge hugs the LEFT of the board, the two board halves fill the middle, and
	# the action column (speed + Ready) hugs the RIGHT. Gameplay controls live around the board they
	# act on. All three stretch to the same height, so the row reads as one balanced band.
	var arena := HBoxContainer.new()
	arena.size_flags_vertical = SIZE_EXPAND_FILL
	arena.add_theme_constant_override("separation", 18)
	col.add_child(arena)

	arena.add_child(_build_mana_gauge())

	_board_row = HBoxContainer.new()
	_board_row.size_flags_horizontal = SIZE_EXPAND_FILL
	_board_row.size_flags_vertical = SIZE_EXPAND_FILL
	_board_row.add_theme_constant_override("separation", int(BOARD_HALVES_GAP))
	arena.add_child(_board_row)

	_board.build_section(_board_row, true)
	_board.build_section(_board_row, false)

	arena.add_child(_build_action_column())

	_hand.build_into(col)

	# The board fills its area with the biggest cards that fit (recomputed on any resize), instead of
	# a fixed grid marooned in empty space.
	_board_row.resized.connect(_resize_board)
	call_deferred("_resize_board")


# The vertical mana gauge, hugging the LEFT of the board: one framed component with a "MANA" label
# in a header cell at the TOP, the chunk stack in the middle (one chunk per point of max mana —
# spent chunks dim, available ones lit, filling from the bottom), and the current/max count in a
# matching footer cell at the BOTTOM. Labels and chunks never overlap. _refresh_mana rebuilds the
# chunk count when max mana ramps and recolours them as mana is spent. Mana is gameplay state, so
# it sits by the board, not the header.
func _build_mana_gauge() -> Control:
	var compact := UIScale.is_compact()
	var gauge := Panel.new()
	gauge.custom_minimum_size.x = 122.0 if compact else 86.0
	gauge.size_flags_vertical = SIZE_EXPAND_FILL
	gauge.tooltip_text = "Mana"
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.05, 0.05, 0.09)
	track.set_corner_radius_all(12)
	track.set_border_width_all(2)
	track.border_color = Color(0.30, 0.32, 0.42)
	gauge.add_theme_stylebox_override("panel", track)

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	pad.add_theme_constant_override("margin_left", 6)
	pad.add_theme_constant_override("margin_right", 6)
	pad.add_theme_constant_override("margin_top", 6)
	pad.add_theme_constant_override("margin_bottom", 6)
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
	_mana_chunks_box.add_theme_constant_override("separation", 5)
	_mana_chunks_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_mana_chunks_box)

	col.add_child(_gauge_divider())

	# Footer cell: the current/max count, in a matching zone at the bottom (never over the chunks).
	_mana_label = Label.new()
	_mana_label.add_theme_font_size_override("font_size", 34 if compact else 26)
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
	sb.bg_color = Color(0.30, 0.32, 0.42)
	divider.add_theme_stylebox_override("panel", sb)
	return divider


# Colours for the mana chunks: lit = available, dim = spent (or not yet ramped into).
const MANA_LIT := Color(0.34, 0.60, 0.98)
const MANA_DIM := Color(0.15, 0.16, 0.23)


func _make_mana_chunk() -> Panel:
	var chunk := Panel.new()
	chunk.size_flags_vertical = SIZE_EXPAND_FILL
	chunk.custom_minimum_size.y = 8.0   # a floor so many chunks never collapse to nothing
	chunk.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return chunk


# The action column, hugging the RIGHT of the board: the big "Ready" button on top, with the
# battle-speed toggle tucked at the bottom. Both gameplay controls, kept by the board they drive.
func _build_action_column() -> Control:
	var compact := UIScale.is_compact()
	var col := VBoxContainer.new()
	col.custom_minimum_size.x = 240.0 if compact else 180.0
	col.add_theme_constant_override("separation", 14)

	# The key touch target — "Ready" — a chunky vertical button filling the top of the column.
	# Green, from the glossy handoff's own "Ready" palette entry.
	_done_btn = ScreenUI.action_button("", _on_done_pressed, Vector2.ZERO,
		44 if compact else 30, ScreenUI.CHROME_READY)
	_done_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	_done_btn.size_flags_vertical = SIZE_EXPAND_FILL
	_done_btn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_done_btn)
	_refresh_done_btn()

	# Battle-speed toggle — cycles 1x → 2x → 4x, applied live as Engine.time_scale — at the bottom.
	_speed_btn = ScreenUI.action_button("", _on_speed_pressed, Vector2.ZERO, 32 if compact else 20)
	_speed_btn.custom_minimum_size.y = 96.0 if compact else 56.0
	_speed_btn.size_flags_horizontal = SIZE_EXPAND_FILL
	col.add_child(_speed_btn)
	_refresh_speed_btn()
	return col


# Sizes every board slot to the largest card that fits the current board area (keeping the card
# aspect), so the two 4×3 halves fill the space with big, tappable cards and even gaps — instead of
# a fixed grid stranded in emptiness. Runs on any resize (window / form factor). Idempotent: bails
# when the target size is unchanged, so setting the slots can't feed back into the resized signal.
func _resize_board() -> void:
	if _board_row == null:
		return
	var area := _board_row.size
	if area.x < 1.0 or area.y < 1.0:
		return

	var cols := BoardData.COLS
	var rows := BoardData.ROWS
	var gap := float(BoardData.SLOT_GAP)
	# Width splits across the two halves (minus the gulf between them); each half holds `cols`.
	var half_w := (area.x - BOARD_HALVES_GAP) / 2.0
	var slot_w_by_width := (half_w - (cols - 1) * gap) / float(cols)
	var slot_w_by_height := ((area.y - (rows - 1) * gap) / float(rows)) / BoardData.SLOT_ASPECT
	var slot_w := floorf(minf(slot_w_by_width, slot_w_by_height))
	if slot_w < 1.0:
		return
	var slot_size := Vector2(slot_w, floorf(slot_w * BoardData.SLOT_ASPECT))

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
	_refresh_done_btn()


func _refresh_mana() -> void:
	if _mana_label:
		_mana_label.text = "%d/%d" % [_mana, _max_mana]
	if _mana_chunks_box == null:
		return

	# Rebuild the segment stack when max mana changes (it ramps up over the fight).
	var want := maxi(_max_mana, 0)
	if _mana_chunks_box.get_child_count() != want:
		for ch in _mana_chunks_box.get_children():
			_mana_chunks_box.remove_child(ch)
			ch.queue_free()
		for _i in want:
			_mana_chunks_box.add_child(_make_mana_chunk())

	# Light the bottom `_mana` chunks (available), dim the rest (spent / not yet ramped).
	var chunks := _mana_chunks_box.get_children()
	for idx in chunks.size():
		var from_bottom := chunks.size() - 1 - idx
		var sb := StyleBoxFlat.new()
		sb.bg_color = MANA_LIT if from_bottom < _mana else MANA_DIM
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
	if _done_btn == null:
		return
	match _phase:
		Phase.PLAYER_PLACE:
			_done_btn.text     = "Ready"
			_done_btn.disabled = false
		Phase.CPU_PLACE:
			_done_btn.text     = "CPU\nplacing…"
			_done_btn.disabled = true
		Phase.COMBAT:
			_done_btn.text     = "Battle…"
			_done_btn.disabled = true
		Phase.TARGETING:
			_done_btn.text     = "Select\na target…"
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
