class_name EnemyPersonality
extends RefCounted

# A named set of eval weights — WHO an enemy is, in the only vocabulary the engine has
# (EVAL_CRITERIA_BRIEF.md). The engine's criteria and their maths are fixed; a personality
# says how loudly each one speaks, and that is the whole authoring surface for character.
#
# Two kinds of entry, a TOOL distinction rather than an engine one (user call 2026-07-30):
#   · CORE TRAITS — every personality has all of them. They are what makes the CPU function
#     as an opponent at all: fear of dying, of being worn down, formation, the worth of the
#     battlefield, using its mana, keeping its units ready, not sitting on a full hand. A
#     personality states a weight for each; leaving one blank keeps the stock number, so a
#     new personality starts as the default character and is edited away from it.
#   · QUIRKS — opt-in leans a personality either has or doesn't. A quirk that is not listed
#     is not in the scorer at all. Today there is exactly one, "maximize damage output"; the
#     split exists so the next lean is a data entry rather than a redesign.
# Conceptually they are the same thing — a criterion and a weight. The engine treats them
# identically (see BoardScoring.stock); only the tool and this file's bookkeeping separate
# them.
#
# Authored in data/enemy_personalities.json (Tool ▸ 🧠 Enemy AI), loaded once at startup like
# every other data file. An encounter names one through EncounterTemplateData.personality;
# an unknown or absent name falls back to the stock character, which is exactly the code
# defaults in board_scoring.gd — so the file is always optional and never load-bearing.
#
# ⚠ EVERY WEIGHT IS PROVISIONAL UNTIL PLAYTESTED. The starter personalities shipped in the
# JSON are directions, not balance: they were authored by reading the criteria, not by
# playing fights. See the standing caution at the top of board_scoring.gd.

const PATH := "res://data/enemy_personalities.json"
const DEFAULT_ID := "default"

# The criteria a personality can speak about, in tool display order. `core` decides which
# section the tool puts it in and whether it is always present — the engine reads the same
# list either way. Adding a criterion to the scorer means adding one entry here (and one arm
# in BoardScoring._criterion_for).
const TRAITS: Array = [
	{"id": "death_risk", "core": true},
	{"id": "harm", "core": true},
	{"id": "protection", "core": true},
	{"id": "board_value", "core": true},
	{"id": "mana", "core": true},
	{"id": "readiness", "core": true},
	{"id": "idle_hand", "core": true},
	{"id": "damage_output", "core": false},
]


# The stock weight of every criterion — the code defaults in board_scoring.gd, which stay
# the single source of truth (they carry the reasoning behind each number). A function, not
# a const, deliberately: a const Dictionary reading BoardScoring's consts would make the two
# classes depend on each other at parse time.
static func stock_weights() -> Dictionary:
	return {
		"death_risk": 1.0,   # the reference scale every other weight is read against
		"harm": BoardScoring.HARM_CRITERION_WEIGHT,
		"protection": BoardScoring.EXPOSURE_CRITERION_WEIGHT,
		"board_value": BoardScoring.BOARD_VALUE_CRITERION_WEIGHT,
		"mana": BoardScoring.MANA_CRITERION_WEIGHT,
		"readiness": BoardScoring.READINESS_CRITERION_WEIGHT,
		"idle_hand": BoardScoring.IDLE_HAND_CRITERION_WEIGHT,
		"damage_output": BoardScoring.DAMAGE_CRITERION_WEIGHT,
	}


# The quirks the stock character carries. Damage output is nonzero in stock ON PURPOSE (the
# offensive-evals initiative's stated goal: the default enemy must reach for damage buffs
# without per-encounter authoring) — it is a quirk because a personality may drop it, not
# because the default lacks it.
static func stock_quirks() -> Dictionary:
	return {"damage_output": BoardScoring.DAMAGE_CRITERION_WEIGHT}


static func core_ids() -> Array:
	return TRAITS.filter(func(t: Dictionary) -> bool: return bool(t["core"])) \
			.map(func(t: Dictionary) -> String: return String(t["id"]))


static func quirk_ids() -> Array:
	return TRAITS.filter(func(t: Dictionary) -> bool: return not bool(t["core"])) \
			.map(func(t: Dictionary) -> String: return String(t["id"]))


