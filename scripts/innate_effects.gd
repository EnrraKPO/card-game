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
# Data: res://data/innate_effects.json — [{ "id": ..., "effects": [ ... ] }, ...]. The
# rule "id" is documentation and error-reporting only; effects are ordinary Effect dicts.
# Immutable environment (like StatusData): loaded once, shared into world copies, so
# simulations see the same rules the live fight runs.

const PATH := "res://data/innate_effects.json"

static var _effects: Array = []   # Array[Effect]
static var _loaded := false


static func all() -> Array:
	if not _loaded:
		_load()
	return _effects


static func _load() -> void:
	_loaded = true
	if not FileAccess.file_exists(PATH):
		return   # innates are optional content; an absent file is a game with no innate rules
	var file := FileAccess.open(PATH, FileAccess.READ)
	var json := JSON.new()
	if file == null or json.parse(file.get_as_text()) != OK or not json.data is Array:
		push_error("InnateEffects: bad %s — %s" % [PATH, json.get_error_message()])
		return
	for rule: Dictionary in json.data:
		for e_data: Dictionary in rule.get("effects", []):
			var e := Effect.from_dict(e_data)
			if (e.kind != Effect.Kind.TRIGGERED and e.kind != Effect.Kind.CUSTOM) or e.is_standing():
				push_error(("InnateEffects: rule '%s' carries a non-event-driven effect — only "
						+ "TRIGGERED/CUSTOM innates dispatch in this build") % str(rule.get("id", "?")))
				continue
			_effects.append(e)
