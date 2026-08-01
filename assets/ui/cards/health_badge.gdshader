shader_type canvas_item;

// The health badge IS the health gauge. The heart drains from the top like any progress bar: the
// spent share above the line is knocked down to a dark version of itself (still the badge, just
// unlit), the surviving share below it stays at full strength. A hard edge, deliberately — this is
// a readout, not an effect, and a soft boundary would blur the one number it exists to convey.
//
// The heart is also RECOLOURED along the way: green while healthy, through yellow, to red at
// death's door. The tint is fed whole from CardUI (see HEALTH_RAMP there) so the ramp's stops live
// with the font-colour thresholds they're anchored to, instead of being split across two files.
//
// Recolouring is saturation-keyed, not a flat modulate: `sat` is ~1 on the heart's saturated red
// body and ~0 on its near-black outline and the antialiased greys, so the tint lands on the shape
// and the linework it needs to read against is left alone. `value` carries the source's own
// shading through, so the art keeps whatever gradient it had.

uniform float fill : hint_range(0.0, 1.0) = 1.0;
uniform vec4 tint : source_color = vec4(0.95, 0.15, 0.12, 1.0);
// How far the spent share is knocked down. Not as far as it wants to go: at low health almost the
// whole heart is spent, and a deep enough dim there turns the badge — the thing that most needs to
// shout at 4 HP — into a dark smudge.
uniform float dim : hint_range(0.0, 1.0) = 0.42;
// The heart's own vertical extent inside the texture (measured from its alpha bounds). The fill
// line is mapped across THIS span, not the full UV rect, so half health cuts the heart at its
// visual middle instead of somewhere in the transparent margin above it.
uniform float art_top = 0.191;
uniform float art_bottom = 0.919;

// The node's modulate, carried in from the vertex colour — the card dims itself wholesale in
// several states (unplayable in hand, non-interactive enemy, phantom), and a fragment that wrote
// COLOR outright would ignore every one of them.
varying vec4 mod_color;

void vertex() {
	mod_color = COLOR;
}

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float value = max(tex.r, max(tex.g, tex.b));
	float low = min(tex.r, min(tex.g, tex.b));
	float sat = value > 0.0 ? (value - low) / value : 0.0;
	vec3 rgb = mix(tex.rgb, tint.rgb * value, sat);
	if (UV.y < mix(art_bottom, art_top, fill)) {
		rgb *= dim;
	}
	COLOR = vec4(rgb, tex.a) * mod_color;
}
