extends Node
# Inspect + tray flow: select a fielded unit -> sidebar + ability tray; press a token ->
# the use_ability ask; the Abilities level lists holders. Screenshots the inspect view.
const OUT := "res://dev/_inspect_out.png"
func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		print("PROBE WATCHDOG")
		get_tree().quit())
	var screen := FightScreen.new()
	add_child(screen)
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	while not (screen._span_active and screen._awaiting_command):
		await get_tree().create_timer(0.2).timeout
	var origin := Vector3i(0, 1, 0)
	screen._on_slot_clicked(origin)   # select the King -> inspect derives
	await get_tree().create_timer(0.5).timeout
	print("PROBE level=", screen._hand.nav_level(),
			" tokens=", screen._hand._gen_cards.size(),
			" sidebar=", screen._hand._desc_panel.visible,
			" title=", screen._hand._desc_name_lbl.text,
			" door=", screen._hand._inspect_abilities_btn.visible,
			" back=", screen._hand._back_btn.visible)
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OUT)
	# A token press fires the ability ask road (move -> destination pick opens).
	var asks: Array = []
	screen._hand.ability_pressed.connect(func(n: StringName) -> void: asks.append(n))
	if screen._hand._gen_cards.size() > 0:
		var token: Control = screen._hand._gen_cards[0]
		if token is CardUI:
			(token as CardUI).pressed.emit()
		else:
			(token as Button).pressed.emit()
	await get_tree().create_timer(0.3).timeout
	print("PROBE token ask relayed: ", asks)
	# Back out, then the Abilities level.
	screen._hand.dismiss_to_hand()
	await get_tree().create_timer(0.2).timeout
	screen._hand.show_abilities()
	await get_tree().create_timer(0.3).timeout
	print("PROBE abilities level=", screen._hand.nav_level(),
			" entries=", screen._hand._ability_entries.size())
	print("PROBE rendered")
	get_tree().quit()
