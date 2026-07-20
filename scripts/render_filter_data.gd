class_name RenderFilterData
extends RefCounted

# One entry per RENDER FILTER — a parametrized GPU effect applied to a texture-bearing Control,
# sibling of VFXData in shape and spirit. A filter reads the SOURCE TEXTURE'S PIXELS (its alpha
# silhouette) and renders from them, which is what separates a filter from the VFX library's
# procedural primitives: those draw shapes sized to a target's bounding box and know nothing
# about what the target actually looks like.
#
#   shader — the .gdshader that does the work. Filters are distinguished by their shader plus
#            their params; adding one is a shader + a JSON entry, no engine code.
#   pad    — how far, in px, the effect may spill past the source. RenderFilterLayer grows its
#            quad by this on every side, because canvas shaders are clipped to their own rect
#            and can't otherwise draw outside the source at all.
#   params — the SKIN, keyed BY SHADER UNIFORM NAME so there is no mapping table to keep in
#            sync: whatever is here is set on the material verbatim. html colour strings are
#            converted to Color, numbers to float. Call sites and VFX entries override by the
#            same names.
#   layer  — "behind" (default) or "above" the source. Behind is right for glow/shadow: the
#            opaque face occludes the bright core, so light reads as coming from BEHIND the
#            object rather than being painted over it.
#
# Data-driven from data/render_filters/*.json, same registry pattern as VFXData/SoundData.
# Authoring metadata (`concept`, `explanation`) rides along for a future Tool tab.

var id: String
var display_name: String
var shader: String = ""
var pad: float = 0.0
var params: Dictionary = {}
var layer: String = "behind"    # behind|above
var concept: String = ""
var explanation: String = ""

static var _all: Dictionary = {}


static func _static_init() -> void:
	var dir := DirAccess.open("res://data/render_filters/")
	if dir == null:
		return   # filter definitions are optional content; an absent folder is fine
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname.ends_with(".json"):
			_load_json("res://data/render_filters/" + fname)
		fname = dir.get_next()
	dir.list_dir_end()


static func _load_json(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:
		push_error("RenderFilterData: parse error in %s — %s" % [path, json.get_error_message()])
		return
	var entries: Array = json.data if json.data is Array else [json.data]
	for d: Dictionary in entries:
		if not bool(d.get("enabled", true)):
			continue
		var rf := RenderFilterData.new()
		rf.id           = d.get("id", "")
		rf.display_name = d.get("display_name", "")
		rf.shader       = d.get("shader", "")
		rf.pad          = float(d.get("pad", 0.0))
		rf.params       = d.get("params", {})
		rf.layer        = d.get("layer", "behind")
		rf.concept      = d.get("concept", "")
		rf.explanation  = d.get("explanation", "")
		if not rf.id.is_empty():
			_all[rf.id] = rf


static func get_filter(p_id: String) -> RenderFilterData:
	return _all.get(p_id, null)


static func all() -> Array:
	return _all.values()


# Params are addressed by shader uniform name, so the only translation needed is JSON's types
# to Godot's: html colour strings become Color, ints become float (a shader `float` uniform
# rejects an int Variant). Everything else passes through untouched.
static func coerce(value: Variant) -> Variant:
	if value is String:
		var s: String = value
		if s.is_valid_html_color():
			return Color.html(s)
		return value
	if value is int:
		return float(value)
	return value
