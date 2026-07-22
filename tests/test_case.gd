class_name TestCase
extends RefCounted

# Base for headless regression tests — see tests/_runner.gd for how suites run and how to add
# one. Subclasses override suite_name() + run(), calling the check helpers; the runner tallies
# and exits nonzero on any failure.
#
# Tests execute in the runner's CLEAN environment (fresh in-memory profile, empty modifier
# set — see _runner.gd::_clean_env), so card base stats ARE the effective stats. Never write
# expectations against a user save slot: slot profiles carry upgrade bonuses that fold into
# get_attribute at read time and skew every number.

var passed := 0
var failed := 0


func suite_name() -> String:
	return "unnamed"


func run() -> void:
	pass


func check(cond: bool, label: String) -> void:
	if cond:
		passed += 1
	else:
		failed += 1
		print("    FAIL: ", label)


func check_eq(got: Variant, want: Variant, label: String) -> void:
	if got == want:
		passed += 1
	else:
		failed += 1
		print("    FAIL: %s — want %s, got %s" % [label, str(want), str(got)])


# Frozen, test-owned card definitions for the chess-piece fixtures the contract suites build
# with unit(). The resolution/status/interception suites assert exact stat arithmetic against
# these numbers, so they must NEVER track live balance data — a content pass retuning the real
# rook must not break the arbitration-layer regression suite (it did once: 26 failures when
# the live rook went 6 HP/3 shield -> 7 HP/2 shield). Identity fields (chess_pieces, abilities,
# ranged) mirror the real cards so composition/eligibility tests keep meaning; only the ids
# listed here are frozen — any other id passed to unit() still resolves live.
const FIXTURE_DEFS: Dictionary = {
	"pawn": {"id": "pawn", "display_name": "Pawn", "cost": 1, "attack": 1, "health": 3,
			"speed": 1, "chess_pieces": ["pawn"]},
	"bishop": {"id": "bishop", "display_name": "Bishop", "cost": 2, "attack": 1, "health": 4,
			"speed": 1, "ranged": true, "chess_pieces": ["bishop"], "abilities": ["heal"]},
	"knight": {"id": "knight", "display_name": "Knight", "cost": 2, "attack": 2, "health": 3,
			"speed": 2, "chess_pieces": ["knight"]},
	"rook": {"id": "rook", "display_name": "Rook", "cost": 3, "attack": 4, "health": 6,
			"speed": 1, "shield": 3, "chess_pieces": ["rook"], "abilities": ["castling"]},
	"queen": {"id": "queen", "display_name": "Queen", "cost": 5, "attack": 5, "health": 5,
			"speed": 3, "ranged": true, "chess_pieces": ["queen"]},
	"king": {"id": "king", "display_name": "King", "cost": 0, "attack": 1, "health": 20,
			"speed": 3, "shield": 5, "is_king": true, "chess_pieces": ["king"]},
}

static var _fixture_cards: Dictionary = {}


# A fresh combat-side unit of the given card, owned by the player (owner 0), as most tests
# need. Fixture ids build from FIXTURE_DEFS; anything else reads the live card. Base stats =
# effective stats in the clean environment.
func unit(card_id: String) -> CardInstance:
	var data: CardData
	if FIXTURE_DEFS.has(card_id):
		if not _fixture_cards.has(card_id):
			_fixture_cards[card_id] = CardData.build_from_dict(FIXTURE_DEFS[card_id])
		data = _fixture_cards[card_id]
	else:
		data = CardData.get_card(card_id)
	var inst := CardInstance.from_data(data)
	inst.owner = 0
	return inst


# A minimal one-unit board context for effect dispatch.
func ctx_for(inst: CardInstance) -> EffectContext:
	return EffectContext.make(inst, [[inst]], [[]])
