class_name VFXEvent
extends RefCounted

enum Type {
	HEALTH_DAMAGE,
	SHIELD_HIT,
	HEAL,
	BUFF,
	DEBUFF,
	DEATH,
	CARD_PLACED,
	SHIELD_RESTORED,
	COMBINE,
}

var type:      Type
var target:    CardUI
var attribute: String = ""
var amount:    int    = 0


static func health_damage(card: CardUI, dmg: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.HEALTH_DAMAGE; e.target = card; e.amount = dmg
	return e


static func shield_hit(card: CardUI, absorbed: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.SHIELD_HIT; e.target = card; e.amount = absorbed
	return e


static func heal(card: CardUI, amount: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.HEAL; e.target = card; e.amount = amount
	return e


static func buff(card: CardUI, attr: String, amount: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.BUFF; e.target = card; e.attribute = attr; e.amount = amount
	return e


static func debuff(card: CardUI, attr: String, amount: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.DEBUFF; e.target = card; e.attribute = attr; e.amount = amount
	return e


static func death(card: CardUI) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.DEATH; e.target = card
	return e


static func card_placed(card: CardUI) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.CARD_PLACED; e.target = card
	return e


static func shield_restored(card: CardUI, amount: int) -> VFXEvent:
	var e := VFXEvent.new()
	e.type = Type.SHIELD_RESTORED; e.target = card; e.amount = amount
	return e
