class_name ItemKindCard
extends ItemKind

# Cards as an acquirable item: granting one appends a fresh DeckCard to the run deck. Pricing and
# pool match the legacy shop card row (30 + cost*20; random non-king cards).

func offer_pool(count: int, _rng: RandomNumberGenerator) -> Array[String]:
	return CardData.random_non_kings(count)


func make_offer_ui(id: String) -> Control:
	var data := CardData.get_card(id)
	if data == null:
		return Control.new()
	var ui := CardUI.create(CardInstance.from_data(data))
	ui.custom_minimum_size = Vector2(130, 170)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return ui


func display_name(id: String) -> String:
	var data := CardData.get_card(id)
	return data.display_name if data != null else id.capitalize()


func tooltip(id: String) -> String:
	return display_name(id)


func default_price(id: String) -> int:
	var data := CardData.get_card(id)
	return 30 + (data.cost * 20 if data != null else 0)


func grant(id: String, count: int) -> void:
	if GameData.current_run == null:
		return
	for _i in maxi(1, count):
		GameData.current_run.deck.append(DeckCard.make(id))
	GameData.save_run()
