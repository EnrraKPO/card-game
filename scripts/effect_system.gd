class_name EffectSystem
extends RefCounted


# Returns an Array of {target, attribute, delta} for each application that
# used the parameterised path. Custom-apply results are not included since
# the system cannot know what changed.

# Apply a single effect with a pre-built context (used for spell casting and
# unit abilities with MANUAL targeting already resolved into context.manual_target).
static func apply_single(effect: Effect, source: CardInstance, context: EffectContext) -> Array:
	return _run_effect(effect, source, context)


# Fires the triggered effects a unit carries for an event, grouped BY CONTAINER so the dispatcher can
# cue each container before its effects: the card's own (native) effects form one group (status_id
# ""), and each active status forms its own group (its magnitudes scaled by stack count). Resolution
# itself is container-blind — the container id is carried only so presentation can glint the right
# badge; it never touches target resolution. Returns Array of { "status_id": String, "results": [] }
# (only groups that produced results).
static func trigger_grouped(event: GameEvent, source: CardInstance, context: EffectContext) -> Array:
	var groups: Array = []
	if source == null or source.data == null:
		return groups
	var native: Array = []
	# The card's own effects, then the INNATE tier — rules every unit carries by being what
	# it is ("fire scorches the ground it strikes"), self-gated by their own trigger
	# conditions and dispatched exactly like card effects (see InnateEffects).
	for effect: Effect in source.data.effects + InnateEffects.all():
		# Only event-driven kinds ride the trigger dispatch — MODIFIERs fold at read time,
		# INTERCEPTORs fire inside Resolver.submit; neither is an event reaction.
		if effect.kind != Effect.Kind.TRIGGERED and effect.kind != Effect.Kind.CUSTOM:
			continue
		# THE activation gate: the effect's injected resolver decides, from the event's
		# origin/destination and this holder, whether it fires (see TriggerResolver).
		if not effect.trigger_resolver().fires(event, source):
			continue
		native.append_array(_run_effect(effect, source, context, event))
	if not native.is_empty():
		groups.append({"status_id": "", "results": native})
	for grp: Dictionary in StatusEngine.triggered_groups(source, event.id):
		var sres: Array = []
		for effect: Effect in grp["effects"]:
			if not effect.trigger_resolver().fires(event, source):
				continue
			# The status id rides down as the mutation CAUSE — so a poison tick that kills
			# stamps `cause = "poison"`, and the `kill` event can name it (see Resolver).
			# per_stack=false pins the scale at 1 (burning's flat tick — see Effect.per_stack).
			sres.append_array(_run_effect(effect, source, context, event,
					int(grp["stacks"]) if effect.per_stack else 1,
					StringName(grp["status_id"])))
			sres.append_array(_restrikes(effect, source, context, event,
					int(grp["stacks"]), StringName(grp["status_id"])))
		if not sres.is_empty():
			groups.append({"status_id": grp["status_id"], "results": sres})
	return groups


# The RESTRIKE pass (Effect.per_stack_chance — "each flame beyond the first may burn
# again"): repeats the whole effect once per stack PAST THE FIRST, each repeat gated by
# its own roll. Each success is a fresh damage INSTANCE through _run_effect — so damage
# riders roll per repeat, exactly as the one-roll-per-instance rule demands. Results carry
# the 1-based stack index ("restrike_stack") so presentation can glint exactly the stacks
# that burned, and only those (user call).
static func _restrikes(effect: Effect, source: CardInstance, context: EffectContext,
		event: GameEvent, stacks: int, cause: StringName) -> Array:
	var out: Array = []
	if effect.per_stack_chance <= 0.0 or stacks <= 1:
		return out
	for i: int in range(1, stacks):
		if CombatRng.roll(&"rules") >= effect.per_stack_chance:
			continue
		for res: Dictionary in _run_effect(effect, source, context, event, 1, cause):
			res["restrike_stack"] = i
			out.append(res)
	return out


