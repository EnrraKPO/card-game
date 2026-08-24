class_name Mutator
extends RefCounted

# A mutator turns an intent into concrete requests, using the facts of the firing
# (Mutation System Design §4). A mutator is the ONLY thing that issues requests: one ask
# is one request, one mutation, one provenance — the mutator's kind. Internals are
# unbounded code: a mutator may read anything and reason however it likes before
# speaking; markup stays flat, and a new capability is a new mutator in code, never new
# authoring vocabulary.
#
# Lifecycle: stateless immutable instances — constructed once, at parse for an authored
# effect, in code for a machinery effect; holds only its authored parameters; every
# situational fact arrives on the plate. One instance is shared across card copies and
# simulated worlds.
#
# Contract: issue(plate, recipient) → events. The base appends the kind to every
# returned event (Core §8 accretion: a mutator its kind — NameEventData, role
# `mutator_kind`); the mutator object itself never travels.

var kind: StringName = &""


# The unique quality (Core §4): a unique kind runs once per delivery, before the
# per-recipient walk, with a null recipient; it appoints its own target from the plate.
# The conductor reads only this declaration.
func is_unique() -> bool:
	return false


func issue(plate: Plate, recipient: GameEntity) -> Array[Event]:
	var events: Array[Event] = _issue(plate, recipient)
	for event: Event in events:
		event.components.append(NameEventData.new(&"mutator_kind", kind))
	return events


func _issue(_plate: Plate, _recipient: GameEntity) -> Array[Event]:
	push_error("Mutator: a kind without an ask")
	return []
