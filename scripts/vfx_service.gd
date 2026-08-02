extends Node

# THE app-wide visual-effect channel — the visual counterpart of Sfx. Any VFX anywhere in the
# app is addressed BY LIBRARY ID (VFXData, data/vfx/*.json) and applied to ANY Control target:
#
#   Vfx.play("ui_badge_pop", badge)                       # one-shot on a target
#   await Vfx.play("projectile_fire", target, {"source": caster, "amount": 4})
#   Vfx.attach("ui_button_attention", button)             # sustained state (glow/aura)
#   Vfx.detach("ui_button_attention", button)
#
# Call sites never know how an effect renders. The entry's `renderer` decides — "procedural"
# (the tweened primitives below), or "custom" (a designed effect class registered at runtime
# via register_custom — combat's 12 looks live there). An asset-backed renderer later is a
# new arm in _dispatch/_attach_dispatch, entries switch over in data, call sites untouched.
#
# PLACEHOLDER GATING: entries flagged placeholder (no designed look yet) are muted wholesale
# when DevFlags.placeholder_vfx is off (F8) — so undesigned effects can be silenced at will
# while judging real content. Designed looks always play.
#
# Combat's board choreography (VFXPlayer: reticle-leads-hit ordering, simultaneous bursts,
# projectile damage deferral) intentionally stays where it is — that's sequencing, not looks.
# Its LOOKS, though, resolve through here: the combat_* entries carry renderer "custom" and
# VFXPlayer registers its designed effect classes on them at setup — one library, one dispatch.

# The procedural behavior vocabulary. Adding a primitive = a _fx_* method + a list entry here
# (the Tool validates entries against this same list — keep them in sync).
const BEHAVIORS := ["flash", "pulse", "pop", "shake", "ring", "sparkle", "glint", "glow",
		"float_label", "burst", "travel", "reticle", "dissolve", "radiance", "emit"]
# Behaviors that can run as a SUSTAINED state (attach/detach) as well as a one-shot.
const SUSTAINED_BEHAVIORS := ["glow", "pulse", "sparkle", "radiance", "emit"]

# All effect nodes draw on dedicated overlay layers above the UI, positioned in global canvas
# coordinates — effects never join a container's layout or clip inside a target's rect.
var _layer: CanvasLayer
# Overlay BANDS (the "coarse depth bands" design from the composited-glow work): an effect
# draws just above ITS OWN widget's canvas layer, never on one global top. A table card's glow
# sits under a modal's scrim; a widget INSIDE the modal's layer glows above it — including a
# glow on the modal panel itself. Key = the target's CanvasLayer index; _layer is the base band
# for widgets living in the plain screen canvas.
var _bands: Dictionary = {}
# Sustained states, keyed "<id>@<target instance id>" -> the state's root node.
var _attached: Dictionary = {}
# Custom renderers, entry id -> Callable(vd, target, opts). An entry with renderer "custom"
# plays through the callable registered for its id; the callable owns its own drawing (combat
# effects draw in the combat tree, not on this service's layer). Registered by the system that
# owns the look (VFXPlayer at combat setup); re-registering overwrites, which keeps this
# correct across scene reloads.
var _custom: Dictionary = {}


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 90
	add_child(_layer)
	# The canonical selection Highlight (grow + outline + glow, see HighlightFx) is a core UI
	# treatment owned by no single screen — registered here so it's live everywhere from boot.
	register_custom(HighlightFx.ENTRY, HighlightFx.state)
	# The canonical HOVER ring — the same treatment at a third volume, and the one every surface in
	# the game answers a pointer with (see HoverFx). App-wide like the Highlight it borrows from.
	register_custom(HoverFx.ENTRY, HighlightFx.state)
	# The turn-order family wears it at two more volumes: the number the marked unit carries, and
	# the entry pointed at / the entry acting. All HighlightFx — one shader, several tunings — so
	# they can never drift apart stylistically.
	var turn_ids := PackedStringArray(["turn_number_spotlight",
			"turn_entry_hover", "turn_entry_acting"])
	for id: String in turn_ids:
		register_custom(id, HighlightFx.state)
	# The screen-arrival cue any navigation can ask for by name (Nav.goto's second argument) —
	# app-wide like the Highlight, owned by no single screen.
	register_custom("screen_grow_in", ScreenGrowFx.play)
	_load_prefs()


# The overlay layer, for effects that must escape the UI tree's clipping. A RenderFilter whose
# spill would be cut off by a clip_contents ancestor draws here instead, tracking its target's
# global rect — see RenderFilters/`layer: "overlay"`.
func overlay_layer() -> CanvasLayer:
	return _layer


# The overlay band for effects on `target`: the layer just above the CanvasLayer the target
# lives on (created lazily per band), or the base band for plain-canvas widgets. Determined by
# construction — the target's own ancestry — never by hand-assigned depths, so an effect can't
# contradict what the screen shows: under a scrim when its widget is, above it when its widget
# rides the modal's layer.
func overlay_layer_for(target: Control) -> CanvasLayer:
	var n: Node = target
	while n != null and not (n is CanvasLayer):
		n = n.get_parent()
	if n == null or (n as CanvasLayer).layer <= _layer.layer:
		return _layer   # base canvas (or something already under the base band)
	var lidx: int = (n as CanvasLayer).layer
	var band: Variant = _bands.get(lidx)
	if band == null or not is_instance_valid(band):
		var made := CanvasLayer.new()
		made.layer = lidx + 1
		# Parent beside the base band (not under it): the render harness reparents these into
		# its capture viewport, and late-created bands must land wherever the base band lives.
		_layer.get_parent().add_child(made)
		_bands[lidx] = made
		band = made
	return band


# ── The event API — play any library effect by id, on any Control ─────────────────

# One-shot playback (fire-and-forget, or await for completion). `opts` carries the anchors the
# entry's behavior may need: "source" (Control — travel flies from it), "amount"/"text" (the
# float_label's content), "color" (a call-site tint overriding the entry's own).
func play(id: String, target: Control, opts: Dictionary = {}) -> void:
	var vd := VFXData.get_vfx(id)
	if vd == null:
		push_warning("Vfx.play: unknown vfx event \"%s\"" % id)
		return
	if vd.placeholder and not DevFlags.placeholder_vfx:
		return
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	# Companion SFX: the entry's paired sound fires atomically with the visual — the audio half
	# of the cue lives in the library entry, never duplicated at call sites. (Direct attach()
	# calls skip it; a sustained state's start only sounds when entered through play.)
	#
	# `params.sfx_delay` moves the sound off that instant for the effects whose LOOK does not begin
	# at frame zero — an arrival that deliberately holds before it moves (screen_grow_in) would
	# otherwise announce itself a beat before anything happened. The pairing still lives in the
	# entry; only its offset is authorable.
	if not vd.sfx.is_empty():
		var sfx_delay := paced(maxf(0.0, vd.num_param("sfx_delay", 0.0)), vd)
		if sfx_delay > 0.0:
			_play_sfx_after(vd.sfx, sfx_delay)   # deliberately not awaited — the visual runs now
		else:
			Sfx.play(vd.sfx)
	if vd.sustained:
		attach(id, target)
		return
	# A freshly added Control has a zero rect until its container lays it out — playing on a
	# just-spawned target (e.g. a drawn card) would draw a degenerate effect at its corner.
	# One frame of patience puts the effect where the target actually lands.
	if target.get_global_rect().size == Vector2.ZERO:
		await get_tree().process_frame
		if not is_instance_valid(target) or not target.is_inside_tree():
			return
	await _dispatch(vd, target, opts)