# Flat results across all of a unit's containers — for callers that don't sequence per-container
# cues (card play, spells). Same resolution as trigger_grouped, one combined array.
static func trigger(event: GameEvent, source: CardInstance, context: EffectContext) -> Array:
	var out: Array = []
	for grp: Dictionary in trigger_grouped(event, source, context):
		out.append_array(grp["results"])
	return out


# Fires RUN-LEVEL triggered effects (upgrades/relics/heroes) for an event — the counterpart to
# trigger() for sources that aren't a card on the board. Run-scope effects are the PLAYER's, so
# they fire for ANY unit's event (yours OR the enemy's) and anchor allegiance to the player:
# their `fires()` gate is called holderless with owner 0, and targeting reads that same anchor
# via context.owner_anchor. "React only to your units" is then an explicit {"allegiance":"ally"}
# condition, not a blanket side gate — which is what lets a relic say "when an enemy dies…".
# context.source stays the triggering (subject) card, the SPATIAL anchor for nearest/distance.
static func trigger_global(event: GameEvent, context: EffectContext) -> Array:
	var results: Array = []
	if context.source == null or context.run_modifiers == null:
		return results
	context.owner_anchor = 0
	for effect: Effect in context.run_modifiers.triggered(event.id):
		if not effect.trigger_resolver().fires(event, null, 0):
			continue
		results.append_array(_run_effect(effect, context.source, context, event))
	return results


# Run-level results GROUPED by their owning container (relic/upgrade), so the dispatcher can cue
# each owner — e.g. glint the relic's chip — before its effects' VFX. Returns Array of
# { "owner_kind": String, "owner_id": String, "results": [] } in firing order, only non-empty groups.
static func trigger_global_grouped(event: GameEvent, context: EffectContext) -> Array:
	var order: Array = []          # owner_ids in first-seen order
	var by_owner: Dictionary = {}  # owner_id -> group dict
	if context.source == null or context.run_modifiers == null:
		return order
	context.owner_anchor = 0
	for effect: Effect in context.run_modifiers.triggered(event.id):
		if not effect.trigger_resolver().fires(event, null, 0):
			continue
		var res := _run_effect(effect, context.source, context, event)
		if res.is_empty():
			continue
		# Container identity is DISPATCH CONTEXT (the set knows who contributed what);
		# the effect itself is container-blind.
		var owner: Dictionary = context.run_modifiers.owner_of(effect)
		var oid := str(owner["id"])
		if not by_owner.has(oid):
			by_owner[oid] = {"owner_kind": str(owner["kind"]), "owner_id": oid, "results": []}
			order.append(oid)
		(by_owner[oid]["results"] as Array).append_array(res)
	var out: Array = []
	for key: String in order:
		out.append(by_owner[key])
	return out


# Fires the triggered effects a bare carrier's (a board slot's) statuses hold for an event —
# the ground layer's dispatch arm (SLOT_LAYER_DESIGN.md §4.4), a caller loop feeding the SAME
# pipeline as everything else, holderless on the trigger_global pattern: no holder unit, the
# allegiance anchor and the anchor COORDINATES arrive pre-set on the context (the cascade sets
# owner_anchor from the slot's half and anchor_* from its address). Slots have no native
# effects, so the status tier is the whole dispatch. Same grouped return shape as
# trigger_grouped; presentation of slot results is deliberately not wired in this build.
static func trigger_carrier_grouped(event: GameEvent, carrier: StatusCarrier, context: EffectContext) -> Array:
	var groups: Array = []
	for grp: Dictionary in StatusEngine.triggered_groups(carrier, event.id):
		var sres: Array = []
		for effect: Effect in grp["effects"]:
			# Fail-loud authoring fence (§4.8): a slot is nobody's holder — an effect whose
			# gate or targeting interrogates "the holder" can never mean anything here, and
			# silently never-firing (or firing as if 'of self' were 'any') hides the bug.
			var offence := _holder_shaped(effect)
			if not offence.is_empty():
				push_error("EffectSystem: slot-held status '%s' carries %s — a slot has no holder unit"
						% [str(grp["status_id"]), offence])
				continue
			if not effect.trigger_resolver().fires(event, null, context.owner_anchor):
				continue
			# per_stack=false pins the scale at 1 (burning's flat tick — see Effect.per_stack).
			sres.append_array(_run_effect(effect, null, context, event,
					int(grp["stacks"]) if effect.per_stack else 1,
					StringName(grp["status_id"])))
			sres.append_array(_restrikes(effect, null, context, event,
					int(grp["stacks"]), StringName(grp["status_id"])))
		if not sres.is_empty():
			groups.append({"status_id": grp["status_id"], "results": sres})
	return groups


