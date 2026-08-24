extends TestCase

# The card standing on its own (docs/planning/RULINGS.html R6): CardUI renders ONLY what is
# injected — its CardData face, its status views — and CardViewModel is the one piece
# composing those injections from the core. Computation facts only; the render probe
# (dev/_cardui_shot.tscn) carries the visual half.


func suite_name() -> String:
	return "CardUI"


var _host: Node = null


func run() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	_host = Node.new()
	tree.root.add_child.call_deferred(_host)
	await tree.process_frame
	_face_renders_its_data()
	_kinds_shape_the_face()
	_composition_chips_render()
	_status_views_drive_the_row()
	_aura_follows_its_view()
	_ground_tint_lands_on_art()
	_phantom_is_reversible()
	_selection_derives_from_the_authority()
	_tooltip_carries_the_views()
	_card_bridge_composes_from_the_core()
	_host.queue_free()
	_host = null


func _card(data: CardData) -> CardUI:
	var ui := CardUI.create(data)
	_host.add_child(ui)
	return ui


func _face(name_text: String = "Squire") -> CardData:
	var data := CardData.new()
	data.display_name = name_text
	data.cost = 2
	data.attack = 3
	data.health = 5
	data.speed = 2
	data.shield = 1
	return data


func _pip_view(id: String, count: int) -> StatusPipView:
	var v := StatusPipView.new()
	v.id = id
	v.display_name = id.capitalize()
	v.color = Color.GREEN
	v.count = count
	v.stacks = count
	return v


func _face_renders_its_data() -> void:
	var ui := _card(_face())
	check_eq(ui._name_label.text, "Squire", "name label carries the name")
	check_eq(ui._cost_lbl.text, "2", "cost badge carries the cost")
	check_eq(ui._atk_lbl.text, "3", "attack badge carries the attack")
	check_eq(ui._hp_lbl.text, "5", "health badge carries the health")
	check_eq(ui._spd_lbl.text, "2", "speed badge carries the speed")
	check_eq(ui._shield_lbl.text, "1", "shield badge carries the shield")
	# The face mirrors REINJECTED data — the live-stat path the fight screen drives.
	var data := _face()
	data.health = 1
	ui.card_data = data
	ui.refresh()
	check_eq(ui._hp_lbl.text, "1", "reinjection moves the face")


func _kinds_shape_the_face() -> void:
	var spell_data := _face("Fireball")
	spell_data.card_type = CardData.CardType.SPELL
	var spell := _card(spell_data)
	check(not spell._atk_lbl.visible, "a spell face carries no attack badge")
	check(not spell._hp_lbl.visible, "a spell face carries no health badge")
	var king_data := _face("King")
	king_data.is_king = true
	var king := _card(king_data)
	check(not king._cost_lbl.visible, "a king face carries no cost badge")


func _composition_chips_render() -> void:
	var data := _face()
	data.elements.assign(["fire", "water"])
	var ui := _card(data)
	check(ui._comp_row.get_child_count() > 0, "elements compose into chips")
	var bare := _card(_face())
	check_eq(bare._comp_row.get_child_count(), 0, "no composition, no chips")


func _status_views_drive_the_row() -> void:
	var ui := _card(_face())
	check_eq(ui._status_row.get_child_count(), 0, "fresh card wears no pips")
	ui.set_status_views([_pip_view("poison", 3), _pip_view("gloom", 1)])
	check_eq(ui._status_row.get_child_count(), 2, "one pip per injected view")
	var first := ui._status_row.get_child(0) as StatusPip
	check_eq(first.view.id, "poison", "pips bind their views in order")
	check((first.get_node("Count") as Label).visible, "stacked view shows its count")
	ui.set_status_views([_pip_view("poison", 4)])
	check_eq(ui._status_row.get_child_count(), 1, "reinjection replaces the row")
	ui.set_status_views([])
	check_eq(ui._status_row.get_child_count(), 0, "empty injection clears the row")


func _aura_follows_its_view() -> void:
	var ui := _card(_face())
	var shielded := _pip_view("barrier", 1)
	shielded.aura = true
	ui.set_status_views([shielded])
	check(ui._aura != null and ui._aura.visible, "an aura view raises the ring")
	ui.set_status_views([_pip_view("poison", 1)])
	check(not ui._aura.visible, "no aura view, no ring")


