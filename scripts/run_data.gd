class_name RunData
extends RefCounted

# The King is the player's run-long avatar and the only loss condition: when its
# health hits 0 in a fight, the run is over. The King unit itself is rebuilt fresh
# each combat by the fight setup, so the only thing we persist between fights
# is how wounded it is — accumulated, unhealed damage. Current health is never
# stored; it's just (max health - king_damage), computed when a fight starts.
var king_damage: int = 0 : set = _set_king_damage
var king_id: String = ProfileData.STARTING_KING   # which King card this run is played with (from the profile)
var gold: int : set = _set_gold
# Magic Mineral: the run-scoped forge resource — consumed by card merges (ForgeCosts), earned
# from combat wins (GameData.apply_encounter_rewards) and grantable/purchasable through the
# "currency" ItemKind. Lives on the RUN (gone when it ends), unlike the profile material bag.
var magic_mineral: int : set = _set_magic_mineral
var deck: Array   # Array[DeckCard] — each entry carries its own permanent mods
var act: int : set = _set_act
var charms: Array = []   # owned, unapplied charm ids (inventory); applied in the forge
# The freebies every run opens with — see create_new for why they exist and why these.
const STARTING_CHARM := "sturdy"
const STARTING_RELIC := "bomb"
# Where the player last acknowledged the map Forge button's "!" badge, as "<act>:<node id>".
# The badge is an ATTENTION cue, not a status light: once seen (hovered or clicked) it should
# stay quiet until something changes. Storing the map POSITION rather than a bool makes
# "reappears after the next completed map event" fall out for free — moving onto a new node is
# what completing an event does — with no reset hook anywhere. Act-qualified because node ids
# repeat across a run's stages.
var forge_alert_ack: String = ""
var relics: Array = []   # owned relic ids (run-unique); each folds its Effects into the run ModifierSet


# Property setters emit on GameSignals (see [[header-system]]) so any live UI — the header's HP/
# Gold/Act fields — updates itself without the mutating code needing to know it exists. Plain
# assignment/compound-assignment (run.gold -= cost) already routes through these; no call-site
# changes needed for these three scalar fields.
func _set_king_damage(v: int) -> void:
	king_damage = v
	GameSignals.hp_changed.emit(king_health(), king_max_health())


func _set_gold(v: int) -> void:
	gold = v
	GameSignals.gold_changed.emit(v)


func _set_magic_mineral(v: int) -> void:
	magic_mineral = v
	GameSignals.mineral_changed.emit(v)


func _set_act(v: int) -> void:
	act = v
	GameSignals.act_changed.emit(v)


# Seeds a fresh run from the profile's selected owned deck (which carries its King).
# The run takes a deep-copied SNAPSHOT, so run-time edits never write back to the saved
# deck. Falls back to the default King + template deck when no profile/deck is supplied
# (e.g. tooling/tests).
static func create_new(profile: ProfileData = null) -> RunData:
	var run := RunData.new()
	run.king_damage = 0
	# Starting purse resolved through the registry (base + any gold.initial modifier). GameData
	# rebuilds the modifier set from this profile before create_new (see start_new_run). While
	# the debug economy override is enabled with a gold amount set, that pins the purse instead.
	var debug_gold := EconomyConfig.gold_override()
	run.gold = debug_gold if debug_gold >= 0 else GameData.value("gold.initial")
	var debug_mineral := EconomyConfig.mineral_override()
	run.magic_mineral = debug_mineral if debug_mineral >= 0 \
			else GameData.value("magic_mineral.initial")
	var deck := profile.get_selected_deck() if profile != null else null
	if deck != null:
		run.king_id = deck.king_id
		run.deck    = deck.snapshot_cards()
	else:
		run.king_id = ProfileData.STARTING_KING
		run.deck    = _deck_from_variants(DeckData.get_deck(DeckData.FALLBACK_ID))
	run.act = 1
	# Every run opens with one charm in the bag, gratis. It is not a balance lever — it is the
	# forge's tutorial: the Attach flow is otherwise invisible until the game happens to award a
	# charm, so a player can reach the first Forge with nothing to do there. `sturdy` (+3 health)
	# is the authored health charm and the safest possible thing to hand out blind — it improves
	# any unit, on any deck, with no rule to read.
	if CharmData.get_charm(STARTING_CHARM) != null:
		run.charms.append(STARTING_CHARM)
	# And one consumable relic, for the same tutorial reason: the bomb is the hold-to-use
	# chip's introduction (a consumable in the combat tray is otherwise invisible until one is
	# bought), and a one-shot 5-to-all is a safety net, never a build-around. Plain append —
	# start_new_run saves after create_new, and a transient relic has nothing to fold into the
	# modifier set anyway (see RelicData.consumable).
	if RelicData.get_relic(STARTING_RELIC) != null:
		run.relics.append(STARTING_RELIC)
	return run


