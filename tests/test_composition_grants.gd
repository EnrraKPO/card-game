extends TestCase

# Composition GRANTS (virtual components): a standing effect makes a unit COUNT AS containing
# component ids for condition resolution — Layer 1 of the layered standing evaluation
# (LiveEffects.effective_composition) — while the card's REAL composition (shared CardData
# identity) never moves. Covers the fixed point (same-unit chains, order independence),
# Layer 2 reading the settled snapshot, expiry-driven invalidation, the non-combat fallback,
# the has_element lens, negative gates, and authoring round-trips.
# (Validator rejections push_error and aren't assertable here — the Tool's api_test covers
# the same four rules; the headless runner surfaces the game-side error visibly.)


func suite_name() -> String:
	return "CompositionGrants"


func run() -> void:
	_basic_grant()
	_chain_settles_both_orders()
	_layer2_reads_layer1()
	_expiry_invalidates()
	_stacks_tracker_expiry()
	_non_combat_fallback()
	_has_element_lens()
	_negative_gate_respects_grants()
	_round_trip()
	_count_reads_identity_not_grants()
	_count_comparators_and_pools()
	_count_round_trips()


# ── helpers ────────────────────────────────────────────────────────────────────────────

const FIRE_GRANT := "_test_grant_fire"


# Registers an in-memory test status (never touches data/statuses/). Erase when done.
static func _register_status(d: Dictionary) -> void:
	var s := StatusData.from_dict(d)
	StatusData._all[s.id] = s


static func _unregister_status(id: String) -> void:
	StatusData._all.erase(id)


# A self-targeted "counts as fire" status, with optional lifecycle overrides.
static func _fire_grant_status(extra: Dictionary = {}) -> void:
	var d := {
		"id": FIRE_GRANT,
		"display_name": "T Fire Grant",
		"effects": [{
			"trigger": {"kind": "while"},
			"targets": {"kind": "self"},
			"grants": ["fire"],
		}],
	}
	d.merge(extra, true)
	_register_status(d)


# ── cases ──────────────────────────────────────────────────────────────────────────────

func _basic_grant() -> void:
	_fire_grant_status()
	var u := unit("pawn")
	var fire := EffectCondition.from_dict({"composition": ["fire"]})
	check(not fire.evaluate(u), "no grant: a plain pawn is not fire")
	StatusEngine.apply(u, FIRE_GRANT, Effect.STATUS_DURATION_DEFAULT, 1, null)
	check(fire.evaluate(u), "a granted component passes the composition condition")
	check(not u.data.elements.has("fire"), "the REAL composition is untouched")
	check_eq(u.get_attribute("element_count"), 0, "identity reads stay raw (element_count)")
	check(not EffectCondition.from_dict({"composition": ["water"]}).evaluate(u),
			"only the granted id passes, not the whole element set")

	# A granted PIECE id: conditions see it, identity (is_building) does not.
	_register_status({"id": "_test_grant_rook", "display_name": "T", "effects": [
		{"trigger": {"kind": "while"}, "targets": {"kind": "self"}, "grants": ["rook"]}]})
	StatusEngine.apply(u, "_test_grant_rook", Effect.STATUS_DURATION_DEFAULT, 1, null)
	check(EffectCondition.from_dict({"composition": ["rook"]}).evaluate(u),
			"a granted piece id passes conditions")
	check(not u.data.is_building(), "identity is untouched: a granted rook is no building")
	u.clear_statuses()
	check(not fire.evaluate(u), "clearing statuses drops the grant at the next read")
	_unregister_status(FIRE_GRANT)
	_unregister_status("_test_grant_rook")


func _chain_settles_both_orders() -> void:
	# Same-unit chain: fire (status grant) enables a run-set "counts as rook while fire"
	# grant — the per-unit fixed point settles both in ONE read, whichever source landed
	# first (order independence is the monotone-union guarantee).
	_fire_grant_status()
	var chain := {
		"trigger": {"kind": "while"},
		"targets": {"kind": "all", "conditions": [{"composition": ["fire"]}]},
		"grants": ["rook"],
	}
	var rook := EffectCondition.from_dict({"composition": ["rook"]})

	var a := unit("pawn")
	StatusEngine.apply(a, FIRE_GRANT, Effect.STATUS_DURATION_DEFAULT, 1, null)
	GameData.current_modifiers.add(Effect.from_dict(chain))
	check(rook.evaluate(a), "chain settles: fire (status) => rook (run set)")

	var b := unit("pawn")
	check(not rook.evaluate(b), "the chain grants nothing without fire")
	StatusEngine.apply(b, FIRE_GRANT, Effect.STATUS_DURATION_DEFAULT, 1, null)
	check(rook.evaluate(b), "chain settles regardless of source arrival order")

	GameData.current_modifiers = ModifierSet.new()
	_unregister_status(FIRE_GRANT)


