extends Node
# Renders the fight screen with the salvaged turn-order strip populated: extra units are
# fielded straight onto both boards after boot so the gutter carries a real list. Two
# shots: the strip at rest, and the harness pointing at the first entry (the hover lift +
# the declared numbers on the cards arrive with their own commits).
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_turn_order_shot.tscn
const OUT_REST := "res://dev/_turn_order_rest.png"
const OUT_POINT := "res://dev/_turn_order_point.png"
const OUT_ACT := "res://dev/_turn_order_act.png"


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1422, 800)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.transparent_bg = false
	add_child(sv)
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.12, 0.11)
	bg.size = sv.size
	sv.add_child(bg)
	var screen := FightScreen.new()
	sv.add_child(screen)
	screen.size = sv.size
	await get_tree().create_timer(0.6).timeout
	# Field a spread of catalogue units directly — display drive, not a rules road.
	var world: World = screen.world
	_field(world, world.player_side(), 0, "air_air_pawn", Vector3i(0, 0, 1))
	_field(world, world.player_side(), 0, "earth_water_knight", Vector3i(0, 2, 2))
	_field(world, world.enemy_side(), 1, "alien_probe", Vector3i(1, 0, 1))
	_field(world, world.enemy_side(), 1, "alien_grey", Vector3i(1, 2, 0))
	screen.refresh()
	await get_tree().create_timer(1.0).timeout
	sv.get_texture().get_image().save_png(OUT_REST)
	var strip: TurnOrderStrip = screen._turn_strip
	var listed: Array = strip.listed()
	if not listed.is_empty():
		strip.point_at(listed[0])
	await get_tree().create_timer(0.6).timeout
	sv.get_texture().get_image().save_png(OUT_POINT)
	# The combat span: end the player's command and catch a unit's acting moment — the
	# gold entry, the strike choreography, the spent greys accumulating behind it.
	strip.point_at(null)
	screen._on_end_turn()
	await get_tree().create_timer(0.45).timeout
	sv.get_texture().get_image().save_png(OUT_ACT)
	print("RENDERED turn order strip (%d listed)" % listed.size())
	get_tree().quit()


func _field(world: World, side: Side, half: int, id: String, at: Vector3i) -> void:
	var unit: Card = ContentLibrary.build_card(StringName(id), side)
	if unit == null:
		return
	var slot: Slot = world.board_manager.slot_at(at)
	WriteAuthority.mint(world, unit)
	WriteAuthority.insert(slot.get_container(&"slotted_unit"), unit)
