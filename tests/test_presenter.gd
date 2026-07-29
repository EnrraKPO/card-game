extends TestCase

# CombatPresenter: the cascade's injected presentation surface (Step 2 of
# COMBAT_DECOUPLING_REFACTOR.md). Pins the ONE property the whole decoupling leans on:
# awaiting the null presenter never suspends — GDScript's await is pay-per-suspend, so a
# cascade handed the base class runs synchronously to completion in a single call.


func suite_name() -> String:
	return "Combat presenter"


func run() -> void:
	_null_presenter_is_synchronous()


func _null_presenter_is_synchronous() -> void:
	var p := CombatPresenter.new()
	# A coroutine that awaits EVERY method of the surface. If any of them actually
	# suspended, the flag would still be false on the line after call() — lambdas run
	# synchronously exactly as far as their first real suspension. (The flag lives in an
	# array because lambdas capture locals by VALUE; the container is the shared channel.)
	var reached: Array = [false]
	var chain := func() -> void:
		await p.show_effect_results([], null)
		await p.relic_glint("some_relic")
		await p.beat(1.0)
		await p.king_fall(null, null)
		await p.unit_fade(null, null)
		p.board_refresh()
		reached[0] = true
	chain.call()
	check(bool(reached[0]), "awaiting the null presenter falls straight through — same stack, same frame")
