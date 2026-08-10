extends TestCase

# The GROUND layer (SLOT_LAYER_DESIGN.md): slots as status carriers. Computation pins only —
# application/stacking through the one writer, Resolver routing + the fail-loud non-STATUS arm,
# interceptor degrade, the cascade's ground tick in reading order, AT_LOCATION targeting over
# incidental co-location, ground-layer status delivery, and copy fidelity. All content here is
# test-fixture statuses (_t_-prefixed); burning/wildfire is a later, separate step.


func suite_name() -> String:
	return "Slot layer"


# Test-owned status definitions, injected around each run (the composition-grants pattern).
# _t_ground_burn's trigger/targets are authored NATIVE — the legacy string schema's default
# subject gate is "self", which is holder-shaped and belongs in the fence test below.
const T_STATUSES := {
	"_t_ground_mark": {"id": "_t_ground_mark", "decay": "duration", "default_duration": 2,
			"stacking": "stack", "max_stacks": 3},
	"_t_ground_burn": {"id": "_t_ground_burn", "decay": "duration", "default_duration": 3,
			"effects": [
				{"trigger": {"kind": "event", "event": "turn_end"},
					"targets": {"kind": "at_location"},
					"attribute": "health", "amount": -2}]},
	"_t_ground_selfish": {"id": "_t_ground_selfish", "decay": "none",
			"effects": [
				{"trigger": "on_turn_end", "attribute": "health", "amount": -2}]},
}


func run() -> void:
	for sid: String in T_STATUSES:
		StatusData._all[sid] = StatusData.from_dict(T_STATUSES[sid])
	_slot_filing_and_stacking()
	_resolver_routes_and_fails_loud()
	_interceptor_degrade()
	_ticking_and_reading_order()
	_at_location_over_colocation()
	_holder_shaped_fenced()
	_ground_delivery()
	_at_location_spelling()
	_copy_fidelity()
	for sid: String in T_STATUSES:
		StatusData._all.erase(sid)


func _world() -> CombatWorld:
	var w := CombatWorld.make(GameData.current_modifiers)
	w.rewards_live = false
	return w


func _place(w: CombatWorld, card_id: String, side_owner: int, r: int, c: int) -> CardInstance:
	var inst := unit(card_id)
	w.place_unit(inst, r, c, side_owner)
	return inst


# One synchronous cascade phase pass under the null presenter (the test_cascade pattern).
func _phase(cascade: CombatCascade, event_id: StringName, subject: CardInstance = null) -> void:
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.resolve_event(event_id, subject)
		done[0] = true
	chain.call()
	check(bool(done[0]), "the ground pass stays synchronous under the null presenter")


func _slot_filing_and_stacking() -> void:
	# The application rules land identically on the second carrier species — same one writer.
	var slot := _world().slot_at(0, 1, 2)
	StatusEngine.apply(slot, "_t_ground_mark", Effect.STATUS_DURATION_DEFAULT, 1, null)
	var si := slot.find_status("_t_ground_mark")
	check(si != null, "a slot files an applied status")
	check(si != null and si.stacks == 1 and si.remaining == 2, "first application takes the status's own shape")
	StatusEngine.apply(slot, "_t_ground_mark", Effect.STATUS_DURATION_DEFAULT, 1, null)
	check(si != null and si.stacks == 2, "intensity stacking combines on a slot")
	StatusEngine.apply(slot, "_t_ground_mark", Effect.STATUS_DURATION_DEFAULT, 5, null)
	check(si != null and si.stacks == 3, "stack clamp holds on a slot (max 3)")
	slot.remove_status("_t_ground_mark")
	check(slot.find_status("_t_ground_mark") == null, "filing removal works on a slot")


func _resolver_routes_and_fails_loud() -> void:
	var w := _world()
	var slot := w.slot_at(1, 0, 0)
	check(w.slot_at(1, 0, 0) == slot, "slot_at answers the same permanent slot every time")
	var out := Resolver.submit(StatMutation.status_apply(slot, "_t_ground_mark",
			Effect.STATUS_DURATION_DEFAULT, 2, null))
	check_eq(out.delta, 2, "the Resolver's STATUS arm reaches a slot (delta = requested stacks)")
	var si := slot.find_status("_t_ground_mark")
	check(si != null and si.stacks == 2, "the routed application landed through StatusEngine.apply")
	# Non-STATUS at a slot: authoring error — loud, no-op, NO crash (the push_error below is
	# this fence proving itself, not a failure).
	var bad := Resolver.submit(StatMutation.make(slot, StatMutation.DAMAGE, 5, null))
	check_eq(bad.delta, 0, "a non-STATUS mutation at a slot commits nothing")


