@tool
extends Button
class_name GlossyButton
# Nine-patch "Bold & Punchy" button (see D:\Godot\ArtDirection\Card game UI system\
# design_handoff_glossy_buttons — Option A). All the button's actual geometry (shoulder, socket,
# riser, candy split, sheen, rim line, corner glint) is baked once into a grayscale texture; a tiny
# recolor shader (button_recolor.gdshader) tints it by `base_color` at runtime. Godot's native
# NinePatchRect stretch keeps the baked corners/riser crisp at any button size — only the flat
# middle bands stretch.
#
# Bucket system (replaces the old single-aspect-ratio 3-tier version): the app's real buttons range
# from near-square (✕/icon) to very wide pills (action/footer buttons, 3:1-9:1) to a tall vertical
# strip (combat's Ready button, ~1:4) — one bake stretched across all of those looked flat/washed-out
# whenever the real shape strayed far from the bake's own aspect ratio (see the button-polish pass
# this replaced). So there are now dedicated bakes for: a square icon shape, a portrait "Ready" shape,
# and 6 landscape heights (48/64/84/96/120/140px) picked by nearest match to the button's own height —
# each landscape texture already has margins fitted to its own aspect ratio, not scaled from a
# single source. Textures are `assets/ui/button_shademap_<bucket>.png`, pre-cropped to their visible
# silhouette (no transparent padding) so NinePatchRect maps them 1:1 onto the button's own layout box.
#
# NOTE: the "84" bucket's source art was corrupted on handoff (broken PNG) — it currently reuses the
# "96" texture/margins as a placeholder (see _LANDSCAPE_BUCKETS below). Swap in the real
# button_shademap_84.png (and its measured margins) once it's re-delivered.

const CHUNKY_FONT := preload("res://assets/fontd/Baloo_2/static/Baloo2-ExtraBold.ttf")

const _TEX_ICON := preload("res://assets/ui/button_shademap_icon.png")
const _TEX_READY := preload("res://assets/ui/button_shademap_ready.png")
const _TEX_48 := preload("res://assets/ui/button_shademap_48.png")
const _TEX_64 := preload("res://assets/ui/button_shademap_64.png")
const _TEX_96 := preload("res://assets/ui/button_shademap_96.png")
const _TEX_120 := preload("res://assets/ui/button_shademap_120.png")
const _TEX_140 := preload("res://assets/ui/button_shademap_140.png")

# A button whose w:h ratio falls in this band is treated as "icon" shape regardless of absolute size.
# Narrow on purpose — this must only catch truly square buttons (close ✕: 56x52=1.08, 88x88=1.0).
# A wider band previously caught the hub's ~1.34-ratio card tiles too, which then rendered by
# uniformly scaling the tiny 64x66 icon texture up 6x instead of properly nine-patching a landscape
# texture — a completely different, oversized corner curve next to normally-nine-patched buttons.
const _ICON_RATIO_MIN := 0.85
const _ICON_RATIO_MAX := 1.15
# A button narrower than this w:h ratio is treated as the portrait "Ready" shape.
const _PORTRAIT_RATIO_MAX := 0.5

# Landscape (wide pill) buckets, picked by nearest match to the button's own height — see class
# comment for how these were measured (cropped-to-silhouette canvas, margins fitted per bucket).
const _LANDSCAPE_BUCKETS := [
	{"key": "48",  "height": 47.0,  "texture": _TEX_48,  "margin_left": 16, "margin_right": 16, "margin_top": 18, "margin_bottom": 20},
	{"key": "64",  "height": 62.0,  "texture": _TEX_64,  "margin_left": 19, "margin_right": 19, "margin_top": 20, "margin_bottom": 22},
	# TODO: "84"'s own bake was corrupted on handoff (broken PNG) — reusing "96"'s texture/margins as
	# a placeholder. Swap in the real button_shademap_84.png + its measured margins once re-delivered.
	{"key": "84",  "height": 84.0,  "texture": _TEX_96,  "margin_left": 32, "margin_right": 32, "margin_top": 30, "margin_bottom": 32},
	{"key": "96",  "height": 93.0,  "texture": _TEX_96,  "margin_left": 32, "margin_right": 32, "margin_top": 30, "margin_bottom": 32},
	{"key": "120", "height": 116.0, "texture": _TEX_120, "margin_left": 37, "margin_right": 37, "margin_top": 39, "margin_bottom": 46},
	{"key": "140", "height": 136.0, "texture": _TEX_140, "margin_left": 40, "margin_right": 40, "margin_top": 29, "margin_bottom": 55},
]

@export var base_color: Color = Color("f6871d"):
	set(v): base_color = v; _apply()
@export var ink: Color = Color("1c2136")   # unused — see class comment; kept for call-site compat

