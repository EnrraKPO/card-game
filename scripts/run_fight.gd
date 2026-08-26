class_name RunFight
extends RefCounted

# The run's fight, stated: composes the FightScreen.next_fight dictionary from the
# current run and the map's encounter — the seam the old combat screen's deck, scaling,
# and king bands re-terminate on (their old solutions: _init_player_deck /
# _init_enemy_deck / place_kings, a9af8d6^).
#
# The fight's cards are the converted catalogue (CardCatalogue) plus a VARIANT ENVELOPE
# for every card this fight fields under a definition the catalogue does not hold (B40):
# a deck entry modified by its override or charms (DeckCard.effective_data), an enemy
# card grown by the encounter's power (CardData.scaled — the old screen's scaling band),
# the player King entering at the run's persisted health (king persistence: the King's
# health is the run's life total). A variant registers under "{base id}~{n}";
# presentation resolves the authored seat — art, locale, chess pieces — by the base half
# (CardViewModel._authored_face).
#
# Statuses and relics ride the slice file's authored envelopes until they get a
# catalogue road of their own (the standing borrow — see FightScreen.real_fight); the
# run's relics enter the fight only where such an envelope exists for their id. The
# rest stay run-level facts whose combat half arrives with that road.


static func compose(run: RunData, enc: EncounterData) -> Dictionary:
	if run == null or enc == null:
		return {}
	var cards: Array[Dictionary] = CardCatalogue.envelopes()
	var base_seats: Dictionary = {}   # base id → its catalogue envelope
	for seat: Dictionary in cards:
		base_seats[String(seat.id)] = seat
	var variants: Dictionary = {}     # base id → Array[Dictionary] of allocated variants

	# The player's deck: every entry's effective definition — override and charms folded
	# in — the King excluded (it enters fielded below, never as a deck card).
	var deck: Array[String] = []
	for entry: Variant in run.deck:
		var deck_card := entry as DeckCard
		if deck_card == null:
			continue
		var data: CardData = deck_card.effective_data()
		if data == null or data.is_king:
			continue
		deck.append(_seat(cards, base_seats, variants, CardCatalogue.envelope(data)))

	# The enemy's deck and captain, grown by the encounter's power.
	var enemy_deck: Array[String] = []
	for id: Variant in enc.enemy_deck:
		var data: CardData = CardData.scaled(CardData.get_card(String(id)), enc.power)
		if data == null or data.is_king:
			continue
		enemy_deck.append(_seat(cards, base_seats, variants, CardCatalogue.envelope(data)))
	var captain: CardData = CardData.scaled(CardData.get_card(enc.enemy_king), enc.power)
	if captain == null:
		push_error("RunFight: the encounter's captain '%s' is not in the catalogue" % enc.enemy_king)
		return {}
	var captain_id: String = _seat(cards, base_seats, variants, CardCatalogue.envelope(captain))

	# The player King enters at the run's persisted health: full max — through the run's
	# modifiers — minus the damage carried over. The fight's ending writes the damage back
	# (FightScreen).
	var king: CardData = CardData.get_card(run.king_id)
	if king == null:
		push_error("RunFight: the run's King '%s' is not in the catalogue" % run.king_id)
		return {}
	var king_envelope: Dictionary = CardCatalogue.envelope(king)
	(king_envelope.stats as Dictionary)["health"] = run.king_health()
	(king_envelope.stats as Dictionary)["max_health"] = run.king_max_health()
	var king_id: String = _seat(cards, base_seats, variants, king_envelope)

	# The authored status and relic envelopes (the slice-file borrow), and the run relics
	# that have a seat among them.
	var slice_content: Dictionary = FightScreen.slice_fight().get("content", {})
	var relic_envelopes: Array = slice_content.get("relics", [])
	var seated: Array[String] = []
	for envelope: Variant in relic_envelopes:
		seated.append(String((envelope as Dictionary).get("id", "")))
	var fight_relics: Array[String] = []
	for relic_id: Variant in run.relics:
		if seated.has(String(relic_id)):
			fight_relics.append(String(relic_id))

	# The fight's one seed (the world's seeded rng); a debug checkout may force it to
	# replay a fight (DebugConfig).
	var forced: int = DebugConfig.forced_seed()
	return {
		"seed": forced if forced >= 0 else randi(),
		"content": {"cards": cards,
				"statuses": slice_content.get("statuses", []),
				"relics": relic_envelopes},
		"player": {"deck": deck, "units": [{"id": king_id, "slot": [1, 0]}],
				"relics": fight_relics},
		"enemy": {"deck": enemy_deck, "units": [{"id": captain_id, "slot": [1, 0]}]},
	}


# The card's seat in the fight's content: the catalogue envelope where the definition
# matches it, else a shared variant — one per distinct definition, allocated on first
# sight under "{base}~{n}" (B40).
static func _seat(cards: Array[Dictionary], base_seats: Dictionary, variants: Dictionary,
		envelope: Dictionary) -> String:
	var base := String(envelope.get("id", ""))
	var catalogue_seat: Dictionary = base_seats.get(base, {})
	if not catalogue_seat.is_empty() and _matches(catalogue_seat, envelope):
		return base
	var siblings: Array = variants.get(base, [])
	for sibling: Variant in siblings:
		if _matches(sibling as Dictionary, envelope):
			return String((sibling as Dictionary).id)
	var allocated: Dictionary = envelope.duplicate(true)
	allocated["id"] = "%s~%d" % [base, siblings.size() + 1]
	siblings.append(allocated)
	variants[base] = siblings
	cards.append(allocated)
	return String(allocated.id)


# Whether two envelopes state the same card, their ids aside.
static func _matches(a: Dictionary, b: Dictionary) -> bool:
	var body_a: Dictionary = a.duplicate()
	var body_b: Dictionary = b.duplicate()
	body_a.erase("id")
	body_b.erase("id")
	return body_a == body_b