static func from_dict(data: Dictionary) -> RunData:
	var run := RunData.new()
	if data.has("king_damage"):
		run.king_damage = data.get("king_damage", 0)
	elif data.has("health") and data.has("max_health"):
		# Migrate legacy saves that stored absolute current/max health.
		run.king_damage = maxi(0, int(data["max_health"]) - int(data["health"]))
	run.king_id = data.get("king_id", ProfileData.STARTING_KING)
	run.gold = int(data.get("gold", GameAttributes.default_value("gold.initial")))
	run.magic_mineral = int(data.get("magic_mineral",
			GameAttributes.default_value("magic_mineral.initial")))
	run.deck = _deck_from_variants(data.get("deck", []))
	run.act  = data.get("act",  1)
	run.charms = data.get("charms", [])
	run.relics = data.get("relics", [])
	run.forge_alert_ack = str(data.get("forge_alert_ack", ""))
	return run


func to_dict() -> Dictionary:
	var deck_data: Array = []
	for dc: DeckCard in deck:
		deck_data.append(dc.to_dict())
	return {
		"king_damage": king_damage,
		"king_id":     king_id,
		"gold":        gold,
		"magic_mineral": magic_mineral,
		"deck":        deck_data,
		"act":         act,
		"charms":      charms,
		"relics":      relics,
		"forge_alert_ack": forge_alert_ack,
	}


# Normalises a raw deck list (DeckData ids, or saved dicts, or legacy bare strings)
# into Array[DeckCard].
static func _deck_from_variants(raw: Array) -> Array:
	var out: Array = []
	for v in raw:
		out.append(DeckCard.from_variant(v))
	return out


# The King's maximum health: its card stat plus the resolved "king.max_health" bonus (default
# 0; e.g. the Warfare capstone). The bonus resolves through the same registry path as every
# other number. GameData owns the active modifier set for the live run.
func king_max_health() -> int:
	var king := CardData.get_card(king_id)
	var base := king.health if king != null else 1
	return base + GameData.value("king.max_health")


# The King's health entering a fight: full max, minus the damage carried over.
func king_health() -> int:
	return maxi(0, king_max_health() - king_damage)


# Grants an owned relic (bought, rewarded, or debug-granted). Rebuilds the run's modifier set so
# the relic's effects take hold immediately, persists, and signals — callers no longer bundle
# rebuild_modifiers()/save_run() themselves (see item_kind_relic.gd, debug_shop.gd).
func add_relic(id: String) -> void:
	relics.append(id)
	GameData.rebuild_modifiers()
	GameData.save_run()
	GameSignals.relics_changed.emit()


# Discards an owned relic (the player may drop a relic at any time to free a slot — no refund).
# Rebuilds the run's modifier set so the relic's effects stop applying, then persists.
func discard_relic(id: String) -> void:
	var idx := relics.find(id)
	if idx == -1:
		return
	relics.remove_at(idx)
	GameData.rebuild_modifiers()
	GameData.save_run()
	GameSignals.relics_changed.emit()
