class_name MaterialBag
extends RefCounted

# A bag of crafting resources: a generic id→count store with safe add/spend. The meta
# economy's value object, held by ProfileData — kept separate so resource logic isn't
# tangled into the profile, and reusable if other layers ever want the same API.
# Conventions for ids live with the display helpers in Materials (scripts/materials.gd).

var _counts: Dictionary = {}


func count(id: String) -> int:
	return int(_counts.get(id, 0))


func add(id: String, n: int = 1) -> void:
	if n == 0:
		return
	_counts[id] = maxi(0, count(id) + n)


func add_many(rewards: Dictionary) -> void:
	for id: String in rewards:
		add(id, int(rewards[id]))


# Spends n of a material if affordable; returns whether the spend happened (guards the
# future Laboratory craft costs).
func spend(id: String, n: int) -> bool:
	if count(id) < n:
		return false
	_counts[id] = count(id) - n
	return true


func is_empty() -> bool:
	return _counts.is_empty()


func ids() -> Array:
	return _counts.keys()


func to_dict() -> Dictionary:
	return _counts.duplicate()


static func from_dict(d: Dictionary) -> MaterialBag:
	var bag := MaterialBag.new()
	bag._counts = d.duplicate()
	return bag
