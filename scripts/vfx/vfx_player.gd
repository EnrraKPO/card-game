class_name VFXPlayer
extends Node

var _root:           Node
var _get_card_ui:    Callable  # func(CardInstance) -> CardUI
var _get_slot_ui:    Callable  # func(BoardSlot) -> SlotUI (ground cues; unset = skipped)
# The relic-chip cue for relic-owned interceptions — func(relic_id: String). Injected by
# combat (the tray lives in its chrome); invalid = no chip on screen, cue skipped.
var relic_glint:     Callable
# Blocks until a unit is standing still — func(inst: CardInstance) -> void, injected by combat
# (see Combat._await_settled). A cue is drawn ON a card, and a card in flight is not a stage: the
# cue would be stamped where the card WAS. So any cue anchored to a unit settles it first. Invalid
# outside combat (the gym, tests) = nothing ever travels, no gate needed.
var await_settled:   Callable


func setup(root: Node, get_card_ui: Callable, get_slot_ui: Callable = Callable()) -> void:
	_root        = root
	_get_card_ui = get_card_ui
	_get_slot_ui = get_slot_ui   # func(BoardSlot) -> SlotUI; unset outside a live board
	for id: String in EFFECT_SCRIPTS:
		Vfx.register_custom(id, _run_designed.bind(EFFECT_SCRIPTS[id]))


# Fire-and-forget: call without await.  Blocking: await the call.
# The look is addressed BY LIBRARY ID (the combat_* entries, renderer "custom") and dispatched
# by the Vfx service back into the designed class registered above — combat keeps choreography
# and drawing, the library keeps the one address space every VFX resolves through.
# ELEMENT RESOLUTION happens here first: when the event carries a composition, the library
# answers with the element-variant look if one is live (projectile_/impact_<sorted comp>),
# else the designed base class plays.
func play(event: VFXEvent) -> void:
	if event.type == VFXEvent.Type.PROJECTILE:
		var vid := Vfx.resolve("projectile", event.composition)
		if not vid.is_empty():
			# Variant flight: the library's travel look flies + bursts in the element's skin.
			await Vfx.play(vid, event.target, {"source": event.source})
			# The designed projectile does its impact bookkeeping on arrival (damage number +
			# HP snap); a variant's arrival is now — same bookkeeping, same designed number read.
			if event.show_impact:
				await play(VFXEvent.health_damage(event.target, event.amount))
				if is_instance_valid(event.target):
					event.target.refresh()
			return
	elif event.type == VFXEvent.Type.HEALTH_DAMAGE:
		var iid := Vfx.resolve("impact", event.composition)
		if not iid.is_empty():
			Vfx.play(iid, event.target)   # the elemental burst under the designed number read
		# The King wounded is the run's own life bleeding — a heavier, screen-worthy cue rides
		# on top of the normal damage read.
		if _is_king(event.target):
			Vfx.play("king_hit_flash", event.target)
	elif event.type == VFXEvent.Type.DEATH:
		# A death may earn a variant dressing (king/tribe/large). It plays OVER the designed
		# fade, which always runs — the card leaving its slot is non-negotiable.
		var did := _death_variant(event.target)
		if not did.is_empty():
			Vfx.play(did, event.target)
	var id := _library_id(event)
	if id.is_empty():
		return
	await Vfx.play(id, event.target, {"event": event})
	# A designed projectile resolves its impact internally (no HEALTH_DAMAGE event follows),
	# so the King cue fires here on arrival.
	if event.type == VFXEvent.Type.PROJECTILE and event.show_impact and _is_king(event.target):
		Vfx.play("king_hit_flash", event.target)


