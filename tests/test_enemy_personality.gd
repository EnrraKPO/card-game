extends TestCase

# The personality layer (EnemyPersonality + BoardScoring.stock): an authored character is a
# set of criterion weights, and nothing else. What this suite defends:
#
#   1. NO PERSONALITY = THE OLD ENGINE. An absent file, an unknown id, a null personality —
#      every one of them must produce exactly the scorer the engine had before personalities
#      existed. The feature is authoring surface, not a behaviour change, and if it ever
#      silently becomes one this is where it shows.
#   2. A CORE TRAIT IS ALWAYS PRESENT; a blank one keeps the stock weight. Core traits are
#      what makes the CPU function, so a personality can only ever re-price them.
#   3. A QUIRK IS OPT-IN. Not listing it removes the criterion from the scorer entirely —
#      the one mechanical consequence of the tool's core/quirk split.
#   4. WEIGHTS REACH THE DECISION. A criterion built at a different weight must be able to
#      change what the engine picks; a personality that only decorates the criterion dump is
#      the failure mode worth pinning (same lesson as _idle_hand_changes_a_decision).
#
# The suite owns its personalities in code — it never reads data/enemy_personalities.json, so
# retuning the shipped starters can never break it.


func suite_name() -> String:
	return "Enemy personality"


func run() -> void:
	_stock_is_the_old_engine()
	_unknown_id_degrades_to_stock()
	_core_traits_are_always_present()
	_blank_core_trait_keeps_the_stock_weight()
	_quirks_are_opt_in()
	_survival_weights_layer_encounter_over_personality()
	_absent_quirks_key_inherits_stock()
	_personality_changes_a_decision()
	_value_rates_layer_over_the_global_price_list()
	_ability_price_specificity()
	_encounter_carries_its_own_instance()
	EnemyPersonality.set_all([])   # release the injected set for the rest of the run


# A criterion id → weight reading of a built scorer: what the engine will actually run.
func _built(personality: EnemyPersonality, overrides: Dictionary = {}) -> Dictionary:
	var scoring := BoardScoring.stock(overrides, personality)
	var out: Dictionary = {}
	for c: BoardScoring.Criterion in scoring.criteria:
		out[c.id] = c.weight
	return out


func _personality(d: Dictionary) -> EnemyPersonality:
	return EnemyPersonality.from_dict(d)


# The whole safety property in one test: the no-personality scorer is the const-defined
# stock character — every core trait plus the stock quirks, and NONE of the parked trio
# (death risk / harm / board value are opt-in quirks since the valuation system,
# 2026-07-30; a null personality must not resurrect them).
func _stock_is_the_old_engine() -> void:
	var built := _built(null)
	var want: Array = EnemyPersonality.core_ids() + EnemyPersonality.stock_quirks().keys()
	check_eq(built.size(), want.size(),
			"with no personality the scorer runs every core trait and the stock quirk")
	var defaults := EnemyPersonality.stock_weights()
	for id: String in want:
		check(built.has(id), "criterion '%s' is in the stock scorer" % id)
		check(absf(float(built.get(id, -1.0)) - float(defaults[id])) < 0.00001,
				"…at its code-default weight (%s = %.3f)" % [id, float(defaults[id])])
	for parked: String in ["death_risk", "harm", "board_value"]:
		check(not built.has(parked), "parked criterion '%s' stays out of the stock scorer" % parked)


# An encounter naming a personality that no longer exists must still fight.
func _unknown_id_degrades_to_stock() -> void:
	EnemyPersonality.set_all([{"id": "only_one", "traits": {"mana": 0.1}}])
	var missing := EnemyPersonality.get_personality("deleted_last_week")
	check_eq(missing.id, EnemyPersonality.DEFAULT_ID, "an unknown id resolves to the stock character")
	check(absf(missing.weight_for("mana") - BoardScoring.MANA_CRITERION_WEIGHT) < 0.00001,
			"…carrying the code-default weights, not the surviving personality's")
	check_eq(EnemyPersonality.get_personality("only_one").weight_for("mana"), 0.1,
			"…while the id that DOES exist resolves to its own weights")
	# An empty name is the "never authored" case, not an error.
	check_eq(EnemyPersonality.get_personality("").id, EnemyPersonality.DEFAULT_ID,
			"an empty personality name is the stock character too")
	EnemyPersonality.set_all([])


# Core traits are the engine's working parts: a personality re-prices them, never drops them.
func _core_traits_are_always_present() -> void:
	var bare := _built(_personality({"id": "bare", "traits": {}, "quirks": {}}))
	for id: String in EnemyPersonality.core_ids():
		check(bare.has(id), "core trait '%s' is present even in a personality that states nothing" % id)


