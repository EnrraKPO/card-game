extends Node
# Renders the hand bar's first slice — injected items across the R8 states: plain,
# unaffordable, pick candidate, statused, spell.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_hand_shot.tscn
const OUT := "res://dev/_hand_out.png"


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1422, 340)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.12, 0.11)
	bg.size = sv.size
	sv.add_child(bg)
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sv.add_child(host)
	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(column)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)

	var mana := Label.new()
	mana.text = "Mana 2/3"
	var hand := Hand.new()
	add_child(hand)
	hand.build_into(column, mana)

	var plain := _item("Squire", 2)
	var poor := _item("Avenger", 9)
	poor.affordable = false
	var candidate := _item("Cleric", 2)
	candidate.pickable = true
	var poisoned := _item("Venom Adder", 3)
	var pip := StatusPipView.new()
	pip.id = "poison"
	pip.display_name = "Poison"
	pip.color = Color(0.45, 0.75, 0.2)
	pip.count = 2
	pip.stacks = 2
	poisoned.statuses = [pip]
	var spell := _item("Fireball", 2)
	spell.card.card_type = CardData.CardType.SPELL

	var view := HandView.new()
	view.items = [plain, poor, candidate, poisoned, spell]
	hand.set_hand(view)

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.3).timeout
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED hand bar states")
	get_tree().quit()


func _item(name_text: String, cost: int) -> HandItemView:
	var item := HandItemView.new()
	item.card = CardData.new()
	item.card.display_name = name_text
	item.card.cost = cost
	item.card.attack = 3
	item.card.health = 5
	item.card.speed = 2
	return item
