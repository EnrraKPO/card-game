class_name HandItemView
extends RefCounted

# One card's presence IN THE HAND (docs/planning/RULINGS.html R8): the wrapper carrying the
# visual states a card has by virtue of its association to the hand presentation. The card's
# own face rides inside (CardData + status views, the card concept unchanged); the
# hand-relational facts sit beside it and NEVER land on the face — the card widget stays
# ignorant of the hand it happens to be fanned in.

# The identity token this item stands for — what Selection names, and what keeps the item's
# card widget STABLE across reinjections (the bar reconciles by it, so a mid-gesture refresh
# never frees the card being gestured with). Opaque to every widget: compared, never read.
var subject: Variant = null
var card: CardData = null
var statuses: Array[StatusPipView] = []
var affordable: bool = true    # the side can pay this card's cost right now
var pickable: bool = false     # a live pick's candidate — wears the candidate tint
