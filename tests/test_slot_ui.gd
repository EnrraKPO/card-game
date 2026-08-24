extends TestCase

# The slot surface under the view-model contract (docs/planning/RULINGS.html R4 + R5): the
# widget renders ONLY what is injected — cues, occupancy, ground views — and the SlotViewModel
# bridge composes those injections from the core. Computation facts only; how it LOOKS is the
# render probe's business (dev/_slotui_shot.tscn) and Enrra's eye.


func suite_name() -> String:
	return "SlotUI"


var _host: Node = null


func run() -> void:
	# The runner is itself mid-_ready, and the tree root refuses add_child while busy — so the
	# widgets mount under a deferred host node, gone whole when the suite ends.
	var tree := Engine.get_main_loop() as SceneTree
	_host = Node.new()
	tree.root.add_child.call_deferred(_host)
	await tree.process_frame
	_fresh_slot_shows_nothing()
	_cues_drive_the_glyphs()
	_attack_marker_is_independent()
	_ground_view_injection()
	_ground_clears_whole()
	_open_hints_respect_side_and_occupancy()
	_pip_binds_its_view()
	_view_model_bridges_the_core()
	_host.queue_free()
	_host = null


func _slot() -> SlotUI:
	var slot := SlotUI.new()
	_host.add_child(slot)
	slot.size = slot.custom_minimum_size
	return slot


func _pip_view(id: String, stacks: int, duplicates: bool) -> StatusPipView:
	var v := StatusPipView.new()
	v.id = id
	v.display_name = id.capitalize()
	v.color = Color.RED
	v.stacks = stacks
	v.count = stacks
	v.duplicates = duplicates
	return v


func _ground(pips: Array[StatusPipView]) -> SlotGroundView:
	var g := SlotGroundView.new()
	g.pips = pips
	if not pips.is_empty():
		g.color = pips[0].color
		g.status_id = pips[0].id
	return g


func _fresh_slot_shows_nothing() -> void:
	var slot := _slot()
	check(not slot._ground_frame.visible, "fresh slot: no ground frame")
	check(not slot._icon.visible, "fresh slot: no cue glyph")
	check(not slot._arrow.visible, "fresh slot: no arrow")
	check(not slot._attack_icon.visible, "fresh slot: no crosshair")
	check(slot.get_card() == null, "fresh slot: empty")


func _cues_drive_the_glyphs() -> void:
	var slot := _slot()
	slot.set_cue(SlotUI.Cue.OPEN)
	check(slot._icon.visible, "OPEN shows the marker")
	slot.set_cue(SlotUI.Cue.TARGET_BAD)
	check(slot._icon.visible, "TARGET_BAD shows the X")
	slot.set_cue(SlotUI.Cue.MOVE, true)
	check(slot._icon.visible, "MOVE shows the pool")
	check(slot._arrow.visible, "animated MOVE shows the arrow")
	slot.set_cue(SlotUI.Cue.MOVE, false)
	check(not slot._arrow.visible, "static MOVE parks the arrow")
	slot.set_cue(SlotUI.Cue.NONE)
	check(not slot._icon.visible, "NONE hides the glyphs")
	# An EMPTY valid target keeps the reticle glyph (no card to light from within).
	slot.set_cue(SlotUI.Cue.TARGET_OK)
	check(slot._icon.visible, "empty TARGET_OK keeps the reticle")


func _attack_marker_is_independent() -> void:
	var slot := _slot()
	slot.set_attack_marker(true)
	slot.set_cue(SlotUI.Cue.TARGET_OK)
	check(slot._attack_icon.visible, "crosshair survives a cue change")
	slot.set_attack_marker(false)
	check(not slot._attack_icon.visible, "crosshair retires on demand")


func _ground_view_injection() -> void:
	var slot := _slot()
	var pips: Array[StatusPipView] = [_pip_view("gloom", 3, false), _pip_view("cinder", 3, true)]
	slot.set_ground(_ground(pips))
	check(slot._ground_frame.visible, "ground view raises the frame")
	check(slot._ground_floor.visible, "ground view washes the floor")
	# One tab for the counted status, one PER STACK for the duplicates status.
	check_eq(slot._ground_pips.get_child_count(), 4, "tab count: 1 counted + 3 duplicate")
	check_eq(slot.ground_pips_of("cinder").size(), 3, "pile enumerates by id")
	check(slot.find_ground_pip("gloom") != null, "single tab found by id")
	check(slot.ground_pip_at("cinder", 9) != null, "index clamps to the last tab standing")


func _ground_clears_whole() -> void:
	var slot := _slot()
	var pips: Array[StatusPipView] = [_pip_view("gloom", 2, false)]
	slot.set_ground(_ground(pips))
	slot.set_ground(null)
	check(not slot._ground_frame.visible, "null view drops the frame")
	check(not slot._ground_floor.visible, "null view drops the floor")
	check_eq(slot._ground_pips.get_child_count(), 0, "null view empties the row")
	check_eq(slot._ground_tint, Color.WHITE, "no ground casts no light")


func _open_hints_respect_side_and_occupancy() -> void:
	var own := _slot()
	own.own_side = true
	own.set_open_hints(true)
	check(own._icon.visible, "own empty slot wears the open marker")
	var card := CardUI.create(CardData.new())
	own.set_card(card)
	check(not own._icon.visible, "an occupant clears the marker")
	own.clear_card()
	check(own._icon.visible, "emptying restores the marker")
	card.queue_free()
	var enemy := _slot()
	enemy.own_side = false
	enemy.set_open_hints(true)
	check(not enemy._icon.visible, "enemy slots never hint placement")


func _pip_binds_its_view() -> void:
	var scene := load("res://scenes/status_pip.tscn") as PackedScene
	var counted := scene.instantiate() as StatusPip
	var v := _pip_view("gloom", 3, false)
	v.show_stacks = true
	counted.setup(v)
	check((counted.get_node("Count") as Label).visible, "count > 1 shows the headline")
	check((counted.get_node("Stacks") as Label).visible, "show_stacks shows the tag")
	check((counted.get_node("Glyph") as Label).visible, "no icon falls back to the glyph")
	counted.free()
	var lone := scene.instantiate() as StatusPip
	lone.setup(_pip_view("gloom", 1, false))
	check(not (lone.get_node("Count") as Label).visible, "count 1 stays bare")
	lone.free()


# The slot bridge answers slot questions only (R6): occupancy, and the ground — a slot with
# no ground statuses composes no view at all. The occupant's face is CardViewModel's business,
# proven in test_card_ui.
func _view_model_bridges_the_core() -> void:
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
	var world := World.new(7)
	if not Genesis.setup(world, fight.player, fight.enemy):
		check(false, "genesis accepts the slice fight")
		return
	var found_unit := false
	for side_index: int in 2:
		for row: int in BoardGeometry.ROWS:
			for col: int in BoardGeometry.COLS:
				var slot: Slot = world.board_manager.slot_at(Vector3i(side_index, row, col))
				check(SlotViewModel.ground_view(slot) == null, "bare ground composes no view")
				if SlotViewModel.occupant(slot) != null:
					found_unit = true
	check(found_unit, "genesis fielded someone to find")
	ContentLibrary.clear()
