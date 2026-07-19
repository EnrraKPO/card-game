class_name ItemKindCurrency
extends ItemKind

# Run-scoped currencies as acquirable items in the unified offer/grant layer: id "gold" or
# "magic_mineral" (Materials.MAGIC_MINERAL), count = the amount. Registered as kind "currency"
# (see ItemKinds), which lets every generic surface pay them out — the shop sells Magic Mineral
# (priced by the shop.magic_mineral.price attribute), and events/reward offers can author
# Grant("currency", id, n) to hand out gold or mineral without bespoke code.

const GOLD := "gold"

const GOLD_COLOR := Color("9c7a10")


# Only Magic Mineral is ever OFFERED (shops sell it for gold; offering gold for gold is
# nonsense). Gold stays grantable — events author it as an explicit Grant.
func offer_pool(count: int, _rng: RandomNumberGenerator) -> Array[String]:
	if count <= 0:
		return []
	var out: Array[String] = [Materials.MAGIC_MINERAL]
	return out


func display_name(id: String) -> String:
	return "Gold" if id == GOLD else Materials.display_name(id)


func tooltip(id: String) -> String:
	if id == GOLD:
		return "Gold — the run's purse."
	return "Magic Mineral — fuels card merges at the Forge."


func color(id: String) -> Color:
	return GOLD_COLOR if id == GOLD else Materials.color(id)


func default_price(id: String) -> int:
	if id == Materials.MAGIC_MINERAL:
		return GameData.value("shop.magic_mineral.price")
	return 0


func can_grant(_id: String) -> bool:
	return GameData.current_run != null


func grant(id: String, count: int) -> void:
	var run := GameData.current_run
	if run == null:
		return
	if id == GOLD:
		run.gold += count
	elif id == Materials.MAGIC_MINERAL:
		run.magic_mineral += count
	GameData.save_run()


func make_offer_ui(id: String) -> Control:
	return make_chip("✦", color(id), tooltip(id), Materials.texture(id) if id != GOLD else null)
