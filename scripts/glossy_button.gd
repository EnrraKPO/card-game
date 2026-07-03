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
# Bucket system: the app's real buttons range from near-square (✕/icon) to very wide pills
# (action/footer buttons, 3:1-9:1) to a tall vertical strip (combat's Ready button, ~1:4) — one bake
# stretched across all of those looked flat/washed-out whenever the real shape strayed far from the
# bake's own aspect ratio. So there are dedicated bakes for: a square icon shape, a portrait "Ready"
# shape, and 6 landscape heights (48/64/84/96/120/140px) picked by nearest match to the button's own
# height — each with its own fitted margins, not scaled from a single source. Each bucket also has
# a genuine baked "pressed" texture (not a fake darken+shift) — see _set_pressed_look. Textures are
# `assets/ui/button_shademap_<bucket>.png` / `_pressed.png`, pre-cropped to their visible silhouette
# (no transparent padding) so NinePatchRect maps them 1:1 onto the button's own layout box.

const CHUNKY_FONT := preload("res://assets/fontd/Baloo_2/static/Baloo2-ExtraBold.ttf")

const _TEX_ICON := preload("res://assets/ui/button_shademap_icon.png")
const _TEX_ICON_PRESSED := preload("res://assets/ui/button_shademap_icon_pressed.png")
const _TEX_READY := preload("res://assets/ui/button_shademap_ready.png")
const _TEX_READY_PRESSED := preload("res://assets/ui/button_shademap_ready_pressed.png")
const _TEX_48 := preload("res://assets/ui/button_shademap_48.png")
const _TEX_48_PRESSED := preload("res://assets/ui/button_shademap_48_pressed.png")
const _TEX_64 := preload("res://assets/ui/button_shademap_64.png")
const _TEX_64_PRESSED := preload("res://assets/ui/button_shademap_64_pressed.png")
const _TEX_84 := preload("res://assets/ui/button_shademap_84.png")
const _TEX_84_PRESSED := preload("res://assets/ui/button_shademap_84_pressed.png")
const _TEX_96 := preload("res://assets/ui/button_shademap_96.png")
const _TEX_96_PRESSED := preload("res://assets/ui/button_shademap_96_pressed.png")
const _TEX_120 := preload("res://assets/ui/button_shademap_120.png")
const _TEX_120_PRESSED := preload("res://assets/ui/button_shademap_120_pressed.png")
const _TEX_140 := preload("res://assets/ui/button_shademap_140.png")
const _TEX_140_PRESSED := preload("res://assets/ui/button_shademap_140_pressed.png")

# A button whose w:h ratio falls in this band is treated as "icon" shape regardless of absolute size.
# Narrow on purpose — this must only catch truly square buttons (close ✕: 56x52=1.08, 88x88=1.0).
# A wider band previously caught the hub's ~1.34-ratio card tiles too, which then rendered by
# uniformly scaling the tiny icon texture up 6x instead of properly nine-patching a landscape
# texture — a completely different, oversized corner curve next to normally-nine-patched buttons.
const _ICON_RATIO_MIN := 0.85
const _ICON_RATIO_MAX := 1.15
# A button narrower than this w:h ratio is treated as the portrait "Ready" shape.
const _PORTRAIT_RATIO_MAX := 0.5

# Landscape (wide pill) buckets, picked by nearest match to the button's own height. Margins were
# measured directly off each cropped texture by finding where the border's own geometric position
# (not color — color keeps drifting across almost the whole width by design) stops changing, plus
# a safety buffer.
const _LANDSCAPE_BUCKETS := [
	{"key": "48",  "height": 47.0,  "texture": _TEX_48,  "texture_pressed": _TEX_48_PRESSED,
		"margin_left": 21, "margin_right": 21, "margin_top": 20, "margin_bottom": 21},
	{"key": "64",  "height": 62.0,  "texture": _TEX_64,  "texture_pressed": _TEX_64_PRESSED,
		"margin_left": 23, "margin_right": 23, "margin_top": 23, "margin_bottom": 25},
	{"key": "84",  "height": 81.0,  "texture": _TEX_84,  "texture_pressed": _TEX_84_PRESSED,
		"margin_left": 27, "margin_right": 27, "margin_top": 29, "margin_bottom": 33},
	{"key": "96",  "height": 93.0,  "texture": _TEX_96,  "texture_pressed": _TEX_96_PRESSED,
		"margin_left": 30, "margin_right": 30, "margin_top": 28, "margin_bottom": 32},
	{"key": "120", "height": 116.0, "texture": _TEX_120, "texture_pressed": _TEX_120_PRESSED,
		"margin_left": 36, "margin_right": 36, "margin_top": 38, "margin_bottom": 42},
	{"key": "140", "height": 136.0, "texture": _TEX_140, "texture_pressed": _TEX_140_PRESSED,
		"margin_left": 40, "margin_right": 40, "margin_top": 38, "margin_bottom": 42},
]

@export var base_color: Color = Color("f6871d"):
	set(v): base_color = v; _apply()
@export var ink: Color = Color("1c2136")   # unused — see class comment; kept for call-site compat

var _skin: NinePatchRect
var _bucket: Dictionary = {}
var _bucket_key: String = ""
var _is_pressed_look := false
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


