extends Node
# Throwaway probe for the phantom wash's SHAPE. Renders the same card three times over a flat
# background — background alone, card unwashed, card washed — so the two masks can be compared
# pixel-exactly outside the game:
#   card mask  = (card render != background render)   -> where the card actually has pixels
#   wash mask  = (washed render != card render)       -> where the wash actually paints
# Everything the wash paints outside the card mask is tint on nothing; everything in the card mask
# the wash misses is a card pixel left at full saturation. Run WITHOUT --headless.
#   godot --path . res://dev/_phantom_probe.tscn -- pawn
const OUT_DIR := "res://dev/"
const RES := Vector2i(420, 520)
const CARD_SIZE := Vector2(260, 340)   # native; the forge stand-ins are a scaled-down version

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var card_id: String = args[0] if args.size() > 0 else "pawn"
	var sv := SubViewport.new()
	sv.size = RES
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# A flat, saturated background nothing on the card shares, so "differs from background" is a
	# clean test for "the card drew here".
	sv.transparent_bg = false
	add_child(sv)
	var bg := ColorRect.new()
	bg.color = Color(1, 0, 1)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sv.add_child(bg)

	await _shoot(sv, "_phantom_bg.png")

	var inst := CardInstance.from_data(CardData.get_card(card_id))
	inst.owner = 0
	var card := CardUI.create(inst)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.position = (Vector2(RES) - CARD_SIZE) * 0.5
	card.size = CARD_SIZE
	# "preadd" reproduces the CardInspector's order: the card is dressed BEFORE it is mounted, so
	# anything CardUI builds during its own _ready/refresh arrives after the treatment was applied.
	var preadd := "preadd" in args
	if preadd:
		card.set_phantom(true)
	sv.add_child(card)
	if preadd:
		await _shoot(sv, "_phantom_on.png")
		card.set_phantom(false)
		await _shoot(sv, "_phantom_off.png")
	else:
		await _shoot(sv, "_phantom_off.png")
		card.set_phantom(true)
		await _shoot(sv, "_phantom_on.png")
	print("PROBE done: card=", card_id, " card_rect=", card.get_rect())
	get_tree().quit()


func _shoot(sv: SubViewport, name: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	sv.get_texture().get_image().save_png(OUT_DIR + name)
