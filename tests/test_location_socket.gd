extends TestCase

# THE EFFECT-SIDE SOCKET (LOCATION_MANAGER_DESIGN.md §4.6): an effect names where it
# resolves FROM and what SHAPE that implies, and gets game objects back. It never sees a
# coordinate, and geometry never sees a condition.
#
# Everything here is computation over test-owned fixtures — what the socket RESOLVES, not
# what any shipped card does with it.

const T_STATUSES := {
	"_t_soot": {"id": "_t_soot", "decay": "duration", "default_duration": 3,
			"stacking": "stack", "max_stacks": 5},
}


func suite_name() -> String:
	return "Location socket"


func run() -> void:
	for sid: String in T_STATUSES:
		StatusData._all[sid] = StatusData.from_dict(T_STATUSES[sid])
	_defaults_reproduce_what_shipped()
	_location_policies()
	_shapes()
	_the_battle_line_is_a_rule()
	_the_ground_layer()
	_conditions_still_gate()
	_round_trip()
	_whiffs_are_answers()
	for sid: String in T_STATUSES:
		StatusData._all.erase(sid)


func _world() -> CombatWorld:
	var w := CombatWorld.make(GameData.current_modifiers)
	w.rewards_live = false
	return w


func _place(w: CombatWorld, card_id: String, side_owner: int, r: int, c: int) -> CardInstance:
	var inst := unit(card_id)
	w.place_unit(inst, r, c, side_owner)
	return inst


func _socket(d: Dictionary) -> TargetResolver.AtLocation:
	var full := {"kind": "at_location"}
	full.merge(d)
	return TargetResolver.parse(full) as TargetResolver.AtLocation


# ── The defaults are the old behaviour, exactly ─────────────────────────────────────────

func _defaults_reproduce_what_shipped() -> void:
	var at := _socket({})
	check_eq(at.from, "anchor", "the default policy is the effect's anchor")
	check_eq(at.shape, "here", "the default shape is the one cell")
	check_eq(at.layer, "pieces", "the default layer yields units")
	check_eq(at.half, "any", "the battle line is not a wall unless an effect says so")

	var w := _world()
	var standing := _place(w, "pawn", 1, 0, 3)
	var ctx := w.make_context(null)
	ctx.anchor_at = BoardLocation.at(1, 0, 3)
	var got: Array = at.resolve(null, null, ctx)
	check(got.size() == 1 and got[0] == standing,
			"an unparameterised socket is still \"the unit at my anchor\"")


# ── Where it resolves FROM ──────────────────────────────────────────────────────────────

func _location_policies() -> void:
	var w := _world()
	var holder := _place(w, "rook", 0, 1, 1)
	var neighbour := _place(w, "pawn", 0, 1, 2)
	var victim := _place(w, "knight", 1, 2, 0)
	var ctx := w.make_context(holder)

	# "holder" — where the effect's own unit stands. Nothing is read off the unit: the board
	# is asked, which is the whole point.
	var here := _socket({"from": "holder"})
	var got: Array = here.resolve(null, holder, ctx)
	check(got.size() == 1 and got[0] == holder, "policy 'holder' resolves from where the holder stands")

	# "picked" — a player's slot gesture, carried as one whole address.
	ctx.manual_at = BoardLocation.at(0, 1, 2)
	var picked := _socket({"from": "picked"})
	var pg: Array = picked.resolve(null, holder, ctx)
	check(pg.size() == 1 and pg[0] == neighbour, "policy 'picked' resolves from the picked square")

	# "origin" / "destination" — the event's participants, by WHERE they are rather than by
	# who they are. That is the difference from the participant kind, and it is what a
	# bouncing effect will need: the square survives the unit standing on it (§2.7).
	var ev := GameEvent.make(&"struck", victim, holder)
	var org := _socket({"from": "origin"})
	var og: Array = org.resolve(ev, holder, ctx)
	check(og.size() == 1 and og[0] == victim, "policy 'origin' resolves from the event's origin")
	var dst := _socket({"from": "destination"})
	var dg: Array = dst.resolve(ev, holder, ctx)
	check(dg.size() == 1 and dg[0] == holder, "policy 'destination' resolves from the event's destination")
	# No event, no participant — a whiff, by construction.
	check(org.resolve(null, holder, ctx).is_empty(),
			"a participant policy without an event resolves to nothing")

	# An unknown policy is a BUG, not a degrade to something plausible (the push_error below
	# is the fence proving itself).
	var bad := _socket({"from": "wherever"})
	check_eq(bad.from, "anchor", "an unknown policy is reported and falls back visibly")


