class_name CardData
extends RefCounted

enum CardType { UNIT, SPELL }

var id: String
# Player-facing text is localized: it lives in data/locale/<lang>.json under `card.<id>.name`
# / `.desc` (see Loc), NOT in the card's data file. The getter reads Loc at access time (so a
# language switch updates live) and falls back to `_name_override` only when Loc has no key —
# for runtime-derived cards (unit-merge composites via _derive) that exist in no data file.
var _name_override := ""
var display_name: String:
	get:
		var s := Loc.opt("card.%s.name" % id)
		return s if s != "" else _name_override
	set(value):
		_name_override = value
var cost: int
var attack: int
var health: int
var speed: int
var shield: int
var is_king: bool
var card_type: CardType = CardType.UNIT
var _desc_override := ""
var description: String:
	get:
		var s := Loc.opt("card.%s.desc" % id)
		return s if s != "" else _desc_override
	set(value):
		_desc_override = value
var effects: Array = []  # Array[Effect]
var image: Texture2D = null
var elements: Array[String] = []
var chess_pieces: Array[String] = []
# The AUTO-ATTACK targeting policy — how this unit picks which enemy its auto-attack hits
# (see TARGET_POLICIES / effective_target_policy). Authored per-card in the tool; "" means
# AUTO — derive it from the chess composition exactly as before (pawns/fodder → nearest,
# knight → leaper, bishop → wounded, rook → tank, queen → threat). Setting it overrides that.
# It resolves the concrete `targeting_strategy` below, and a localized one-line description of
# it is appended to the card's rules text on display (see targeting_line).
var target_policy: String = ""
var targeting_strategy: TargetingStrategy
# Enemy-only fodder cards (tribes the CPU fights with). Kept out of every player-facing
# pool — reward offers and shop stock (random_non_kings). They carry no element/chess
# composition, so composition_key is empty and they're already absent from the collection
# screen and the combine system; this flag covers the remaining reward/shop path.
var enemy_only: bool = false
# The fodder tribe this card belongs to ("goblin"/"undead"/"golem", "" for everyone else) —
# set on the enemy tribe files; cues resolve tribe-flavoured variants through it (death_<tribe>).
var tribe: String = ""
# The ACTIVATED ABILITIES this card holds, by ability id (see AbilityData — definitions in
# data/abilities/). Rook buildings author these ("abilities": ["castling"]); any card may.
# Read through ability_ids(), which adds the derived fallback for un-authored rook combos.
var abilities: Array[String] = []
# Ranged units fire a projectile at their target on auto-attack instead of the melee lunge
# (see combat.gd::_resolve_attack). Authored per-card — NOT derived from composition, so e.g.
# the base Bishop is ranged but most bishop-composed units aren't unless they opt in.
var ranged: bool = false
# Attacks per combat round (the multi-strike stat — see combat._resolve_attack's strike loop).
# Base 1 for everyone; authored higher for flurry units (harpies and friends). Foldable, so
# standing effects/statuses can grant extra strikes at read time (CardInstance.get_attribute).
var strikes: int = 1

# Procedural enemy power scaling: each point of encounter `power` grows a scaled card's
# offensive/defensive stats by this fraction (see CardData.scaled / EncounterTemplateData).
const POWER_STAT_GROWTH := 0.05

# The canonical component-id vocabulary — everything a composition may contain, and therefore
# everything a standing composition GRANT may confer (see Effect._validate_grants /
# LiveEffects.effective_composition). Mirrors the Tool's ELEMENTS/PIECES (Tool/server.js),
# like FOLDABLE_ATTRS — keep the two in step.
const ELEMENT_IDS: Array[String] = ["fire", "water", "air", "earth", "darkness", "light"]
const CHESS_PIECE_IDS: Array[String] = ["pawn", "knight", "bishop", "rook", "queen", "king"]


static func is_component_id(component_id: String) -> bool:
	return ELEMENT_IDS.has(component_id) or CHESS_PIECE_IDS.has(component_id)


