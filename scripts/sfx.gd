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
# Managed-bed fade endpoints: -60dB is perceptual silence (a fade landing there then stopping
# is inaudible); stops cap their fade shorter than seam blends so leaving a screen feels
# responsive even on events authored with long crossfades.
const _SILENT_DB := -60.0
const _STOP_FADE := 0.8
# A bed arriving over SILENCE is click-guarded, not eased in (a swell from nothing reads as
# awkward dead air). A bed REPLACING another crossfades: both sides share _BED_XFADE, running
# simultaneously, so one song blends into the next with no energy dip — never a sharp A → B.
# (Fades tween LINEAR amplitude, not dB: two opposing linear ramps sum to constant loudness.)
const _START_FADE := 0.15
const _BED_XFADE := 1.5

# A looped event's playback channel. UNMANAGED (placeholder hums, WAVs, the mixing drone):
# one player, stream-level looping, exactly the old behavior. MANAGED (real mp3/ogg beds):
# a PAIR of players and manual looping — `trim` seconds are cut off both asset ends, and near
# the trimmed end the idle player starts at the trimmed head while the active one fades out,
# so the seam is a `fade`-second blend instead of a hard cut. Starts fade in, stops fade out.
class LoopChannel:
	var players: Array[AudioStreamPlayer] = []
	var active := 0          # index into players of the currently-leading player
	var managed := false
	var path := ""           # resource path of the current draw — the resume-position key
	var length := 0.0
	var trim := 0.0
	var fade := 0.0
	var volume_db := 0.0
	var swapping := false    # a seam blend is in flight — don't retrigger until it lands
	var stopping := false    # fading toward a stop — still audible, but no longer "on"

	func lead() -> AudioStreamPlayer:
		return players[active]

var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _loop_channels: Dictionary = {}      # event id -> LoopChannel
var _loop_tweens: Dictionary = {}        # event id -> Tween (pitch ramps on looped events)
# Where each TRACK (by resource path) last stopped — a revisited screen that draws a track it
# has played before resumes it there instead of replaying the intro. Session-scoped on purpose.
var _resume: Dictionary = {}
var _placeholder_cache: Dictionary = {}  # event id -> AudioStreamWAV
# The two cross-screen BED channels — one music track and one ambience loop at a time; a
# screen states which bed it wants and the previous one stops. "" = silence the channel.
var _music_id := ""
var _ambience_id := ""


func _ready() -> void:
	for i in _POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"   # AudioSettings' bus — it autoloads before Sfx and creates both buses
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
	# Track-to-track = a real crossfade (matched windows, concurrent). To/from silence keeps
	# the short edges: instant-on entrance, quick fade-out exit.
	var crossfading := not current.is_empty() and not id.is_empty()
	if not current.is_empty():
		loop_stop(current, _BED_XFADE if crossfading else _STOP_FADE)
	set(field, id)
	if not id.is_empty():
		loop_start(id, _BED_XFADE if crossfading else _START_FADE)


# Starts a looped event (drone/ambience/music). Idempotent: re-calling while already playing
# keeps the current loop rather than audibly restarting it. `entrance_fade` is how long a
# managed bed takes to reach full level — _set_bed passes the crossfade window when another
# bed is handing off; the default is the bare click guard (unmanaged loops ignore it).
func loop_start(id: String, entrance_fade: float = _START_FADE) -> void:
	var sd := SoundData.get_sound(id)
	if sd == null:
		push_warning("Sfx.loop_start: unknown sound event \"%s\"" % id)
		return
	# A loop with no real asset is a placeholder hum — same F7 gate as one-shot placeholders.
	if not sd.has_asset() and not DevFlags.placeholder_sfx:
		return
	var ch: LoopChannel = _loop_channels.get(id, null)
	if ch == null:
		ch = LoopChannel.new()
		for i in 2:
			var p := AudioStreamPlayer.new()
			add_child(p)
			ch.players.append(p)
		_loop_channels[id] = ch
	if ch.lead().playing and not ch.stopping:
		return
	if ch.stopping:
		# Re-entered while the outgoing fade is still audible (quick screen bounce) — cut the
		# fade short and start fresh; the restart's own fade-in keeps it soft.
		for p in ch.players:
			var f: Tween = p.get_meta("fade_tween") if p.has_meta("fade_tween") else null
			if f != null and f.is_valid():
				f.kill()
			p.stop()
		ch.stopping = false
	# Mixer routing, re-decided each start: the two atmospheric BED channels (music + ambience)
	# sit on the Music bus; every other loop (drones like the forge mixer) is an effect.
	var bus_name := "Music" if (id == _music_id or id == _ambience_id) else "SFX"
	for p in ch.players:
		p.bus = bus_name
	# The stream is resolved on every fresh START (not once per channel): pool events
	# (SoundData.dir) draw a random member each time the bed presents.
	var stream := sd.stream()
	ch.swapping = false
	ch.volume_db = sd.volume_db
	if stream is AudioStreamMP3 or stream is AudioStreamOggVorbis:
		# A real music/ambience asset: managed crossfade looping. Trim/fade shrink to fit
		# short assets so the machinery never eats a track whole.
		ch.managed = true
		ch.path = stream.resource_path
		ch.length = stream.get_length()
		ch.fade = clampf(sd.fade, 0.05, ch.length / 4.0)
		ch.trim = clampf(sd.trim, 0.0, ch.length / 4.0)
		ch.lead().stream = stream
		ch.lead().volume_linear = 0.0
		# Resume where this track last left off (revisited screens skip the intro); a fresh
		# track starts at the trimmed head.
		var from: float = _resume.get(ch.path, ch.trim)
		if from >= ch.length - ch.trim - ch.fade:
			from = ch.trim   # saved position sits inside the outro — wrap to the head
		ch.lead().play(from)
		_fade_to(ch.lead(), ch.volume_db, entrance_fade)
	elif stream != null:
		# WAV assets loop sample-perfectly through loop_mode — no seam to blend.
		ch.managed = false
		var looped: AudioStream = stream.duplicate()
		(looped as AudioStreamWAV).loop_mode = AudioStreamWAV.LOOP_FORWARD
		ch.lead().stream = looped
		ch.lead().volume_db = ch.volume_db
		ch.lead().play()
	else:
		ch.managed = false
		ch.lead().stream = _placeholder(sd)
		ch.lead().volume_db = _PLACEHOLDER_LOOP_DB + sd.volume_db
		ch.lead().play()