func _interceptor_degrade() -> void:
	# A unit-shaped (target-participant) status interceptor: live on the unit path, silently
	# non-matching on a slot application — the `as CardInstance` degrade, no special-casing.
	var src := CardInstance.from_data(CardData.build_from_dict({
		"id": "_t_status_boost", "display_name": "T", "cost": 1, "attack": 1, "health": 3,
		"speed": 1, "effects": [
			{"intercept": "status", "of": {"participant": "target"}, "amount": 1},
		]}))
	src.owner = 0
	var tgt := unit("pawn")
	var uout := Resolver.submit(StatMutation.status_apply(tgt, "_t_ground_mark",
			Effect.STATUS_DURATION_DEFAULT, 1, src))
	check_eq(uout.delta, 2, "sanity: the interceptor rewrites a UNIT application (+1 stack)")
	var w := _world()
	var slot := w.slot_at(0, 2, 2)
	var sout := Resolver.submit(StatMutation.status_apply(slot, "_t_ground_mark",
			Effect.STATUS_DURATION_DEFAULT, 1, src))
	check_eq(sout.delta, 1, "the same interceptor does not match a SLOT application")
	check(sout.interceptions.is_empty(), "…and records no interception (no phantom cue)")


func _ticking_and_reading_order() -> void:
	var w := _world()
	# Scrambled insertion; enumeration must come back in reading order (side, row, col).
	StatusEngine.apply(w.slot_at(1, 1, 3), "_t_ground_mark", Effect.STATUS_DURATION_DEFAULT, 1, null)
	StatusEngine.apply(w.slot_at(0, 1, 2), "_t_ground_mark", Effect.STATUS_DURATION_DEFAULT, 1, null)
	StatusEngine.apply(w.slot_at(0, 0, 0), "_t_ground_mark", Effect.STATUS_DURATION_DEFAULT, 1, null)
	w.slot_at(1, 0, 0)   # touched but empty — must not enumerate
	var order: Array = []
	for s: BoardSlot in w.active_slots():
		order.append(w.location_of(s).key())
	check_eq(order, [Vector3i(0, 0, 0), Vector3i(0, 1, 2), Vector3i(1, 1, 3)],
			"active_slots lists carrying slots only, in reading order")

	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var subject := _place(w, "pawn", 0, 0, 3)
	_phase(cascade, &"activate", subject)
	var si := w.slot_at(0, 0, 0).find_status("_t_ground_mark")
	check(si != null and si.remaining == 2, "a subject-scoped moment never ticks the ground")
	_phase(cascade, &"turn_end")
	check(si != null and si.remaining == 1, "a phase moment decays slot statuses like the unit tier")
	_phase(cascade, &"turn_end")
	check(w.slot_at(0, 0, 0).find_status("_t_ground_mark") == null,
			"an expired slot status is dropped by the tick")


func _at_location_over_colocation() -> void:
	# The core model claim: the slot targets WHOEVER stands at its address right now —
	# co-location is a fresh world lookup, never a stored relationship.
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var first := _place(w, "rook", 0, 0, 0)   # 6 HP, 3 shield — but health payload bypasses shield
	var hp0 := first.current_health
	StatusEngine.apply(w.slot_at(0, 0, 0), "_t_ground_burn", Effect.STATUS_DURATION_DEFAULT, 1, null)
	_phase(cascade, &"turn_end")
	check_eq(first.current_health, hp0 - 2, "a slot status hits the unit standing on its cell")
	# The unit steps off; the fire stays behind by construction. ONE move, on the one
	# authority — leaving the old cell is not a second step to remember.
	w.locations.move(first, BoardLocation.at(0, 1, 0))
	_phase(cascade, &"turn_end")
	check_eq(first.current_health, hp0 - 2, "an empty cell whiffs legally — the mover is not chased")
	# A NEW unit walks in and takes the ground as it finds it.
	var second := _place(w, "knight", 0, 0, 0)
	var hp1 := second.current_health
	_phase(cascade, &"turn_end")
	check_eq(second.current_health, hp1 - 2, "the new occupant is hit — co-location is incidental")
	check(w.slot_at(0, 0, 0).find_status("_t_ground_burn") == null,
			"the burn decayed out after its three phase ticks")


