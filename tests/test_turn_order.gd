extends TestCase

# The salvaged turn-order strip on the new core (H2/H3): the list walks the ONE sort
# (CombatCascade.turn_order), rebuilds only when the order actually differs, dresses
# entries by allegiance, greys the spent with the board's own exhaust tint, golds the
# acting moment, and declares numbers/spotlight to the screen. Computation facts only;
# how it LOOKS is the render probe's business (dev/_turn_order_shot) and Enrra's eye.


func suite_name() -> String:
	return "the turn-order strip"


var _host: Node = null
var _world: World = null


func run() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	_host = Node.new()
	tree.root.add_child.call_deferred(_host)
	await tree.process_frame
	_build_world()
	_strip_lists_the_one_sort()
	_rebuild_only_on_a_changed_order()
	_entries_dress_by_side_and_state()
	_declarations_reach_the_screen()
	await _cards_wear_the_declared_numbers()
	await _attention_arrives_from_the_board()
	_host.queue_free()
	_host = null
	Selection.clear()


# A fixed stage: slice content (registered fresh), three player units and two enemy units
# fielded at authored speeds so the order interleaves the sides.
func _build_world() -> void:
	var fight: Dictionary = FightScreen.slice_fight()
	ContentLibrary.clear()
	for envelope: Variant in fight.content.cards:
		ContentLibrary.register_card(envelope)
	_world = World.new(7)
	var setup := {
		"player": {"units": [
			{"id": "squire", "slot": [0, 1]},
			{"id": "cleric", "slot": [1, 2]},
			{"id": "king", "slot": [2, 0]},
		]},
		"enemy": {"units": [
			{"id": "squire", "slot": [1, 1]},
			{"id": "captain", "slot": [0, 0]},
		]},
	}
	check(Genesis.setup(_world, setup.player, setup.enemy), "the stage's genesis holds")


func _strip() -> TurnOrderStrip:
	var strip := TurnOrderStrip.new()
	strip.world = _world
	_host.add_child(strip)
	strip.size = Vector2(58, 700)
	# Away from the origin: the headless cursor rests at (0,0), and a strip standing there
	# would read as hovered — its per-frame rect test is doing its job, not a bug.
	strip.position = Vector2(1600, 100)
	return strip


func _strip_lists_the_one_sort() -> void:
	var strip := _strip()
	strip.refresh()
	var order: Array[Unit] = CombatCascade.turn_order(_world)
	check_eq(strip.listed().size(), order.size(), "one entry per fielded unit")
	check_eq(strip.listed(), Array(order), "the list IS the clock's order, unre-sorted")
	strip.queue_free()


func _rebuild_only_on_a_changed_order() -> void:
	var strip := _strip()
	strip.refresh()
	var before: Array = strip.listed()
	# The signature guard: the ENTRY NODES survive a same-order refresh — a rebuild
	# would have freed and replaced them (listed() alone could not tell the difference).
	var first_entry: Control = strip._entry_for(before[0])
	strip.refresh()
	check(strip._entry_for(before[0]) == first_entry,
			"an unchanged order rebuilds nothing")
	# A death reorders the list: bury the fastest unit and re-ask.
	var fastest: Unit = before[0]
	var slot := fastest.housing
	WriteAuthority.remove(slot, fastest)
	var side: Side = fastest.allegiance
	WriteAuthority.insert(side.get_container(&"graveyard"), fastest)
	strip.refresh()
	check_eq(strip.listed().size(), before.size() - 1, "a buried unit leaves the list")
	check(not strip.listed().has(fastest), "the departed is not listed")
	strip.queue_free()


func _entries_dress_by_side_and_state() -> void:
	var strip := _strip()
	strip.refresh()
	# The palette derivation at the seam: allegiance decides the fill index.
	for unit: Unit in strip.listed():
		var want := 0 if unit.allegiance == _world.player_side() else 1
		var fill := TurnOrderStrip.fill_color(want)
		check(fill == TurnOrderStrip.PLAYER_FILL if want == 0 \
				else fill == TurnOrderStrip.ENEMY_FILL,
				"the palette keys by allegiance for '%s'" % unit.id)
	# A tapped unit's entry greys with the BOARD's own exhaust tint after a state sync.
	var spent: Unit = strip.listed()[0]
	spent.seed_stat(&"tapped", 1.0)
	strip._sync_states()
	var entry: Control = strip._entry_for(spent)
	check(entry != null and entry.modulate == CardUI.EXHAUST_TINT,
			"a tapped unit's entry wears the shared spent grey")
	spent.seed_stat(&"tapped", 0.0)
	strip._sync_states()
	check(entry.modulate == Color.WHITE, "untapping restores the entry")
	strip.queue_free()


