extends TestCase

# The run→fight composition (RunFight): the run's deck, the encounter's power-scaled
# enemy, and the King at its persisted health become the FightScreen.next_fight
# dictionary. A definition the catalogue does not hold registers as a variant envelope
# under "{base}~{n}" (B40), one seat per distinct definition; everything the composition
# states must register and pass Genesis whole.


func suite_name() -> String:
	return "the run's fight composition"


func run() -> void:
	var base_id := "air_air_pawn"
	var base: CardData = CardData.get_card(base_id)
	check(base != null, "the probe card exists in the catalogue")

	var run_state := RunData.new()
	run_state.king_id = "king"
	run_state.king_damage = 7
	run_state.relics = ["contagion_stone", "no_such_relic"]
	var plain := DeckCard.make(base_id)
	var bumped := DeckCard.make(base_id)
	bumped.bump("attack", 2)
	var bumped_twin := DeckCard.make(base_id)
	bumped_twin.bump("attack", 2)
	run_state.deck = [plain, bumped, bumped_twin]

	var enc := EncounterData.new()
	enc.enemy_king = "king"
	enc.enemy_deck.assign([base_id, base_id])
	enc.power = 4.0

	var fight: Dictionary = RunFight.compose(run_state, enc)
	check(not fight.is_empty(), "the composition yields a fight")

	# The player's deck: the plain entry sits on the catalogue seat; the two identical
	# bumped entries share ONE variant seat carrying the folded stats.
	var deck: Array = (fight.player as Dictionary).deck
	check_eq(deck.size(), 3, "every deck entry is seated")
	check_eq(String(deck[0]), base_id, "an unmodified entry keeps its catalogue seat")
	check_eq(String(deck[1]), base_id + "~1", "a modified entry seats as a variant")
	check_eq(String(deck[2]), String(deck[1]), "identical definitions share one seat")
	var seats: Dictionary = {}
	for envelope: Dictionary in (fight.content as Dictionary).cards:
		seats[String(envelope.id)] = envelope
	var bumped_seat: Dictionary = seats.get(base_id + "~1", {})
	check(not bumped_seat.is_empty(), "the variant envelope is in the fight's content")
	check_eq(int((bumped_seat.stats as Dictionary).attack), base.attack + 2,
			"the variant carries the folded stats")

	# The enemy: deck and captain grown by the encounter's power — each envelope states
	# the scaled numbers, seated apart from the player's unscaled cards.
	var scaled: CardData = CardData.scaled(base, enc.power)
	check(scaled.health != base.health, "the probe power actually scales")
	var enemy_deck: Array = (fight.enemy as Dictionary).deck
	check_eq(enemy_deck.size(), 2, "every enemy entry is seated")
	check(String(enemy_deck[0]) != base_id, "a scaled enemy card seats apart from the base")
	var enemy_seat: Dictionary = seats.get(String(enemy_deck[0]), {})
	check_eq(int((enemy_seat.stats as Dictionary).attack), scaled.attack,
			"the enemy envelope states the scaled attack")
	check_eq(int((enemy_seat.stats as Dictionary).health), scaled.health,
			"the enemy envelope states the scaled health")
	var captain_id := String(((fight.enemy as Dictionary).units[0] as Dictionary).id)
	var captain_seat: Dictionary = seats.get(captain_id, {})
	check(bool(captain_seat.get("king", false)), "the captain envelope bears the king fact")

	# The King enters at the run's persisted health: max through the run's modifiers,
	# minus the carried damage.
	var king_id := String(((fight.player as Dictionary).units[0] as Dictionary).id)
	var king_seat: Dictionary = seats.get(king_id, {})
	check_eq(int((king_seat.stats as Dictionary).health), run_state.king_health(),
			"the King envelope states the persisted health")
	check_eq(int((king_seat.stats as Dictionary).max_health), run_state.king_max_health(),
			"the King envelope states the run's max health")

	# The run's relics: only an id with an authored core envelope enters the fight.
	var fight_relics: Array = (fight.player as Dictionary).relics
	check_eq(fight_relics.size(), 1, "only enveloped relics enter the fight")
	check_eq(String(fight_relics[0]), "contagion_stone", "the enveloped relic is seated")

	# The whole composition registers and passes Genesis: the fielded King stands at the
	# persisted health.
	ContentLibrary.clear()
	for envelope: Dictionary in (fight.content as Dictionary).cards:
		if not ContentLibrary.register_card(envelope):
			check(false, "envelope '%s' refuses to register" % envelope.get("id"))
	for envelope: Variant in (fight.content as Dictionary).statuses:
		ContentLibrary.register_status(envelope)
	for envelope: Variant in (fight.content as Dictionary).relics:
		ContentLibrary.register_relic(envelope)
	var world := World.new(int(fight.seed))
	check(Genesis.setup(world, fight.player, fight.enemy), "the composed fight passes Genesis")
	var throne: Slot = world.board_manager.slot_at(Vector3i(0, 1, 0))
	var king_unit: Unit = throne.get_container(&"slotted_unit").members[0] as Unit
	check(king_unit != null and king_unit.is_king, "the King stands on its seat")
	check_eq(roundi(king_unit.get_stat(&"health")), run_state.king_health(),
			"the fielded King wears the persisted health")
	ContentLibrary.clear()
