extends Node
# Renders the fight screen on the SLICE fight — the player's Contagion Stone seated by
# Genesis — to verify the relic strip's world mode: the Side's relic renders its chip.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_relic_tray_shot.tscn
const OUT := "res://dev/_relic_tray_out.png"


func _ready() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(1422, 800)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.transparent_bg = false
	add_child(sv)
	var bg := ColorRect.new()
	bg.color = Color(0.13, 0.12, 0.11)
	bg.size = sv.size
	sv.add_child(bg)
	var screen := FightScreen.new()
	screen.next_fight = FightScreen.slice_fight()
	sv.add_child(screen)
	screen.size = sv.size
	await get_tree().create_timer(1.2).timeout
	sv.get_texture().get_image().save_png(OUT)
	print("RENDERED fight screen on the slice fight (relic tray world mode)")
	get_tree().quit()
