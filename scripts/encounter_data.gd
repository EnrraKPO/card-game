class_name EncounterData
extends RefCounted

enum Type    { COMBAT, ELITE, BOSS }
enum Outcome { PENDING, WIN, LOSE }

var type: Type = Type.COMBAT
var enemy_deck: Array[String] = []   # card IDs; king is implicit, non-king cards only
var reward_pool: Array[String] = []  # card IDs offered as rewards after a win
var ai: EnemyAI = null               # null falls back to default EnemyAI in combat

var outcome: Outcome = Outcome.PENDING

# Set by map.gd so combat can advance the run state after a win.
# completing_node_id: the node to mark as visited (was current when combat started).
# destination_node_id: the node to set as current after the win (the node clicked).
var completing_node_id: int = -1
var destination_node_id: int = -1
