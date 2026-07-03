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


# A fresh combat-side unit of the given card, owned by the player (owner 0), as most tests
# need. Base stats = effective stats in the clean environment.
func unit(card_id: String) -> CardInstance:
	var inst := CardInstance.from_data(CardData.get_card(card_id))
	inst.owner = 0
	return inst


# A minimal one-unit board context for effect dispatch.
func ctx_for(inst: CardInstance) -> EffectContext:
	return EffectContext.make(inst, [[inst]], [[]])
