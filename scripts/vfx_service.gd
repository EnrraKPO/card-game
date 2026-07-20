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
		"float_label", "burst", "travel", "reticle", "dissolve", "radiance"]
# Behaviors that can run as a SUSTAINED state (attach/detach) as well as a one-shot.
const SUSTAINED_BEHAVIORS := ["glow", "pulse", "sparkle", "radiance"]

# All effect nodes draw on one dedicated layer above the UI, positioned in global canvas
# coordinates — effects never join a container's layout or clip inside a target's rect.
var _layer: CanvasLayer
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
	if not vd.sfx.is_empty():
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
	var node: Node = _attached.get(key, null)
	if node == null:
		return
	_attached.erase(key)
	if is_instance_valid(node):
		node.queue_free()


func _attach_key(id: String, target: Control) -> String:
	return "%s@%d" % [id, target.get_instance_id()]


# Registers the playback callable for a renderer-"custom" entry: fn(vd: VFXData,
# target: Control, opts: Dictionary), awaited like any look. See _custom above.
func register_custom(id: String, fn: Callable) -> void:
	_custom[id] = fn


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
			await _play_procedural(vd, target, opts)
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
		"filter":
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
func _make_halo(vd: VFXData, opts: Dictionary) -> _HaloFx:
	var fx := _HaloFx.new()
	fx.color = _p_color(vd, opts, Color(1.0, 0.9, 0.6))
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
	var origin := target.position
	var strength := 6.0 * _p_scale(vd)
	var tw := target.create_tween()
	for i in 4:
		var off := Vector2(randf_range(-strength, strength), randf_range(-strength, strength))
		tw.tween_property(target, "position", origin + off, _p_dur(vd, 0.28) / 5.0)
	tw.tween_property(target, "position", origin, _p_dur(vd, 0.28) / 5.0)
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
class _HaloFx extends Control:
	const LAYERS := 6
	const BASE_CORNER := 14.0
	var color := Color.WHITE
	var reach := 18.0
	var energy := 0.0:
		set(v): energy = v; queue_redraw()
	func _draw() -> void:
		if energy <= 0.001:
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
