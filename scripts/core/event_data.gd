class_name EventData
extends RefCounted

# The base of the typed component family (Core System Design §8): one class per shape of
# fact. A fact of an existing shape with a different purpose reuses the class — purpose
# is a name (the role), never a new shape. Concrete shapes: StatMutationEventData,
# NameEventData, RequestEventData (the request at hand, A19); the family grows one
# class per genuinely new shape. (EntityEventData left with its demotion — the event
# target is native in the core, A16.)
