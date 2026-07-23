class_name UpgradeNode
extends RefCounted

# A single point in a skill tree (see UpgradeTree). Grid-positioned by row/col (row = depth,
# col = lateral); `requires` lists the node ids that must be owned first, drawn as links by
# the Upgrades screen. Buying a node (ProfileData.purchase_upgrade) spends its `cost` upgrade
# points and contributes its `effects` (run-wide Effects) to the run's ModifierSet.

var id: String
# Localized text (Loc `upgrade.<id>.name`/`.desc`), not read from the data file. See CardData.
var _name_override := ""
var display_name: String:
	get:
		var s := Loc.opt("upgrade.%s.name" % id)
		return s if s != "" else _name_override
	set(value):
		_name_override = value
var _desc_override := ""
var description: String:
	get:
		var s := Loc.opt("upgrade.%s.desc" % id)
		return s if s != "" else _desc_override
	set(value):
		_desc_override = value
var cost: int = 1
var icon: String = "✦"
var row: int = 0
var col: int = 0
var requires: Array[String] = []
var effects: Array = []   # Array[Effect] — the run-wide effects this node grants


static func from_dict(d: Dictionary) -> UpgradeNode:
	var n := UpgradeNode.new()
	n.id           = d.get("id", "")
	# display_name/description resolve through Loc by id (see the property getters).
	n.cost         = int(d.get("cost", 1))
	n.icon         = d.get("icon", "✦")
	n.row          = int(d.get("row", 0))
	n.col          = int(d.get("col", 0))
	for r: String in d.get("requires", []):
		n.requires.append(r)
	for e: Dictionary in d.get("effects", []):
		n.effects.append(Effect.from_dict(e))
	return n
