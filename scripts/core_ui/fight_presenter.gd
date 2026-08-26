class_name FightPresenter
extends PresentationOutlet

# The live world's presenter behind the presentation outlet (Mutation §10, §11 + A12) —
# the strike presentation's reference shape (docs/planning/RULINGS.html R13): everything
# arrives through the outlet's stream, the presenter builds one VFXEvent per cue and hands
# it to the salvaged VFXPlayer, and the flow beats — carrying the acting holder per A12 —
# play the cause→effect read the old combat had: the source's approach (lunge / bolt /
# glint) leads, the recipients wear the target marks, the held procedure cues burst at the
# contact, and the attacker withdraws under the victim's suffering.
#
# The pause contract (MSD §10): procedure cues arriving while paused queue in arrival
# order; the conductor unpauses at the contact, and the held set plays as one burst — a
# multi-target payload reads as simultaneous, exactly as the old resolution walk did.

var _screen: FightScreen = null
var _paused: bool = false
var _held: Array[Array] = []
# The lunge's in-flight furniture, alive from the windup to the conclusion: the attacker's
# ghost, its concealed original, and where home is.
var _ghost: CardUI = null
var _ghost_source: CardUI = null
var _ghost_home: Vector2 = Vector2.ZERO
# The settle discipline (the old _await_settled, in presenter form): one retreat tween per
# source card, awaited before that SAME source may open a new lunge — a retaliation can
# begin while the prior ghost is still gliding home, and without the wait the earlier
# retreat's teardown pops the original back to full alpha mid-swing.
var _retreats: Dictionary = {}


func _init(screen: FightScreen) -> void:
	_screen = screen


func cue(visual: StringName, recipient: GameEntity, magnitude: float,
		variant: StringName = &"") -> void:
	if _paused:
		_held.append([visual, recipient, magnitude, variant])
	else:
		_screen.play_cue(visual, recipient, magnitude, variant)


func pause() -> void:
	_paused = true


func unpause() -> void:
	_paused = false
	for held: Array in _held:
		_screen.play_cue(held[0], held[1], held[2], held[3])
	_held.clear()


# The windup: the cause half leads (the old choreography, keyed by the effect's authored
# windup name — glint flares the source, bolt flies source→victim, lunge sends the ghost
# in), and every recipient wears the tinted target reticle that leads its hit.
func windup(visual: StringName, source: GameEntity, recipients: Array[GameEntity]) -> void:
	# The acting fact for the turn-order strip's gold entry (see FightScreen.acting):
	# an AUTHORED windup names its actor's moment; machinery's unnamed beats name none.
	if visual != &"" and source is Unit:
		_screen.acting = source as Unit
	_screen.refresh()
	# Marks lead only AUTHORED windups: every delivery beats through here — the round
	# machinery included (untap's recipients are the whole board) — and an unnamed windup
	# is machinery's, not a show (the same over-broadcast the contact shake had).
	if visual != &"":
		for recipient: GameEntity in recipients:
			_screen.play_beat_mark(recipient)
	# The source resolves through the one surface lookup (R14) — the stand-in override
	# outranks — so a holder that stands on screen as something other than a card (a
	# status's pip, a relic's chip) gets its announce too.
	var surface: Control = _screen.surface_of(source)
	if surface == null:
		# The old yank guard: a choreography whose actor has no surface on screen SKIPS
		# its show outright — the delivery still resolves; rules never depend on the
		# show. A side-held effect lands its cues without an approach.
		return
	if not (surface is CardUI):
		# A non-card holder announces with its kind's own show, whole from the old tree —
		# the pip's proc discharge, the relic chip's glint — under ANY authored windup
		# name (a pip cannot lunge; what it says is "I fired"). The unnamed windup stays
		# machinery's, silent, exactly as below.
		if visual == &"":
			return
		# The announce holds for its span — the old rule's named exceptions: cues drawn
		# by somebody else, with no library entry to read from (PIP_SPAN / CHIP_SPAN),
		# released at the handoff like every other beat.
		if surface is StatusPip:
			(surface as StatusPip).flash_proc()
			await _screen.beat(&"", [], Vfx.handoff(VFXPlayer.PIP_SPAN))
		elif _screen.relic_tray() != null:
			_screen.relic_tray().glint_chip(surface)
			await _screen.beat(&"", [], Vfx.handoff(VFXPlayer.CHIP_SPAN))
		return
	var source_ui: CardUI = surface as CardUI
	match visual:
		&"glint":
			await _screen.vfx().play(VFXEvent.source_trigger(source_ui))
		&"bolt":
			var bolt_target: CardUI = _screen.card_of(recipients[0]) \
					if not recipients.is_empty() else null
			if bolt_target != null:
				# show_impact false: the strike's damage cues carry the numbers.
				await _screen.vfx().play(VFXEvent.projectile(source_ui, bolt_target, 0,
						Color(0.65, 0.9, 1.0), VFXEvent.Projectile.BOLT, false))
		&"lunge":
			await _lunge(source_ui, _screen.card_of(recipients[0])
					if not recipients.is_empty() else null)
		_:
			# A windup with no authored choreography shows nothing and HOLDS nothing —
			# only an actual show may spend the player's time (authoring the look is what
			# buys the beat back).
			pass


