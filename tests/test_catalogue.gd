extends TestCase

# The catalogue conversion (AMENDMENTS A7: "the existing catalogue converts at the
# parity migration"): every loaded CardData maps to an A7 envelope, registers, and
# builds — kind, birth facts (building, king, elements), and stats carried true. The
# old files' dead effect/ability reference strings do not convert (their definitions
# died at the A11 swap); the stubbed real-content fight assembles and passes Genesis.


func suite_name() -> String:
	return "the catalogue conversion"


func run() -> void:
	var cards: Array = CardData.all()
	check(cards.size() >= 700, "the catalogue is loaded (%d cards)" % cards.size())

	ContentLibrary.clear()
	var registered := 0
	for envelope: Dictionary in CardCatalogue.envelopes():
		if ContentLibrary.register_card(envelope):
			registered += 1
		else:
			check(false, "card '%s' refuses to register" % envelope.get("id"))
	check_eq(registered, cards.size(), "every catalogue card registers")

	var world := World.new(1)
	var side: Side = world.player_side()
	var built := 0
	for entry: Variant in cards:
		var data: CardData = entry
		var card: Card = ContentLibrary.build_card(StringName(data.id), side)
		if card == null:
			check(false, "card '%s' refuses to build" % data.id)
			continue
		built += 1
		var want_spell := data.card_type == CardData.CardType.SPELL
		if (card is Spell) != want_spell:
			check(false, "card '%s' builds the wrong kind" % data.id)
		if card.elements.size() != data.elements.size():
			check(false, "card '%s' loses its elements" % data.id)
		if card.get_stat(&"cost") != float(data.cost):
			check(false, "card '%s' loses its cost" % data.id)
		if card is Unit:
			var unit: Unit = card
			if unit.is_building != data.is_building():
				check(false, "unit '%s' mistakes its building fact" % data.id)
			if unit.is_king != data.is_king:
				check(false, "unit '%s' mistakes its king fact" % data.id)
			if unit.get_stat(&"attack") != float(data.attack) \
					or unit.get_stat(&"health") != float(data.health) \
					or unit.get_stat(&"max_health") != float(data.health) \
					or unit.get_stat(&"speed") != float(data.speed) \
					or unit.get_stat(&"shield") != float(data.shield):
				check(false, "unit '%s' loses a stat" % data.id)
	check_eq(built, cards.size(), "every catalogue card builds")

	# Spot checks against the authored numbers.
	var pawn: Card = ContentLibrary.build_card(&"air_air_pawn", side)
	check(pawn is Unit and pawn.get_stat(&"attack") == 1.0 and pawn.get_stat(&"health") == 3.0
			and pawn.get_stat(&"speed") == 9.0, "the Wind Pawn's numbers carry")
	check(pawn != null and pawn.elements == ([&"air", &"air"] as Array[StringName]),
			"the Wind Pawn's composition is stamped")
	var king: Card = ContentLibrary.build_card(&"king", side)
	check(king is Unit and (king as Unit).is_king and king.get_stat(&"shield") == 5.0,
			"the King bears his fact and his shield")
	var spell_found := false
	for entry: Variant in cards:
		var data: CardData = entry
		if data.card_type == CardData.CardType.SPELL:
			var spell: Card = ContentLibrary.build_card(StringName(data.id), side)
			check(spell != null and not spell.bears_stat(&"attack"),
					"a spell ('%s') bears no unit stats" % data.id)
			spell_found = true
			break
	check(spell_found, "the catalogue derives spells")

	# The stubbed real-content fight assembles whole and passes Genesis.
	var fight: Dictionary = FightScreen.real_fight()
	check(not fight.is_empty(), "the stub fight assembles")
	if fight.is_empty():
		return
	ContentLibrary.clear()
	for envelope: Variant in (fight.content as Dictionary).cards:
		if not ContentLibrary.register_card(envelope):
			check(false, "the stub fight's content refuses '%s'" % (envelope as Dictionary).get("id"))
	for envelope: Variant in (fight.content as Dictionary).get("statuses", []):
		if not ContentLibrary.register_status(envelope):
			check(false, "the stub fight's statuses refuse '%s'" % (envelope as Dictionary).get("id"))
	for envelope: Variant in (fight.content as Dictionary).get("relics", []):
		if not ContentLibrary.register_relic(envelope):
			check(false, "the stub fight's relics refuse '%s'" % (envelope as Dictionary).get("id"))
	var stage := World.new(int(fight.seed))
	check(Genesis.setup(stage, fight.player, fight.enemy), "Genesis accepts the stub fight")
	var seated: Array[GameEntity] = stage.player_side().get_container(&"relics").members
	check(seated.size() == 1 and seated[0].id == &"contagion_stone",
			"the stub fight seats the player's test relic")
	check(stage.player_side().get_container(&"deck").members.size()
			+ stage.player_side().get_container(&"hand").members.size() == 12,
			"the player's stub deck deals whole")