# The holder-shaped constructs a slot dispatch must refuse (see trigger_carrier_grouped):
# identity trigger gates ("of: self"), self/holder targeting, and the nearest criterion
# (spatially anchored on a holder unit). Returns a description of the offence, "" if clean.
static func _holder_shaped(effect: Effect) -> String:
	var tr := effect.trigger_resolver()
	if tr is TriggerResolver.Simple and (tr as TriggerResolver.Simple).of_holder:
		return "an identity trigger gate ('of: self')"
	if tr is TriggerResolver.Dual:
		var dual := tr as TriggerResolver.Dual
		if dual.origin_of_holder or dual.destination_of_holder:
			return "an identity trigger gate ('of: self')"
	var tres := effect.targets_resolver()
	if tres is TargetResolver.Participant and (tres as TargetResolver.Participant).participant == "holder":
		return "self targeting"
	if tres is TargetResolver.Auto and (tres as TargetResolver.Auto).criterion == "nearest":
		return "nearest targeting (distance is measured from a holder unit)"
	return ""


# Runs one effect (TRIGGERED → resolve targets + apply; CUSTOM → invoke its code hook).
# `event` is the GameEvent that activated the effect (null for a transient use — a spell
# cast / ability activation), handed to the target resolver so participant targeting can
# reference the event's origin/destination. `amount_scale` multiplies stat/heal magnitudes
# (used to scale a stacked status's effects).
static func _run_effect(effect: Effect, source: CardInstance, context: EffectContext,
		event: GameEvent = null, amount_scale: int = 1, cause: StringName = &"") -> Array:
	# Probabilistic gate (the effect's `chance`): roll once; on a miss the effect doesn't fire at all.
	if effect.chance < 1.0 and CombatRng.roll(&"rules") >= effect.chance:
		return []
	if effect.kind == Effect.Kind.CUSTOM:
		var hook := EffectHooks.get_hook(effect.custom_id)
		context.effect = effect   # expose per-effect params to the hook (e.g. deliver_material's material)
		return hook.call(context) if hook.is_valid() else []
	# GROUND-layer status delivery (SLOT_LAYER_DESIGN.md §4.7): the payload names its
	# recipient layer — the SLOT, never a unit. WHERE stays the targeting socket's job:
	# a slot-pick (MANUAL_SLOT) delivers to the picked cell, anchor coords as the dispatch
	# fallback; any unit-resolving targeting delivers to the ground UNDER each resolved
	# unit ("burn the slot you strike" = participant destination + layer ground). An empty
	# resolution is a legal whiff — no coordinates to complain about.
	if not effect.status_id.is_empty() and effect.status_layer == "ground" \
			and not _targets_the_ground(effect):
		if effect.targets_resolver() is TargetResolver.ManualSlot:
			var gres := _ground_status_at_coords(effect, source, context, cause)
			return [gres] if not gres.is_empty() else []
		var gresults: Array = []
		for gtarget: Object in effect.targets_resolver().resolve(event, source, context):
			var under := gtarget as CardInstance
			var beneath: BoardLocation = null
			if context != null and context.world != null:
				beneath = context.world.location_of(under)
			if beneath == null:
				continue   # a side target / off-board unit has no ground beneath it
			# ONE address, both layers: the ground under a unit is the unit's own square,
			# asked for as a whole rather than rebuilt out of a row, a column and a guess at
			# which half (LOCATION_MANAGER_DESIGN.md §3).
			var gr := _ground_status_at(effect, source, context, cause, beneath)
			if not gr.is_empty():
				gresults.append(gr)
		return gresults
	# THE targeting socket: the effect's injected resolver returns the affected target(s)
	# from the same shared context the trigger saw (see TargetResolver). The array is
	# heterogeneous — units (CardInstance), a player (CombatSide, the "side" kind), or a
	# cell of the ground (BoardSlot, the location socket's ground layer) — dispatched by
	# type here, mirroring Resolver.submit. Effects apply to royalty (King/Queen) and
	# lackeys alike; only the resolver's conditions filter.
	var results: Array = []
	for target: Object in effect.targets_resolver().resolve(event, source, context):
		var r: Dictionary
		if target is CombatSide:
			r = _apply_side(effect, target as CombatSide, source, amount_scale, cause)
		elif target is BoardSlot:
			r = _apply_ground(effect, target as BoardSlot, source, context, cause)
		else:
			r = _apply(effect, target as CardInstance, source, context, amount_scale, cause)
		if not r.is_empty():
			results.append(r)
	return results