# Plays a resolution result array (await it). Three layers read as cause → effect: (1) the SOURCE
# card glints once (its ability fired); (2) every affected card gets a tinted TARGET reticle that
# leads its hit; (3) the effect's own VFX lands. Layers 2 + 3 fire for ALL targets AT ONCE, so a
# multi-target effect (e.g. a death that damages a whole row) reads as one simultaneous burst rather
# than a one-card-at-a-time walk — the reticles still call out exactly who is hit and how. When the
# source unit is on the board, health damage flies in as a projectile from it (the impact snaps HP +
# shows the number on arrival); otherwise damage resolves on the target in place.
# CALLERS MUST AWAIT THIS before cleanup_effect_deaths(), or a killed target is freed mid-sequence.
#
# PACING is NOT held here. Every beat below simply awaits its own cue, which returns at that cue's
# handoff (see the "Sequencing" section in Vfx): the glint's tail runs under the reticle, the
# reticle's under the hit. The four fixed sleeps this used to carry — SOURCE_HOLD, MARK_LEAD,
# STEP_HOLD, CHIP_LEAD — were dead air between finished animations, and are now the one global
# `vfx.overlap` dial. The two spans below are the exceptions: cues drawn by somebody else (a
# status pip, a relic tray chip) with no library entry to read a span from.
const PIP_SPAN  := 0.30   # a status pip's proc flash (StatusPip.flash_proc)
const CHIP_SPAN := 0.34   # a relic chip glinting in the tray (RelicTray.glint)

func play_results(results: Array, source_inst: CardInstance = null,
		cue_status_id: String = "", show_cue: bool = true) -> void:
	var source_ui: CardUI = null
	if source_inst != null:
		# The ACTOR settles before its ability is presented: a unit still withdrawing from its own
		# strike glints, and fires any projectile, from where it has come to rest — not from a card
		# sliding away underneath the cue. Covers the whole resolution, since source_ui is also the
		# origin every damage bolt below flies from.
		source_ui = await _stage(source_inst)
	# The source's composition rides every hit of this resolution, so damage can play its
	# element-variant look — known here even when the source has no on-board UI.
	var comp: Array = []
	if source_inst != null and source_inst.data != null:
		comp = source_inst.data.elements

	# Layer 1 — the CONTAINER cue: glint the container whose effects are about to land, once, and only
	# when the effects actually move a stat (a no-op resolution shouldn't flare). An empty cue id glints
	# the source card itself (the card container); a status id glints that status's pip. `show_cue` off
	# skips it entirely (e.g. run-level effects with no on-board container).
	if show_cue and source_ui != null and is_instance_valid(source_ui) and not results.is_empty():
		if cue_status_id.is_empty():
			await play(VFXEvent.source_trigger(source_ui))
		else:
			var pip := source_ui.find_status_pip(cue_status_id)
			if pip != null:
				pip.flash_proc()
				_status_tick_sfx(cue_status_id)
				await _hold(Vfx.handoff(PIP_SPAN))

	# Launch each affected card's reticle + hit as its own sub-sequence and let them run together.
	# `remaining` is a mutable box (Array so the concurrent calls share one counter); each sub-
	# sequence ticks it down when its hit lands, and we drain the box before returning so callers
	# still see every hit resolved before they sweep deaths.
	var remaining := [0]
	for r: Dictionary in results:
		if r.is_empty():
			continue
		# Whatever intercepted this result's mutation inside the Arbitrator cues FIRST — the
		# rewriter (relic chip / status pip) reads as the cause of the adjusted number.
		if r.has("interceptions"):
			await play_interceptions(r.get("interceptions"))
		# A status application has no stat delta — it's its own cue: mark the target, then pop the
		# pip that was added/stacked. Handled up front, sequentially, so it reads before stat hits.
		if r.has("status_applied"):
			# A GROUND application's target is a BoardSlot — its arrival plays on the SLOT
			# (tint + pip appearing, pip blooming), never on the card-shaped path.
			var st_target := r.get("target") as CardInstance
			if st_target != null:
				await _play_status_applied(st_target, str(r.get("status_applied", "")))
			else:
				var st_slot := r.get("target") as BoardSlot
				if st_slot != null:
					await _play_ground_status_applied(st_slot, str(r.get("status_applied", "")))
			continue
		# A side-targeted result (draw/mana — target is a CombatSide, not a card) has no board
		# surface here: its presentation IS the hand/gauge reacting to the side's signals.
		var inst := r.get("target") as CardInstance
		if inst == null:
			continue
		# HAVING A CARD is the test, not being on the board: the unit this result killed was
		# undocked the instant it died, and its number has to land on the card still standing
		# there. A side target (no card) and a hand card (not in a slot) both fall out here.
		var card_ui: CardUI = _get_card_ui.call(inst) as CardUI
		if card_ui == null:
			continue
		var attr:  String = r.get("attribute", "")
		var delta: int    = r.get("delta", 0)
		if delta == 0:
			continue
		remaining[0] += 1
		# `inst`, not the UI resolved above: a target that is itself travelling (a retaliation
		# striking the attacker mid-withdrawal) settles first, then its stage is re-resolved — by
		# then the ghost has landed and the cue anchors to where the unit actually is.
		_play_target(inst, attr, delta, source_ui, comp, remaining)

	if remaining[0] == 0:
		return
	# Drain to the last hit's HANDOFF, not its last frame — the burst's tails keep playing while
	# the caller moves on to whatever comes next.
	while remaining[0] > 0:
		await get_tree().process_frame


