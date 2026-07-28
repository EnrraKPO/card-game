class_name ForgeFuseAnim
extends Control

# The merge "fusion" sequence, played over the table when a combine is confirmed:
#   1. the two source cards fly straight together and collapse INTO each other (full size, fading to
#      half alpha so they blend) — the whole ForgeMergeFX reaction (swirl + link + wobble) rides along
#      the entire way in, so the pair never stops reacting as it merges. The deck has ALREADY
#      committed by now (the screen commits at fly start) but the TABLE holds still — the pair's
#      two empty slots stay open for the whole sequence,
#   2. a particle splash at the collision (the `flashed` signal fires at the impact beat — purely
#      sensory now: the screen plays the SFX + element burst there, nothing transactional),
#   3. the forged result grows and fades in out of the collision, holds a beat,
#   4. the result flies HOME while the table reorganizes BENEATH it, in one simultaneous
#      movement: `returning` fires first (the screen starts its reflow there), then `dest` is
#      queried for the result's FINAL slot — where it will sit after the reflow — and the flight
#      aims straight at it. One landing, at the place the card will actually live,
#   5. `finished` fires at touchdown so the screen can swap the clone for the real grid card
#      (they overlap exactly). The framed path's result toast is already up by then — the screen
#      raises it on the `returning` beat, and the finale plays out beneath it.
# Self-contained: give it the two source instances + the result, their on-screen centres, the
# convergence point (all global) and the landing-rect provider, and it builds/animates/frees its
# own card clones and overlays.
# NOTE: there is deliberately NO screen whiteout — the impact reads from the splash alone.

signal flashed    # impact beat — sensory only (SFX + element burst); the merge is already committed
signal returning  # return-flight start — reorganize the table NOW, before `dest` is queried
signal finished   # the result LANDED on its final grid slot — unhide the real card, show the toast

const T_FLY := 0.34         # source cards flying together
const T_IMPACT := 0.09      # beat between the cards landing on each other and the burst
const T_REVEAL := 0.34      # the result growing/fading in out of the collision
const HOLD := 0.28          # beat on the revealed result before it flies home
# The return flight deliberately has NO duration of its own: it runs on FitGrid.ANIM_T with the
# glide's exact curve (sine ease-in-out — gentle, no lunge), because the table's reflow launches
# on the same frame (see `returning`) — same length + same curve + same start = the finale reads
# as ONE motion, and both stop together.
const REVEAL_FROM_SCALE := 0.32   # the forged result grows in from this scale

var _card_size := Vector2(150, 196)
var _color := Color.WHITE
var _dest := Callable()          # -> Rect2 (global): the landing slot, read at return-flight start
var _merge_fx: ForgeMergeFX = null   # the swirl/link/wobble riding the pair as it converges


func play(a_inst: CardInstance, b_inst: CardInstance, result_inst: CardInstance,
		a_gc: Vector2, b_gc: Vector2, center_gc: Vector2, card_size: Vector2,
		color_a: Color, color_b: Color, link_color: Color, dest: Callable) -> void:
	_card_size = card_size
	_color = color_a
	_dest = dest
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
	if _merge_fx != null:            # the reaction collapses into the impact along with the cards
		_merge_fx.queue_free()
		_merge_fx = null
	card_a.queue_free()
	card_b.queue_free()

	# The result starts invisible at the collision point and grows/fades in out of it (added before
	# the splash = drawn below the sparks).
	var result := _make_card(result_inst, c_local)
	result.scale = Vector2(REVEAL_FROM_SCALE, REVEAL_FROM_SCALE)
	result.modulate.a = 0.0

	# The splash bursts NOW — on contact, the frame the two collapse into one — while the SFX/
	# element-burst beat (`flashed`) keeps its slight T_IMPACT lag: the eye gets the debris at
	# the instant of touch, the ear a breath later.
	# It's a LIBRARY cue (`forge_contact_splash`, tunable in the Tool): played on a card-sized
	# marker at the collision point, tinted with the moment's element colour. The marker only
	# gives the cue its rect and dies with this anim.
	var marker := Control.new()
	marker.mouse_filter = MOUSE_FILTER_IGNORE
	marker.size = _card_size
	marker.position = c_local - _card_size * 0.5
	add_child(marker)
	Vfx.play("forge_contact_splash", marker, {"color": _color})

	var tw := create_tween()
	tw.tween_interval(T_IMPACT)
	tw.tween_callback(func() -> void: flashed.emit())
	tw.tween_property(result, "scale", Vector2.ONE, T_REVEAL).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(result, "modulate:a", 1.0, T_REVEAL * 0.6).set_trans(Tween.TRANS_SINE)
	tw.chain().tween_interval(HOLD)
	tw.tween_callback(_fly_home.bind(result))


# The return flight: the revealed result travels (and resizes) onto its FINAL grid slot, while
# the table reorganizes beneath it. `returning` launches the reflow synchronously; `_dest` then
# answers with the destination rect of the reorganized layout (a fixed point — the reflow's
# targets don't move once computed). Position and size tween together (scale is 1 by now, so the
# pivot doesn't distort anything); at touchdown the clone exactly covers the real grid card.
func _fly_home(result: Control) -> void:
	returning.emit()
	var rect_gc: Rect2 = _dest.call() if _dest.is_valid() else Rect2()
	if rect_gc.size == Vector2.ZERO:   # no destination (entry vanished?) — land where it stands
		finished.emit()
		return
	var inv := get_global_transform().affine_inverse()
	var tl: Vector2 = inv * rect_gc.position

	var tw := create_tween()
	tw.set_parallel(true)
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(result, "position", tl, FitGrid.ANIM_T)
	tw.tween_property(result, "size", rect_gc.size, FitGrid.ANIM_T)
	tw.chain().tween_callback(func() -> void: finished.emit())


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
