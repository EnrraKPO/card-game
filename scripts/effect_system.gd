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
		if not sres.is_empty():
			groups.append({"status_id": grp["status_id"], "results": sres})
	return groups


# (The RESTRIKE pass and damage RIDERS were deleted 2026-08-11: never user-designed,
# disavowed 2026-08-09. One activation per firing; damage carries no follow-ons.)


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
		if not sres.is_empty():
			groups.append({"status_id": grp["status_id"], "results": sres})
	return groups


# The holder-shaped constructs a slot dispatch must refuse (see trigger_carrier_grouped):
# identity trigger gates ("of: self"). Returns a description of the offence, "" if clean.
# TARGETING REMOVED: this fence also refused holder-shaped TARGETING (self targeting, and the
# nearest criterion — spatially anchored on a holder unit a slot doesn't have). The rebuilt
# targeting authority must restore that half of the refusal.
static func _holder_shaped(effect: Effect) -> String:
	var tr := effect.trigger_resolver()
	if tr is TriggerResolver.Simple and (tr as TriggerResolver.Simple).of_holder:
		return "an identity trigger gate ('of: self')"
	if tr is TriggerResolver.Dual:
		var dual := tr as TriggerResolver.Dual
		if dual.origin_of_holder or dual.destination_of_holder:
			return "an identity trigger gate ('of: self')"
	return ""


# Runs one effect (TRIGGERED → resolve targets + apply; CUSTOM → invoke its code hook).
# `_event` is the GameEvent that activated the effect (null for a transient use — a spell
# cast / ability activation); the targeting authority needs it so participant targeting can
# reference the event's origin/destination. `_amount_scale` multiplies stat/heal magnitudes
# (used to scale a stacked status's effects). Both unread while resolution is demolished —
# the signature is kept whole because every dispatch entry point threads them.
static func _run_effect(effect: Effect, _source: CardInstance, context: EffectContext,
		_event: GameEvent = null, _amount_scale: int = 1, _cause: StringName = &"") -> Array:
	# Probabilistic gate (the effect's `chance`): roll once; on a miss the effect doesn't fire at all.
	if effect.chance < 1.0 and CombatRng.roll(&"rules") >= effect.chance:
		return []
	if effect.kind == Effect.Kind.CUSTOM:
		# CODE HOOKS REMOVED (effect-cleanse — EffectHooks burned with its content). NEEDS:
		# the rebuilt payload species cover what the hooks hand-rolled — deliver_material's
		# merge (composition combine, wounds as a damage delta, never lethal, king/rook
		# backstops, empty-pick = spawn) chief among them — as AUTHORED payloads, not opaque
		# code; a payload the schema can't say is the schema's gap to close, not a hook's.
		return []
	# TARGETING REMOVED (targeting-cleanup demolition) — every dispatch below this line is
	# INERT: no effect resolves anybody, so no payload lands. NEEDS: the targeting authority
	# returns the affected target(s) from the same shared context the trigger saw, as ONE
	# heterogeneous answer — units (CardInstance), a player (CombatSide), or cells of the
	# ground (BoardSlot) — dispatched by type to the payload appliers kept below
	# (_apply / _apply_side / _apply_ground), mirroring Resolver.submit. Requirements the
	# old resolution honoured, which the rebuild must state rather than special-case:
	#   · GROUND delivery: a status payload naming layer "ground" lands on SLOTS — the picked
	#     cell for a slot-pick (context.manual_at), the anchor address as the slot-dispatch
	#     fallback (context.anchor_at), or the ground UNDER each resolved unit ("burn the slot
	#     you strike"). ONE address asked whole, never rebuilt from row+col+a guessed half
	#     (LOCATION_MANAGER_DESIGN.md §3). The old code did this in a pre-branch that
	#     type-peeked the resolver — the rebuilt socket should make slots an ordinary answer.
	#   · An empty resolution is a LEGAL WHIFF, not an error; effects reach royalty and
	#     lackeys alike — only conditions filter.
	#   · `amount_scale` (a stacked status's multiplier) applies to what lands.
	return []


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
		return _with_interceptions({"target": target, "attribute": "health", "delta": -amount}, dout)
	else:
		if amount == 0:
			return {}
		var mout := Resolver.submit(_caused(StatMutation.make(target,
				StatMutation.stat_for_attribute(effect.attribute), amount, source), cause))
		return _with_interceptions({"target": target, "attribute": effect.attribute, "delta": amount}, mout)


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
# TARGETING REMOVED — the PRE-resolution eligibility gate went with it. NEEDS: one evaluation
# of an effect's conditions serving BOTH the resolution and the eligibility surfaces (the
# spell-targeting UI lighting eligible units, the enemy AI's target picking), with ONE anchor
# semantics. The old exposed helper evaluated with owner −1 when no holder was passed while
# resolution used the real allegiance anchor — two paths that could disagree (see
# TECH_DEBT_BRIEF.md, "one dispatch, one vocabulary"): the rebuilt authority must make that
# disagreement impossible, not rare.
