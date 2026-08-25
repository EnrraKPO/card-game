class_name StatusPipView
extends RefCounted

# The plain facts one status badge renders — nothing else (docs/planning/RULINGS.html R4:
# views take injected data, never pull from the game world). Whoever composes this decides
# every display question that needs game knowledge (what counts, whether stacks show); the
# pip just paints what it is handed.

var id: String = ""                  # opaque token — matching and VFX conventions key on it
var subject: GameEntity = null       # the core Status this view renders — what the fight
                                     # screen keys the pip's R14 surface registration by;
                                     # null where no engine stands behind the view (hand
                                     # items, previews). A reference the pip never reads —
                                     # the same "what this is a view OF" seat CardUI's
                                     # view_subject carries.
var display_name: String = ""
var color: Color = Color.WHITE
var icon: Texture2D = null           # preferred art; null falls back to the glyph
var glyph: String = ""
var count: int = 1                   # the headline number (shown when > 1)
var stacks: int = 1                  # intensity; also the tab count for a duplicates status
var show_stacks: bool = false        # the "x N" tag beside the headline count
var duplicates: bool = false         # ground rows show one tab PER stack instead of a count
var aura: bool = false               # the holder's card wears a whole-card ring in `color`
var description: String = ""         # tooltip body (empty = title only)
