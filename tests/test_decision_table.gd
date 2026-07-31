extends TestCase

# The judge/peer decision table (BoardScoring.peer_shares / judge_factor): the contract
# every anchor of the design conversation rests on. These pins are the algebra's spec —
# if one breaks, the meaning of every authored weight changes with it.


func suite_name() -> String:
	return "Decision table"


func run() -> void:
	_lone_peer_means_what_it_says()
	_two_peers_dilute_proportionally()
	_five_equal_hungers_eat_equally()
	_order_never_matters()
	_share_never_exceeds_weight()
	_bigger_table_bigger_claim()
	_zero_and_empty_tables()
	_out_of_range_weights_clamp()
	_judge_factor_anchors()


func _close(a: float, b: float) -> bool:
	return absf(a - b) < 0.0001


# A peer alone at the table gets exactly its weight: 0.4 means 0.4.
func _lone_peer_means_what_it_says() -> void:
	var s := BoardScoring.peer_shares([0.4])
	check(_close(float(s[0]), 0.4), "lone 0.4 peer holds exactly 0.4")
	s = BoardScoring.peer_shares([1.0])
	check(_close(float(s[0]), 1.0), "lone 1.0 peer holds the whole decision")


# (0.2, 0.4): together they claim 1 − 0.8×0.6 = 0.52, split 1:2 — the conversation's
# founding example.
func _two_peers_dilute_proportionally() -> void:
	var s := BoardScoring.peer_shares([0.2, 0.4])
	check(_close(float(s[0]) + float(s[1]), 0.52), "0.2+0.4 claim 0.52 together")
	check(_close(float(s[1]) / float(s[0]), 2.0), "0.4 speaks exactly twice as loud as 0.2")


# Five 0.4s: even parts of 1 − 0.6^5 ≈ 0.9222 — each ~0.184, not 0.4. Attention divides.
func _five_equal_hungers_eat_equally() -> void:
	var s := BoardScoring.peer_shares([0.4, 0.4, 0.4, 0.4, 0.4])
	var want := (1.0 - pow(0.6, 5)) / 5.0
	for i in 5:
		check(_close(float(s[i]), want), "five 0.4s: seat %d eats the even share" % i)


# (0.1, 0.2) behaves exactly like (0.2, 0.1): influence comes from weight, never position.
func _order_never_matters() -> void:
	var ab := BoardScoring.peer_shares([0.1, 0.2])
	var ba := BoardScoring.peer_shares([0.2, 0.1])
	check(_close(float(ab[0]), float(ba[1])) and _close(float(ab[1]), float(ba[0])),
			"(0.1,0.2) mirrors (0.2,0.1)")


# Dilution only ever shrinks: no seat ends up with more than its stated hunger.
func _share_never_exceeds_weight() -> void:
	var weights := [0.4, 0.4, 0.5, 0.9, 0.05]
	var s := BoardScoring.peer_shares(weights)
	var ok := true
	for i in weights.size():
		if float(s[i]) > float(weights[i]) + 0.0001:
			ok = false
	check(ok, "no share exceeds its weight")
	# The (0.4, 0.4, 0.5) anchor: the 0.5 ends near a third of the whole decision.
	s = BoardScoring.peer_shares([0.4, 0.4, 0.5])
	check(float(s[2]) > 0.3 and float(s[2]) < 0.35, "0.5 among two 0.4s holds about a third")


# A weight-1 peer drives the table's combined claim to 1 (nothing is left unclaimed), but
# as a PEER it still shares proportionally — absoluteness belongs to judges only.
func _bigger_table_bigger_claim() -> void:
	var s := BoardScoring.peer_shares([1.0, 0.4])
	check(_close(float(s[0]) + float(s[1]), 1.0), "a 1.0 peer leaves nothing unclaimed")
	check(_close(float(s[0]) / float(s[1]), 2.5), "even a 1.0 peer shares proportionally")


func _zero_and_empty_tables() -> void:
	check_eq(BoardScoring.peer_shares([]).size(), 0, "empty table: no shares")
	var s := BoardScoring.peer_shares([0.0, 0.0])
	check(_close(float(s[0]), 0.0) and _close(float(s[1]), 0.0), "zero hungers claim nothing")


# The contract forbids weights outside [0,1]; the math clamps rather than amplifies.
func _out_of_range_weights_clamp() -> void:
	var s := BoardScoring.peer_shares([2.0])
	check(_close(float(s[0]), 1.0), "an over-1 weight clamps to 1, never 'overyes'")
	s = BoardScoring.peer_shares([-0.5, 0.4])
	check(_close(float(s[0]), 0.0), "a negative weight clamps to silence")
	check(_close(float(s[1]), 0.4), "a clamped-out seat leaves the table undisturbed")


# Judges: objections multiply what survives; a categorical objection zeroes it.
func _judge_factor_anchors() -> void:
	check(_close(BoardScoring.judge_factor([]), 1.0), "no judges: everything survives")
	check(_close(BoardScoring.judge_factor([0.0]), 1.0), "a content judge takes nothing")
	check(_close(BoardScoring.judge_factor([0.5]), 0.5), "objection 0.5 halves the candidate")
	check(_close(BoardScoring.judge_factor([1.0]), 0.0), "full objection IS the veto")
	check(_close(BoardScoring.judge_factor([0.5, 0.5]), 0.25), "two judges compound")
	check(_close(BoardScoring.judge_factor([0.99]), 0.01),
			"0.99 is not a decision — a crack survives")