# Whether this effect's own targeting already resolves to GROUND — in which case delivery
# goes through the ordinary socket below, not the layer-key pre-branch above. Both routes
# reach the same one delivery point; the pre-branch stays because it is how every ground
# status authored so far is spelled, and a reversal of policy is not a deletion of the
# mechanism it replaced.
static func _targets_the_ground(effect: Effect) -> bool:
	var at := effect.targets_resolver() as TargetResolver.AtLocation
	return at != null and at.layer == "ground"


# A resolved SLOT: the ground is a status carrier and nothing else, so the only payload
# that means anything here is a status. Anything else is an authoring error — loud, and no
# quiet no-op that looks like a legal whiff.
static func _apply_ground(effect: Effect, slot: BoardSlot, source: CardInstance,
		context: EffectContext, cause: StringName) -> Dictionary:
	if effect.status_id.is_empty():
		push_error("EffectSystem: ground-layer targeting resolved a slot, but the payload is "
				+ "'%s' — the ground carries statuses and nothing else" % effect.attribute)
		return {}
	if context == null or context.world == null:
		return {}
	return _ground_status_at(effect, source, context, cause, context.world.location_of(slot))


# ── Effect application ─────────────────────────────────────────────────────────

# A side-targeted payload (draw/discard/mana/max_mana — load-validated pairing): one
# mutation on the side, same result-dict shape as the unit path so dispatchers/cues
# treat it uniformly. Delta 0 (empty pile, intercepted away) is a no-op — no result.
static func _apply_side(effect: Effect, side: CombatSide, source: CardInstance, amount_scale: int = 1, cause: StringName = &"") -> Dictionary:
	var amount := effect.amount_int() * amount_scale
	if amount == 0:
		return {}
	var out := Resolver.submit(_caused(StatMutation.make(side,
			StatMutation.stat_for_attribute(effect.attribute), amount, source), cause))
	if out.delta == 0:
		return {}
	return _with_interceptions({"target": side, "attribute": effect.attribute, "delta": out.delta}, out)


# The ADDRESS form of ground delivery (MANUAL_SLOT targeting): the picked cell (a cast's
# gesture), else the anchor (a slot status re-applying ground state through its own
# dispatch). No address at all = authoring bug: fail loud, apply nothing.
#
# ⚠ HISTORY WORTH KEEPING: this used to hold a bare row and column and reach for
# TriggerResolver.anchor_owner to decide WHICH HALF the picked square was on — deriving a
# spatial fact from the allegiance channel. It worked because the two normally agree, which
# is exactly what made it hard to see. A pick arrives as one whole address now, so there is
# no half left to go looking for (LOCATION_MANAGER_DESIGN.md §3, §2.6).
static func _ground_status_at_coords(effect: Effect, source: CardInstance, context: EffectContext, cause: StringName) -> Dictionary:
	if context == null or context.world == null:
		return {}
	var at: BoardLocation = context.manual_at
	if at == null:
		at = context.anchor_at
	if at == null:
		push_error("EffectSystem: ground status '%s' has no address (no picked slot, no anchor)"
				% effect.status_id)
		return {}
	return _ground_status_at(effect, source, context, cause, at)


