class_name StatusInstance
extends RefCounted

# A live Status on a CardInstance: its definition + remaining duration + stack count + the unit
# that applied it. Purely combat-runtime (CardInstances are rebuilt every fight), so it is never
# serialized. See StatusData (definition) and StatusEngine (the operator).

var data: StatusData
var remaining: int = -1           # rounds left; -1 = lasts the whole combat (never counts down)
var stacks: int = 1
var source: CardInstance = null   # who applied it (nullable; for future source-linked durations)

# Trackers bound to this instance, one per standing effect, created lazily on first read
# (the go-live moment) and never rebuilt — a tracker's death is one-way. See EffectTracker.
var _trackers: Dictionary = {}


static func make(p_data: StatusData, p_remaining: int, p_stacks: int, p_source: CardInstance) -> StatusInstance:
	var si := StatusInstance.new()
	si.data = p_data
	si.remaining = p_remaining
	si.stacks = p_stacks
	si.source = p_source
	return si


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


# The headline number shown for this status: the stack COUNT for a count-decay status (poison's
# value, a Barrier's remaining charges), otherwise the remaining turns. A whole-combat status
# returns -1 (no number).
func count() -> int:
	if data.decay == StatusData.DECAY_STACKS or data.decay == StatusData.DECAY_INTERCEPT:
		return stacks
	return remaining
