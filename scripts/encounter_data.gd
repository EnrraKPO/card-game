class_name EncounterData
extends RefCounted

enum Type    { COMBAT, ELITE, BOSS }
enum Outcome { PENDING, WIN, LOSE }

var type: Type = Type.COMBAT
var enemy_deck: Array[String] = []   # card IDs; king is implicit, non-king cards only
var enemy_king: String = "king"      # the enemy's win-condition unit (a themed Captain for tribe fights)
var reward_pool: Array[String] = []  # card IDs offered as rewards after a win
var relic_offer: String = ""         # optional relic id offered alongside the card pick (elites/bosses)
var gold_reward: int = 0             # gold granted on win, set by EncounterTemplateData
var exp_reward: int = 1              # profile experience granted on win (1 by default; special fights more)
var material_rewards: Dictionary = {}  # profile crafting resources (id→count) granted on win
var ai: EnemyAI = null               # null falls back to default EnemyAI in combat

var outcome: Outcome = Outcome.PENDING

# Set by map.gd so combat can advance the run state after a win.
# completing_node_id: the node to mark as visited (was current when combat started).
# destination_node_id: the node to set as current after the win (the node clicked).
var completing_node_id: int = -1
var destination_node_id: int = -1
