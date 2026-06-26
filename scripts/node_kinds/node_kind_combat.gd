class_name NodeKindCombat
extends NodeKind

# Shared by Combat, Elite, and Boss nodes — they only differ in which
# EncounterTemplateData pool gets sampled (see EncounterTemplateData.pick_for).
func enter(node: MapNodeData, map_screen: MapScreen) -> void:
	var stage: int = GameData.current_run.act if GameData.current_run != null else 1
	# Per-node RNG. A map-wide rng can't be shared here: the map scene reloads after every
	# fight and re-seeds it to the same map_seed, so the first roll — and thus the chosen
	# template — would be identical for every node (every combat became the same tribe).
	# Derive a stable, distinct seed per node instead: varied between nodes, reproducible
	# within a run (mirrors the medallion-jitter seeding in map.gd).
	var rng := RandomNumberGenerator.new()
	var seed_base: int = GameData.current_map_state.map_seed if GameData.current_map_state != null else 0
	rng.seed = seed_base ^ (node.id * 2654435761)
	var template := EncounterTemplateData.pick_for(node.type, node.floor, stage, rng)
	if template == null:
		push_error("NodeKindCombat: no encounter template available for node_type %s" % node.type)
		return

	var enc := template.instantiate(rng)
	enc.material_rewards    = node.material_rewards.duplicate()   # the reward previewed on the map
	enc.completing_node_id  = map_screen.current_node_id
	enc.destination_node_id = node.id
	GameData.current_encounter = enc
	map_screen.get_tree().change_scene_to_file("res://scenes/combat.tscn")
