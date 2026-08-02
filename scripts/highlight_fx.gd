class_name HighlightFx
extends GlowFx

# THE canonical "this is picked" treatment, for ANY Control anywhere — worn by the forge's picked
# source and by a picked combat card alike, so selection reads identically wherever the player
# meets it. Three cues, from TWO owners:
#   • a thick solid outline hugging the widget's TRUE composited silhouette, and
#   • a dense outer glow radiating past the outline
#     — both this effect's, on the overlay layer (SilhouetteBaker + transform-aware sync), driving
#       filter_highlight.gdshader instead of the plain glow;
#   • the widget grows in place — a pure canvas transform (pivot-centred scale), so its layout size
#     never changes and nothing around it is displaced, and it rises over its neighbours (z bump)
#     the way a picked-up card should
#     — the WIDGET's, applied by whoever owns it via the static set_grown below.
#
# ALL of it is data: the `highlight` entry in data/vfx/vfx.json carries scale, outline_color,
# outline_width, glow_color, glow_intensity, glow_span, glow_spread — tool-tunable, no code
# constants. Used from anywhere, always as a pair:
#   Vfx.attach("highlight", w) + HighlightFx.set_grown(w, true)
#   Vfx.detach("highlight", w) + HighlightFx.set_grown(w, false)

const HIGHLIGHT_SHADER := "res://assets/ui/shaders/filter_highlight.gdshader"

const ENTRY := "highlight"   # the vfx.json entry this class is THE treatment for

const GROW_TIME := 0.16      # scale-up pop (slight overshoot); the shrink-back is a touch quicker
const SHRINK_TIME := 0.12
const Z_LIFT := 20           # draw-order lift while highlighted — the grown widget covers, never peeks

# THE GROW IS NOT THIS EFFECT'S TO OWN — see set_grown below.
#
# A widget's scale/pivot/z belong to the widget. This effect used to take them over for the
# duration of a highlight, which meant it had to guess what "resting" looked like by SAMPLING them
# when it attached. That guess is wrong whenever the widget isn't at rest at that instant — and it
# routinely wasn't, because a highlight is torn down and rebuilt on every re-pick, with the old
# one's teardown landing AFTER its replacement was already up (Vfx.detach frees deferred, attach
# builds immediately). Each pass baked a transient into the "resting" size, so a card grew a little
# more every time it was clicked and never came home.
#
# No amount of bookkeeping inside the effect fixes that, because the effect is not the owner. So
# the widget's owner drives the grow through set_grown() — an idempotent state, not a lifecycle —
# and this effect does what it is actually good at: the outline and glow on the overlay, which
# TRACK whatever transform the widget happens to have (GlowFx syncs to it) and never write it.
# THE OUTLINE IS A CHANNEL, AND IT CAN BE LENT OUT. A widget may legitimately be two things at once
# — picked AND pointed at — and each wants a ring of a different colour on the same edge. Two rings
# is not an answer: they land on the same pixels and both lose. So the outline is a channel with one
# occupant, and a hover borrows it (see HoverFx.apply) while leaving the rest of this effect alone:
# the glow keeps radiating and the grow keeps holding, so the selection is still plainly a selection
# with the hover ring inside its light.
#
# Muted rather than re-configured, so the authored width survives to be handed straight back — and
# `_pad` is deliberately NOT recomputed, since a quad that is briefly larger than it needs costs
# nothing and re-padding would force a re-place mid-hover.
var _outline_w: float = 0.0

func set_outline_shown(on: bool) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("outline_width", _outline_w if on else 0.0)


const GROWN_META := "highlight_grown"   # {on, scale, pivot, z} — the widget's own record
const GROW_META  := "highlight_grow"    # the authored grow factor, left here by the attached entry
const TWEEN_META := "highlight_tween"   # the widget's one in-flight transform tween


# The vfx.json `highlight` entry's renderer-"custom" state hook (see Vfx.register_custom).
static func state(vd: VFXData, target: Control) -> Node:
	var h := HighlightFx.new()
	# The target's own overlay BAND: outside the UI tree (no clipping), and depth-correct —
	# a table card's highlight stays under a modal's scrim, a modal widget's rises above it.
	Vfx.overlay_layer_for(target).add_child(h)
	h.setup(target, vd.params)
	return h


