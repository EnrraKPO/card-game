class_name StatusData
extends RefCounted

# A Status is a named, time-boxed bundle of Effects applied to a card at runtime (buffs,
# debuffs, periodic or event-reactive effects). It is NOT special-cased anywhere: it carries the
# SAME Effect payloads (MODIFIER / TRIGGERED / CUSTOM) that cards, charms, relics and upgrades
# use — so anything those can express, a status can too — only it is applied dynamically during
# combat and removed on a timer. See StatusInstance (runtime) and StatusEngine (the operator).
# Data-driven from data/statuses/*.json.

const ICON_DIR := "res://assets/ui/status/"   # pip art: "<id>_status.png" (optional)

# How re-applying onto a card that already carries the status combines with the existing one.
const STACK_REFRESH := "refresh"          # reset the timer; intensity stays 1 (default)
const STACK_EXTEND := "extend"            # add the new duration onto the remaining timer
const STACK_INTENSITY := "stack"          # +1 stack (scales effect magnitude); refresh the timer
const STACK_INDEPENDENT := "independent"  # keep a separate instance

# How the status wears off (what counts down each round, and when it expires):
const DECAY_DURATION := "duration"   # `remaining` counts down (default); expires at 0
const DECAY_STACKS := "stacks"       # the stack COUNT counts down; expires at 0 stacks (e.g. poison)
const DECAY_NONE := "none"           # never wears off (lasts the whole fight)

# When the decay (and any matching periodic effects) resolves. TURN_START/END sweep every unit at
# the round boundary; ACTIVATE ticks the one unit when its turn comes up in the combat order.
const PHASE_TURN_START := "turn_start"
const PHASE_TURN_END := "turn_end"   # default
const PHASE_ACTIVATE := "activate"

var id: String
var display_name: String
var description: String
var color: Color = Color(0.75, 0.75, 0.82)
var glyph: String = "✦"
var beneficial: bool = true     # picks the apply VFX + default pip read
var default_duration: int = 1   # initial `remaining` for DECAY_DURATION statuses
var decay: String = DECAY_DURATION
var decay_phase: String = PHASE_TURN_END
var stacking: String = STACK_REFRESH
var max_stacks: int = 99
var effects: Array = []   # Array[Effect]

static var _all: Dictionary = {}


static func _static_init() -> void:
	var dir := DirAccess.open("res://data/statuses/")
	if dir == null:
		return   # statuses are optional content; an absent folder is fine
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/statuses/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("StatusData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = json.data if json.data is Array else [json.data]
	for d: Dictionary in entries:
		var s := StatusData.from_dict(d)
		if not s.id.is_empty():
			_all[s.id] = s


static func from_dict(d: Dictionary) -> StatusData:
	var s := StatusData.new()
	s.id               = str(d.get("id", ""))
	s.display_name     = str(d.get("display_name", s.id.capitalize()))
	s.description      = str(d.get("description", ""))
	s.color            = Color.html(str(d.get("color", "bfbfd2")))
	s.glyph            = str(d.get("glyph", d.get("letter", "✦")))
	s.beneficial       = bool(d.get("beneficial", true))
	s.default_duration = int(d.get("default_duration", d.get("duration", 1)))
	s.decay            = str(d.get("decay", DECAY_DURATION))
	s.decay_phase      = str(d.get("decay_phase", PHASE_TURN_END))
	s.stacking         = str(d.get("stacking", STACK_REFRESH))
	s.max_stacks       = int(d.get("max_stacks", 99))
	for e_data: Dictionary in d.get("effects", []):
		s.effects.append(Effect.from_dict(e_data))
	return s


static func get_status(p_id: String) -> StatusData:
	return _all.get(p_id, null)


static func all() -> Array:
	return _all.values()


# Pip art ("<id>_status.png" under ICON_DIR), or null (then the pip falls back to the glyph).
func icon() -> Texture2D:
	var path := ICON_DIR + id + "_status.png"
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


# A `px`-square TextureRect of the status art for inline use (tooltips / description rows), or null
# if the status has no art — callers then show text alone rather than falling back to the glyph,
# which doesn't scale or render reliably on mobile.
func icon_rect(px: float) -> TextureRect:
	var tex := icon()
	if tex == null:
		return null
	var r := TextureRect.new()
	r.texture = tex
	r.custom_minimum_size = Vector2(px, px)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.size_flags_vertical = Control.SIZE_SHRINK_BEGIN   # top-align with the first line of the label
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r
