class_name EffectLibrary
extends RefCounted

# The NAMED-EFFECT library (signed ATTACK_SYSTEM_DESIGN.html §3/§8.2): an effect authored
# ONCE, by id, in data/effects/ — one effect per file, the statuses/abilities pattern —
# and referenced by containers ("effects": ["melee_attack"]). The attack family lives
# here; any shared effect joins it. Card-unique effects are authored inline instead; both
# forms parse to the same TriggeredEffect structure (see CardData).
#
# Load is loud and total: a malformed file or a duplicate id is refused with an error,
# never half-loaded — the dead old schema is not parsed, it is re-authored.

const EFFECTS_DIR := "res://data/effects/"

static var _all: Dictionary = {}


static func _static_init() -> void:
	var dir := DirAccess.open(EFFECTS_DIR)
	if dir == null:
		return   # an absent library is fine until content ships
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json(EFFECTS_DIR + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("EffectLibrary: cannot open %s" % path)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("EffectLibrary: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var effect := TriggeredEffect.parse(json.data)
	if effect == null:
		push_error("EffectLibrary: %s does not hold a valid effect — refused" % path)
		return
	if effect.id.is_empty():
		push_error("EffectLibrary: %s holds an effect with no id — a library effect IS its name; refused" % path)
		return
	if _all.has(effect.id):
		push_error("EffectLibrary: duplicate effect id '%s' (%s) — refused" % [effect.id, path])
		return
	_all[effect.id] = effect


# The one lookup. Null = no such named effect (the caller decides loudness).
static func get_effect(p_id: String) -> TriggeredEffect:
	return _all.get(p_id, null)
