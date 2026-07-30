extends TestCase

# How an encounter's enemy deck is composed (EncounterTemplateData.instantiate): which pool
# entries are eligible at a given difficulty, and in what proportion.
#
# Two rules this suite defends, both user calls of 2026-07-30:
#   1. DIFFICULTY DECIDES WHO IS IN THE POOL, WEIGHTS DECIDE THE SHARES. Power gates entries
#      through their `min_power` anchor and grows the deck's SIZE; it must never reweight the
#      mix. The removed cost skew did exactly that — it inverted authored weights at depth, the
#      rarest entry becoming the commonest card — so flatness is pinned at several powers.
#   2. COMPOSITION IS PROCEDURAL, NOT ROLLED. Weights are apportioned (largest remainder), so a
#      weight-3-of-12 entry takes a quarter of the cards in EVERY fight. Independent sampling was
#      the old shape and it played as noise: all-fodder fights next to no-fodder fights from one
#      template. RNG survives only as a tiebreak between equal remainders — which is itself
#      pinned below, in both directions: it must vary, and it must never move a whole share.


func suite_name() -> String:
	return "Encounter pool"


func run() -> void:
	_weights_hold_at_every_power()
	_shares_are_exact_not_sampled()
	_rng_only_breaks_ties()
	_small_decks_favour_the_heaviest()
	_zero_weight_never_appears()
	_anchors_gate_entries()
	_anchored_pool_fails_open()
	_deck_size_still_ramps()


# A template built in code, so the suite never depends on authored content.
func _template(pool: Array, picks: Array = [12, 12]) -> EncounterTemplateData:
	var t := EncounterTemplateData.new()
	t.id = "_test_pool"
	t.node_type = MapNodeData.Type.COMBAT
	t.enemy_king = "captain_dummy"
	t.enemy_pool = pool
	t.pick_count = picks
	return t


func _entry(id: String, weight: float, min_power: float = 0.0) -> Dictionary:
	return {"id": id, "weight": weight, "min_power": min_power}


# Tally of card id → share of the decks drawn over many rolls.
func _shares(t: EncounterTemplateData, power: float, rolls: int = 200) -> Dictionary:
	var counts: Dictionary = {}
	var total := 0
	for i in rolls:
		var rng := RandomNumberGenerator.new()
		rng.seed = 7000 + i
		for id: String in t.instantiate(rng, power).enemy_deck:
			counts[id] = int(counts.get(id, 0)) + 1
			total += 1
	var out: Dictionary = {}
	for id: String in counts:
		out[id] = float(counts[id]) / float(maxi(total, 1))
	return out


