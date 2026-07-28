extends Node

const SAVE_PATH = "user://save_data.cfg"
const SLOT_COUNT = 3

var username: String = "":
	set(value):
		username = value
		_save_player()

# Each save slot is an independent game: its own meta-progression (profile_N) plus at
# most one in-progress run (slot_N / map_N). A slot is selected before entering its hub.
var current_slot: int = -1
var current_run: RunData = null
var current_map_state: MapState = null
var current_encounter: EncounterData = null
# The stat a "?" event site upgrades, handed to the event screen on entry (transient).
var current_event_attr: String = ""
# A standalone reward request for the reward screen when it's NOT tied to a combat encounter
# (e.g. the charm choice after clearing a stage). When pending_reward_offers is non-empty the
# reward screen shows those offers instead of building from current_encounter. Transient — set
# just before navigating to the reward screen, consumed and cleared there (see reward_screen).
var pending_reward_offers: Array = []          # Array[Grant]
var pending_reward_title: String = ""
var pending_reward_advance_stage: bool = false
# The deck the detail screen should display, handed off from the Decks screen (transient).
var viewing_deck_id: String = ""
# The deck the builder should edit, handed off from the Decks screen (transient).
var editing_deck_id: String = ""
# Meta-progression for the currently-selected slot (see ProfileData).
var current_profile: ProfileData = null
# Aggregate of every active run-wide Effect (from owned upgrades now; relics/heroes
# later). Rebuilt whenever the profile changes or a run starts; the game systems read every
# number through value() (globals) / LiveEffects.bonus (cards) / EffectSystem.trigger_global
# (combat events). Empty default = no-op for every query.
var current_modifiers: ModifierSet = ModifierSet.new():
	set(v):
		current_modifiers = v
		# Whole-set swaps (rebuild_modifiers, test resets) may add/remove composition
		# grants — drop the settled snapshot (see LiveEffects.effective_composition).
		LiveEffects.invalidate_compositions()


# Harness safety: while this is on, every write to the save file is a no-op (reads still work,
# so a harness still sees the player's real profile/decks).
#
# The dev/ render and probe scenes deliberately drive the REAL autoloads — that is the whole point,
# they have to look and behave like the game — and nearly all of them call start_new_run() to get a
# populated run. start_new_run() PERSISTS. Run against the player's own save that silently replaces
# their in-progress run with a brand-new one: the run deck reverts to the owned deck's template, so
# everything the run had EARNED is gone the next time they Continue — the base King deck's three
# elemental picks (king_reward_picks appends those to the RUN deck only), reward cards, forged
# merges, charms, map progress. The profile survives, which is exactly why the loss reads as "some
# element cards went missing when I restarted".
#
# Detected from the launched scene rather than opted into per file, so a new probe is safe without
# anyone remembering the rule; settable by hand for a harness launched some other way.
var sandboxed := false


func _ready() -> void:
	sandboxed = _is_harness_launch()
	if sandboxed:
		print("GameData: harness launch — save writes disabled (see GameData.sandboxed)")
	_load_player()


# A harness launch = the main scene named on the command line lives in dev/ or tests/.
static func _is_harness_launch() -> bool:
	for arg: String in OS.get_cmdline_args():
		var a := arg.replace("\\", "/").to_lower()
		if a.ends_with(".tscn") and (a.contains("dev/") or a.contains("tests/")):
			return true
	return false


# ── Slot selection ──────────────────────────────────────────────────────────────

# Enters a save slot: loads (or creates) its profile and clears prior run state. The
# run is started/continued from the hub via start_new_run / load_run.
func select_slot(slot: int) -> void:
	current_slot = slot
	var existing := _read_section("profile_%d" % slot)
	current_profile = ProfileData.from_dict(existing)
	if existing.is_empty():
		save_profile()   # register the new save so the slot reads as started
	rebuild_modifiers()
	current_run = null
	current_map_state = null
	current_encounter = null


func slot_started(slot: int) -> bool:
	return not _read_section("profile_%d" % slot).is_empty()


func slot_has_run(slot: int) -> bool:
	return not _read_section("slot_%d" % slot).is_empty()


# A slot's profile without selecting it — for save-select display only.
func peek_profile(slot: int) -> ProfileData:
	return ProfileData.from_dict(_read_section("profile_%d" % slot))


# ── Per-slot profile (meta-progression) ───────────────────────────────────────────

