extends Node
# Throwaway probe: the round-3 board from combat log 2026-07-31 18:15 — the one-column
# stack (fodder r0c3, captain r1c2, support r1c3, dps r2c3) — read through the v2 exposure
# model and the chain form of Formation, against the user's stated ideal (cheap bodies one
# column up, the prize alone behind).
#   godot --headless --path . res://dev/_formation_probe.tscn


func _unit(card_id: String, r: int, c: int) -> CardInstance:
	var inst := CardInstance.from_data(CardData.get_card(card_id))
	inst.owner = 1
	inst.row = r
	inst.col = c
	return inst


func _board(units: Array) -> BoardState:
	var player_grid: Array = []
	var enemy_grid: Array = []
	for _r in BoardData.ROWS:
		var pr: Array = []
		var er: Array = []
		for _c in BoardData.COLS:
			pr.append(null)
			er.append(null)
		player_grid.append(pr)
		enemy_grid.append(er)
	for u: CardInstance in units:
		enemy_grid[u.row][u.col] = u
	return BoardState.capture(player_grid, enemy_grid)


func _dump(label: String, s: BoardState) -> void:
	BoardScoring.run_valuation(s, null)
	print("\n── %s ──" % label)
	for u: BoardState.UnitState in s.units(1):
		print("   %-16s r%dc%d  raw %.2f  exposure %.4f" % [u.card_id, u.row, u.col,
				u.raw_value, BoardScoring.exposure_of(s, 1, u.row, u.col)])
	print("   formation_order = %.4f" % BoardScoring.formation_order(s, 1))


func _ready() -> void:
	# What the CPU actually built: everything stacked in column 3 (+captain c2).
	_dump("actual (the c3 stack)", _board([
			_unit("fodder_dummy", 0, 3), _unit("captain_dummy", 1, 2),
			_unit("support_dummy", 1, 3), _unit("dps_dummy", 2, 3)]))
	# The user's ideal: chain of protection — support (the prize, 6.3) deepest, dps
	# screening it, captain next, fodder at the true front.
	_dump("ideal (the chain)", _board([
			_unit("fodder_dummy", 0, 0), _unit("captain_dummy", 1, 1),
			_unit("dps_dummy", 1, 2), _unit("support_dummy", 1, 3)]))
	get_tree().quit()
