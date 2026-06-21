class_name UpgradeNode
extends RefCounted

# A single point in a skill tree (see UpgradeTree). Grid-positioned by row/col (row = depth,
# col = lateral); `requires` lists the node ids that must be owned first, drawn as links by
# the Upgrades screen. Buying a node (ProfileData.purchase_upgrade) spends its `cost` upgrade
# points and contributes its `effects` (run-wide Effects) to the run's ModifierSet.

var id: String
var display_name: String
var description: String
var cost: int = 1
var icon: String = "✦"
var row: int = 0
var col: int = 0
var requires: Array[String] = []
var effects: Array = []   # Array[Effect] — the run-wide effects this node grants


static func from_dict(d: Dictionary) -> UpgradeNode:
	var n := UpgradeNode.new()
	n.id           = d.get("id", "")
	n.display_name = d.get("display_name", "")
	n.description  = d.get("description", "")
	n.cost         = int(d.get("cost", 1))
	n.icon         = d.get("icon", "✦")
	n.row          = int(d.get("row", 0))
	n.col          = int(d.get("col", 0))
	for r: String in d.get("requires", []):
		n.requires.append(r)
	for e: Dictionary in d.get("effects", []):
		n.effects.append(Effect.from_dict(e))
	return n