var _skin: NinePatchRect
var _bucket_key: String = ""
var _was_disabled := false   # see _process — Button has no signal for `disabled` changing
var _was_toggled := false    # see _process — persistent toggle_mode state (e.g. active tabs)


func _ready() -> void:
	_build()
	if not resized.is_connected(_on_resized):
		resized.connect(_on_resized)
	if not button_down.is_connected(_on_down):
		button_down.connect(_on_down)
		button_up.connect(_on_up)
	_apply()
	call_deferred("_apply")   # size is not final until after layout
	_was_disabled = disabled
	_apply_disabled()
	_was_toggled = button_pressed
	_apply_toggle()


func _process(_delta: float) -> void:
	if disabled != _was_disabled:
		_was_disabled = disabled
		_apply_disabled()
	if toggle_mode and button_pressed != _was_toggled:
		_was_toggled = button_pressed
		_apply_toggle()


func _apply_disabled() -> void:
	modulate = Color(1, 1, 1, 0.5) if disabled else Color.WHITE


# No baked pressed texture exists, so "pushed in" is faked: darken + nudge down a couple px.
# button_down/button_up below drive the same look for an ordinary momentary click.
func _apply_toggle() -> void:
	_set_pressed_look(button_pressed)


func _set_pressed_look(is_pressed: bool) -> void:
	if _skin == null:
		return
	_skin.modulate = Color(0.82, 0.82, 0.82) if is_pressed else Color.WHITE
	_skin.position.y = 3.0 if is_pressed else 0.0


func _build() -> void:
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		add_theme_stylebox_override(s, StyleBoxEmpty.new())
	add_theme_font_override("font", CHUNKY_FONT)
	if _skin == null:
		_skin = NinePatchRect.new()
		_skin.name = "Skin"
		_skin.show_behind_parent = true
		_skin.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_skin.set_anchors_preset(Control.PRESET_FULL_RECT)
		_skin.axis_stretch_horizontal = NinePatchRect.AXIS_STRETCH_MODE_STRETCH
		_skin.axis_stretch_vertical = NinePatchRect.AXIS_STRETCH_MODE_STRETCH
		var mat := ShaderMaterial.new()
		mat.shader = load("res://assets/ui/shaders/button_recolor.gdshader")
		_skin.material = mat
		add_child(_skin)
		move_child(_skin, 0)


# Picks which baked shape best matches this button's actual on-screen proportions — see class
# comment for the three shape families (icon/ready/landscape).
func _pick_bucket(w: float, h: float) -> Dictionary:
	if h <= 0.0:
		return _LANDSCAPE_BUCKETS[0]
	var ratio := w / h
	if ratio >= _ICON_RATIO_MIN and ratio <= _ICON_RATIO_MAX:
		# A circular icon has no real flat band to stretch (unlike a wide pill) — any nine-patch
		# middle at all distorts the circle into a lens/diamond. Using half the 64x66 source's own
		# size as the margin on every side (zero middle) makes NinePatchRect scale the whole image
		# uniformly instead of slicing it, which is what a near-circular shape actually needs.
		return {"key": "icon", "texture": _TEX_ICON, "margin_left": 32, "margin_right": 32,
			"margin_top": 33, "margin_bottom": 33}
	if ratio <= _PORTRAIT_RATIO_MAX:
		return {"key": "ready", "texture": _TEX_READY, "margin_left": 34, "margin_right": 34,
			"margin_top": 33, "margin_bottom": 33}
	var best: Dictionary = _LANDSCAPE_BUCKETS[0]
	var best_diff := INF
	for bucket in _LANDSCAPE_BUCKETS:
		var diff: float = absf(h - bucket.height)
		if diff < best_diff:
			best_diff = diff
			best = bucket
	return best


func _apply() -> void:
	if _skin == null:
		return
	if size.x > 1.0 and size.y > 1.0:
		var bucket := _pick_bucket(size.x, size.y)
		var key: String = bucket.key
		if key != _bucket_key:
			_bucket_key = key
			_skin.texture = bucket.texture
			_skin.patch_margin_left = bucket.margin_left
			_skin.patch_margin_right = bucket.margin_right
			_skin.patch_margin_top = bucket.margin_top
			_skin.patch_margin_bottom = bucket.margin_bottom
	var mat: ShaderMaterial = _skin.material
	mat.set_shader_parameter("base_color", base_color)
	var o := base_color.darkened(0.55)
	add_theme_color_override("font_color", Color.WHITE)
	add_theme_color_override("font_outline_color", o)
	add_theme_constant_override("outline_size", 8)
	add_theme_color_override("font_shadow_color", o)
	add_theme_constant_override("shadow_offset_x", 0)
	add_theme_constant_override("shadow_offset_y", 3)


func _on_resized() -> void:
	_apply()


func _on_down() -> void:
	_set_pressed_look(true)


func _on_up() -> void:
	_set_pressed_look(toggle_mode and button_pressed)
