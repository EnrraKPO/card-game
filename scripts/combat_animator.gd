class_name CombatAnimator
extends Node

var _root:       Node
var _get_card_ui: Callable  # func(CardInstance) -> CardUI
var _vfx:        VFXPlayer


func setup(root: Node, p_get_card_ui: Callable, vfx: VFXPlayer) -> void:
	_root        = root
	_get_card_ui = p_get_card_ui
	_vfx         = vfx


# Converts EffectSystem result arrays to VFX events via VFXPlayer. Pass `source` (the unit
# whose effect produced these results) so direct damage flies in as a projectile from it.
func show_effect_results(results: Array, source: CardInstance = null) -> void:
	_vfx.play_results(results, source)


# ── Positional animations (lunge / retreat / shake) ───────────────────────────

func spawn_ghost(source: CardUI) -> CardUI:
	var ghost := CardUI.create(source.card_instance)
	ghost.z_index             = 20
	ghost.mouse_filter        = Control.MOUSE_FILTER_IGNORE
	ghost.custom_minimum_size = source.size
	_root.add_child(ghost)
	ghost.global_position = source.global_position
	return ghost


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
	var tw := create_tween()
	tw.set_ease(Tween.EASE_IN)
	tw.set_trans(Tween.TRANS_QUAD)
	tw.tween_property(ghost, "global_position", target_pos, 0.3)
	await tw.finished


func play_retreat(ghost: CardUI, home_pos: Vector2) -> void:
	var tw := create_tween()
	tw.set_ease(Tween.EASE_OUT)
	tw.set_trans(Tween.TRANS_QUAD)
	tw.tween_property(ghost, "global_position", home_pos, 0.2)
	await tw.finished
