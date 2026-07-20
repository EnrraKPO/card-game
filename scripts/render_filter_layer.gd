class_name RenderFilterLayer
extends ColorRect

# The quad a RenderFilter actually renders into. Its whole job is to solve the constraint that
# makes filters awkward in the first place: a canvas_item shader is CLIPPED TO ITS NODE'S RECT,
# so an effect that must spill (glow, shadow, bloom) cannot live on the source node. This node
# is therefore sized to source + 2*pad and handed the source as a texture uniform, and the
# shader remaps its own UV back into the source's sub-rect (`u_src_rect`).
#
# PARENTING: it is a CHILD of the target with show_behind_parent, not a sibling. A sibling
# would be laid out by the target's parent whenever that parent is a Container; a child with
# show_behind_parent draws underneath the target and everything else it holds, while a plain
# Control parent never lays its children out — so the geometry we set here sticks. `above`
# filters skip the flag and draw over the target instead.
#
# ASSUMPTION: the source texture fills the target's rect. That holds for the TextureRect/button
# cases this exists for; a target whose texture is letterboxed inside it would need its real
# drawn rect passed in rather than inferred.

var filter_id: String
var pad: float = 0.0

var _target: Control
var _shader_mat: ShaderMaterial
var _shape := false
var _overlay := false


func setup(fd: RenderFilterData, target: Control, tex: Texture2D, overrides: Dictionary) -> void:
	filter_id = fd.id
	pad = fd.pad
	_target = target

	name = "RenderFilter_" + fd.id
	color = Color.WHITE          # the fragment shader replaces this wholesale
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	show_behind_parent = fd.layer != "above"

	var sh: Shader = load(fd.shader)
	if sh == null:
		push_error("RenderFilterLayer: filter \"%s\" has no loadable shader at %s" % [fd.id, fd.shader])
		return
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = sh
	material = _shader_mat

	# Shape-sourced filters describe their silhouette analytically and never sample a texture;
	# tex is null for them. shape_mode tells the shader which branch to take.
	_shape = fd.source == "rounded_rect"
	_shader_mat.set_shader_parameter("shape_mode", 1 if _shape else 0)
	if tex != null:
		_shader_mat.set_shader_parameter("src_tex", tex)
	# Entry defaults first, call-site overrides second — both keyed by shader uniform name.
	for key: String in fd.params:
		_shader_mat.set_shader_parameter(key, RenderFilterData.coerce(fd.params[key]))
	for key: String in overrides:
		_shader_mat.set_shader_parameter(key, RenderFilterData.coerce(overrides[key]))

	_overlay = fd.layer == "overlay"
	# Overlay layers live outside the target's subtree, so they must track its POSITION too, not
	# just its size — item_rect_changed covers both.
	if _overlay:
		target.item_rect_changed.connect(_sync)
	target.resized.connect(_sync)
	_sync()


# Geometry is expressed in the TARGET's own space (we are its child), so it depends on nothing
# but the target's size — no global-coordinate tracking, and it follows the target for free
# wherever the target moves.
func _sync() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	var quad := _target.size + Vector2(pad, pad) * 2.0
	if _overlay:
		# Not our target's child: place by its GLOBAL rect on the overlay canvas.
		global_position = _target.get_global_rect().position - Vector2(pad, pad)
	else:
		position = Vector2(-pad, -pad)
	size = quad
	if _shader_mat == null or quad.x <= 0.0 or quad.y <= 0.0:
		return
	_shader_mat.set_shader_parameter("u_size", quad)
	# Where the source sits inside our padded quad, in our UV space.
	_shader_mat.set_shader_parameter("u_src_rect", Vector4(
			pad / quad.x, pad / quad.y, _target.size.x / quad.x, _target.size.y / quad.y))
	# Shape filters work in px against the target's own rect, so they need its size directly —
	# a UV-space rect alone can't tell a 220x64 button from a 140x183 card.
	_shader_mat.set_shader_parameter("u_src_size", _target.size)


# The handle the VFX layer animates: any shader uniform, by name.
func set_param(key: String, value: Variant) -> void:
	if _shader_mat != null:
		_shader_mat.set_shader_parameter(key, RenderFilterData.coerce(value))


func get_param(key: String) -> Variant:
	return _shader_mat.get_shader_parameter(key) if _shader_mat != null else null