# Starts a sustained effect (glow/aura/breathing) on a target. Idempotent per (id, target):
# re-attaching keeps the running state. The state auto-detaches if the target leaves the tree.
func attach(id: String, target: Control) -> void:
	var vd := VFXData.get_vfx(id)
	if vd == null:
		push_warning("Vfx.attach: unknown vfx event \"%s\"" % id)
		return
	if vd.placeholder and not DevFlags.placeholder_vfx:
		return
	if target == null or not is_instance_valid(target) or not target.is_inside_tree():
		return
	var key := _attach_key(id, target)
	if _attached.has(key):
		return
	var node := _attach_dispatch(vd, target)
	if node == null:
		return
	_attached[key] = node
	target.tree_exiting.connect(func(): detach(id, target), CONNECT_ONE_SHOT)


func detach(id: String, target: Control) -> void:
	var key := _attach_key(id, target)
	if not _attached.has(key):
		return
	# Fetched as Variant, not typed Node: a stale entry can point at an object queue_free already
	# doomed (or already gone) elsewhere — e.g. RenderFilters' own cache handing back a layer that
	# was mid-deletion (see apply()'s is_queued_for_deletion guard). Converting straight to a typed
	# Node prints "invalid previously freed instance" for that case; is_instance_valid on the raw
	# Variant checks safely instead. The key is erased regardless so a dead entry never wedges this
	# state permanently un-attachable.
	var raw: Variant = _attached[key]
	_attached.erase(key)
	if is_instance_valid(raw):
		(raw as Node).queue_free()


# "My shape changed" — told to every sustained state riding `target`, for the ones that care (the
# silhouette-baked glows; see GlowFx.shape_changed). A widget whose CHILDREN come and go has no
# other way to say so: `resized` speaks only for its own rect. Cheap by design — the glows measure
# before they re-bake, so a notification that changes nothing costs a little rect math.
func shape_changed(target: Control) -> void:
	if target == null or not is_instance_valid(target):
		return
	var suffix := "@%d" % target.get_instance_id()
	for key: String in _attached.keys():
		if not key.ends_with(suffix):
			continue
		var raw: Variant = _attached[key]
		if is_instance_valid(raw) and (raw as Object).has_method("shape_changed"):
			(raw as Object).call("shape_changed")


# The LIVE sustained state riding (id, target), or null if there isn't one — the door for cues that
# have to arbitrate with each other rather than merely coexist. Two effects that both want the same
# visual channel need one of them to be able to find the other and say so; HoverFx borrowing the
# selection Highlight's outline is the case this exists for.
#
# Read-only by intent: the state belongs to Vfx's lifecycle, and a caller that frees what it finds
# here leaves a dangling key. Ask it to change what it draws, never to stop existing.
func state_of(id: String, target: Control) -> Node:
	if target == null or not is_instance_valid(target):
		return null
	var key := _attach_key(id, target)
	if not _attached.has(key):
		return null
	var raw: Variant = _attached[key]
	return (raw as Node) if is_instance_valid(raw) else null


func _attach_key(id: String, target: Control) -> String:
	return "%s@%d" % [id, target.get_instance_id()]


# Every sustained state attached to anything inside `root`, dropped at once.
#
# A screen parked as a modal's backdrop (Shell._park_departing) has to take its overlay effects
# with it. Those draw on the overlay LAYERS, which sit above every screen by construction — the
# whole point of them — so a glow, a slot cue or an attention badge belonging to the screen
# UNDERNEATH would otherwise be the one thing still floating on top of the modal. Raising the
# modal's z cannot reach them: a CanvasLayer outranks any z_index.
func detach_under(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	var doomed: Array[String] = []
	for key: String in _attached.keys():
		var parts := key.rsplit("@", true, 1)
		if parts.size() < 2 or not parts[1].is_valid_int():
			continue
		var target: Object = instance_from_id(int(parts[1]))
		var node := target as Node
		if node != null and is_instance_valid(node) and (node == root or root.is_ancestor_of(node)):
			doomed.append(key)
	for key: String in doomed:
		var raw: Variant = _attached[key]
		_attached.erase(key)
		if is_instance_valid(raw):
			(raw as Node).queue_free()


# Registers the playback callable for a renderer-"custom" entry: fn(vd: VFXData,
# target: Control, opts: Dictionary), awaited like any look. See _custom above.
func register_custom(id: String, fn: Callable) -> void:
	_custom[id] = fn


# ── Sequencing: span vs handoff ────────────────────────────────────────────────────
#
# THE fluidity rule for every sequenced cue in the game. A cue has two times, and they are not
# the same:
#
#   SPAN    — how long it plays.
#   HANDOFF — when the next beat may start.
#
# A reticle snapping onto a card has said its piece the moment it lands; the rest of its span is
# it getting out of the way. So `await Vfx.play(...)` returns at the HANDOFF and the look plays on
# in the background, letting the next cue's head run under this one's tail. Cues stay strictly
# ORDERED — this only decides how much of a cue's span counts as "its moment".
#
# One global dial (`vfx.overlap`, GameAttributes → the Tool's 🎛 Tuning tab) sets the fraction of
# every cue's tail the next beat overlaps, so tuning the game's whole combat rhythm is one number.
# An entry overrides it with its own `overlap` param when its look needs a different feel — and
# `"overlap": 0` declares the entry ATOMIC: it is awaited to its last frame, for the cases where
# finishing is load-bearing (a screen transition that must complete before navigation).
#
# Effects have the matching escape hatch in code: a VFXEffect leaving `span` at 0 is atomic and
# awaited outright (VFXEffectProjectile, VFXEffectDeath).

# Fallback spans for the procedural primitives — each behavior's own default animation length,
# mirroring the `_p_dur(vd, …)` fallback inside its _fx_* method. An entry's `duration` param
# overrides it, exactly as it overrides the primitive's own timing.
const BEHAVIOR_SPANS := {
	"flash": 0.28, "pulse": 0.45, "pop": 0.30, "shake": 0.28, "ring": 0.40,
	"sparkle": 0.50, "glint": 0.36, "glow": 0.45, "float_label": 0.80, "burst": 0.40,
	"travel": 0.26, "reticle": 0.40, "dissolve": 0.50, "radiance": 0.50, "emit": 1.60,
}


# ── Combat pacing: the player's own dial ───────────────────────────────────────────
# Overlap is a matter of TASTE as much as tuning. A player who wants to follow every beat can turn
# it down — at 0 the sequence is strictly one-at-a-time, each cue playing to its last frame before
# the next begins — and one who wants combat to flow can leave it up. Exposed in Settings ⚙.
#
# Two layers, mirroring AudioSettings over data/audio.json: the GameAttributes value is the SHIPPED
# default (designer-tuned, editable in the Tool's 🎛 Tuning tab), and the player's own choice
# persists to user:// and wins over it. Untouched (-1) = follow the shipped default, so re-tuning
# the game's baseline still reaches everyone who never opened the setting.
const _PREF_PATH := "user://vfx_settings.json"

# The player-facing presets, slowest first — the settings overlay renders one button per entry and
# `pacing_key` names the active one. Values, not labels: the copy lives in the locale tables.
const PACING := [
	{"key": "steps",   "overlap": 0.0},    # every beat plays out in full before the next begins
	{"key": "chill",   "overlap": 0.28},
	{"key": "flowing", "overlap": 0.5},
	{"key": "fast",    "overlap": 0.72},
	{"key": "snappy",  "overlap": 0.95},   # the dial's ceiling — beats barely clear their own heads
]

var _overlap_pref: float = -1.0

# WHICH CUES THE DIAL GOVERNS. Pacing is a COMBAT setting — how much the beats of a fight overlap
# and compress — because a fight is the one place the player reads a long sequence of cues against
# a clock they want to hurry or slow. Everything outside that clock is an AUTHORED MOMENT: a chest
# opening, a screen arriving, a forge merging, a coin flying to the purse. Those play at the length
# they were written whatever the fight is set to; a player who set combat to Snappy asked for a
# faster fight, not for the game's every flourish to be clipped.
#
# The entry's CATEGORY is the default declaration. It is a proxy, not a law: `coin_flight` is
# economy by subject but fires mid-fight as a kill is paid out, and the fight must not wait on it
# at any pacing — so `params.paced` (1/0) overrides the category either way, for a cue whose
# SUBJECT and whose CLOCK disagree. A caller with no library entry at all (a relic chip glinting
# in its tray) is paced: those are combat's own, or they would have an entry.
const PACED_CATEGORIES := ["combat", "status", "card", "resource"]


# One numeric param off an entry, without playing it. For the callers who must know what a cue is
# GOING to do before it runs — the Shell reading `modal` to decide whether to hold the departing
# screen's frame — so the declaration stays in the library entry rather than being duplicated as a
# flag at the call site.
func param_of(id: String, key: String, fallback: float) -> float:
	var vd := VFXData.get_vfx(id)
	return fallback if vd == null else vd.num_param(key, fallback)


# Whether the pacing dial applies to this entry at all — see PACED_CATEGORIES.
func paces(vd: VFXData) -> bool:
	if vd == null:
		return true
	var declared := vd.num_param("paced", -1.0)
	if declared >= 0.0:
		return declared > 0.0
	return vd.category in PACED_CATEGORIES


# The global overlap dial, live (re-read per cue, so changing it mid-fight takes effect at once).
func overlap() -> float:
	var v := _overlap_pref if _overlap_pref >= 0.0 else GameAttributes.default_value("vfx.overlap")
	return clampf(v, 0.0, 0.95)


func set_overlap(pct: float) -> void:
	_overlap_pref = clampf(pct, 0.0, 0.95)
	_save_prefs()


# The preset key whose overlap is closest to the live value — what the settings overlay highlights.
# Closest rather than exact so a Tool-tuned default (or an old saved value) still lights a button.
func pacing_key() -> String:
	var live := overlap()
	var best: String = str(PACING[0]["key"])
	var best_d := 999.0
	for p: Dictionary in PACING:
		var d := absf(float(p["overlap"]) - live)
		if d < best_d:
			best_d = d
			best = str(p["key"])
	return best


func _load_prefs() -> void:
	if not FileAccess.file_exists(_PREF_PATH):
		return
	var f := FileAccess.open(_PREF_PATH, FileAccess.READ)
	if f == null:
		return
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK or not (json.data is Dictionary):
		return   # a corrupt prefs file is not worth an error — fall back to the shipped default
	var raw: Variant = (json.data as Dictionary).get("overlap")
	if raw is float or raw is int:
		_overlap_pref = clampf(float(raw), 0.0, 0.95)


func _save_prefs() -> void:
	var f := FileAccess.open(_PREF_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"overlap": _overlap_pref}))


