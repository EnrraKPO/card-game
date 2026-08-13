class_name Mutator
extends RefCounted

# THE evaluable-value contract (TARGETING_DESIGN.md §12.6, signed ATTACK_SYSTEM_DESIGN.html):
# every payload value slot — numeric amounts AND identities — is filled by a mutator.
# Per-need species under this one contract, the targeting doctrine verbatim: generality
# lives here, specificity in the species, and NO general expression language ever exists.
#
# Lifecycle: PARAMETERIZED AT PARSE (the payload's parser constructs the species with its
# authored params — one stateless, immutable instance shared by every fielded copy, the
# TriggerResolver precedent), FED AT DELIVERY (the ActionExecutor assembles the Feed and
# the payload calls derive), DERIVES ON THE SPOT (the species' own logic; nobody outside
# knows how). A fixed number is the trivial species, not a separate code path.
#
# Species are inner classes of this file (the one-file load-order rule). The roster is
# content-driven, never speculative: day one is exactly the two the auto-attack needs.
#
# Authoring: a bare number is FixedNumber shorthand; otherwise { "kind": "<species>", ... }.


# Derive this mutator's value from the delivery context. Variant because species may
# yield numbers OR identities (a status id, a card id); each payload slot documents the
# kind it expects and fails loud on a mismatch.
func derive(_feed: Feed) -> Variant:
	return null


# Native (dictionary/number) authored form.
func to_dict() -> Variant:
	return null


# The one authored form. Bare numbers are FixedNumber shorthand; unknown kinds are refused
# loudly — no permissive default.
static func parse(value: Variant) -> Mutator:
	if value is int or value is float:
		return FixedNumber.of(int(value))
	if not (value is Dictionary):
		push_error("Mutator: '%s' is not a mutator form (number or {kind: ...}) — refusing" % str(value))
		return null
	var d := value as Dictionary
	match str(d.get("kind", "")):
		"fixed_number":
			return FixedNumber.of(int(d.get("value", 0)))
		"holder_stat":
			return HolderStat.of(str(d.get("stat", "")))
	push_error("Mutator: unknown mutator kind '%s' — refusing (no permissive default)" % str(d.get("kind", "")))
	return null


# ── Species ──────────────────────────────────────────────────────────────────────────

class FixedNumber extends Mutator:
	# A fixed authored number — the trivial species. It is a NUMBER and only a number:
	# the species says so in its name, and nothing here ever carries a word, a flag or
	# an id (Enrra's naming ruling, 2026-08-13).
	var value: int = 0

	static func of(p_value: int) -> FixedNumber:
		var m := FixedNumber.new()
		m.value = p_value
		return m

	func derive(_feed: Feed) -> Variant:
		return value

	func to_dict() -> Variant:
		return value


class HolderStat extends Mutator:
	# A named stat read off the HOLDER at delivery time — "my attack stat", read fresh so
	# buffs, statuses and run bonuses count. Unauthorable on a holderless (run-scope)
	# container: derive fails loud rather than guessing.
	var stat: String = ""

	static func of(p_stat: String) -> HolderStat:
		var m := HolderStat.new()
		m.stat = p_stat
		return m

	func derive(feed: Feed) -> Variant:
		if feed == null or feed.holder == null:
			push_error("Mutator.HolderStat('%s'): no holder to read — a holder-stat value cannot ride a run-scope container" % stat)
			return 0
		return feed.holder.get_attribute(stat)

	func to_dict() -> Variant:
		return {"kind": "holder_stat", "stat": stat}
