extends TestCase

# THE selection's one hazard: a pick whose subject stops existing.
#
# Selection accepts any Object as a subject — a CardInstance for a card, a bare widget for
# things that are their own subject (a forge chip, a shop/event entry's ui). The widget kind is
# a NODE, and a screen that rebuilds or tears down its entries frees it out from under the pick.
# A freed instance then fails LOUDLY at every use: `==` errors and `as` throws "Trying to cast a
# freed object" — which is exactly how it surfaced, a crash at the `Selection.current() as
# CardInstance` read in combat's interaction bridge.
#
# So the collapse is pinned at the STATE, not at the asking sites: no reader may observe a freed
# pick. These are plumbing tests — the guard's mechanics and its silence — never a claim about
# which subject any screen ought to pick.


func suite_name() -> String:
	return "Selection"


func run() -> void:
	_freed_pick_is_no_pick()
	_freed_pick_takes_its_ability()
	_collapse_is_silent()
	Selection.clear()


# A freed subject reads as nothing through EVERY reader — the guard lives at the one choke
# point, so `current()` cannot hand back what `holds()` already disowns.
func _freed_pick_is_no_pick() -> void:
	var widget := Control.new()
	Selection.select(widget)
	check(Selection.current() == widget, "a live widget is the pick")
	check(Selection.active(), "…and reads as active")
	widget.free()
	check(Selection.current() == null, "a freed pick reads as null through current()")
	check(not Selection.active(), "…and as inactive through active()")
	check(not Selection.holds(null), "…and holds nothing")
	# The regression itself: the cast that crashed combat.gd must now yield a plain null.
	var inst := Selection.current() as CardInstance
	check(inst == null, "casting the collapsed pick yields null instead of throwing")


# The ability is "the PICK's ability" — it cannot outlive the owner it hangs off, freed or not.
func _freed_pick_takes_its_ability() -> void:
	var owner_widget := Control.new()
	var ability := RefCounted.new()
	Selection.select_ability(owner_widget, ability)
	check(Selection.current_ability() == ability, "the pick's ability is held")
	owner_widget.free()
	check(Selection.current_ability() == null, "a freed owner takes its ability with it")
	check(not Selection.ability_held(owner_widget, ability), "…and holds it for nobody")


# Reading is not a transition: the pick did not MOVE, it stopped existing, and every view
# derives by self-polling (CardUI.derive_presentation). A getter that emitted would re-enter the
# derivers mid-derive — so the collapse is silent, and a later real select still signals.
func _collapse_is_silent() -> void:
	var widget := Control.new()
	Selection.select(widget)
	var beats: Array = []
	var tap := func(subject: Variant) -> void: beats.append(subject)
	Selection.changed.connect(tap)
	widget.free()
	var _ignored: Variant = Selection.current()
	check_eq(beats.size(), 0, "collapsing a freed pick emits nothing")
	Selection.select(unit("pawn"))
	check_eq(beats.size(), 1, "…and a real selection after it still signals")
	Selection.changed.disconnect(tap)
