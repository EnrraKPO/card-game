extends Node
# Throwaway: renders the consumable relic chip's states side by side for eyeballing — the
# button-dressed frame vs a passive icon chip, ready/locked/mid-hold, and the letter fallback.
# godot --path . res://dev/_consumable_chip_shot.tscn ; view _consumable_chip_out.png
const OUT := "res://dev/_consumable_chip_out.png"
const CHIP := 76.0


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(900, 330)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.transparent_bg = false
	add_child(sv)

	var bg := ColorRect.new()
	bg.color = ScreenUI.MANA_TRACK_BG   # the combat relic strip's track — the chip's real stage
	bg.size = sv.size
	sv.add_child(bg)

	var relic := RelicData.get_relic("bomb")
	var row := HBoxContainer.new()
	row.position = Vector2(24, 50)
	row.add_theme_constant_override("separation", 28)
	sv.add_child(row)

	# [label, check_valid, check_result, progress, strip_icon]
	var states := [
		["passive chip", false, false, 0.0, true],
		["display (map)", false, false, 0.0, false],
		["ready", true, true, 0.0, false],
		["locked", true, false, 0.0, false],
		["hold 60%", true, true, 0.6, false],
		["letter fallback", true, true, 0.0, false],
	]
	var chips: Array = []
	for st: Array in states:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 10)
		row.add_child(box)
		var lbl := Label.new()
		lbl.text = st[0]
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(lbl)
		if bool(st[4]):
			# The passive comparison: the frameless icon chip every other relic wears.
			var btn := Button.new()
			btn.custom_minimum_size = Vector2(CHIP, CHIP)
			btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			btn.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
			var tex := TextureRect.new()
			tex.texture = relic.icon
			tex.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			btn.add_child(tex)
			box.add_child(btn)
			continue
		var chip := ConsumableChip.new()
		chip.relic = relic
		if str(st[0]) == "letter fallback":
			var bare := RelicData.new()
			bare.id = "bomb"
			bare.color = relic.color
			bare.letter = relic.letter
			chip.relic = bare
		if bool(st[1]):
			var res: bool = st[2]
			chip.check = func() -> bool: return res
		chip.custom_minimum_size = Vector2(CHIP, CHIP)
		chip.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		box.add_child(chip)
		chips.append([chip, st])

	await get_tree().process_frame
	await get_tree().process_frame
	for entry: Array in chips:
		var chip := entry[0] as ConsumableChip
		var st: Array = entry[1]
		if float(st[3]) > 0.0:
			chip._holding = true   # freeze a mid-hold frame (no synthetic press needed)
			chip.set_process(false)
			chip._progress = float(st[3])
			chip._set_popped(true)   # the hold pop that gets the gauge out from under a fingertip
			chip.queue_redraw()
	await get_tree().create_timer(0.4).timeout
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED consumable chip states")
	get_tree().quit()
