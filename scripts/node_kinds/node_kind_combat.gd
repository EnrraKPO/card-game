class_name NodeKindCombat
extends NodeKind

# Shared by Combat, Elite, and Boss nodes — they only differ in which
# EncounterTemplateData pool gets sampled (see EncounterTemplateData.pick_for).
func enter(node: MapNodeData, map_screen: MapScreen) -> void:
	var template := EncounterTemplateData.pick_for(node.type, node.floor, map_screen.encounter_rng)
	if template == null:
		push_error("NodeKindCombat: no encounter template available for node_type %s" % node.type)
		return

	var enc := template.instantiate(map_screen.encounter_rng)
	enc.completing_node_id  = map_screen.current_node_id
	enc.destination_node_id = node.id
	GameData.current_encounter = enc
	map_screen.get_tree().change_scene_to_file("res://scenes/combat.tscn")
