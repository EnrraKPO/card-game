extends TestCase

# The hand bar's first slice (docs/planning/RULINGS.html R7/R8): the bar renders an injected
# HandView and nothing else — faces through the card concept, hand-relational states on the
# item wrappers, presses reported by index. Computation facts only; dev/_hand_shot.tscn
# carries the visual half.


func suite_name() -> String:
	return "Hand"


var _host: Control = null


func run() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	_host = Control.new()
	tree.root.add_child.call_deferred(_host)
	await tree.process_frame
	_bar_renders_its_view()
	_states_dress_the_arrangement()
	_presses_report_their_index()
	_resize_reaches_every_card()
	_hand_bridge_composes_from_the_core()
	_host.queue_free()
	_host = null


func _bar() -> Hand:
	var hand := Hand.new()
	_host.add_child(hand)
	hand.build_into(_host)
	return hand


func _item(name_text: String, affordable := true, pickable := false) -> HandItemView:
	var item := HandItemView.new()
	item.card = CardData.new()
	item.card.display_name = name_text
	item.card.cost = 2
	item.affordable = affordable
	item.pickable = pickable
	return item


func _view(items: Array[HandItemView]) -> HandView:
	var view := HandView.new()
	view.items = items
	return view


func _bar_renders_its_view() -> void:
	var hand := _bar()
	check_eq(hand.card_count(), 0, "an uninjected bar is empty")
	hand.set_hand(_view([_item("Squire"), _item("Cleric"), _item("Fireball")]))
	check_eq(hand.card_count(), 3, "one card face per item")
	check_eq(hand.card_at(0)._name_label.text, "Squire", "faces bind in item order")
	hand.set_hand(_view([_item("Cleric")]))
	check_eq(hand.card_count(), 1, "reinjection replaces the row")
	hand.set_hand(null)
	check_eq(hand.card_count(), 0, "a null view empties the bar")
	# A statused item hands its views through to the face — the card concept unchanged.
	var poisoned := _item("Adder")
	var pip := StatusPipView.new()
	pip.id = "poison"
	pip.count = 2
	poisoned.statuses = [pip]
	hand.set_hand(_view([poisoned]))
	check_eq(hand.card_at(0)._status_row.get_child_count(), 1, "item statuses reach the face")


func _states_dress_the_arrangement() -> void:
	var hand := _bar()
	hand.set_hand(_view([_item("Plain"), _item("Poor", false), _item("Candidate", true, true),
			_item("PoorCandidate", false, true)]))
	check_eq(hand.card_at(0).modulate, Color.WHITE, "affordable rests undressed")
	check_eq(hand.card_at(1).modulate, Hand.UNAFFORDABLE_DIM, "unaffordable dims")
	check_eq(hand.card_at(2).modulate, Hand.PICKABLE_TINT, "a candidate wears the tint")
	check_eq(hand.card_at(3).modulate, Hand.PICKABLE_TINT,
			"the candidate tint outranks the dim")


func _presses_report_their_index() -> void:
	var hand := _bar()
	hand.set_hand(_view([_item("A"), _item("B"), _item("C")]))
	var reported: Array = []
	hand.card_pressed.connect(func(index: int) -> void: reported.append(index))
	hand.card_at(1).pressed.emit()
	hand.card_at(2).pressed.emit()
	check_eq(reported, [1, 2], "presses report the pressed item's index")


func _resize_reaches_every_card() -> void:
	var hand := _bar()
	hand.set_hand(_view([_item("A"), _item("B")]))
	hand.set_card_size(Vector2(110, 144))
	check_eq(hand.card_at(0).custom_minimum_size, Vector2(110, 144),
			"the adopted size reaches every card")
	hand.set_hand(_view([_item("C")]))
	check_eq(hand.card_at(0).custom_minimum_size, Vector2(110, 144),
			"later injections keep the adopted size")


# The hand bridge composes the bar's view from a live world: faces by kind, affordability
# from the payability query, pickability from the passed candidate list.
func _hand_bridge_composes_from_the_core() -> void:
	var fight: Dictionary = FightScreen.slice_fight()
	if fight.is_empty():
		check(false, "slice fight available to the bridge test")
		return
	ContentLibrary.clear()
	for envelope: Variant in fight.content.cards:
		ContentLibrary.register_card(envelope)
	for envelope: Variant in fight.content.get("statuses", []):
		ContentLibrary.register_status(envelope)
	for envelope: Variant in fight.content.get("relics", []):
		ContentLibrary.register_relic(envelope)
	var world := World.new(13)
	if not Genesis.setup(world, fight.player, fight.enemy):
		check(false, "genesis accepts the slice fight")
		return
	var side: Side = world.player_side()
	var hand_container: EntityContainer = side.get_container(&"hand")
	# Genesis deals the opening hand (3, per the frame's seeds) — the composed view mirrors
	# the container one-to-one from the start.
	var dealt: int = hand_container.members.size()
	check_eq(HandViewModel.hand_view(side).items.size(), dealt,
			"the view mirrors the dealt hand")
	var squire: Card = ContentLibrary.build_card(&"squire", side)
	var fireball: Card = ContentLibrary.build_card(&"fireball", side)
	WriteAuthority.mint(world, squire)
	WriteAuthority.mint(world, fireball)
	WriteAuthority.insert(hand_container, squire)
	WriteAuthority.insert(hand_container, fireball)
	var candidates: Array[GameEntity] = [fireball]
	var view: HandView = HandViewModel.hand_view(side, candidates)
	check_eq(view.items.size(), dealt + 2, "one item per held card")
	check_eq(view.items[dealt].card.display_name, squire.display_name,
			"items keep hand order")
	check_eq(view.items[dealt + 1].card.card_type, CardData.CardType.SPELL,
			"a spell composes a spell face")
	check_eq(view.items[dealt].affordable, squire.payable(),
			"affordability speaks the payability query")
	check(view.items[dealt + 1].pickable and not view.items[dealt].pickable,
			"pickability follows the candidate list")
	ContentLibrary.clear()
