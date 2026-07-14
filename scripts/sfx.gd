extends Node

# THE sound-effect channel — every SFX anywhere in the app plays through this autoload, the audio
# counterpart of ScreenUI's "one builder per look" rule: a given game moment always sounds the
# same, and no scene owns audio nodes of its own.
#
# DATA-DRIVEN: every game moment is a SoundData event (data/sounds/*.json, managed in the Tool's
# Sounds tab) played by id — Sfx.play("card_draw"). An event without a real asset plays a short
# PROCEDURAL PLACEHOLDER blip (pitch derived from the id, character from the category), so every
# event in the library is hooked and audible today; producing the real asset later is purely a
# data/asset change, no code. The legacy named methods (button/combined/…) remain as thin
# wrappers over library ids so historical call sites read unchanged.
#
# One-shots go through a small round-robin player pool so overlapping cues (e.g. two units struck
# in quick succession) don't cut each other off. LOOPED events (drones, ambience, music) each own
# a dedicated player, keyed by event id — start with loop_start(id), stop with loop_stop(id).

const _POOL_SIZE := 6

# The mixing drone's "reacting" rev-up: pitch_scale both raises the tone and speeds playback, so
# the buzz audibly accelerates while two cards are connected. Ramped over _MIXING_RAMP rather than
# switched — hover flickers across card edges, and a hard pitch jump on each flicker reads as a
# glitch instead of a rev.
const _MIXING_REACT_PITCH := 1.4
const _MIXING_RAMP := 0.25

# Placeholder synth shape: a short decaying sine blip. Loudness is deliberately restrained —
# placeholders exist to prove the hookup, not to be mistaken for sound design.
const _PLACEHOLDER_DB := -10.0
const _PLACEHOLDER_RATE := 22050
# Placeholder loops get a longer, quieter hum so an ambience/music slot is audibly "on" without
# a 0.14s blip machine-gunning forever.
const _PLACEHOLDER_LOOP_SECS := 1.2
const _PLACEHOLDER_LOOP_DB := -22.0

var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _loop_players: Dictionary = {}       # event id -> AudioStreamPlayer (looped events only)
var _loop_tweens: Dictionary = {}        # event id -> Tween (pitch ramps on looped events)
var _placeholder_cache: Dictionary = {}  # event id -> AudioStreamWAV
# The two cross-screen BED channels — one music track and one ambience loop at a time; a
# screen states which bed it wants and the previous one stops. "" = silence the channel.
var _music_id := ""
var _ambience_id := ""


func _ready() -> void:
	for i in _POOL_SIZE:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_pool.append(p)


# ── The event API — play any library event by id ─────────────────────────────────

# One-shot playback of a sound event. Unknown ids are a loud mistake (a typo'd hookup should be
# heard about immediately in development), missing assets are not — they play the placeholder.
func play(id: String) -> void:
	var sd := SoundData.get_sound(id)
	if sd == null:
		push_warning("Sfx.play: unknown sound event \"%s\"" % id)
		return
	if sd.loop:
		loop_start(id)
		return
	var stream := sd.stream()
	if stream != null:
		_play(stream, sd.volume_db)
	elif DevFlags.placeholder_sfx:
		# No real asset = a PLACEHOLDER event. Clearly flagged as such (the synth blip is
		# unmistakable) and mutable at will — F7 / DevFlags.placeholder_sfx silences every
		# placeholder while leaving real assets playing.
		_play(_placeholder(sd), _PLACEHOLDER_DB + sd.volume_db)


# Declares the screen's music bed (music_* events). No-op when it's already playing, so
# navigation between screens sharing a track never restarts it.
func music(id: String) -> void:
	_set_bed(id, "_music_id")


# Declares the screen's ambience bed (amb_* events) — the music channel's quieter sibling.
func ambience(id: String) -> void:
	_set_bed(id, "_ambience_id")


func _set_bed(id: String, field: String) -> void:
	var current: String = get(field)
	if id == current:
		return
	if not current.is_empty():
		loop_stop(current)
	set(field, id)
	if not id.is_empty():
		loop_start(id)


