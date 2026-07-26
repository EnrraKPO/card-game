class_name TextIcons
extends RefCounted

# Inline keyword icons for rules text. Game terms are authored as EXPLICIT `<id>` markup
# (e.g. "<pawn>", "<attack>") — never bare words — so incidental prose ("a holy knight",
# "Fire the coach") is left untouched and, crucially, a translated string can't collide with
# the icon pass. Each marked term resolves to EITHER its chip [img] icon (when the surface
# shows icons AND the term has one, i.e. the 6 elements + 6 pieces) OR its appointed word for
# the active language (Loc "term.<id>", covering the icon-less stat terms and every non-icon
# surface). The icon pass matches the stable id, so it is language-independent; localization
# is just the Loc lookup for the leftovers. Rules text renders through rich_label; callers opt
# in per text surface.

# Bakes of the ACTUAL card composition chips (tinted container + icon), rendered by
# dev/_chip_bake.tscn — rerun that scene whenever the chip style changes. Keyword icons in text
# thus look exactly like the chips on the card face.
const ICONS := {
	"air":      "res://assets/ui/icons/text/air.png",
	"darkness": "res://assets/ui/icons/text/darkness.png",
	"earth":    "res://assets/ui/icons/text/earth.png",
	"fire":     "res://assets/ui/icons/text/fire.png",
	"light":    "res://assets/ui/icons/text/light.png",
	"water":    "res://assets/ui/icons/text/water.png",
	"pawn":     "res://assets/ui/icons/text/pawn.png",
	"bishop":   "res://assets/ui/icons/text/bishop.png",
	"knight":   "res://assets/ui/icons/text/knight.png",
	"rook":     "res://assets/ui/icons/text/rook.png",
	"queen":    "res://assets/ui/icons/text/queen.png",
	"king":     "res://assets/ui/icons/text/king.png",
}

static var _regex: RegEx

# Native tooltips are theme-styled (TooltipLabel); tooltip_body reads the same values so an
# icon tooltip matches a plain one exactly.
const THEME: Theme = preload("res://assets/ui/theme.tres")
# Cap on a tooltip's single-line width before it wraps.
const TIP_MAX_WIDTH := 560.0


# Drop-in Button/Panel whose native hover tooltip renders keyword icons: assign tooltip_text
# as usual, the override swaps the popup's plain label for an enriched RichTextLabel.
class TipButton extends Button:
	func _make_custom_tooltip(for_text: String) -> Object:
		if UIScale.is_touch():
			return null
		return TextIcons.tooltip_body(for_text)


class TipPanel extends Panel:
	func _make_custom_tooltip(for_text: String) -> Object:
		if UIScale.is_touch():
			return null
		return TextIcons.tooltip_body(for_text)


# Rules text -> BBCode. Every `<id>` term markup is replaced by its chip [img] icon (when
# `icons` and the term HAS an icon, sized proportionally to the font — a touch over it so the
# chip reads at line height, its rim eating a few px) or else by the appointed word for the
# active language (Loc "term.<id>"). Bare words are NEVER matched — only explicit markup. The
# surrounding prose is treated as PLAIN text: literal '[' is escaped so authored brackets
# (and the resolved words) can't inject BBCode. Pass icons=false for plain-text surfaces.
static func enrich(text: String, font_size: int, icons := true) -> String:
	if _regex == null:
		_regex = RegEx.new()
		_regex.compile("<([a-z0-9_]+)>")
	var icon_px := int(font_size * 1.3)
	var out := ""
	var last := 0
	for m: RegExMatch in _regex.search_all(text):
		out += _escape(text.substr(last, m.get_start() - last))
		var id := m.get_string(1)
		if icons and ICONS.has(id):
			out += "[img=%dx%d]%s[/img]" % [icon_px, icon_px, ICONS[id]]
		else:
			out += _escape(Loc.t("term." + id))
		last = m.get_end()
	out += _escape(text.substr(last))
	return out


static func _escape(s: String) -> String:
	return s.replace("[", "[lb]")


# Markup resolved to PLAIN words, for surfaces without a RichTextLabel — native tooltips and
# plain Labels, which can render neither an [img] icon nor BBCode. Each <id> becomes its
# appointed word for the active language (these surfaces showed the bare English word before
# markup, so this preserves them while making them translatable). No '[' escaping: the output
# is literal text, not BBCode.
static func plain(text: String) -> String:
	if _regex == null:
		_regex = RegEx.new()
		_regex.compile("<([a-z0-9_]+)>")
	var out := ""
	var last := 0
	for m: RegExMatch in _regex.search_all(text):
		out += text.substr(last, m.get_start() - last)
		out += Loc.t("term." + m.get_string(1))
		last = m.get_end()
	out += text.substr(last)
	return out


# The standard enriched rules-text label: autowrapped, content-fit, mouse-transparent.
# Callers pin width / size flags per surface (see CardTooltip's SIZING RULE — an unpinned
# autowrap label can report phantom minimum heights). Pass TRANSPARENT to keep the theme's
# text colour.
static func rich_label(text: String, font_size: int, color := Color.TRANSPARENT,
		centered := false) -> RichTextLabel:
	var rtl := RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.scroll_active = false
	rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rtl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rtl.add_theme_font_size_override("normal_font_size", font_size)
	if color.a > 0.0:
		rtl.add_theme_color_override("default_color", color)
	set_text(rtl, text, centered)
	return rtl


# (Re)assigns enriched text, re-deriving icon size from the label's CURRENT font size — use
# this instead of `.text =` so live font rescaling (e.g. reward offers) re-sizes icons too.
static func set_text(rtl: RichTextLabel, text: String, centered := false) -> void:
	var body := enrich(text, rtl.get_theme_font_size("normal_font_size"))
	rtl.text = ("[center]%s[/center]" % body) if centered else body


# Replacement content for a native hover tooltip (Control._make_custom_tooltip): the same
# text, styled from the theme's TooltipLabel items, with keyword icons. Width = the text's
# natural span (so short tips stay small), capped so long ones wrap.
static func tooltip_body(tip: String) -> Control:
	var fs := THEME.get_font_size("font_size", "TooltipLabel")
	var rtl := rich_label(tip, fs, THEME.get_color("font_color", "TooltipLabel"))
	rtl.add_theme_color_override("font_outline_color",
		THEME.get_color("font_outline_color", "TooltipLabel"))
	rtl.add_theme_constant_override("outline_size",
		THEME.get_constant("outline_size", "TooltipLabel"))
	var font := THEME.default_font if THEME.default_font != null else rtl.get_theme_font("normal_font")
	var est := font.get_multiline_string_size(tip, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x + 16.0
	rtl.custom_minimum_size.x = minf(est, TIP_MAX_WIDTH)
	return rtl
