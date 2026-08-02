class_name StatusCarrier
extends RefCounted

# A thing statuses can be pinned to — a unit today (CardInstance), a board slot later. The
# carrier is deliberately DUMB: an address plus a filing cabinet. It holds the list below and
# answers lookups over it — nothing more. Every rule of status BEHAVIOR (application/stacking,
# ticking, decay, expiry) lives in the status definitions and StatusEngine, the one operator;
# a carrier has zero say. Application therefore has no carrier method at all — callers go to
# StatusEngine.apply(carrier, ...). See StatusData / StatusInstance / StatusEngine.

# Live Statuses pinned to this carrier (Array[StatusInstance]) — runtime buffs/debuffs/periodic
# effects applied during combat and removed on a timer. Never serialized (rebuilt each fight).
# Their STANDING effects fold into get_attribute via LiveEffects; TRIGGERED ones fire via
# EffectSystem.trigger.
var statuses: Array = []


func find_status(status_id: String) -> StatusInstance:
	for si: StatusInstance in statuses:
		if si.data.id == status_id:
			return si
	return null


# The removal writes are FILING, not rules — truth about expiry lives in the status itself
# (StatusEngine.is_expired, pull-checked on every read); dropping the entry is hygiene. The
# LiveEffects invalidation keeps grant-carrying statuses honest for direct callers.
func remove_status(status_id: String) -> void:
	statuses = statuses.filter(func(si: StatusInstance) -> bool: return si.data.id != status_id)
	LiveEffects.invalidate_compositions()


func clear_statuses() -> void:
	statuses.clear()
	LiveEffects.invalidate_compositions()
