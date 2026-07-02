class_name UIPalette
extends Resource

# The app's whole theme palette, backing ScreenUI's static color constants (see screen_ui.gd) —
# edit the Color() values below directly to retheme the game; every screen picks them up
# automatically since ScreenUI reads them once at class-load time.

@export_group("Surfaces")
@export var bg_color := Color("7585c5ff")             # the app background — Shell, and nothing else
@export var surface_color := Color("a6aae1ff")        # header/footer/panel surfaces sitting on bg_color
@export var surface_border := Color("778cd4ff")       # accent border on a surface_color panel
@export var surface_deep := Color("9ea3e8ff")         # inset panels sitting ON a surface
@export var surface_deep_border := Color("7071cdff")
@export var text_color := Color("ffffffff")           # default warm dark text on a light background

@export_group("Button chrome")
@export var chrome_neutral := Color("7687b2ff")       # matte blue — everyday/secondary actions
@export var chrome_confirm := Color("fac300ff")       # gold — THE primary/confirm action
@export var chrome_danger := Color("c73838")        # red — destructive/reset actions
@export var chrome_ready := Color("00ab1dff")         # green — combat's Ready button only
@export var chrome_debug := Color("f6871d")         # orange — the debug affordance
@export var chrome_ink := Color("1c2136")           # handoff's shared outline ink

@export_group("Combat board")
@export var slot_empty := Color("272e4eff")           # empty battlefield slot — deliberately separate
													 # from surface_deep; the board, not app chrome
@export var slot_border_idle := Color(0.40, 0.36, 0.30)
@export var slot_border_highlight := Color(0.95, 0.75, 0.1)
@export var mana_track_bg := Color(0.203, 0.21, 0.547, 1.0)
@export var mana_track_border := Color(0.036, 0.0, 0.37, 1.0)
@export var mana_lit := Color(0.3, 0.358, 1.0, 1.0)     # mana chunk: available
@export var mana_dim := Color(0.066, 0.014, 0.46, 1.0)     # mana chunk: spent / not yet ramped into