func _blank_core_trait_keeps_the_stock_weight() -> void:
	var p := _personality({"id": "loud_mana", "traits": {"mana": 2.0}, "quirks": {}})
	var built := _built(p)
	check_eq(float(built.get("mana", -1.0)), 2.0, "an authored core weight is what the criterion runs at")
	check(absf(float(built.get("idle_hand", -1.0)) - BoardScoring.IDLE_HAND_CRITERION_WEIGHT) < 0.00001,
			"…and every trait it did NOT mention keeps the stock weight")


# The one mechanical consequence of the core/quirk split.
func _quirks_are_opt_in() -> void:
	var without := _built(_personality({"id": "no_quirks", "quirks": {}}))
	check(not without.has("damage_output"),
			"a personality that lists no quirks does not run the damage criterion at all")

	var with_quirk := _built(_personality({"id": "bloodthirsty", "quirks": {"damage_output": 0.9}}))
	check_eq(float(with_quirk.get("damage_output", -1.0)), 0.9,
			"…and a carried quirk runs at the weight the personality gave it")


# Two layers of survival weights, and which one wins. The personality states the character's
# standing protect ordering; the encounter's own table is the per-fight amendment on top.
# Read through DeathRisk, which the coward opts back in as a quirk — this doubles as the pin
# that a PARKED criterion is still whole for any personality that wants it.
func _survival_weights_layer_encounter_over_personality() -> void:
	var p := _personality({"id": "coward", "survival_weights": {"captain": 2.5, "fodder": 0.4},
			"quirks": {"death_risk": 1.0}})
	var scoring := BoardScoring.stock({"captain": 1.0}, p)
	var risk: BoardScoring.DeathRisk = null
	for c: BoardScoring.Criterion in scoring.criteria:
		if c is BoardScoring.DeathRisk:
			risk = c
	check(risk != null, "the parked death-risk criterion is built when a quirk asks for it")
	check_eq(float(risk.survival_weights.get("captain", -1.0)), 1.0,
			"the ENCOUNTER's survival weight overrides the personality's for the same key")
	check_eq(float(risk.survival_weights.get("fodder", -1.0)), 0.4,
			"…while the personality's other entries stand")
	check_eq(float(risk.survival_weights.get("support", -1.0)),
			float(BoardScoring.STOCK_SURVIVAL_WEIGHTS["support"]),
			"…and anything neither of them mentions keeps the stock table's value")


# The absent-vs-empty distinction, made once in from_dict: a hand-written personality that
# never mentions quirks must not silently lose the default's aggression.
func _absent_quirks_key_inherits_stock() -> void:
	var silent := _personality({"id": "silent", "traits": {"harm": 0.9}})
	check(silent.has_quirk("damage_output"),
			"a personality with no 'quirks' key at all inherits the stock quirks")
	var explicit := _personality({"id": "explicit", "traits": {"harm": 0.9}, "quirks": {}})
	check(not explicit.has_quirk("damage_output"),
			"…while an explicitly EMPTY quirks object means exactly what it says")


# The anti-decoration pin: a personality has to be able to change what the CPU does. Scored
# through the real scorer on one staged position — a wounded ally in danger next to an idle
# hand — a fearful character and a greedy one must not agree.
func _personality_changes_a_decision() -> void:
	var state := _staged_state()
	# The fearful character opts the parked death-risk quirk back in at full voice; the
	# greedy one runs the stock core and shouts about the idle hand instead.
	var fearful := BoardScoring.stock({}, _personality({"id": "fearful",
			"traits": {"idle_hand": 0.1}, "quirks": {"death_risk": 3.0}}))
	var greedy := BoardScoring.stock({}, _personality({"id": "greedy",
			"traits": {"idle_hand": 3.0}, "quirks": {}}))
	var fear_score := fearful.score(state)
	var greed_score := greedy.score(state)
	check(absf(fear_score - greed_score) > 0.5,
			"the same position reads very differently to a fearful character than to a greedy one "
			+ "(%.3f vs %.3f) — the weights reach the score, they are not decoration"
			% [fear_score, greed_score])

	# And the ordering of the two charges is inverted between them, which is the behaviour the
	# weights are supposed to buy: fear dominated by the dying unit, greed by the idle hand.
	var no_hand := _staged_state()
	no_hand.hand_unit_costs = []
	check(greedy.score(no_hand) - greed_score > fearful.score(no_hand) - fear_score,
			"emptying the hand is worth more to the greedy character than to the fearful one")


