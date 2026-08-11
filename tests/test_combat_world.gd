extends TestCase

# CombatWorld: the cohesive context of combat rules state and its snapshot (copy()) — the
# Step-1 contract of COMBAT_DECOUPLING_REFACTOR.md. Pins: copy INDEPENDENCE (mutating either
# side of a snapshot never touches the other), identity-remap COMPLETENESS (no reference
# inside a copy resolves to an original object — killed_by_unit, a status's
# source and carrier, hand/pile cards), the TWO-TIER rule (mutable state deep-copied,
# immutable defs/modifiers shared), tracker re-binding (a copy's standing effects fold from
# the copy's own stacks), and the rewards_live policy flip (a copy never pays).


func suite_name() -> String:
	return "Combat world"


func run() -> void:
	_construction()
	_grid_copy_independence()
	_status_copy_independence()
	_side_copy_independence()
	_remap_completeness()
	_off_world_reference_copies()
	_shared_immutables()
	_tracker_rebind()
	_kill_provenance_cycle()
	_policy_flip()
	_turn_order()


# A unit of the fixture card placed on the world's grid at (r, c) for the given side.
func _place(w: CombatWorld, card_id: String, side_owner: int, r: int, c: int) -> CardInstance:
	var inst := unit(card_id)
	w.place_unit(inst, r, c, side_owner)
	return inst


func _cell(w: CombatWorld, side_owner: int, r: int, c: int) -> CardInstance:
	var grid: Array = w.grid_of(side_owner)
	var grid_row: Array = grid[r]
	return grid_row[c]


func _construction() -> void:
	var w := CombatWorld.make()
	check_eq(w.player_grid.size(), BoardData.ROWS, "player grid has ROWS rows")
	var first_row: Array = w.player_grid[0]
	check_eq(first_row.size(), BoardData.COLS, "each row has COLS cells")
	check(w.side(0) == w.player_side and w.side(1) == w.enemy_side, "side() routes by owner")
	check_eq(w.grid_of(1), w.enemy_grid, "grid_of() routes by side")
	check(w.rewards_live, "a made world is live — it pays rewards")


func _grid_copy_independence() -> void:
	var w := CombatWorld.make()
	var pawn := _place(w, "pawn", 0, 0, 0)
	_place(w, "king", 1, 2, 3)
	var w2 := w.copy()
	var pawn2 := _cell(w2, 0, 0, 0)

	check(pawn2 != null and pawn2 != pawn, "the copied cell holds a DIFFERENT object")
	check(_cell(w2, 1, 2, 3) != null, "every occupied cell copies")
	check_eq(pawn2.current_health, pawn.current_health, "copied unit carries the same health")
	check(w2.location_of(pawn2) == BoardLocation.at(0, 0, 0), "placement copies with the world")
	check_eq(w2.location_of(pawn), null, "and the copy knows nothing of the live units")

	# Mutate the copy — the original must not move.
	pawn2.current_health -= 2
	pawn2.apply_modifier("attack", 3)
	check_eq(pawn.current_health, pawn2.current_health + 2, "damaging the copy leaves the original whole")
	check_eq(pawn.get_attribute("attack"), pawn2.get_attribute("attack") - 3,
			"a stat write on the copy never reaches the original")

	# Clear a cell on the copy (a simulated death) — the live board keeps its unit.
	w2.locations.undock(pawn2)
	check(_cell(w2, 0, 0, 0) == null, "the copy's cell is empty")
	check(_cell(w, 0, 0, 0) == pawn, "emptying the copy's cell leaves the live board intact")

	# And the reverse: the live game moving on must not disturb a held snapshot.
	var w3 := w.copy()
	pawn.current_health -= 1
	var pawn3 := _cell(w3, 0, 0, 0)
	check_eq(pawn3.current_health, pawn.current_health + 1, "mutating the original leaves a held snapshot frozen")


func _status_copy_independence() -> void:
	var w := CombatWorld.make()
	var pawn := _place(w, "pawn", 0, 0, 0)
	StatusEngine.apply(pawn, "empowered", Effect.STATUS_DURATION_DEFAULT, 1, null)
	var w2 := w.copy()
	var pawn2 := _cell(w2, 0, 0, 0)

	check_eq(pawn2.statuses.size(), 1, "statuses copy")
	var si: StatusInstance = pawn.statuses[0]
	var si2: StatusInstance = pawn2.statuses[0]
	check(si2 != si, "the copied status is a different instance")
	check_eq(si2.remaining, si.remaining, "remaining copies")

	# Advance the copy's clock to expiry — the original's status must survive.
	StatusEngine.advance(pawn2, &"turn_end")
	StatusEngine.advance(pawn2, &"turn_end")
	check(pawn2.find_status("empowered") == null, "the copy's status expires on the copy's clock")
	check(pawn.find_status("empowered") != null, "…and the original's is untouched")

	# A status applied to the copy never appears on the original.
	StatusEngine.apply(pawn2, "empowered", Effect.STATUS_DURATION_DEFAULT, 1, null)
	check_eq(pawn.statuses.size(), 1, "a status applied to the copy stays on the copy")


