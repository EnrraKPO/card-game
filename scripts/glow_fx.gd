class_name GlowFx
extends ColorRect

# A real outer glow for ANY Control. It reads the widget's true composited silhouette (via
# SilhouetteBaker — the widget AND all descendants) and radiates from that outline on the global
# overlay CanvasLayer, so it:
#   • never clips — it lives outside the UI tree, past every ScrollContainer / panel / clip,
#   • never covers a child — the shader is hollow wherever the silhouette is opaque, and the
#     silhouette contains every child (badge, status pip, whatever), measured, never assumed.
# Reuses filter_glow.gdshader in texture mode. Drive it through Vfx.attach/detach like any sustained
# effect; it cleans itself up when freed or when its widget leaves the tree.

const SHADER_PATH := "res://assets/ui/shaders/filter_glow.gdshader"

var _widget: Control
var _baker: SilhouetteBaker
var _mat: ShaderMaterial
var _pad: float = 48.0            # spill room around the silhouette; must exceed `spread`
var _base_intensity: float = 1.0
var _tween: Tween
var _ready_to_sync := false
var _params: Dictionary = {}     # kept so a recovering re-bake can (re)start breathing


# `params` mirrors a vfx.json entry's params: glow_color (hex), spread, falloff, intensity, and an
# optional `animate` {param, from, to, period} that breathes the intensity.
func setup(widget: Control, params: Dictionary) -> void:
	_widget = widget
	_params = params
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	color = Color.WHITE
	visible = false                # stays hidden until the silhouette is baked

	_configure(params)             # subclass hook: builds _mat + sets _pad/_base_intensity
	material = _mat

	if widget.item_rect_changed.is_connected(_on_widget_moved):
		return
	widget.item_rect_changed.connect(_on_widget_moved)
	widget.resized.connect(_on_widget_resized)
	widget.visibility_changed.connect(_on_widget_visibility)
	widget.tree_exiting.connect(_on_widget_gone, CONNECT_ONE_SHOT)

	_baker = SilhouetteBaker.new()
	await _baker.bake(widget, self)
	if not is_instance_valid(self) or _widget == null or not is_instance_valid(_widget):
		return
	if _baker.texture == null:
		return
	_mat.set_shader_parameter("src_tex", _baker.texture)
	_ready_to_sync = true
	_sync()
	_apply_visibility()
	_start_breathing(params)


# CONTINUOUS FOLLOW: re-place the glow every frame from the widget's LIVE global transform. The
# signal-driven `_sync` calls (item_rect_changed / resized / visibility) only fire when the
# widget's OWN rect changes — they are blind to an ANCESTOR moving or scaling it (a container
# repositioning it, a parent's scale tween, a modal being placed late). That blind spot is what
# made glows drift off their widget. Following every frame tracks any motion with no special
# cases; the expensive part (the bake) stays event-driven on `resized`, so this is just a
# transform read + a few param writes per active glow.
func _process(_delta: float) -> void:
	if _ready_to_sync and visible:
		_sync()


# Builds the ShaderMaterial and sets _pad/_base_intensity from the entry's params. The base is
# the plain outer glow; HighlightFx overrides this with its outline+glow shader (and its widget
# scale-up). Called from setup with _widget already assigned.
func _configure(params: Dictionary) -> void:
	var spread := float(params.get("spread", 40.0))
	_pad = spread + 12.0
	_base_intensity = float(params.get("intensity", 1.0))

	_mat = ShaderMaterial.new()
	_mat.shader = load(SHADER_PATH)
	_mat.set_shader_parameter("shape_mode", 0)                 # sample a real silhouette texture
	_mat.set_shader_parameter("spread", spread)
	_mat.set_shader_parameter("falloff", float(params.get("falloff", 2.0)))
	_mat.set_shader_parameter("glow_color", _parse_color(params.get("glow_color", "ffffff")))
	_mat.set_shader_parameter("intensity", _base_intensity)


func _on_widget_moved() -> void:
	if _ready_to_sync:
		_sync()


