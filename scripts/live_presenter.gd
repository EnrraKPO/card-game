class_name LivePresenter
extends CombatPresenter

# The live fight's presenter: the cascade call sites' presentation bodies, moved verbatim
# from combat.gd (COMBAT_DECOUPLING_REFACTOR.md Step 2). Same calls, same order, same
# awaits — a player must not be able to tell the seam exists.
#
# The scene-heavy death dressings (_king_fall's treasure chest + end-of-combat gate,
# _fade_out's card disposal) STAY on the Combat scene and are reached through Callables:
# they read and write combat's own state (_reward_chest, _chest_ready), and moving them
# would be a rewrite, not a relocation. Awaiting a coroutine through Callable.call is the
# codebase's proven pattern (see VFXPlayer.await_settled).

# A relic chip glinting in its tray — a cue with no library entry (moved from combat.gd,
# whose consumable-use path also reads it here).
const RELIC_CHIP_SPAN := 0.34

var _animator: CombatAnimator
var _tree: SceneTree
var _board: CombatBoard
var _relic_tray_get: Callable   # -> RelicTray; the tray is built after combat's wiring block
var _king_fall_cb: Callable     # Combat._king_fall
var _fade_out_cb: Callable      # Combat._fade_out


static func make(animator: CombatAnimator, tree: SceneTree, board: CombatBoard,
		relic_tray_get: Callable, king_fall_cb: Callable, fade_out_cb: Callable) -> LivePresenter:
	var p := LivePresenter.new()
	p._animator = animator
	p._tree = tree
	p._board = board
	p._relic_tray_get = relic_tray_get
	p._king_fall_cb = king_fall_cb
	p._fade_out_cb = fade_out_cb
	return p


func show_effect_results(results: Array, holder: CardInstance, status_id: String = "",
		cue: bool = true) -> void:
	# (Restrike beats deleted 2026-08-11 with the disavowed restrike mechanism.)
	if not results.is_empty():
		await _animator.show_effect_results(results, holder, status_id, cue)


func show_ground_results(procs: Array) -> void:
	# The cause first, board-wide and SIMULTANEOUS: every acting slot flares and every one of
	# its tabs glints in the same instant — the whole fire acts as one (the spread tier is
	# where flames act alone, one glint per roll). The flare rides each glint (see VFXPlayer's
	# arrival path): the slot acting and the tabs discharging are one event, and the flare's
	# sparks are what carry it to a covered slot. (The restrike second-burn beat is deleted
	# with the disavowed restrike mechanism, 2026-08-11.)
	var any_cue := false
	var base_results: Array = []
	for p: Dictionary in procs:
		var slot: BoardSlot = p["slot"]
		var slot_ui := _board.slot_ui_of(slot)
		if slot_ui != null:
			slot_ui.flare_ground(str(p["status_id"]))
			for pip: StatusPip in slot_ui.ground_pips_of(str(p["status_id"])):
				pip.flash_proc()
			any_cue = true
		base_results.append_array(p["results"])
	if any_cue:
		await beat(VFXPlayer.PIP_SPAN)
	# Then the effect: the results land together, exactly as any effect's do (damage
	# numbers, reticles) — one moment, not a slot-by-slot stagger. No holder card exists to
	# glint — the tabs above WERE the cue.
	await _animator.show_effect_results(base_results, null, "", false)


func show_spread_roll(carrier: StatusCarrier, status_id: String, stack_index: int,
		outcome: StringName, target: BoardSlot, arrival_results: Array = [],
		arrived_id: String = "") -> void:
	# The roll: the rolling pip glints — identically whatever comes of it (user call: the
	# ignition flare below is the only success signal). ONE vocabulary, either layer: a ground
	# tab on a slot, the card's own status badge on a unit.
	var slot := carrier as BoardSlot
	if slot != null:
		var slot_ui := _board.slot_ui_of(slot)
		if slot_ui != null:
			var pip := slot_ui.ground_pip_at(status_id, stack_index)
			if pip != null:
				pip.flash_proc()
	else:
		var unit := carrier as CardInstance
		if unit != null:
			var card := _board.get_card_ui(unit)
			if card != null:
				# A card badge shows the pile as ONE pip wearing a count, so every stack's roll
				# glints the same badge — the count beside it says how many are rolling.
				var upip := card.find_status_pip(status_id)
				if upip != null:
					upip.flash_proc()
	await beat(VFXPlayer.PIP_SPAN)
	if outcome == &"spread" and target != null:
		# The catch: the target's tab arrives WITH its flare — the slot catching light and the
		# tab appearing are one event (the ground arrival convention). The destination speaks
		# its own status (arrived_id): a unit's ablaze lands on the ground as burning.
		var caught := arrived_id if not arrived_id.is_empty() else status_id
		_board.refresh()
		var target_ui := _board.slot_ui_of(target)
		if target_ui != null:
			target_ui.flare_ground(caught)
			var fresh := target_ui.find_ground_pip(caught)   # newest tab (last match)
			if fresh != null:
				fresh.flash_applied()
		if not arrival_results.is_empty():
			# The arriving flame's touch on the occupant — damage numbers land with the catch,
			# through the same animator path as any effect's results.
			await _animator.show_effect_results(arrival_results, null, "", false)
		await beat(VFXPlayer.PIP_SPAN)
	elif outcome == &"fade":
		# The flame dying down: the glint above has played out; the re-render simply shows one
		# tab fewer. A shorter settle than a spread — nothing new arrived to look at.
		_board.refresh()
		await beat(VFXPlayer.PIP_SPAN * 0.5)


func relic_glint(owner_id: String) -> void:
	var tray: RelicTray = _relic_tray_get.call()
	if tray == null:
		return
	tray.glint(owner_id)
	await beat(RELIC_CHIP_SPAN)


func beat(seconds: float) -> void:
	await _tree.create_timer(Vfx.handoff(seconds)).timeout


func king_fall(inst: CardInstance) -> void:
	var corpse := _board.get_card_ui(inst)
	if corpse == null:
		return   # no card standing (already dropped) — nothing to dress
	await _king_fall_cb.call(inst, corpse)


func unit_fade(inst: CardInstance) -> void:
	var corpse := _board.get_card_ui(inst)
	if corpse == null:
		return   # no card standing (already dropped) — nothing to dress, no beat either
	# The fade plays on past the beat below — deliberately un-awaited; it disposes of the
	# card at its own end. The death BEAT is what the fight pauses for.
	_fade_out_cb.call(inst, corpse)
	await beat(VFXEffectDeath.FADE_DUR)


func board_refresh() -> void:
	_board.refresh()
