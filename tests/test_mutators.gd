extends TestCase

# The Mutator contract (TARGETING_DESIGN.md §12.6): parameterized at parse, fed at
# delivery, derives on the spot. Pins the two day-one species (FixedNumber, HolderStat),
# the bare-number shorthand, the read-fresh rule, and the loud refusal of unknown forms.
# (Refusal checks intentionally print an ERROR line each — the loud-refusal contract
# under test; the tally below is the verdict.)


func suite_name() -> String:
	return "Mutators"


func run() -> void:
	_fixed_number_forms()
	_holder_stat_reads_fresh()
	_refusals()


func _feed_for(holder: CardInstance) -> Feed:
	return Feed.make(null, holder, 0, null, null)


func _fixed_number_forms() -> void:
	var bare := Mutator.parse(5)
	check(bare is Mutator.FixedNumber, "a bare number parses as the FixedNumber species")
	check_eq(bare.derive(_feed_for(null)), 5, "FixedNumber derives its fixed value")
	var longhand := Mutator.parse({"kind": "fixed_number", "value": 3})
	check_eq(longhand.derive(_feed_for(null)), 3, "the longhand fixed_number form derives the same way")
	check_eq(longhand.to_dict(), 3, "FixedNumber round-trips to the bare-number shorthand")
	check(Mutator.parse({"kind": "literal", "value": 3}) == null,
			"'literal' is dead vocabulary — refused loudly, never silently accepted")


func _holder_stat_reads_fresh() -> void:
	var rook := unit("rook")
	var m := Mutator.parse({"kind": "holder_stat", "stat": "attack"})
	check(m is Mutator.HolderStat, "holder_stat parses to its species")
	check_eq(m.derive(_feed_for(rook)), 4, "HolderStat reads the holder's stat (fixture rook attack)")
	rook.apply_modifier("attack", 2)
	check_eq(m.derive(_feed_for(rook)), 6, "the read is FRESH at delivery — a buff between derives counts")
	check_eq(m.to_dict(), {"kind": "holder_stat", "stat": "attack"}, "HolderStat round-trips its authored form")


func _refusals() -> void:
	check(Mutator.parse("attack") == null, "a bare string is refused (no permissive default)")
	check(Mutator.parse({"kind": "gummy_bears"}) == null, "an unknown species is refused loudly")
