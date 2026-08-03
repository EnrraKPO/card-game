class_name CombatCascade
extends RefCounted

# The event cascade — THE rules of "what happens when an effect fires" (broadcast fan-out,
# per-holder dispatch, run-level procs, kill provenance, death and burial), re-homed verbatim
# from combat.gd methods (COMBAT_DECOUPLING_REFACTOR.md Step 3). Constructed with the two
# injected dependencies and nothing else:
#
#   world     — WHAT is: the cohesive combat state (see CombatWorld). The live game hands
#               the real one; a simulation hands a copy.
#   presenter — what it LOOKS like: every await routes through it (see CombatPresenter).
#               LivePresenter animates; the null base class returns immediately, making the
#               identical cascade synchronous.
#
# combat.gd keeps one-line delegating wrappers, so every call site (the attack loop, casts,
# the debug captain-kill) still reads as before. This file is a RELOCATION, not a rewrite —
# bodies match their combat.gd originals line for line wherever possible.

var world: CombatWorld
var presenter: CombatPresenter


static func make(p_world: CombatWorld, p_presenter: CombatPresenter) -> CombatCascade:
	var c := CombatCascade.new()
	c.world = p_world
	c.presenter = p_presenter
	return c


# Builds a dispatch context for one holder reacting to an event. The context carries the
# legacy single-subject view (SUBJECT/ATTACKER/ATTACK_TARGET targeting still read it); the
# activation decision itself lives entirely in each effect's TriggerResolver.
func event_ctx(event: GameEvent, holder: CardInstance) -> EffectContext:
	var ctx := world.make_context(holder)
	ctx.subject = event.subject()
	if event.id == &"attack" or event.id == &"crit":
		ctx.attack_target = event.destination   # attack/crit: subject is the striker, expose who got hit
	elif event.id == &"struck" or event.id == &"dodge":
		ctx.attacker = event.origin             # struck/dodge: the unit that struck (the dodger is the subject)
	return ctx


# The per-holder dispatch-and-present point: resolves `event` for `holder` in world context AND
# forwards the results to the presenter, inseparably — a dispatch path shows its results BY
# CONSTRUCTION, not by each call site remembering to forward them.
func fire(event: GameEvent, holder: CardInstance) -> void:
	var ctx := event_ctx(event, holder)
	# Walk the holder's containers one at a time — its card, then each status — cueing each before its
	# (container-blind) effects land: card glint / pip glint → that container's effect VFX.
	for group: Dictionary in EffectSystem.trigger_grouped(event, holder, ctx):
		var gres: Array = group["results"]
		var sid: String = group["status_id"]
		await presenter.show_effect_results(gres, holder, sid)


# Run-level (relic/upgrade) effects for an event, fired ONCE from the perspective of the
# event's subject, grouped by their owning item: glint the owner's chip (relics only for now)
# before its effects' VFX, so a relic proc reads as cause -> effect.
func fire_run_level(event: GameEvent) -> void:
	var persp := event.subject()
	if persp == null:
		return
	var ctx := event_ctx(event, persp)
	for grp: Dictionary in EffectSystem.trigger_global_grouped(event, ctx):
		var rres: Array = grp["results"]
		if rres.is_empty():
			continue
		if str(grp["owner_kind"]) == "relic":
			await presenter.relic_glint(str(grp["owner_id"]))
		await presenter.show_effect_results(rres, persp, "", false)


# Fires the `kill` event for a just-dead unit, immediately before its `death` — reading the
# provenance the Resolver stamped at the fatal blow (CardInstance.killed_by_*). `kill` names
# the killer (a unit for attacks; the cause id, e.g. "poison", otherwise) so "when I kill" and
# "when a unit dies from poison" are authorable; `death` stays the corpse's own perspective.
# A death with no recorded cause (killed_by_channel == "") fires `death` only.
func emit_kill(corpse: CardInstance) -> void:
	if corpse.killed_by_channel == &"":
		return
	await broadcast(GameEvent.kill(corpse.killed_by_unit, corpse,
			corpse.killed_by_channel, corpse.killed_by_cause))