func _side_copy_independence() -> void:
	var w := CombatWorld.make()
	w.player_side.mana = 3
	w.player_side.max_mana = 5
	for _i in 3:
		var c := unit("pawn")
		w.player_side.draw_pile.append(c)
	var held := unit("knight")
	w.player_side.hand.append(held)
	var w2 := w.copy()

	check_eq(w2.player_side.mana, 3, "mana copies")
	check_eq(w2.player_side.max_mana, 5, "max mana copies")
	check_eq(w2.player_side.hand.size(), 1, "hand copies")
	check_eq(w2.player_side.draw_pile.size(), 3, "pile copies")
	check(w2.player_side.hand[0] != held, "hand cards are copies, not shared refs")

	# Draw and spend on the copy — the live side must not move.
	Resolver.submit(StatMutation.make(w2.player_side, StatMutation.DRAW, 2))
	w2.player_side.set_mana(0)
	check_eq(w.player_side.hand.size(), 1, "drawing on the copy leaves the live hand alone")
	check_eq(w.player_side.draw_pile.size(), 3, "…and the live pile")
	check_eq(w.player_side.mana, 3, "…and the live mana")


func _remap_completeness() -> void:
	var w := CombatWorld.make()
	var pawn := _place(w, "pawn", 0, 0, 0)
	var king := _place(w, "king", 0, 2, 0)
	var rook := _place(w, "rook", 0, 1, 1)
	StatusEngine.apply(pawn, "empowered", Effect.STATUS_DURATION_DEFAULT, 1, king)
	pawn.killed_by_unit = rook
	pawn.killed_by_channel = &"attack"
	var w2 := w.copy()
	var pawn2 := _cell(w2, 0, 0, 0)
	var king2 := _cell(w2, 0, 2, 0)
	var rook2 := _cell(w2, 0, 1, 1)

	var si2: StatusInstance = pawn2.statuses[0]
	check(si2.source == king2, "a status's source remaps to the COPIED unit")
	check(si2._carrier_ref != null and si2._carrier_ref.get_ref() == pawn2,
			"a status's carrier rebinds to the copy")
	check(pawn2.killed_by_unit == rook2, "killed_by_unit remaps to the copied killer")
	check_eq(pawn2.killed_by_channel, &"attack", "kill provenance channel copies")


func _off_world_reference_copies() -> void:
	# A reference to a unit NOT on the world (a buried killer, a dead status source) still
	# copies — the remap grows to cover it, so no original ever leaks into a snapshot.
	var w := CombatWorld.make()
	var pawn := _place(w, "pawn", 0, 0, 0)
	var dead := unit("knight")
	pawn.killed_by_unit = dead
	StatusEngine.apply(pawn, "empowered", Effect.STATUS_DURATION_DEFAULT, 1, dead)
	var w2 := w.copy()
	var pawn2 := _cell(w2, 0, 0, 0)

	check(pawn2.killed_by_unit != dead, "an off-world killer never leaks into the copy")
	check(pawn2.killed_by_unit != null and pawn2.killed_by_unit.data == dead.data,
			"…it is copied instead, same definition")
	var si2: StatusInstance = pawn2.statuses[0]
	check(si2.source == pawn2.killed_by_unit,
			"the ONE remap spans all reference kinds — killer and status source converge on one copy")


func _shared_immutables() -> void:
	var mods := ModifierSet.new()
	var w := CombatWorld.make(mods)
	var pawn := _place(w, "pawn", 0, 0, 0)
	StatusEngine.apply(pawn, "empowered", Effect.STATUS_DURATION_DEFAULT, 1, null)
	var w2 := w.copy()
	var pawn2 := _cell(w2, 0, 0, 0)

	check(pawn2.data == pawn.data, "CardData is shared, never copied")
	var si: StatusInstance = pawn.statuses[0]
	var si2: StatusInstance = pawn2.statuses[0]
	check(si2.data == si.data, "StatusData is shared, never copied")
	check(w2.modifiers == mods, "the modifier set is shared into copies (full-fidelity sims)")


