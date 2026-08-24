extends Node
# Renders the salvaged SlotUI's states side by side for eyeballing — the R5 data setups:
# cues, ground views, occupancy, composition. Injection only; no game world behind it.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_slotui_shot.tscn
const OUT := "res://dev/_slotui_out.png"
const SLOT := Vector2(150, 196)


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1340, 640)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.transparent_bg = false
	add_child(sv)

	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.12, 0.11)
	bg.size = sv.size
	sv.add_child(bg)

	var grid := GridContainer.new()
	grid.columns = 7
	grid.position = Vector2(24, 16)
	grid.add_theme_constant_override("h_separation", SlotUI.SLOT_GAP + 6)
	grid.add_theme_constant_override("v_separation", SlotUI.SLOT_GAP + 22)
	sv.add_child(grid)

	_shot(grid, "empty idle", func(_slot: SlotUI) -> void: pass)
	_shot(grid, "open hint", func(slot: SlotUI) -> void:
		slot.own_side = true
		slot.set_open_hints(true))
	_shot(grid, "move static", func(slot: SlotUI) -> void:
		slot.set_cue(SlotUI.Cue.MOVE, false))
	_shot(grid, "move live", func(slot: SlotUI) -> void:
		slot.set_cue(SlotUI.Cue.MOVE, true))
	_shot(grid, "target ok (empty)", func(slot: SlotUI) -> void:
		slot.set_cue(SlotUI.Cue.TARGET_OK))
	_shot(grid, "target bad", func(slot: SlotUI) -> void:
		slot.set_cue(SlotUI.Cue.TARGET_BAD))
	_shot(grid, "crosshair", func(slot: SlotUI) -> void:
		slot.set_attack_marker(true))
	_shot(grid, "bad + crosshair", func(slot: SlotUI) -> void:
		slot.set_cue(SlotUI.Cue.TARGET_BAD)
		slot.set_attack_marker(true))
	_shot(grid, "ground x3", func(slot: SlotUI) -> void:
		slot.set_ground(_ground([_pip("venom", Color(0.45, 0.75, 0.2), 3, false)])))
	_shot(grid, "ground pile x4", func(slot: SlotUI) -> void:
		slot.set_ground(_ground([_pip("cinder", Color(0.9, 0.45, 0.15), 4, true)])))
	_shot(grid, "ground mixed", func(slot: SlotUI) -> void:
		slot.set_ground(_ground([_pip("venom", Color(0.45, 0.75, 0.2), 2, false),
				_pip("cinder", Color(0.9, 0.45, 0.15), 3, true)])))
	_shot(grid, "occupied", func(slot: SlotUI) -> void:
		slot.set_card(_card()))
	_shot(grid, "occupied + ground", func(slot: SlotUI) -> void:
		slot.set_card(_card())
		slot.set_ground(_ground([_pip("cinder", Color(0.9, 0.45, 0.15), 3, true)])))
	_shot(grid, "phantom", func(slot: SlotUI) -> void:
		slot.mount_phantom(_card()))

	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().create_timer(0.45).timeout
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED slot ui states")
	get_tree().quit()


func _shot(grid: Control, label_text: String, dress: Callable) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	grid.add_child(box)
	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color.WHITE)
	box.add_child(label)
	var slot := SlotUI.new()
	box.add_child(slot)
	slot.custom_minimum_size = SLOT
	slot.size = SLOT
	dress.call(slot)


func _pip(id: String, color: Color, stacks: int, duplicates: bool) -> StatusPipView:
	var v := StatusPipView.new()
	v.id = id
	v.display_name = id.capitalize()
	v.color = color
	v.stacks = stacks
	v.count = stacks
	v.duplicates = duplicates
	return v


func _ground(pips: Array[StatusPipView]) -> SlotGroundView:
	var g := SlotGroundView.new()
	g.pips = pips
	g.color = pips[0].color
	g.status_id = pips[0].id
	return g


func _card() -> CardUI:
	var data := CardData.new()
	data.display_name = "Squire"
	data.cost = 2
	data.attack = 3
	data.health = 5
	data.speed = 2
	data.shield = 1
	return CardUI.create(data)
