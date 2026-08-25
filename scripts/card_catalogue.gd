class_name CardCatalogue
extends RefCounted

# The catalogue → envelope conversion (AMENDMENTS A7: "the existing catalogue converts
# at the parity migration"). CardData stays the authority on the old authored schema —
# its load already applies the derivations (spell kind, derived stats for stat-less
# composition cards, the `enabled` kill-switch) — and this maps each loaded card into
# the A7 envelope the ContentLibrary registers.
#
# What does not convert: the old files' `effects` and `abilities` entries. They are
# reference strings ("nearest_attack", "heal") into definitions exterminated at the A11
# swap — there is nothing behind them to convert. Effect-bearing content returns as
# authored waves through the CONTENT_DICTIONARY gate; until then the catalogue's units
# fight on the machinery main action alone.
#
# Stats: a unit's envelope seeds cost/attack/health/speed from the authored numbers,
# max_health = the authored health, and shield only where authored — a spell bears only
# cost (the Unit stat list is not a spell's). Tool-side keys (art, tribe, enemy_only,
# description, bounties) stay on CardData; the envelope carries what the core declares.


static func envelope(card: CardData) -> Dictionary:
	var spell := card.card_type == CardData.CardType.SPELL
	var stats: Dictionary = {"cost": card.cost}
	if not spell:
		stats["attack"] = card.attack
		stats["health"] = card.health
		stats["max_health"] = card.health
		stats["speed"] = card.speed
		if card.shield > 0:
			stats["shield"] = card.shield
	var out: Dictionary = {
		"id": card.id,
		"name": card.display_name,
		"kind": "spell" if spell else "unit",
		"stats": stats,
	}
	if not card.elements.is_empty():
		out["elements"] = card.elements.duplicate()
	if not spell and card.is_building():
		out["building"] = true
	if card.is_king:
		out["king"] = true
	return out


# Every loaded card, converted — the fight content's `cards` list.
static func envelopes() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for card: Variant in CardData.all():
		out.append(envelope(card as CardData))
	return out
