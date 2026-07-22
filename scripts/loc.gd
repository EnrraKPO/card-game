extends Node

# The localization layer — one call, Loc.t("entry.title"), resolves against the currently
# selected language's string table. Tables are game data: data/locale/<lang>.json, flat dicts
# of dotted key → string, authored in the Tool's 🌐 Localization tab. English is the CANONICAL
# table: every key exists there, and a missing key in another language falls back to English,
# then to the raw key itself — an untranslated string is always VISIBLE, never blank, so gaps
# surface immediately.
#
# The player's chosen language persists to user://locale.json (mirrors AudioSettings). Absent
# a saved choice, the first launch auto-detects the OS locale (Spanish → es, everything else
# → en). Switching language emits `changed` so code-built screens can rebuild in place.

signal changed

const DEFAULT_LANG := "en"
# The languages we ship; the order here is the pick order in the Settings language row.
const LANGS := ["en", "es"]
const LANG_NAMES := {"en": "English", "es": "Español"}
const _DIR := "res://data/locale/"
const _USER_PATH := "user://locale.json"

var _lang := DEFAULT_LANG
var _tables: Dictionary = {}   # lang → {key: String}


func _ready() -> void:
	for lang: String in LANGS:
		_tables[lang] = _load_table(lang)
	_lang = _initial_lang()


func locale() -> String:
	return _lang


func language_name(lang: String) -> String:
	return String(LANG_NAMES.get(lang, lang))


# The one lookup: resolve `key` in the active language, filling {placeholders} from `params`
# — Loc.t("entry.greet", {"name": n}) turns "Hola, {name}" into "Hola, <n>".
func t(key: String, params: Dictionary = {}) -> String:
	return t_in(_lang, key, params)


# Resolve `key` in a SPECIFIC language rather than the active one. Fallback chain: the
# requested language → English → the raw key (an untranslated string stays VISIBLE). t()
# routes through here with the active language; the onboarding language gate calls it once
# per language to show both readings at once, before the player has chosen.
func t_in(lang: String, key: String, params: Dictionary = {}) -> String:
	var s := key
	var table: Dictionary = _tables.get(lang, {})
	if table.has(key):
		s = String(table[key])
	elif (_tables.get(DEFAULT_LANG, {}) as Dictionary).has(key):
		s = String((_tables[DEFAULT_LANG] as Dictionary)[key])
	for name: String in params:
		s = s.replace("{" + name + "}", str(params[name]))
	return s


func set_locale(lang: String) -> void:
	if lang == _lang or not (lang in LANGS):
		return
	_lang = lang
	_save()
	changed.emit()


# The player's saved choice wins; absent it, auto-detect the OS locale once (Spanish → es).
func _initial_lang() -> String:
	var f := FileAccess.open(_USER_PATH, FileAccess.READ)
	if f != null:
		var json := JSON.new()
		if json.parse(f.get_as_text()) == OK and json.data is Dictionary:
			var saved := String((json.data as Dictionary).get("lang", ""))
			if saved in LANGS:
				return saved
	var os_lang := OS.get_locale_language()   # e.g. "es", "en"
	return os_lang if os_lang in LANGS else DEFAULT_LANG


func _load_table(lang: String) -> Dictionary:
	var path := _DIR + lang + ".json"
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK or not (json.data is Dictionary):
		push_error("Loc: bad locale file " + path)
		return {}
	return json.data as Dictionary


func _save() -> void:
	var f := FileAccess.open(_USER_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"lang": _lang}))