# The old lunge whole: overshoot PAST the attack position along the approach line so the
# rebound retraces the exact vector the lunge came in on — a real recoil off the hit. The
# original conceals while its ghost swings; the swing arc reads over the motion.
func _lunge(source_ui: CardUI, target_ui: CardUI) -> void:
	if target_ui == null or not is_instance_valid(target_ui):
		return
	# A unit must be standing still before it can start another move (the old settle rule):
	# its own prior retreat finishes — and its teardown restores the original — first.
	var prior: Tween = _retreats.get(source_ui)
	if prior != null and prior.is_valid() and prior.is_running():
		await prior.finished
	var a_home: Vector2 = source_ui.global_position
	var gap := 12.0
	# The approach side keys on ALLEGIANCE, as the old geometry did: the player strikes
	# from the target's left, the enemy from its right — the armies' facing. The card's
	# housing slot says whose half the attacker stands in.
	var player_attacks: bool = source_ui.get_parent() is SlotUI \
			and (source_ui.get_parent() as SlotUI).own_side
	var beside_x: float = (target_ui.global_position.x - source_ui.size.x - gap) \
			if player_attacks \
			else (target_ui.global_position.x + target_ui.size.x + gap)
	var beside := Vector2(beside_x, target_ui.global_position.y)
	var overshoot: Vector2 = beside + (beside - a_home).normalized() * (source_ui.size.x * 0.3)
	_ghost = _screen.animator().spawn_ghost(source_ui)
	_ghost_source = source_ui
	_ghost_home = a_home
	source_ui.modulate.a = 0.0   # the ghost IS the attacker while the swing lasts
	Vfx.play("attack_swing_arc", _ghost)   # the swing reads over the lunge, concurrent
	await _screen.animator().play_lunge(_ghost, overshoot)
	await _screen.animator().play_rebound(_ghost, beside)


# The contact: the board re-reads and the held procedure cues burst here, as one
# simultaneous read (the pause contract) — paced the old way: each cue is its own
# concurrent sub-sequence that awaits its show to the show's handoff, sharing the old
# `remaining` counter box, and the beat drains the box before the flow moves on — the
# burst reads simultaneous, the tails keep playing under whatever comes next. The impact
# shake does NOT live here — a contact fires for EVERY delivery, the round machinery's
# included (the untap rule's recipients are the whole board, and shaking them read as a
# board-wide vibration at the turn boundary); the shake belongs to the DAMAGE moment, on
# the struck card, where the old solution kept it (see FightScreen.play_cue).
func contact(_visual: StringName, _source: GameEntity,
		_recipients: Array[GameEntity]) -> void:
	_screen.refresh()
	if _held.is_empty():
		return
	var remaining := [0]
	for held: Array in _held:
		remaining[0] += 1
		_burst_one(held, remaining)
	_held.clear()
	while remaining[0] > 0:
		if not _screen.is_inside_tree():
			return
		await _screen.get_tree().process_frame


# One held cue's slice of the burst, run concurrently with its siblings (the old
# _play_target shape): awaits its own show, ticks the shared counter down on completion.
func _burst_one(held: Array, remaining: Array) -> void:
	await _screen.play_cue(held[0], held[1], held[2], held[3])
	remaining[0] -= 1


# The conclusion: the attacker withdraws — the retreat STARTS and the flow moves on under
# it (the old rule: standing around waiting for the victim to finish reacting is what made
# a strike read as a stall); the ghost frees and the original returns at the glide's end.
func conclude(_visual: StringName, _source: GameEntity) -> void:
	# The actor's moment closes with its conclusion — only its own (an overlapping later
	# windup has already taken the fact, and must not be cleared by the earlier retreat).
	if _screen.acting != null and _screen.acting == _source:
		_screen.acting = null
	# The only hold here is the retreat's own handoff — a conclusion without a show in
	# flight spends no time at all.
	var hold := 0.0
	if _ghost != null and is_instance_valid(_ghost):
		var ghost: CardUI = _ghost
		var source_ui: CardUI = _ghost_source
		var retreat: Tween = _screen.animator().start_retreat(ghost, _ghost_home)
		if source_ui != null:
			_retreats[source_ui] = retreat
		retreat.finished.connect(func() -> void:
			if is_instance_valid(source_ui):
				source_ui.modulate.a = 1.0
				_retreats.erase(source_ui)
			if is_instance_valid(ghost):
				ghost.queue_free())
		# The withdrawal paces through the player's overlap dial, as the old conclude did.
		hold = Vfx.handoff(CombatAnimator.RETREAT_DUR)
	_ghost = null
	_ghost_source = null
	if hold > 0.0:
		await _screen.beat(&"", [], hold)
	_screen.refresh()
