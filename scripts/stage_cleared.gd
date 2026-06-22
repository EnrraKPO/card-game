extends Control

# Shown after a (non-final) stage boss falls. Offers a special reward — a pick from a
# stronger card selection — then advances the run into the next stage. The reward pool
# is intentionally simple for now (any non-King card); specialise it here later.
const REWARD_CHOICES := 3

var _picked := false


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	Nav.clear_back()   # terminal screen — the OS back gesture stays inert (use the on-screen button)
	var compact := UIScale.is_compact()

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.color = Color(0.05, 0.09, 0.07)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 36)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Stage %d Cleared!" % GameData.current_run.act
	title.add_theme_font_size_override("font_size", 52 if compact else 40)
	title.modulate = Color(0.5, 1.0, 0.6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Claim a reward before pressing onward."
	subtitle.add_theme_font_size_override("font_size", 30 if compact else 18)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	var card_row := HBoxContainer.new()
	card_row.add_theme_constant_override("separation", 32)
	card_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(card_row)

	for id: String in CardData.random_non_kings(REWARD_CHOICES):
		var data := CardData.get_card(id)
		if data == null:
			continue
		var ui := CardUI.create(CardInstance.from_data(data))
		ui.draggable = false
		ui.custom_minimum_size = Vector2(230, 302) if compact else Vector2(160, 210)
		ui.pressed.connect(func(): _pick_card(id))
		card_row.add_child(ui)

	var onward := Button.new()
	onward.text = "Onward  →"
	onward.add_theme_font_size_override("font_size", 32 if compact else 20)
	onward.custom_minimum_size = Vector2(280, 88) if compact else Vector2(200, 0)
	onward.size_flags_horizontal = SIZE_SHRINK_CENTER
	onward.pressed.connect(_advance)
	vbox.add_child(onward)


func _pick_card(id: String) -> void:
	if _picked:
		return
	_picked = true
	GameData.current_run.deck.append(DeckCard.make(id))
	_advance()


func _advance() -> void:
	GameData.advance_stage()
	get_tree().change_scene_to_file("res://scenes/map.tscn")
