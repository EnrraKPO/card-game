class_name CombatLog
extends RefCounted

# THE fight's black box: everything needed to understand — or re-run — a combat after the
# fact. Debug-only (DebugConfig.enabled()); with debug off every entry point below is a
# cheap no-op and nothing is ever written.
#
# ALWAYS RECORDING, never armed. The button in combat's debug row DUMPS what has been
# captured; it does not start the capture. A bug you can reproduce on demand does not need
# a log — the one worth having is the fight you had already started when the CPU did
# something inexplicable, and an arm-first recorder would have missed exactly that one.
#
# What a dump contains:
#   · the header — the SEED first (see CombatRng: paste it into debug.json as
#     "combat_seed" and the fight re-deals itself), the encounter, both decks in draw
#     order, the kings, and the run's relics/upgrades. That is the reproduction recipe.
#   · the chronology — rounds, draws, every play by both sides, every strike with its
#     resolved outcome (dodge, crit, shield/health split, deaths), and the ending.
#   · the CPU's REASONING, verbose — per pick, the whole candidate cohort with each
#     criterion's score, its share of the decision table, every judge's objection, and the
#     do-nothing baseline the winner had to beat. This is the part that answers "why did
#     it do THAT", which the plays alone never can.
#
# Written to res://debugLogs/combat_<stamp>.log — inside the project folder, where the person
# reading it already is, rather than off in the user:// data dir. dump() returns the OS path
# so combat can show it. Text, not JSON: it is read by a person hunting a behaviour, and the
# seed makes the machine-readable half unnecessary.
#
# res:// is only writable from the editor / a debug build, which is exactly when this recorder
# runs (DebugConfig gates it); an exported build falls back to user://logs so a dump asked for
# there still lands somewhere.

const DIR := "res://debugLogs"
const FALLBACK_DIR := "user://logs"
# A runaway fight must never eat memory unbounded. Past the cap the OLDEST entries go —
# the tail is where the fight went wrong, and the header is never part of the ring.
const MAX_ENTRIES := 40000

static var _entries: Array[String] = []
static var _header: Array[String] = []
static var _round: int = 0
static var _pick: int = 0
static var _dropped: int = 0
static var _open: bool = false
# The CPU-reasoning tier. On by default (it is the reason to read a log at all); the engine
# checks it before building any explanation, so switching it off costs the planner nothing.
static var _verbose: bool = true


static func recording() -> bool:
	return _open and DebugConfig.enabled()


static func verbose() -> bool:
	return recording() and _verbose


static func set_verbose(v: bool) -> void:
	_verbose = v


# Opens a fresh capture — one fight, one log. Called at the top of combat, before a card is
# dealt, so the header's decks are the piles the fight will actually draw from.
static func open(seed_value: int) -> void:
	_entries.clear()
	_header.clear()
	_round = 0
	_pick = 0
	_dropped = 0
	_open = DebugConfig.enabled()
	if not _open:
		return
	head("seed", "%d   ← replay: put \"combat_seed\": %d in debug.json" % [seed_value, seed_value])


static func close() -> void:
	_open = false


# ── Recording ──────────────────────────────────────────────────────────────────────────

# One header field. Label column is padded so the recipe reads as a table.
static func head(label: String, text: String) -> void:
	if not recording():
		return
	_header.append("%-10s %s" % [label, text])


# A header list (a deck in draw order, the relic roster) — indented under its own label.
static func head_list(label: String, items: Array) -> void:
	if not recording():
		return
	if items.is_empty():
		_header.append("%-10s (none)" % label)
		return
	_header.append("%-10s %d" % [label, items.size()])
	var line := ""
	for i in items.size():
		line += "%2d. %-18s" % [i + 1, String(items[i])]
		if (i + 1) % 4 == 0:
			_header.append("           " + line)
			line = ""
	if not line.is_empty():
		_header.append("           " + line)


# The round marker every later line is stamped against.
static func round_begin(n: int, player_mana: String, enemy_mana: String) -> void:
	if not recording():
		return
	_round = n
	_pick = 0
	_push("")
	_push("── round %d ──  player mana %s · enemy mana %s" % [n, player_mana, enemy_mana])


# One event. `channel` is the short tag the line is filed under (player / cpu / combat /
# draw / end) so a reader can scan one actor's story down the page.
static func note(channel: String, text: String) -> void:
	if not recording():
		return
	_push("[T%d] %-7s %s" % [_round, channel, text])


# A multi-line block under the current round — the CPU's reasoning dump, indented so it
# never competes with the chronology for the left edge.
static func block(lines: Array) -> void:
	if not recording():
		return
	for l: Variant in lines:
		_push("        " + String(l))


# The next CPU pick's number within this round (picks are greedy and sequential).
static func next_pick() -> int:
	_pick += 1
	return _pick


static func _push(line: String) -> void:
	_entries.append(line)
	if _entries.size() > MAX_ENTRIES:
		_entries.remove_at(0)
		_dropped += 1


# ── The dump ───────────────────────────────────────────────────────────────────────────

# Writes everything captured so far and returns the OS path (empty on failure). The capture
# is NOT cleared: the fight goes on and a second dump later still holds the whole story.
static func dump() -> String:
	if not recording():
		return ""
	var dir := DIR if OS.has_feature("editor") else FALLBACK_DIR
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path := "%s/combat_%s.log" % [dir, stamp]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("CombatLog: could not write %s" % path)
		return ""
	f.store_string(text())
	f.close()
	return ProjectSettings.globalize_path(path)


# The whole capture as one string — the file's contents, also handy from a breakpoint.
static func text() -> String:
	var out := "════════════════ COMBAT LOG ════════════════\n"
	out += "%-10s %s\n" % ["written", Time.get_datetime_string_from_system()]
	for h: String in _header:
		out += h + "\n"
	out += "════════════════════════════════════════════\n"
	if _dropped > 0:
		out += "(… %d earlier entries dropped — the log ring is %d lines)\n" % [_dropped, MAX_ENTRIES]
	for e: String in _entries:
		out += e + "\n"
	return out
