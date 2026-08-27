class_name PoisonMutator
extends Mutator

# `poison` (Kind Rosters §3): the Poison status's periodic ask — damages the recipient
# per the holder's stacks, the damage carrying the poison kind (CONTENT_DICTIONARY's
# demand: "damages the unit carrying it, per its stacks; the damage carries the poison
# kind"). The plain damage mutator's authored amount is fixed; the stacks are a fact of
# the holding status, read at issuance — a new capability is a new mutator in code
# (Mutation §4). Authored "poison", no parameters. Concludes in a DamageRequest.


func _init() -> void:
	kind = &"poison"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	var stacks: int = roundi(plate.holder.get_stat(&"stacks"))
	if stacks <= 0:
		return []
	return MutationEngine.submit(DamageRequest.new(kind, plate.holder, recipient, stacks))
