class_name WeightedRandom
extends RefCounted

# Picks one entry from a weighted pool. `weight_fn` extracts the weight
# (float/int) from each entry — entries can be Dictionaries, Resources, or
# any object, as long as weight_fn knows how to read a weight from them.
# Falls back to the last entry on floating-point edge cases.
static func pick(rng: RandomNumberGenerator, entries: Array, weight_fn: Callable) -> Variant:
	var total := 0.0
	for e in entries:
		total += float(weight_fn.call(e))

	var roll: float = rng.randf() * total
	for e in entries:
		roll -= float(weight_fn.call(e))
		if roll <= 0.0:
			return e
	return entries.back()
