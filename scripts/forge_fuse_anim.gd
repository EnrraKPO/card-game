class_name ForgeFuseAnim
extends Control

# The merge "fusion" sequence, played over the confirm modal when a combine is confirmed:
#   1. the two source cards fly straight together and collapse INTO each other (full size, fading to
#      half alpha so they blend) — the whole ForgeMergeFX reaction (swirl + link + wobble) rides along
#      the entire way in, so the pair never stops reacting as it merges,
#   2. a white flash + particle splash at the collision (the `flashed` signal fires at the peak —
#      the screen commits the merge + plays the SFX there, hidden behind the white),
#   3. the whiteout fades back to reveal the forged result growing in,
#   4. `finished` fires so the screen can raise its result toast.
# Self-contained: give it the two source instances + the result, their on-screen centres and the
# convergence point (all global), and it builds/animates/frees its own card clones and overlays.

signal flashed    # white-flash peak — commit the merge + play SFX here (it's hidden by the flash)
signal finished   # result fully revealed — safe to show the result toast

const T_FLY := 0.34         # source cards flying together
const T_FLASH_IN := 0.09    # ramp up to full white
const T_REVEAL := 0.34      # white fading back while the result grows in
const HOLD := 0.28          # beat on the revealed result before handing off to the toast
const REVEAL_FROM_SCALE := 0.32   # the forged result grows in from this scale as the white clears

var _card_size := Vector2(150, 196)
var _color := Color.WHITE
var _merge_fx: ForgeMergeFX = null   # the swirl/link/wobble riding the pair as it converges


func play(a_inst: CardInstance, b_inst: CardInstance, result_inst: CardInstance,
		a_gc: Vector2, b_gc: Vector2, center_gc: Vector2, card_size: Vector2,
		color_a: Color, color_b: Color, link_color: Color) -> void:
	_card_size = card_size
	_color = color_a
	mouse_filter = MOUSE_FILTER_IGNORE

	var inv := get_global_transform().affine_inverse()
	var a_local: Vector2 = inv * a_gc
	var b_local: Vector2 = inv * b_gc
	var c_local: Vector2 = inv * center_gc

	var card_a := _make_card(a_inst, a_local)
	var card_b := _make_card(b_inst, b_local)

	# The same reaction the confirm modal showed, now carried onto the moving clones: swirl, motes
	# flowing between them, and the tilt wobble — all following the cards as they close in. own_position
	# is false so the fly tween below owns their position and the two don't fight.
	_merge_fx = ForgeMergeFX.new()
	add_child(_merge_fx)
	_merge_fx.bind(card_a, card_b, color_a, color_b, link_color, false)

	var half := card_size * 0.5

	# Fly both source cards straight onto the same spot at full size (no shrink) and fade each to half
	# alpha, so they're pulled INTO each other — the overlap reads as the two merging.
	# EASE_OUT: they're "let go" and snap toward each other with immediate energy, settling as they
	# meet — reads as an attraction/release, not a slow walk-in (EASE_IN felt sluggish).
	var tw := create_tween()
	tw.set_parallel(true)
	tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(card_a, "position", c_local - half, T_FLY)
	tw.tween_property(card_a, "modulate:a", 0.5, T_FLY)
	tw.tween_property(card_b, "position", c_local - half, T_FLY)
	tw.tween_property(card_b, "modulate:a", 0.5, T_FLY)
	tw.chain().tween_callback(_flash_and_reveal.bind(card_a, card_b, result_inst, c_local))


func _flash_and_reveal(card_a: Control, card_b: Control, result_inst: CardInstance, c_local: Vector2) -> void:
	if _merge_fx != null:            # the reaction collapses into the flash along with the cards
		_merge_fx.queue_free()
		_merge_fx = null
	card_a.queue_free()
	card_b.queue_free()

	# The result sits under the white, then is revealed as the flash fades (added first = drawn below).
	var result := _make_card(result_inst, c_local)
	result.scale = Vector2(REVEAL_FROM_SCALE, REVEAL_FROM_SCALE)

	var flash := ColorRect.new()
	flash.color = Color(1, 1, 1, 0.0)
	flash.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	flash.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(flash)

	var splash := ForgeSplash.new()
	splash.position = c_local
	add_child(splash)   # above the flash so the sparks read against the white and after

	var tw := create_tween()
	tw.tween_property(flash, "color:a", 0.95, T_FLASH_IN).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func() -> void:
		flashed.emit()
		splash.burst(46, _color, 130.0, 470.0, 1.0, 3.0, 0.6))
	tw.tween_property(flash, "color:a", 0.0, T_REVEAL).set_trans(Tween.TRANS_SINE)
	tw.parallel().tween_property(result, "scale", Vector2.ONE, T_REVEAL).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(HOLD)
	tw.tween_callback(func() -> void: finished.emit())


# A CardUI clone whose CENTRE sits at `center_local`, pivoted at its centre so scale/rotation swirl
# around the middle.
func _make_card(inst: CardInstance, center_local: Vector2) -> Control:
	var ui := CardUI.create(inst)
	ui.custom_minimum_size = _card_size
	ui.size = _card_size
	ui.pivot_offset = _card_size * 0.5
	ui.position = center_local - _card_size * 0.5
	ui.mouse_filter = MOUSE_FILTER_IGNORE
	add_child(ui)
	return ui
