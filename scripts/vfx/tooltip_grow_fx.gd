class_name TooltipGrowFx
extends RefCounted

# THE ARRIVAL of a panel that speaks FOR something else: it grows out of the thing it describes.
#
# The card-details hover panel is the case this exists for. It used to snap into existence beside
# the card at full size, which reads as a second window opening — the player's eye has to find it
# and then work out what it belongs to. Growing it from the corner nearest the card answers that
# before it is asked: the panel visibly comes OUT of the card, so the two are one statement.
#
# THE CORNER IS THE WHOLE POINT. A panel scaled about its centre expands in every direction at
# once and says nothing about where it came from; scaled about the corner touching its subject, the
# motion itself is the line drawn between them. Which corner that is has to be measured, not
# assumed: the tooltip normally hangs down-right of the cursor (so the card is up-left of it), but
# against a screen edge the engine flips the panel to the other side of the cursor and the nearest
# corner flips with it.
#
# ── Riding Godot's own tooltip ─────────────────────────────────────────────────────────────
# The panel is what Control._make_custom_tooltip returns, so the ENGINE owns its life: it wraps the
# panel in a PopupPanel, sizes that popup to the panel's minimum size, places it near the cursor and
# clamps it to the screen — all before this gets a frame. Three consequences shape the code below:
#
#   * The wrapper draws its OWN background. Scaling our panel down inside a wrapper that popped at
#     full size would just be a small panel sitting on a big plate, which is worse than no
#     animation at all. The wrapper's stylebox is emptied (our panel draws its own skin anyway).
#   * Placement is known only AFTER the popup is laid out, so the corner is chosen a frame late.
#     The panel is parked at zero scale from the moment it is built — before it ever enters the
#     tree — so that frame is never seen.
#   * The popup is sized from the panel's MINIMUM size, which ignores scale. Growing the panel
#     therefore cannot resize or move the popup underneath it.
#
# There is no exit half. A tooltip is dismissed by the pointer leaving, which has already happened
# by the time anything could play — the panel simply goes.

const ENTRY := "tooltip_grow_in"

const DEF_DUR := 0.16
const DEF_FADE := 0.7    # fraction of the span the fade takes (it finishes before the growth does)


# Hands `panel` its arrival: it will grow out of the corner nearest `anchor` once the engine has
# placed it. Called by whoever BUILDS the tooltip (CardUI._make_custom_tooltip), because the anchor
# — the widget the panel speaks for — is a fact only the builder knows.
#
# Parked at zero here, synchronously, rather than when the tree signal arrives: the panel is handed
# straight to the engine and there is no guarantee about which frame it first draws on.
static func arrive(panel: Control, anchor: Control) -> void:
	if panel == null or anchor == null or not Vfx.live(ENTRY):
		return
	panel.scale = Vector2.ZERO
	panel.modulate.a = 0.0
	panel.tree_entered.connect(_grow.bind(panel, anchor), CONNECT_ONE_SHOT)


# The entry's registered renderer, for a panel that is ALREADY mounted somewhere of its own:
#
#   Vfx.play("tooltip_grow_in", panel, {"anchor": the_widget_it_speaks_for})
#
# arrive() is the same growth for the one case that cannot go through Vfx.play — a tooltip panel is
# handed to the engine before it is in any tree, and Vfx.play (rightly) refuses a target that isn't.
static func play(vd: VFXData, target: Control, opts: Dictionary = {}) -> void:
	if target == null or not is_instance_valid(target):
		return
	target.scale = Vector2.ZERO
	target.modulate.a = 0.0
	await _grow_now(vd, target, opts.get("anchor") as Control)


static func _grow(panel: Control, anchor: Control) -> void:
	var vd := VFXData.get_vfx(ENTRY)
	if vd == null:
		return
	_strip_wrapper(panel)
	await _grow_now(vd, panel, anchor)


static func _grow_now(vd: VFXData, panel: Control, anchor: Control) -> void:
	if vd == null or not is_instance_valid(panel) or not panel.is_inside_tree():
		return
	# One frame for the popup to be sized and placed — until then the panel has no rect to take a
	# corner from and no position to compare against the anchor.
	await panel.get_tree().process_frame
	if not is_instance_valid(panel) or not panel.is_inside_tree():
		return
	# The anchor may already be gone (the card died, the screen changed): the panel still has to
	# arrive, it just has nothing to point at, so it comes out of its own centre.
	panel.pivot_offset = _corner_toward(panel, anchor)
	var dur := Vfx.paced(maxf(0.05, vd.num_param("duration", DEF_DUR)), vd)
	var fade: float = clampf(vd.num_param("fade", DEF_FADE), 0.05, 1.0)
	var tw := panel.create_tween()
	tw.tween_property(panel, "scale", Vector2.ONE, dur) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(panel, "modulate:a", 1.0, dur * fade)
	await tw.finished
	if is_instance_valid(panel):
		panel.scale = Vector2.ONE


# The popup Godot wraps a custom tooltip in draws a themed plate behind it. Ours is a PanelContainer
# with its own background and border, so that plate is pure duplication at rest — and during the
# growth it is the one thing on screen that did not grow. Emptied rather than hidden: the stylebox
# also supplies content margins, and dropping them is what lets the panel's own edge be the edge.
# A POPUP, not a Control: what the engine wraps a custom tooltip in is a PopupPanel, which descends
# from Window. Reaching for it as a Control finds nothing and silently strips nothing — which is
# exactly the failure this comment exists to stop the next reader from re-introducing.
static func _strip_wrapper(panel: Control) -> void:
	var wrapper := panel.get_parent() as Window
	if wrapper == null:
		return
	wrapper.add_theme_stylebox_override("panel", StyleBoxEmpty.new())


# Which of the panel's four corners sits closest to `anchor`, in panel-local coordinates — the
# point the growth pivots about. Falls back to the centre when there is nothing to point at, which
# is the honest answer: an arrival with no subject came from nowhere in particular.
#
# The two rects have to be compared in ONE space, and a tooltip panel does not share the anchor's.
# It lives inside the popup window the engine wrapped it in, so its own global rect is measured from
# that popup's corner; the popup's `position` is where that corner sits in the space the anchor is
# already measured in, which makes it the bridge. A panel mounted in the anchor's own viewport (the
# play() path) needs no bridge at all — hence the two cases rather than one.
static func _corner_toward(panel: Control, anchor: Control) -> Vector2:
	var size := panel.size
	if not is_instance_valid(anchor) or not anchor.is_inside_tree():
		return size * 0.5
	var origin := panel.get_global_rect().position
	if panel.get_viewport() != anchor.get_viewport():
		var popup := panel.get_viewport() as Window
		if popup == null:
			return size * 0.5
		origin += Vector2(popup.position)
	var toward := anchor.get_global_rect().get_center()
	var best := size * 0.5
	var best_d := INF
	for corner: Vector2 in [Vector2.ZERO, Vector2(size.x, 0.0), Vector2(0.0, size.y), size]:
		var d := (origin + corner).distance_squared_to(toward)
		if d < best_d:
			best_d = d
			best = corner
	return best
