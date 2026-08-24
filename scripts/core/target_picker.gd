class_name TargetPicker
extends RefCounted

# The world's picker seam (Core §4: "hand-pick's decision consults the player"). The live
# world's picker consults the player through the interaction layer at the reconnection
# phase; this base declines every ask — the simulated world's picker as-is, and a
# declined pick yields an empty election.
#
# `pick` is a coroutine: the live picker awaits the player.


func pick(_candidates: Array[GameEntity], _plate: Plate) -> GameEntity:
	@warning_ignore("redundant_await")
	await null
	return null
