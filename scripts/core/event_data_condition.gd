class_name EventDataCondition
extends Condition

# The family whose subject is an Event (Core §9). The trigger hands it the occasion; it
# carries no route and reads components by shape itself (Core §8). A condition asking of
# an absent component evaluates false — inverted to true where negate is set.


func holds(plate: Plate, subject: Event) -> bool:
	return _answer(plate, subject) != negate


func _answer(_plate: Plate, _subject: Event) -> bool:
	push_error("EventDataCondition: a kind without a question")
	return false
