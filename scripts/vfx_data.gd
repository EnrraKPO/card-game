class_name VFXData
extends RefCounted

# One entry per VISUAL EFFECT the game will ever show — the data half of the VFX pipeline,
# sibling of SoundData. A VFX is addressed BY ID and applied to any Control target through the
# Vfx autoload; call sites never know how an effect renders. Each entry resolves its id to:
#
#   renderer — HOW it renders. "procedural" is the only kind today (tweened primitives drawn
#              by Vfx); asset-backed renderers later (flipbook/scene/...) are new kinds + one
#              dispatch arm in Vfx — entries switch renderer without any call-site change.
#   behavior — WHICH procedural primitive it rides (see Vfx.BEHAVIORS): flash, pulse, pop,
#              shake, ring, sparkle, glint, glow, float_label, burst, travel, reticle, dissolve.
#   params   — the SKIN: colors/scale/duration/intensity. What separates projectile_fire from
#              projectile_water over the same travel behavior.
#   sustained — a state (glow/aura) attached and detached, vs a one-shot. Sustained entries
#              must ride a sustained-capable behavior (Vfx.SUSTAINED_BEHAVIORS).
#   placeholder — TRUE until the effect is given its designed look. Placeholder entries are
#              clearly flagged and can be muted at will (DevFlags.placeholder_vfx, F8) so
#              undesigned effects never pollute a look-judgment pass. The pre-existing combat/
#              forge effects ship placeholder: false — they ARE their designed look today.
#
# Authoring metadata rides along: `concept` (what the moment means), `explanation` (what it
# looks like), `prompt` (AI generation text for a future asset renderer). Managed in the
# Tool's VFX tab. Data-driven from data/vfx/*.json, same registry pattern as SoundData.

var id: String
var display_name: String
var category: String = "ui"     # ui|card|combat|status|resource|map|economy|lab|meta|screen
var renderer: String = "procedural"
var behavior: String = "flash"
var params: Dictionary = {}     # behavior skin: color/color2 (html), scale, duration, intensity
var sustained: bool = false
var placeholder: bool = true
# Companion sound: a SoundData id Vfx.play fires atomically with the visual ("" = silent).
# The audio half of the cue lives HERE, in data — call sites never pair the two by hand.
var sfx: String = ""
var concept: String = ""        # what this moment MEANS — why the effect exists
var explanation: String = ""    # what it LOOKS like — the visual design
var prompt: String = ""         # AI generation prompt for a future asset-backed look

static var _all: Dictionary = {}


static func _static_init() -> void:
	var dir := DirAccess.open("res://data/vfx/")
	if dir == null:
		return   # VFX definitions are optional content; an absent folder is fine
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/vfx/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		push_error("VFXData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = json.data if json.data is Array else [json.data]
	for d: Dictionary in entries:
		if not bool(d.get("enabled", true)):
			continue
		var v := VFXData.new()
		v.id           = d.get("id", "")
		v.display_name = d.get("display_name", "")
		v.category     = d.get("category", "ui")
		v.renderer     = d.get("renderer", "procedural")
		v.behavior     = d.get("behavior", "flash")
		v.params       = d.get("params", {})
		v.sustained    = bool(d.get("sustained", false))
		v.placeholder  = bool(d.get("placeholder", true))
		v.sfx          = d.get("sfx", "")
		v.concept      = d.get("concept", "")
		v.explanation  = d.get("explanation", "")
		v.prompt       = d.get("prompt", "")
		if not v.id.is_empty():
			_all[v.id] = v


static func get_vfx(p_id: String) -> VFXData:
	return _all.get(p_id, null)


static func all() -> Array:
	return _all.values()


# A param colour, html-parsed with a fallback — the accessor behaviors read their skin through.
func color_param(key: String, fallback: Color) -> Color:
	var raw := str(params.get(key, ""))
	if raw.is_empty() or not raw.is_valid_html_color():
		return fallback
	return Color.html(raw)


func num_param(key: String, fallback: float) -> float:
	var raw: Variant = params.get(key)
	if raw is float or raw is int:
		return float(raw)
	return fallback
