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
		var existing := get_layer(id, target)
		# A layer mid-queue_free (Vfx.detach frees the node it was handed — see there) is still
		# is_instance_valid until the deferred delete actually runs, so that alone can't tell a
		# live layer from a doomed one about to vanish out from under a fresh attach this same
		# frame. is_queued_for_deletion catches that window; falling through re-creates instead.
		if existing != null and not existing.is_queued_for_deletion():
			return existing
		_applied.erase(key)

	# Shape-sourced filters derive their silhouette analytically, so they need no texture at all —
	# which is the whole point of them: a procedural button has no pixels to hand us.
	var tex: Texture2D = overrides.get("texture", null)
	if tex == null and fd.source != "rounded_rect":
		tex = _resolve_texture(target)
		if tex == null:
			push_warning("RenderFilters.apply: no source texture found on \"%s\" for filter \"%s\" — a texture-sourced filter reads the source's pixels, so it needs one (use a rounded_rect source for procedural or composed targets)" % [target.name, id])
			return null

	var layer := RenderFilterLayer.new()
	# A call site can override the filter's authored layer (e.g. a shared "overlay" glow parented
	# "behind" a specific unclipped target so that target's own children — a card's stat badges —
	# draw ON TOP of it instead of being washed out). Layer is a per-application property, not part
	# of the silhouette skin, so it's erased from the skin below like "texture".
	var eff_layer := str(overrides.get("layer", fd.layer))
	if eff_layer == "overlay":
		# A filter parented to its target inherits every ancestor's clip_contents, so a spilling
		# effect gets cut off by any clipping holder above it — invisibly, since the part that
		# survives is the part inside the silhouette, which such filters deliberately leave
		# empty. Overlay filters draw on the VFX CanvasLayer in GLOBAL coordinates instead,
		# outside the UI tree entirely. Safe only for effects that add nothing over the target
		# itself (a hollow outer glow); anything that fills the silhouette would wash it out.
		Vfx.overlay_layer().add_child(layer)
	else:
		target.add_child(layer)
		# Sibling order decides what a filter sits under. "behind" goes to index 0 so it is
		# beneath the target's other children too (show_behind_parent in setup() puts it under
		# the target itself); "above" must stay LAST or those siblings would cover its light.
		if eff_layer != "above":
			target.move_child(layer, 0)
	var skin := overrides.duplicate()
	skin.erase("texture")
	skin.erase("layer")
	layer.setup(fd, target, tex, skin, eff_layer)

	_applied[key] = layer
	target.tree_exiting.connect(func() -> void: clear(id, target), CONNECT_ONE_SHOT)
	# The layer can also be freed by whoever owns it (Vfx.detach frees the node it was handed),
	# so drop the registry entry on ANY exit — otherwise a later apply() hands back a freed node.
	layer.tree_exiting.connect(func() -> void: _applied.erase(key), CONNECT_ONE_SHOT)
	return layer


func clear(id: String, target: Control) -> void:
	var key := _key(id, target)
	if not _applied.has(key):
		return
	var raw: Variant = _applied[key]   # Variant, not typed Node — see Vfx.detach for why
	_applied.erase(key)
	if is_instance_valid(raw):
		(raw as Node).queue_free()


func get_layer(id: String, target: Control) -> RenderFilterLayer:
	var found: Variant = _applied.get(_key(id, target), null)
	if is_instance_valid(found) and found is RenderFilterLayer:
		return found
	return null


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
