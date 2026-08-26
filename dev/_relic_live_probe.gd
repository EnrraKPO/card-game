extends Node
# Films the live road: boots the stub fight on the real screen, swaps both commanders for
# the pass-only base (kings trade blows, the relic procs each round), lets the fight run
# itself, and saves a frame every 0.4s — the glint, status_applied and poison ticks must
# appear across the strip if the live dressing works.
# "D:/Godot/Godot_v4.6.3-stable_win64_console.exe" --path . res://dev/_relic_live_probe.tscn

var _sv: SubViewport = null


func _ready() -> void:
	_sv = SubViewport.new()
	_sv.size = Vector2i(1422, 800)
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)
	var screen := FightScreen.new()
	_sv.add_child(screen)
	screen.size = _sv.size
	# Before the deferred _run fires: machinery commanders — no UI waits, rounds roll.
	screen.world.clock.player_commander = Commander.new()
	screen.world.clock.enemy_commander = Commander.new()
	await get_tree().create_timer(0.8).timeout
	for i: int in range(30):
		await get_tree().create_timer(0.4).timeout
		_sv.get_texture().get_image().save_png("res://dev/_relic_live_%02d.png" % i)
	print("FILMED 30 frames")
	get_tree().quit()