func _layer2_reads_layer1() -> void:
	# A stat fold gated on composition reads the SETTLED snapshot: granting fire turns the
	# conditional +2 attack on; dropping the grant turns it off.
	_fire_grant_status()
	GameData.current_modifiers.add(Effect.from_dict({
		"trigger": {"kind": "while"},
		"targets": {"kind": "all", "conditions": [{"composition": ["fire"]}]},
		"attribute": "attack",
		"amount": 2,
	}))
	var u := unit("pawn")
	var base := u.data.attack
	check_eq(u.get_attribute("attack"), base, "no fire, no bonus")
	StatusEngine.apply(u, FIRE_GRANT, Effect.STATUS_DURATION_DEFAULT, 1, null)
	check_eq(u.get_attribute("attack"), base + 2,
			"Layer 2 reads Layer 1: the composition-gated fold sees the granted component")
	u.remove_status(FIRE_GRANT)
	check_eq(u.get_attribute("attack"), base, "the bonus leaves with the grant")
	GameData.current_modifiers = ModifierSet.new()
	_unregister_status(FIRE_GRANT)


func _expiry_invalidates() -> void:
	# The round tick (StatusEngine.advance) is the expiry writer — no manual invalidation:
	# the snapshot drops with the tick and the next read sees the post-decay world.
	_fire_grant_status({"decay": "duration", "default_duration": 1, "decay_phase": "turn_end"})
	var u := unit("pawn")
	StatusEngine.apply(u, FIRE_GRANT, Effect.STATUS_DURATION_DEFAULT, 1, null)
	var fire := EffectCondition.from_dict({"composition": ["fire"]})
	check(fire.evaluate(u), "grant live before the tick")
	StatusEngine.advance(u, &"turn_end")
	check(not fire.evaluate(u), "the tick expires the grant — next read sees it gone")
	_unregister_status(FIRE_GRANT)


func _stacks_tracker_expiry() -> void:
	# A stack-tracked grant: union payloads don't SCALE with stacks, but tracker validity
	# still gates existence — 0 stacks = no grant.
	_register_status({
		"id": "_test_grant_stacks", "display_name": "T",
		"decay": "stacks", "decay_phase": "turn_end", "stacking": "stack",
		"effects": [{
			"trigger": {"kind": "while"}, "targets": {"kind": "self"},
			"grants": ["water"], "tracker": {"kind": "stacks"},
		}],
	})
	var u := unit("pawn")
	StatusEngine.apply(u, "_test_grant_stacks", Effect.STATUS_DURATION_DEFAULT, 2, null)
	var water := EffectCondition.from_dict({"composition": ["water"]})
	check(water.evaluate(u), "stack-tracked grant live at 2 stacks")
	StatusEngine.advance(u, &"turn_end")
	check(water.evaluate(u), "still live at 1 stack (a union exists or it doesn't)")
	StatusEngine.advance(u, &"turn_end")
	check(not water.evaluate(u), "0 stacks = grant gone")
	_unregister_status("_test_grant_stacks")


func _non_combat_fallback() -> void:
	# Outside combat nothing special-cases: an allegiance-gated run grant fails closed on a
	# sideless (owner -1) preview instance and reaches a player-owned unit — the same
	# semantics every standing read already has. No grants at all = effective == raw.
	GameData.current_modifiers.add(Effect.from_dict({
		"trigger": {"kind": "while"},
		"targets": {"kind": "all", "conditions": [{"allegiance": "ally"}]},
		"grants": ["light"],
	}))
	var light := EffectCondition.from_dict({"composition": ["light"]})
	var preview := CardInstance.from_data(CardData.get_card("pawn"))   # owner -1
	check(not light.evaluate(preview), "sideless preview: allegiance-gated grant fails closed")
	var mine := unit("pawn")   # owner 0
	check(light.evaluate(mine), "player unit: the ally-gated run grant reaches it")
	GameData.current_modifiers = ModifierSet.new()
	var plain := CardInstance.from_data(CardData.get_card("pawn"))
	check(not light.evaluate(plain), "no grants: effective == raw composition")


func _has_element_lens() -> void:
	# has_element reads the same effective lens as the composition form — a granted element
	# must satisfy both alike (they'd otherwise disagree about the same unit).
	_fire_grant_status()
	var u := unit("pawn")   # pieces-only, no elements
	var any_element := EffectCondition.from_dict({"has_element": true})
	check(not any_element.evaluate(u), "a pieces-only unit has no element")
	StatusEngine.apply(u, FIRE_GRANT, Effect.STATUS_DURATION_DEFAULT, 1, null)
	check(any_element.evaluate(u), "a granted element satisfies has_element")
	_unregister_status(FIRE_GRANT)