func _ground_tint_lands_on_art() -> void:
	var ui := _card(_face())
	ui.set_ground_tint(Color.RED)
	check_eq(ui._art.self_modulate, Color.RED, "the ground's light lands on the art")
	ui.set_ground_tint(Color.WHITE)
	check_eq(ui._art.self_modulate, Color.WHITE, "white is the no-op resting light")


func _phantom_is_reversible() -> void:
	var ui := _card(_face())
	ui.set_phantom(true)
	check(ui._canvas.material != null, "the phantom treatment hangs its shader")
	ui.set_phantom(false)
	check(ui._canvas.material == null, "the treatment lifts whole")


# The card asks THE one authority whether it is the pick (R9) and dresses itself — no
# screen writes a selection state onto the view.
func _selection_derives_from_the_authority() -> void:
	var ui := _card(_face())
	var subject := RefCounted.new()   # any Object can be a pick's subject
	ui.view_subject = subject
	ui.pressed.connect(func() -> void: pass)   # a wired press makes the view pickable
	Selection.select(subject)
	ui.derive_presentation()
	check(ui._selected_now, "the pick's view derives selected")
	Selection.clear()
	ui.derive_presentation()
	check(not ui._selected_now, "clearing the authority undresses the view")


# The card's details read renders the SAME injected views its badge row wears — the tooltip
# is card presentation, on the injection circuit like everything else.
func _tooltip_carries_the_views() -> void:
	var ui := _card(_face())
	var view := _pip_view("poison", 3)
	view.description = "Suffers per stack."
	ui.set_status_views([view])
	var panel := ui.build_details_panel()
	check(panel != null, "the card builds its read")
	_host.add_child(panel)
	check(_mentions(panel, "Poison"), "the read names the held status")
	var bare := _card(_face())
	var bare_panel := bare.build_details_panel()
	_host.add_child(bare_panel)
	check(not _mentions(bare_panel, Loc.t("card_tooltip.section_statuses")),
			"no views, no statuses section")


func _mentions(node: Node, needle: String) -> bool:
	if node is Label and (node as Label).text.contains(needle):
		return true
	if node is RichTextLabel and (node as RichTextLabel).text.contains(needle):
		return true
	for child: Node in node.get_children():
		if _mentions(child, needle):
			return true
	return false


# The card bridge composes card facts from a live world: the face mirrors live stats, and a
# held status arrives as its badge view.
func _card_bridge_composes_from_the_core() -> void:
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
	var world := World.new(11)
	if not Genesis.setup(world, fight.player, fight.enemy):
		check(false, "genesis accepts the slice fight")
		return
	var unit: Unit = null
	for side_index: int in 2:
		for row: int in BoardGeometry.ROWS:
			for col: int in BoardGeometry.COLS:
				var found: Unit = SlotViewModel.occupant(
						world.board_manager.slot_at(Vector3i(side_index, row, col)))
				if found != null and unit == null:
					unit = found
	if unit == null:
		check(false, "genesis fielded someone to bridge")
		return
	var face: CardData = CardViewModel.unit_card(unit)
	check_eq(face.display_name, unit.display_name, "face carries the name")
	check_eq(face.health, roundi(unit.get_stat(&"health")), "face mirrors live health")
	check_eq(face.is_king, unit.is_king, "face carries kinghood")
	check(CardViewModel.status_views(unit).is_empty(), "no statuses, no views")
	var status: Status = ContentLibrary.build_status(&"poison", unit.allegiance)
	WriteAuthority.mint(world, status)
	var no_events: Array[Event] = []
	WriteAuthority.stat_write(status, &"stacks", 3.0, no_events)
	WriteAuthority.insert(unit.get_container(&"contained"), status)
	var views: Array[StatusPipView] = CardViewModel.status_views(unit)
	check_eq(views.size(), 1, "a held status composes one view")
	check_eq(views[0].id, "poison", "the view names its status")
	check_eq(views[0].count, 3, "the view headlines the live stacks")
	ContentLibrary.clear()
