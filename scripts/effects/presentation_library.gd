class_name PresentationLibrary
extends RefCounted

# The presentations library (signed EFFECT_PRESENTATION_DESIGN.html §8): the one data
# file defining the presentations effects appoint — a windups section (each entry a name
# bound to one of the three choreographies of §5: lunge, bolt, glint) and a contacts
# section (each entry the named visuals that play on every recipient when the effect
# lands; ships with the one default_landing entry — amendment 4 of iteration 2).
#
# Load is loud and total: a malformed file, entry, or unknown
# choreography is refused with an error, never half-loaded.

const PRESENTATIONS_PATH := "res://data/presentations.json"
const CHOREOGRAPHIES: Array[String] = ["lunge", "bolt", "glint"]

static var _windups: Dictionary = {}
static var _contacts: Dictionary = {}


static func _static_init() -> void:
	var file := FileAccess.open(PRESENTATIONS_PATH, FileAccess.READ)
	if file == null:
		push_error("PresentationLibrary: cannot open %s" % PRESENTATIONS_PATH)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK or not (json.data is Dictionary):
		push_error("PresentationLibrary: %s is not a valid presentations file — refused whole"
				% PRESENTATIONS_PATH)
		return
	var d := json.data as Dictionary
	for name: String in (d.get("windups", {}) as Dictionary):
		var entry: Variant = (d["windups"] as Dictionary)[name]
		if not (entry is Dictionary) or not CHOREOGRAPHIES.has(str((entry as Dictionary).get("choreography", ""))):
			push_error("PresentationLibrary: windup '%s' names no known choreography — refused" % name)
			continue
		_windups[name] = entry
	for name: String in (d.get("contacts", {}) as Dictionary):
		var entry: Variant = (d["contacts"] as Dictionary)[name]
		if not (entry is Dictionary) or not ((entry as Dictionary).get("visuals") is Array):
			push_error("PresentationLibrary: contact '%s' declares no visuals array — refused" % name)
			continue
		_contacts[name] = entry


# The two questions the library answers (§8). An unknown name is loud — appointments are
# validated at effect parse, so reaching here with a stranger is a programming error.
static func windup(name: String) -> Dictionary:
	if not _windups.has(name):
		push_error("PresentationLibrary: no windup named '%s'" % name)
		return {}
	return _windups[name]


static func contact(name: String) -> Dictionary:
	if not _contacts.has(name):
		push_error("PresentationLibrary: no contact named '%s'" % name)
		return {}
	return _contacts[name]


static func has_windup(name: String) -> bool:
	return _windups.has(name)


static func has_contact(name: String) -> bool:
	return _contacts.has(name)
