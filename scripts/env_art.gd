class_name EnvArt

# Environment art loader for diegetic "room" screens (crafting, and later shop/lab). Each room's
# dressing lives at assets/environments/<env>/<slot>.<ext> under stable slot names, so generated
# PNGs (installed by the Tool's Environments tab) override the hand-authored SVG placeholders 1:1
# without touching screen code.
static func tex(env: String, slot: String) -> Texture2D:
	for ext: String in ["png", "svg"]:
		var path := "res://assets/environments/%s/%s.%s" % [env, slot, ext]
		if ResourceLoader.exists(path):
			return load(path)
	return null