# How many components this card is made of — the size of its composition, elements and chess
# pieces together. A base card is 1; combining raises it, up to the 2-elements-plus-2-pieces
# ceiling can_combine enforces. Read by rarity (a wider card is rarer) and by charm capacity
# (a card bears one charm per component — see DeckCard.charm_capacity).
func component_count() -> int:
	return elements.size() + chess_pieces.size()


# A building is any unit carrying a rook in its composition. Buildings are
# defensive structures: once placed on the board they are rooted and cannot be
# repositioned (enforced in CardUI._get_drag_data and CombatBoard.do_place_unit).
func is_building() -> bool:
	return chess_pieces.has("rook")


# A normal fieldable deck unit — the valid target for per-card modifications (charms,
# the "?" event upgrade). Excludes spells (never placed as units) and the King (spawned
# by place_kings, never drawn from the deck, so deck-side changes can't reach the board).
func is_deck_unit() -> bool:
	return card_type == CardType.UNIT and not is_king


# Royalty = the King and Queen (the King is also the win/lose condition and persists across
# fights). Effects now apply to royalty and lackeys equally; this is kept as a domain concept.
func is_royalty() -> bool:
	return is_king or chess_pieces.has("queen")


func is_lackey() -> bool:
	return card_type == CardType.UNIT and not is_royalty()


# The card's base activated abilities, by id (see AbilityData). Authored via "abilities";
# a rook BUILDING with none authored falls back to the derived rule — Castling for pure
# rooks, the synthesized material delivery for its non-rook remainder — so forge-derived
# rook combos keep their offer. NOTE: rootedness (is_building) and abilities are separate
# concepts — buildings are rooted by composition whether or not they hold abilities.
func ability_ids() -> Array:
	if not abilities.is_empty():
		return abilities
	if not is_building():
		return []
	var chess := chess_pieces.duplicate()
	while chess.has("rook"):
		chess.erase("rook")
	if chess.is_empty() and elements.is_empty():
		return ["castling"]
	var ab := AbilityData.material_ability(elements, chess)
	if ab == null:
		return []
	return [ab.id]


static var _all: Dictionary = {}
static var _by_composition: Dictionary = {}
# Authored composition cards that omitted their stats — they inherit the derived stats once every
# base card is loaded (so designers can attach effects to a composition without re-stating it).
static var _derive_fill: Array = []   # [{ "card": CardData, "def": Dictionary }]


