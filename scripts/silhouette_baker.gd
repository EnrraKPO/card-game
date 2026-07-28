class_name SilhouetteBaker
extends RefCounted

# Bakes the COMPOSITED silhouette of a Control subtree — the widget AND every descendant (badges,
# status pips, anything) — into a texture. The result is the real rendered shape, so an outer glow
# driven from it radiates from the TRUE outline and stays hollow wherever the subtree is opaque: it
# can never cover a child, whatever children exist now or later.
#
# WHY A CLONE: the live widget can't be moved into a render viewport (it would leave its place in
# the UI and its container would re-lay-out with a flicker). We render a scriptless duplicate —
# duplicate() copies each node's current storage properties (textures, text, sizes, scale,
# modulate), so the clone looks exactly like the widget right now, minus behaviour: no _ready side
# effects, no signal spam, no re-triggered VFX. The OUTER outline doesn't depend on a badge's
# number text, so a clone re-baked only on layout change stays faithful.
#
# WHY AN ImageTexture (not the live ViewportTexture): the glow shader samples coarser mips the
# further out it reaches, which is what keeps a wide spread smooth and cheap. A ViewportTexture has
# no mip chain, so we read the render back once and generate mipmaps on it. That also frees the
# viewport immediately — nothing lingers per glow.

# Filled by bake(). `texture` is the mipmapped silhouette; `offset`/`bbox` are the subtree's
# bounding box relative to the widget's own top-left (offset is negative on any overhang side).
var texture: ImageTexture = null
var offset: Vector2 = Vector2.ZERO
var bbox: Vector2 = Vector2.ONE

# NOT PART OF THE SHAPE. A child marked with this meta is drawn OVER the widget but is not part of
# what the widget IS — the targeting tags are the case that named it: chips that hang off the card's
# left edge to annotate it, appearing and vanishing with the preview world. Baked in, they made the
# glow wrap the annotations instead of the card, and left it that shape after they were gone.
#
# The rule is about meaning, not geometry: a status pip overhangs the card too and IS part of it.
const EXCLUDE_META := "silhouette_exclude"


# Marks `node` (and its subtree) as annotation rather than shape — see EXCLUDE_META.
static func exclude(node: CanvasItem) -> void:
	if node != null and is_instance_valid(node):
		node.set_meta(EXCLUDE_META, true)


# Renders `widget`'s subtree silhouette and fills texture/offset/bbox. `host` supplies the tree
# (a RefCounted can't reach it) — the viewport is parented there for the one frame it renders.
# Async: await it. Safe to call again to re-bake after a layout change.
#
# TWO-TIER: a scriptless clone (flags 0) renders any widget whose visuals are child nodes/textures
# with NO side effects — the safe default. But a widget drawn by its OWN script `_draw` (a procedural
# GlossyButton, a custom-painted Control) renders BLANK without its script, so if the first pass
# comes back empty we re-bake keeping the scripts (DUPLICATE_SCRIPTS) so `_draw` runs. That second
# pass re-runs the clone's `_ready`; targets of a glow must have a side-effect-free `_ready` (our
# cards/buttons do — self-contained signal wiring only, no sound or global mutation).
func bake(widget: Control, host: Node) -> void:
	if widget == null or not is_instance_valid(widget):
		return
	_measure(widget)
	var img := await _render_clone(widget, host, 0)
	if img != null and img.get_used_rect().size == Vector2i.ZERO:
		# Nothing drew — a script-painted widget. Retry with its scripts so `_draw` fires.
		img = await _render_clone(widget, host, Node.DUPLICATE_SCRIPTS | Node.DUPLICATE_USE_INSTANTIATION)
	if img == null or img.is_empty() or img.get_used_rect().size == Vector2i.ZERO:
		return
	img.generate_mipmaps()
	texture = ImageTexture.create_from_image(img)


