class_name ProfileData
extends RefCounted

# Profile-scoped meta-progression that outlives any single run — a sibling to
# RunData/MapState, but persisted ONCE per profile (a "profile" save section), not
# per run slot. A new run draws its deck from the selected OwnedDeck here, and permanent
# unlocks accumulate here across runs. Surfaced by the "game world" hub
# (game_world.gd). This is the load-bearing layer for the roguelike meta loop;
# content panels (king select, deck editing, unlock shop) build on top of it.
#
# Decks are first-class OWNED entities (see OwnedDeck), not derived from the King:
# unlocking a King seeds a deck from its template, but the player may then hold several
# decks per King and edit each. "Picking a deck" picks its King (king_id is deck metadata).

const STARTING_KING := "king"

# Kings a fresh profile starts with (one deck each). Elemental kings are now earned by
# forging them in the Lab (Lab.forge: 1 King Piece + 2 elemental stones), so a new profile
# begins with only the basic King.
const STARTING_KINGS := ["king"]

# Experience curve: how much experience converts into one upgrade point. The tuning knob
# for the whole meta-progression pace (see gain_experience / the Upgrades screen).
const EXP_PER_UPGRADE_POINT := 10

var unlocked_kings: Array = []   # Array[String]: king card ids the player may run with
var decks: Array = []            # Array[OwnedDeck]: the player's owned, editable decks
var selected_deck_id: String = ""  # which OwnedDeck a fresh run uses
var next_deck_uid: int = 0       # monotonic counter for collision-free OwnedDeck ids
# Experience accrues from combat (and event rewards); each EXP_PER_UPGRADE_POINT of it
# becomes one upgrade point. `experience` is only the progress toward the NEXT point (the
# bar); `upgrade_points` is the spendable balance for the Upgrades skill trees.
var experience: int = 0
var upgrade_points: int = 0
# Purchased Upgrades-tree nodes (UpgradeNode ids). Each owned node contributes its run-wide
# Effects to the run's ModifierSet — the profile-level source feeding the upgrade system.
var owned_upgrades: Array = []   # Array[String]
# Profile-level crafting resources (the meta economy, distinct from run cards) — see
# MaterialBag. Essences keyed by element id ("fire".."light"); King Pieces by "king_piece".
var materials: MaterialBag = MaterialBag.new()
# Crafted cards the player OWNS (card id -> count) — minted from materials in the Lab and
# drawn from when building decks. Innate King cards are NOT here (see CardCollection).
var collection: CardCollection = CardCollection.new()


static func create_default() -> ProfileData:
	var p := ProfileData.new()
	for king_id: String in STARTING_KINGS:
		p.unlocked_kings.append(king_id)
		var deck := p._seed_deck(king_id)
		if p.selected_deck_id.is_empty():
			p.selected_deck_id = deck.id
	# TEMP dev seed for testing the Lab/Forge: enough King Pieces to forge every King (21),
	# a stock of every elemental stone, and chess-piece tokens to mint cards with. Remove
	# once the materials economy is balanced.
	p.materials.add(Materials.piece_id("king"), 21)
	for piece: String in Materials.PIECES:
		if piece != "king":
			p.materials.add(Materials.piece_id(piece), 10)
	for element: String in Materials.ELEMENTS:
		p.materials.add(Materials.stone_id(element), 10)
	# TEMP dev seed: spendable upgrade points so the Upgrades trees are testable before the
	# experience grind fills them. Remove once experience pacing is tuned.
	p.upgrade_points = 12
	return p


static func from_dict(data: Dictionary) -> ProfileData:
	if data.is_empty():
		return create_default()
	var p := ProfileData.new()
	p.unlocked_kings = data.get("unlocked_kings", [STARTING_KING])
	# Rebranded from "renown" — migrate the legacy key into experience.
	p.experience = int(data.get("experience", data.get("renown", 0)))
	p.upgrade_points = int(data.get("upgrade_points", 0))
	p.owned_upgrades = data.get("owned_upgrades", [])
	p.next_deck_uid = int(data.get("next_deck_uid", 0))
	p.materials = MaterialBag.from_dict(data.get("materials", {}))
	p.collection = CardCollection.from_dict(data.get("collection", {}))
	if data.has("decks"):
		for d in data.get("decks", []):
			p.decks.append(OwnedDeck.from_dict(d))
		p.selected_deck_id = data.get("selected_deck_id", "")
	else:
		# Migrate a pre-owned-deck save: one deck seeded from the legacy selected_king,
		# preserving a legacy `starting_deck` (card-id list) if one was stored.
		var king: String = data.get("selected_king", STARTING_KING)
		var deck := p._seed_deck(king)
		var legacy_cards: Array = data.get("starting_deck", [])
		if not legacy_cards.is_empty():
			deck.cards.clear()
			for v in legacy_cards:
				deck.cards.append(DeckCard.from_variant(v))
		p.selected_deck_id = deck.id
	# Guard against a dangling/empty selection.
	if p.get_selected_deck() == null:
		var fallback := p._seed_deck(STARTING_KING)
		p.selected_deck_id = fallback.id
	return p


