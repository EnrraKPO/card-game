extends TestCase

# The Arbitrator contract: single writer, resolution forms (shield-first damage, signed health,
# shield floor), set-form helpers, the DeckCard override target, and the stat vocabulary.


func suite_name() -> String:
	return "Arbitrator"


func run() -> void:
	_damage_form()
	_health_form()
	_modifier_form()
	_shield_form_and_helpers()
	_deck_card_target()
	_vocabulary()
	_null_safety()
	_kill_stamping()


func _damage_form() -> void:
	var u := unit("rook")   # 6 HP, 3 shield
	var out := Arbitrator.submit(StatMutation.damage(u, 5, null))
	check_eq(out.shield_absorbed, 3, "damage 5 vs 3 shield: shield absorbs 3")
	check_eq(out.health_damage, 2, "damage 5 vs 3 shield: 2 bleeds through")
	check_eq(out.delta, -5, "damage outcome delta = total landed, negative")
	check_eq(u.current_shield, 0, "shield pool emptied")
	check_eq(u.current_health, 4, "health pool wounded by the bleed only")

	var whiff := Arbitrator.submit(StatMutation.damage(u, -4, null))
	check_eq(whiff.delta, 0, "sub-zero damage lands 0 (never heals)")
	check_eq(u.current_health, 4, "health untouched by sub-zero damage")


func _health_form() -> void:
	var u := unit("rook")
	Arbitrator.submit(StatMutation.make(u, StatMutation.HEALTH, -2, null))
	check_eq(u.current_health, 4, "direct -2 health bypasses shield (poison form)")
	check_eq(u.current_shield, 3, "shield untouched by direct health change")

	var heal := Arbitrator.submit(StatMutation.make(u, StatMutation.HEALTH, 99, null))
	check_eq(u.current_health, 6, "heal clamps to max")
	check_eq(heal.delta, 2, "heal outcome reports the LANDED delta, not the request")

	var full := Arbitrator.submit(StatMutation.make(u, StatMutation.HEALTH, 5, null))
	check_eq(full.delta, 0, "heal at full HP lands 0")


func _modifier_form() -> void:
	var u := unit("rook")
	var atk0 := u.get_attribute("attack")
	var out := Arbitrator.submit(StatMutation.make(u, StatMutation.ATTACK, 2, null))
	check_eq(u.get_attribute("attack"), atk0 + 2, "modifier mutation folds into get_attribute")
	check_eq(out.delta, 2, "modifier outcome carries the delta")


func _shield_form_and_helpers() -> void:
	var u := unit("rook")
	Arbitrator.submit(StatMutation.damage(u, 5, null))   # shield 0, HP 4
	Arbitrator.restore_shield(u)
	check_eq(u.current_shield, 3, "restore_shield refills to base")

	Arbitrator.submit(StatMutation.make(u, StatMutation.SHIELD_POOL, 2, null))
	check_eq(u.current_shield, 5, "SHIELD_POOL mutation adds to the live pool")
	var floored := Arbitrator.submit(StatMutation.make(u, StatMutation.SHIELD_POOL, -99, null))
	check_eq(u.current_shield, 0, "shield pool floors at 0")
	check_eq(floored.delta, -5, "shield outcome reports the ACTUAL change under the floor")

	# Plain SHIELD is the per-round BASE (a modifier): it raises what restore_shield refills to.
	Arbitrator.submit(StatMutation.make(u, StatMutation.SHIELD, 1, null))
	Arbitrator.restore_shield(u)
	check_eq(u.current_shield, 4, "SHIELD modifier raises the per-round refill target")

	Arbitrator.set_health(u, 2)
	check_eq(u.current_health, 2, "set_health lands the absolute value")
	Arbitrator.fill_health(u)
	check_eq(u.current_health, u.get_attribute("max_health"), "fill_health tops up to effective max")


func _deck_card_target() -> void:
	var dc := DeckCard.make("pawn")
	var base_atk := CardData.get_card("pawn").attack
	Arbitrator.submit(StatMutation.make(dc, StatMutation.ATTACK, 1, null, StatMutation.CH_SYSTEM))
	var inst := dc.make_instance()
	check_eq(inst.data.attack, base_atk + 1, "DeckCard target bumps the persistent override")
	check(not dc.override.is_empty(), "override materialised on first edit")


func _vocabulary() -> void:
	check_eq(StatMutation.stat_for_attribute("health"), StatMutation.HEALTH,
			"attribute 'health' maps to the signed HEALTH form")
	check_eq(StatMutation.stat_for_attribute("damage_taken"), StatMutation.DAMAGE,
			"attribute 'damage_taken' maps to the shield-first DAMAGE form")
	check_eq(StatMutation.stat_for_attribute("attack"), StatMutation.ATTACK,
			"any other attribute passes through as a modifier stat")


func _null_safety() -> void:
	check_eq(Arbitrator.submit(null).delta, 0, "null mutation -> empty outcome, no crash")
	check_eq(Arbitrator.submit(StatMutation.make(null, StatMutation.HEALTH, 5, null)).delta, 0,
			"null target -> empty outcome, no crash")


# The Arbitrator records the fatal blow's provenance at the lethal HP crossing (killed_by_*),
# which combat reads to fire the `kill` event.
func _kill_stamping() -> void:
	# An attack kill credits the striker as the killer unit; kind = attack.
	var striker := unit("rook")
	var victim := unit("pawn")   # low HP
	victim.current_health = 1
	victim.current_shield = 0
	Arbitrator.submit(StatMutation.damage(victim, 99, striker))
	check(victim.current_health <= 0, "attack took the victim to <= 0")
	check_eq(victim.killed_by_unit, striker, "attack kill credits the striker as killer unit")
	check_eq(victim.killed_by_channel, StatMutation.CH_ATTACK, "attack kill kind = attack")

	# A poison-form kill (a HEALTH mutation carrying cause "poison") credits NO unit — the
	# cause names it. This is the "died from poison" provenance.
	var v2 := unit("pawn")
	v2.current_health = 1
	var pm := StatMutation.make(v2, StatMutation.HEALTH, -5, v2)   # holder = victim, as a real tick
	pm.cause = &"poison"
	Arbitrator.submit(pm)
	check(v2.current_health <= 0, "poison took the victim to <= 0")
	check_eq(v2.killed_by_unit, null, "poison kill credits no killer unit")
	check_eq(v2.killed_by_cause, &"poison", "poison kill records the status id as the cause")

	# Overkill by a later blow can't overwrite the first killer (the pre > 0 guard).
	Arbitrator.submit(StatMutation.damage(v2, 99, striker))
	check_eq(v2.killed_by_cause, &"poison", "a post-mortem blow doesn't rewrite the killer")
