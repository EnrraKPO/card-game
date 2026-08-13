extends Node

# Bench: how long does the CPU take to PLAN a turn when it is holding its whole roster?
# (dev probe for the 2026-07-30 "draw the whole roster at start" experiment — the engine's
# candidate count is hand × empty slots, so a full hand is the case worth measuring.)
#
#   godot --path . res://dev/_enemy_turn_bench.tscn -- enc=slime_tide depth=17 mana=12
#
# Prints one line per (hand size, mana) pass: the plan length and the wall clock the planner
# spent. Nothing here touches the live game — it builds its own grids and hand.

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var enc_id := "slime_tide"
	var depth := 17
	var mana := 12
	for a: String in args:
		if a.begins_with("enc="):
			enc_id = a.trim_prefix("enc=")
		elif a.begins_with("depth="):
			depth = int(a.trim_prefix("depth="))
		elif a.begins_with("mana="):
			mana = int(a.trim_prefix("mana="))

	var tpl: EncounterTemplateData = null
	for t: EncounterTemplateData in EncounterTemplateData.all():
		if t.id == enc_id:
			tpl = t
			break
	if tpl == null:
		print("BENCH: no template '", enc_id, "'")
		get_tree().quit()
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var enc := tpl.instantiate(rng, EncounterTemplateData.power_for_depth(depth))
	print("BENCH encounter=%s roster=%d power=%.2f" % [enc_id, enc.enemy_deck.size(), enc.power])
	# Composition tally: what the pool ACTUALLY yields over many rolls at this power. Since the
	# cost skew was removed (2026-07-30) this should match the authored weights among the
	# entries unlocked at this power — if it drifts, something is reweighting the pool again.
	var tally: Dictionary = {}
	var rolls := 40
	var total_cards := 0
	for i in rolls:
		var r2 := RandomNumberGenerator.new()
		r2.seed = 1000 + i
		var e2 := tpl.instantiate(r2, EncounterTemplateData.power_for_depth(depth))
		for id3: String in e2.enemy_deck:
			tally[id3] = int(tally.get(id3, 0)) + 1
			total_cards += 1
	print("BENCH composition over %d rolls (avg deck %.1f cards):" % [rolls, float(total_cards) / rolls])
	for id4: String in tally:
		var per_deck := float(tally[id4]) / float(rolls)
		var card := CardData.get_card(id4)
		print("BENCH   %-22s cost %d  avg %.2f per deck  (%.1f%%)"
				% [id4, int(card.cost) if card != null else -1, per_deck,
				100.0 * float(tally[id4]) / float(total_cards)])

	var costs: Array = []
	for id2: String in enc.enemy_deck:
		var d2 := CardData.scaled(CardData.get_card(id2), enc.power)
		if d2 != null and not d2.is_king:
			costs.append("%s:%d" % [id2, int(d2.cost)])
	print("BENCH roster costs ", str(costs))

	# The hand: the whole roster, exactly as Combat._init_enemy_deck now deals it.
	var hand: Array = []
	for id: String in enc.enemy_deck:
		var data := CardData.scaled(CardData.get_card(id), enc.power)
		if data != null and not data.is_king:
			var inst := CardInstance.from_data(data)
			inst.owner = 1
			# INERT (2026-08-13 ruling): the fill-to-max rode the nuked write form.
			hand.append(inst)

	# Two kings on an otherwise empty field — the most open board there is, so the placement
	# candidate count (hand × empty slots) is at its worst.
	var player_grid := _blank()
	var enemy_grid := _blank()
	_put(enemy_grid, _make("goblin_warlord", 1), BoardData.ROWS - 1, BoardData.COLS - 1)
	_put(player_grid, _make("king", 0), BoardData.ROWS - 1, BoardData.COLS - 1)

	for m: int in [1, 3, 6, mana]:
		var engine := EnemyEngine.new()
		engine.weight_overrides = enc.survival_weights
		var t0 := Time.get_ticks_usec()
		var actions := engine.decide_actions(hand.duplicate(), player_grid, enemy_grid, m, 5)
		var ms := float(Time.get_ticks_usec() - t0) / 1000.0
		# What the plan actually SPENT — the number that says whether a short plan is the
		# engine under-committing or simply buying expensive bodies.
		var spent := 0
		var kinds: Array = []
		for a: Dictionary in actions:
			var inst: CardInstance = a.get("inst", a.get("unit", null))
			var c := 0
			if int(a["type"]) == EnemyEngine.Action.PLACE or int(a["type"]) == EnemyEngine.Action.CAST:
				c = int(inst.get_attribute("cost"))
			elif int(a["type"]) == EnemyEngine.Action.GENERATE:
				c = int((a["ability"] as AbilityData).mana)
			spent += c
			kinds.append("%s(%d)" % [inst.data.id if inst != null else "?", c])
		print("BENCH hand=%d mana=%2d -> %d actions, %d/%d mana spent in %.1f ms  %s"
				% [hand.size(), m, actions.size(), spent, m, ms, str(kinds)])
	get_tree().quit()


func _make(id: String, owner: int) -> CardInstance:
	var inst := CardInstance.from_data(CardData.get_card(id))
	inst.owner = owner
	# INERT (2026-08-13 ruling): the fill-to-max rode the nuked write form.
	return inst


func _put(grid: Array, inst: CardInstance, r: int, c: int) -> void:
	grid[r][c] = inst


func _blank() -> Array:
	var grid: Array = []
	for _r in BoardData.ROWS:
		var row: Array = []
		for _c in BoardData.COLS:
			row.append(null)
		grid.append(row)
	return grid
