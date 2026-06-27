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


# Plays an EffectSystem result array (await it). Three layers read as cause → effect: (1) the SOURCE
# card glints once (its ability fired); (2) every affected card gets a tinted TARGET reticle that
# leads its hit; (3) the effect's own VFX lands. Layers 2 + 3 fire for ALL targets AT ONCE, so a
# multi-target effect (e.g. a death that damages a whole row) reads as one simultaneous burst rather
# than a one-card-at-a-time walk — the reticles still call out exactly who is hit and how. When the
# source unit is on the board, health damage flies in as a projectile from it (the impact snaps HP +
# shows the number on arrival); otherwise damage resolves on the target in place.
# CALLERS MUST AWAIT THIS before cleanup_effect_deaths(), or a killed target is freed mid-sequence.
const SOURCE_HOLD := 0.22   # beat after the caster glints, before its effects start landing
const MARK_LEAD   := 0.24   # the reticle reads as "look at THIS card" before its badge cue fires
const STEP_HOLD   := 0.30   # beat after the burst resolves, before returning

func play_results(results: Array, source_inst: CardInstance = null) -> void:
	var source_ui: CardUI = null
	if source_inst != null and source_inst.row >= 0:
		source_ui = _get_card_ui.call(source_inst) as CardUI

	# Layer 1 — source glint: once, and only when the effect actually moved a stat (an empty/no-op
	# resolution shouldn't flare). Spells pass no on-board source, so they're naturally skipped.
	if source_ui != null and is_instance_valid(source_ui) and _has_effect(results):
		await play(VFXEvent.source_trigger(source_ui))
		await _hold(SOURCE_HOLD)

	# Launch each affected card's reticle + hit as its own sub-sequence and let them run together.
	# `remaining` is a mutable box (Array so the concurrent calls share one counter); each sub-
	# sequence ticks it down when its hit lands, and we drain the box before returning so callers
	# still see every hit resolved before they sweep deaths.
	var remaining := [0]
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
		remaining[0] += 1
		_play_target(card_ui, attr, delta, source_ui, remaining)

	if remaining[0] == 0:
		return
	while remaining[0] > 0:
		await get_tree().process_frame
	await _hold(STEP_HOLD)


# One affected card's slice of a (possibly multi-target) resolution, run concurrently with its
# siblings: the tinted reticle leads (so the eye arrives first), then the effect's own VFX lands.
# Ticks `remaining` down on completion so play_results knows when the whole burst has resolved.
func _play_target(card_ui: CardUI, attr: String, delta: int, source_ui: CardUI, remaining: Array) -> void:
	# Layer 2 — target reticle leads the hit, tinted by what's happening to this card.
	await play(VFXEvent.target_mark(card_ui, _result_color(attr, delta)))
	await _hold(MARK_LEAD)
	# Layer 3 — the effect's own VFX. A projectile defers the HP snap to its own impact, so
	# don't double-refresh here.
	var deferred := false
	match attr:
		"health":
			if delta < 0:
				if source_ui != null and is_instance_valid(source_ui) and source_ui != card_ui:
					await play(VFXEvent.projectile(source_ui, card_ui, -delta))
					deferred = true
				else:
					await play(VFXEvent.health_damage(card_ui, -delta))
			else:
				await play(VFXEvent.heal(card_ui, delta))
		"shield":
			if delta < 0: await play(VFXEvent.shield_hit(card_ui, -delta))
			else:         await play(VFXEvent.shield_restored(card_ui, delta))
		_:
			if delta > 0: await play(VFXEvent.buff(card_ui, attr, delta))
			else:         await play(VFXEvent.debuff(card_ui, attr, -delta))
	# The instance was already mutated by the effect; snap the card's printed stats so the
	# change is visible immediately, not only at the next board-wide refresh (end of turn).
	if not deferred and is_instance_valid(card_ui):
		card_ui.refresh()
	remaining[0] -= 1


func _hold(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


# Whether any result actually changed a stat (drives the source glint — a no-op resolution
# shouldn't flare its caster).
func _has_effect(results: Array) -> bool:
	for r: Dictionary in results:
		if not r.is_empty() and int(r.get("delta", 0)) != 0:
			return true
	return false


# The reticle/category tint for a result, by the same (attribute, sign) logic that routes the
# effect VFX below — one classification, reused. Extend both together when adding a category.
func _result_color(attr: String, delta: int) -> Color:
	match attr:
		"health": return Color(0.3, 1.0, 0.4) if delta > 0 else Color(1.0, 0.3, 0.3)
		"shield": return Color(0.5, 0.85, 1.0)
		_:        return Color(1.0, 0.85, 0.2) if delta > 0 else Color(0.78, 0.42, 1.0)


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
		VFXEvent.Type.SOURCE_TRIGGER:  return VFXEffectSourceGlint.new()
		VFXEvent.Type.TARGET_MARK:     return VFXEffectTargetMark.new()
		_:
			push_warning("VFXPlayer: no effect registered for type %d" % type)
			return null
