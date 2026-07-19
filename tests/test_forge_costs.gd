extends TestCase

# The forge's Magic Mineral pricing (ForgeCosts.merge_cost): component rates count the RESULT
# card's composition; exactly one flat applies per merge — element_only when both inputs are
# pure-element cards, piece_op when at least one input holds a chess piece. Knobs are injected
# (the `k` override) so the suite is immune to authored game_attributes.json values; one case
# checks the empty-dict path resolves through the registry.

# Distinct values so each term is separable in the expected totals.
const K := {"per_piece": 2, "per_element": 1, "element_only": 3, "piece_op": 5}


func suite_name() -> String:
	return "ForgeCosts"


func run() -> void:
	_element_only_merges()
	_piece_merges()
	_registry_knobs()


func _element_only_merges() -> void:
	var fire := CardData.get_card("fire")
	var water := CardData.get_card("water")
	# fire + water → result 2 elements, 0 pieces; both inputs pure-element → element_only flat.
	check_eq(ForgeCosts.merge_cost(fire, water, K), 2 * 1 + 3,
			"element+element: 2 × per_element + element_only flat")
	check_eq(ForgeCosts.merge_cost(fire, fire, K), 2 * 1 + 3,
			"same-element pair prices identically")


func _piece_merges() -> void:
	var fire := CardData.get_card("fire")
	var water := CardData.get_card("water")
	var pawn := CardData.get_card("pawn")
	var knight := CardData.get_card("knight")
	# fire + pawn → result 1 element + 1 piece; a piece is involved → piece_op flat.
	check_eq(ForgeCosts.merge_cost(fire, pawn, K), 2 + 1 + 5,
			"element+piece: per_piece + per_element + piece_op flat")
	# pawn + knight → result 2 pieces, 0 elements.
	check_eq(ForgeCosts.merge_cost(pawn, knight, K), 2 * 2 + 5,
			"piece+piece: 2 × per_piece + piece_op flat")
	# A combined card as an ingredient: (fire+pawn) + water → result 2 elements + 1 piece.
	var fire_pawn := CardData.combine(fire, pawn)
	check_eq(ForgeCosts.merge_cost(fire_pawn, water, K), 2 + 2 * 1 + 5,
			"multi-component input: the RESULT composition is what's counted")


func _registry_knobs() -> void:
	# The empty-dict path must resolve every knob through GameData.value (registry + modifiers).
	var k := ForgeCosts.knobs()
	check_eq(int(k["per_piece"]), GameData.value("forge.cost.per_piece"),
			"knobs() reads the registry")
	var fire := CardData.get_card("fire")
	var pawn := CardData.get_card("pawn")
	check_eq(ForgeCosts.merge_cost(fire, pawn),
			int(k["per_piece"]) + int(k["per_element"]) + int(k["piece_op"]),
			"default-knob merge_cost matches the registry values")
