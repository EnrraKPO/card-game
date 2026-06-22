class_name Grant
extends RefCounted

# A single acquirable item: a (kind, id, count) descriptor that delegates every operation to its
# ItemKind (see ItemKinds). The unified currency of the offer/grant layer — shops, reward screens
# and events build lists of Grants and render/price/apply them generically, never special-casing
# the item type. Serialisable so encounters/events can author reward specs as data.

var kind: String = ""
var id: String = ""
var count: int = 1


static func make(p_kind: String, p_id: String, p_count: int = 1) -> Grant:
	var g := Grant.new()
	g.kind = p_kind
	g.id = p_id
	g.count = p_count
	return g


func _kind_def() -> ItemKind:
	return ItemKinds.get_kind(kind)


func display_name() -> String:
	var k := _kind_def()
	return k.display_name(id) if k != null else id


func tooltip() -> String:
	var k := _kind_def()
	return k.tooltip(id) if k != null else id


func price() -> int:
	var k := _kind_def()
	return k.default_price(id) if k != null else 0


func can_apply() -> bool:
	var k := _kind_def()
	return k != null and k.can_grant(id)


func make_ui() -> Control:
	var k := _kind_def()
	return k.make_offer_ui(id) if k != null else Control.new()


func apply() -> void:
	var k := _kind_def()
	if k != null:
		k.grant(id, count)


static func from_dict(d: Dictionary) -> Grant:
	return Grant.make(d.get("kind", ""), d.get("id", ""), int(d.get("count", 1)))


func to_dict() -> Dictionary:
	return {"kind": kind, "id": id, "count": count}
