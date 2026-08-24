class_name EntityContainer
extends RefCounted

# The bible's one Container class for every use (Core System Design §2). Named
# EntityContainer because Godot's native Container (a Control) takes the bare name —
# BRIEFS.html B1. Members exactly as ruled: owner (GameEntity), name (StringName), and
# members (ordered Array[GameEntity]).
#
# It accepts any GameEntity; membership legality is enforced by the procedures that write
# it. The membership primitives (WriteAuthority.insert / remove) are the ONLY writers of
# `members`, and they maintain each housed entity's back-reference on every write.
#
# The `name` member duplicates the owning entity's container-map key; both are set here,
# once, at construction — the map never renames a container.
#
# The owner reference is weak: the owner's container map holds this object strongly, so a
# strong owner reference would cycle (established weak-reference discipline, §2).

var _owner_ref: WeakRef = null

var owner: GameEntity:
	get: return _owner_ref.get_ref() if _owner_ref != null else null

var name: StringName = &""

var members: Array[GameEntity] = []


func _init(p_owner: GameEntity, p_name: StringName) -> void:
	_owner_ref = weakref(p_owner)
	name = p_name