# When the next beat may start, for a cue of length `span`. `vd` may be null (callers pacing a cue
# that has no library entry — a relic chip glinting in its tray); it then rides the global dial.
# Returns `span` itself for an atomic cue, so callers can compare the two to detect that case.
func handoff(span: float, vd: VFXData = null) -> float:
	if span <= 0.0:
		return 0.0
	# A cue outside the combat clock hands off at its own end unless it says otherwise: nothing is
	# waiting on it in a sequence the player is pacing, so there is no tail to give up.
	var frac := overlap() if paces(vd) else 0.0
	if vd != null:
		frac = clampf(vd.num_param("overlap", frac), 0.0, 0.95)
	return span * (1.0 - frac)


func _span_of(vd: VFXData) -> float:
	var fallback: float = float(BEHAVIOR_SPANS.get(vd.behavior, 0.35))
	return maxf(0.0, vd.num_param("duration", fallback))


# The dial applied to a duration that CANNOT be handed off partway through — an ATOMIC cue whose
# ending is the beat everything after it waits for. A ranged bolt is the case: the damage genuinely
# cannot read before the shot lands, so nothing may overlap its flight.
#
# Such a cue used to escape pacing entirely, which made it the one beat in combat that didn't answer
# to the player's setting. At Snappy every other beat collapsed toward its head while the bolt flew
# for exactly as long as at Step by step — so the harder pacing was turned up, the more ranged stood
# out as the only slow thing left on the board.
#
# Overlap and compression are the same taste expressed two ways: a cue that can share its tail gives
# up that tail, and a cue that can't gives up length instead. So the dial COMPRESSES what it cannot
# overlap, down to PACED_FLOOR of the authored duration at the ceiling — never to nothing, because
# an atomic cue that plays too fast to read defeats the point of gating on it.
const PACED_FLOOR := 0.45   # the most a fully-snappy dial may compress an atomic duration

# The companion sound of an effect that starts late (see play's sfx_delay). Fire-and-forget: it
# outlives the caller's frame and is never awaited, so a delayed sound never holds up a visual.
func _play_sfx_after(id: String, delay: float) -> void:
	await get_tree().create_timer(delay).timeout
	Sfx.play(id)


# `vd` is the entry the duration belongs to: outside the combat clock (see PACED_CATEGORIES) the
# authored number IS the answer and comes back untouched. Omitting it means "combat's own" — the
# callers with no library entry behind them.
func paced(seconds: float, vd: VFXData = null) -> float:
	if seconds <= 0.0:
		return 0.0
	if not paces(vd):
		return seconds
	return seconds * lerpf(1.0, PACED_FLOOR, overlap() / 0.95)


# ── Transient displacement: one mover per widget ───────────────────────────────────
# Motion that DISPLACES a widget in place — an impact shake, a wound tremble, a dodge sidestep, a
# crit stagger — as opposed to the overlay effects above, which draw beside it. Every such animation
# ends by handing the widget back exactly where its layout put it, and that is only safe if ONE of
# them runs at a time:
#
#   * Two tweens writing the same `position` fight for it every frame — the visible symptom is
#     jagged, stuttering motion rather than either animation.
#   * Worse, the second one captures a MID-MOTION position as its "rest" and restores to that, so
#     the widget is left permanently offset and each further cue compounds the drift.
#
# Serialized cues made collisions rare; overlapping ones make them routine, so exclusivity has to be
# enforced rather than hoped for. begin() cancels whatever was running, snaps the widget back to the
# TRUE rest it recorded on first claim, and hands that rest to the new mover; hold() then registers
# the new tween so the next claimant can cancel it in turn.
const _MOVER := "vfx_mover"        # the running displacement Tween
const _REST  := "vfx_mover_rest"   # the full transform as of the first uncontested claim


# Claims `target` for a displacement, returning the position it must be handed back to.
#
# The snapshot covers PIVOT as well as pos/rot/scale, because a cancelled mover cannot clean up
# after itself: a cue that rocks a card about its base (the crit stagger) sets pivot_offset and
# restores it in a chained callback on its own tween — the very tween the next claimant kills. That
# leaves the card pivoting about its bottom edge forever, so every later scale/rotate on it (the
# selection grow, the canonical Highlight) is silently wrong, and it compounds across a fight.
# Restoring the whole transform here means cancellation is complete BY CONSTRUCTION, and no mover
# has to be written defensively against being interrupted.
func begin_displace(target: Control) -> Vector2:
	var rest := {"pos": target.position, "rot": target.rotation_degrees,
			"scale": target.scale, "pivot": target.pivot_offset}
	var prev: Variant = target.get_meta(_MOVER, null)
	if prev != null and is_instance_valid(prev) and (prev as Tween).is_valid():
		# Something is mid-motion: its recorded rest is the truth, the live transform is not.
		rest = target.get_meta(_REST, rest)
		(prev as Tween).kill()
		target.position         = rest["pos"]
		target.rotation_degrees = rest["rot"]
		target.scale            = rest["scale"]
		target.pivot_offset     = rest.get("pivot", target.pivot_offset)
	target.set_meta(_REST, rest)
	return rest["pos"]