# Plays the cue for each interception record (Outcome.interceptions, or a result dict's
# "interceptions" key), in firing order — pure playback; resolution already happened. A
# status-owned record flashes that status's pip on its holder; a card-owned one glints the
# holder's card; a relic-owned one glints its tray chip via the injected relic_glint.
# Upgrades (and un-owned run records) have no combat chip — no cue surface.
func play_interceptions(records: Array) -> void:
	for rec: Dictionary in records:
		var kind := str(rec.get("owner_kind", ""))
		if kind == "relic":
			if relic_glint.is_valid():
				relic_glint.call(str(rec.get("owner_id", "")))
				await _hold(Vfx.handoff(CHIP_SPAN))
			continue
		if kind != "status" and kind != "card":
			continue
		var holder: CardInstance = rec.get("holder")
		var ui: CardUI = await _stage(holder)
		if ui == null:
			continue
		if kind == "status":
			var pip := ui.find_status_pip(str(rec.get("owner_id", "")))
			if pip != null:
				pip.flash_proc()
				await _hold(Vfx.handoff(PIP_SPAN))
		else:
			await play(VFXEvent.source_trigger(ui))


# A status landing on a card: a benefit-tinted reticle on the card, then refresh so the new/updated
# pip exists, then pop that pip so the gained stack reads. No stat number — the pip carries the count.
# A status arriving on the GROUND: re-derive the slot's ground look right now (the tint and
# pip must exist before they can bloom — the same place-a-frame-late choreography as the card
# path), then the pip's "gained" bloom in the status's own colour. Same sfx vocabulary as a
# unit application.
func _play_ground_status_applied(slot: BoardSlot, status_id: String) -> void:
	if not _get_slot_ui.is_valid():
		return
	var slot_ui := _get_slot_ui.call(slot) as SlotUI
	if slot_ui == null or not is_instance_valid(slot_ui):
		return
	slot_ui.render_ground()
	await get_tree().process_frame   # let the freshly built pip lay out before it can pivot/pop
	var sd := StatusData.get_status(status_id)
	var beneficial := sd == null or sd.beneficial
	Sfx.play("status_apply_buff" if beneficial else "status_apply_debuff")
	# The ground's own burst goes with the tab's glint, not after it: the slot catching light and
	# the tab appearing are ONE event, and staging them in sequence would read as two.
	slot_ui.flare_ground(status_id)
	var pip := slot_ui.find_ground_pip(status_id)
	if pip != null:
		pip.flash_applied()
		await _hold(Vfx.handoff(PIP_SPAN))


func _play_status_applied(inst: CardInstance, status_id: String) -> void:
	var card_ui: CardUI = await _stage(inst)
	if card_ui == null:
		return
	var sd := StatusData.get_status(status_id)
	var beneficial := sd == null or sd.beneficial
	var tint := Color(0.55, 0.95, 0.6) if beneficial else Color(0.95, 0.55, 0.55)
	Sfx.play("status_apply_buff" if beneficial else "status_apply_debuff")
	await play(VFXEvent.target_mark(card_ui, tint))
	card_ui.refresh()
	await get_tree().process_frame   # let the freshly built pip lay out before it can pivot/pop
	var pip := card_ui.find_status_pip(status_id)
	if pip != null:
		pip.flash_applied()
		await _hold(Vfx.handoff(PIP_SPAN))