static func _static_init() -> void:
	var dir := DirAccess.open("res://data/cards/")
	if dir == null:
		push_error("CardData: cannot open res://data/cards/")
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/cards/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()
	_fill_derived_stats()   # composition cards authored without stats inherit them now


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("CardData: cannot open " + path)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("CardData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = []
	if json.data is Array:
		entries = json.data
	else:
		entries = [json.data]
	for d: Dictionary in entries:
		_load_card_dict(d)


# Builds a CardData from a definition dict WITHOUT registering it. The single card
# constructor: used by the JSON loader, and by run-level overridden cards rebuilt from
# their stored definition (see DeckCard). Derived fields (image, targeting_strategy)
# are recomputed here from id + chess_pieces, so they never need to be serialised.
static func build_from_dict(d: Dictionary) -> CardData:
	var card := CardData.new()
	card.id           = d.get("id", "")
	# display_name/description are NOT read from the data file — they resolve through Loc by id
	# (see the property getters). The field stays in the JSON as dormant authoring source until
	# it is stripped in a later pass.
	card.cost         = int(d.get("cost", 0))
	card.attack       = int(d.get("attack", 0))
	card.health       = int(d.get("health", 1))
	card.speed        = int(d.get("speed", 1))
	card.is_king      = d.get("is_king", false)
	card.shield       = int(d.get("shield", 0))
	card.elements     = Array(d.get("elements",     []), TYPE_STRING, "", null)
	card.chess_pieces = Array(d.get("chess_pieces", []), TYPE_STRING, "", null)
	card.enemy_only   = bool(d.get("enemy_only", false))
	card.tribe        = str(d.get("tribe", ""))
	card.abilities    = Array(d.get("abilities", []), TYPE_STRING, "", null)
	card.ranged       = bool(d.get("ranged", false))
	card.strikes      = maxi(1, int(d.get("strikes", 1)))
	card.target_policy = str(d.get("target_policy", ""))
	for e_data: Dictionary in d.get("effects", []):
		card.effects.append(Effect.from_dict(e_data))
	if d.has("card_type"):
		card.card_type = CardType.SPELL if d.get("card_type") == "spell" else CardType.UNIT
	elif not card.elements.is_empty() and card.chess_pieces.is_empty():
		card.card_type = CardType.SPELL
	else:
		card.card_type = CardType.UNIT
	card.targeting_strategy = _strategy_for_policy(card.effective_target_policy())
	# Enemy fodder/captain art is organised under cards/enemies/ to keep it out of the
	# main (player-facing) card art folder.
	var art_dir := "res://assets/cards/enemies/" if card.enemy_only else "res://assets/cards/"
	var art_path := "%s%s.png" % [art_dir, card.id]
	card.image = load(art_path) if ResourceLoader.exists(art_path) \
		else load("res://assets/cards/placeholder.png")
	return card


static func _load_card_dict(d: Dictionary) -> void:
	# Authoring kill-switch: an entry with "enabled": false exists in the data but is not
	# loaded — content deactivates without leaving the file (see the authoring tool).
	if not bool(d.get("enabled", true)):
		return
	var card := build_from_dict(d)
	if card.id.is_empty():
		return
	_all[card.id] = card
	if card.elements.size() > 0 or card.chess_pieces.size() > 0:
		_by_composition[composition_key(card.elements, card.chess_pieces)] = card
		# A composition card authored without stats (e.g. just to attach effects) inherits the
		# derived stats in a post-load pass, once every base card is available.
		if not d.has("attack"):
			_derive_fill.append({"card": card, "def": d})


# Fills the derived stats for stat-less composition cards (deferred to here so base cards are
# all loaded). Any core field the author DID specify is respected; the rest come from the formula.
static func _fill_derived_stats() -> void:
	for entry: Dictionary in _derive_fill:
		var card: CardData = entry["card"]
		var def: Dictionary = entry["def"]
		var s := _derived_stats(card.elements, card.chess_pieces)
		if not def.has("cost"):         card.cost = int(s["cost"])
		if not def.has("health"):       card.health = int(s["health"])
		if not def.has("speed"):        card.speed = int(s["speed"])
		if not def.has("attack"):       card.attack = int(s["attack"])
		if not def.has("display_name"): card.display_name = str(s["display_name"])
	_derive_fill.clear()


# Inverse of build_from_dict — serialises the authorable definition (omitting derived
# image/targeting_strategy). Used to snapshot a card into a DeckCard override.
func to_dict() -> Dictionary:
	var fx: Array = []
	for e: Effect in effects:
		fx.append(e.to_dict())
	var d := {
		"id":           id,
		"display_name": display_name,
		"cost":         cost,
		"attack":       attack,
		"health":       health,
		"speed":        speed,
		"shield":       shield,
		"is_king":      is_king,
		"ranged":       ranged,
		"description":  description,
		"card_type":    "spell" if card_type == CardType.SPELL else "unit",
		"elements":     Array(elements, TYPE_STRING, "", null),
		"chess_pieces": Array(chess_pieces, TYPE_STRING, "", null),
		"effects":      fx,
	}
	# A card's held abilities are identity, like its effects — they survive override snapshots
	# (a "?"-event bump must not reset what a rook offers).
	if not abilities.is_empty():
		d["abilities"] = Array(abilities, TYPE_STRING, "", null)
	if not tribe.is_empty():
		d["tribe"] = tribe
	# Conditional like tribe/abilities: the overwhelming single-strike majority keeps its
	# serialized shape byte-identical to before the stat existed.
	if strikes != 1:
		d["strikes"] = strikes
	# Only the authored override is serialised — an AUTO ("") card keeps its byte-identical
	# pre-policy shape, and the strategy re-derives from the composition on load.
	if not target_policy.is_empty():
		d["target_policy"] = target_policy
	return d


static func get_card(p_id: String) -> CardData:
	if _all.has(p_id):
		return _all[p_id]
	return _derive_from_key(p_id)


# Returns a COPY of `base` with attack/health/shield grown by `power` (the procedural enemy
# difficulty lever — same card, stronger deeper in a run). Cost/speed/effects are unchanged:
# cost stays the card's identity on the curve (the pool weighting handles "heavier mix"). power
# <= 0 returns the base untouched. Never registered, so it can't pollute the card pools.
static func scaled(base: CardData, power: float) -> CardData:
	if base == null or power <= 0.0:
		return base
	var c := CardData.new()
	c.id            = base.id
	c.display_name  = base.display_name
	c.cost          = base.cost
	c.speed         = base.speed
	c.is_king       = base.is_king
	c.card_type     = base.card_type
	c.description   = base.description
	c.elements      = base.elements.duplicate()
	c.chess_pieces  = base.chess_pieces.duplicate()
	c.enemy_only    = base.enemy_only
	c.tribe         = base.tribe
	c.abilities     = base.abilities.duplicate()
	c.ranged        = base.ranged
	c.strikes       = base.strikes
	c.target_policy = base.target_policy
	c.effects       = base.effects
	c.targeting_strategy = base.targeting_strategy
	c.image         = base.image
	var mult := 1.0 + power * POWER_STAT_GROWTH
	c.attack = int(round(base.attack * mult))
	c.health = int(round(base.health * mult))
	c.shield = int(round(base.shield * mult))
	return c


static func all() -> Array:
	return _all.values()


# Offer rarity is data-driven — all tunable numbers live in res://data/offer_rarity.json (see
# OFFER_RARITY_DEFAULT for the shape / fallback). HIGHER rarity = LESS likely to be offered. A
# card's rarity = product of its components' rarities × the count multiplier for how many
# components it has; its offer likelihood is 1 / rarity. Edit the JSON and restart to retune.
const OFFER_RARITY_PATH := "res://data/offer_rarity.json"
const OFFER_RARITY_DEFAULT := {
	"piece_rarity": {"pawn": 4.0, "knight": 5.0, "bishop": 5.0, "rook": 5.0, "queen": 20.0, "king": 5.0},
	"element_rarity": 10.0,
	"count_multiplier": {"1": 1.0, "2": 2.0, "3": 3.0, "4": 4.0},
}
static var _offer_cfg: Dictionary = {}


# Lazily loads (and caches) the offer-rarity config, falling back to OFFER_RARITY_DEFAULT for the
# whole file or any missing key so a partial / absent JSON still works.
static func _offer_config() -> Dictionary:
	if not _offer_cfg.is_empty():
		return _offer_cfg
	_offer_cfg = OFFER_RARITY_DEFAULT.duplicate(true)
	if FileAccess.file_exists(OFFER_RARITY_PATH):
		var file := FileAccess.open(OFFER_RARITY_PATH, FileAccess.READ)
		var json := JSON.new()
		if file != null and json.parse(file.get_as_text()) == OK and json.data is Dictionary:
			var d: Dictionary = json.data
			if d.get("piece_rarity") is Dictionary:
				_offer_cfg["piece_rarity"] = d["piece_rarity"]
			if d.get("element_rarity") != null:
				_offer_cfg["element_rarity"] = float(d["element_rarity"])
			if d.get("count_multiplier") is Dictionary:
				_offer_cfg["count_multiplier"] = d["count_multiplier"]
		else:
			push_error("CardData: bad offer_rarity.json — using defaults")
	return _offer_cfg


static func offer_weight(card: CardData) -> float:
	var cfg := _offer_config()
	var piece_rarity: Dictionary = cfg["piece_rarity"]
	var element_rarity: float = float(cfg["element_rarity"])
	var count_mult: Dictionary = cfg["count_multiplier"]

	var rarity := 1.0
	for _e in card.elements:
		rarity *= element_rarity
	for piece: String in card.chess_pieces:
		rarity *= float(piece_rarity.get(piece, 5.0))
	# Extra penalty scaling with the number of components: multi-piece cards fall off faster
	# than the per-component product alone. Counts beyond the table fall back to the count itself.
	var components := card.component_count()
	rarity *= float(count_mult.get(str(components), float(components)))

	return 1.0 / rarity if rarity > 0.0 else 0.0


# Returns up to `count` random non-king card ids, drawn WITHOUT replacement weighted by
# offer_weight (rarer compositions surface less often). Shared by reward and shop offer
# generation (see EncounterTemplateData.resolve_reward_pool and shop_screen.gd).
static func random_non_kings(count: int) -> Array[String]:
	var pool: Array = []   # [{ "id": String, "w": float }]
	for card: CardData in all():
		if not card.is_king and not card.enemy_only:
			pool.append({"id": card.id, "w": offer_weight(card)})

	var out: Array[String] = []
	var draws := mini(count, pool.size())
	for _i in draws:
		var total := 0.0
		for entry: Dictionary in pool:
			total += float(entry["w"])
		if total <= 0.0:
			break
		var roll := randf() * total
		var pick := pool.size() - 1
		for j in pool.size():
			roll -= float(pool[j]["w"])
			if roll <= 0.0:
				pick = j
				break
		out.append(String(pool[pick]["id"]))
		pool.remove_at(pick)
	return out


static func composition_key(elems: Array, chess: Array) -> String:
	var e := elems.duplicate(); e.sort()
	var c := chess.duplicate(); c.sort()
	return "_".join(e + c)


static func can_combine(a: CardData, b: CardData) -> bool:
	return (a.elements.size() + b.elements.size()) <= 2 \
		and (a.chess_pieces.size() + b.chess_pieces.size()) <= 2


static func combine(a: CardData, b: CardData) -> CardData:
	var elems: Array = a.elements + b.elements
	var chess: Array  = a.chess_pieces + b.chess_pieces
	var key := composition_key(elems, chess)
	var authored: CardData = _by_composition.get(key, null)
	if authored:
		return authored
	var derived := _derive(elems, chess, key)
	_all[key]            = derived
	_by_composition[key] = derived
	return derived


static func _derive_from_key(key: String) -> CardData:
	if key.is_empty():
		return null
	# An authored card already owns this composition (e.g. "earth_water" → the Clay spell,
	# "earth_fire" → Magma). Return it instead of deriving a generic one — deriving here
	# would OVERWRITE _by_composition[key] and break combine() for that pair.
	if _by_composition.has(key):
		return _by_composition[key]
	var elems: Array[String] = []
	var chess: Array[String]  = []
	for part: String in key.split("_"):
		var base: CardData = _all.get(part, null)
		if base == null or (base.elements.is_empty() and base.chess_pieces.is_empty()):
			return null
		elems.append_array(base.elements)
		chess.append_array(base.chess_pieces)
	if elems.is_empty() and chess.is_empty():
		return null
	var derived := _derive(elems, chess, key)
	_all[key]            = derived
	_by_composition[key] = derived
	return derived


# The formula stats for a composition (the values a fully-derived card gets, and the values a
# stat-less authored composition card inherits — see _fill_derived_stats).
static func _derived_stats(elems: Array, chess: Array) -> Dictionary:
	var n := elems.size() + chess.size()
	var cost := 0
	for e: String in elems:
		var base: CardData = _all.get(e, null)
		cost += base.cost if base else 1
	for cp: String in chess:
		var base: CardData = _all.get(cp, null)
		cost += base.cost if base else 1
	return {
		"cost":         cost,
		"attack":       n * 2,
		"health":       n * 3,
		"speed":        2,
		"display_name": _derive_name(elems, chess),
	}


static func _derive(elems: Array, chess: Array, key: String) -> CardData:
	var c := CardData.new()
	c.id           = key
	c.elements     = Array(elems, TYPE_STRING, "", null)
	c.chess_pieces = Array(chess, TYPE_STRING, "", null)
	c.is_king      = false
	c.description  = ""
	var s := _derived_stats(elems, chess)
	c.display_name = str(s["display_name"])
	c.cost         = int(s["cost"])
	c.attack       = int(s["attack"])
	c.health       = int(s["health"])
	c.speed        = int(s["speed"])
	c.card_type          = CardType.SPELL if (chess.is_empty() and not elems.is_empty()) else CardType.UNIT
	c.targeting_strategy = _strategy_for_policy(_derived_policy(chess))
	var art := "res://assets/cards/%s.png" % key
	c.image = load(art) if ResourceLoader.exists(art) \
		else load("res://assets/cards/placeholder.png")
	return c


# The authorable auto-attack targeting policies (the semantic vocabulary, decoupled from the
# chess pieces that historically implied them). Mirrors the tool's TARGET_POLICIES select and the
# `targeting.<policy>.desc` locale keys — keep the three in step. "" (unlisted) means AUTO/derive.
const TARGET_POLICIES: Array[String] = ["nearest", "leaper", "wounded", "tank", "threat"]


# The policy this card's auto-attack actually uses: the authored override when set, otherwise the
# one derived from the chess composition (backward-compatible with every pre-policy card).
func effective_target_policy() -> String:
	return target_policy if not target_policy.is_empty() else _derived_policy(chess_pieces)


# The localized one-line rules-text description of this card's auto-attack targeting, appended
# after the authored description on every board unit (see CardTooltip / CardUI). Spells never
# auto-attack, so they get nothing. Carries <term> markup, so TextIcons resolves the icons/words.
func targeting_line() -> String:
	if card_type == CardType.SPELL:
		return ""
	return Loc.t("targeting.%s.desc" % effective_target_policy())


# The localized one-line rules-text note that marks a building as rooted, appended after the
# authored description on buildings only (see CardTooltip / CardUI). Non-buildings get nothing.
func building_line() -> String:
	if not is_building():
		return ""
	return Loc.t("building.line")


# The legacy composition → policy mapping (the AUTO default). First non-pawn piece wins; a pure
# pawn / element / fodder composition falls through to nearest.
static func _derived_policy(chess_pieces: Array) -> String:
	for piece: String in chess_pieces:
		match piece:
			"pawn": continue
			"knight": return "leaper"
			"bishop": return "wounded"
			"rook":   return "tank"
			"queen":  return "threat"
	return "nearest"


static func _strategy_for_policy(policy: String) -> TargetingStrategy:
	match policy:
		"leaper":  return TargetingKnight.new()
		"wounded": return TargetingBishop.new()
		"tank":    return TargetingRook.new()
		"threat":  return TargetingQueen.new()
		_:         return TargetingNearest.new()


static func _derive_name(elems: Array, chess: Array) -> String:
	const INITIALS := {
		"fire": "F", "water": "W", "air": "A", "earth": "E",
		"darkness": "D", "light": "L",
		"pawn": "P", "bishop": "B", "knight": "K",
		"rook": "R", "queen": "Q", "king": "C",
	}
	var e := elems.duplicate(); e.sort()
	var c := chess.duplicate(); c.sort()
	var name := ""
	for mat: String in e:
		name += INITIALS.get(mat, mat[0].to_upper())
	for mat: String in c:
		name += INITIALS.get(mat, mat[0].to_upper())
	return name
