class_name AttentionBadge
extends Control

# THE "look at this" cue — one component for every marker the game pins to a widget to say a
# thing is worth the player's attention: the map Forge's "!", the Lab button's "NEW", and the
# unspent-something counts still to come.
#
# It exists because the game had grown two of these independently (map.gd's "!" and
# game_world.gd's "NEW" pill, the latter borrowing the Forge's own glow entry by name), and they
# disagreed on all three of the things such a cue actually is:
#
#   THE MARK       what it shows — a glyph ("bang"), a labelled pill, a count. Art is swappable
#                  per kind through the same drop-a-PNG hook for every mark, not per call site.
#   THE PLACEMENT  where it pins, as a fraction of the HOST's box. Values outside 0..1 are legal
#                  and meaningful: that's how "just off the right shoulder" and "above it" are
#                  the same mechanism as "inside the top-right corner", instead of three.
#   THE LIFECYCLE  the split that matters most, and the one the two versions got wrong in
#                  different ways:
#                    * a STATUS mark is on while a condition holds and never dismisses itself;
#                    * an ATTENTION mark asks ONCE and goes quiet when answered (hover or press).
#                  A cue that never stops shouting stops being a cue.
#
# What this does NOT own: WHETHER the cue should show, and remembering that it was answered.
# That's game data (RunData.forge_alert_ack, ProfileData.lab_visited) — the badge emits
# `acknowledged` and the caller persists whatever that means for it.
#
#   var b := AttentionBadge.pin(fab, {"kind": "bang", "at": "right", "size": 0.5})
#   b.arm_ack()                                   # attention mark: hover/press answers it
#   b.acknowledged.connect(_remember_it_was_seen)
#   b.shown = has_unspent_mineral                 # the glow rides this, by construction
#
# The glow is not optional bookkeeping the caller has to remember: it attaches and detaches WITH
# the mark. Every hand-rolled version got this wrong the same way — a dismissed badge leaving a
# glowing hole in the air — because the light and the thing it lights were two separate calls.

signal acknowledged

# Mark art, by kind. Each entry ships a placeholder SVG and names the PNG that silently wins if
# dropped beside it — swapping in final art is a file drop, for every mark, with no code change.
const ART := {
	"bang": {"svg": preload("res://assets/ui/alert_bang.svg"), "png": "res://assets/ui/alert_bang.png"},
}

# Named placements, as fractions of the host's box (the badge's CENTRE lands here). The "inside"
# presets are pulled well off the true corner because art usually carries transparent padding —
# a corner-anchored mark floats off the visible shape. The "outside" ones clear the edge by a
# hair, so the mark reads as pinned to the host rather than as a second object near it.
const PLACEMENTS := {
	"top_right":    Vector2(0.80, 0.20),
	"top_left":     Vector2(0.20, 0.20),
	"bottom_right": Vector2(0.80, 0.80),
	"right":        Vector2(1.02, 0.42),
	"left":         Vector2(-0.02, 0.42),
	"above":        Vector2(0.50, -0.04),
	"below":        Vector2(0.50, 1.04),
}

# The mark's own dense light, and the optional breathing glow on the HOST it marks. Both are
# library entries, so their look is data — see data/vfx/vfx.json.
#
# Two entries for one look, picked by kind rather than by the caller: an outer glow derives its
# silhouette either from a source TEXTURE or from the widget's SHAPE, and a glyph mark has the
# former while a pill has only the latter. Handing a Label the texture-sourced entry doesn't look
# worse — it does nothing at all, with a warning nobody reads. (That is precisely how the Lab
# button's hand-rolled "NEW" pill shipped a glow that never drew.) So the component knows, and no
# call site has to.
const DEFAULT_GLOW := "attention_badge_glow"        # glyph marks: read the art's own alpha
const TEXT_GLOW := "attention_badge_glow_rrect"     # text marks: read the pill's rounded rect
const HOST_GLOW := "ui_attention_glow"              # any host: shape-sourced, works on anything

# Text marks size their font from the mark's nominal height; a glyph mark fills it as a square.
const TEXT_FONT_RATIO := 0.42

var host: Control
var kind := "bang"
var at := PLACEMENTS["top_right"]
## Nominal mark height, as a fraction of the host's SHORTER side — so one number places the same
## cue correctly on a 96px button and a 252px map button.
var size_frac := 0.38
## Legibility (and tap-target) floor: a fraction of a small host must not shrink to a speck.
var min_px := 26.0
var glow_id := DEFAULT_GLOW
var host_glow_id := ""

var _mark: Control
var _armed := false

# The one switch: showing/hiding the mark takes its light with it.
var shown := true:
	set(v):
		if shown == v:
			return
		shown = v
		visible = v
		if is_inside_tree():
			_apply_cues()


# Pins a badge to `host` and returns it. `cfg` keys: kind ("bang" | "pill" | "count"), text /
# value (the text kinds' content), at (a PLACEMENTS key or a Vector2 fraction), size, min_px,
# color (text kinds' pill colour), glow ("" = none), host_glow (true = breathe the host too),
# shown (starts hidden with false).
static func pin(p_host: Control, cfg: Dictionary = {}) -> AttentionBadge:
	var b := AttentionBadge.new()
	b.host = p_host
	b.kind = str(cfg.get("kind", "bang"))
	var where: Variant = cfg.get("at", "top_right")
	b.at = where if where is Vector2 else PLACEMENTS.get(str(where), PLACEMENTS["top_right"])
	b.size_frac = float(cfg.get("size", 0.38))
	b.min_px = float(cfg.get("min_px", 26.0))
	var kind_glow: String = TEXT_GLOW if b.kind in ["pill", "count"] else DEFAULT_GLOW
	b.glow_id = str(cfg.get("glow", kind_glow))
	b.host_glow_id = HOST_GLOW if bool(cfg.get("host_glow", false)) else ""
	b.mouse_filter = Control.MOUSE_FILTER_IGNORE   # never steals a click from what it marks
	b._build_mark(cfg)
	# Added last so the mark draws OVER the host's own content. A mark placed outside the host's
	# box relies on the host not clipping its children (Controls don't, unless clip_contents is
	# set) — a clipping host wants an "inside" placement instead.
	p_host.add_child(b)
	b.shown = bool(cfg.get("shown", true))
	b.visible = b.shown
	return b


