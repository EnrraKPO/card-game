extends Node

const SAVE_PATH = "user://save_data.cfg"
const SLOT_COUNT = 3

var username: String = "":
	set(value):
		username = value
		_save_player()

var current_slot: int = -1
var current_run: RunData = null
var current_map_state: MapState = null
var current_encounter: EncounterData = null


func _ready() -> void:
	_load_player()


func new_run(slot: int) -> void:
	current_slot = slot
	current_run = RunData.create_new()
	current_map_state = MapState.create_new()
	save_run()


func load_run(slot: int) -> void:
	current_slot = slot
	current_run = RunData.from_dict(get_slot_data(slot))
	current_map_state = MapState.from_dict(_read_section("map_%d" % slot))


func save_run() -> void:
	if current_slot < 0 or current_run == null:
		return
	_write_section("slot_%d" % current_slot, current_run.to_dict())
	if current_map_state != null:
		_write_section("map_%d" % current_slot, current_map_state.to_dict())


func delete_slot(slot: int) -> void:
	var config := ConfigFile.new()
	config.load(SAVE_PATH)
	config.erase_section("slot_%d" % slot)
	config.erase_section("map_%d" % slot)
	config.save(SAVE_PATH)


func get_slot_data(slot: int) -> Dictionary:
	return _read_section("slot_%d" % slot)


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


func _save_player() -> void:
	var config := ConfigFile.new()
	config.load(SAVE_PATH)
	config.set_value("player", "username", username)
	config.save(SAVE_PATH)


func _load_player() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) == OK:
		username = config.get_value("player", "username", "")
