class_name EnemyCommander
extends Commander

# The slice's enemy commander (Combat Frame §5): the span's servant behind the same ask
# vocabulary the player uses. It plays what it can afford onto its own half — the first
# payable card, the first eligible slot — and yields when nothing more lands. The
# personality-driven encounter engine re-enters at the parity pass, rebuilt on the new
# core (B34).
#
# While this commander speaks, the world's picker answers ITS asks — the pick belongs to
# whoever commands — so the span swaps in an auto-picker and restores the player's on
# yield.


# Picks the first candidate: deterministic, and enough for the slice's fixed fight.
class AutoPicker extends TargetPicker:
	func pick(candidates: Array[GameEntity], _plate: Plate) -> GameEntity:
		@warning_ignore("redundant_await")
		await null
		return candidates[0] if not candidates.is_empty() else null


func command(world: World) -> void:
	var side: Side = world.enemy_side()
	var saved: TargetPicker = world.picker
	world.picker = AutoPicker.new()
	while true:
		var mana_before: float = side.get_stat(&"mana")
		var asked := false
		for member: GameEntity in side.get_container(&"hand").members.duplicate():
			var card := member as Card
			if card != null and card.payable():
				await world.cascade.fire(Event.new(&"play", card, world.game))
				asked = true
				break
		# Yield when nothing was asked, or the ask committed nothing (a declined or
		# empty election) — otherwise an unplayable-but-payable card would loop forever.
		if not asked or side.get_stat(&"mana") == mana_before:
			break
	world.picker = saved
