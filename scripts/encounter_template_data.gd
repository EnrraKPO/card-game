class_name EncounterTemplateData
extends RefCounted

var id: String = ""
var node_type: MapNodeData.Type = MapNodeData.Type.COMBAT
var min_floor: int = 0
var max_floor: int = 999
# Stage (act) band this template is eligible for — the difficulty-scaling knob. Author
# tougher templates (bigger enemy_pool / pick_count / stats) tagged to later stages.
var min_stage: int = 1
var max_stage: int = 999
var weight: float = 1.0
# Array[{ "id": String, "weight": float, "min_power": float }] — the units this encounter can
# field, what SHARE of the deck each takes, and the difficulty each is ANCHORED to. An entry is
# simply absent until the fight's power reaches its min_power (0 = always eligible); among the
# unlocked entries the weights are apportioned, not rolled (see compose_deck / _eligible_pool).
var enemy_pool: Array = []
# The card id placed in the enemy's king slot — its win-condition unit. Defaults to the
# generic "king"; tribe encounters name a themed Captain (an is_king enemy_only card).
var enemy_king: String = "king"
var pick_count: Array = [1, 1]    # [min, max] inclusive
var gold_reward: Array = [0, 0]      # [min, max] inclusive
var mineral_reward: Array = [0, 0]   # [min, max] authored Magic Mineral (default rides on top)
var exp_reward: int = 1           # profile experience for winning this fight (special fights author more)
var ai: String = "default"
var reward_pool: String = "default"
# Optional role→weight entries layered over the enemy engine's stock survival-weight table
# (see BoardScoring / EncounterData.survival_weights).
var survival_weights: Dictionary = {}
# The authored enemy PERSONALITY this fight is fought with (EnemyPersonality id) — the
# criterion weights the enemy engine scores with, i.e. how aggressive / careful / greedy this
# opponent is. "default" or an unknown id = the stock character.
var personality: String = EnemyPersonality.DEFAULT_ID
# Chance (0..1) this fight also offers a relic on the reward screen, alongside the card pick.
var relic_reward_chance: float = 0.0

# Extra power on top of the depth-derived value (authored per template) — lets elites/bosses
# be tougher than a plain combat at the same floor without separate scaling code.
var power_bonus: float = 0.0

# ── Procedural difficulty (power) tuning ──────────────────────────────────────
# `power` = how deep the player is. It drives the procedural levers below (deck size, which pool
# entries are unlocked, and — via CardData.scaled — per-card stats), so ONE curve shapes the whole
# difficulty ramp. See power_for_depth() for how run depth maps to power.
const POWER_PER_FLOOR  := 1.0    # peak power at the final boss ≈ POWER_PER_FLOOR * deepest floor
# Shape of the depth→power ramp. 1.0 = linear (constant slope, the old behaviour). >1 = gentle at
# the start and steep later: the first fights sit near power 0 (very easy) while deep fights ramp
# up hard. This is the knob to turn if the early/late balance still feels off.
const POWER_CURVE_EXP  := 1.7
const POWER_SIZE_GROWTH := 0.5   # extra enemy-deck cards per point of power
# (per-card stat growth lives on CardData.POWER_STAT_GROWTH, used by CardData.scaled)
#
# ⚠ THE COST SKEW IS GONE (user call 2026-07-30). A deep fight used to reweight the pool by card
# cost — exp(BIAS × power × (cost − pool midpoint)) — which quietly OVERRODE the authored weights
# and hit the cheapest entry hardest: measured on test_dummies, the weight-3 fodder fell from 2.08
# cards per deck at power 0 to 1.75 at power 11.7 while the weight-1, cost-4 group heal climbed
# from 0.82 to 3.83. The rarest authored entry became the most common card in the deck, and an
# author reading the weights had no way to see it coming. Difficulty now shapes the mix through
# ANCHORS instead (per-entry min_power): an author says when a unit joins the fight, and from then
# on the weights mean exactly what they say. Do not reintroduce an implicit cost skew.