# ── The geometry procedure ──────────────────────────────────────────────────────────────

func _shapes() -> void:
	var w := _world()
	var centre := _place(w, "rook", 0, 1, 1)
	var up := _place(w, "pawn", 0, 0, 1)
	var down := _place(w, "pawn", 0, 2, 1)
	var left := _place(w, "pawn", 0, 1, 0)
	var far := _place(w, "pawn", 0, 0, 3)
	var ctx := w.make_context(centre)

	# "around" — the cells one step away. The centre is NOT among them.
	var around := _socket({"from": "holder", "shape": "around"})
	var got: Array = around.resolve(null, centre, ctx)
	check_eq(got.size(), 3, "'around' finds the three occupied neighbours")
	check(got.has(up) and got.has(down) and got.has(left), "…and exactly those three")
	check(not got.has(centre), "…never the origin itself")
	check(not got.has(far), "…and nothing two steps away")

	# "nearest" — every cell ordered by distance, the origin first. `count` takes the front
	# of that list, so "the two nearest" is one authored number, not a second search.
	var nearest := _socket({"from": "holder", "shape": "nearest", "count": 2})
	var near: Array = nearest.resolve(null, centre, ctx)
	check_eq(near.size(), 2, "'nearest' with count 2 returns two")
	check(near[0] == centre, "…the origin's own occupant first (distance 0)")
	check(near[1] == up or near[1] == down or near[1] == left,
			"…then a neighbour, before anything further out")

	# Uncounted, it finds everyone — geometry orders, the caller stops when it likes.
	var all_near := _socket({"from": "holder", "shape": "nearest"})
	check_eq((all_near.resolve(null, centre, ctx) as Array).size(), 5,
			"'nearest' with no count walks the whole board")


func _the_battle_line_is_a_rule() -> void:
	# Whether the halves touch is a GAME RULE, so it lives on the socket, not in geometry
	# (§4.4). The front columns are adjacent, so 'around' crosses the line by default.
	var w := _world()
	var front := _place(w, "rook", 0, 1, BoardData.COLS - 1)
	var across := _place(w, "pawn", 1, BoardData.ROWS - 1 - 1, 0)
	var ctx := w.make_context(front)

	var open := _socket({"from": "holder", "shape": "around"})
	check((open.resolve(null, front, ctx) as Array).has(across),
			"by default a shape reaches across the battle line")
	var walled := _socket({"from": "holder", "shape": "around", "half": "same"})
	check(not (walled.resolve(null, front, ctx) as Array).has(across),
			"half 'same' makes the line a wall — an authored rule, not a geometry fact")


# ── The other layer ─────────────────────────────────────────────────────────────────────

