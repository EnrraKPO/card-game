extends Node

const SAVE_PATH = "user://save_data.cfg"

var username: String = "":
	set(value):
		username = value
		_save()


func _ready() -> void:
	_load()


func _save() -> void:
	var config := ConfigFile.new()
	config.set_value("player", "username", username)
	config.save(SAVE_PATH)


func _load() -> void:
	var config := ConfigFile.new()
	if config.load(SAVE_PATH) == OK:
		username = config.get_value("player", "username", "")