# The card counts of ONE roll, keyed by id — what a single fight actually fields.
func _counts(t: EncounterTemplateData, power: float, seed_v: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var out: Dictionary = {}
	for id: String in t.instantiate(rng, power).enemy_deck:
		out[id] = int(out.get(id, 0)) + 1
	return out


# The heart of it: a cheap unit weighted 3 against a costly one weighted 1 keeps its 3:1 share
# at power 0 and at depth alike. Under the old cost skew this inverted.
func _weights_hold_at_every_power() -> void:
	var t := _template([_entry("fodder_dummy", 3.0), _entry("dummy_group_heal", 1.0)])
	for power: float in [0.0, 5.0, 12.0, 20.0]:
		var shares := _shares(t, power)
		var cheap := float(shares.get("fodder_dummy", 0.0))
		var costly := float(shares.get("dummy_group_heal", 0.0))
		check(absf(cheap - 0.75) < 0.05,
				"power %.0f: the weight-3 entry keeps ~75%% of the deck, got %.1f%%"
				% [power, cheap * 100.0])
		check(cheap > costly * 2.0,
				"power %.0f: the weight-3 cheap unit still outnumbers the weight-1 costly one"
				% power)


# The apportionment itself: 12 cards over weights 3:1 is 9 and 3 — in every fight, from every
# seed. This is the property independent sampling could not give at any weighting.
func _shares_are_exact_not_sampled() -> void:
	var t := _template([_entry("fodder_dummy", 3.0), _entry("dummy_group_heal", 1.0)])
	for s in 12:
		var c := _counts(t, 0.0, 500 + s)
		check_eq(int(c.get("fodder_dummy", 0)), 9,
				"seed %d: the weight-3 entry takes exactly three quarters of 12 cards" % s)
		check_eq(int(c.get("dummy_group_heal", 0)), 3,
				"seed %d: …and the weight-1 entry exactly one quarter" % s)

	# Three-way, uneven, and a deck size that divides cleanly: 2/1/1 over 12 → 6/3/3.
	var t3 := _template([_entry("fodder_dummy", 2.0), _entry("tank_dummy", 1.0),
			_entry("dps_dummy", 1.0)])
	var c3 := _counts(t3, 0.0, 77)
	check_eq(int(c3.get("fodder_dummy", 0)), 6, "2:1:1 over 12 cards puts 6 on the heaviest")
	check_eq(int(c3.get("tank_dummy", 0)), 3, "…3 on the second")
	check_eq(int(c3.get("dps_dummy", 0)), 3, "…and 3 on the third")


# What RNG is still allowed to do, and what it is not. Equal weights over an ODD deck: someone
# must get the spare card, and which one varies by seed — but the two whole shares never move.
func _rng_only_breaks_ties() -> void:
	var t := _template([_entry("fodder_dummy", 1.0), _entry("tank_dummy", 1.0)], [9, 9])
	var seen_fodder_high := false
	var seen_tank_high := false
	for s in 24:
		var c := _counts(t, 0.0, 900 + s)
		var f := int(c.get("fodder_dummy", 0))
		var k := int(c.get("tank_dummy", 0))
		check_eq(f + k, 9, "seed %d: the whole deck is dealt out" % s)
		check(mini(f, k) == 4 and maxi(f, k) == 5,
				"seed %d: an equal-weight pair splits 9 as 4/5 — the tie moves ONE card, "
				% s + "got %d/%d" % [f, k])
		if f > k:
			seen_fodder_high = true
		else:
			seen_tank_high = true
	check(seen_fodder_high and seen_tank_high,
			"…and which side gets the spare genuinely varies with the seed (never fixed to "
			+ "whoever was authored first)")


# A deck smaller than the pool: no entry earns a whole share, so the leftovers go strictly to the
# biggest fractions — the heaviest entries, deterministically.
func _small_decks_favour_the_heaviest() -> void:
	var t := _template([_entry("fodder_dummy", 5.0), _entry("tank_dummy", 1.0),
			_entry("dps_dummy", 1.0)], [1, 1])
	for s in 8:
		var c := _counts(t, 0.0, 300 + s)
		check_eq(int(c.get("fodder_dummy", 0)), 1,
				"seed %d: a one-card deck goes to the weight-5 entry, never a light one" % s)


# Weight 0 means "not in this fight" — including when leftover cards are handed out.
func _zero_weight_never_appears() -> void:
	var t := _template([_entry("fodder_dummy", 1.0), _entry("dummy_group_heal", 0.0)], [7, 7])
	for s in 8:
		var c := _counts(t, 0.0, 400 + s)
		check_eq(int(c.get("dummy_group_heal", 0)), 0,
				"seed %d: a zero-weight entry never receives a card, spare or otherwise" % s)
		check_eq(int(c.get("fodder_dummy", 0)), 7, "…and the rest of the deck absorbs its share")


# An anchor keeps a unit out of the fight entirely until its power, and lets it in after.
func _anchors_gate_entries() -> void:
	var t := _template([_entry("fodder_dummy", 1.0), _entry("dps_dummy", 1.0, 8.0)])
	var early := _shares(t, 7.9)
	check(not early.has("dps_dummy"), "below its anchor the unit never appears")
	check(absf(float(early.get("fodder_dummy", 0.0)) - 1.0) < 0.0001,
			"…and the unanchored entry fills the whole deck")

	var at_anchor := _shares(t, 8.0)
	check(at_anchor.has("dps_dummy"), "AT its anchor the unit joins (the gate is inclusive)")
	var deep := _shares(t, 20.0)
	check(absf(float(deep.get("dps_dummy", 0.0)) - 0.5) < 0.05,
			"…and past it, equal weights mean an equal share — the anchor is a gate, not a bias")


# Anchoring every entry above the fight's power would leave it with no units at all, which is
# never what an author meant: the roll falls open on the whole pool rather than fielding a lone
# captain. (The Tool refuses to save such a pool; this is the runtime's own backstop.)
func _anchored_pool_fails_open() -> void:
	var t := _template([_entry("fodder_dummy", 1.0, 5.0), _entry("dps_dummy", 1.0, 9.0)])
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var enc := t.instantiate(rng, 0.0)
	check(enc.enemy_deck.size() > 0, "an all-anchored pool still yields a deck")

	# An EMPTY pool is the honest way to author "no units" and stays empty.
	var bare := _template([])
	check_eq(bare.instantiate(rng, 0.0).enemy_deck.size(), 0, "an empty pool draws nothing")


# Power still grows the deck's SIZE — the lever that survived (POWER_SIZE_GROWTH).
func _deck_size_still_ramps() -> void:
	var t := _template([_entry("fodder_dummy", 1.0)], [10, 10])
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	check_eq(t.instantiate(rng, 0.0).enemy_deck.size(), 10, "at power 0 the deck is pick_count")
	check_eq(t.instantiate(rng, 10.0).enemy_deck.size(),
			10 + int(round(10.0 * EncounterTemplateData.POWER_SIZE_GROWTH)),
			"power adds cards at POWER_SIZE_GROWTH per point")