func _declarations_reach_the_screen() -> void:
	# A bare screen instance (never in the tree, so its boot does not run) carries the
	# declaration stores the strip talks to.
	var screen := FightScreen.new()
	var strip := _strip()
	strip.screen = screen
	strip.refresh()
	var first: Unit = strip.listed()[0]
	check_eq(screen.turn_number(first), 0, "no declaration, no number")
	strip.point_at(first)
	check(screen.is_spotlit(first), "pointing at an entry spotlights its unit")
	check_eq(screen.turn_number(first), 1, "reading the list declares the numbers")
	check_eq(screen.turn_number(strip.listed()[1]), 2, "every listed unit knows its place")
	strip.point_at(null)
	check(not screen.is_spotlit(first), "the spotlight dies with the gesture")
	check_eq(screen.turn_number(first), 0, "the numbers die with the reading")
	strip.queue_free()
	screen.free()


# The card-side half: a fielded unit's card wears its declared number while the list is
# read, and sheds it — plate hidden — when the reading ends (see CardUI._refresh_turn_number).
func _cards_wear_the_declared_numbers() -> void:
	var screen := FightScreen.new()
	FightScreen.current = screen
	var strip := _strip()
	strip.screen = screen
	strip.refresh()
	var unit: Unit = strip.listed()[0]
	var slot_ui := SlotUI.new()
	_host.add_child(slot_ui)
	var card := CardUI.create(CardViewModel.unit_card(unit))
	card.view_subject = unit
	slot_ui.set_card(card)
	await (Engine.get_main_loop() as SceneTree).process_frame
	card.derive_presentation()
	check(card._turn_plate == null or not card._turn_plate.visible,
			"no declaration, no plate")
	strip.point_at(unit)
	card.derive_presentation()
	check(card._turn_plate != null and card._turn_plate.visible,
			"reading the list writes the number on the card")
	if card._turn_lbl != null:
		check_eq(card._turn_lbl.text, "1", "the card wears its own place")
	check(card._spotlit_now, "the pointed-at unit's card is spotlit")
	strip.point_at(null)
	card.derive_presentation()
	check(card._turn_plate != null and not card._turn_plate.visible,
			"the plate dies with the reading")
	check(not card._spotlit_now, "the spotlight sheds with the gesture")
	strip.queue_free()
	slot_ui.queue_free()
	FightScreen.current = null
	screen.free()


# The board-side circuits: marking a unit (the cursor on its CARD) lifts its entry with
# the hover cue, and the game-wide pick lays the dashed ring on its entry — both derived
# on the strip's own beat, exactly as the cursor's own hover is.
func _attention_arrives_from_the_board() -> void:
	var strip := _strip()
	strip.refresh()
	var tree := Engine.get_main_loop() as SceneTree
	await tree.process_frame
	var unit: Unit = strip.listed()[0]
	var entry: Control = strip._entry_for(unit)
	check(float(entry.get_meta("turn_lift", 1.0)) == 1.0, "an unmarked entry rests")
	strip.mark(unit)
	check(float(entry.get_meta("turn_lift", 1.0)) > 1.0,
			"marking the unit lifts its entry with the hover cue")
	strip.mark(null)
	# mark(null) drops the latch; the next attention sync re-derives from the real facts.
	strip._sync_attention()
	check(float(entry.get_meta("turn_lift", 1.0)) == 1.0, "the mark sheds with the gesture")
	# The pick: Selection is the one authority — the strip reads it, never mirrors it.
	var ring: Control = entry.get_meta("ring")
	check(not ring.visible, "no pick, no dashed ring")
	Selection.select(unit)
	strip._sync_attention()
	check(ring.visible, "the pick lays the dashed ring on its entry")
	Selection.clear()
	strip._sync_attention()
	check(not ring.visible, "the ring dies with the pick")
	# The acting moment: the screen's beat-derived fact golds the entry, outranking spent.
	var screen := FightScreen.new()
	strip.screen = screen
	unit.seed_stat(&"tapped", 1.0)
	screen.acting = unit
	strip._sync_states()
	check_eq(int(entry.get_meta("state", -1)), TurnOrderStrip.ST_ACTING,
			"the acting moment outranks spent (a tapped unit's moment is still its moment)")
	screen.acting = null
	strip._sync_states()
	check_eq(int(entry.get_meta("state", -1)), TurnOrderStrip.ST_SPENT,
			"the moment passes and the entry reads spent")
	unit.seed_stat(&"tapped", 0.0)
	strip.queue_free()
	screen.free()
