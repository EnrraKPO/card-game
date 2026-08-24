class_name FightPresenter
extends PresentationOutlet

# The live world's presenter behind the presentation outlet (Mutation §10, §11) — the
# strike presentation's reference shape (docs/planning/RULINGS.html R13): everything
# arrives through the outlet's stream, the presenter builds one VFXEvent per cue and hands
# it to the salvaged VFXPlayer, and the flow beats pace the fight. Nothing reaches around
# the stream; the widgets are told, they never ask.
#
# The pause contract (MSD §10): procedure cues arriving while paused queue in arrival
# order; the conductor unpauses at the contact, and the held set plays as one burst — a
# multi-target payload reads as simultaneous, exactly as the old resolution walk did.

var _screen: FightScreen = null
var _paused: bool = false
var _held: Array[Array] = []


func _init(screen: FightScreen) -> void:
	_screen = screen


func cue(visual: StringName, recipient: GameEntity, magnitude: float) -> void:
	if _paused:
		_held.append([visual, recipient, magnitude])
	else:
		_screen.play_cue(visual, recipient, magnitude)


func pause() -> void:
	_paused = true


func unpause() -> void:
	_paused = false
	for held: Array in _held:
		_screen.play_cue(held[0], held[1], held[2])
	_held.clear()


# The windup beat: every recipient wears the tinted target reticle that leads its hit —
# the old cause→effect read's second layer. The FIRST layer (the source's glint, the
# lunge, the bolt flight) cannot play yet: the outlet's beats carry the effect's name and
# its recipients but NOT the acting holder (MSD §11's stated shape) — the one contract
# gap, surfaced in the journal for ruling. The beat's hold gives the marks their lead.
func windup(visual: StringName, recipients: Array[GameEntity]) -> void:
	_screen.refresh()
	for recipient: GameEntity in recipients:
		_screen.play_beat_mark(recipient)
	await _screen.beat(visual, recipients, 0.35)


# The contact: the held procedure cues burst here (unpause follows this beat in the
# conductor's order), and the board re-reads its numbers.
func contact(visual: StringName, recipients: Array[GameEntity]) -> void:
	await _screen.beat(visual, recipients, 0.2)
	_screen.refresh()


func conclude(_visual: StringName) -> void:
	await _screen.beat(&"", [], 0.1)
	_screen.refresh()