# One affected card's slice of a (possibly multi-target) resolution, run concurrently with its
# siblings: the tinted reticle leads (so the eye arrives first), then the effect's own VFX lands.
# Ticks `remaining` down on completion so play_results knows when the whole burst has resolved.
func _play_target(inst: CardInstance, attr: String, delta: int, source_ui: CardUI,
		comp: Array, remaining: Array) -> void:
	var card_ui: CardUI = await _stage(inst)
	if card_ui == null:
		remaining[0] -= 1   # nothing to draw on — release the counter or play_results never drains
		return
	# Layer 2 — target reticle leads the hit, tinted by what's happening to this card. The await
	# returns once the reticle has SNAPPED IN (its handoff); its fade plays out under the hit.
	await play(VFXEvent.target_mark(card_ui, _result_color(attr, delta)))
	# Layer 3 — the effect's own VFX. A projectile defers the HP snap to its own impact, so
	# don't double-refresh here. Damage carries the source's composition so the library can
	# answer with the element-variant look (see play()).
	var deferred := false
	match attr:
		"health":
			if delta < 0:
				if source_ui != null and is_instance_valid(source_ui) and source_ui != card_ui:
					var shot := VFXEvent.projectile(source_ui, card_ui, -delta)
					shot.composition = comp
					await play(shot)
					deferred = true
				else:
					var hit := VFXEvent.health_damage(card_ui, -delta)
					hit.composition = comp
					await play(hit)
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


# THE one place a unit becomes a place to draw on: settle it, then resolve its card. Every cue
# anchored to a unit goes through here, which is what makes "a moving card is not a stage" a single
# rule rather than a check remembered at each call site. Returns null when the unit has no on-board
# surface (off the board, or swept between resolution and playback).
func _stage(inst: CardInstance) -> CardUI:
	if inst == null:
		return null
	if await_settled.is_valid():
		await await_settled.call(inst)
	# No placement check: a unit that has just died is already undocked, and its card is
	# precisely what its send-off is played on. Having no card IS the "no surface" answer —
	# for a hand card, a spell token, or a corpse already disposed of.
	var ui := _get_card_ui.call(inst) as CardUI
	return ui if ui != null and is_instance_valid(ui) else null


