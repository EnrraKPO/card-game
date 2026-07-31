class_name CombatRng
extends RefCounted

# THE fight's randomness — one master seed per combat, so a fight can be REPRODUCED from
# its log (see CombatLog: the seed is the log's first line). Before this, every roll came
# from Godot's global generator and a fight was gone the moment it ended.
#
# NAMED STREAMS, not one sequence. Each concern draws from its own generator, derived from
# the master seed:
#   · rules — dodge, crit, effect `chance` (the Resolver / EffectSystem gates)
#   · deck  — shuffles and random discard (which cards arrive, and when)
#   · ai    — the enemy engine's tie-break among equally-scored candidates
# The split is what makes a replay survive EDITING: change how the CPU breaks ties and the
# dodges still land where they landed, because the ai stream's consumption can't shift the
# rules stream. One shared sequence would re-deal the whole fight on any change.
#
# THE HYPOTHETICAL SCOPE is the other half of that property. The enemy engine simulates
# casts by running the REAL rules on a world copy (CandidateApply._apply_real), so planning
# ROLLS — dodge, crit, chance — exactly like the live fight does. Those rolls must not
# advance the live streams, or the fight the player sees changes when the CPU merely
# THINKS differently (a personality tweak, one extra candidate) and the seed stops
# reproducing anything. Inside the scope every draw comes from a scratch generator that is
# thrown away when planning ends: seeded per simulation, so hypotheticals stay repeatable
# in their own right, and structurally unable to touch the live streams.
#
# OUTSIDE COMBAT there is no fight to seed: every entry point falls back to the global
# generator, exactly as before. The Resolver and EffectSystem run in the Lab, the forge and
# deck edits too — this class never makes them deterministic, and never has to.

# The streams built per fight. Names are the vocabulary above; drawing from an unknown one
# is a programming error (loud, not silent — a mis-typed stream would quietly re-couple two
# concerns and only show up as an unreproducible replay months later).
const STREAMS: Array[StringName] = [&"rules", &"deck", &"ai"]

static var _seed: int = 0
static var _live: bool = false
static var _streams: Dictionary = {}

# The hypothetical scope, re-entrant: a simulated cast can nest (an ON_PLAY effect running
# inside a simulated placement). Only the outermost enter/exit builds and drops the scratch.
static var _hypo_depth: int = 0
static var _hypo_count: int = 0
static var _scratch: RandomNumberGenerator = null


# Opens a fight. `p_seed` < 0 asks for the configured seed (debug.json "combat_seed"), and
# failing that a fresh random one. Returns the seed actually used — combat hands it to the
# log, which is the whole point.
static func begin(p_seed: int = -1) -> int:
	var s := p_seed
	if s < 0:
		s = DebugConfig.forced_seed()
	if s < 0:
		var r := RandomNumberGenerator.new()
		r.randomize()
		s = int(r.randi())
	_seed = s
	_live = true
	_hypo_depth = 0
	_hypo_count = 0
	_scratch = null
	_streams.clear()
	for name: StringName in STREAMS:
		var g := RandomNumberGenerator.new()
		g.seed = _derive(s, String(name))
		_streams[name] = g
	return _seed


# Closes the fight: every entry point falls back to the global generator again.
static func end() -> void:
	_live = false
	_hypo_depth = 0
	_scratch = null
	_streams.clear()


static func active() -> bool:
	return _live


static func seed_value() -> int:
	return _seed


# ── The draws ──────────────────────────────────────────────────────────────────────────
#
# Named for what they DO rather than mirroring randf/randi_range: a static randf() here
# would shadow the global one and turn its own fallback into infinite recursion.

static func roll(stream_name: StringName = &"rules") -> float:
	var g := _gen(stream_name)
	return g.randf() if g != null else randf()


static func roll_int(from: int, to: int, stream_name: StringName = &"ai") -> int:
	var g := _gen(stream_name)
	return g.randi_range(from, to) if g != null else randi_range(from, to)


# Fisher-Yates on the named stream. Array.shuffle() would reach for the global generator —
# the exact hole that made shuffled draw piles unreproducible.
static func shuffle(arr: Array, stream_name: StringName = &"deck") -> void:
	var g := _gen(stream_name)
	if g == null:
		arr.shuffle()
		return
	for i in range(arr.size() - 1, 0, -1):
		var j := g.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


# ── The hypothetical scope ─────────────────────────────────────────────────────────────

static func enter_hypothetical() -> void:
	_hypo_depth += 1
	if _hypo_depth == 1 and _live:
		_hypo_count += 1
		_scratch = RandomNumberGenerator.new()
		_scratch.seed = _derive(_seed, "hypothetical:%d" % _hypo_count)


static func exit_hypothetical() -> void:
	_hypo_depth = maxi(0, _hypo_depth - 1)
	if _hypo_depth == 0:
		_scratch = null


static func hypothetical() -> bool:
	return _hypo_depth > 0


# ── Internals ──────────────────────────────────────────────────────────────────────────

# The live generator for a stream — or the scratch one while a hypothetical is running,
# whatever stream was asked for: a simulation's draws all come from the same throwaway.
# Null means "no fight open": the caller falls back to the global generator.
static func _gen(stream_name: StringName) -> RandomNumberGenerator:
	if not _live:
		return null
	if _hypo_depth > 0:
		return _scratch
	var g: RandomNumberGenerator = _streams.get(stream_name, null)
	if g == null:
		push_error("CombatRng: unknown stream '%s' — rolling from `rules`" % stream_name)
		g = _streams.get(&"rules", null)
	return g


# One master seed fans out into independent streams. String-hashed rather than seed+index
# so adding a stream later never re-numbers the existing ones (which would invalidate every
# logged seed in circulation).
static func _derive(master: int, label: String) -> int:
	return int(hash("%d/%s" % [master, label]))
