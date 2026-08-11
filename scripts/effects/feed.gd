class_name Feed
extends RefCounted

# The DUMB PLATE (TARGETING_DESIGN.md §12.6, signed ATTACK_SYSTEM_DESIGN.html): the four
# facts an action holds at delivery time, assembled by the ActionExecutor — the only party
# that ever holds them all at once — and handed down to payloads and mutators. Facts only:
# no derived state, no helper logic, no caching. The deleted effect_context.gd grew into a
# smart object and died for it; this class stays a plate or it gets deleted too.
#
# The allegiance anchor is its OWN fact (never derived from the holder): run-scope
# containers (relics/upgrades) deliver with no holder unit, anchored to the player's side
# per the two-anchor model.

var world: CombatWorld = null        # the world this delivery runs in (live or simulated)
var holder: CardInstance = null      # the unit holding the effect (null for run-scope)
var owner: int = -1                  # the allegiance anchor side (0 player / 1 enemy)
var event: GameEvent = null          # the occasion (null for an activated invocation)
var recipient: GameEntity = null     # the entity this delivery lands on (null = targetless)


static func make(p_world: CombatWorld, p_holder: CardInstance, p_owner: int,
		p_event: GameEvent, p_recipient: GameEntity) -> Feed:
	var f := Feed.new()
	f.world = p_world
	f.holder = p_holder
	f.owner = p_owner
	f.event = p_event
	f.recipient = p_recipient
	return f
