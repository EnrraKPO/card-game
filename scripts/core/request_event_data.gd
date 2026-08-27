class_name RequestEventData
extends EventData

# The request at hand, stamped whole (Core §8, Mutation §7): every event
# originated from a mutation request path carries the request it was minted under.
# The stamp happens at the minting station — a procedure or the WriteAuthority, each
# holding the request as context — so the applied path stamps the applying request
# and provenance stays singular (Mutation §7). Readers reach the kind as
# request.mutator_kind, and deeper request-reading consults the request's typed
# members through its concrete shape.

var request: EngineRequest = null


func _init(p_request: EngineRequest) -> void:
	request = p_request
