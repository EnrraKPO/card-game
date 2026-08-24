class_name Decision
extends RefCounted

# The decision of a target resolver (Core System Design §4): conditions narrow the world
# to eligible candidates; the decision picks among them. The authored mechanisms:
# nearest, random, stat-ranked, hand-pick, the occasion's targets; machinery adds the
# Game default (Core §4, "no resolver authored") and, at the main action's phase, the
# attack preference (Core §3).
#
# The two phases live here. `resolve` is side-effect-free: it narrows as far as
# determinism reaches, nothing committed — a deterministic decision answers its election,
# an undecided one answers the eligible field. `engage` is committing: unknowns settle
# once, in the live flow — rolls draw from the world's seeded rng, the picker picks.
# Engagement is issued uniformly; a decision with nothing unknown answers from its
# resolution. Stateless immutable, like every parsed part.


func resolve(_plate: Plate, candidates: Array[GameEntity]) -> Array[GameEntity]:
	return candidates


# Coroutine (the hand-pick consults the player). A decision with nothing unknown answers
# from its resolution.
func engage(plate: Plate, candidates: Array[GameEntity]) -> Array[GameEntity]:
	@warning_ignore("redundant_await")
	await null
	return resolve(plate, candidates)