# The one delivery point for a ground status: submit to the slot at the address, through the
# Resolver like the unit form (single-writer rule — stack counts stay interceptable).
# Outside combat (no world in the context) the payload is inert, mirroring spawn.
static func _ground_status_at(effect: Effect, source: CardInstance, context: EffectContext,
		cause: StringName, at: BoardLocation) -> Dictionary:
	if context == null or context.world == null or at == null:
		return {}
	var slot := BoardFacade.slot_at(context.world, at)
	var sout := Resolver.submit(_caused(StatMutation.status_apply(slot, effect.status_id,
			effect.status_duration, effect.status_stacks, source), cause))
	if sout.delta <= 0:
		return {}
	# Ground state is INVISIBLE for now (no slot pips until the presentation step) — the
	# always-recording combat log is the one witness a playtest has.
	CombatLog.note("ground", "%s ignites slot %s%s" % [effect.status_id, str(at),
			"" if source == null else " — by " + str(source.data.id)])
	return _with_interceptions({"target": slot, "status_applied": effect.status_id}, sout)


static func _apply(effect: Effect, target: CardInstance, source: CardInstance, context: EffectContext, amount_scale: int = 1, cause: StringName = &"") -> Dictionary:
	if effect.custom_apply.is_valid():
		effect.custom_apply.call(target)
		return {}
	# Generic "apply a status" operation: any effect can grant a status to each resolved target.
	# Routed through the Resolver (single-writer rule) so interceptors can rewrite the stack
	# count — an application intercepted away (delta 0) applies nothing and cues nothing.
	if not effect.status_id.is_empty():
		var sout := Resolver.submit(_caused(StatMutation.status_apply(target, effect.status_id,
				effect.status_duration, effect.status_stacks, source), cause))
		if sout.delta <= 0:
			return {}
		return _with_interceptions({"target": target, "status_applied": effect.status_id}, sout)
	# Generic "spawn units" payload: queue `spawn_count` copies of the card on the target's side,
	# anchored at the target's slot. The world flushes the queue after its next death sweep, so an
	# on-death split lands where the corpse stood (see CombatWorld.queue_spawn). Spawn count is
	# authored, never stack-scaled — a status stack multiplies magnitudes, not populations.
	# Outside combat (no world in context) the payload is inert.
	if not effect.spawn_id.is_empty():
		if context == null or context.world == null or context.world.location_of(target) == null:
			return {}
		context.world.queue_spawn(effect.spawn_id, effect.spawn_count, target)
		return {"target": target, "spawned": effect.spawn_id, "count": effect.spawn_count}
	# Every branch returns {} for a no-op (nothing changed) and a non-empty result when something
	# happened — so "produced a result" == "the container did something", which drives the cue.
	var amount := effect.amount_int() * amount_scale
	if effect.attribute == "health":
		# Direct health change — a signed HEALTH mutation. The Resolver owns the form (negative
		# bypasses shield, e.g. poison; positive heals, clamped to max) and reports the delta
		# that actually landed. The shield-routed pipeline lives on "damage_taken".
		var out := Resolver.submit(_caused(StatMutation.make(target,
				StatMutation.stat_for_attribute(effect.attribute), amount, source), cause))
		if out.delta == 0:
			return {}   # already full / 0 heal — nothing happened
		return _with_interceptions({"target": target, "attribute": "health", "delta": out.delta}, out)
	elif effect.attribute == "damage_taken":
		# The incoming-hit channel: attack-form damage — shield absorbs first, the remainder
		# wounds health. HOW it splits is the Resolver's knowledge, not ours.
		if amount <= 0:
			return {}
		var dout := Resolver.submit(_caused(StatMutation.make(target,
				StatMutation.stat_for_attribute(effect.attribute), amount, source), cause))
		var dres := _with_interceptions({"target": target, "attribute": "health", "delta": -amount}, dout)
		_run_riders(effect, target, source, cause, dout, dres)
		return dres
	else:
		if amount == 0:
			return {}
		var mout := Resolver.submit(_caused(StatMutation.make(target,
				StatMutation.stat_for_attribute(effect.attribute), amount, source), cause))
		return _with_interceptions({"target": target, "attribute": effect.attribute, "delta": amount}, mout)


