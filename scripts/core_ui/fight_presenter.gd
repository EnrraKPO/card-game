class_name FightPresenter
extends PresentationOutlet

# The live world's presenter behind the presentation outlet (Mutation §10, §11). This
# first iteration presents functionally: every flow beat refreshes the screen and holds
# the flow a moment so the fight reads as a sequence of happenings; procedure cues
# queue while paused and land as floating notes at the contact, in arrival order. The
# full visual language (VFX/SFX choreography) re-enters at the parity pass (A10 —
# partial functionality through iteration).

var _screen: FightScreen = null
var _paused: bool = false
var _held: Array[Array] = []


func _init(screen: FightScreen) -> void:
	_screen = screen


func cue(visual: StringName, recipient: GameEntity, magnitude: float) -> void:
	if _paused:
		_held.append([visual, recipient, magnitude])
	else:
		_screen.show_cue(visual, recipient, magnitude)


func pause() -> void:
	_paused = true


func unpause() -> void:
	_paused = false
	for held: Array in _held:
		_screen.show_cue(held[0], held[1], held[2])
	_held.clear()


func windup(visual: StringName, recipients: Array[GameEntity]) -> void:
	_screen.refresh()
	await _screen.beat(visual, recipients, 0.25)


func contact(visual: StringName, recipients: Array[GameEntity]) -> void:
	await _screen.beat(visual, recipients, 0.2)
	_screen.refresh()


func conclude(_visual: StringName) -> void:
	await _screen.beat(&"", [], 0.1)
	_screen.refresh()