func save_profile() -> void:
	if current_profile == null or current_slot < 0:
		return
	_write_section("profile_%d" % current_slot, current_profile.to_dict())


# ── Run-wide modifiers (the upgrade/relic/hero hook) ────────────────────────────────

# Recomputes the active modifier set from the current profile. Call after the profile
# changes (slot select, an upgrade purchase) or a run starts so every queried number
# reflects the player's owned upgrades.
func rebuild_modifiers() -> void:
	current_modifiers = ModifierSet.for_run(current_profile, current_run)


# THE resolver: the current value of any registered game number = its registry default plus
# every active modifier for that key. This is the single call every system makes to read a
# run/match number, so they all behave identically and a new number is just a registry row.
func value(key: String) -> int:
	return int(round(value_f(key)))


func value_f(key: String) -> float:
	return GameAttributes.default_value(key) + current_modifiers.total_add(key)


# Awards profile crafting resources (the one entry point any node/screen uses — combat
# now, events/shops later). `rewards` is an id→count dict; no-op if empty or no profile.
func grant_materials(rewards: Dictionary) -> void:
	if rewards.is_empty() or current_profile == null:
		return
	current_profile.materials.add_many(rewards)
	save_profile()


# Awards profile experience (combat wins now, event rewards later — the single entry point).
# Returns the number of upgrade points newly crossed, for UI feedback. No-op without a profile.
func grant_experience(amount: int) -> int:
	if amount <= 0 or current_profile == null:
		return 0
	var gained := current_profile.gain_experience(amount)
	save_profile()
	return gained


# Every encounter number is either AUTHORED (per-template roll) or TOOL-DRIVEN (the per-node-type
# reward.* attribute defaults) — these resolve the total a win actually pays: authored + default.
# The reward screen reads the same helpers, so display always matches what was banked.
func reward_gold(enc: EncounterData) -> int:
	return enc.gold_reward + value("reward.gold." + _reward_suffix(enc.type))


func reward_mineral(enc: EncounterData) -> int:
	return enc.mineral_reward + value("reward.magic_mineral." + _reward_suffix(enc.type))


func _reward_suffix(t: EncounterData.Type) -> String:
	match t:
		EncounterData.Type.ELITE:
			return "elite"
		EncounterData.Type.BOSS:
			return "boss"
	return "combat"


# The one place an encounter's AUTOMATIC win rewards are applied: gold + Magic Mineral → the run,
# crafting materials + experience → the profile. (The card-pick reward stays interactive in
# reward_screen.) Caller persists the run; grant_materials / grant_experience persist the profile.
func apply_encounter_rewards(enc: EncounterData) -> void:
	if enc == null:
		return
	if current_run != null:
		current_run.gold += reward_gold(enc)
		current_run.magic_mineral += reward_mineral(enc)
	# The matching element CARD for each essence reward is now OPT-IN on the reward screen
	# (Accept/Reject), so it's not forced into the deck — only the essence is auto-granted here.
	grant_materials(enc.material_rewards)
	grant_materials(_bonus_reward_materials(enc))
	grant_experience(enc.exp_reward)


# Extra crafting materials granted by run-wide modifiers on top of the encounter's own
# rewards: a flat essence bonus (random element) and a chance for an Elite to drop a King
# Piece. Returns an id→count bag (empty when no modifier applies); grant_materials no-ops on it.
func _bonus_reward_materials(enc: EncounterData) -> Dictionary:
	var bag := {}
	var essence := value("reward.essence")
	if essence > 0:
		var elem: String = Materials.ELEMENTS[randi() % Materials.ELEMENTS.size()]
		bag[elem] = essence
	var kp_chance := value_f("reward.king_piece_chance")
	if enc.type == EncounterData.Type.ELITE and kp_chance > 0.0 and randf() < kp_chance:
		var kp := Materials.piece_id("king")
		bag[kp] = int(bag.get(kp, 0)) + 1
	return bag


