class_name TargetingQueen
extends TargetingStrategy

# Neutralises the greatest threat — always attacks the highest-ATK enemy.
# Distance is used as a tiebreaker when ATK is equal.
func find_target(places: LocationManager, attacker: CardInstance) -> CardInstance:
	var all := sorted_by_dist(places, attacker)
	if all.is_empty():
		return null
	var from := at(places, attacker)
	all.sort_custom(func(a: CardInstance, b: CardInstance) -> bool:
		var aa := a.get_attribute("attack")
		var ba := b.get_attribute("attack")
		if aa != ba:
			return aa > ba
		return dist(from, at(places, a)) < dist(from, at(places, b))
	)
	return all[0]