# Renders one clone of the subtree (built with `dup_flags`) into a transient SubViewport and reads
# it back to an Image. Returns null on failure.
func _render_clone(widget: Control, host: Node, dup_flags: int) -> Image:
	if not is_instance_valid(widget):
		return null
	var vp := SubViewport.new()
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.size = Vector2i(maxi(1, ceili(bbox.x)), maxi(1, ceili(bbox.y)))
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vp.add_child(holder)
	var clone := widget.duplicate(dup_flags) as Control
	clone.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Strip the clone's ANCHORS first. We position and size it by hand below, inside a bare holder
	# with no layout of its own — anchors are meaningless here, and a clone that keeps full-rect
	# ones has its size recomputed from a parent it no longer has (Godot warns "size overridden
	# after _ready" and the bake comes out at the wrong extent). The widget being glowed is very
	# often full-rect inside its own host, so this is the common case, not an exotic one.
	clone.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
	# Place the clone so the widget's own origin lands at -offset, putting the bbox top-left
	# (offset may be negative where the subtree overhangs) exactly at the viewport's (0, 0).
	clone.position = -offset
	clone.size = widget.size
	# The silhouette is baked in the widget's UNSCALED local space (offset/bbox are measured
	# there too) — a highlighted/scaled widget's transform is applied at DRAW time by the
	# consumer (GlowFx._sync), so the bake stays valid across a scale animation.
	clone.scale = Vector2.ONE
	clone.rotation = 0.0
	# And at FULL opacity: the silhouette is the widget's SHAPE, not its current tint — baking
	# a ghosted/dimmed widget (duplicate copies modulate) would produce a semi-transparent
	# silhouette that renders as broken, stacked-alpha outlines.
	clone.modulate = Color.WHITE
	clone.self_modulate = Color.WHITE
	# Annotations are dropped from the clone as well as from the measure — otherwise they would
	# still be PAINTED inside the (now smaller) bbox, and the glow would read their edges as part
	# of the outline. Hidden rather than freed: cheaper, and a container that loses a child mid-bake
	# re-lays-out the very thing we are trying to photograph.
	for path: NodePath in _excluded:
		var ex := clone.get_node_or_null(path) as CanvasItem
		if ex != null:
			ex.visible = false
	holder.add_child(clone)
	host.add_child(vp)
	# Let it lay out and render, then read it back. Two frames is belt-and-braces for the clone's
	# own child containers to settle before the capture.
	await host.get_tree().process_frame
	await host.get_tree().process_frame
	var img: Image = null
	if is_instance_valid(vp):
		img = vp.get_texture().get_image()
		vp.queue_free()
	return img


# The subtree's bounding box in the widget's LOCAL space: union of the widget's own rect and every
# visible descendant Control's rect. Descendant rects are mapped through the widget's inverse
# global transform, so the measure is SCALE-NORMALIZED — a widget mid-scale-animation (the
# Highlight treatment) measures the same local bbox as at rest. (Assumes no rotation.)
func _measure(widget: Control) -> void:
	var inv := widget.get_global_transform().affine_inverse()
	var min_p := Vector2.ZERO                 # the widget's own origin is (0,0) in its own space
	var max_p := widget.size
	_excluded.clear()
	for n: Node in widget.find_children("*", "Control", true, false):
		var c := n as Control
		if _is_excluded(c, widget):
			continue
		if not c.is_visible_in_tree() or c.size == Vector2.ZERO:
			continue
		var gr := c.get_global_rect()
		var p1: Vector2 = inv * gr.position
		var p2: Vector2 = inv * gr.end
		min_p = Vector2(minf(min_p.x, p1.x), minf(min_p.y, p1.y))
		max_p = Vector2(maxf(max_p.x, p2.x), maxf(max_p.y, p2.y))
	offset = min_p
	bbox = max_p - min_p


# The excluded nodes found by the last _measure, as paths RELATIVE TO THE WIDGET — which is how the
# clone is told what to drop. Paths rather than the nodes themselves (or the meta, which the clone
# may or may not inherit depending on the duplicate flags in play): the clone is a different tree
# with the same shape, so the same path names the same node in it.
var _excluded: Array[NodePath] = []


func _is_excluded(c: Control, widget: Control) -> bool:
	var n: Node = c
	while n != null and n != widget:
		if n.has_meta(EXCLUDE_META) and bool(n.get_meta(EXCLUDE_META)):
			_excluded.append(widget.get_path_to(c))
			return true
		n = n.get_parent()
	return false


# The silhouette's extent WITHOUT rendering anything — the cheap half of a bake. Callers use it to
# ask "has my shape actually changed?" before paying for a re-bake (see GlowFx.shape_changed).
func measure_only(widget: Control) -> Rect2:
	if widget == null or not is_instance_valid(widget):
		return Rect2()
	var keep_offset := offset
	var keep_bbox := bbox
	_measure(widget)
	var out := Rect2(offset, bbox)
	offset = keep_offset
	bbox = keep_bbox
	return out
