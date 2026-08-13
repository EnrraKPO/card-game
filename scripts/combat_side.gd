class_name CombatSide
extends RefCounted

# One side of a combat: the per-player resource state — mana, the hand, the draw pile —
# that used to live as loose asymmetric fields on combat.gd (_mana/_enemy_mana/_enemy_hand/…).
# Both sides are the same object now; "the player" and "the CPU" differ only in who watches.
#
# A side was one of the target kinds the nuked single writer dispatched on: "draw 2" and
# "gain 1 mana" were writes aimed at a side. That writer and its mutation form were nuked
# 2026-08-13 as cursed, and with them went the resolution FORMS (draw floors at 0 and stops
# at the pile; mana floors at 0, UNCAPPED above max). What survives here is the state plus
# the commit PRIMITIVES those forms called — nothing calls them until the sanctioned write
# form is pitched.
#
# Presentation subscribes to the signals: the player's Hand spawns/removes CardUI on
# cards_drawn/cards_discarded, the mana gauge refreshes on mana_changed. The enemy side has
# no subscribers — same object, nobody watching.

signal cards_drawn(insts: Array)
signal cards_discarded(insts: Array)
signal mana_changed

var owner: int = 0          # 0 = player, 1 = enemy — the same axis as CardInstance.owner
var mana: int = 0
var max_mana: int = 0
var hand: Array = []        # Array[CardInstance]
var draw_pile: Array = []   # Array[CardInstance]


static func make(p_owner: int) -> CombatSide:
	var s := CombatSide.new()
	s.owner = p_owner
	return s


# Deep-copy for world snapshots (see CombatWorld.copy): resource numbers duplicated, every
# card in hand/pile copied through the snapshot's shared identity remap (hand spells are
# cast in simulations, so zones copy at full fidelity). A copy starts with no signal
# subscribers — same object shape as the enemy side live: state with nobody watching.
func copy(remap: Dictionary) -> CombatSide:
	var s := CombatSide.make(owner)
	s.mana = mana
	s.max_mana = max_mana
	for inst: CardInstance in hand:
		s.hand.append(CardInstance.copied(inst, remap))
	for inst: CardInstance in draw_pile:
		s.draw_pile.append(CardInstance.copied(inst, remap))
	return s


# ── Commit primitives (uncalled since the write form was nuked — see the class comment) ──

# Moves up to `n` cards off the top of the draw pile into the hand. The caller floors `n`;
# running out of pile is THIS zone's knowledge — the return reports what moved.
func pull_to_hand(n: int) -> Array:
	var count := mini(n, draw_pile.size())
	if count <= 0:
		return []
	var drawn := draw_pile.slice(0, count)
	draw_pile = draw_pile.slice(count)
	hand.append_array(drawn)
	cards_drawn.emit(drawn)
	return drawn


# Removes up to `n` random cards from the hand. Discarded cards cease to exist — there is
# no discard-pile/graveyard zone (deliberate; played cards vanish the same way).
func discard_random(n: int) -> Array:
	var count := mini(n, hand.size())
	if count <= 0:
		return []
	var gone: Array = []
	for _i in count:
		gone.append(hand.pop_at(CombatRng.roll_int(0, hand.size() - 1, &"deck")))
	cards_discarded.emit(gone)
	return gone


func set_mana(v: int) -> void:
	if mana == v:
		return
	mana = v
	mana_changed.emit()


func set_max_mana(v: int) -> void:
	if max_mana == v:
		return
	max_mana = v
	mana_changed.emit()


# Hand membership bookkeeping for a card leaving by being PLAYED — zone movement via play,
# never a stat write (the orchestrator calls it where it already handles the play). No
# signal: the play flow removes its own UI.
func remove_from_hand(inst: CardInstance) -> void:
	hand.erase(inst)
