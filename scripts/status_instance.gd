class_name StatusInstance
extends RefCounted

# A live Status pinned to a carrier (a unit, later a slot — see StatusCarrier): its definition +
# remaining duration + stack count + the unit that applied it. Purely combat-runtime (carriers are
# rebuilt every fight), so it is never serialized. See StatusData (definition) and StatusEngine
# (the operator — the status and its engine own ALL behavior; the carrier just files it).

var data: StatusData
var remaining: int = -1           # rounds left; -1 = lasts the whole combat (never counts down)
var stacks: int = 1
var source: CardInstance = null   # who applied it (nullable; for future source-linked durations)

# Trackers bound to this instance, one per standing effect, created lazily on first read
# (the go-live moment) and never rebuilt — a tracker's death is one-way. See EffectTracker.
var _trackers: Dictionary = {}
# The carrier this status is pinned to — WEAK (the carrier files the statuses; a strong
# back-ref would cycle). Bound by StatusEngine.apply; unbound instances (tests building
# state by hand) just skip prompt removal — pull validity keeps them correct regardless.
var _carrier_ref: WeakRef = null


static func make(p_data: StatusData, p_remaining: int, p_stacks: int, p_source: CardInstance) -> StatusInstance:
	var si := StatusInstance.new()
	si.data = p_data
	si.remaining = p_remaining
	si.stacks = p_stacks
	si.source = p_source
	return si


# Deep-copy for world snapshots (see CombatWorld.copy): per-instance state duplicated, the
# immutable definition shared, unit references resolved through the snapshot's identity remap.
# Trackers are RE-BOUND to the copy rather than duplicated — a duplicated tracker's weak host
# ref would keep watching the ORIGINAL status — and since every tracker kind derives
# valid()/intensity() from its host at read time, a fresh binding reproduces the original's
# state exactly, including its "already went live" identity (the effect keys carry over).
static func copied(si: StatusInstance, carrier: StatusCarrier, remap: Dictionary) -> StatusInstance:
	var copy := StatusInstance.new()
	copy.data = si.data
	copy.remaining = si.remaining
	copy.stacks = si.stacks
	copy.source = CardInstance.copied(si.source, remap)
	copy.bind_carrier(carrier)
	for e: Effect in si._trackers:
		copy._trackers[e] = EffectTracker.bind(e.tracker_spec, copy)
	return copy


# The EffectTracker existence probe (duck-typed — see EffectTracker.Container): this
# status still exists while its decay state says so. Pull-checked on every read, so a
# not-yet-removed expired instance is already inert.
func exists() -> bool:
	return not StatusEngine.is_expired(self)


# The lifetime authority for one of this status's standing effects, bound to this
# instance. The binding is resolved privately by the tracker (design hard rule: neither
# the effect nor the container knows the other's type).
func tracker_for(e: Effect) -> EffectTracker:
	if not _trackers.has(e):
		_trackers[e] = EffectTracker.bind(e.tracker_spec, self)
	return _trackers[e]


func bind_carrier(carrier: StatusCarrier) -> void:
	_carrier_ref = weakref(carrier)


# The BLIND UPWARD CHANNEL (EFFECT_SYSTEM_DESIGN.md §2.2): dispatch tells this container
# one of its effects just genuinely fired; how to react is entirely this container's
# business — an intercept-decay status (Barrier) spends a charge per real rewrite (a
# rewrite that changed nothing never reaches here, so a whiff spends nothing). The effect
# never knows WHAT it signalled.
func fired(_e: Effect) -> void:
	if data.decay != StatusData.DECAY_INTERCEPT:
		return
	stacks -= 1
	if stacks > 0 or _carrier_ref == null:
		return   # spent-out but unbound instances stay inert via pull validity (exists())
	var carrier: StatusCarrier = _carrier_ref.get_ref()
	if carrier != null:
		carrier.remove_status(data.id)   # prompt removal = hygiene (the pip disappearing)


# The headline number shown for this status: the stack COUNT for a count-decay status (poison's
# value, a Barrier's remaining charges), otherwise the remaining turns. A whole-combat status
# returns -1 (no number).
func count() -> int:
	if data.decay == StatusData.DECAY_STACKS or data.decay == StatusData.DECAY_INTERCEPT:
		return stacks
	return remaining
