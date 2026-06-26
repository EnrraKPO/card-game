class_name VFXPlayer
extends Node

var _root:        Node
var _get_card_ui: Callable  # func(CardInstance) -> CardUI


func setup(root: Node, get_card_ui: Callable) -> void:
	_root        = root
	_get_card_ui = get_card_ui


# Fire-and-forget: call without await.  Blocking: await the call.
func play(event: VFXEvent) -> void:
	var effect := _make_effect(event.type)
	if effect == null:
		return
	effect.setup(event, _root)
	add_child(effect)
	await effect.play()


# Converts EffectSystem result arrays into VFX events and plays them. When the effect's
# `source` unit is on the board, health damage flies in as a projectile from it (the impact
# snaps HP + shows the number on arrival); otherwise damage resolves on the target in place.
func play_results(results: Array, source_inst: CardInstance = null) -> void:
	var source_ui: CardUI = null
	if source_inst != null and source_inst.row >= 0:
		source_ui = _get_card_ui.call(source_inst) as CardUI
	for r: Dictionary in results:
		if r.is_empty():
			continue
		var inst: CardInstance = r.get("target")
		if inst == null or inst.row < 0:
			continue
		var card_ui: CardUI = _get_card_ui.call(inst) as CardUI
		if card_ui == null:
			continue
		var attr:  String = r.get("attribute", "")
		var delta: int    = r.get("delta", 0)
		if delta == 0:
			continue
		# A projectile defers the HP snap to its own impact, so don't double-refresh here.
		var deferred := false
		match attr:
			"health":
				if delta < 0:
					if source_ui != null and is_instance_valid(source_ui) and source_ui != card_ui:
						play(VFXEvent.projectile(source_ui, card_ui, -delta))
						deferred = true
					else:
						play(VFXEvent.health_damage(card_ui, -delta))
				else:
					play(VFXEvent.heal(card_ui, delta))
			"shield":
				if delta < 0: play(VFXEvent.shield_hit(card_ui, -delta))
				else:         play(VFXEvent.shield_restored(card_ui, delta))
			_:
				if delta > 0: play(VFXEvent.buff(card_ui, attr, delta))
				else:         play(VFXEvent.debuff(card_ui, attr, -delta))
		# The instance was already mutated by the effect; snap the card's printed stats so the
		# change is visible immediately, not only at the next board-wide refresh (end of turn).
		if not deferred:
			card_ui.refresh()


# ── Registry ───────────────────────────────────────────────────────────────────
# Add a new match arm + a new effect file to support a new VFX type.

func _make_effect(type: VFXEvent.Type) -> VFXEffect:
	match type:
		VFXEvent.Type.HEALTH_DAMAGE:   return VFXEffectHealthDamage.new()
		VFXEvent.Type.SHIELD_HIT:      return VFXEffectShieldHit.new()
		VFXEvent.Type.HEAL:            return VFXEffectHeal.new()
		VFXEvent.Type.BUFF:            return VFXEffectBuff.new()
		VFXEvent.Type.DEBUFF:          return VFXEffectDebuff.new()
		VFXEvent.Type.DEATH:           return VFXEffectDeath.new()
		VFXEvent.Type.CARD_PLACED:     return VFXEffectCardPlaced.new()
		VFXEvent.Type.SHIELD_RESTORED: return VFXEffectShieldRestored.new()
		VFXEvent.Type.PROJECTILE:      return VFXEffectProjectile.new()
		_:
			push_warning("VFXPlayer: no effect registered for type %d" % type)
			return null
