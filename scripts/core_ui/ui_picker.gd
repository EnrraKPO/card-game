class_name UiPicker
extends TargetPicker

# The live world's picker (Core §4): consults the player through the fight screen — the
# eligible candidates light up, the player clicks one or cancels, and a declined pick
# yields the empty election. The screen owns the presentation of the ask; this seam owns
# nothing but the question.

var _screen: FightScreen = null


func _init(screen: FightScreen) -> void:
	_screen = screen


func pick(candidates: Array[GameEntity], _plate: Plate) -> GameEntity:
	return await _screen.pick_one(candidates)
