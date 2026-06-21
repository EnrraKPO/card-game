class_name Lab
extends RefCounted

# Crafting machines for the Laboratory hub screen (lab_screen.gd), operating on a profile's
# MaterialBag — the meta economy. The Refinery condenses raw elemental essence into matching
# elemental stones at a fixed ratio. The King forge consumes 1 King Piece + 2 elemental stones
# to unlock the King whose composition is those two stones' elements (+ its deck).

const REFINE_RATIO := 10   # essence spent per stone produced
const KING_PIECE := "king_piece"


# Whether the profile has enough essence of `element` to refine one stone.
static func can_refine(profile: ProfileData, element: String) -> bool:
	return profile.materials.count(element) >= REFINE_RATIO


# Spends REFINE_RATIO essence of `element` for one matching stone. Returns whether it ran
# (false if unaffordable). Persistence is the caller's job (GameData.save_profile).
static func refine(profile: ProfileData, element: String) -> bool:
	if not profile.materials.spend(element, REFINE_RATIO):
		return false
	profile.materials.add(Materials.stone_id(element), 1)
	return true


# ── King forge ─────────────────────────────────────────────────────────────────────────

# The King forged from two elements: canonical id = sorted elements + the "king" piece.
static func king_id_for(el_a: String, el_b: String) -> String:
	return CardData.composition_key([el_a, el_b], ["king"])


# A real, deck-backed elemental King — not a generic card derivation (see DeckData.has).
static func is_forgeable_king(king_id: String) -> bool:
	var card := CardData.get_card(king_id)
	return card != null and card.is_king and DeckData.has(king_id)


# The stones the forge consumes for these two elements (element-stone id -> count); 2 of one
# stone when both elements match (a pure King).
static func stone_cost(el_a: String, el_b: String) -> Dictionary:
	var cost: Dictionary = {}
	for el: String in [el_a, el_b]:
		var sid := Materials.stone_id(el)
		cost[sid] = int(cost.get(sid, 0)) + 1
	return cost


# Whether the forge can run for (el_a, el_b): the pair maps to a real King the player does
# NOT already own (duplicates are blocked — scope-limited for now), and they hold 1 King
# Piece plus the required stones.
static func can_forge(profile: ProfileData, el_a: String, el_b: String) -> bool:
	var king_id := king_id_for(el_a, el_b)
	if not is_forgeable_king(king_id):
		return false
	if king_id in profile.unlocked_kings:
		return false
	if profile.materials.count(KING_PIECE) < 1:
		return false
	for sid: String in stone_cost(el_a, el_b):
		if profile.materials.count(sid) < int(stone_cost(el_a, el_b)[sid]):
			return false
	return true


# Forges the King for (el_a, el_b): spends 1 King Piece + the 2 stones and unlocks the King
# (which also seeds its deck). Returns the forged king id, or "" if it couldn't run.
# Persistence is the caller's job (GameData.save_profile).
static func forge(profile: ProfileData, el_a: String, el_b: String) -> String:
	if not can_forge(profile, el_a, el_b):
		return ""
	profile.materials.spend(KING_PIECE, 1)
	var cost := stone_cost(el_a, el_b)
	for sid: String in cost:
		profile.materials.spend(sid, int(cost[sid]))
	var king_id := king_id_for(el_a, el_b)
	profile.unlock_king(king_id)
	return king_id


# ── Card Forge (minting collection cards) ────────────────────────────────────────────────

# The material cost to mint a card: its composition decomposed into ingredients — one stone
# per element, one piece-token per chess piece (duplicates counted). This is the same shape
# the King Forge spends; the King's `king_piece` is just its chess-piece ingredient.
static func card_cost(card_id: String) -> Dictionary:
	var card := CardData.get_card(card_id)
	var cost: Dictionary = {}
	if card == null:
		return cost
	for el: String in card.elements:
		var sid := Materials.stone_id(el)
		cost[sid] = int(cost.get(sid, 0)) + 1
	for piece: String in card.chess_pieces:
		var pid := Materials.piece_id(piece)
		cost[pid] = int(cost.get(pid, 0)) + 1
	return cost


# A card the Card Forge can mint into the collection: a real card with at least one
# ingredient that is NOT a King (Kings are forged via forge(), not collected).
static func is_mintable(card_id: String) -> bool:
	var card := CardData.get_card(card_id)
	return card != null and not card.is_king and not card_cost(card_id).is_empty()


static func can_mint(profile: ProfileData, card_id: String) -> bool:
	if not is_mintable(card_id):
		return false
	var cost := card_cost(card_id)
	for id: String in cost:
		if profile.materials.count(id) < int(cost[id]):
			return false
	return true


# Mints one copy of `card_id` into the collection, spending its ingredient materials.
# Returns whether it ran. Persistence is the caller's job (GameData.save_profile).
static func mint(profile: ProfileData, card_id: String) -> bool:
	if not can_mint(profile, card_id):
		return false
	for id: String in card_cost(card_id):
		profile.materials.spend(id, int(card_cost(card_id)[id]))
	profile.collection.add(card_id, 1)
	return true
