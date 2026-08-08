class_name TargetingBishop
extends TargetingStrategy

# Hunts the most wounded enemy — finishes off weakened units.
# Distance is used as a tiebreaker when HP is equal.
func find_target(places: LocationManager, attacker: CardInstance) -> CardInstance:
	var all := sorted_by_dist(places, attacker)
	if all.is_empty():
		return null
	var from := at(places, attacker)
	all.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		if a.current_health != b.current_health:
			return a.current_health < b.current_health
		return dist(from, at(places, a)) < dist(from, at(places, b))
	)
	return all[0]
