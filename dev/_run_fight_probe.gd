extends Node
# Renders the fight screen booted THROUGH THE RUN ROAD (RunFight.compose): a constructed
# run — wounded King, a charmed card — against a power-scaled enemy encounter, exactly
# what NodeKindCombat states before Nav.goto.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_run_fight_probe.tscn
const OUT := "res://dev/_run_fight_probe_out.png"


func _ready() -> void:
	var run := RunData.new()
	run.king_id = "king"
	run.king_damage = 10
	run.relics = ["contagion_stone"]
	var deck: Array = []
	var picked := 0
	for entry: Variant in CardData.all():
		var card: CardData = entry
		if card.card_type != CardData.CardType.UNIT or card.enemy_only or card.is_king:
			continue
		deck.append(DeckCard.make(card.id))
		picked += 1
		if picked == 12:
			break
	run.deck = deck

	var enc := EncounterData.new()
	enc.power = 4.0
	for entry: Variant in CardData.all():
		var card: CardData = entry
		if not card.enemy_only or card.card_type != CardData.CardType.UNIT:
			continue
		if card.is_king:
			if enc.enemy_king == "king":
				enc.enemy_king = card.id
		elif enc.enemy_deck.size() < 8:
			enc.enemy_deck.append(card.id)

	GameData.current_run = run
	GameData.current_encounter = enc
	FightScreen.next_fight = RunFight.compose(run, enc)

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
	await get_tree().create_timer(1.2).timeout
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED the run-road fight screen")
	get_tree().quit()