# Registers the displacement tween begun after a begin_displace claim.
func hold_displace(target: Control, tw: Tween) -> void:
	target.set_meta(_MOVER, tw)


# ── Reaction claims: when a big cue speaks for the card ────────────────────────────
# Exclusivity above decides who moves a card; this decides who gets to REACT on it at all.
#
# The routine negative-event reaction (VFXEffect._drain_card's grey wash + tremble) fires off the
# damage numbers, which land a frame behind a crit on the same card. Both are the card answering
# the SAME blow, and the crit's answer is the louder one — so a crit claims the card for the length
# of its stagger and the drain stands down rather than talking over it.
#
# Deliberately a claim with a DURATION rather than a running-tween handle: it has to outlive the
# effect node that made it (a designed effect frees itself at the end of play(), long before its
# tweens finish), and it must not be silently released when some other cue cancels the mover.
const _REACT_UNTIL := "vfx_reaction_until"


# Claims `target`'s reaction for `seconds` — a lesser cue on the same card will yield.
func claim_reaction(target: Control, seconds: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	target.set_meta(_REACT_UNTIL, Time.get_ticks_msec() + int(seconds * 1000.0))


# Whether a bigger cue is currently speaking for this card.
func reaction_claimed(target: Control) -> bool:
	if target == null or not is_instance_valid(target) or not target.has_meta(_REACT_UNTIL):
		return false
	return int(target.get_meta(_REACT_UNTIL)) > Time.get_ticks_msec()


# ── Element resolution ─────────────────────────────────────────────────────────────

# (kind, composition) -> the element-variant entry id ("projectile_air_fire"), or `fallback`
# when no variant serves it: empty composition, no such entry, or the variant is a placeholder
# currently muted (F8) — a designed base look always beats silence. The id is the kind + the
# SORTED composition, the same canonical form the 27-element space uses everywhere.
func resolve(kind: String, composition: Array, fallback: String = "") -> String:
	if composition.is_empty():
		return fallback
	var elems := PackedStringArray()
	for e: String in composition:
		elems.append(e)
	elems.sort()
	var id := "%s_%s" % [kind, "_".join(elems)]
	return id if live(id) else fallback


# Whether an entry would actually show right now: it exists, and it isn't a placeholder
# currently muted by F8. The gate variant pickers decide "variant or designed base" through.
func live(id: String) -> bool:
	var vd := VFXData.get_vfx(id)
	if vd == null:
		return false
	return not vd.placeholder or DevFlags.placeholder_vfx


# ── Renderer dispatch ──────────────────────────────────────────────────────────────

func _dispatch(vd: VFXData, target: Control, opts: Dictionary) -> void:
	match vd.renderer:
		"procedural":
			# Return at the HANDOFF, not the end (see "Sequencing" above): the primitive keeps
			# playing — and frees itself — while the caller's next beat starts under its tail. An
			# atomic entry ("overlap": 0) is awaited outright.
			var span: float = _span_of(vd)
			var lead: float = handoff(span, vd)
			if lead >= span:
				await _play_procedural(vd, target, opts)
			else:
				_play_procedural(vd, target, opts)
				await get_tree().create_timer(lead).timeout
		"custom":
			var fn: Callable = _custom.get(vd.id, Callable())
			if fn.is_valid():
				await fn.call(vd, target, opts)
			else:
				# The owning system isn't alive (e.g. a combat look outside combat) — no cue.
				push_warning("Vfx: custom renderer for \"%s\" is not registered" % vd.id)
		_:
			# Future renderer kinds (flipbook/scene/...) land here as new arms.
			push_warning("Vfx: unknown renderer \"%s\" on \"%s\"" % [vd.renderer, vd.id])


func _play_procedural(vd: VFXData, target: Control, opts: Dictionary) -> void:
	match vd.behavior:
		"flash":       await _fx_flash(vd, target, opts)
		"pulse":       await _fx_pulse_once(vd, target, opts)
		"pop":         await _fx_pop(vd, target, opts)
		"shake":       await _fx_shake(vd, target, opts)
		"ring":        await _fx_ring(vd, target, opts)
		"sparkle":     await _fx_sparkle(vd, target, opts)
		"glint":       await _fx_glint(vd, target, opts)
		"glow":        await _fx_glow_once(vd, target, opts)
		"float_label": await _fx_float_label(vd, target, opts)
		"burst":       await _fx_burst(vd, target, opts)
		"travel":      await _fx_travel(vd, target, opts)
		"reticle":     await _fx_reticle(vd, target, opts)
		"dissolve":    await _fx_dissolve(vd, target, opts)
		"radiance":    await _fx_radiance_once(vd, target, opts)
		"emit":        await _fx_emit_once(vd, target, opts)
		_:
			push_warning("Vfx: unknown behavior \"%s\" on \"%s\"" % [vd.behavior, vd.id])


func _attach_dispatch(vd: VFXData, target: Control) -> Node:
	match vd.renderer:
		"procedural":
			match vd.behavior:
				"glow":     return _sustain_glow(vd, target)
				"pulse":    return _sustain_pulse(vd, target)
				"sparkle":  return _sustain_sparkle(vd, target)
				"radiance": return _sustain_radiance(vd, target)
				"emit":     return _sustain_emit(vd, target)
		"filter":
			# STANDARD for outer glows: the `glow_rrect` filter (the outer-glow shader) now ALWAYS
			# runs composited — it reads the target's TRUE silhouette (it + all children) and draws
			# on the overlay layer, so it never clips and never covers a child (badge, status pip,
			# anything). `composited: true` opts any other entry in; `composited: false` opts out.
			# Inner effects (luminescence_rrect / inner_glow) are NOT outer glows and stay analytic.
			var is_glow: bool = str(vd.params.get("filter", "")) == "glow_rrect"
			if bool(vd.params.get("composited", is_glow)):
				return _sustain_composited_glow(vd, target)
			return _sustain_filter(vd, target)
		"custom":
			var fn: Callable = _custom.get(vd.id, Callable())
			if fn.is_valid():
				var node: Node = fn.call(vd, target)
				if node != null and node.get_parent() == null:
					_layer.add_child(node)   # in-tree so tree_exiting fires when detach frees it
				return node
	push_warning("Vfx.attach: \"%s\" (%s/%s) is not sustain-capable" % [vd.id, vd.renderer, vd.behavior])
	return null


# ── Shared skin readers ────────────────────────────────────────────────────────────

func _p_color(vd: VFXData, opts: Dictionary, fallback: Color) -> Color:
	if opts.has("color") and opts.get("color") is Color:
		return opts.get("color")
	return vd.color_param("color", fallback)


func _p_dur(vd: VFXData, fallback: float) -> float:
	return maxf(0.05, vd.num_param("duration", fallback))


func _p_scale(vd: VFXData) -> float:
	return clampf(vd.num_param("scale", 1.0), 0.2, 4.0)


func _center(c: Control) -> Vector2:
	return c.get_global_rect().get_center()


# An additive-blended ColorRect — the workhorse overlay every light-like primitive draws with.
func _make_rect(color: Color, size: Vector2) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.size = size
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	r.material = mat
	_layer.add_child(r)
	return r


# The "radiance" behavior's draw node: additive-blended, sized to the target's rect (glued or set
# once by the caller) — see _HaloFx for the actual layered falloff.
#
# `params.shape` picks what the light is shaped LIKE. "rect" (the default) traces the target's
# own box, which is right when the target IS the lit thing (a card, a button, a slot). "radial"
# blooms as concentric discs from its centre, which is right when the light comes OUT of the
# target rather than being it — a chest's lid opening, a mouth of a flask, a wound. On those, a
# rect halo reads as a bright PANEL parked behind the art instead of as light.
func _make_halo(vd: VFXData, opts: Dictionary) -> _HaloFx:
	var fx := _HaloFx.new()
	fx.color = _p_color(vd, opts, Color(1.0, 0.9, 0.6))
	fx.radial = vd.text_param("shape", "rect") == "radial"
	fx.reach = 18.0 * _p_scale(vd)
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	fx.material = mat
	_layer.add_child(fx)
	return fx


# ── One-shot primitives ────────────────────────────────────────────────────────────
# Every primitive draws OVERLAYS positioned by the target's global rect; pop/shake are the two
# deliberate exceptions (motion of the thing itself IS the effect) and always restore what they
# touched. All guard against the target dying mid-animation.

# A bright film over the target's rect, gone in one breath.
func _fx_flash(vd: VFXData, target: Control, opts: Dictionary) -> void:
	var rect := target.get_global_rect()
	var color := _p_color(vd, opts, Color(1, 1, 1))
	var fx := _make_rect(Color(color.r, color.g, color.b, 0.55), rect.size)
	fx.global_position = rect.position
	var tw := fx.create_tween()
	tw.tween_property(fx, "modulate:a", 0.0, _p_dur(vd, 0.28))
	await tw.finished
	fx.queue_free()


# One soft halo swell behind/over the target — the single-beat form of the sustained pulse.
func _fx_pulse_once(vd: VFXData, target: Control, opts: Dictionary) -> void:
	var rect := target.get_global_rect()
	var color := _p_color(vd, opts, Color(1.0, 0.9, 0.5))
	var grow := 14.0 * _p_scale(vd)
	# Full-alpha colour, fade driven by modulate ONLY — pixel alpha is the PRODUCT of the two,
	# so a zero base alpha can never fade in no matter what modulate does.
	var fx := _make_rect(Color(color.r, color.g, color.b, 1.0), rect.size + Vector2(grow, grow) * 2.0)
	fx.modulate.a = 0.0
	fx.global_position = rect.position - Vector2(grow, grow)
	var dur := _p_dur(vd, 0.45)
	var tw := fx.create_tween()
	tw.tween_property(fx, "modulate:a", 0.4, dur * 0.4).set_trans(Tween.TRANS_SINE)
	tw.tween_property(fx, "modulate:a", 0.0, dur * 0.6).set_trans(Tween.TRANS_SINE)
	await tw.finished
	fx.queue_free()


# A quick scale bounce of the target itself (pivot centered), restored exactly.
func _fx_pop(vd: VFXData, target: Control, _opts: Dictionary) -> void:
	var old_pivot := target.pivot_offset
	target.pivot_offset = target.size * 0.5
	var amount := 1.0 + 0.18 * _p_scale(vd)
	var dur := _p_dur(vd, 0.3)
	var tw := target.create_tween()
	tw.tween_property(target, "scale", Vector2(amount, amount), dur * 0.35) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(target, "scale", Vector2.ONE, dur * 0.65) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	if is_instance_valid(target):
		target.scale = Vector2.ONE
		target.pivot_offset = old_pivot


# A brief positional jitter of the target itself, restored exactly.
func _fx_shake(vd: VFXData, target: Control, _opts: Dictionary) -> void:
	var origin := begin_displace(target)   # exclusive — see the displacement section above
	var strength := 6.0 * _p_scale(vd)
	var tw := target.create_tween()
	for i in 4:
		var off := Vector2(randf_range(-strength, strength), randf_range(-strength, strength))
		tw.tween_property(target, "position", origin + off, _p_dur(vd, 0.28) / 5.0)
	tw.tween_property(target, "position", origin, _p_dur(vd, 0.28) / 5.0)
	hold_displace(target, tw)
	await tw.finished
	if is_instance_valid(target):
		target.position = origin


# An expanding circle outline from the target's center.
func _fx_ring(vd: VFXData, target: Control, opts: Dictionary) -> void:
	var fx := _RingFx.new()
	fx.color = _p_color(vd, opts, Color(0.6, 0.9, 1.0))
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(fx)
	fx.global_position = _center(target)
	var radius := 26.0 + 34.0 * _p_scale(vd)
	var dur := _p_dur(vd, 0.4)
	var tw := fx.create_tween().set_parallel()
	tw.tween_property(fx, "radius", radius, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(fx, "modulate:a", 0.0, dur)
	await tw.finished
	fx.queue_free()


# Small diamond glints scattering off random points of the target's rect.
func _fx_sparkle(vd: VFXData, target: Control, opts: Dictionary) -> void:
	var rect := target.get_global_rect()
	var color := _p_color(vd, opts, Color(1.0, 0.95, 0.6))
	var count := int(6 * _p_scale(vd)) + 3
	var dur := _p_dur(vd, 0.5)
	var last: Tween = null
	for i in count:
		var s := 4.0 + randf() * 5.0
		var p := _make_rect(color, Vector2(s, s))
		p.rotation = PI / 4.0
		p.global_position = rect.position + Vector2(randf() * rect.size.x, randf() * rect.size.y)
		var drift := Vector2(randf_range(-24, 24), randf_range(-40, -12))
		var tw := p.create_tween().set_parallel()
		tw.tween_property(p, "global_position", p.global_position + drift, dur)
		tw.tween_property(p, "modulate:a", 0.0, dur)
		tw.chain().tween_callback(p.queue_free)
		last = tw
	if last != null:
		await last.finished


# A sheen flare: quick bright swell + fade over the whole rect — "this thing just acted".
func _fx_glint(vd: VFXData, target: Control, opts: Dictionary) -> void:
	var rect := target.get_global_rect()
	var color := _p_color(vd, opts, Color(1.0, 1.0, 0.85))
	var fx := _make_rect(Color(color.r, color.g, color.b, 1.0), rect.size)   # full-alpha base;
	fx.modulate.a = 0.0   # modulate alone drives the fade (see _fx_pulse_once)
	fx.global_position = rect.position
	var dur := _p_dur(vd, 0.36)
	var tw := fx.create_tween()
	tw.tween_property(fx, "modulate:a", 0.7, dur * 0.3).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(fx, "modulate:a", 0.0, dur * 0.7).set_trans(Tween.TRANS_QUAD)
	await tw.finished
	fx.queue_free()


# The one-shot form of glow: a halo that blooms and fades once.
func _fx_glow_once(vd: VFXData, target: Control, opts: Dictionary) -> void:
	await _fx_pulse_once(vd, target, opts)


# A genuine soft radiance: layered rounded rects growing outward with falling alpha (additive),
# so the target reads as the BRIGHT CORE of a light bleeding into its surroundings — unlike
# glow/pulse's single flat rect (a uniform block that pops in/out with a hard edge), this fades
# smoothly to nothing at its outer edge. One-shot: a single breathe in and out.
func _fx_radiance_once(vd: VFXData, target: Control, opts: Dictionary) -> void:
	var fx := _make_halo(vd, opts)
	var rect := target.get_global_rect()
	fx.global_position = rect.position
	fx.size = rect.size
	var dur := _p_dur(vd, 0.5)
	var tw := fx.create_tween()
	tw.tween_property(fx, "energy", 1.0, dur * 0.4).set_trans(Tween.TRANS_SINE)
	tw.tween_property(fx, "energy", 0.0, dur * 0.6).set_trans(Tween.TRANS_SINE)
	await tw.finished
	fx.queue_free()


# Floating text rising off the target — numbers ("-3"), words ("Miss"), whatever opts carries.
func _fx_float_label(vd: VFXData, target: Control, opts: Dictionary) -> void:
	var amount: int = int(opts.get("amount", 0))
	var text := str(opts.get("text", ("%+d" % amount) if amount != 0 else ""))
	if text.is_empty():
		return   # nothing to say — checked BEFORE creating the node so nothing leaks
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", int(26 * _p_scale(vd)))
	lbl.add_theme_color_override("font_color", _p_color(vd, opts, Color.WHITE))
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	lbl.add_theme_constant_override("outline_size", 6)
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(lbl)
	lbl.global_position = _center(target) - Vector2(lbl.size.x * 0.5, 10)
	var dur := _p_dur(vd, 0.8)
	var tw := lbl.create_tween().set_parallel()
	tw.tween_property(lbl, "global_position:y", lbl.global_position.y - 46.0, dur)
	tw.tween_property(lbl, "modulate:a", 0.0, dur).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw.finished
	lbl.queue_free()


# Radial shards flying outward from the target's center — an impact.
func _fx_burst(vd: VFXData, target: Control, opts: Dictionary) -> void:
	var center := _center(target)
	var color := _p_color(vd, opts, Color(1.0, 0.6, 0.25))
	var count := int(8 * _p_scale(vd)) + 4
	var dur := _p_dur(vd, 0.4)
	var last: Tween = null
	for i in count:
		var s := 5.0 + randf() * 4.0
		var p := _make_rect(color, Vector2(s, s))
		p.global_position = center
		var dir := Vector2.RIGHT.rotated(TAU * float(i) / count + randf() * 0.5)
		var tw := p.create_tween().set_parallel()
		tw.tween_property(p, "global_position", center + dir * (40.0 + randf() * 40.0) * _p_scale(vd), dur) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(p, "modulate:a", 0.0, dur)
		tw.chain().tween_callback(p.queue_free)
		last = tw
	if last != null:
		await last.finished


# An orb flying from opts.source to the target, bursting on arrival. Without a source it
# degrades to the burst alone — the impact still reads.
func _fx_travel(vd: VFXData, target: Control, opts: Dictionary) -> void:
	var source: Control = opts.get("source") as Control
	var color := _p_color(vd, opts, Color(1.0, 0.5, 0.15))
	if source != null and is_instance_valid(source) and source.is_inside_tree():
		var s := 18.0 * _p_scale(vd)
		var orb := _make_rect(color, Vector2(s, s))
		orb.rotation = PI / 4.0
		orb.global_position = _center(source) - Vector2(s, s) * 0.5
		var tw := orb.create_tween()
		tw.tween_property(orb, "global_position", _center(target) - Vector2(s, s) * 0.5,
				_p_dur(vd, 0.26)).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		await tw.finished
		orb.queue_free()
	if is_instance_valid(target) and target.is_inside_tree():
		await _fx_burst(vd, target, opts)


# Four corner brackets snapping onto the target — "THIS one".
func _fx_reticle(vd: VFXData, target: Control, opts: Dictionary) -> void:
	var fx := _ReticleFx.new()
	fx.color = _p_color(vd, opts, Color(1.0, 0.9, 0.3))
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(fx)
	var rect := target.get_global_rect()
	fx.global_position = rect.position
	fx.size = rect.size
	fx.spread = 26.0
	var dur := _p_dur(vd, 0.4)
	var tw := fx.create_tween()
	tw.tween_property(fx, "spread", 0.0, dur * 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(dur * 0.3)
	tw.tween_property(fx, "modulate:a", 0.0, dur * 0.25)
	await tw.finished
	fx.queue_free()


# A shroud that closes over the target and fades — the abstract "it vanishes" cue.
func _fx_dissolve(vd: VFXData, target: Control, opts: Dictionary) -> void:
	var rect := target.get_global_rect()
	var color := _p_color(vd, opts, Color(0.15, 0.1, 0.2))
	var fx := ColorRect.new()   # NOT additive — a shroud darkens
	fx.color = Color(color.r, color.g, color.b, 0.0)
	fx.size = rect.size
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(fx)
	fx.global_position = rect.position
	var dur := _p_dur(vd, 0.5)
	var tw := fx.create_tween()
	tw.tween_property(fx, "color:a", 0.75, dur * 0.4)
	tw.tween_property(fx, "modulate:a", 0.0, dur * 0.6)
	await tw.finished
	fx.queue_free()


# ── The "emit" behavior: a stream rising out of a FEATURE of the target's art ──────
#
# Every other primitive treats its target as ONE rect. This one doesn't: art often has a place
# where something comes OUT — a flask's mouth, a chimney, a wound, a censer — and a cue that
# ignores it (spawning across the whole widget) reads as glitter pasted over a picture rather
# than as the picture doing something. So the entry DECLARES the feature, in fractions of the
# target's rect, and the stream spans exactly that and nowhere else:
#
#   "params": { "origin": {"x": 0.33, "y": 0.08, "w": 0.30, "h": 0.07}, "shape": "ellipse",
#               "particle": "bubble", "rate": 5, "rise": 0.30, "drift": 0.05 }
#
# Fractions, not pixels, because the same art is laid out at several sizes (desktop/compact) —
# a mouth is at the same place in the picture at any diameter. Everything the particles measure
# (size, rise, drift) is likewise a fraction of the target, so the whole effect scales with the
# widget by construction and never needs a per-screen number.
func _make_emitter(vd: VFXData, target: Control) -> _EmitFx:
	var fx := _EmitFx.new()
	fx.target = target
	fx.color = vd.color_param("color", Color(0.8, 1.0, 0.6))
	var org: Dictionary = vd.params.get("origin", {}) if vd.params.get("origin") is Dictionary else {}
	fx.origin = Rect2(float(org.get("x", 0.0)), float(org.get("y", 0.0)),
			float(org.get("w", 1.0)), float(org.get("h", 1.0)))
	fx.ellipse = str(vd.params.get("shape", "rect")) == "ellipse"
	fx.particle = str(vd.params.get("particle", "bubble"))
	fx.rate = maxf(0.0, vd.num_param("rate", 5.0)) * _p_scale(vd)
	fx.size_min = maxf(0.001, vd.num_param("size_min", 0.02))
	fx.size_max = maxf(fx.size_min, vd.num_param("size_max", 0.05))
	fx.rise = vd.num_param("rise", 0.30)
	fx.drift = vd.num_param("drift", 0.04)
	fx.life_min = maxf(0.1, vd.num_param("life_min", 1.2))
	fx.life_max = maxf(fx.life_min, vd.num_param("life_max", 2.0))
	fx.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	fx.material = mat
	overlay_layer_for(target).add_child(fx)
	return fx


# One-shot form: a single puff of `count` particles out of the feature, then the node retires
# itself once the last one has faded (a burp, where the sustained form is a simmer).
func _fx_emit_once(vd: VFXData, target: Control, _opts: Dictionary) -> void:
	var fx := _make_emitter(vd, target)
	fx.spawning = false
	var count := int(vd.num_param("count", 6.0) * _p_scale(vd))
	for i in count:
		fx.spawn_one()
	fx.free_when_empty = true
	await get_tree().create_timer(fx.life_max).timeout


# Sustained form: the stream runs for as long as the state is attached. detach() frees the node.
func _sustain_emit(vd: VFXData, target: Control) -> Node:
	var fx := _make_emitter(vd, target)
	# Seeded mid-flight, so attaching (entering the screen) shows a stream already in progress
	# rather than an empty mouth that takes a couple of seconds to fill.
	fx.prime()
	return fx


# ── Sustained primitives (attach/detach states) ────────────────────────────────────
# Each returns the state's root node; detach frees it. The node keeps itself glued to the
# target's rect so a moving/resizing target carries its aura along.

func _sustain_glow(vd: VFXData, target: Control) -> Node:
	return _breathing_halo(vd, target, _p_dur(vd, 0.9), 0.32, 0.08)


# The glow's insistent sibling: a faster, deeper breath — attention, not ambience.
func _sustain_pulse(vd: VFXData, target: Control) -> Node:
	return _breathing_halo(vd, target, _p_dur(vd, 0.45), 0.42, 0.05)


# The genuine-radiance sibling of glow/pulse: same breathing idea, but the light itself falls off
# smoothly outward (see _make_halo/_HaloFx) instead of a single flat rect popping in and out with
# a hard edge — use this one when the effect needs to actually read as light bleeding outward.
func _sustain_radiance(vd: VFXData, target: Control) -> Node:
	var fx := _make_halo(vd, {})
	_glue(fx, target, 0.0)   # the halo's own layers provide the reach; the base rect just tracks the target
	var period := _p_dur(vd, 0.9)
	var tw := fx.create_tween().set_loops()
	tw.tween_property(fx, "energy", 1.0, period).set_trans(Tween.TRANS_SINE)
	tw.tween_property(fx, "energy", 0.3, period).set_trans(Tween.TRANS_SINE)
	return fx


# renderer "filter": the look is a RenderFilter (a shader reading the source texture's pixels),
# and this entry owns WHEN it is on and how its params move. `params.filter` names the filter;
# every other param is forwarded as a shader-uniform override; the optional `params.animate`
# block breathes one uniform between two values forever:
#
#   "params": { "filter": "glow", "spread": 46,
#               "animate": {"param": "intensity", "from": 0.5, "to": 1.2, "period": 1.6} }
#
# Note the returned node belongs to the TARGET's subtree, not this service's overlay layer —
# that is the point of a filter (it draws behind the source, not over the whole UI). detach()
# frees it either way.
# The general outer glow: a GlowFx on the overlay layer, driven by the target's real composited
# silhouette (see GlowFx / SilhouetteBaker). Escapes all clipping, never covers a child. Params
# (glow_color/spread/falloff/intensity/animate) come straight from the vfx.json entry.
func _sustain_composited_glow(vd: VFXData, target: Control) -> Node:
	var g := GlowFx.new()
	# The target's own BAND — outside the UI tree's clipping, and depth-correct against modals
	# (a modal widget's glow rises above the scrim; a table widget's stays under it).
	overlay_layer_for(target).add_child(g)
	g.setup(target, vd.params)        # async bake inside; the glow reveals once its silhouette lands
	return g


func _sustain_filter(vd: VFXData, target: Control) -> Node:
	var fid := str(vd.params.get("filter", ""))
	if fid.is_empty():
		push_warning("Vfx: entry \"%s\" is renderer \"filter\" but names no params.filter" % vd.id)
		return null
	var overrides: Dictionary = {}
	for key: String in vd.params:
		if key == "filter" or key == "animate":
			continue
		overrides[key] = vd.params[key]
	var layer: RenderFilterLayer = RenderFilters.apply(fid, target, overrides)
	if layer == null:
		return null

	var anim: Dictionary = vd.params.get("animate", {})
	if not anim.is_empty():
		var pname := str(anim.get("param", ""))
		var lo := float(anim.get("from", 0.0))
		var hi := float(anim.get("to", 1.0))
		var period := maxf(0.05, float(anim.get("period", 1.0)))
		if not pname.is_empty():
			var tw: Tween = layer.create_tween().set_loops()
			tw.tween_method(func(v: float) -> void: layer.set_param(pname, v),
					lo, hi, period).set_trans(Tween.TRANS_SINE)
			tw.tween_method(func(v: float) -> void: layer.set_param(pname, v),
					hi, lo, period).set_trans(Tween.TRANS_SINE)
	return layer


func _breathing_halo(vd: VFXData, target: Control, period: float, hi: float, lo: float) -> Node:
	var color := vd.color_param("color", Color(1.0, 0.85, 0.4))
	var grow := 10.0 * _p_scale(vd)
	var fx := _make_rect(Color(color.r, color.g, color.b, 1.0), Vector2.ZERO)   # full-alpha base;
	fx.modulate.a = 0.0   # the breath drives modulate alone (see _fx_pulse_once)
	_glue(fx, target, grow)
	var tw := fx.create_tween().set_loops()
	tw.tween_property(fx, "modulate:a", hi, period).set_trans(Tween.TRANS_SINE)
	tw.tween_property(fx, "modulate:a", lo, period).set_trans(Tween.TRANS_SINE)
	return fx


# A slow drip of sparkles off the target for as long as the state is attached.
func _sustain_sparkle(vd: VFXData, target: Control) -> Node:
	var host := Node.new()
	_layer.add_child(host)
	var timer := Timer.new()
	timer.wait_time = maxf(0.15, 0.6 / _p_scale(vd))
	timer.autostart = true
	host.add_child(timer)
	timer.timeout.connect(func():
		if not is_instance_valid(target) or not target.is_inside_tree():
			return
		var rect := target.get_global_rect()
		var color := vd.color_param("color", Color(1.0, 0.95, 0.6))
		var s := 3.0 + randf() * 4.0
		var p := _make_rect(color, Vector2(s, s))
		p.rotation = PI / 4.0
		p.global_position = rect.position + Vector2(randf() * rect.size.x, randf() * rect.size.y)
		var tw := p.create_tween().set_parallel()
		tw.tween_property(p, "global_position:y", p.global_position.y - 26.0, 0.7)
		tw.tween_property(p, "modulate:a", 0.0, 0.7)
		tw.chain().tween_callback(p.queue_free))
	return host


# Keeps an overlay rect tracking the target's global rect (grown by `grow` on every side),
# re-synced each frame — cheap, and survives the target moving, resizing, or scrolling.
func _glue(fx: Control, target: Control, grow: float) -> void:
	var sync := func() -> void:
		if not is_instance_valid(target) or not target.is_inside_tree():
			return
		var rect := target.get_global_rect()
		fx.global_position = rect.position - Vector2(grow, grow)
		fx.size = rect.size + Vector2(grow, grow) * 2.0
	sync.call()
	var ticker := Timer.new()
	ticker.wait_time = 0.05
	ticker.autostart = true
	fx.add_child(ticker)
	ticker.timeout.connect(sync)


# ── Draw-node inner classes ─────────────────────────────────────────────────────────

class _RingFx extends Control:
	var color := Color.WHITE
	var radius := 4.0:
		set(v): radius = v; queue_redraw()
	func _draw() -> void:
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, color, 3.0, true)


class _ReticleFx extends Control:
	var color := Color.WHITE
	var spread := 0.0:
		set(v): spread = v; queue_redraw()
	func _draw() -> void:
		var arm := minf(size.x, size.y) * 0.22
		var w := 3.0
		for corner in [Vector2(0, 0), Vector2(size.x, 0), Vector2(0, size.y), size]:
			var dx: float = 1.0 if corner.x == 0.0 else -1.0
			var dy: float = 1.0 if corner.y == 0.0 else -1.0
			var origin: Vector2 = corner + Vector2(-dx * spread, -dy * spread)
			draw_line(origin, origin + Vector2(dx * arm, 0), color, w, true)
			draw_line(origin, origin + Vector2(0, dy * arm), color, w, true)


# The "radiance" behavior's look: several rounded rects, growing outward from the base rect
# (0 = flush with it) toward `reach` px past it, alpha falling off toward the outer layers —
# stacked ADDITIVE, so the base rect's own footprint accumulates every layer's contribution
# (brightest, reading as the light's core) while the rim only carries the outermost, faintest
# layer. That gradient is what actually reads as "radiance" — a single flat rect (glow/pulse's
# look) has no such falloff, so it just pops as a hard-edged block.
# The "emit" behavior's draw node (see _make_emitter). ONE node draws the whole stream — every
# particle lives in the target's NORMALIZED space (0..1 of its rect) and is converted to pixels
# at draw time, so a target that moves, scales or relayouts carries its stream along without a
# single particle having to be repositioned.
class _EmitFx extends Control:
	var target: Control
	var color := Color.WHITE
	var origin := Rect2(0, 0, 1, 1)   # the emitting feature, in fractions of the target's rect
	var ellipse := false              # spawn inside the region's inscribed ellipse, not its box
	var particle := "bubble"          # bubble (hollow, rimmed, specular) | mote (soft dot)
	var rate := 5.0                   # particles per second
	var size_min := 0.02              # radius, in fractions of the target's SHORTER side
	var size_max := 0.05
	var rise := 0.30                  # travel before dying, in fractions of the target's height
	var drift := 0.04                 # sideways wander amplitude, in fractions of its width
	var life_min := 1.2
	var life_max := 2.0
	var spawning := true              # false = a fixed puff (see _fx_emit_once)
	var free_when_empty := false

	var _parts: Array[Dictionary] = []
	var _accum := 0.0

	func _ready() -> void:
		z_index = 1
		_sync_rect()

	# One particle, born somewhere in the feature. `x`/`y` are its birthplace in normalized
	# target space; everything else is its own variation of the entry's skin.
	func spawn_one(age := 0.0) -> void:
		var p := Vector2(randf(), randf())
		if ellipse:
			# Rejection-free polar pick, area-uniform (sqrt), then squashed onto the region's box —
			# an ellipse rather than a rect matters here: a flask mouth IS an ellipse, and corner
			# spawns would sit on the glass rim instead of over the opening.
			var a := randf() * TAU
			var r := sqrt(randf()) * 0.5
			p = Vector2(0.5 + cos(a) * r, 0.5 + sin(a) * r)
		_parts.append({
			"x": origin.position.x + p.x * origin.size.x,
			"y": origin.position.y + p.y * origin.size.y,
			"r": randf_range(size_min, size_max),
			"life": randf_range(life_min, life_max),
			"age": age,
			# Each bubble wanders on its own phase and speed, so the stream never reads as a
			# column of clones marching in step.
			"phase": randf() * TAU,
			"wob": randf_range(0.7, 1.6),
			"lean": randf_range(-1.0, 1.0),
		})

	# Fills the stream with particles already partway through their lives — what a simmer that has
	# been running all along looks like, as opposed to one that starts the moment you look at it.
	func prime() -> void:
		if rate <= 0.0:
			return
		var mid := (life_min + life_max) * 0.5
		for i in int(rate * mid):
			spawn_one(randf() * mid)

	func _process(delta: float) -> void:
		if target == null or not is_instance_valid(target) or not target.is_inside_tree():
			queue_free()
			return
		_sync_rect()
		visible = target.is_visible_in_tree()
		if spawning and rate > 0.0:
			_accum += delta * rate
			while _accum >= 1.0:
				_accum -= 1.0
				spawn_one()
		var alive: Array[Dictionary] = []
		for p: Dictionary in _parts:
			p["age"] = float(p["age"]) + delta
			if float(p["age"]) < float(p["life"]):
				alive.append(p)
		_parts = alive
		if _parts.is_empty() and not spawning and free_when_empty:
			queue_free()
			return
		queue_redraw()

	# Glued to the target's global rect — the same tracking _glue does for the halo primitives,
	# done per frame here because particles are re-drawn every frame anyway.
	func _sync_rect() -> void:
		var rect := target.get_global_rect()
		global_position = rect.position
		size = rect.size

	func _draw() -> void:
		if size.x <= 0.0 or size.y <= 0.0:
			return
		var unit := minf(size.x, size.y)
		for p: Dictionary in _parts:
			var t: float = clampf(float(p["age"]) / float(p["life"]), 0.0, 1.0)
			# Rising: quick off the surface, easing as it climbs — and swelling slightly on the
			# way up, the way a real bubble does as the pressure around it drops.
			var climb: float = pow(t, 0.78)
			var wander: float = sin(float(p["phase"]) + t * TAU * float(p["wob"])) * drift \
					+ float(p["lean"]) * drift * 0.5 * t
			var c := Vector2((float(p["x"]) + wander) * size.x,
					(float(p["y"]) - climb * rise) * size.y)
			var r: float = float(p["r"]) * unit * (1.0 + 0.35 * t)
			# In fast, out slow: a bubble breaking the surface is abrupt, its dissipation isn't.
			var a: float = smoothstep(0.0, 0.12, t) * (1.0 - smoothstep(0.55, 1.0, t))
			if a <= 0.003 or r <= 0.4:
				continue
			_draw_particle(c, r, a)

	func _draw_particle(c: Vector2, r: float, a: float) -> void:
		if particle == "mote":
			draw_circle(c, r, Color(color.r, color.g, color.b, a * 0.85))
			return
		# A bubble is mostly its RIM: a faint fill, a bright edge, and one specular dot up-left —
		# the same read as the painted bubbles inside the flask, so the ones leaving it look like
		# they came from the same picture.
		draw_circle(c, r, Color(color.r, color.g, color.b, a * 0.20))
		draw_arc(c, r * 0.86, 0.0, TAU, 20, Color(color.r, color.g, color.b, a * 0.85),
				maxf(1.0, r * 0.22), true)
		draw_circle(c - Vector2(r * 0.32, r * 0.32), maxf(0.8, r * 0.22),
				Color(1, 1, 1, a * 0.65))


class _HaloFx extends Control:
	const LAYERS := 6
	const BASE_CORNER := 14.0
	const RADIAL_LAYERS := 10   # discs read smooth only with more steps than rects need
	var color := Color.WHITE
	var reach := 18.0
	var radial := false   # see _make_halo: light OUT OF the target, rather than light SHAPED like it
	var energy := 0.0:
		set(v): energy = v; queue_redraw()
	func _draw() -> void:
		if energy <= 0.001:
			return
		if radial:
			_draw_radial()
			return
		var sb := StyleBoxFlat.new()
		var span := float(LAYERS - 1)
		for i in LAYERS:
			var f := float(i) / span   # 0 = innermost (flush with the target) → 1 = outermost
			var grow := reach * f
			var corner := BASE_CORNER + grow
			sb.set_corner_radius_all(int(corner))
			var col := color
			# Squared falloff: most layers stay faint, the innermost couple carry the visible
			# brightness — reads as a core with a long soft tail, not a linear-fading blob.
			col.a = energy * 0.22 * pow(1.0 - f, 2.0)
			sb.bg_color = col
			draw_style_box(sb, Rect2(Vector2.ZERO, size).grow(grow))

	# Concentric discs from the target's centre, brightest in the middle and fading to nothing
	# at the rim — a source of light rather than a lit box. The additive stack accumulates
	# toward the core (every layer covers the middle), the same falloff the reward orb uses.
	func _draw_radial() -> void:
		var c := size * 0.5
		var inner: float = minf(size.x, size.y) * 0.28   # the "mouth" the light comes out of
		var span := float(RADIAL_LAYERS - 1)
		for i in RADIAL_LAYERS:
			var f := float(i) / span   # 0 = innermost → 1 = outermost
			var col := color
			col.a = energy * 0.16 * pow(1.0 - f, 2.0)
			draw_circle(c, inner + reach * f * 1.6, col)