# Eval PARAMETERS are per-fight too, not just eval weights (user call 2026-07-30): a
# personality carries its own unit-value price list, laid over the global one KEY BY KEY — so
# a fight that re-prices shields says only that, and every other price still comes from the
# global config. A whole-table replacement would make the partial form a silent trap.
func _value_rates_layer_over_the_global_price_list() -> void:
	BoardValueConfig.set_config({"stat_rates": {"attack": 1.0, "health": 1.0, "shield": 2.0,
			"missing_health": 0.1, "speed": 0.5}, "ability_default": 2.0})
	var u := BoardState.UnitState.new()
	u.owner = 1
	u.attack = 3
	u.strikes = 1
	u.health = 4
	u.max_health = 4
	u.shield = 2
	u.speed = 2

	var globally := BoardScoring.unit_value(u)
	check(absf(globally - (3.0 + 4.0 + 4.0 + 1.0)) < 0.0001,
			"with no personality a unit is priced by the global list (got %.2f)" % globally)

	var shield_lover := _personality({"id": "shield_lover", "value_rates": {"stat_rates": {"shield": 5.0}}})
	var priced := BoardScoring.unit_value(u, shield_lover)
	check(absf(priced - (3.0 + 4.0 + 10.0 + 1.0)) < 0.0001,
			"the personality's own shield price is used (got %.2f, want 18.00)" % priced)
	check(absf(shield_lover.stat_rate("attack") - 1.0) < 0.0001,
			"…and a price it did NOT mention still falls through to the global list")

	# The criterion must actually read it — a price list nothing consults is decoration.
	var state := BoardState.empty()
	state.place(u, 0, 0)
	check(absf(BoardScoring.board_value(state, shield_lover) - priced) < 0.0001,
			"board value measures through the fight's price list")
	BoardValueConfig.set_config({})


# Specificity beats locality: a price authored for ONE ability outranks a character's blanket
# rate, but the character's price for that same ability outranks both.
func _ability_price_specificity() -> void:
	BoardValueConfig.set_config({"ability_default": 2.0, "ability_values": {"heal": 6.0}})
	var blanket := _personality({"id": "blanket", "value_rates": {"ability_default": 9.0}})
	check_eq(blanket.ability_value("heal"), 6.0,
			"a globally priced ability keeps its price against a character's blanket rate")
	check_eq(blanket.ability_value("castling"), 9.0,
			"…while an unpriced ability takes the character's blanket rate")
	var specific := _personality({"id": "specific",
			"value_rates": {"ability_default": 9.0, "ability_values": {"heal": 1.0}}})
	check_eq(specific.ability_value("heal"), 1.0,
			"…and the character's own price for that ability beats the global one")
	BoardValueConfig.set_config({})


# The encounter owns a COPY, not a reference (user call 2026-07-30). Both authored forms
# resolve to an instance, and tuning one fight can never reach another.
func _encounter_carries_its_own_instance() -> void:
	EnemyPersonality.set_all([{"id": "brave", "traits": {"death_risk": 0.4}, "quirks": {}}])
	var rng := RandomNumberGenerator.new()
	rng.seed = 5

	var named := EncounterTemplateData.new()
	named.id = "_t_named"
	named.enemy_pool = [{"id": "fodder_dummy", "weight": 1.0, "min_power": 0.0}]
	named.pick_count = [2, 2]
	named.personality = EncounterTemplateData._read_personality("brave")
	check_eq(named.instantiate(rng, 0.0).personality.weight_for("death_risk"), 0.4,
			"naming a template instantiates it for the fight")

	var own := EncounterTemplateData.new()
	own.id = "_t_own"
	own.enemy_pool = named.enemy_pool
	own.pick_count = [2, 2]
	own.personality = EncounterTemplateData._read_personality({
		"from": "brave", "traits": {"death_risk": 2.2}, "quirks": {"damage_output": 0.5}})
	var mine := own.instantiate(rng, 0.0).personality
	check_eq(mine.weight_for("death_risk"), 2.2, "an inline object is the fight's own tuned instance")
	check_eq(mine.from_template, "brave", "…which remembers the template it was copied from")
	check_eq(EnemyPersonality.get_personality("brave").weight_for("death_risk"), 0.4,
			"…and tuning the copy never reaches the template it came from")

	var bare := EncounterTemplateData.new()
	bare.id = "_t_bare"
	bare.enemy_pool = named.enemy_pool
	bare.pick_count = [2, 2]
	check(bare.personality == null, "a template that never mentions a personality holds none…")
	check(bare.instantiate(rng, 0.0).personality != null,
			"…and instantiating one still hands combat a personality (the stock character)")
	EnemyPersonality.set_all([])


# A CPU unit in mortal danger, an idle affordable body in hand, and a choice that spent
# nothing — the position both charges speak about at once.
func _staged_state() -> BoardState:
	var state := BoardState.empty()
	var u := BoardState.UnitState.new()
	u.card_id = "dps_dummy"
	u.owner = 1
	u.role = "dps"
	u.health = 1
	u.max_health = 6
	u.attack = 2
	u.strikes = 1
	u.speed = 1
	state.place(u, 0, 0)
	state.player_mana = 6
	state.enemy_mana_total = 3
	state.enemy_mana_left = 3
	state.mana_capacity_before = 3
	state.mana_spent_step = 0
	state.hand_budget_before = 3
	state.hand_costs = [2]
	state.hand_unit_costs = [2]
	return state