# Starts a looped event (drone/ambience/music). Idempotent: re-calling while already playing
# keeps the current loop rather than audibly restarting it.
func loop_start(id: String) -> void:
	var sd := SoundData.get_sound(id)
	if sd == null:
		push_warning("Sfx.loop_start: unknown sound event \"%s\"" % id)
		return
	# A loop with no real asset is a placeholder hum — same F7 gate as one-shot placeholders.
	if not sd.has_asset() and not DevFlags.placeholder_sfx:
		return
	var p: AudioStreamPlayer = _loop_players.get(id, null)
	if p == null:
		p = AudioStreamPlayer.new()
		add_child(p)
		_loop_players[id] = p
		var stream := sd.stream()
		if stream != null:
			# Loop at the stream level rather than restarting from `finished` — a signal-driven
			# restart has an audible seam on every pass. MP3/OggVorbis expose a `loop` bool;
			# WAV loops through loop_mode instead — handle whichever this asset is.
			var looped: AudioStream = stream.duplicate()
			if looped is AudioStreamWAV:
				(looped as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
			else:
				looped.set("loop", true)
			p.stream = looped
			p.volume_db = sd.volume_db
		else:
			p.stream = _placeholder(sd)
			p.volume_db = _PLACEHOLDER_LOOP_DB + sd.volume_db
	if not p.playing:
		p.play()


func loop_stop(id: String) -> void:
	var p: AudioStreamPlayer = _loop_players.get(id, null)
	if p == null:
		return
	var tw: Tween = _loop_tweens.get(id, null)
	if tw != null:
		tw.kill()
		_loop_tweens.erase(id)
	p.stop()
	p.pitch_scale = 1.0   # next start begins calm, not mid-rev


# Ramps a running loop's pitch (and thus playback speed) toward `pitch` — the generic form of
# the Forge drone's rev-up. Only meaningful while the loop runs; safe to call anytime.
func loop_pitch(id: String, pitch: float, ramp: float = _MIXING_RAMP) -> void:
	var p: AudioStreamPlayer = _loop_players.get(id, null)
	if p == null:
		return
	var old: Tween = _loop_tweens.get(id, null)
	if old != null:
		old.kill()
	var tw := create_tween()
	tw.tween_property(p, "pitch_scale", pitch, ramp)
	_loop_tweens[id] = tw


# ── Legacy named moments (thin wrappers over library ids) ────────────────────────

# Any button press, app-wide — called by GlossyButton itself (see its _on_down), never by screens.
func button() -> void:
	play("ui_button_press")


# Celebrates a successful merge of things into a new thing: the Forge screen's card combine, and
# the Lab's forge/craft operations.
func combined() -> void:
	play("forge_combine_success")


# An attack's damage landing on a unit's health.
func attack_damage() -> void:
	play("attack_melee_hit")


# An attack (fully or partly) caught by a unit's shield.
func shield_block() -> void:
	play("shield_block")


# The Forge's swirling-particles drone while a card/charm is being dragged.
func mixing_start() -> void:
	loop_start("forge_mixing_loop")


# Revs the mixing drone up (two cards are reacting — a valid combine target is hovered) or back
# down (hover left).
func mixing_react(on: bool) -> void:
	loop_pitch("forge_mixing_loop", _MIXING_REACT_PITCH if on else 1.0)


func mixing_stop() -> void:
	loop_stop("forge_mixing_loop")


# ── Playback internals ───────────────────────────────────────────────────────────

# `db`: per-moment loudness trim relative to the asset's own level (0 = as authored, negative =
# gentler) — the balancing knob when one asset is mastered hotter than the rest.
func _play(stream: AudioStream, db: float = 0.0) -> void:
	var p := _pool[_next]
	_next = (_next + 1) % _POOL_SIZE
	p.stream = stream
	p.volume_db = db
	p.play()


# Synthesizes the event's placeholder: a short sine blip whose pitch is derived from the event id
# (so distinct events are audibly distinct) and whose length/shape comes from whether it loops.
# Cached per id — the synth runs once per event per session.
func _placeholder(sd: SoundData) -> AudioStreamWAV:
	var cached: AudioStreamWAV = _placeholder_cache.get(sd.id, null)
	if cached != null:
		return cached
	var freq := 240.0 + float(_id_hash(sd.id) % 720)
	var secs := _PLACEHOLDER_LOOP_SECS if sd.loop else 0.14
	var frames := int(_PLACEHOLDER_RATE * secs)
	var data := PackedByteArray()
	data.resize(frames * 2)   # 16-bit mono
	for i in frames:
		var t := float(i) / _PLACEHOLDER_RATE
		# One-shots decay away like a struck tine; loops hold a gentle steady hum with a slow
		# tremolo so a running loop placeholder is audibly alive but not abrasive.
		var env: float = 0.55 + 0.45 * sin(TAU * 2.0 * t) if sd.loop else exp(-18.0 * t)
		var v := sin(TAU * freq * t) * env
		# A quiet octave-up partial gives the blip a little identity beyond a raw sine.
		v += 0.25 * sin(TAU * freq * 2.0 * t) * env
		var sample := int(clampf(v, -1.0, 1.0) * 12000.0)
		data.encode_s16(i * 2, sample)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = _PLACEHOLDER_RATE
	wav.data = data
	if sd.loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = frames
	_placeholder_cache[sd.id] = wav
	return wav


# Deterministic tiny hash shared (by formula) with the Tool's in-browser preview, so the
# placeholder you audition in the Sounds tab is the pitch you hear in game.
static func _id_hash(id: String) -> int:
	var h := 0
	for i in id.length():
		h = (h * 31 + id.unicode_at(i)) % 99991
	return h
