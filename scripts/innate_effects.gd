class_name InnateEffects
extends RefCounted

# INNATE effects — the rules a unit carries by BEING what it is, not by any card author
# remembering to copy them onto every matching card: effects every unit implicitly holds
# alongside its card's own, gated purely by their authored trigger conditions. The
# element-intrinsic tier lives here as pure data — "fire scorches the ground it strikes"
# is ONE rule, held by every unit on either side, and it reaches granted-fire units too
# because composition conditions read the effective composition (LiveEffects) like every
# other condition in the game.
#
# Enumerated by EffectSystem.trigger_grouped as part of the holder's NATIVE tier: same
# dispatch, same cues (the holder's card glints), container-blind like every effect.
# THIS BUILD dispatches event-driven kinds only (TRIGGERED/CUSTOM) — a standing/modifier/
# interceptor innate would need enumeration in LiveEffects/Resolver too, so the loader
# refuses one loudly until someone builds that, rather than letting it silently never fold.
#
# Data model mirrors the other content registries (statuses, named effects): a DIRECTORY of
# json files, each an array of RULES — { "id", "display_name", "description", "effects": [...] }
# — which is the shape the authoring Tool's file-tree model edits natively. A rule's id and
# text are documentation and error-reporting only; `effects` are ordinary Effect dicts. The
# standard `enabled: false` skip guard takes a rule out of the game without deleting it.
# Immutable environment (like StatusData): loaded once, shared into world copies, so
# simulations see the same rules the live fight runs.

const DIR := "res://data/innate_effects/"

static var _effects: Array = []   # Array[Effect]
static var _loaded := false


static func all() -> Array:
	if not _loaded:
		_load()
	return _effects


static func _load() -> void:
	_loaded = true
	var dir := DirAccess.open(DIR)
	if dir == null:
		return   # innates are optional content; an absent registry is a game with no innate rules
	var files: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			files.append(fname)
		fname = dir.get_next()
	dir.list_dir_end()
	# Deterministic across platforms: DirAccess promises no order, and the innate tier's
	# firing order is part of what a seeded replay reproduces.
	files.sort()
	for f: String in files:
		_load_json(DIR + f)


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("InnateEffects: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var rules: Array = json.data if json.data is Array else [json.data]
	for rule_v: Variant in rules:
		if not rule_v is Dictionary:
			push_error("InnateEffects: non-object entry in %s — skipped" % path)
			continue
		var rule := rule_v as Dictionary
		var id := str(rule.get("id", ""))
		if id.is_empty():
			push_error("InnateEffects: rule without an id in %s — skipped" % path)
			continue
		if not bool(rule.get("enabled", true)):
			continue
		for e_data: Dictionary in rule.get("effects", []):
			var e := Effect.from_dict(e_data)
			if (e.kind != Effect.Kind.TRIGGERED and e.kind != Effect.Kind.CUSTOM) or e.is_standing():
				push_error(("InnateEffects: rule '%s' carries a non-event-driven effect — only "
						+ "TRIGGERED/CUSTOM innates dispatch in this build") % id)
				continue
			_effects.append(e)
