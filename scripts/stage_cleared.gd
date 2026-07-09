extends Control

# Shown after a (non-final) stage boss falls: a brief "you cleared the stage" beat, then Onward
# hands out the stage reward — a choice of charms — through the shared reward screen (which then
# advances the run into the next stage). See GameData.pending_reward_* / reward_screen.
const CHARM_CHOICES := 4


func _ready() -> void:
	Nav.clear_back()   # terminal screen — the OS back gesture stays inert (use the on-screen button)
	var compact := UIScale.is_compact()

	# No screen-wide background here — Shell already paints the app's one BG_COLOR behind every screen.
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 36)
	center.add_child(vbox)

	var title := Label.new()
	title.text = "Stage %d Cleared!" % GameData.current_run.act
	title.add_theme_font_size_override("font_size", 52 if compact else 40)
	title.add_theme_color_override("font_color", Color("1f7a35"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "A charm awaits — press onward to choose your reward."
	subtitle.add_theme_font_size_override("font_size", 30 if compact else 26)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(subtitle)

	var onward := ScreenUI.action_button("Onward  →", _advance,
		Vector2(280, 88) if compact else Vector2(240, 76), 32 if compact else 26,
		ScreenUI.CHROME_CONFIRM)
	onward.size_flags_horizontal = SIZE_SHRINK_CENTER
	vbox.add_child(onward)


# Onward: queue a charm choice for the reward screen, which advances the stage once it's picked
# (or skipped). If no charms are available to offer, just advance straight through.
func _advance() -> void:
	var offers: Array = []
	var kind := ItemKinds.get_kind("charm")
	if kind != null:
		for id: String in kind.offer_pool(CHARM_CHOICES, null):
			offers.append(Grant.make("charm", id))

	if offers.is_empty():
		GameData.advance_stage()
		Nav.goto("res://scenes/map.tscn")
		return

	GameData.pending_reward_offers = offers
	GameData.pending_reward_title = "Stage Cleared — Choose a Charm"
	GameData.pending_reward_advance_stage = true
	Nav.goto("res://scenes/reward_screen.tscn")