# ── Kill bounties ─────────────────────────────────────────────────────────────────
#
# What killing one enemy unit pays, mid-fight, the instant it dies — the twin of the
# encounter's end-of-fight rewards above, and the ONE place the numbers come from. Combat
# calls this and nothing else: the coin flight and the experience gauge both animate whatever
# it returns, so retuning the economy never touches a line of presentation code.
#
# Two tiers, in the shape every authorable number in this game takes:
#   AUTHORED — the card names a flat `bounty_gold` / `bounty_exp` (0 included: pays nothing).
#   DERIVED  — anything unauthored (-1) is the unit's mana cost through the `bounty.*` rates,
#              floored at `bounty.minimum` so a 0-cost body is still worth killing.
# Today both rates are 1.0, so a 3-cost unit pays 3 gold and 3 experience. That is a tuning
# default, not an assumption anything downstream makes.
#
# Kings pay NOTHING: a king's death is the fight itself ending, and it hands over a treasure
# chest instead (see Combat._king_fall) — a bounty on top would double-pay the same moment.
func kill_bounty(inst: CardInstance) -> Dictionary:
	var none := {"gold": 0, "exp": 0}
	if inst == null or inst.data == null or inst.data.is_king:
		return none
	var cost: int = maxi(0, inst.data.cost)
	var floor_v: int = maxi(0, value("bounty.minimum"))
	var gold: int = inst.data.bounty_gold
	if gold < 0:
		gold = maxi(floor_v, int(round(cost * value_f("bounty.gold_per_cost"))))
	# `xp`, not `exp` — `exp()` is a GDScript global and shadowing it is a warning (this
	# project treats warnings as errors).
	var xp: int = inst.data.bounty_exp
	if xp < 0:
		xp = maxi(floor_v, int(round(cost * value_f("bounty.exp_per_cost"))))
	return {"gold": maxi(0, gold), "exp": maxi(0, xp)}


# ── Run lifecycle (one run per slot) ──────────────────────────────────────────────

func start_new_run() -> void:
	rebuild_modifiers()   # bake current upgrades into this run's starting numbers
	current_run = RunData.create_new(current_profile)
	current_map_state = MapState.create_new()
	save_run()


func load_run() -> void:
	current_run = RunData.from_dict(_read_section("slot_%d" % current_slot))
	current_map_state = MapState.from_dict(_read_section("map_%d" % current_slot))
	rebuild_modifiers()   # after the run loads, so its relics are folded in too


func save_run() -> void:
	if current_slot < 0 or current_run == null:
		return
	_write_section("slot_%d" % current_slot, current_run.to_dict())
	if current_map_state != null:
		_write_section("map_%d" % current_slot, current_map_state.to_dict())


# Rolls the run into the next stage: bump the act and hand out a fresh, unexplored
# map (new seed). Called from the Stage Cleared screen after a non-final boss.
func advance_stage() -> void:
	if current_run == null or current_map_state == null:
		return
	current_run.act += 1
	current_map_state.map_seed = randi()
	current_map_state.current_node_id = -1
	current_map_state.visited_nodes = []
	save_run()


# Ends the current run (defeat/abandon/victory) but KEEPS the slot's meta-progression.
func end_run() -> void:
	_erase_sections(["slot_%d" % current_slot, "map_%d" % current_slot])
	current_run = null
	current_map_state = null
	current_encounter = null


# ── Save management ───────────────────────────────────────────────────────────────

func delete_slot(slot: int) -> void:
	_erase_sections(["profile_%d" % slot, "slot_%d" % slot, "map_%d" % slot])


# The global "reset everything": wipes the player name and every save.
func wipe_all() -> void:
	var sections: Array = ["player"]
	for i in SLOT_COUNT:
		sections.append_array(["profile_%d" % i, "slot_%d" % i, "map_%d" % i])
	_erase_sections(sections)
	current_slot = -1
	current_profile = null
	current_run = null
	current_map_state = null
	username = ""


# ── ConfigFile helpers ────────────────────────────────────────────────────────────

func _read_section(section: String) -> Dictionary:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) != OK:
		return {}
	if not config.has_section(section):
		return {}
	var data := {}
	for key in config.get_section_keys(section):
		data[key] = config.get_value(section, key)
	return data


func _write_section(section: String, data: Dictionary) -> void:
	if sandboxed:
		return
	var config := ConfigFile.new()
	config.load(SAVE_PATH)
	for key in data:
		config.set_value(section, key, data[key])
	config.save(SAVE_PATH)


func _erase_sections(sections: Array) -> void:
	if sandboxed:
		return
	var config := ConfigFile.new()
	config.load(SAVE_PATH)
	for s: String in sections:
		config.erase_section(s)
	config.save(SAVE_PATH)


func _save_player() -> void:
	if sandboxed:
		return
	var config := ConfigFile.new()
	config.load(SAVE_PATH)
	config.set_value("player", "username", username)
	config.save(SAVE_PATH)


func _load_player() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) == OK:
		username = config.get_value("player", "username", "")