# Maps how deep the player is (global floor, 0 at the first fight) to encounter power. A convex
# ramp (POWER_CURVE_EXP > 1) keeps early fights near power 0 (gentle) and then climbs steeply toward
# the deepest floor. Normalised so the deepest floor still peaks at the same power the old linear
# ramp did (POWER_PER_FLOOR * deepest floor) — only the SHAPE of the curve changes, not the ceiling.
static func power_for_depth(global_floor: int) -> float:
	var max_depth := float(MapData.STAGES * MapData.FLOORS - 1)
	if global_floor <= 0 or max_depth <= 0.0:
		return 0.0
	var t := clampf(float(global_floor) / max_depth, 0.0, 1.0)
	return POWER_PER_FLOOR * max_depth * pow(t, POWER_CURVE_EXP)

static var _all: Array = []  # Array[EncounterTemplateData]


# Every loaded template — the Combat Gym's listing source (selection flows use pick_for).
static func all() -> Array:
	return _all


# ── Loading ─────────────────────────────────────────────────────────────────

static func _static_init() -> void:
	var dir := DirAccess.open("res://data/encounters/")
	if dir == null:
		push_error("EncounterTemplateData: cannot open res://data/encounters/")
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/encounters/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("EncounterTemplateData: cannot open " + path)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("EncounterTemplateData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = []
	if json.data is Array:
		entries = json.data
	else:
		entries = [json.data]
	for d: Dictionary in entries:
		if not bool(d.get("enabled", true)):
			continue
		_all.append(_from_dict(d))


static func _from_dict(d: Dictionary) -> EncounterTemplateData:
	var t := EncounterTemplateData.new()
	t.id          = d.get("id", "")
	t.node_type   = _str_node_type(d.get("node_type", "combat"))
	t.min_floor   = d.get("min_floor", 0)
	t.max_floor   = d.get("max_floor", 999)
	t.min_stage   = d.get("min_stage", 1)
	t.max_stage   = d.get("max_stage", 999)
	t.weight      = d.get("weight", 1.0)
	t.ai          = d.get("ai", "default")
	t.enemy_king  = d.get("enemy_king", "king")
	t.power_bonus = float(d.get("power_bonus", 0.0))
	t.reward_pool = d.get("reward_pool", "default")
	t.relic_reward_chance = float(d.get("relic_reward", 0.0))
	t.survival_weights = d.get("survival_weights", {})
	t.personality = String(d.get("personality", EnemyPersonality.DEFAULT_ID))
	t.exp_reward  = int(d.get("exp_reward", 1))
	var pc: Array = d.get("pick_count", [1, 1])
	t.pick_count  = [pc[0], pc[0] if pc.size() < 2 else pc[1]]
	var gr: Array = d.get("gold_reward", [0, 0])
	t.gold_reward = [gr[0], gr[0] if gr.size() < 2 else gr[1]]
	var mr: Array = d.get("mineral_reward", [0, 0])
	t.mineral_reward = [mr[0], mr[0] if mr.size() < 2 else mr[1]]
	for e: Dictionary in d.get("enemy_pool", []):
		t.enemy_pool.append({"id": e.get("id", ""), "weight": e.get("weight", 1.0),
				"min_power": float(e.get("min_power", 0.0))})
	return t


static func _str_node_type(s: String) -> MapNodeData.Type:
	match s:
		"combat": return MapNodeData.Type.COMBAT
		"elite":  return MapNodeData.Type.ELITE
		"boss":   return MapNodeData.Type.BOSS
		"test":   return MapNodeData.Type.TEST
	push_error("EncounterTemplateData: unknown node_type '%s', defaulting to combat" % s)
	return MapNodeData.Type.COMBAT


# ── Selection ───────────────────────────────────────────────────────────────

# Picks a template matching node_type whose floor AND stage bands contain `floor`/`stage`.
# Falls back to ignoring the bands (any template of that node_type) if nothing matches
# exactly, so a gap in authored coverage degrades gracefully instead of crashing.
static func pick_for(p_node_type: MapNodeData.Type, floor: int, stage: int, rng: RandomNumberGenerator) -> EncounterTemplateData:
	var in_band: Array = _all.filter(func(t: EncounterTemplateData) -> bool:
		return t.node_type == p_node_type \
			and floor >= t.min_floor and floor <= t.max_floor \
			and stage >= t.min_stage and stage <= t.max_stage
	)
	var candidates: Array = in_band if not in_band.is_empty() else \
		_all.filter(func(t: EncounterTemplateData) -> bool: return t.node_type == p_node_type)

	if candidates.is_empty():
		push_error("EncounterTemplateData: no template found for node_type %s" % p_node_type)
		return null

	return WeightedRandom.pick(rng, candidates, func(t: EncounterTemplateData) -> float: return t.weight)


# ── Instantiation ───────────────────────────────────────────────────────────

func instantiate(rng: RandomNumberGenerator, power: float = 0.0) -> EncounterData:
	var enc := EncounterData.new()
	enc.type = _encounter_data_type(node_type)
	enc.ai   = EnemyAI.from_key(ai)
	enc.enemy_king = enemy_king
	enc.survival_weights = survival_weights.duplicate()
	enc.personality = personality
	enc.power = maxf(0.0, power + power_bonus)

	# Deck SIZE ramps with power (a bigger deck = more sustain). The mix does not: power decides
	# WHICH entries are unlocked (their anchors), and the authored weights decide the PROPORTIONS
	# among them — see compose_deck, which apportions rather than samples. The per-card STAT
	# scaling is applied later, at deck build (combat._init_enemy_deck), from enc.power.
	var count: int = rng.randi_range(pick_count[0], pick_count[1]) \
		+ int(round(enc.power * POWER_SIZE_GROWTH))
	enc.enemy_deck = compose_deck(_eligible_pool(enc.power), count, rng)

	enc.gold_reward = rng.randi_range(gold_reward[0], gold_reward[1])
	enc.mineral_reward = rng.randi_range(mineral_reward[0], mineral_reward[1])
	enc.exp_reward  = exp_reward
	if enc.type == EncounterData.Type.ELITE:
		# Elites ("epic" fights) grant a special reward instead of cards: a choice of relics and charms.
		enc.reward_offers = _roll_elite_offers(rng)
	else:
		enc.reward_pool = resolve_reward_pool(reward_pool)
		if relic_reward_chance > 0.0 and rng.randf() < relic_reward_chance:
			enc.relic_offer = _roll_relic_offer(rng)
	return enc


# Elite reward: up to 4 offers mixing relics and charms, balanced by alternating the two pools and
# filling from whichever still has entries when one runs short. Reuses each kind's offer pool (the
# relic pool already filters out relics the player owns), so it degrades gracefully if a pool is thin.
func _roll_elite_offers(rng: RandomNumberGenerator) -> Array:
	const TOTAL := 4
	var relic_kind := ItemKinds.get_kind("relic")
	var charm_kind := ItemKinds.get_kind("charm")
	var relics: Array = relic_kind.offer_pool(TOTAL, rng) if relic_kind != null else []
	var charms: Array = charm_kind.offer_pool(TOTAL, rng) if charm_kind != null else []
	var offers: Array = []
	var ri := 0
	var ci := 0
	while offers.size() < TOTAL and (ri < relics.size() or ci < charms.size()):
		if ri < relics.size():
			offers.append(Grant.make("relic", relics[ri]))
			ri += 1
		if offers.size() >= TOTAL:
			break
		if ci < charms.size():
			offers.append(Grant.make("charm", charms[ci]))
			ci += 1
	return offers


# Average mana cost across the pool — the midpoint the cost bias pivots around.
# ── Deck composition (PROCEDURAL, not sampled — user call 2026-07-30) ─────────────────────
#
# A deck is APPORTIONED to the authored weights, not rolled against them: an entry weighted 3 of a
# total 12 gets a quarter of the cards, this fight and every fight. Independent weighted sampling
# was the previous shape and it read as noise — over a 9-card deck drawn from six entries you get
# fights that are all fodder and fights with no fodder at all, and no amount of weight authoring
# fixes it, because the variance IS the sampler.
#
# Largest-remainder apportionment (Hamilton's method): each entry takes its whole share, then the
# leftover cards — never more than one per entry — go to the largest fractional remainders. RNG
# enters in exactly one place: which of two EQUAL remainders wins a leftover card. That is the
# "small to minimal" influence asked for — two fights from the same template differ by at most a
# card or two, and only where the arithmetic genuinely ties.
#
# `rng` is also what shuffles the result, so the deck isn't served in pool order.
static func compose_deck(pool: Array, count: int, rng: RandomNumberGenerator) -> Array[String]:
	var deck: Array[String] = []
	if count <= 0 or pool.is_empty():
		return deck

	var total_w := 0.0
	for e: Dictionary in pool:
		total_w += maxf(0.0, float(e.get("weight", 1.0)))
	# Every weight zero reads as "no preference stated", not "no units": fall back to equal
	# shares rather than handing back an empty army.
	var flat := total_w <= 0.0
	if flat:
		total_w = float(pool.size())

	# Whole shares first; remainders parked with a random tiebreak key (see the header).
	var claims: Array = []
	var assigned := 0
	for e: Dictionary in pool:
		var w := 1.0 if flat else maxf(0.0, float(e.get("weight", 1.0)))
		var exact := float(count) * w / total_w
		var whole := int(floor(exact))
		for _i in whole:
			deck.append(String(e.id))
		assigned += whole
		# A zero-weight entry is excluded on purpose — it never earns a leftover card either,
		# so "weight 0" means what it says: this unit is not in this fight.
		if w > 0.0:
			claims.append({"id": String(e.id), "rem": exact - float(whole), "tie": rng.randf()})

	# Leftovers to the biggest remainders, ties settled by the pre-rolled key so the order is
	# reproducible from the rng and never favours whoever was authored first.
	claims.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if absf(float(a.rem) - float(b.rem)) > 0.000001:
			return float(a.rem) > float(b.rem)
		return float(a.tie) > float(b.tie))
	var leftover := count - assigned
	for i in mini(leftover, claims.size()):
		deck.append(String(claims[i].id))

	_shuffle(deck, rng)
	return deck


