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
# The deck the detail screen should display, handed off from the Decks screen (transient).
var viewing_deck_id: String = ""
# The deck the builder should edit, handed off from the Decks screen (transient).
var editing_deck_id: String = ""
# Meta-progression for the currently-selected slot (see ProfileData).
var current_profile: ProfileData = null
# Aggregate of every active run-wide Effect (from owned upgrades now; relics/heroes
# later). Rebuilt whenever the profile changes or a run starts; the game systems read every
# number through value() (globals) / card_bonus() (cards) / EffectSystem.trigger_global
# (combat events). Empty default = no-op for every query.
var current_modifiers: ModifierSet = ModifierSet.new()


func _ready() -> void:
	_load_player()


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


# Run-wide CARD modifier bonus for an attribute on a specific instance, resolved at read-time
# by CardInstance.get_attribute. Guarded to PLAYER combat units (owner 0) so upgrade/relic
# buffs never leak onto enemies or non-combat (deck-builder/preview) instances.
func card_bonus(inst: CardInstance, attr: String) -> int:
	if inst == null or inst.owner != 0:
		return 0
	return current_modifiers.card_bonus(inst, attr)


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


# The one place an encounter's AUTOMATIC win rewards are applied: gold → the run, crafting
# materials + experience → the profile. (The card-pick reward stays interactive in reward_screen.)
# Caller persists the run; grant_materials / grant_experience persist the profile.
func apply_encounter_rewards(enc: EncounterData) -> void:
	if enc == null:
		return
	if current_run != null:
		current_run.gold += enc.gold_reward
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
	var config := ConfigFile.new()
	config.load(SAVE_PATH)
	for key in data:
		config.set_value(section, key, data[key])
	config.save(SAVE_PATH)


func _erase_sections(sections: Array) -> void:
	var config := ConfigFile.new()
	config.load(SAVE_PATH)
	for s: String in sections:
		config.erase_section(s)
	config.save(SAVE_PATH)


func _save_player() -> void:
	var config := ConfigFile.new()
	config.load(SAVE_PATH)
	config.set_value("player", "username", username)
	config.save(SAVE_PATH)


func _load_player() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) == OK:
		username = config.get_value("player", "username", "")
