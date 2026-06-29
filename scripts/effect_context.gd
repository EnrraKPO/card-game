class_name EffectContext
extends RefCounted

var source: CardInstance
var player_board: Array  # [row][col] -> CardInstance or null
var enemy_board: Array   # [row][col] -> CardInstance or null
var manual_target: CardInstance = null
var attack_target: CardInstance = null   # the unit `source` is striking, during an ON_ATTACK


static func make(src: CardInstance, p_board: Array, e_board: Array) -> EffectContext:
	var ctx := EffectContext.new()
	ctx.source = src
	ctx.player_board = p_board
	ctx.enemy_board = e_board
	return ctx
