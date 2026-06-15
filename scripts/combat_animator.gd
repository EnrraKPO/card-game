class_name CombatAnimator
extends Node

var _root: Node
var get_card_ui: Callable  # func(CardInstance) -> CardUI


func setup(root: Node, p_get_card_ui: Callable) -> void:
	_root = root
	get_card_ui = p_get_card_ui


# ── Effect results ─────────────────────────────────────────────────────────────

func show_effect_results(results: Array) -> void:
	for r: Dictionary in results:
		if r.is_empty():
			continue
		var target: CardInstance = r.get("target")
		if target == null or target.row < 0 or target.col < 0:
			continue
		var card_ui := get_card_ui.call(target) as CardUI
		if card_ui == null:
			continue
		spawn_effect_label(card_ui, r.get("attribute", ""), r.get("delta", 0))


func spawn_effect_label(card_ui: CardUI, attribute: String, delta: int) -> void:
	if delta == 0:
		return
	var lbl := Label.new()
	var sign := "+" if delta > 0 else ""
	match attribute:
		"health":
			lbl.text     = "%s%d HP" % [sign, delta]
			lbl.modulate = Color(0.3, 1.0, 0.3) if delta > 0 else Color(1.0, 0.4, 0.4)
		"max_health":
			lbl.text     = "%s%d Max HP" % [sign, delta]
			lbl.modulate = Color(0.4, 0.9, 0.4) if delta > 0 else Color(1.0, 0.4, 0.4)
		"attack":
			lbl.text     = "%s%d ATK" % [sign, delta]
			lbl.modulate = Color(1.0, 0.85, 0.1) if delta > 0 else Color(1.0, 0.5, 0.2)
		"speed":
			lbl.text     = "%s%d SPD" % [sign, delta]
			lbl.modulate = Color(0.3, 0.8, 1.0) if delta > 0 else Color(0.7, 0.5, 0.9)
		_:
			lbl.text     = "%s%d %s" % [sign, delta, attribute.to_upper()]
			lbl.modulate = Color(1.0, 1.0, 1.0)
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.z_index  = 15
	lbl.position = card_ui.global_position + Vector2(card_ui.size.x * 0.5 - 20.0, 0.0)
	_root.add_child(lbl)
	var tween := create_tween()
	tween.tween_property(lbl, "position:y", lbl.position.y - 60.0, 0.7)
	tween.parallel().tween_property(lbl, "modulate:a", 0.0, 0.7)
	tween.tween_callback(lbl.queue_free)


func spawn_damage_label(card: CardUI, amount: int) -> void:
	if card == null:
		return
	var lbl := Label.new()
	lbl.text     = "-%d" % amount
	lbl.modulate = Color(1.0, 0.25, 0.25)
	lbl.z_index  = 10
	lbl.add_theme_font_size_override("font_size", 30)
	lbl.position = card.global_position + card.size * 0.5 - Vector2(20, 20)
	_root.add_child(lbl)
	var tween := create_tween()
	tween.tween_property(lbl, "position:y", lbl.position.y - 64.0, 0.6)
	tween.parallel().tween_property(lbl, "modulate:a", 0.0, 0.6)
	tween.tween_callback(lbl.queue_free)


# ── Card animations ────────────────────────────────────────────────────────────

func spawn_ghost(source: CardUI) -> CardUI:
	var ghost := CardUI.create(source.card_instance)
	ghost.z_index          = 20
	ghost.mouse_filter     = Control.MOUSE_FILTER_IGNORE
	ghost.custom_minimum_size = source.size
	_root.add_child(ghost)
	ghost.global_position  = source.global_position
	return ghost


func animate_card_placed(card: CardUI) -> void:
	if card == null:
		return
	card.modulate = Color(1.6, 1.6, 0.5)
	var tween := create_tween()
	tween.tween_property(card, "modulate", Color.WHITE, 0.3)


func tween_flash(card: CardUI, flash_color: Color, return_color: Color, duration: float) -> void:
	if card == null:
		return
	var tween := create_tween()
	tween.tween_property(card, "modulate", flash_color,   duration * 0.3)
	tween.tween_property(card, "modulate", return_color,  duration * 0.7)


func animate_death(card: CardUI) -> void:
	if card == null:
		return
	var tween := create_tween()
	tween.tween_property(card, "modulate", Color(0.6, 0.1, 0.1, 0.0), 0.4)
	await tween.finished


func shake_card(card: CardUI) -> void:
	if card == null:
		return
	var origin := card.position
	var d      := 6.0
	var t      := 0.04
	var tw     := create_tween()
	tw.tween_property(card, "position", origin + Vector2(d,        0), t)
	tw.tween_property(card, "position", origin + Vector2(-d,       0), t)
	tw.tween_property(card, "position", origin + Vector2(d * 0.5,  0), t)
	tw.tween_property(card, "position", origin + Vector2(-d * 0.5, 0), t)
	tw.tween_property(card, "position", origin,                        t)
	await tw.finished


func play_lunge(ghost: CardUI, target_pos: Vector2) -> void:
	var tween := create_tween()
	tween.set_ease(Tween.EASE_IN)
	tween.set_trans(Tween.TRANS_QUAD)
	tween.tween_property(ghost, "global_position", target_pos, 0.3)
	await tween.finished


func play_retreat(ghost: CardUI, home_pos: Vector2) -> void:
	var tween := create_tween()
	tween.set_ease(Tween.EASE_OUT)
	tween.set_trans(Tween.TRANS_QUAD)
	tween.tween_property(ghost, "global_position", home_pos, 0.2)
	await tween.finished
