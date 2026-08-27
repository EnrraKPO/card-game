class_name AutoResolver
extends TargetResolver

# The generic AutoResolver (Core System Design §4): the fallback for an effect
# authored without a targeting block, fixed at construction. It resolves as the target
# carried in context — the occasion's target — falling back to the Game where none is
# found. No conditions, nothing unknown: engagement answers from its resolution.


func _init() -> void:
	super._init([], null)


func resolve(plate: Plate) -> Array[GameEntity]:
	var carried: GameEntity = plate.occasion.target
	var elected: Array[GameEntity] = [carried if carried != null else plate.world().game]
	return elected


func engage(plate: Plate) -> Array[GameEntity]:
	return resolve(plate)
