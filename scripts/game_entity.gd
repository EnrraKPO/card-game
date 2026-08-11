class_name GameEntity
extends RefCounted

# A thing that exists in the game world — a unit (CardInstance), a board slot (BoardSlot).
# This shared base carries the two facts common to every entity: statuses can be pinned to
# it, and a target resolver can point at it (a resolution is an Array[GameEntity] —
# TARGETING_DESIGN.md §12.1; payloads tell kinds apart via delivery conditions, §4.3).
# As a status carrier it is deliberately DUMB: an address plus a filing cabinet. It holds the list below and
# answers lookups over it — nothing more. Every rule of status BEHAVIOR (application/stacking,
# ticking, decay, expiry) lives in the status definitions and StatusEngine, the one operator;
# a carrier has zero say. Application therefore has no carrier method at all — callers go to
# StatusEngine.apply(carrier, ...). See StatusData / StatusInstance / StatusEngine.

# Live Statuses pinned to this carrier (Array[StatusInstance]) — runtime buffs/debuffs/periodic
# effects applied during combat and removed on a timer. Never serialized (rebuilt each fight).
# Their STANDING effects fold into get_attribute via LiveEffects; TRIGGERED ones fire via
# the rules layer's dispatch.
var statuses: Array = []


func find_status(status_id: String) -> StatusInstance:
	for si: StatusInstance in statuses:
		if si.data.id == status_id:
			return si
	return null


# The removal writes are FILING, not rules — truth about expiry lives in the status itself
# (StatusEngine.is_expired, pull-checked on every read); dropping the entry is hygiene.
# Nothing to invalidate: every LiveEffects read derives fresh (no-cache ruling 2026-08-11).
func remove_status(status_id: String) -> void:
	statuses = statuses.filter(func(si: StatusInstance) -> bool: return si.data.id != status_id)


func clear_statuses() -> void:
	statuses.clear()
