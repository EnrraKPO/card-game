class_name TreasureChest
extends Control

# What an enemy King leaves behind. A king pays no coin bounty (GameData.kill_bounty) because a
# king's death is not a kill like the others — it is the fight ending — so instead of paying out
# where it stood, it BURSTS, and the chest is thrown clear of the explosion like the contents of
# a piñata: shot up out of the blast and dropped back onto the board a little way clear of it.
#
# The chest is the hand-off between combat and its rewards. Everything the win pays — gold,
# minerals, materials, experience, the card pick — used to appear because the screen changed
# under the player; now the player opens the thing that holds it and the screen changes because
# they did. Combat awaits `opened` before it navigates (see Combat._handle_combat_end), so the
# chest is a real gate and not a decoration played over one.
#
#   var chest := TreasureChest.pop_from(self, burst_centre, king_slot_rect)
#   await chest.opened      # fires once the reward ORB has reached the middle of the screen
#
# `opened` deliberately fires LATE — not when the lid comes up, but when the orb the chest
# releases has flown to the centre of the screen (see RewardOrbFx). That is the moment the next
# screen should grow out of, so the whole chain — burst, chest, lid, orb, screen — is one
# continuous motion with no cut in it.
#
# Art is a straight file drop (assets/ui/treasure_chest*.png); with neither file present the
# chest still flies, lands and opens as a plain gold box, because the SEQUENCE is the feature
# and the picture is the skin.

signal opened

const ART_CLOSED := "res://assets/ui/treasure_chest.png"
const ART_OPEN   := "res://assets/ui/treasure_chest_open.png"

const POP_DUR := 0.40       # the flight from the burst to wherever the blast throws it
const POP_RISE := 0.40      # when the arc is at its top — under 0.5, so the fall is the long half
const POP_APEX := 210.0     # px the chest is thrown above the higher of its two ends…
const POP_CEILING := 24.0   # …less whatever it takes to keep it this far inside the top edge
const POP_THROW := 0.75     # of a slot's width — how far CLEAR of the blast it comes to rest
const POP_LEAN := 9.0       # deg it leans into the throw; square to the board again by landing
const POP_MARGIN := 12.0    # px the landing spot stays inside the screen
const SIZE_FACTOR := 1.15   # of the slot's width — a chest slightly overflowing the square it
							 # lands in reads as an object ON the board, not a tile OF it

var _art: TextureRect
var _prompt: Label
var _open := false
var _rest := Vector2.ZERO   # where the chest comes to land (its own top-left)


# Throws a chest out of the burst at `from` (global) and lands it in `rect` (a slot's global
# rect) inside `host`. Returns it immediately; the arrival plays itself.
static func pop_from(host: Control, from: Vector2, rect: Rect2) -> TreasureChest:
	var chest := TreasureChest.new()
	chest.custom_minimum_size = Vector2.ONE * (rect.size.x * SIZE_FACTOR)
	host.add_child(chest)
	chest.size = chest.custom_minimum_size
	# Landing height is the slot's BOTTOM EDGE — the grid line — not the slot's middle. A thrown
	# object comes to rest ON a surface; centred in the square it would read as floating, and
	# because the chest is wider than the slot it would break the row's line on both sides
	# instead of standing on it.
	chest._rest = Vector2(rect.get_center().x - chest.size.x * 0.5, rect.end.y - chest.size.y)
	chest.global_position = from - chest.size * 0.5
	chest._pop()
	return chest


func _ready() -> void:
	z_index = 60   # above the board's cards, below nothing that matters here
	mouse_filter = Control.MOUSE_FILTER_STOP
	_art = TextureRect.new()
	_art.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	_art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_art.texture = _tex(ART_CLOSED)
	add_child(_art)
	if _art.texture == null:
		_art.add_child(_fallback_box())

	# The invitation, under the chest — a chest nobody realises is a button is a dead end.
	_prompt = Label.new()
	_prompt.text = Loc.t("combat.chest_open")
	_prompt.add_theme_font_size_override("font_size", 26 if UIScale.is_compact() else 20)
	_prompt.add_theme_color_override("font_color", Color(1.0, 0.92, 0.62))
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_prompt.add_theme_constant_override("outline_size", 6)
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt.modulate.a = 0.0
	_prompt.set_anchors_preset(PRESET_BOTTOM_WIDE)
	_prompt.offset_top = 4.0
	_prompt.offset_bottom = 40.0
	add_child(_prompt)
	UIScale.tip(self, Loc.t("combat.chest_tip"))


func _gui_input(event: InputEvent) -> void:
	if _open:
		return
	var click := event is InputEventMouseButton and (event as InputEventMouseButton).pressed
	var tap := event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed
	if click or tap:
		accept_event()
		_open_it()


