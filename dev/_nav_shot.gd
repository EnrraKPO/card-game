extends Node
# Throwaway visual check for the hand-panel navigation levels: boots the real combat screen
# (like _render.gd), spawns a rook (castling holder) so the Abilities list has content, then
# renders level 2 (Abilities) and level 3 (Inspect) to PNGs. Run WITHOUT --headless.
const RES := Vector2i(1920, 1080)


func _ready() -> void:
	GameData.select_slot(0)
	GameData.start_new_run()

	var sv := SubViewport.new()
	sv.size = RES
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var shell: Node = load("res://scenes/main.tscn").instantiate()
	shell.auto_start = false
	sv.add_child(shell)
	shell.mount("res://scenes/combat.tscn")
	for _i in 8:
		await get_tree().process_frame

	var combat: Node = sv.find_child("Combat", true, false)
	if combat == null:
		# The screen root may not be named Combat — find it by script instead.
		for n: Node in sv.find_children("*", "", true, false):
			if n.get_script() != null and str(n.get_script().resource_path).ends_with("combat.gd"):
				combat = n
				break
	if combat == null:
		print("SHOT FAIL: combat node not found")
		get_tree().quit()
		return

	# Content for the list: a rook (holds Castling) on the player board.
	var rook := CardInstance.from_data(CardData.get_card("rook"))
	Resolver.fill_health(rook)
	combat._board.spawn_player_card(rook, 1, 1)

	combat._hand.show_abilities()
	for _i in 4:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png("res://dev/_nav_l2.png")

	combat._hand.set_inspected(rook)
	for _i in 4:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png("res://dev/_nav_l3.png")

	# A unit WITHOUT activated abilities — the token row's place shows the explanatory text.
	combat._hand.set_inspected(combat._board.get_player_king())
	for _i in 4:
		await get_tree().process_frame
	sv.get_texture().get_image().save_png("res://dev/_nav_l3_no_abilities.png")

	print("RENDERED nav levels 2+3")
	get_tree().quit()
