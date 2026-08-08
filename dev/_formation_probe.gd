extends Node
# Throwaway probe, two parts:
#   1. The four offending boards from tonight's logs, scored by the restored measure
#      (value order vs v2 exposure order) next to their repaired versions.
#   2. The exact 20:13 failure position run through the FULL engine — what turn does it
#      plan now?
#   godot --headless --path D:\Godot\CardGame res://dev/_formation_probe.tscn


var _seats: Dictionary = {}   # CardInstance -> Vector2i(row, col), the probe's layout


func _inst(card_id: String, owner: int, r: int, c: int) -> CardInstance:
	var inst := CardInstance.from_data(CardData.get_card(card_id))
	inst.owner = owner
	_seats[inst] = Vector2i(r, c)
	return inst


func _grids(enemy: Array, player: Array = []) -> Array:
	var pg: Array = []
	var eg: Array = []
	for _r in BoardData.ROWS:
		var pr: Array = []
		var er: Array = []
		for _c in BoardData.COLS:
			pr.append(null)
			er.append(null)
		pg.append(pr)
		eg.append(er)
	for u: CardInstance in player:
		var ps: Vector2i = _seats[u]
		pg[ps.x][ps.y] = u
	for u: CardInstance in enemy:
		var es: Vector2i = _seats[u]
		eg[es.x][es.y] = u
	return [pg, eg]


func _score(label: String, enemy: Array) -> void:
	var grids := _grids(enemy)
	var s := BoardState.capture(grids[0], grids[1])
	print("   %-46s formation %.4f" % [label, BoardScoring.formation_order(s, 1)])


func _ready() -> void:
	print("\n── the logged boards, old vs repaired ──")
	# 19:19 — dps in front of the fodder vs behind it (captain r0c1, fodder r1c3).
	_score("19:19 dps fronting the fodder (r1c2)", [_inst("captain_dummy", 1, 0, 1),
			_inst("fodder_dummy", 1, 1, 3), _inst("dps_dummy", 1, 1, 2)])
	_score("19:19 dps behind (r0c3)", [_inst("captain_dummy", 1, 0, 1),
			_inst("fodder_dummy", 1, 1, 3), _inst("dps_dummy", 1, 0, 3)])
	# 19:28 — support stacked onto the fodder's column vs the spread.
	_score("19:28 support stacked on fodder (both c3)", [_inst("captain_dummy", 1, 1, 2),
			_inst("fodder_dummy", 1, 0, 3), _inst("support_dummy", 1, 1, 3)])
	_score("19:28 spread (fodder c2? no — fodder mid)", [_inst("captain_dummy", 1, 1, 1),
			_inst("fodder_dummy", 1, 0, 2), _inst("support_dummy", 1, 1, 3)])
	# 20:13 — the fodder in the deepest seat over the support.
	_score("20:13 fodder deepest, support c1", [_inst("captain_dummy", 1, 0, 0),
			_inst("support_dummy", 1, 0, 1), _inst("fodder_dummy", 1, 0, 3)])
	_score("20:13 repaired: support deepest, fodder mid", [_inst("captain_dummy", 1, 0, 0),
			_inst("fodder_dummy", 1, 0, 2), _inst("support_dummy", 1, 0, 3)])

	# Part 2 — the 20:13 position, planned live: captain r2c3 (start), fodder placed T1
	# at r0c3, support arriving T2 with mana 2. We replay T2's planning input exactly:
	# captain already at r0c0 (its T1 move), fodder r0c3, support in hand.
	var grids := _grids(
			[_inst("captain_dummy", 1, 0, 0), _inst("fodder_dummy", 1, 0, 3)],
			[_inst("pawn", 0, 1, 0), _inst("knight", 0, 2, 0), _inst("king", 0, 2, 1)])
	var support := _inst("support_dummy", 1, -1, -1)
	var engine := EnemyEngine.new(RandomNumberGenerator.new())
	var actions: Array = engine.decide_actions([support], grids[0], grids[1], 2, 2)
	print("\n── the T2 turn the engine now plans ──")
	for a: Dictionary in actions:
		match int(a["type"]):
			EnemyEngine.Action.PLACE:
				print("   place %s → r%dc%d" % [(a["inst"] as CardInstance).data.id,
						int(a["row"]), int(a["col"])])
			EnemyEngine.Action.MOVE:
				print("   move  %s → r%dc%d" % [(a["inst"] as CardInstance).data.id,
						int(a["row"]), int(a["col"])])
			_:
				print("   (other action)")
	get_tree().quit()
