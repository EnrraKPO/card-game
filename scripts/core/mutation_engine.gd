class_name MutationEngine
extends RefCounted

# The single entry point for every mutation in the game (Mutation System Design §7). The
# doorway is submit(request) — static; synchronous, returning the mutation's events.
# Requests are self-sufficient, so one doorway serves the live fight and every simulated
# world.
#
# The engine has its procedures fixed in code, as a class has its parts. Its ONE decision
# is handing each request to the procedure that claims its shape; every other decision is
# made before submission, by a mutator, or during resolution, by a procedure. A new
# happening enters as one new procedure and its request; nothing existing changes.
#
# The doorway refuses loudly: a request no procedure claims, or a null target where the
# verb requires one — every current verb requires one — is an error at submission, never
# a silent drop.


static func submit(request: EngineRequest) -> Array[Event]:
	if request.target == null:
		push_error("MutationEngine: request '%s' has a null target — refused"
				% _shape_label(request))
		return []
	if request is StatMutationRequest:
		return StatMutationProcedure.resolve(request)
	if request is StrikeRequest:
		return StrikeProcedure.resolve(request)
	if request is DamageRequest:
		return DamageProcedure.resolve(request)
	if request is StatusRequest:
		return StatusProcedure.resolve(request)
	if request is MoveRequest:
		return MoveProcedure.resolve(request)
	if request is DrawRequest:
		return DrawProcedure.resolve(request)
	if request is BuryRequest:
		return BuryProcedure.resolve(request)
	if request is PayCostRequest:
		return PayCostProcedure.resolve(request)
	push_error("MutationEngine: no procedure claims the shape '%s' — refused"
			% _shape_label(request))
	return []


static func _shape_label(request: EngineRequest) -> String:
	var script: Script = request.get_script()
	return script.get_global_name() if script != null else "EngineRequest"
