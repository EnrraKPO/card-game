extends TestCase

# The attack, end to end, under the ONE CRANK: the sequencer fires `act`, dispatch
# unfolds the unit's attack effect like any other, blow-news derives from the Outcomes,
# deaths ride the one death path — headless, under the null presenter, proving the rules
# never needed a screen. Effects here are INLINE fixtures (frozen — the suite must never
# track live content); the library's own loading is pinned separately.


func suite_name() -> String:
	return "Attack system"


func run() -> void:
	_library_loads_the_attack_family()
	_act_unfolds_the_attack()
	_untapped_condition_gates()
	_pacifists_never_swing()
	_repeats_is_dead()
	_news_is_results_retaliation_unfolds()


const MELEE_FIXTURE := {
	"trigger": {"kind": "event", "event": "act", "of": "self",
			"conditions": [{"untapped": true}]},
	"targets": {"kind": "nearest"},
	"payloads": [{"kind": "attack", "amount": {"kind": "holder_stat", "stat": "attack"}}],
}


func _world() -> CombatWorld:
	var w := CombatWorld.make(GameData.current_modifiers)
	w.rewards_live = false
	return w


func _fighter(attack: int, health: int, extra_effects: Array = []) -> CardInstance:
	var def := {"id": "atk_fixture_%d_%d" % [attack, health],
			"display_name": "Fixture", "cost": 1, "attack": attack, "health": health,
			"speed": 1, "chess_pieces": ["pawn"],
			"effects": [MELEE_FIXTURE] + extra_effects}
	return CardInstance.from_data(CardData.build_from_dict(def))


func _bystander(health: int, extra_effects: Array = []) -> CardInstance:
	var def := {"id": "vic_fixture_%d" % health, "display_name": "Victim", "cost": 1,
			"attack": 1, "health": health, "speed": 1, "chess_pieces": ["pawn"],
			"effects": extra_effects}
	return CardInstance.from_data(CardData.build_from_dict(def))


func _place(w: CombatWorld, inst: CardInstance, side: int, r: int, c: int) -> CardInstance:
	inst.owner = side
	w.place_unit(inst, r, c, side)
	return inst


func _act(w: CombatWorld, attacker: CardInstance) -> void:
	var cascade := CombatCascade.make(w, CombatPresenter.new())
	var done: Array = [false]
	var chain := func() -> void:
		await cascade.resolve_event(&"act", attacker)
		done[0] = true
	chain.call()
	check(bool(done[0]), "the act moment completes synchronously under the null presenter")


func _library_loads_the_attack_family() -> void:
	# One named effect per POLICY (signed §8.3) — each loads and points with its species.
	var species := {
		"nearest_attack": TargetResolver.Nearest,
		"leap_attack": TargetResolver.Leap,
		"wounded_attack": TargetResolver.Wounded,
		"tank_attack": TargetResolver.Tank,
		"threat_attack": TargetResolver.Threat,
	}
	for effect_id: String in species:
		var e := EffectLibrary.get_effect(effect_id)
		check(e != null, "the library loads %s from data/effects/" % effect_id)
		if e == null:
			continue
		check(is_instance_of(e.targets, species[effect_id]),
				"%s points with its own species" % effect_id)
	check(EffectLibrary.get_effect("melee_attack") == null,
			"melee_attack is DEAD — renamed nearest_attack")


func _act_unfolds_the_attack() -> void:
	var w := _world()
	var attacker := _place(w, _fighter(2, 5), 0, 1, 3)
	var victim := _place(w, _bystander(4), 1, 1, 0)
	_act(w, attacker)
	check_eq(victim.current_health, 2, "the act moment alone delivers the blow — no separate attack step")
	check_eq(attacker.current_health, 5, "an effect-less victim answers nothing")


func _untapped_condition_gates() -> void:
	var w := _world()
	var attacker := _place(w, _fighter(2, 5), 0, 1, 3)
	var victim := _place(w, _bystander(4), 1, 1, 0)
	attacker.attack_exhausted = true
	_act(w, attacker)
	check_eq(victim.current_health, 4, "a spent action gates the attack out (the untapped condition)")


func _pacifists_never_swing() -> void:
	var w := _world()
	var pacifist := _place(w, _bystander(5), 0, 1, 3)   # no attack effect authored
	var victim := _place(w, _bystander(4), 1, 1, 0)
	_act(w, pacifist)
	check_eq(victim.current_health, 4, "a card referencing no attack effect simply doesn't swing")


func _repeats_is_dead() -> void:
	# The repeats mechanism was nuked 2026-08-12 (Enrra's ruling): an effect authoring the
	# dead key is refused whole, and one act delivers exactly one blow. The kill-crediting
	# checks that rode the old flurry test live on against the single blow.
	var authored := MELEE_FIXTURE.duplicate(true)
	authored["repeats"] = {"kind": "holder_stat", "stat": "strikes"}
	check(TriggeredEffect.parse(authored) == null, "'repeats' is a refused key — the effect is not half-loaded")
	var w := _world()
	var attacker := _place(w, _fighter(3, 5), 0, 1, 3)
	var first := _place(w, _bystander(3), 1, 1, 0)
	var second := _place(w, _bystander(4), 1, 0, 0)
	_act(w, attacker)
	check(not first.is_alive(), "the blow fells the victim")
	check(w.location_of(first) == null, "the corpse left play through the one death path")
	check_eq(first.killed_by_channel, StatMutation.CH_ATTACK, "the kill is credited to the attack channel")
	check(first.killed_by_unit == attacker, "the killer unit is stamped for the kill event")
	check_eq(second.current_health, 4, "one act, one blow — nothing reaches the second unit")


func _news_is_results_retaliation_unfolds() -> void:
	# Blow-news derives from the Outcomes and feeds the same crank: a victim authored with
	# a struck-triggered attack (retaliation) unfolds it the moment the news fires.
	var retaliation := {
		"trigger": {"kind": "dual_event", "event": "struck", "destination_of": "self"},
		"targets": {"kind": "nearest"},
		"payloads": [{"kind": "attack", "amount": 1}],
	}
	var w := _world()
	var attacker := _place(w, _fighter(2, 5), 0, 1, 3)
	var victim := _place(w, _bystander(4, [retaliation]), 1, 1, 0)
	_act(w, attacker)
	check_eq(victim.current_health, 2, "the blow landed")
	check_eq(attacker.current_health, 4, "the struck news unfolded the victim's retaliation through the same dispatch")
