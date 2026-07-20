extends Node

# The RenderFilter registry — apply/clear a data-defined GPU filter on any texture-bearing
# Control, addressed BY ID. Deliberately mirrors the Vfx autoload's attach/detach shape and its
# "<id>@<target>" keying, because the two are meant to compose: Vfx owns WHEN an effect runs
# and how its params move over time, RenderFilters owns WHAT it looks like per-pixel.
#
# The split that matters: the VFX library's procedural behaviors draw primitives sized to a
# target's BOUNDING BOX — they cannot know an anvil from a sandwich. A filter reads the source
# texture's alpha, so the silhouette itself is what the effect is derived from. Anything whose
# look depends on the actual pixels belongs here.

# Applied filters, keyed "<filter id>@<target instance id>" -> the layer node.
var _applied: Dictionary = {}


# Add `id` to `target`. `overrides` are shader uniform names -> values, layered over the
# entry's own params. `texture` may be passed in opts when auto-detection can't find it.
# Idempotent: applying a filter already on a target returns the existing layer.
func apply(id: String, target: Control, overrides: Dictionary = {}) -> RenderFilterLayer:
	var fd := RenderFilterData.get_filter(id)
	if fd == null:
		push_warning("RenderFilters.apply: unknown filter \"%s\"" % id)
		return null
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return null
	var key := _key(id, target)
	if _applied.has(key):
		return get_layer(id, target)

	var tex: Texture2D = overrides.get("texture", null)
	if tex == null:
		tex = _resolve_texture(target)
	if tex == null:
		push_warning("RenderFilters.apply: no source texture found on \"%s\" for filter \"%s\" — a filter reads the source's pixels, so it needs one" % [target.name, id])
		return null

	var layer := RenderFilterLayer.new()
	target.add_child(layer)
	# A child is drawn after (over) the parent; show_behind_parent inside setup() flips that for
	# "behind" filters. Index 0 additionally keeps it under the target's other children.
	target.move_child(layer, 0)
	var skin := overrides.duplicate()
	skin.erase("texture")
	layer.setup(fd, target, tex, skin)

	_applied[key] = layer
	target.tree_exiting.connect(func() -> void: clear(id, target), CONNECT_ONE_SHOT)
	# The layer can also be freed by whoever owns it (Vfx.detach frees the node it was handed),
	# so drop the registry entry on ANY exit — otherwise a later apply() hands back a freed node.
	layer.tree_exiting.connect(func() -> void: _applied.erase(key), CONNECT_ONE_SHOT)
	return layer


func clear(id: String, target: Control) -> void:
	var key := _key(id, target)
	var layer: Node = _applied.get(key, null)
	if layer == null:
		return
	_applied.erase(key)
	if is_instance_valid(layer):
		layer.queue_free()


func get_layer(id: String, target: Control) -> RenderFilterLayer:
	var found: Variant = _applied.get(_key(id, target), null)
	return found if found is RenderFilterLayer else null


func _key(id: String, target: Control) -> String:
	return "%s@%d" % [id, target.get_instance_id()]


# A filter's source is whatever texture the target draws. Targets are usually a TextureRect, or
# a wrapper Control holding one (the map's Forge button is the latter: a plain Control with the
# button art and a transparent Button over it).
func _resolve_texture(target: Control) -> Texture2D:
	if target is TextureRect:
		return (target as TextureRect).texture
	for child in target.get_children():
		if child is TextureRect and (child as TextureRect).texture != null:
			return (child as TextureRect).texture
	return null