# The arrival: EXPELLED by the King's detonation — shot out of the blast, up and clear of it, and
# down onto the board under its own weight. It starts small at the blast point (it was "inside"
# the King), swells to full size as it clears the explosion, and lands square.
#
# What it deliberately does NOT do is tumble. An earlier build spun the chest a full turn on the
# way over and it read as a ball ROLLING through the air rather than an object thrown out of an
# explosion; all that survives of the spin is a lean into the throw that unwinds before impact.
#
# Nor does it come home: a thing expelled lands where it was thrown, so the resting spot is the
# King's slot pushed clear of the blast (away from the nearest screen edge, kept on-screen). The
# empty slot is where the chest came FROM, not where it belongs.
func _pop() -> void:
	var from := global_position
	pivot_offset = size * 0.5
	scale = Vector2(0.15, 0.15)
	rotation_degrees = 0.0

	# Thrown away from the screen edge it is nearest, so a King at the board's rim still pitches
	# its chest into open space instead of off-screen.
	var vw := get_viewport_rect().size.x
	var dir := -1.0 if from.x > vw * 0.5 else 1.0
	var land := _rest
	land.x = clampf(land.x + dir * size.x * POP_THROW, POP_MARGIN, vw - size.x - POP_MARGIN)
	_rest = land   # what _impact snaps to, and what the invitation stands on

	# The apex is capped by the room actually available ABOVE the flight: a King on the board's
	# top row is only ~60px from the edge, and the authored throw would have launched the chest
	# clean off the screen and back — the player would see it vanish, not fly.
	var top := minf(from.y, land.y)
	var apex_y := maxf(top - POP_APEX, POP_CEILING)
	var lean := POP_LEAN * dir

	# One diagonal shove and then only gravity: horizontal speed is CONSTANT for the whole flight
	# and the height is a single quadratic, which is what a constant downward pull actually is.
	# The chest therefore leaves the blast on a slant, coasts over the apex and FALLS onto the
	# grid line — a jump, rather than the eased glide-into-place a per-axis ease would give.
	# The quadratic is a Lagrange fit through (0, from.y), (POP_RISE, apex_y), (1, land.y) —
	# pulling the apex sample before the midpoint leans the arc into a quick rise and a long fall.
	var w0 := 1.0 / (POP_RISE)               # weights, hoisted out of the per-frame lambda
	var w1 := 1.0 / (POP_RISE * (POP_RISE - 1.0))
	var w2 := 1.0 / (1.0 - POP_RISE)

	var tw := create_tween()
	tw.tween_method(func(t: float) -> void:
			var p := Vector2.ZERO
			p.x = lerpf(from.x, land.x, t)
			p.y = from.y * (t - POP_RISE) * (t - 1.0) * w0 \
					+ apex_y * t * (t - 1.0) * w1 \
					+ land.y * t * (t - POP_RISE) * w2
			position = p
			rotation_degrees = lean * sin(t * PI),   # leans into the throw, square again by the end
		0.0, 1.0, POP_DUR).set_trans(Tween.TRANS_LINEAR)
	# Swelling out of the blast happens over the first quarter — after that it is a solid object
	# in flight, not an effect still resolving.
	tw.parallel().tween_property(self, "scale", Vector2.ONE, POP_DUR * 0.26) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# Impact: flatten, rebound, settle.
	tw.tween_property(self, "scale", Vector2(1.24, 0.76), 0.05).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_callback(_impact)
	tw.tween_property(self, "scale", Vector2(0.95, 1.07), 0.07)
	tw.tween_property(self, "scale", Vector2.ONE, 0.10).set_trans(Tween.TRANS_BACK)
	# Only once it has landed does it start asking to be opened.
	tw.tween_callback(_invite)


func _impact() -> void:
	position = _rest        # the parabola's own end, made exact before anything reads it
	rotation_degrees = 0.0
	Sfx.play("combat_place_building")   # the heaviest "something solid landed" in the library
	Vfx.play("chest_landing", self)


# The standing "open me": a breathing glow on the chest itself plus the prompt fading in. Both
# are library states, so how loud the invitation is stays a data question.
func _invite() -> void:
	if _open:
		return
	Vfx.attach("chest_waiting", self)
	var tw := create_tween()
	tw.tween_property(_prompt, "modulate:a", 1.0, 0.22)


# Opening is the first half of a handoff, not an end in itself: the lid comes up, the light
# inside gathers into an orb, and the orb carries the reward to the middle of the screen. Only
# when it arrives is `opened` emitted — the next screen grows from exactly there.
func _open_it() -> void:
	_open = true
	Vfx.detach("chest_waiting", self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tw := create_tween()
	tw.tween_property(_prompt, "modulate:a", 0.0, 0.10)
	tw.parallel().tween_property(self, "scale", Vector2(1.12, 0.92), 0.07)   # the lid's kick
	tw.tween_callback(func() -> void:
		var open_tex := _tex(ART_OPEN)
		if open_tex != null:
			_art.texture = open_tex
		Vfx.play("chest_open", self))
	tw.tween_property(self, "scale", Vector2.ONE, 0.13).set_trans(Tween.TRANS_BACK)
	tw.tween_callback(_release_orb)


func _release_orb() -> void:
	# The orb is drawn on the VFX overlay, not inside combat, so it outlives this screen and can
	# still be hanging in the middle of the air while the next one grows out of it.
	Vfx.play("reward_orb", self, {"on_arrive": func() -> void: opened.emit()})


func _tex(path: String) -> Texture2D:
	return load(path) if ResourceLoader.exists(path) else null


# Art-less stand-in: a banded gold box. Enough to fly, land, glow and open with.
func _fallback_box() -> Control:
	var p := Panel.new()
	p.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.55, 0.36, 0.14)
	sb.border_color = Color(1.0, 0.82, 0.30)
	sb.set_border_width_all(6)
	sb.set_corner_radius_all(10)
	p.add_theme_stylebox_override("panel", sb)
	return p
