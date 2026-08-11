extends TestCase

# CombatSide through the arbitration Resolver — the side-stat mutation forms (draw /
# discard / mana / max_mana): floors, pile/hand limits, NO mana cap (settled), set-forms,
# and presentation signals. This is Resolver + StatMutation behavior, a surviving system.
#
# Deliberately absent: anything through the old effect layer (dispatch payloads, legacy
# interceptors, authored content) — banished with that machinery; the rebuild's own suites
# cover side-stat payloads when the new structures deliver them.


func suite_name() -> String:
	return "Combat sides"


func run() -> void:
	_draw_form()
	_discard_form()
	_mana_form()
	_max_mana_form()
	_set_forms()
	_signals()
	_side_stat_vocabulary()


# A side with `n` units in its draw pile.
func _side_with_pile(side_owner: int, n: int) -> CombatSide:
	var s := CombatSide.make(side_owner)
	for _i in n:
		var inst := unit("pawn")
		inst.owner = side_owner
		s.draw_pile.append(inst)
	return s


func _draw_form() -> void:
	var s := _side_with_pile(0, 3)
	var out := Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 2))
	check_eq(out.delta, 2, "draw 2 moves 2 cards")
	check_eq(s.hand.size(), 2, "drawn cards sit in the hand")
	check_eq(s.draw_pile.size(), 1, "the pile shrank by the same 2")
	var over := Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 5))
	check_eq(over.delta, 1, "drawing past the pile stops at it (delta reports what moved)")
	var empty := Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 3))
	check_eq(empty.delta, 0, "an empty pile draws nothing")
	var negative := Resolver.submit(StatMutation.make(s, StatMutation.DRAW, -2))
	check_eq(negative.delta, 0, "a negative draw floors at 0 — never a discard")


func _discard_form() -> void:
	var s := _side_with_pile(0, 3)
	Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 3))
	var out := Resolver.submit(StatMutation.make(s, StatMutation.DISCARD, 2))
	check_eq(out.delta, 2, "discard 2 removes 2")
	check_eq(s.hand.size(), 1, "the hand shrank to 1")
	var over := Resolver.submit(StatMutation.make(s, StatMutation.DISCARD, 5))
	check_eq(over.delta, 1, "discarding past the hand stops at it")
	check_eq(s.hand.size(), 0, "hand empty")
	check_eq(Resolver.submit(StatMutation.make(s, StatMutation.DISCARD, 1)).delta, 0,
			"an empty hand discards nothing")


func _mana_form() -> void:
	var s := CombatSide.make(0)
	s.max_mana = 3
	s.mana = 3
	var gain := Resolver.submit(StatMutation.make(s, StatMutation.MANA, 2))
	check_eq(gain.delta, 2, "mana gain is UNCAPPED above max (settled: no clamp)")
	check_eq(s.mana, 5, "pool sits at 5 over a max of 3")
	var spend := Resolver.submit(StatMutation.make(s, StatMutation.MANA, -4))
	check_eq(s.mana, 1, "signed spend lands")
	check_eq(spend.delta, -4, "delta reports the landed spend")
	var floor_out := Resolver.submit(StatMutation.make(s, StatMutation.MANA, -9))
	check_eq(s.mana, 0, "mana floors at 0")
	check_eq(floor_out.delta, -1, "delta reports only what the floor allowed")


func _max_mana_form() -> void:
	var s := CombatSide.make(0)
	Resolver.submit(StatMutation.make(s, StatMutation.MAX_MANA, 3))
	check_eq(s.max_mana, 3, "max_mana is additive")
	var floor_out := Resolver.submit(StatMutation.make(s, StatMutation.MAX_MANA, -5))
	check_eq(s.max_mana, 0, "max_mana floors at 0")
	check_eq(floor_out.delta, -3, "delta reports what the floor allowed")


func _set_forms() -> void:
	var s := CombatSide.make(0)
	Resolver.set_side_max_mana(s, 4)
	Resolver.set_side_mana(s, 4)
	check(s.max_mana == 4 and s.mana == 4, "turn set-forms land as signed deltas")
	Resolver.set_side_mana(s, 2)
	check_eq(s.mana, 2, "set-form goes down too")


func _signals() -> void:
	var s := _side_with_pile(0, 2)
	var drawn_seen: Array = []
	var mana_bumps: Array = []
	s.cards_drawn.connect(func(insts: Array) -> void: drawn_seen.append_array(insts))
	s.mana_changed.connect(func() -> void: mana_bumps.append(true))
	Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 2))
	check_eq(drawn_seen.size(), 2, "cards_drawn carries the drawn instances")
	check(drawn_seen[0] is CardInstance and s.hand.has(drawn_seen[0]),
			"the presented instances ARE the hand's instances")
	Resolver.submit(StatMutation.make(s, StatMutation.MANA, 1))
	check_eq(mana_bumps.size(), 1, "mana_changed fires on a mana write")
	Resolver.submit(StatMutation.make(s, StatMutation.DRAW, 0))
	check_eq(drawn_seen.size(), 2, "a no-op draw emits nothing")


func _side_stat_vocabulary() -> void:
	check(StatMutation.is_side_stat("draw") and StatMutation.is_side_stat("max_mana")
			and not StatMutation.is_side_stat("attack"), "the side-stat vocabulary set")
