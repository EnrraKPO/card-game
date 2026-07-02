class_name ItemKindRelic
extends ItemKind

# Relics as an acquirable item: granting one adds its id to run.relics and rebuilds the run's
# ModifierSet so the relic's effects take hold immediately. Relics are run-unique and capped at
# the tunable "relic.capacity" (see GameAttributes), so can_grant gates both.

func offer_pool(count: int, _rng: RandomNumberGenerator) -> Array[String]:
	var pool: Array = RelicData.all().filter(func(r: RelicData) -> bool: return not _owned(r.id))
	pool.shuffle()
	var out: Array[String] = []
	for i in mini(count, pool.size()):
		out.append((pool[i] as RelicData).id)
	return out


func make_offer_ui(id: String) -> Control:
	var r := RelicData.get_relic(id)
	if r == null:
		return Control.new()
	return ItemKind.make_chip(r.letter, r.color, tooltip(id))


func display_name(id: String) -> String:
	var r := RelicData.get_relic(id)
	return r.display_name if r != null else id.capitalize()


func tooltip(id: String) -> String:
	var r := RelicData.get_relic(id)
	return "%s — %s" % [r.display_name, r.description] if r != null else id.capitalize()


func color(id: String) -> Color:
	var r := RelicData.get_relic(id)
	return r.color if r != null else Color.WHITE


func default_price(id: String) -> int:
	var r := RelicData.get_relic(id)
	return r.price if r != null else 80


func can_grant(id: String) -> bool:
	if GameData.current_run == null or _owned(id):
		return false
	return GameData.current_run.relics.size() < GameData.value("relic.capacity")


func grant(id: String, _count: int) -> void:
	if not can_grant(id):
		return
	GameData.current_run.add_relic(id)


func _owned(id: String) -> bool:
	return GameData.current_run != null and id in GameData.current_run.relics
