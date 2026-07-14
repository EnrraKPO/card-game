extends Node

# VFX pixel probe (cue-population verification harness): plays every designed combat look and
# snapshots fixed frames, so refactors of the VFX pipeline can be pixel-compared (hash the
# PNGs of two runs). Phase 1 (designed looks) renders in a SubViewport; phase 2 (element
# variants) renders on the ROOT viewport, because the Vfx autoload draws on a root-viewport
# CanvasLayer that SubViewport captures cannot see; phase 3 checks the companion-sfx field.
# Run WINDOWED (never --headless — it hangs on render), fixed fps for deterministic tweens:
#   Godot_console.exe --path . --fixed-fps 60 res://tests/_vfx_probe.tscn -- <out_subdir>

const OUT_BASE := "res://_probe_out"
const SNAP_FRAMES := [3, 8, 14, 22, 34]

var _vp: SubViewport
var _fx_root: Control
var _player: VFXPlayer
var _src: CardUI
var _dst: CardUI


func _ready() -> void:
	var sub := "run"
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		sub = args[0]
	var out_dir := "%s/%s" % [OUT_BASE, sub]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))

	var cd: CardData = null
	for c: CardData in CardData.all():
		if c.card_type == CardData.CardType.UNIT and c.health > 0:
			cd = c
			break

	# ── Phase 1: designed looks inside a SubViewport (D1 parity captures) ──
	_vp = SubViewport.new()
	_vp.size = Vector2i(900, 520)
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_vp)
	_fx_root = _make_stage(_vp, Vector2(900, 520))
	_src = _spawn_card(cd, Vector2(110, 150), _fx_root)
	_dst = _spawn_card(cd, Vector2(620, 150), _fx_root)
	_player = VFXPlayer.new()
	_player.setup(_fx_root, Callable())
	_fx_root.add_child(_player)

	for i in 3:
		await get_tree().process_frame

	var shots: Array = [
		["health_damage",   VFXEvent.health_damage(_dst, 3)],
		["shield_hit",      VFXEvent.shield_hit(_dst, 2)],
		["heal",            VFXEvent.heal(_dst, 3)],
		["buff",            VFXEvent.buff(_dst, "attack", 2)],
		["debuff",          VFXEvent.debuff(_dst, "speed", 1)],
		["card_placed",     VFXEvent.card_placed(_dst)],
		["shield_restored", VFXEvent.shield_restored(_dst, 2)],
		["projectile_orb",  VFXEvent.projectile(_src, _dst, 4)],
		["projectile_bolt", VFXEvent.projectile(_src, _dst, 4,
				Color(0.65, 0.9, 1.0), VFXEvent.Projectile.BOLT, false)],
		["source_glint",    VFXEvent.source_trigger(_src)],
		["target_mark",     VFXEvent.target_mark(_dst, Color(1.0, 0.3, 0.3))],
		["miss",            VFXEvent.miss(_dst)],
		["death",           VFXEvent.death(_dst)],   # last — darkens the card; restored after
	]
	var idx := 0
	for pair: Array in shots:
		await _capture(str(pair[0]), pair[1] as VFXEvent, out_dir, idx,
				_player, _vp, _src, _dst)
		idx += 1

	# ── Phase 2 (D2): element variants, staged on the ROOT viewport ──
	var was_placeholder := DevFlags.placeholder_vfx
	DevFlags.placeholder_vfx = true
	var root2 := _make_stage(self, get_viewport().get_visible_rect().size)
	var src2 := _spawn_card(cd, Vector2(110, 150), root2)
	var dst2 := _spawn_card(cd, Vector2(620, 150), root2)
	var player2 := VFXPlayer.new()
	player2.setup(root2, Callable())
	root2.add_child(player2)
	for i in 3:
		await get_tree().process_frame

	var fire_orb := VFXEvent.projectile(src2, dst2, 4)
	fire_orb.composition = ["fire"]
	await _capture("d2_fire_orb", fire_orb, out_dir, 20,
			player2, get_viewport(), src2, dst2)

	var lightning_bolt := VFXEvent.projectile(src2, dst2, 4,
			Color(0.65, 0.9, 1.0), VFXEvent.Projectile.BOLT, false)
	lightning_bolt.composition = ["fire", "air"]   # unsorted on purpose — resolve must sort
	await _capture("d2_lightning_bolt", lightning_bolt, out_dir, 21,
			player2, get_viewport(), src2, dst2)

	var water_hit := VFXEvent.health_damage(dst2, 3)
	water_hit.composition = ["water"]
	await _capture("d2_water_impact", water_hit, out_dir, 22,
			player2, get_viewport(), src2, dst2)

	# Designed orb on the root stage vs the same shot with placeholders MUTED and a fire
	# composition: the muted variant must fall back to the designed look, pixel-exact.
	await _capture("d2_designed_orb", VFXEvent.projectile(src2, dst2, 4), out_dir, 30,
			player2, get_viewport(), src2, dst2)
	DevFlags.placeholder_vfx = false
	var muted := VFXEvent.projectile(src2, dst2, 4)
	muted.composition = ["fire"]
	await _capture("d2_muted_fallback", muted, out_dir, 30,
			player2, get_viewport(), src2, dst2)
	DevFlags.placeholder_vfx = was_placeholder

	# ── Phase 3 (D3): companion sfx fires atomically with Vfx.play ──
	var was_sfx := DevFlags.placeholder_sfx
	DevFlags.placeholder_vfx = true
	DevFlags.placeholder_sfx = true
	var vd := VFXData.get_vfx("card_draw_flick")
	vd.sfx = "card_draw"   # runtime-injected pairing; entries gain real pairs in D4
	Vfx.play("card_draw_flick", dst2)
	await get_tree().process_frame
	var sounding := false
	for p: AudioStreamPlayer in Sfx._pool:
		if p.playing:
			sounding = true
	vd.sfx = ""
	DevFlags.placeholder_sfx = was_sfx
	DevFlags.placeholder_vfx = was_placeholder
	print("D3 COMPANION SFX FIRED: ", sounding)

	print("PROBE DONE -> ", out_dir)
	get_tree().quit()


func _make_stage(parent: Node, stage_size: Vector2) -> Control:
	var stage := Control.new()
	stage.size = stage_size
	parent.add_child(stage)
	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.10, 0.13)
	bg.size = stage_size
	stage.add_child(bg)
	return stage


func _spawn_card(cd: CardData, pos: Vector2, stage: Control) -> CardUI:
	var ui := CardUI.create(CardInstance.from_data(cd))
	ui.position = pos
	ui.size = Vector2(160, 210)
	stage.add_child(ui)
	return ui


func _capture(look: String, event: VFXEvent, out_dir: String, idx: int,
		player: VFXPlayer, vp: Viewport, a: CardUI, b: CardUI) -> void:
	seed(1000 + idx)
	player.play(event)   # fire-and-forget; we sample frames while it runs
	var frame := 0
	var last: int = SNAP_FRAMES[SNAP_FRAMES.size() - 1]
	while frame <= last:
		await RenderingServer.frame_post_draw
		frame += 1
		if SNAP_FRAMES.has(frame):
			var img := vp.get_texture().get_image()
			img.save_png("%s/%s_f%02d.png" % [out_dir, look, frame])
	# let the effect finish + settle before the next look
	await get_tree().create_timer(1.2).timeout
	a.modulate = Color.WHITE
	b.modulate = Color.WHITE
	a.scale = Vector2.ONE
	b.scale = Vector2.ONE