func _ready() -> void:
	if host != null and is_instance_valid(host):
		host.resized.connect(_sync)
	_sync()
	_apply_cues()


# Re-asserts the cues whenever the badge (re)enters the tree. A sustained Vfx state detaches when
# its target leaves the tree — which is right for destruction and WRONG for a reparent, and a
# reparent is routine here: Shell mounts a screen by moving the built branch into the tree, so a
# badge pinned during its screen's construction is torn down and re-entered before anyone sees
# it. Symptom is a mark that comes back without its light, silently and permanently. Attach is
# idempotent per (id, target), so re-asserting costs nothing when nothing was lost.
func _enter_tree() -> void:
	if is_node_ready():
		call_deferred("_apply_cues")


# Answers the cue on hover or press of `on` (the host by default) — the gesture that proves the
# player looked at the thing, not a separate dismiss button. Opt-in: a status mark never calls it.
#
# `on` exists because WHERE a mark sits and WHAT the player touches are not always the same
# widget: the map's Forge button is a plain Control holding the art (the right thing to place a
# badge against) with a transparent Button laid over it (the only thing that ever sees a hover,
# since it covers the host and consumes the event). Armed on the host there, the cue would simply
# never be answerable.
func arm_ack(on: Control = null) -> void:
	var src: Control = on if on != null else host
	if _armed or src == null or not is_instance_valid(src):
		return
	_armed = true
	# Touch never acknowledges by hover: emulate_mouse_from_touch parks a ghost cursor wherever
	# the last tap landed, and that phantom would silently retire a cue nobody ever saw. Touch
	# answers by tapping. See [[tooltip-touch-gate]] for the same gate on tooltips.
	src.mouse_entered.connect(func() -> void:
		if not UIScale.is_touch():
			acknowledge())
	if src is BaseButton:
		(src as BaseButton).pressed.connect(acknowledge)
	else:
		src.gui_input.connect(func(e: InputEvent) -> void:
			if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
				acknowledge())


# Answered: the mark goes quiet and the caller is told, so it can persist what "seen" means for
# it. A no-op when the mark isn't showing, so a second hover can't re-fire it.
func acknowledge() -> void:
	if not shown:
		return
	shown = false
	acknowledged.emit()


func _build_mark(cfg: Dictionary) -> void:
	match kind:
		"pill", "count":
			var lbl := Label.new()
			lbl.text = str(cfg.get("value", "")) if kind == "count" else str(cfg.get("text", ""))
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			lbl.add_theme_color_override("font_color", Color(0.12, 0.1, 0.02))
			var style := StyleBoxFlat.new()
			style.bg_color = cfg.get("color", Color("f6b91e")) as Color
			style.set_corner_radius_all(10)
			style.set_content_margin_all(6)
			style.content_margin_left = 14
			style.content_margin_right = 14
			lbl.add_theme_stylebox_override("normal", style)
			_mark = lbl
		_:
			var tex := TextureRect.new()
			tex.texture = _art_for(kind)
			tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			_mark = tex
	_mark.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_mark)


# A kind's art: the dropped-in PNG if it exists, else the shipped placeholder.
func _art_for(k: String) -> Texture2D:
	var entry: Dictionary = ART.get(k, ART["bang"])
	var png_path := str(entry.get("png", ""))
	if not png_path.is_empty() and ResourceLoader.exists(png_path):
		var png: Resource = load(png_path)
		if png is Texture2D:
			return png
	return entry.get("svg") as Texture2D


# Places the badge: its CENTRE at `at` of the host's box, sized from the host's shorter side, so
# one config survives every diameter/layout/zoom the host is ever laid out at. Re-run on every
# host resize.
func _sync() -> void:
	if host == null or not is_instance_valid(host):
		return
	var side: float = maxf(min_px, size_frac * minf(host.size.x, host.size.y))
	var box := Vector2(side, side)
	if _mark is Label:
		# A text mark is as wide as its text: the nominal height drives the FONT, and the box
		# then comes from what the label actually needs (a square would crop or pad it).
		(_mark as Label).add_theme_font_size_override("font_size", int(side * TEXT_FONT_RATIO))
		box = (_mark as Label).get_combined_minimum_size()
	anchor_left = at.x; anchor_right = at.x
	anchor_top = at.y;  anchor_bottom = at.y
	offset_left = -box.x * 0.5; offset_right = box.x * 0.5
	offset_top = -box.y * 0.5;  offset_bottom = box.y * 0.5


# The light rides the mark's visibility — the whole reason this is a component (see the header).
func _apply_cues() -> void:
	if not is_inside_tree():
		return
	if not glow_id.is_empty():
		if shown:
			Vfx.attach(glow_id, self)
		else:
			Vfx.detach(glow_id, self)
	if not host_glow_id.is_empty() and host != null and is_instance_valid(host):
		if shown:
			Vfx.attach(host_glow_id, host)
		else:
			Vfx.detach(host_glow_id, host)