# Fisher-Yates on the INJECTED rng — Array.shuffle() would reach for the global generator, which
# would put an unseeded source back into a composition this whole function exists to make
# reproducible.
static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


# The entries this fight may draw from: everything whose ANCHOR (min_power) the fight's power has
# reached. This is the ONE way difficulty shapes the mix — an author states when a unit joins the
# roster, and above that line its authored weight stands unmodified at every depth.
#
# Anchoring EVERY entry above the current power would leave the encounter with no units at all
# (a captain alone on an empty board), which is never what an author meant — so that case
# fails OPEN, on the whole pool, and says so. An encounter that should genuinely field nothing is
# expressed with an empty pool, not with unreachable anchors.
func _eligible_pool(power: float) -> Array:
	var out: Array = []
	for e: Dictionary in enemy_pool:
		if power + 0.0001 >= float(e.get("min_power", 0.0)):
			out.append(e)
	if out.is_empty() and not enemy_pool.is_empty():
		push_warning("EncounterTemplateData '%s': every pool entry is anchored above power %.2f — "
				% [id, power] + "ignoring anchors for this roll (check min_power values)")
		return enemy_pool
	return out


# Picks an un-owned relic id to offer (empty if the player already owns every relic). Reuses the
# relic ItemKind's pool so ownership filtering lives in one place.
func _roll_relic_offer(rng: RandomNumberGenerator) -> String:
	var kind := ItemKinds.get_kind("relic")
	if kind == null:
		return ""
	var ids := kind.offer_pool(1, rng)
	return ids[0] if not ids.is_empty() else ""


static func _encounter_data_type(t: MapNodeData.Type) -> EncounterData.Type:
	match t:
		MapNodeData.Type.ELITE: return EncounterData.Type.ELITE
		MapNodeData.Type.BOSS:  return EncounterData.Type.BOSS
	return EncounterData.Type.COMBAT


# ── Reward pools ────────────────────────────────────────────────────────────

# Named reward-pool strategies, keyed by the "reward_pool" string in template
# JSON. Add a new match arm here to introduce e.g. tag-filtered pools later.
static func resolve_reward_pool(key: String) -> Array[String]:
	match key:
		"default", "":
			return CardData.random_non_kings(3)
		_:
			push_error("EncounterTemplateData: unknown reward_pool key '%s', falling back to default" % key)
			return resolve_reward_pool("default")
