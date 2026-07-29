class_name EncounterData
extends RefCounted

enum Type    { COMBAT, ELITE, BOSS }
enum Outcome { PENDING, WIN, LOSE }

var type: Type = Type.COMBAT
var enemy_deck: Array[String] = []   # card IDs; king is implicit, non-king cards only
var enemy_king: String = "king"      # the enemy's win-condition unit (a themed Captain for tribe fights)
var power: float = 0.0               # procedural difficulty: scales enemy card stats, deck size, captain
var reward_pool: Array[String] = []  # card IDs offered as rewards after a win
var relic_offer: String = ""         # optional relic id offered alongside the card pick (elites/bosses)
# An explicit reward offer list (Array[Grant]); when non-empty the reward screen shows these
# INSTEAD of the card pool + single relic. Elites use it for their relic/charm choice.
var reward_offers: Array = []
var gold_reward: int = 0             # gold granted on win, set by EncounterTemplateData
var mineral_reward: int = 0          # authored Magic Mineral on win (the tool-driven per-type
                                     # default stacks on top — see GameData.reward_mineral)
var exp_reward: int = 1              # profile experience granted on win (1 by default; special fights more)
var material_rewards: Dictionary = {}  # profile crafting resources (id→count) granted on win
var ai: EnemyAI = null               # placeholder, no longer consulted — EnemyEngine plans the CPU turn
# Per-encounter overrides layered over BoardScoring.STOCK_SURVIVAL_WEIGHTS (role → weight,
# e.g. {"fodder": 0.5} = "in this fight, fodders are precious"). The enemy engine's one
# authored steering knob so far; empty = pure stock behaviour.
var survival_weights: Dictionary = {}

var outcome: Outcome = Outcome.PENDING

# A Combat Gym launch (see combat_gym.gd): the fight plays out exactly like the real thing,
# but its ENDING writes nothing — no rewards, no king-damage carry, no map advance, no save,
# no run end on defeat — and navigation returns to the gym instead of the map/reward flow.
var practice: bool = false

# Set by map.gd so combat can advance the run state after a win.
# completing_node_id: the node to mark as visited (was current when combat started).
# destination_node_id: the node to set as current after the win (the node clicked).
var completing_node_id: int = -1
var destination_node_id: int = -1
