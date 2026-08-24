class_name EngineProcedure
extends RefCounted

# The base of the engine's procedures (Mutation System Design §7). A procedure is the
# game's way of resolving one kind of happening into writes and events: a fixed part of
# the engine, stateless — all state lives in the world's facts — owning one request
# shape, its request paired with it by name.
#
# A procedure has two entrances, one body. Asked: a mutator issues the procedure's
# request; the procedure unpacks it and runs (resolve). Applied: a procedure,
# mid-resolution, runs another procedure directly, passing the parameters it computed
# and the request already in its hand (apply). Both entrances run the same body, produce
# the same events, stamp the same way — no request is minted on the applied path, so
# provenance stays singular.
#
# Every decision lives in a procedure; a primitive never decides. Where only a raw write
# happens, a procedure uses a WriteAuthority primitive; it applies another procedure
# only when the applied happening happens.
