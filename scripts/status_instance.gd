class_name StatusInstance
extends RefCounted

# A live Status on a CardInstance: its definition + remaining duration + stack count + the unit
# that applied it. Purely combat-runtime (CardInstances are rebuilt every fight), so it is never
# serialized. See StatusData (definition) and StatusEngine (the operator).

var data: StatusData
var remaining: int = -1           # rounds left; -1 = lasts the whole combat (never counts down)
var stacks: int = 1
var source: CardInstance = null   # who applied it (nullable; for future source-linked durations)


static func make(p_data: StatusData, p_remaining: int, p_stacks: int, p_source: CardInstance) -> StatusInstance:
	var si := StatusInstance.new()
	si.data = p_data
	si.remaining = p_remaining
	si.stacks = p_stacks
	si.source = p_source
	return si


# The headline number shown for this status: the stack COUNT for a count-decay status (e.g.
# poison's value), otherwise the remaining turns. A whole-combat status returns -1 (no number).
func count() -> int:
	return stacks if data.decay == StatusData.DECAY_STACKS else remaining
