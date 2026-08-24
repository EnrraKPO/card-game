class_name Condition
extends RefCounted

# A condition is a predicate: it asks ONE question of its inputs and answers true or
# false. It writes nothing and decides nothing beyond its answer (Core System Design §9).
#
# This base carries what all conditions author alike: the negate member and the
# stateless-immutable lifecycle — a condition is constructed at parse, holds only its
# authored members, and one instance is shared across card copies and simulated worlds;
# anything needing memory is a world fact. The two families beneath it declare the
# subject type and thereby the signature: EntityCondition tests a GameEntity,
# EventDataCondition tests an Event. Concrete kinds derive within a family and implement
# the question in its natural sense; the machinery inverts the answer where negate is
# set — over an absent component the inverted answer is true.

var negate: bool = false
