class_name ForgeMergeFX
extends Node2D

# Binds the Forge's drag VFX (ForgeAura swirl + ForgeLink vortex) to a STATIC pair of card Controls
# that are being merged — the same "each card swirls, motes flow between them, both glow" look the
# drag shows on a moving follower, but pinned to two laid-out cards. Used by the combine-confirm
# modal and the forge side panel so a queued merge reads the same as a dragged one. Add as a child
# of an overlay that shares canvas space with the cards, then call bind(). Each frame it re-reads the
# two Controls' global centres/sizes into this node's local space, so it tracks any relayout. Purely
# visual — SFX is the caller's call (the modal drones, the panel stays silent). Tuning: ForgeFX.
#
# Both auras sit permanently at connect_intensity (this pair is always "connected"), so the linked
# glow + rev'd swirl are on from the first frame — no easing-in, unlike the hover-driven drag path.

var _a: Control = null
var _b: Control = null
var _color_a := Color.WHITE
var _color_b := Color.WHITE
var _link_color := Color.WHITE

var _aura_a: ForgeAura = null
var _aura_b: ForgeAura = null
var _link: ForgeLink = null
var _inited := false
var _wob_t := 0.0             # drives the card wobble (ForgeFX.CARD) — the pair jiggles as it fuses
var _base_a := Vector2.ZERO   # each card's resting position (captured at init) — the pull offsets from here
var _base_b := Vector2.ZERO
var _pull_amp := 0.0          # px each card lunges toward the other (PULL_FRAC of card width)
var _own_position := true     # false = caller drives the cards' position (e.g. a fly tween); we only
                              # decorate (auras + link + rotation), never write position


# Bind to the two card Controls to swirl (a + b) and the colours to paint them / the vortex with.
# FX construction is deferred to the first frame the Controls have a real size (they may not be laid
# out yet at bind time), since ForgeAura bakes its glow outline from the radii at setup.
# `own_position` false when something else already moves the cards (the fusion fly tween) — then we
# keep the swirl/link/wobble but leave position alone, so the reaction rides along as they converge.
func bind(a: Control, b: Control, color_a: Color, color_b: Color, link_color: Color, own_position := true) -> void:
	_a = a
	_b = b
	_color_a = color_a
	_color_b = color_b
	_link_color = link_color
	_own_position = own_position


func _radii(c: Control) -> Vector2:
	var scale := float(ForgeFX.AURA["radius_scale"])
	var margin := float(ForgeFX.AURA["margin"])
	return Vector2(c.size.x * 0.5 * scale + margin, c.size.y * 0.5 * scale + margin)


func _init_fx() -> void:
	var connect_intensity := float(ForgeFX.AURA["connect_intensity"])
	var ra := _radii(_a)
	var rb := _radii(_b)

	_aura_a = ForgeAura.new()
	_aura_a.setup(ra.x, ra.y, _color_a)
	_aura_a.intensity = connect_intensity        # start already energised (no ease-in — always linked)
	_aura_a.set_intensity(connect_intensity)
	add_child(_aura_a)

	_aura_b = ForgeAura.new()
	_aura_b.setup(rb.x, rb.y, _color_b)
	_aura_b.intensity = connect_intensity
	_aura_b.set_intensity(connect_intensity)
	add_child(_aura_b)

	_link = ForgeLink.new()
	_link.setup(_link_color)
	add_child(_link)

	# Wobble rotates each card around its own centre — set the pivots now that sizes are known.
	_a.pivot_offset = _a.size * 0.5
	_b.pivot_offset = _b.size * 0.5
	# The inward lunge offsets from each card's resting position; scale it to the card width.
	_base_a = _a.position
	_base_b = _b.position
	_pull_amp = _a.size.x * float(ForgeFX.CARD["pull_frac"])

	_inited = true


func _process(delta: float) -> void:
	if _a == null or _b == null or not is_instance_valid(_a) or not is_instance_valid(_b):
		return
	if not _inited:
		if _a.size.x <= 0.0 or _b.size.x <= 0.0:
			return                                # wait for layout so radii/glow bake correctly
		_init_fx()

	var inv := get_global_transform().affine_inverse()
	var ca: Vector2 = inv * _a.get_global_rect().get_center()
	var cb: Vector2 = inv * _b.get_global_rect().get_center()
	_aura_a.position = ca
	_aura_b.position = cb
	var ra := _radii(_a)
	_link.set_endpoints(ca, cb, ra.x, ra.y)       # both cards share a size — a's radii drive the ring

	# The pair reacts as it fuses. Two layers, both a half-cycle out of phase between the cards:
	#  • a gentle tilt (full drag speed, reduced range — a small nervous quiver, not a big swing), and
	#  • a rhythmic lunge toward the partner so the two read as PULLING into each other.
	# get_global_rect() (above) is the rotation-invariant AABB centre, so halos/link stay glued as the
	# cards tilt; the lunge moves that centre, so halos/link follow the tug too.
	_wob_t += delta
	var cfg := ForgeFX.CARD
	var freq := float(cfg["wobble_freq"])
	var rot := float(cfg["wobble_rot"])
	# Raised cosine (0 → amp → 0) keeps the tug always INWARD, both cards surging in together.
	var axis := cb - ca
	var dir := axis.normalized() if axis.length() > 0.01 else Vector2.ZERO
	var pull := _pull_amp * (0.5 - 0.5 * cos(_wob_t * freq * float(cfg["pull_freq_mult"])))
	_a.rotation = rot * sin(_wob_t * freq)
	_b.rotation = rot * sin(_wob_t * freq + PI * 0.5)
	if _own_position:                             # otherwise the caller's tween owns position
		_a.position = _base_a + dir * pull
		_b.position = _base_b - dir * pull


# Un-tilt the bound cards when this FX is torn down (the side panel reuses the slots — a left-over
# rotation would freeze a card mid-wobble). The modal frees its cards with the FX, so this is a no-op
# there. Auras/link are our own children and die with us.
func _exit_tree() -> void:
	if _a != null and is_instance_valid(_a):
		_a.rotation = 0.0
		if _own_position:
			_a.position = _base_a
	if _b != null and is_instance_valid(_b):
		_b.rotation = 0.0
		if _own_position:
			_b.position = _base_b
