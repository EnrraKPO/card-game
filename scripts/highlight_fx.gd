class_name HighlightFx
extends GlowFx

# THE canonical "this is selected / active" treatment, for ANY Control anywhere (forge selection
# now; combat selection next). Three cues in one attach:
#   • the widget grows in place — a pure canvas transform (pivot-centred scale), so its layout
#     size never changes and nothing around it is displaced; it rises over its neighbours
#     (z bump) the way a picked-up card should,
#   • a thick solid outline hugging the widget's TRUE composited silhouette,
#   • a dense outer glow radiating past the outline.
# Outline + glow ride the GlowFx machinery (SilhouetteBaker + overlay layer + transform-aware
# sync), driving filter_highlight.gdshader instead of the plain glow.
#
# ALL of it is data: the `highlight` entry in data/vfx/vfx.json carries scale, outline_color,
# outline_width, glow_color, glow_intensity, glow_span, glow_spread — tool-tunable, no code
# constants. Use it from anywhere:
#   Vfx.attach("highlight", any_control)  /  Vfx.detach("highlight", any_control)

const HIGHLIGHT_SHADER := "res://assets/ui/shaders/filter_highlight.gdshader"

const GROW_TIME := 0.16      # scale-up pop (slight overshoot); the shrink-back is a touch quicker
const SHRINK_TIME := 0.12
const Z_LIFT := 20           # draw-order lift while highlighted — the grown widget covers, never peeks

var _orig_scale := Vector2.ONE
var _orig_pivot := Vector2.ZERO
var _orig_z := 0
var _grow := 1.15
var _grow_tween: Tween


# The vfx.json `highlight` entry's renderer-"custom" state hook (see Vfx.register_custom).
static func state(vd: VFXData, target: Control) -> Node:
	var h := HighlightFx.new()
	Vfx.overlay_layer().add_child(h)   # outside the UI tree — outline/glow escape all clipping
	h.setup(target, vd.params)
	return h


# GlowFx hook: our shader + params, plus the widget scale-up (started here, BEFORE the async
# silhouette bake, so the grow pops on the same frame as the selection tap).
func _configure(params: Dictionary) -> void:
	var outline_w := maxf(float(params.get("outline_width", 6.0)), 0.0)
	var span := maxf(float(params.get("glow_span", 30.0)), 1.0)
	_pad = outline_w + span + 12.0
	_base_intensity = float(params.get("glow_intensity", 1.0))

	_mat = ShaderMaterial.new()
	_mat.shader = load(HIGHLIGHT_SHADER)
	_mat.set_shader_parameter("outline_color", _parse_color(params.get("outline_color", "ffffff")))
	_mat.set_shader_parameter("outline_width", outline_w)
	_mat.set_shader_parameter("glow_color", _parse_color(params.get("glow_color", "ffffff")))
	_mat.set_shader_parameter("glow_span", span)
	_mat.set_shader_parameter("glow_spread", float(params.get("glow_spread", 2.0)))
	_mat.set_shader_parameter("intensity", _base_intensity)

	_grow = maxf(float(params.get("scale", 1.15)), 0.01)
	_start_grow()


func _start_grow() -> void:
	_orig_scale = _widget.scale
	_orig_pivot = _widget.pivot_offset
	_orig_z = _widget.z_index
	_widget.pivot_offset = _widget.size * 0.5   # grow evenly from the centre
	_widget.z_index = _orig_z + Z_LIFT
	_grow_tween = create_tween()
	_grow_tween.tween_method(_set_widget_scale, _widget.scale, _orig_scale * _grow, GROW_TIME) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Drives the grow AND keeps the overlay quad glued to the growing silhouette — item_rect_changed
# doesn't fire for scale changes, so the tween is the sync signal here.
func _set_widget_scale(s: Vector2) -> void:
	if _widget == null or not is_instance_valid(_widget):
		return
	_widget.scale = s
	if _ready_to_sync:
		_sync()


# Detach (queue_free) hands the widget back exactly as found: original z/pivot, and the scale
# eased back down on the WIDGET's own tween (this node is dying, its tweens die with it). If the
# widget itself is leaving the tree, just snap — nobody's watching.
func _exit_tree() -> void:
	if _grow_tween != null and _grow_tween.is_valid():
		_grow_tween.kill()
	if _widget == null or not is_instance_valid(_widget):
		return
	_widget.z_index = _orig_z
	_widget.pivot_offset = _orig_pivot
	if _widget.is_inside_tree():
		var tw := _widget.create_tween()
		tw.tween_property(_widget, "scale", _orig_scale, SHRINK_TIME) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	else:
		_widget.scale = _orig_scale