func _apply_toggle() -> void:
	_set_pressed_look(button_pressed)


# Swaps in the bucket's own baked "pressed" texture (darker, flatter, sunk-in) instead of faking
# it with a modulate darken + position nudge — every bucket now has a real pressed bake.
func _set_pressed_look(is_pressed: bool) -> void:
	if _skin == null or _bucket.is_empty():
		return
	_is_pressed_look = is_pressed
	_skin.texture = _bucket.texture_pressed if is_pressed else _bucket.texture


func _build() -> void:
	for s in ["normal", "hover", "pressed", "focus", "disabled"]:
		add_theme_stylebox_override(s, StyleBoxEmpty.new())
	add_theme_font_override("font", CHUNKY_FONT)
	# Nine-patch corner margins are fixed SOURCE pixels — Godot draws them at that same pixel
	# footprint in the destination regardless of how small the button is, so a button smaller than
	# roughly 2x its bucket's margin sum has corners that draw past its own rect (visible as the
	# button bleeding into whatever sits behind/below it, e.g. spilling out of a header bar). Clip
	# to our own rect so an undersized button is contained instead of bleeding — a structural
	# guarantee, not dependent on picking exactly-right sizes per bucket.
	clip_contents = true
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
		# A circular icon has no real flat band to stretch (unlike a wide pill) - any nine-patch
		# middle at all distorts the circle into a lens/diamond. Using half the 64x66 source's own
		# size as the margin on every side (zero middle) makes NinePatchRect scale the whole image
		# uniformly instead of slicing it, which is what a near-circular shape actually needs.
		# These margins are SOURCE PIXELS Godot draws 1:1 in the destination regardless of button
		# size, so they're only correct once the button is close to the source's own ~64px - for
		# anything smaller (e.g. the header's close X, ~45px) _apply() clamps them down at
		# render time (see _clamped_margins) so the corners can't paint past the button's own
		# rect; for anything at/above native size they're used as authored, which keeps the
		# crisp baked corner detail instead of blurrily stretching the whole texture.
		return {"key": "icon", "texture": _TEX_ICON, "texture_pressed": _TEX_ICON_PRESSED,
			"margin_left": 32, "margin_right": 32, "margin_top": 33, "margin_bottom": 33}
	if ratio <= _PORTRAIT_RATIO_MAX:
		return {"key": "ready", "texture": _TEX_READY, "texture_pressed": _TEX_READY_PRESSED,
			"margin_left": 30, "margin_right": 29, "margin_top": 44, "margin_bottom": 44}
	var best: Dictionary = _LANDSCAPE_BUCKETS[0]
	var best_diff := INF
	for bucket in _LANDSCAPE_BUCKETS:
		var diff: float = absf(h - bucket.height)
		if diff < best_diff:
			best_diff = diff
			best = bucket
	return best


# NinePatchRect corner margins are a fixed CROP of the source texture, not a proportion — shrinking
# a margin value doesn't shrink the crop toward the same visual detail, it samples a DIFFERENT,
# unrelated slice of the art (tried that; on this button it turned the circle into a jagged
# diamond). So margins are only ever used exactly as authored (crisp baked corners) or zeroed out
# entirely (the whole texture becomes one plain scalable image, no slicing at all — safe whenever
# we're scaling that whole image DOWN, i.e. the button is at/under the texture's own native pixel
# size on both axes). A button bigger than native size always gets full margins, since zero-margin
# would upscale the raw source and blur it — this is why the header's small close ✕ (spills past
# native size otherwise) and the larger square buttons elsewhere (already native-or-bigger, want
# crisp baked corners) need different treatment, not one shared shrink factor.
func _clamped_margins(bucket: Dictionary, sz: Vector2) -> Vector4:
	var tex: Texture2D = bucket.texture
	var fits_native := sz.x <= tex.get_width() and sz.y <= tex.get_height()
	if fits_native:
		return Vector4(0.0, 0.0, 0.0, 0.0)
	return Vector4(bucket.margin_left, bucket.margin_right, bucket.margin_top, bucket.margin_bottom)


func _apply() -> void:
	if _skin == null:
		return
	if size.x > 1.0 and size.y > 1.0:
		var bucket := _pick_bucket(size.x, size.y)
		var key: String = bucket.key
		if key != _bucket_key:
			_bucket_key = key
			_bucket = bucket
			_skin.texture = bucket.texture_pressed if _is_pressed_look else bucket.texture
		# Re-clamped every call (not just on bucket change) since the same bucket can be reused
		# by buttons of very different sizes — see _clamped_margins.
		var m := _clamped_margins(_bucket, size)
		_skin.patch_margin_left = m.x
		_skin.patch_margin_right = m.y
		_skin.patch_margin_top = m.z
		_skin.patch_margin_bottom = m.w
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
	# The app-wide button-press sound lives here, on the shared button class, so every button
	# sounds the same and no screen wires audio itself — the audio counterpart of "every button
	# goes through this one builder". Editor-guarded: this is a @tool script and the Sfx autoload
	# only exists in a running game.
	if not Engine.is_editor_hint():
		Sfx.button()


func _on_up() -> void:
	_set_pressed_look(toggle_mode and button_pressed)