func to_dict() -> Dictionary:
	var deck_data: Array = []
	for od: OwnedDeck in decks:
		deck_data.append(od.to_dict())
	return {
		"unlocked_kings":   unlocked_kings,
		"decks":            deck_data,
		"selected_deck_id": selected_deck_id,
		"next_deck_uid":    next_deck_uid,
		"experience":       experience,
		"upgrade_points":   upgrade_points,
		"owned_upgrades":   owned_upgrades,
		"materials":        materials.to_dict(),
		"collection":       collection.to_dict(),
	}


# ── Experience / upgrade points ─────────────────────────────────────────────────────

# Banks experience and converts each full EXP_PER_UPGRADE_POINT into one upgrade point,
# carrying the remainder toward the next. Returns the number of points newly gained (for
# UI feedback). Caller is responsible for persisting (GameData.grant_experience does).
func gain_experience(amount: int) -> int:
	if amount <= 0:
		return 0
	experience += amount
	var gained := 0
	while experience >= EXP_PER_UPGRADE_POINT:
		experience -= EXP_PER_UPGRADE_POINT
		upgrade_points += 1
		gained += 1
	return gained


# ── Upgrade nodes ───────────────────────────────────────────────────────────────────

func owns_upgrade(node_id: String) -> bool:
	return node_id in owned_upgrades


# A node is buyable when it isn't already owned, every prerequisite is owned, and the player
# can afford it. Used to gate the Upgrades screen's purchase button.
func can_purchase(node: UpgradeNode) -> bool:
	if node == null or owns_upgrade(node.id):
		return false
	if upgrade_points < node.cost:
		return false
	for req: String in node.requires:
		if not owns_upgrade(req):
			return false
	return true


# Whether a node's prerequisites are all owned (regardless of points) — drives the
# locked/available distinction in the tree view. Owned nodes count as unlocked.
func upgrade_unlocked(node: UpgradeNode) -> bool:
	if node == null:
		return false
	for req: String in node.requires:
		if not owns_upgrade(req):
			return false
	return true


# Spends the node's cost and records ownership. Returns false (no-op) if not buyable.
# Caller persists (GameData.save_profile) and rebuilds the run modifiers.
func purchase_upgrade(node: UpgradeNode) -> bool:
	if not can_purchase(node):
		return false
	upgrade_points -= node.cost
	owned_upgrades.append(node.id)
	return true


# ── Deck / King access ────────────────────────────────────────────────────────────

# The owned deck a fresh run will use. Falls back to the first owned deck if the stored
# selection is missing; null only if the player somehow owns no decks at all.
func get_selected_deck() -> OwnedDeck:
	for od: OwnedDeck in decks:
		if od.id == selected_deck_id:
			return od
	return decks[0] if not decks.is_empty() else null


# Convenience for the many call sites that only need the King of the active deck.
func get_selected_king() -> String:
	var od := get_selected_deck()
	return od.king_id if od != null else STARTING_KING


# Unlocks a King (if new) and grants a fresh deck seeded from its template — the
# data-layer entry point for the future unlock shop.
func unlock_king(king_id: String) -> OwnedDeck:
	if king_id not in unlocked_kings:
		unlocked_kings.append(king_id)
	return _seed_deck(king_id)


# Adds another deck for an ALREADY-unlocked King (the "New Deck" flow). Returns null if
# the King isn't unlocked — the UI only ever offers unlocked kings, but guard anyway.
func add_deck_for_king(king_id: String) -> OwnedDeck:
	if king_id not in unlocked_kings:
		return null
	return _seed_deck(king_id)


# Marks an owned deck as the active one (used by a fresh run). No-op if the id is unknown.
func select_deck(deck_id: String) -> void:
	for od: OwnedDeck in decks:
		if od.id == deck_id:
			selected_deck_id = deck_id
			return


func deck_count_for_king(king_id: String) -> int:
	var n := 0
	for od: OwnedDeck in decks:
		if od.king_id == king_id:
			n += 1
	return n


# A deck may be deleted only if its King has another deck — every unlocked King keeps at
# least one (its "base"), so it stays playable. A reset can always restore the template.
func can_delete_deck(deck_id: String) -> bool:
	var od := _deck_by_id(deck_id)
	return od != null and deck_count_for_king(od.king_id) > 1


# Deletes an owned deck (if allowed), reassigning the active selection if it was deleted.
func delete_deck(deck_id: String) -> bool:
	if not can_delete_deck(deck_id):
		return false
	for i in decks.size():
		if decks[i].id == deck_id:
			decks.remove_at(i)
			break
	if selected_deck_id == deck_id:
		var fallback := get_selected_deck()   # falls back to the first remaining deck
		selected_deck_id = fallback.id if fallback != null else ""
	return true


func _deck_by_id(deck_id: String) -> OwnedDeck:
	for od: OwnedDeck in decks:
		if od.id == deck_id:
			return od
	return null


# ── internals ─────────────────────────────────────────────────────────────────────

# Creates, registers, and returns a new owned deck from a King's template.
func _seed_deck(king_id: String) -> OwnedDeck:
	var deck := OwnedDeck.from_template(king_id, _new_deck_id())
	decks.append(deck)
	return deck


func _new_deck_id() -> String:
	var deck_id := "deck_%d" % next_deck_uid
	next_deck_uid += 1
	return deck_id
