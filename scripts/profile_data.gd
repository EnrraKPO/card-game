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
var experience: int = 0 : set = _set_experience
var upgrade_points: int = 0 : set = _set_upgrade_points
# Purchased Upgrades-tree nodes (UpgradeNode ids). Each owned node contributes its run-wide
# Effects to the run's ModifierSet — the profile-level source feeding the upgrade system.
var owned_upgrades: Array = []   # Array[String]
# Profile-level crafting resources (the meta economy, distinct from run cards) — see
# MaterialBag. Essences keyed by element id ("fire".."light"); King Pieces by "king_piece".
var materials: MaterialBag = MaterialBag.new()
# Crafted cards the player OWNS (card id -> count) — minted from materials in the Lab and
# drawn from when building decks. Innate King cards are NOT here (see CardCollection).
var collection: CardCollection = CardCollection.new()
# One-time milestone ids the player has met (see Achievements). Not user-facing yet — the
# layer just records unlocks here so each achievement fires (and pays out) exactly once.
var unlocked_achievements: Array = []   # Array[String]
# Achievement ids whose celebration modal is queued but not yet shown. Unlocks happen mid-run
# (in combat); the celebration is deferred to the next hub visit, which drains this. Persisted
# so the celebration still fires if the run that earned it is saved & quit before returning home.
var pending_celebrations: Array = []    # Array[String]
# FTUE flag: has the player ever opened the Lab? Drives the hub's "New" badge on the Lab button
# (shown once they've earned their first King Piece), which clears the first time they visit.
var lab_visited: bool = false
# Quick merge: the crafting table commits a valid merge on the spot, with no confirmation framing.
# A convenience the player opts into, so it defaults OFF and persists once chosen. `quick_merge_ack`
# records that they've read the one-time warning (merges are destructive and can't be undone) — the
# warning is a first-enable ritual, not a nag on every toggle.
var quick_merge: bool = false
var quick_merge_ack: bool = false
# Quick preview: with a source picked, every valid partner on the crafting table shows what it
# WOULD become instead of what it is. Purely a way of looking at the table — nothing it does can
# lose a card — so unlike quick_merge it needs no acknowledgement, just a switch.
var quick_preview: bool = false


static func create_default() -> ProfileData:
	var p := ProfileData.new()
	for king_id: String in STARTING_KINGS:
		p.unlocked_kings.append(king_id)
		var deck := p._seed_deck(king_id)
		# The starter deck earns the elemental pick ritual at run start (see king_reward_picks).
		deck.is_base_template = true
		if p.selected_deck_id.is_empty():
			p.selected_deck_id = deck.id
	# Starting resources are data-driven (data/economy.json via EconomyConfig, authored in
	# the Tool's 🎛 Tuning ▸ 💰 Economy): the shipping `initial` bag, or the `debug` bag
	# while its dev override is enabled (the old TEMP Lab/Forge seed lives on as the
	# debug-bag default).
	p.materials.add_many(EconomyConfig.starting_materials())
	p.upgrade_points = EconomyConfig.starting_upgrade_points()
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
	p.unlocked_achievements = data.get("unlocked_achievements", [])
	p.pending_celebrations = data.get("pending_celebrations", [])
	p.lab_visited = bool(data.get("lab_visited", false))
	p.quick_merge = bool(data.get("quick_merge", false))
	p.quick_merge_ack = bool(data.get("quick_merge_ack", false))
	p.quick_preview = bool(data.get("quick_preview", false))
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
	# Backfill the base-template marker for saves made before it existed: the profile's first
	# base-King deck is its starter. (New profiles set it in create_default.)
	if not p.decks.any(func(od: OwnedDeck) -> bool: return od.is_base_template):
		for od: OwnedDeck in p.decks:
			if od.king_id == STARTING_KING:
				od.is_base_template = true
				break
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
		"unlocked_achievements": unlocked_achievements,
		"pending_celebrations":  pending_celebrations,
		"lab_visited":           lab_visited,
		"quick_merge":           quick_merge,
		"quick_merge_ack":       quick_merge_ack,
		"quick_preview":         quick_preview,
	}


# ── Experience / upgrade points ─────────────────────────────────────────────────────

# Property setters emit GameSignals.exp_changed (see [[header-system]]) so the header's EXP field
# updates itself — no payload (the widget reads both experience and upgrade_points together), so
# the subscriber just re-reads current state, same coarse-refresh treatment as relics.
func _set_experience(v: int) -> void:
	experience = v
	GameSignals.exp_changed.emit()


func _set_upgrade_points(v: int) -> void:
	upgrade_points = v
	GameSignals.exp_changed.emit()


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


# ── Achievements ────────────────────────────────────────────────────────────────────

func has_achievement(id: String) -> bool:
	return id in unlocked_achievements


# Records a met achievement. Returns false (no-op) if already held. Caller persists
# (Achievements does, via GameData.grant_materials / save_profile).
func unlock_achievement(id: String) -> bool:
	if id in unlocked_achievements:
		return false
	unlocked_achievements.append(id)
	return true


# Queues an achievement's celebration for the next hub visit (idempotent). Caller persists.
func queue_celebration(id: String) -> void:
	if id not in pending_celebrations:
		pending_celebrations.append(id)


# Removes and returns the next queued celebration id, or "" if none. Caller persists.
func pop_celebration() -> String:
	return pending_celebrations.pop_front() if not pending_celebrations.is_empty() else ""


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
