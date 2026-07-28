extends Node
# Throwaway: drives a real ConsumableChip with SYNTHETIC TOUCH (no mouse motion ever) to prove the
# hold actually fills and commits on a touch device — the bug was is_hovered() reading false for a
# finger that never moves, cancelling the hold on its first frame.
# godot --path . res://dev/_consumable_touch_probe.tscn

const CHIP := 76.0


func _ready() -> void:
	var chip := ConsumableChip.new()
	chip.relic = RelicData.get_relic("bomb")
	chip.check = func() -> bool: return true
	chip.position = Vector2(200, 200)
	chip.size = Vector2(CHIP, CHIP)
	add_child(chip)

	var committed := [false]
	chip.commit_requested.connect(func() -> void: committed[0] = true)

	await get_tree().process_frame
	await get_tree().process_frame

	var at := chip.get_global_rect().get_center()
	var down := InputEventScreenTouch.new()
	down.index = 0
	down.pressed = true
	down.position = at
	Input.parse_input_event(down)

	await get_tree().process_frame
	await get_tree().process_frame
	print("after press: pressed=%s holding=%s progress=%.2f hovered=%s scale=%.2f" % [
		chip.button_pressed, chip.is_holding(), chip._progress, chip.is_hovered(), chip.scale.x])

	await get_tree().create_timer(0.35).timeout
	print("mid hold: holding=%s progress=%.2f scale=%.2f" % [
		chip.is_holding(), chip._progress, chip.scale.x])

	await get_tree().create_timer(GameData.value_f("ux.consume_hold.duration") + 0.3).timeout
	print("after full hold: committed=%s scale=%.2f" % [committed[0], chip.scale.x])

	# And the back-out: a touch that slides off before the fill completes must cancel.
	committed[0] = false
	Input.parse_input_event(down)
	await get_tree().create_timer(0.25).timeout
	var drag := InputEventScreenDrag.new()
	drag.index = 0
	drag.position = at + Vector2(400, 0)
	Input.parse_input_event(drag)
	await get_tree().process_frame
	await get_tree().process_frame
	print("after slide-off: holding=%s progress=%.2f committed=%s" % [
		chip.is_holding(), chip._progress, committed[0]])

	var up := InputEventScreenTouch.new()
	up.index = 0
	up.pressed = false
	up.position = at + Vector2(400, 0)
	Input.parse_input_event(up)
	await get_tree().process_frame
	get_tree().quit()
