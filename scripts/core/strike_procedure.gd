class_name StrikeProcedure
extends EngineProcedure

# Resolves a strike (Mutation System Design §7): dodge, crit, amount read from the
# striker's attack; a connecting strike applies damage. The striker is the source.
#
# The pipeline, fixed: dodge → (interception — out of frame, slot reserved) → crit →
# damage.
#
# The numbers are stats of the Game entity — per mechanic: base, speed rating,
# difference rating, cap; plus the crit multiplier and its cap. Rolls draw from the
# world's seeded rng, dodge first, in pipeline order.


# The chance formula, shared by dodge and crit: chance = base + own Speed × speed rating
# + difference rating × max(0, Speed difference), capped. The difference term is
# one-sided: only a positive difference contributes. Values are percent.
static func chance(base: float, own_speed: float, speed_rating: float,
		difference_rating: float, speed_difference: float, cap: float) -> float:
	return minf(base + own_speed * speed_rating
			+ difference_rating * maxf(0.0, speed_difference), cap)


static func resolve(request: StrikeRequest) -> Array[Event]:
	var striker: GameEntity = request.source
	var defender: GameEntity = request.target
	if striker == null:
		push_error("StrikeProcedure: a strike with no striker — refused")
		return []
	var world: World = striker.world
	var game: Game = world.game
	var events: Array[Event] = []
	var striker_speed: float = striker.get_stat(&"speed")
	var defender_speed: float = defender.get_stat(&"speed")

	# Dodge rolls first, from the defender (difference = defender minus attacker). A
	# dodge ends the strike — no damage, no crit. Buildings never dodge.
	var defender_is_building: bool = defender is Unit and (defender as Unit).is_building
	if not defender_is_building:
		var dodge_chance: float = chance(game.get_stat(&"dodge_base"), defender_speed,
				game.get_stat(&"dodge_speed_rating"), game.get_stat(&"dodge_difference_rating"),
				defender_speed - striker_speed, game.get_stat(&"dodge_cap"))
		if world.rng.randf() * 100.0 < dodge_chance:
			# The source is mechanical (A15): the strike's source; the dodger is the
			# event's native target (A16).
			var dodged := Event.new(&"dodged", request.source, defender)
			dodged.components.append(NameEventData.new(&"mutator_kind", request.mutator_kind))
			events.append(dodged)
			world.outlet.cue(&"dodge", defender, 0.0)   # its cue at commit (MSD s10)
			return events

	var amount: int = roundi(striker.get_stat(&"attack"))

	# Crit rolls only on a connecting strike whose damage, after mitigation, is above
	# zero — the shield would not absorb it whole. It rolls from the attacker
	# (difference = attacker minus defender); buildings crit and are crit normally.
	if float(amount) - defender.get_stat(&"shield") > 0.0:
		var crit_chance: float = chance(game.get_stat(&"crit_base"), striker_speed,
				game.get_stat(&"crit_speed_rating"), game.get_stat(&"crit_difference_rating"),
				striker_speed - defender_speed, game.get_stat(&"crit_cap"))
		if world.rng.randf() * 100.0 < crit_chance:
			var multiplier: float = minf(game.get_stat(&"crit_multiplier"),
					game.get_stat(&"crit_multiplier_cap"))
			amount = roundi(float(amount) * multiplier)
			var crit := Event.new(&"crit", request.source, defender)
			crit.components.append(NameEventData.new(&"mutator_kind", request.mutator_kind))
			events.append(crit)
			world.outlet.cue(&"crit", defender, 0.0)   # its cue at commit (MSD s10)

	# Damage happens inside a connecting strike, so the strike procedure applies the
	# damage procedure — application stays inside the one mutation.
	events.append_array(DamageProcedure.apply(defender, amount, request))
	return events