# GlowFx hook: our shader + params, plus the widget scale-up (started here, BEFORE the async
# silhouette bake, so the grow pops on the same frame as the selection tap).
func _configure(params: Dictionary) -> void:
	var outline_w := maxf(float(params.get("outline_width", 6.0)), 0.0)
	var span := maxf(float(params.get("glow_span", 30.0)), 1.0)
	_outline_w = outline_w
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

	# The authored grow travels with the entry, but it is APPLIED by the widget's owner, not here.
	#
	# ONLY IF THIS ENTRY ACTUALLY AUTHORS ONE. The meta is a single slot per WIDGET, while entries
	# are many — so an entry that grows nothing (scale 1) used to stamp "grow by 1.0" over whatever
	# the widget's real selection grow was, and the next set_grown() with no override read it and
	# grew by nothing. That is exactly what happened when a combat card wore the turn-order
	# spotlight (scale 1) and was then picked: the pick's grow silently became a no-op, but only
	# when the cursor had visited the strip first, which made it look like the card knew how it had
	# been selected. An effect with no opinion about the grow must not leave an instruction lying
	# around for one that has.
	#
	# This does NOT make the slot safe for two effects that BOTH grow — for that the owner must
	# name its factor (see the scale_override argument, and CardUI._apply_selected).
	var grow := maxf(float(params.get("scale", 1.15)), 0.01)
	if not is_equal_approx(grow, 1.0):
		_widget.set_meta(GROW_META, grow)


# THE GROW, as a state the widget's owner sets on itself. Idempotent both ways: asking for the
# state a widget is already in does nothing — it does not re-read the widget, does not restart a
# tween and cannot accumulate. That is what makes "select what is already selected" free.
#
# The resting scale/pivot/z are recorded ONCE, on the way in, and are the widget's own record; the
# way out restores exactly those, then forgets them. Pivot and z go back at the END of the shrink,
# not the start: swapping the pivot while still scaled up would swing the widget from growing about
# its centre to growing about its top-left corner (a visible sideways jump), and dropping the z
# early would duck the shrinking widget under the neighbours it is still overlapping.
#
# `scale_override` is for widgets with no highlight attached to read it from; otherwise the value
# authored on the `highlight` entry is used.
static func set_grown(widget: Control, on: bool, scale_override: float = 0.0) -> void:
	if widget == null or not is_instance_valid(widget):
		return
	var rec: Dictionary = widget.get_meta(GROWN_META, {})
	if bool(rec.get("on", false)) == on:
		return                      # already in this state — nothing to do, by construction
	var grow: float = scale_override if scale_override > 0.0 \
			else float(widget.get_meta(GROW_META, Vfx.param_of("highlight", "scale", 1.15)))
	if on:
		rec = {"on": true, "scale": widget.scale, "pivot": widget.pivot_offset,
				"z": widget.z_index}
		widget.set_meta(GROWN_META, rec)
		widget.pivot_offset = widget.size * 0.5   # grow evenly from the centre
		widget.z_index = int(rec["z"]) + Z_LIFT
		_transform_tween(widget).tween_property(widget, "scale",
				(rec["scale"] as Vector2) * grow, GROW_TIME) \
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		return
	rec["on"] = false
	widget.set_meta(GROWN_META, rec)
	var scale_rest: Vector2 = rec.get("scale", Vector2.ONE)
	var pivot_rest: Vector2 = rec.get("pivot", Vector2.ZERO)
	var z_rest: int = int(rec.get("z", 0))
	if not widget.is_inside_tree():
		widget.scale = scale_rest
		widget.pivot_offset = pivot_rest
		widget.z_index = z_rest
		widget.remove_meta(GROWN_META)
		return
	var tw := _transform_tween(widget)
	tw.tween_property(widget, "scale", scale_rest, SHRINK_TIME) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.finished.connect(func() -> void:
		# Only if the widget hasn't been grown again since — a re-grow owns the transform now, and
		# this stale finish must not drag it back down or erase its record.
		if not is_instance_valid(widget) \
				or bool((widget.get_meta(GROWN_META, {}) as Dictionary).get("on", false)):
			return
		widget.pivot_offset = pivot_rest
		widget.z_index = z_rest
		widget.remove_meta(GROWN_META))


# ONE transform tween per widget, ever: starting a new one kills whatever was still easing, so the
# two can never fight over `scale`. Parked on the widget, because the widget is what they act on.
static func _transform_tween(widget: Control) -> Tween:
	# `has_meta` first: get_meta with a NULL default is an error in Godot, not a miss.
	if widget.has_meta(TWEEN_META):
		var prev: Variant = widget.get_meta(TWEEN_META)
		if prev is Tween and (prev as Tween).is_valid():
			(prev as Tween).kill()
	var tw := widget.create_tween()
	widget.set_meta(TWEEN_META, tw)
	return tw
