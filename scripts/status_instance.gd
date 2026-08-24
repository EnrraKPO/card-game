class_name StatusInstance
extends RefCounted

# A live Status pinned to a carrier (a unit, later a slot — see LegacyGameEntity): its definition +
# remaining duration + stack count + the unit that applied it. Purely combat-runtime (carriers are
# rebuilt every fight), so it is never serialized. See StatusData (definition) and StatusEngine
# (the operator — the status and its engine own ALL behavior; the carrier just files it).

var data: StatusData
var remaining: int = -1           # rounds left; -1 = lasts the whole combat (never counts down)
var stacks: int = 1
var source: CardInstance = null   # who applied it (nullable; for future source-linked durations)

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
static func copied(si: StatusInstance, carrier: LegacyGameEntity, remap: Dictionary) -> StatusInstance:
	var copy := StatusInstance.new()
	copy.data = si.data
	copy.remaining = si.remaining
	copy.stacks = si.stacks
	copy.source = CardInstance.copied(si.source, remap)
	copy.bind_carrier(carrier)
	return copy


# This status still exists while its decay state says so. Pull-checked on every read, so a
# not-yet-removed expired instance is already inert.
func exists() -> bool:
	return not StatusEngine.is_expired(self)


func bind_carrier(carrier: LegacyGameEntity) -> void:
	_carrier_ref = weakref(carrier)


# The BLIND UPWARD CHANNEL: the rules layer tells this container something it carries just
# genuinely fired; how to react is entirely this container's business — an intercept-decay
# status (Barrier) spends a charge per real rewrite (a rewrite that changed nothing never
# reaches here, so a whiff spends nothing). Caller-less while the effect layer is razed;
# the rebuilt InterceptorEffect delivery calls it (TARGETING_DESIGN.md §8).
func fired(_source: Variant) -> void:
	if data.decay != StatusData.DECAY_INTERCEPT:
		return
	stacks -= 1
	if stacks > 0 or _carrier_ref == null:
		return   # spent-out but unbound instances stay inert via pull validity (exists())
	var carrier: LegacyGameEntity = _carrier_ref.get_ref()
	if carrier != null:
		carrier.remove_status(data.id)   # prompt removal = hygiene (the pip disappearing)


# The headline number shown for this status: the stack COUNT for a count-decay status (poison's
# value, a Barrier's remaining charges), otherwise the remaining turns. A whole-combat status
# returns -1 (no number).
func count() -> int:
	if data.decay == StatusData.DECAY_STACKS or data.decay == StatusData.DECAY_INTERCEPT:
		return stacks
	return remaining