func _holder_shaped_fenced() -> void:
	# §4.8: a slot is nobody's holder. A legacy-authored effect (default subject gate "self",
	# default SELF targeting) must be refused LOUDLY, not fired as if "of self" meant "any".
	# The push_error this prints is the fence proving itself.
	var w := _world()
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var occupant := _place(w, "pawn", 0, 0, 0)
	var hp0 := occupant.current_health
	StatusEngine.apply(w.slot_at(0, 0, 0), "_t_ground_selfish", Effect.STATUS_DURATION_DEFAULT, 1, null)
	_phase(cascade, &"turn_end")
	check_eq(occupant.current_health, hp0, "a holder-shaped effect on a slot is skipped, not misfired")


func _ground_delivery() -> void:
	# The "layer": "ground" payload — a cast's MANUAL_SLOT pick delivers the status to the SLOT.
	var w := _world()
	var caster := unit("pawn")
	var ctx := w.make_context(caster)
	ctx.manual_at = BoardLocation.at(0, 1, 2)
	var e := Effect.from_dict({"targets": {"kind": "manual_slot"},
			"status": {"id": "_t_ground_mark", "layer": "ground"}})
	var res := EffectSystem.apply_single(e, caster, ctx)
	var si := w.slot_at(0, 1, 2).find_status("_t_ground_mark")
	check(si != null, "a ground-layer status lands on the picked cell's SLOT, caster's half")
	check(res.size() == 1 and res[0].get("target") is BoardSlot,
			"the delivery reports the slot as its target")
	check_eq(str(e.to_dict()["status"]["layer"]), "ground", "the layer key survives the round trip")
	# Anchor-coordinate fallback (a slot status re-applying ground state through its own dispatch).
	var ctx2 := w.make_context(null)
	ctx2.owner_anchor = 1
	ctx2.anchor_at = BoardLocation.at(1, 0, 3)
	EffectSystem.apply_single(e, null, ctx2)
	check(w.slot_at(1, 0, 3).find_status("_t_ground_mark") != null,
			"with no pick, the anchor coordinates address the ground")
	# No coordinates at all: authoring bug — loud no-op (the push_error is the fence).
	var bare := w.make_context(caster)
	check(EffectSystem.apply_single(e, caster, bare).is_empty(),
			"a ground payload with no address applies nothing")

	# ⚠ THE CONFLATION, PINNED SHUT (LOCATION_MANAGER_DESIGN.md §3). A pick on the ENEMY half
	# by a PLAYER-allegiance caster lands on the enemy half. It used to land on the player's,
	# because delivery held a bare row and column and took its half from the allegiance
	# channel — the two normally agree, which is precisely why nobody saw it. A picked square
	# arrives as one whole address now, so there is no half to go looking for.
	var across := w.make_context(caster)
	across.manual_at = BoardLocation.at(1, 2, 1)
	EffectSystem.apply_single(e, caster, across)
	check(w.slot_at(1, 2, 1).find_status("_t_ground_mark") != null,
			"a pick lands on the half it points at, whoever is casting")
	check(w.slot_at(0, 2, 1).find_status("_t_ground_mark") == null,
			"…and NOT on the caster's own half, which is what the allegiance read used to do")


func _at_location_spelling() -> void:
	# TARGETING REMOVED (targeting-cleanup demolition): "parses to the AtLocation kind" and its
	# compat mirror belong to the rebuilt authority's suite. The verbatim round-trip remains.
	var e := Effect.from_dict({"trigger": {"kind": "event", "event": "turn_end"},
			"targets": {"kind": "at_location"}, "attribute": "health", "amount": -1})
	var td: Dictionary = e.to_dict()
	check_eq(str((td["targets"] as Dictionary)["kind"]), "at_location", "at_location serializes back by name")


func _copy_fidelity() -> void:
	var w := _world()
	var igniter := _place(w, "pawn", 0, 1, 1)
	StatusEngine.apply(w.slot_at(1, 2, 3), "_t_ground_mark", Effect.STATUS_DURATION_DEFAULT, 2, igniter)
	var w2 := w.copy()
	var copy_slot := w2.slot_at(1, 2, 3)
	check(copy_slot != w.slot_at(1, 2, 3), "the copy owns its own slot objects")
	var si2 := copy_slot.find_status("_t_ground_mark")
	check(si2 != null and si2.stacks == 2 and si2.remaining == 2, "slot statuses ride the snapshot intact")
	var grid_row: Array = w2.player_grid[1]
	check(si2 != null and si2.source == grid_row[1] and si2.source != igniter,
			"the status's source unit is remapped into the snapshot")
	if si2 != null:
		si2.stacks = 5
	StatusEngine.advance(copy_slot, &"turn_end")
	var si0 := w.slot_at(1, 2, 3).find_status("_t_ground_mark")
	check(si0 != null and si0.stacks == 2 and si0.remaining == 2,
			"mutating the copy leaves the original world untouched")
