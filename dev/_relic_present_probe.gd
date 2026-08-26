extends Node
# Diagnostic for the relic/status presentation road ON THE SCREEN: boots the stub fight,
# resolves the relic's surface, then fires the windup and the status_applied /
# health_damage cues by hand, screenshotting mid-show. Run WITHOUT stderr swallowed —
# a script error in the dressing path is a finding.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_relic_present_probe.tscn
const OUT_GLINT := "res://dev/_relic_present_glint.png"
const OUT_CUES := "res://dev/_relic_present_cues.png"

var _sv: SubViewport = null


func _shot(path: String) -> void:
	_sv.get_texture().get_image().save_png(path)


func _ready() -> void:
	_sv = SubViewport.new()
	_sv.size = Vector2i(1422, 800)
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)
	var screen := FightScreen.new()
	_sv.add_child(screen)
	screen.size = _sv.size
	await get_tree().create_timer(1.2).timeout

	var relic: GameEntity = null
	for member: GameEntity in screen.world.player_side().get_container(&"relics").members:
		relic = member
	print("relic entity: ", relic.id if relic != null else "MISSING")
	var surface: Control = screen.surface_of(relic)
	print("surface_of(relic): ", surface if surface != null else "NULL")

	var captain: Unit = null
	for entity: GameEntity in screen.world.all_entities():
		if entity is Unit and (entity as Unit).is_king \
				and entity.allegiance == screen.world.enemy_side():
			captain = entity
	print("captain: ", captain.id if captain != null else "MISSING",
			" card_of: ", screen.card_of(captain))

	var recipients: Array[GameEntity] = [captain]
	screen.world.outlet.windup(&"glint", relic, recipients)
	await get_tree().create_timer(0.15).timeout
	_shot(OUT_GLINT)

	screen.play_cue(&"status_applied", captain, 1.0)
	screen.play_cue(&"health_damage", captain, 1.0)
	await get_tree().create_timer(0.25).timeout
	_shot(OUT_CUES)
	print("PROBE DONE")
	get_tree().quit()
