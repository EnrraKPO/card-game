class_name DrawMutator
extends Mutator

# `draw` (Mutation §4): authored {"draw": {"count": int}}. Reads the deck's top from the
# world and asks that the card move to hand — one DrawRequest per card, target the
# drawn card (A17: the entity being moved is the target, routed to its
# specific-purpose procedure); the recipient is the drawing side. The deck's top is its
# first member (B22); a deck holding fewer than `count` yields the draws that exist.
#
# count −1 is the machinery's sentinel (never authored): the turn-draw rule's form,
# reading the Game's `turn_draw` stat at issuance (Combat Frame §4).

var count: int = 0


func _init() -> void:
	kind = &"draw"


func _issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	var events: Array[Event] = []
	var deck: EntityContainer = recipient.get_container(&"deck")
	if deck == null:
		return events
	var asked: int = count if count >= 0 else roundi(plate.world().game.get_stat(&"turn_draw"))
	for i: int in asked:
		if deck.members.is_empty():
			break
		var top: GameEntity = deck.members[0]
		events.append_array(MutationEngine.submit(DrawRequest.new(kind, plate.holder, top)))
	return events
