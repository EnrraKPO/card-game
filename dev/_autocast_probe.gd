extends Node
# Throwaway: verifies the autocast target gate agrees with the tray-token gate for a
# slot-targeting ability (the Barracks' Conscription). Run WITH autoloads:
#   godot --headless --path . res://dev/_autocast_probe.tscn

var _fails := 0


func _check(ok: bool, label: String) -> void:
	print(("  PASS  " if ok else "  FAIL  ") + label)
	if not ok:
		_fails += 1


func _slot(owner_id: int) -> SlotUI:
	var s := SlotUI.new()
	s.location = BoardLocation.at(owner_id, 0, 0)
	s.custom_minimum_size = Vector2(165, 216)
	add_child(s)
	return s


func _ready() -> void:
	await get_tree().process_frame

	# A real board over a real world: "fielded" is a fact of the BOARD now, not a coordinate
	# the unit carries, so the fixture has to actually stand the holder somewhere.
	var board := CombatBoard.new()
	add_child(board)
	board.setup_grids()
	var row := HBoxContainer.new()
	add_child(row)
	board.build_section(row, true)
	board.build_section(row, false)
	var world := CombatWorld.make(GameData.current_modifiers)
	world.rewards_live = false
	board.world = world

	var caster := SpellCaster.new()
	caster.board = board
	caster.get_mana = func() -> int: return 99
	add_child(caster)

	# A fielded Barracks with Conscription armed.
	var holder := CardInstance.from_data(CardData.get_card("pawn_rook"))
	world.place_unit(holder, 0, 0, 0)
	holder.autocast_ability = "pawn_material"

	var ab := holder.armed_autocast()
	_check(ab != null, "the Barracks arms pawn_material")
	if ab == null:
		get_tree().quit(1)
		return

	var own_empty := _slot(0)
	var enemy_empty := _slot(1)
	await get_tree().process_frame

	# THE fix: an empty own slot is a legal autocast pick (it is the ability's spawn case).
	_check(caster.autocast_drop_ok(holder, own_empty),
			"empty OWN slot accepts the armed holder drop")
	# Both gestures must agree — this is the parity that was broken.
	_check(caster.effects_target_ok(ab.effects, own_empty),
			"the shared judge accepts it too (tray-token parity)")
	# Side gate still holds.
	_check(not caster.autocast_drop_ok(holder, enemy_empty),
			"empty ENEMY slot is still rejected")
	# Cost gate still holds.
	holder.attack_exhausted = true
	_check(not caster.autocast_drop_ok(holder, own_empty),
			"a tapped holder still cannot autocast")
	holder.attack_exhausted = false
	var poor := SpellCaster.new()
	poor.get_mana = func() -> int: return 0
	add_child(poor)
	_check(not poor.autocast_drop_ok(holder, own_empty),
			"an unaffordable ability is still rejected")

	print("PROBE: %s" % ("OK" if _fails == 0 else "%d FAILED" % _fails))
	get_tree().quit(1 if _fails > 0 else 0)
