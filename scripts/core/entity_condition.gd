class_name EntityCondition
extends Condition

# The family whose subject is a GameEntity (Core §9). In a resolver seat, the subject is
# each candidate; in a trigger seat, the entities the entry's route yields.


# The machinery's read: the kind's natural answer, inverted where negate is set.
func holds(plate: Plate, subject: GameEntity) -> bool:
	return _answer(plate, subject) != negate


# The one question, in its natural sense. Overridden by every concrete kind.
func _answer(_plate: Plate, _subject: GameEntity) -> bool:
	push_error("EntityCondition: a kind without a question")
	return false
