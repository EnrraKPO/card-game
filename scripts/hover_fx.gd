class_name HoverFx

# THE game-wide "the pointer is addressing this" cue, for ANY Control anywhere — a board unit, an
# empty slot, an ability in the tray, a card in hand. One language, learned once: a thick yellow
# ring means "this is the thing your cursor is talking to".
#
# It is deliberately the SAME treatment the turn-order strip already used for the unit an entry
# points at, promoted out of that one gutter. Which is also why the strip's two ends agree for free:
# hovering a card and hovering its entry are the same question asked from opposite sides of the
# screen, so they get the same ring.
#
# THE OUTLINE CHANNEL HOLDS ONE VALUE AT A TIME, and hover wins it. A selected widget already wears
# the canonical Highlight (white outline + glow + grow); while the pointer is on it, that white
# outline is MUTED and this yellow one takes its place. Nothing else about the selection changes —
# the glow still radiates and the grow still holds, so the white light reads as a halo around the
# yellow ring rather than a second ring fighting it for the same pixels. That is what keeps two
# genuinely different facts ("I picked this" / "I am pointing at this") legible at once on one card.
#
# ALL of it is data: the `hover_outline` entry in data/vfx/vfx.json (colour, width, and the glow
# that is authored off). Tool-tunable like any other look.
const ENTRY := "hover_outline"


# The cue as an idempotent STATE, not a lifecycle — ask for what a widget already has and nothing
# happens. Safe (and expected) to re-assert from any path that re-derives a widget's look.
#
# ⚠ RE-ASSERT AFTER ANYTHING THAT TOUCHES THE SELECTION. The mute is written into the live Highlight
# effect, so a widget that is picked WHILE hovered gets a brand-new Highlight with its outline at
# full width — attaching it silently undoes the mute. Owners call this again on the way out of their
# selection applier (see CardUI._apply_hover_outline); there is no way for this to notice on its own.
static func apply(widget: Control, hovered: bool) -> void:
	if widget == null or not is_instance_valid(widget):
		return
	if hovered:
		Vfx.attach(ENTRY, widget)
	else:
		Vfx.detach(ENTRY, widget)
	# The arbitration, every time — including on the way out, which is what restores the white
	# outline of a selection the pointer has just left.
	var sel: Object = Vfx.state_of(HighlightFx.ENTRY, widget)
	if sel != null and sel.has_method("set_outline_shown"):
		sel.call("set_outline_shown", not hovered)


# Whether this surface answers a hover at all. Touch has no hover: what Godot's emulated mouse
# leaves behind is a ghost cursor parked wherever you last tapped, which would leave a ring burning
# on a widget nobody is pointing at (the same reasoning that gates tooltips — see UIScale.is_touch).
static func available() -> bool:
	return not UIScale.is_touch()