# THE rule that keeps a glow from outliving what it belongs to. We draw on the overlay layer,
# outside the widget's branch, so hiding that branch hides the widget and nothing else — the glow
# has no parent whose visibility could carry it. (What this fixes: the hand row is switched off
# wholesale when the inspect view opens (Hand._set_level), so every hand card's glow went on
# radiating over a panel whose card wasn't drawn at all.) `visibility_changed` covers the widget's
# own flag AND any ancestor's, which is the case that actually bites — a card is almost never
# hidden directly, its row is.
func _on_widget_visibility() -> void:
	_apply_visibility()


# Mirrors the widget's EFFECTIVE visibility. Gated on the bake: before the silhouette lands we're
# deliberately hidden regardless, and this must not reveal an unpainted quad. Re-syncs on the way
# back in because `item_rect_changed` doesn't fire while hidden — a layout that shifted under a
# dark branch would otherwise place the glow at a stale rect for a frame.
func _apply_visibility() -> void:
	if not _ready_to_sync or _widget == null or not is_instance_valid(_widget):
		return
	var showing := _widget.is_visible_in_tree()
	if showing:
		_sync()
	visible = showing


# A resize (or flip) changes the outline — re-bake the silhouette, then re-place. This is ALSO
# the recovery path for a failed FIRST bake: a widget that was 0-sized at attach (built before
# its container laid it out) bakes empty, leaving `_ready_to_sync` false and the glow hidden
# forever; when it later gets a real size, `resized` fires here and a now-successful bake flips
# it live (previously the flag never recovered).
func _on_widget_resized() -> void:
	if _widget == null or not is_instance_valid(_widget):
		return
	await _baker.bake(_widget, self)
	if not is_instance_valid(self) or _baker.texture == null:
		return
	_mat.set_shader_parameter("src_tex", _baker.texture)
	var recovered := not _ready_to_sync
	_ready_to_sync = true
	_sync()
	if recovered:
		_apply_visibility()
		_start_breathing(_params)


func _on_widget_gone() -> void:
	queue_free()


# Place our padded quad over the widget's silhouette bbox in GLOBAL space (we're on the overlay
# layer, not the widget's child), and tell the shader where the silhouette sits inside that quad.
# TRANSFORM-AWARE: offset/bbox are measured in the widget's unscaled local space (see
# SilhouetteBaker), so they're mapped through the widget's live global transform here — a widget
# mid-scale (the Highlight treatment) keeps its outline/glow hugging the enlarged silhouette,
# while the pad stays constant screen px. (Assumes no rotation.)
func _sync() -> void:
	if _widget == null or not is_instance_valid(_widget) or _mat == null:
		return
	var xf := _widget.get_global_transform()
	var origin: Vector2 = xf * _baker.offset
	var sbbox := _baker.bbox * xf.get_scale()
	var quad := sbbox + Vector2(_pad, _pad) * 2.0
	if quad.x <= 0.0 or quad.y <= 0.0:
		return
	global_position = origin - Vector2(_pad, _pad)
	size = quad
	_mat.set_shader_parameter("u_size", quad)
	_mat.set_shader_parameter("u_src_rect", Vector4(
			_pad / quad.x, _pad / quad.y, sbbox.x / quad.x, sbbox.y / quad.y))


func _start_breathing(params: Dictionary) -> void:
	var anim: Dictionary = params.get("animate", {})
	if anim.is_empty() or str(anim.get("param", "")) != "intensity":
		return
	var lo := float(anim.get("from", _base_intensity))
	var hi := float(anim.get("to", _base_intensity))
	var period := maxf(0.05, float(anim.get("period", 1.0)))
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_loops()
	_tween.tween_method(_set_intensity, lo, hi, period).set_trans(Tween.TRANS_SINE)
	_tween.tween_method(_set_intensity, hi, lo, period).set_trans(Tween.TRANS_SINE)


func _set_intensity(v: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter("intensity", v)


func _parse_color(v: Variant) -> Color:
	if v is Color:
		return v
	return Color.html(str(v))