func _negative_gate_respects_grants() -> void:
	# Negative gates CONSUME grants even though grants may not CARRY negative conditions
	# (monotonicity binds Layer 1's own gates, not Layer 2 consumers): a granted queen makes
	# the unit royalty as far as the lackeys-only gate is concerned.
	_register_status({"id": "_test_grant_queen", "display_name": "T", "effects": [
		{"trigger": {"kind": "while"}, "targets": {"kind": "self"}, "grants": ["queen"]}]})
	var u := unit("pawn")
	var lackey_gate := EffectCondition.from_dict({"composition": ["king", "queen"], "present": false})
	check(lackey_gate.evaluate(u), "a plain pawn passes the lackeys-only gate")
	StatusEngine.apply(u, "_test_grant_queen", Effect.STATUS_DURATION_DEFAULT, 1, null)
	check(not lackey_gate.evaluate(u), "a granted queen trips the negative gate")
	_unregister_status("_test_grant_queen")


func _round_trip() -> void:
	var d := {
		"trigger": {"kind": "while"},
		"targets": {"kind": "self"},
		"grants": ["fire", "rook"],
	}
	var e := Effect.from_dict(d)
	check(e.is_composition_grant(), "a while+grants effect is a composition grant")
	check(not e.is_standing() or e.standing_attribute() == "",
			"a grant is invisible to the stat fold (no standing attribute)")
	check_eq(e.to_dict(), d, "grants effect round-trips byte-faithfully")


# ── The COUNT form: two lenses, two questions (user ruling 2026-08-04) ──────────────────
# PRESENCE asks the grant-aware "treated as" lens; COUNT asks the card's real identity.
# A grant says a unit is to be TREATED AS fire — never how MUCH fire it is built from —
# so it has nothing to contribute to a quantity, and a blessed fire pawn is fire but is
# NOT fire_fire. This is also what keeps the count form clear of the Layer-1 fixed point.
func _count_reads_identity_not_grants() -> void:
	_fire_grant_status()
	var double := unit("fire_fire_pawn")   # elements ["fire", "fire"] — really double fire
	var single := unit("fire_pawn")        # elements ["fire"]         — really single fire
	var two_fire := EffectCondition.from_dict({"composition": ["fire"], "count": 2})
	check(two_fire.evaluate(double), "a real fire_fire unit is built from two fire")
	check(not two_fire.evaluate(single), "a single-fire unit is not")

	# THE RULING, as a test: bless the single-fire unit and it stays single fire.
	StatusEngine.apply(single, FIRE_GRANT, Effect.STATUS_DURATION_DEFAULT, 1, null)
	check(EffectCondition.from_dict({"composition": ["fire"]}).evaluate(single),
			"the blessing still answers the PRESENCE question — it is treated as fire")
	check(not two_fire.evaluate(single),
			"…but it does not make the unit count as fire_fire — a grant is not a quantity")

	# And a blessing on a unit with no fire at all cannot manufacture even one.
	var none := unit("pawn")
	StatusEngine.apply(none, FIRE_GRANT, Effect.STATUS_DURATION_DEFAULT, 1, null)
	check(EffectCondition.from_dict({"composition": ["fire"]}).evaluate(none),
			"a blessed pawn is treated as fire")
	check(not EffectCondition.from_dict({"composition": ["fire"], "count": 1}).evaluate(none),
			"…and is built from no fire at all")
	_unregister_status(FIRE_GRANT)


func _count_comparators_and_pools() -> void:
	var double := unit("fire_fire_pawn")
	var single := unit("fire_pawn")
	# The default comparator is "at least" — the common authoring intent.
	check(EffectCondition.from_dict({"composition": ["fire"], "count": 1}).evaluate(double),
			"count defaults to 'at least': two fire satisfies at-least-one")
	check(EffectCondition.from_dict({"composition": ["fire"], "count": 2, "comparator": "eq"}).evaluate(double),
			"an explicit comparator pins it exactly")
	check(not EffectCondition.from_dict({"composition": ["fire"], "count": 2, "comparator": "eq"}).evaluate(single),
			"…and excludes the single-fire unit")
	check(EffectCondition.from_dict({"composition": ["fire"], "count": 1, "comparator": "eq"}).evaluate(single),
			"exactly-one admits the single-fire unit")
	# Occurrences across the listed ids are SUMMED: the list is a POOL to count from.
	check(EffectCondition.from_dict({"composition": ["fire", "water"], "count": 2}).evaluate(double),
			"a multi-id list counts the pool: two fire fills a two-from-{fire,water} ask")
	# Pieces count on the same footing as elements.
	check(EffectCondition.from_dict({"composition": ["pawn"], "count": 1}).evaluate(double),
			"chess pieces are counted by the same lens")
	check(not EffectCondition.from_dict({"composition": ["rook"], "count": 1}).evaluate(double),
			"…and a piece it doesn't have counts zero")


func _count_round_trips() -> void:
	var d := {"composition": ["fire"], "count": 2, "comparator": "gte"}
	check_eq(EffectCondition.from_dict(d).to_dict(), d, "the count form round-trips byte-faithfully")
	# The presence form must be untouched by the addition (no stray count/comparator keys).
	var p := {"composition": ["fire"], "present": true}
	check_eq(EffectCondition.from_dict(p).to_dict(), p, "the presence form still round-trips as before")
