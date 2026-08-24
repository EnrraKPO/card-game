class_name DrawMutator
extends Mutator

# `draw` (Mutation §4): authored {"draw": {"count": int}}. Reads the deck's top from the
# world and asks that the card move to hand — one ContainerMoveRequest per card, the
# recipient being the drawing side. The deck's top is its first member (B22); a deck
# holding fewer than `count` yields the draws that exist.

var count: int = 0


func _init() -> void:
	kind = &"draw"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	var events: Array[Event] = []
	var deck: EntityContainer = recipient.get_container(&"deck")
	if deck == null:
		return events
	for i: int in count:
		if deck.members.is_empty():
			break
		var top: GameEntity = deck.members[0]
		events.append_array(MutationEngine.submit(
				ContainerMoveRequest.new(kind, plate.holder, top, recipient, &"hand")))
	return events
