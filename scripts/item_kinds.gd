class_name ItemKinds
extends RefCounted

# The registry of acquirable item kinds, keyed by a short string ("card"/"charm"/"relic"). Built
# once at static-init (mirrors CharmData._all / EffectHooks._hooks). The unified offer/grant
# surfaces (shop, rewards, relic event) resolve kinds here through Grant, so a new item type is a
# single registration with no changes to those screens.

static var _kinds: Dictionary = {}


static func _static_init() -> void:
	_kinds["card"]  = ItemKindCard.new()
	_kinds["charm"] = ItemKindCharm.new()
	_kinds["relic"] = ItemKindRelic.new()


# The handler for a kind key, or null if unknown (callers guard).
static func get_kind(kind: String) -> ItemKind:
	return _kinds.get(kind, null)