func _tracker_rebind() -> void:
	var w := CombatWorld.make()
	var pawn := _place(w, "pawn", 0, 0, 0)
	var atk0 := pawn.get_attribute("attack")
	StatusEngine.apply(pawn, "charged", Effect.STATUS_DURATION_DEFAULT, 3, null)
	check_eq(pawn.get_attribute("attack"), atk0 + 3, "charged folds live (tracker went live pre-copy)")

	var w2 := w.copy()
	var pawn2 := _cell(w2, 0, 0, 0)
	check_eq(pawn2.get_attribute("attack"), atk0 + 3, "the copy folds the same standing bonus")

	# The copy's trackers must watch the COPY's stacks, not the original's.
	var si2 := pawn2.find_status("charged")
	si2.stacks = 0
	check_eq(pawn2.get_attribute("attack"), atk0, "zeroing the copy's stacks kills the copy's fold")
	check_eq(pawn.get_attribute("attack"), atk0 + 3, "…while the original keeps folding its own")

	# And the mirror: the original's tracker dying must not reach the copy.
	var w3 := w.copy()
	var si := pawn.find_status("charged")
	si.stacks = 0
	var pawn3 := _cell(w3, 0, 0, 0)
	check_eq(pawn3.get_attribute("attack"), atk0 + 3, "a held snapshot's fold survives the original's expiry")


func _kill_provenance_cycle() -> void:
	# Mutual killers: a reference cycle through killed_by_unit must terminate (the remap
	# memoizes BEFORE references fill) and both references must converge inside the copy.
	var w := CombatWorld.make()
	var a := _place(w, "pawn", 0, 0, 0)
	var b := _place(w, "knight", 1, 0, 3)
	a.killed_by_unit = b
	b.killed_by_unit = a
	var w2 := w.copy()
	var a2 := _cell(w2, 0, 0, 0)
	var b2 := _cell(w2, 1, 0, 3)

	check(a2.killed_by_unit == b2, "cycle: a's killer remaps to the copied b")
	check(b2.killed_by_unit == a2, "cycle: b's killer remaps to the copied a")


func _policy_flip() -> void:
	var w := CombatWorld.make()
	check(w.rewards_live, "the live world pays")
	var w2 := w.copy()
	check(not w2.rewards_live, "a copy never pays — hypotheticals write no run state")
	var w3 := w2.copy()
	check(not w3.rewards_live, "…nor does a copy of a copy")


# The activation order is the CONTRACT between the round loop and the turn-order strip that
# advertises it (see CombatWorld.turn_order / TurnOrderStrip): one sort, walked by both. Every
# tie is broken deterministically on purpose — an arbitrary order between equal units reads to
# the player as a rule, and a display that guessed differently from the fight would be a lie.
func _turn_order() -> void:
	var w := CombatWorld.make()
	var slow := _place(w, "pawn", 0, 0, 0)
	slow.apply_modifier("speed", -5)
	var fast := _place(w, "pawn", 0, 1, 0)
	fast.apply_modifier("speed", 5)
	var order := w.turn_order()
	check(order[0] == fast and order[1] == slow, "speed decides first")

	# Equal speed, opposite armies: the player's unit acts first.
	var w2 := CombatWorld.make()
	var mine := _place(w2, "pawn", 0, 0, 0)
	var theirs := _place(w2, "pawn", 1, 0, 0)
	check(w2.turn_order()[0] == mine, "on equal speed the player's army goes first")

	# Equal speed, same army: the unit further FORWARD (deeper into the enemy) goes first, and
	# the back row settles a shared column.
	var w3 := CombatWorld.make()
	var back := _place(w3, "pawn", 0, 0, 0)
	var front := _place(w3, "pawn", 0, 0, BoardData.COLS - 1)
	var deep_row := _place(w3, "pawn", 0, BoardData.ROWS - 1, BoardData.COLS - 1)
	var o3 := w3.turn_order()
	check(o3[0] == deep_row and o3[1] == front and o3[2] == back,
			"depth first, then the back row — every tie broken")

	# The enemy's depth is mirrored: its forward column is the LOW one.
	var w4 := CombatWorld.make()
	var e_back := _place(w4, "pawn", 1, 0, BoardData.COLS - 1)
	var e_front := _place(w4, "pawn", 1, 0, 0)
	check(w4.turn_order()[0] == e_front, "the enemy's depth runs the other way")
	check(w4.turn_order().size() == 2 and e_back != null, "…and every unit on the board is listed")