# The seam watcher: when a managed bed's lead player nears its trimmed end, the idle player
# takes over from the trimmed head and the two blend across the fade window.
func _process(_delta: float) -> void:
	for id: String in _loop_channels:
		var ch: LoopChannel = _loop_channels[id]
		if not ch.managed or ch.swapping or ch.stopping or not ch.lead().playing:
			continue
		if ch.lead().get_playback_position() >= ch.length - ch.trim - ch.fade:
			_blend_seam(ch)


func _blend_seam(ch: LoopChannel) -> void:
	ch.swapping = true
	var outgoing := ch.lead()
	ch.active = (ch.active + 1) % 2
	var incoming := ch.lead()
	incoming.stream = outgoing.stream   # players share the stream; positions are per-player
	incoming.volume_linear = 0.0
	incoming.play(ch.trim)
	_fade_to(incoming, ch.volume_db, ch.fade)
	var tw := _fade_to(outgoing, _SILENT_DB, ch.fade)
	tw.tween_callback(func() -> void: outgoing.stop(); ch.swapping = false)


# `exit_fade`: how long a managed bed takes to leave — _set_bed passes the crossfade window
# when another bed is arriving over it; the default is the quick to-silence exit.
func loop_stop(id: String, exit_fade: float = _STOP_FADE) -> void:
	var ch: LoopChannel = _loop_channels.get(id, null)
	if ch == null:
		return
	var tw: Tween = _loop_tweens.get(id, null)
	if tw != null:
		tw.kill()
		_loop_tweens.erase(id)
	if ch.managed and ch.lead().playing:
		# Remember where this track stopped (resume-on-revisit), then fade out — a bed
		# leaving is an exit, not a power cut. Both players fade: a stop mid-blend has two.
		_resume[ch.path] = ch.lead().get_playback_position()
		for p in ch.players:
			if p.playing:
				var out := _fade_to(p, _SILENT_DB, exit_fade)
				out.tween_callback(p.stop)
		ch.swapping = false
		ch.stopping = true
	else:
		for p in ch.players:
			p.stop()
	for p in ch.players:
		p.pitch_scale = 1.0   # next start begins calm, not mid-rev


# Ramps a running loop's pitch (and thus playback speed) toward `pitch` — the generic form of
# the Forge drone's rev-up. Only meaningful while the loop runs; safe to call anytime.
func loop_pitch(id: String, pitch: float, ramp: float = _MIXING_RAMP) -> void:
	var ch: LoopChannel = _loop_channels.get(id, null)
	if ch == null:
		return
	var old: Tween = _loop_tweens.get(id, null)
	if old != null:
		old.kill()
	var tw := create_tween()
	tw.tween_property(ch.lead(), "pitch_scale", pitch, ramp)
	_loop_tweens[id] = tw


# Volume ramp on one player, replacing any ramp already running on it (the tween is tracked
# on the player itself via meta — fades are per-player, unlike the per-event pitch ramps).
# The ramp runs on LINEAR amplitude (a dB-space ramp spends most of its time near-silent,
# which makes crossfades dip in the middle); the target still arrives as the event's dB trim.
func _fade_to(p: AudioStreamPlayer, db: float, secs: float) -> Tween:
	var old: Tween = p.get_meta("fade_tween") if p.has_meta("fade_tween") else null
	if old != null and old.is_valid():
		old.kill()
	var tw := create_tween()
	tw.tween_property(p, "volume_linear", 0.0 if db <= _SILENT_DB else db_to_linear(db), secs)
	p.set_meta("fade_tween", tw)
	return tw


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
