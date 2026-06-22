class_name ItemKindCharm
extends ItemKind

# Charms as an acquirable item: granting one adds its id to the run's charm inventory (applied
# later in the forge). Flat-priced, rendered as a coloured chip.

const PRICE := 60


func offer_pool(count: int, _rng: RandomNumberGenerator) -> Array[String]:
	var pool: Array = CharmData.all()
	pool.shuffle()
	var out: Array[String] = []
	for i in mini(count, pool.size()):
		out.append((pool[i] as CharmData).id)
	return out


func make_offer_ui(id: String) -> Control:
	var c := CharmData.get_charm(id)
	if c == null:
		return Control.new()
	return ItemKind.make_chip(c.letter, c.color, tooltip(id))


func display_name(id: String) -> String:
	var c := CharmData.get_charm(id)
	return c.display_name if c != null else id.capitalize()


func tooltip(id: String) -> String:
	var c := CharmData.get_charm(id)
	return "%s — %s" % [c.display_name, c.description] if c != null else id.capitalize()


func color(id: String) -> Color:
	var c := CharmData.get_charm(id)
	return c.color if c != null else Color.WHITE


func default_price(_id: String) -> int:
	return PRICE


func grant(id: String, _count: int) -> void:
	if GameData.current_run == null:
		return
	GameData.current_run.charms.append(id)
	GameData.save_run()
