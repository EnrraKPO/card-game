extends Node

# THE sound-effect channel — every SFX anywhere in the app plays through this autoload, the audio
# counterpart of ScreenUI's "one builder per look" rule: a given game moment always sounds the
# same, and no scene owns audio nodes of its own. One named method per game moment (not a generic
# play-by-path API) so call sites read as intent ("Sfx.combined()") and the asset behind a moment
# can change in exactly one place.
#
# One-shots go through a small round-robin player pool so overlapping cues (e.g. two units struck
# in quick succession) don't cut each other off. The Forge's mixing drone is the one looped sound
# and owns a dedicated player with start/stop — see mixing_start.

const _BUTTON := preload("res://assets/sound/button_press_thocky.mp3")
const _COMBINED := preload("res://assets/sound/combined.mp3")
const _ATTACK_DAMAGE := preload("res://assets/sound/attack_damage.mp3")
const _SHIELD_BLOCK := preload("res://assets/sound/melee_shield_block.mp3")
const _MIXING := preload("res://assets/sound/mixing.mp3")

const _POOL_SIZE := 6

# The mixing drone's "reacting" rev-up: pitch_scale both raises the tone and speeds playback, so
# the buzz audibly accelerates while two cards are connected. Ramped over _MIXING_RAMP rather than
# switched — hover flickers across card edges, and a hard pitch jump on each flicker reads as a
# glitch instead of a rev.
const _MIXING_REACT_PITCH := 1.4
const _MIXING_RAMP := 0.25

var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _mixing_player: AudioStreamPlayer
var _mixing_tween: Tween


func _ready() -> void:
	for i in _POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)
	_mixing_player = AudioStreamPlayer.new()
	# Loop the drone at the stream level (AudioStreamMP3.loop) rather than restarting it from
	# `finished` — a signal-driven restart has an audible seam on every pass.
	var loop_stream := _MIXING.duplicate() as AudioStreamMP3
	loop_stream.loop = true
	_mixing_player.stream = loop_stream
	add_child(_mixing_player)


# Any button press, app-wide — called by GlossyButton itself (see its _on_down), never by screens.
func button() -> void:
	_play(_BUTTON)


# Celebrates a successful merge of things into a new thing: the Forge screen's card combine, and
# the Lab's forge/craft operations. Softened — at full volume the celebration overpowered the
# moment instead of accenting it.
func combined() -> void:
	_play(_COMBINED, -25.0)


# An attack's damage landing on a unit's health. Softened: attacks fire constantly during the
# auto-battle, so at full volume the barrage dominated combat.
func attack_damage() -> void:
	_play(_ATTACK_DAMAGE, -25.0)


# An attack (fully or partly) caught by a unit's shield.
func shield_block() -> void:
	_play(_SHIELD_BLOCK)


# The Forge's swirling-particles drone while a card/charm is being dragged. Looped — runs until
# mixing_stop(). Idempotent: re-calling while already playing keeps the current loop rather than
# audibly restarting it.
func mixing_start() -> void:
	if not _mixing_player.playing:
		_mixing_player.play()


# Revs the mixing drone up (two cards are reacting — a valid combine target is hovered) or back
# down (hover left). Only meaningful while the loop runs; safe to call anytime.
func mixing_react(on: bool) -> void:
	if _mixing_tween != null:
		_mixing_tween.kill()
	_mixing_tween = create_tween()
	_mixing_tween.tween_property(_mixing_player, "pitch_scale",
		_MIXING_REACT_PITCH if on else 1.0, _MIXING_RAMP)


func mixing_stop() -> void:
	if _mixing_tween != null:
		_mixing_tween.kill()
		_mixing_tween = null
	_mixing_player.stop()
	_mixing_player.pitch_scale = 1.0   # next drag starts calm, not mid-rev


# `db`: per-moment loudness trim relative to the asset's own level (0 = as authored, negative =
# gentler) — the balancing knob when one asset is mastered hotter than the rest.
func _play(stream: AudioStream, db: float = 0.0) -> void:
	var p := _pool[_next]
	_next = (_next + 1) % _POOL_SIZE
	p.stream = stream
	p.volume_db = db
	p.play()