# BROADCASTS one event to the whole board: the participants first (the origin fires even when
# it is dead-but-on-board — a dying unit's own death effects), then every other alive unit as
# a watcher, then the run-level tier once. Any watcher a proc kills goes through the normal
# death path (itself a broadcast). Legacy content is self-gated by its parsed resolver
# conditions, so only participants ever produce results from it — bystander watching is the
# new capability this opens (e.g. "whenever a darkness pawn dies…" on a fielded card).
func broadcast(event: GameEvent, run_level: bool = true) -> void:
	var holders: Array = []
	if event.origin != null:
		holders.append(event.origin)
	if event.destination != null and not holders.has(event.destination):
		holders.append(event.destination)
	for u: CardInstance in world.get_all_units():
		if u.is_alive() and not holders.has(u):
			holders.append(u)
	for holder: CardInstance in holders:
		var was_alive := holder.is_alive()
		await fire(event, holder)
		# Swept only if this broadcast's procs killed it; a participant that ENTERED dead (the
		# struck unit after a lethal hit) is the call site's death to handle, not ours.
		if was_alive and not holder.is_alive() and event.id != &"death":
			await emit_kill(holder)
			await broadcast(GameEvent.make(&"death", holder))
			await bury(holder)
	if run_level:
		await fire_run_level(event)


# The entry point for a combat PHASE moment (turn boundaries, a unit's activation): fans the
# moment to every alive holder, then runs the decay tier. A phase moment with no subject is
# each holder's OWN moment (the event fans per-holder, origin = the holder), so "everyone's
# turn-end effects fire" stays true; a subject moment (activation) is one event about that
# unit which every holder may watch. Two ordered tiers:
#   1. Effects PROC — each holder's resolver decides if it reacts; a holder a proc kills is
#      swept through the normal death path.
#   2. Statuses DECAY — self-scoped: a subject event decays only the subject's statuses; a
#      phase event decays everyone's. A second tier so all effects land first.
func resolve_event(event_id: StringName, subject: CardInstance = null) -> void:
	var units := world.get_all_units()
	for holder: CardInstance in units:
		if not holder.is_alive():
			continue
		var ev := GameEvent.make(event_id, subject if subject != null else holder)
		# Per-holder fan-out: no run-level tier here (phase moments never fed it, and firing it
		# per holder would multiply it).
		await fire(ev, holder)
		if not holder.is_alive():
			await emit_kill(holder)
			await broadcast(GameEvent.make(&"death", holder))
			await bury(holder)
	for holder: CardInstance in units:
		if subject == null or subject == holder:
			StatusEngine.advance(holder, event_id)
	# ── The GROUND layer (SLOT_LAYER_DESIGN.md §4.4): after the unit tiers, slot statuses
	# fire HOLDERLESS then decay — the same two-tier order, fed through the same dispatch
	# pipeline (a caller loop, not a second one). Subject-scoped moments skip slots entirely
	# (a slot is never a subject in this build). Units a slot proc kills are swept by the
	# cleanup below, the same silent path as any other bystander an effect kills. Results
	# are deliberately unpresented — no cue machinery for slot containers yet (§6); the
	# world state changes and board_refresh shows the aftermath.
	if subject == null:
		var ground := world.active_slots()
		for slot: BoardSlot in ground:
			var gctx := world.make_context(null)
			gctx.owner_anchor = slot.side   # the ground inherits the half it sits on
			gctx.anchor_side = slot.side
			gctx.anchor_row = slot.row
			gctx.anchor_col = slot.col
			var groups := EffectSystem.trigger_carrier_grouped(GameEvent.make(event_id, null), slot, gctx)
			# Ground procs present through the same dispatch-shows-its-results contract as
			# units (pip glint, then the targets' cues), and narrate into the combat log —
			# the tint/pip may have no witnesses in a headless run, the log always does.
			for grp: Dictionary in groups:
				for res: Dictionary in grp["results"]:
					var victim := res.get("target") as CardInstance
					CombatLog.note("ground", "slot (%s r%d c%d) %s: %s %d on %s" % [
							"player" if slot.side == 0 else "enemy", slot.row, slot.col,
							str(grp["status_id"]), str(res.get("attribute", "?")),
							int(res.get("delta", 0)),
							"?" if victim == null or victim.data == null else str(victim.data.id)])
				await presenter.show_ground_results(slot, str(grp["status_id"]), grp["results"])
		for slot: BoardSlot in ground:
			StatusEngine.advance(slot, event_id)
	world.cleanup_deaths()
	presenter.board_refresh()


# The LOGIC half of a death: the unit leaves play this instant (world.retire — which also
# pays whatever a death is owed, through the world's unit_retired wire), then the presenter
# dresses the departure. An enemy King does not die like a unit — it FALLS, and leaves the
# fight's reward behind where it stood; a hypothetical world (rewards_live false) has no
# reward to leave, so its kings get the plain send-off like everyone else.
func bury(inst: CardInstance) -> void:
	world.retire(inst)
	if inst.owner == 1 and inst.data != null and inst.data.is_king and world.rewards_live:
		await presenter.king_fall(inst)
		return
	# A death is a BEAT like any other, handed off through the overlap dial: at Flowing combat
	# carries on while the corpse is still fading, at Step by step it waits the fade out in full.
	await presenter.unit_fade(inst)
