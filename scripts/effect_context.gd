class_name EffectContext
extends RefCounted

var source: CardInstance                 # the HOLDER: the unit whose effect is being evaluated
var player_board: Array  # [row][col] -> CardInstance or null
var enemy_board: Array   # [row][col] -> CardInstance or null
var manual_target: CardInstance = null
var attack_target: CardInstance = null   # the unit `source` is striking, during an ON_ATTACK
# The SUBJECT: the unit the broadcast event is about (who activated / attacked / died). An effect's
# subject_filter is evaluated against this relative to the holder; null for subject-less phase events.
var subject: CardInstance = null


static func make(src: CardInstance, p_board: Array, e_board: Array) -> EffectContext:
	var ctx := EffectContext.new()
	ctx.source = src
	ctx.player_board = p_board
	ctx.enemy_board = e_board
	return ctx
