class_name NamedEffects
extends RefCounted

# NAMED EFFECTS — reusable effect PAYLOAD templates, the classic TCG keyword mechanic:
# "Burn 1" = deal 1 damage, a chance the damaged unit catches Ablaze — defined ONCE here,
# referenced by name wherever it's used ({"trigger": ..., "targets": ..., "named": "burn"}).
# The call site owns WHEN and ON WHOM (trigger/targets); the name supplies WHAT HAPPENS.
# Retuning a number in the registry updates every user; the authored files never repeat it.
#
# A template is a PARTIAL effect dict, merged under the authored dict at parse time
# (Effect.from_dict) — authored keys win, so a call site can override a template field
# (escape hatch, not the normal case). Templates may not reference other templates: one
# level of naming, no expansion chains (refused loudly at load).
#
# This is NOT a damage-type system: nothing on the receiving end classifies incoming
# damage (resistances, immunities, per-kind interception don't exist). A separate concern,
# deliberately unbuilt — user call 2026-08-03.

const DIR := "res://data/named_effects/"
# Library/tooling metadata carried on an entry but never part of the TEMPLATE — stripped
# before the merge so it can't leak into parsed effects (the authoring Tool reads and
# writes these; the game's parser has no use for them).
const META_KEYS: Array[String] = ["id", "enabled", "display_name", "description", "tool"]

static var _all: Dictionary = {}
static var _loaded := false


# Lazy-loaded on first lookup rather than _static_init: Effect.from_dict runs from many
# loaders (statuses, cards, charms, relics) whose static-init order is nobody's contract.
static func get_named(id: String) -> Dictionary:
	if not _loaded:
		_load()
	return _all.get(id, {}) as Dictionary


static func all() -> Dictionary:
	if not _loaded:
		_load()
	return _all


# Data model mirrors the other content registries (statuses, cards): a DIRECTORY of json
# files, each an array of entries carrying an "id" — the shape the authoring Tool's
# file-tree model edits natively — with the standard `enabled: false` skip guard.
static func _load() -> void:
	_loaded = true
	var dir := DirAccess.open(DIR)
	if dir == null:
		return   # named effects are optional content; an absent registry is fine
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json(DIR + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("NamedEffects: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = json.data if json.data is Array else [json.data]
	for entry: Variant in entries:
		if not entry is Dictionary:
			push_error("NamedEffects: non-object entry in %s — skipped" % path)
			continue
		var d := entry as Dictionary
		var id := str(d.get("id", ""))
		if id.is_empty():
			push_error("NamedEffects: entry without an id in %s — skipped" % path)
			continue
		if not bool(d.get("enabled", true)):
			continue
		var t := d.duplicate(true)
		for k: String in META_KEYS:
			t.erase(k)
		if t.has("named"):
			# No chains: a template naming another template would expand recursively — the
			# merge in Effect.from_dict relies on the merged dict carrying no "named" key.
			push_error("NamedEffects: template '%s' references another named effect — refused" % id)
			t.erase("named")
		_all[id] = t