func _the_ground_layer() -> void:
	var w := _world()
	var burner := _place(w, "rook", 0, 1, 1)
	var ctx := w.make_context(burner)

	var ground := _socket({"from": "holder", "shape": "around", "half": "same", "layer": "ground"})
	var got: Array = ground.resolve(null, burner, ctx)
	check_eq(got.size(), 4, "the ground layer answers for every neighbouring cell")
	check(got.all(func(o: Object) -> bool: return o is BoardSlot),
			"…as slots, resolved by the façade — the caller never casts")
	# The ground EXISTS everywhere: cells nothing has touched still come back, or a spreading
	# fire would skip the squares it had not visited yet.
	var fresh := _socket({"from": "holder", "shape": "here", "layer": "ground"})
	check_eq((fresh.resolve(null, burner, ctx) as Array).size(), 1,
			"a never-touched cell still has ground on it")

	# End to end: an effect delivering a status through the socket lands on the SLOTS.
	var e := Effect.from_dict({"trigger": "on_play",
			"targets": {"kind": "at_location", "from": "holder", "shape": "around",
				"half": "same", "layer": "ground"},
			"status": {"id": "_t_soot", "stacks": 2}})
	var results := EffectSystem.apply_single(e, burner, ctx)
	check_eq(results.size(), 4, "the delivery reports one result per caught cell")
	check(w.slot_at(0, 0, 1).find_status("_t_soot") != null, "the cell above caught it")
	check(w.slot_at(0, 2, 1).find_status("_t_soot") != null, "the cell below caught it")
	check(w.slot_at(0, 1, 0).find_status("_t_soot") != null, "the cell behind caught it")
	check(w.slot_at(0, 1, 2).find_status("_t_soot") != null, "the cell ahead caught it")
	check(w.slot_at(0, 1, 1).find_status("_t_soot") == null,
			"…and the cell the holder stands on did not — 'around' excludes the origin")
	var si := w.slot_at(0, 0, 1).find_status("_t_soot")
	check(si != null and si.stacks == 2, "the authored stack count arrives intact")

	# A slot has nothing the condition grammar can predicate on — refused at parse, loudly,
	# rather than silently ignored (the push_error is the fence).
	var conditioned := _socket({"layer": "ground",
			"conditions": [{"attribute": "attack", "comparator": "gte", "value": 1}]})
	check(conditioned.conditions.is_empty(), "ground targeting drops authored conditions, loudly")


func _conditions_still_gate() -> void:
	# The fence §4.4 draws: geometry hands back locations, the socket asks the façade what is
	# there, and the AUTHORED conditions do the filtering — the same grammar as every other
	# kind. Geometry never learns a predicate.
	var w := _world()
	var centre := _place(w, "rook", 0, 1, 1)
	var hurt := _place(w, "pawn", 0, 0, 1)
	_place(w, "pawn", 0, 2, 1)
	Resolver.submit(StatMutation.damage(hurt, 1, null))
	var ctx := w.make_context(centre)

	var wounded := _socket({"from": "holder", "shape": "around",
			"conditions": [{"attribute": "health", "comparator": "lte", "value": 2}]})
	var got: Array = wounded.resolve(null, centre, ctx)
	check(got.size() == 1 and got[0] == hurt, "authored conditions gate what the shape found")


func _round_trip() -> void:
	var authored := {"kind": "at_location", "from": "destination", "shape": "nearest",
			"layer": "ground", "half": "same", "count": 3}
	var back: Dictionary = (TargetResolver.parse(authored) as TargetResolver.AtLocation).to_dict()
	check_eq(back, authored, "every socket key round-trips")
	# Defaults stay OUT of the serialised form, so untouched data keeps its bytes.
	check_eq((TargetResolver.parse({"kind": "at_location"}) as TargetResolver.AtLocation).to_dict(),
			{"kind": "at_location"}, "an unparameterised socket serialises back bare")

	var e := Effect.from_dict({"trigger": "on_play",
			"targets": authored, "attribute": "health", "amount": -1})
	check(e.targets_resolver() is TargetResolver.AtLocation, "the effect builds the socket kind")
	check_eq(e.targeting_policy, Effect.TargetingPolicy.AT_LOCATION,
			"…and mirrors to the compat policy, whatever its parameters")


func _whiffs_are_answers() -> void:
	# Emptiness is an ANSWER, not a miss (§2.9). None of these is an error.
	var w := _world()
	var lonely := _place(w, "rook", 0, 0, 0)
	var ctx := w.make_context(lonely)
	var around := _socket({"from": "holder", "shape": "around"})
	check((around.resolve(null, lonely, ctx) as Array).is_empty(),
			"a shape over empty cells resolves to nobody, quietly")

	var offboard := unit("pawn")
	check((_socket({"from": "holder"}).resolve(null, offboard, ctx) as Array).is_empty(),
			"a holder that stands nowhere resolves from nowhere")

	var bare := w.make_context(lonely)
	check((_socket({}).resolve(null, lonely, bare) as Array).is_empty(),
			"no anchor set means nothing to resolve from")