func _hold(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _is_king(ui: CardUI) -> bool:
	return ui != null and is_instance_valid(ui) and ui.card_instance != null \
			and ui.card_instance.data != null and ui.card_instance.data.is_king


# The death dressing a unit earns: the King's shatter, its tribe's signature, or the heavy
# version for expensive units. "" = just the designed fade. Gated on Vfx.live so muted
# placeholders fall back silently.
const LARGE_DEATH_COST := 5

func _death_variant(ui: CardUI) -> String:
	if ui == null or not is_instance_valid(ui) or ui.card_instance == null:
		return ""
	var data := ui.card_instance.data
	if data == null:
		return ""
	if data.is_king and Vfx.live("death_king"):
		return "death_king"
	if not data.tribe.is_empty() and Vfx.live("death_" + data.tribe):
		return "death_" + data.tribe
	if data.cost >= LARGE_DEATH_COST and Vfx.live("death_large"):
		return "death_large"
	return ""


# A status proc's sound, when the library defines one for it (damage_poison_tick, …).
func _status_tick_sfx(status_id: String) -> void:
	var tick := "damage_%s_tick" % status_id
	if SoundData.get_sound(tick) != null:
		Sfx.play(tick)


# The reticle/category tint for a result, by the same (attribute, sign) logic that routes the
# effect VFX below — one classification, reused. Extend both together when adding a category.
func _result_color(attr: String, delta: int) -> Color:
	match attr:
		"health": return Color(0.3, 1.0, 0.4) if delta > 0 else Color(1.0, 0.3, 0.3)
		"shield": return Color(0.5, 0.85, 1.0)
		_:        return Color(1.0, 0.85, 0.2) if delta > 0 else Color(0.78, 0.42, 1.0)


# ── The designed looks, as library custom renderers ───────────────────────────
# Each combat_* entry in data/vfx/vfx.json (renderer "custom") maps to one designed effect
# class. Supporting a new VFX type = a new effect file + a row here + a library entry.

var EFFECT_SCRIPTS := {
	"combat_health_damage":   VFXEffectHealthDamage,
	"combat_shield_hit":      VFXEffectShieldHit,
	"combat_heal":            VFXEffectHeal,
	"combat_buff":            VFXEffectBuff,
	"combat_debuff":          VFXEffectDebuff,
	"combat_death":           VFXEffectDeath,
	"combat_card_placed":     VFXEffectCardPlaced,
	"combat_shield_restored": VFXEffectShieldRestored,
	"combat_projectile_orb":  VFXEffectProjectile,
	"combat_projectile_bolt": VFXEffectProjectile,
	"combat_source_glint":    VFXEffectSourceGlint,
	"combat_target_mark":     VFXEffectTargetMark,
	"combat_miss":            VFXEffectMiss,
	"combat_dodge":           VFXEffectDodge,
	"combat_crit":            VFXEffectCrit,
}


# The library id a VFXEvent plays as. The two projectile looks share one class; the event's
# style picks the entry.
func _library_id(event: VFXEvent) -> String:
	match event.type:
		VFXEvent.Type.HEALTH_DAMAGE:   return "combat_health_damage"
		VFXEvent.Type.SHIELD_HIT:      return "combat_shield_hit"
		VFXEvent.Type.HEAL:            return "combat_heal"
		VFXEvent.Type.BUFF:            return "combat_buff"
		VFXEvent.Type.DEBUFF:          return "combat_debuff"
		VFXEvent.Type.DEATH:           return "combat_death"
		VFXEvent.Type.CARD_PLACED:     return "combat_card_placed"
		VFXEvent.Type.SHIELD_RESTORED: return "combat_shield_restored"
		VFXEvent.Type.PROJECTILE:
			if event.proj_style == VFXEvent.Projectile.BOLT:
				return "combat_projectile_bolt"
			return "combat_projectile_orb"
		VFXEvent.Type.SOURCE_TRIGGER:  return "combat_source_glint"
		VFXEvent.Type.TARGET_MARK:     return "combat_target_mark"
		VFXEvent.Type.MISS:            return "combat_miss"
		VFXEvent.Type.DODGE:           return "combat_dodge"
		VFXEvent.Type.CRIT:            return "combat_crit"
		_:
			push_warning("VFXPlayer: no library id for event type %d" % event.type)
			return ""


# The custom-renderer callable behind every combat entry: instantiate the designed class and
# run it against the VFXEvent carried in opts, drawing into the combat tree exactly as before.
# Returns at the look's HANDOFF (see Vfx's "Sequencing" section) — the class declares its own
# span, the dial decides how much of it counts as its moment, and the tail plays on under the
# next beat. A class that leaves span at 0 is ATOMIC and awaited to its last frame.
func _run_designed(_vd: VFXData, _target: Control, opts: Dictionary, effect_script: GDScript) -> void:
	var event: VFXEvent = opts.get("event")
	if event == null:
		return
	var effect: VFXEffect = effect_script.new()
	effect.setup(event, _root)
	add_child(effect)
	# ONLY a declared-atomic look (span 0) is awaited through play(). "Its handoff equals its span"
	# is NOT the same statement, and collapsing the two inverted the whole dial: nearly every
	# designed look builds its tweens and returns immediately (only Death and Projectile await
	# themselves), so at overlap 0 — where handoff == span — `await effect.play()` returned in zero
	# frames and Step by step ran with NO pacing at all, faster than every other setting. A spanned
	# look is always paced by the timer, which at overlap 0 waits its full span.
	if effect.span <= 0.0:
		await effect.play()
		return
	effect.play()
	await get_tree().create_timer(Vfx.handoff(effect.span, _vd)).timeout