# The damage RIDERS (see Effect.riders): follow-ons the damage CARRIES onto whoever took
# it — "burn damage may set you alight" without inventing a fire-damage TYPE, which is a
# separate concern we deliberately have no plans for (user call 2026-08-03).
#
# ONE ROLL PER DAMAGE INSTANCE, flat: the amount is not a multiplier, so a 3-damage hit
# rolls exactly as often as a 1-damage one. Getting more rolls means dealing damage in more
# instances — a repetition question that lives nowhere near here.
#
# Gated on the damage having LANDED (delta != 0): the rider rides the damage, so a hit
# intercepted away to nothing carries nothing. Shield-absorbed damage DOES carry it (the
# delta is real, it just spent itself on shield) — otherwise a shield would read as immunity
# to catching fire, which it is not.
#
# Applications ride the Resolver like every other status write (single-writer rule), and
# land on the result dict as `rider_applied` so presentation can cue the new pip.
static func _run_riders(effect: Effect, target: CardInstance, source: CardInstance,
		cause: StringName, dout: Resolver.Outcome, result: Dictionary) -> void:
	if effect.riders.is_empty() or target == null or dout.delta == 0:
		return
	var applied: Array = []
	for r: Dictionary in effect.riders:
		var chance := float(r["chance"])
		if chance < 1.0 and CombatRng.roll(&"rules") >= chance:
			continue
		var sout := Resolver.submit(_caused(StatMutation.status_apply(target,
				str(r["status_id"]), int(r["status_duration"]), int(r["status_stacks"]), source), cause))
		if sout.delta <= 0:
			continue   # intercepted away — nothing was applied, so nothing to cue
		applied.append(str(r["status_id"]))
		CombatLog.note("rider", "%s damage sets %s %s" % [cause,
				"?" if target.data == null else str(target.data.id), str(r["status_id"])])
	if not applied.is_empty():
		result["rider_applied"] = applied


# Stamps the provenance cause onto a mutation just before submit — a passthrough so the
# many make() sites above stay one-liners. See StatMutation.cause / the `kill` event.
static func _caused(m: StatMutation, cause: StringName) -> StatMutation:
	m.cause = cause
	return m


# Rides the Resolver's interception records on the result dict, so presentation can cue the
# rewriters (relic chip / status pip / card glint) before the effect's own VFX — the effect
# path's counterpart of the attack path's Outcome.interceptions playback.
static func _with_interceptions(r: Dictionary, out: Resolver.Outcome) -> Dictionary:
	if not out.interceptions.is_empty():
		r["interceptions"] = out.interceptions
	return r


# ── Condition evaluation ───────────────────────────────────────────────────────

# The same gate _resolve_targets applies, exposed for PRE-resolution eligibility checks —
# the spell-targeting UI (only eligible units light up / accept the drop) and the enemy AI's
# target picking, so an ineligible pick is impossible instead of a silent fizzle.
static func passes_conditions(conditions: Array, card: CardInstance, holder: CardInstance = null) -> bool:
	return _passes_conditions(conditions, card, holder)


static func _passes_conditions(conditions: Array, card: CardInstance, holder: CardInstance = null) -> bool:
	var owner := -1 if holder == null else holder.owner   # conditions are (unit, owner-side) predicates
	for cond: EffectCondition in conditions:
		if not cond.evaluate(card, owner):
			return false
	return true


# (Board flattening and the nearest-distance metric moved into TargetResolver — the
# targeting socket owns its own search primitives now.)