var id: String = DEFAULT_ID
var display_name: String = ""
var description: String = ""
# Core trait id → weight. A missing key keeps the stock weight, so a personality only ever
# records what it actually changed.
var traits: Dictionary = {}
# Quirk id → weight. AUTHORITATIVE when present: a personality that lists no quirks has no
# quirks. Only a personality that never mentions quirks at all inherits the stock ones —
# see from_dict, where the distinction is made once.
var quirks: Dictionary = {}
# Role/card → protect weight, layered over BoardScoring.STOCK_SURVIVAL_WEIGHTS. The death
# risk trait's parameters: its weight says how loudly the CPU fears losing units, this says
# which units it fears losing. An encounter's own survival_weights layer on top of these.
var survival_weights: Dictionary = {}


# What this personality says criterion `trait_id` is worth: its own entry, else the stock
# number. Quirks are looked up in `quirks` and are absent rather than zero when not carried.
func weight_for(trait_id: String) -> float:
	if traits.has(trait_id):
		return float(traits[trait_id])
	if quirks.has(trait_id):
		return float(quirks[trait_id])
	return float(stock_weights().get(trait_id, 0.0))


func has_quirk(quirk_id: String) -> bool:
	return quirks.has(quirk_id)


func name_or_id() -> String:
	return display_name if not display_name.is_empty() else id


# ── Loading ─────────────────────────────────────────────────────────────────

static var _all: Array = []      # Array[EnemyPersonality], authored order
static var _by_id: Dictionary = {}
static var _loaded := false


static func all() -> Array:
	_ensure_loaded()
	return _all


# The personality an encounter named. An unknown name is not an error worth crashing a
# fight over — it degrades to the stock character and says so once.
static func get_personality(p_id: String) -> EnemyPersonality:
	_ensure_loaded()
	if p_id.is_empty():
		return stock()
	if _by_id.has(p_id):
		return _by_id[p_id]
	if p_id != DEFAULT_ID:
		push_warning("EnemyPersonality: unknown personality '%s' — using the stock character" % p_id)
	return stock()


# The code-default character, built fresh (never cached): every core trait at its stock
# weight and the stock quirks. This is what the engine did before personalities existed, so
# an empty/absent JSON changes nothing.
static func stock() -> EnemyPersonality:
	var p := EnemyPersonality.new()
	p.id = DEFAULT_ID
	p.display_name = "Default"
	p.quirks = stock_quirks()
	return p


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if not FileAccess.file_exists(PATH):
		return
	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null:
		push_error("EnemyPersonality: cannot open " + PATH)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("EnemyPersonality: parse error in %s — %s" % [PATH, json.get_error_message()])
		return
	var entries: Array = json.data if json.data is Array else [json.data]
	for d: Variant in entries:
		if not (d is Dictionary):
			continue
		var p := from_dict(d as Dictionary)
		if p.id.is_empty() or _by_id.has(p.id):
			continue
		_all.append(p)
		_by_id[p.id] = p


static func from_dict(d: Dictionary) -> EnemyPersonality:
	var p := EnemyPersonality.new()
	p.id = String(d.get("id", ""))
	p.display_name = String(d.get("name", ""))
	p.description = String(d.get("description", ""))
	p.traits = _numeric(d.get("traits", {}))
	# THE ONE PLACE the absent-vs-empty distinction is made: a personality that never
	# mentions quirks inherits the stock ones (so a hand-written entry does not silently
	# lose the default's aggression), while an explicit — even empty — quirks object is
	# taken at its word. The tool always writes the key.
	p.quirks = _numeric(d["quirks"]) if d.has("quirks") else stock_quirks()
	p.survival_weights = _numeric(d.get("survival_weights", {}))
	return p


# Numeric entries only — a typo'd string weight would otherwise read as 0.0 and quietly
# silence a criterion.
static func _numeric(src: Variant) -> Dictionary:
	var out: Dictionary = {}
	if not (src is Dictionary):
		return out
	for key: Variant in (src as Dictionary):
		var v: Variant = (src as Dictionary)[key]
		if v is float or v is int:
			out[String(key)] = float(v)
	return out


# Injects a set directly, bypassing the JSON (tests). Pass an empty array to force a reload
# from disk on the next read.
static func set_all(entries: Array) -> void:
	_all = []
	_by_id = {}
	if entries.is_empty():
		_loaded = false
		return
	_loaded = true
	for d: Variant in entries:
		var p: EnemyPersonality = d if d is EnemyPersonality else from_dict(d as Dictionary)
		_all.append(p)
		_by_id[p.id] = p
