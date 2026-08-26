class_name EngineRequest
extends RefCounted

# What a mutator issues, and what the engine receives (Mutation System Design §6). The
# facts changing is the mutation; this object is the asking — minting a request is the
# act of asking, and only mutators mint. A dumb data record: this base carries the
# context bundle common to every request; one subclass per procedure, named by the
# happening it asks for, carries that procedure's parameters as typed members.
#
# A request is complete at construction: context is stamped at issuance and travels
# unmodified; a null context slot states that the party genuinely does not exist —
# never "unknown." The context bundle is a floor.

# The manner of the asking — the kind IS the provenance.
var mutator_kind: StringName = &""

# The holder it came from.
var source: GameEntity = null

# The target carried from context, until the mutator appoints a new one (A16).
var target: GameEntity = null


func _init(p_mutator_kind: StringName, p_source: GameEntity, p_target: GameEntity) -> void:
	mutator_kind = p_mutator_kind
	source = p_source
	target = p_target
