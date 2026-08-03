shader_type canvas_item;
render_mode unshaded;

// ── Heat haze: the air over a fire, not a thing drawn on top of it ────────────────────────────
//
// Every other effect in the library ADDS light. This one adds nothing at all — it re-samples what
// is already on screen through a rising distortion, so the read is "the picture is wobbling"
// rather than "something is floating here". That is why it is a shader and not a particle: a
// visible particle is exactly what a heat wave is not.
//
// The displacement dies to zero at the top and at the edges, and a zero displacement samples the
// pixel the fragment already sat on — so the field needs no mask and leaves no seam.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float strength = 0.004;   // peak displacement, in SCREEN uv (kept small — see below)
uniform float speed = 0.55;       // how fast the column climbs
uniform float wave_scale = 5.0;   // waves across the rect; higher = finer, more turbulent air
uniform float base = 0.9;         // how far up the rect the shimmer is still at full strength
uniform float top_fade = 0.15;    // where it has thinned out completely

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453);
}

// Value noise: cheap, and smooth enough that the air LOOKS like air rather than like static.
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void fragment() {
	// UV.y is 0 at the TOP, so the fire's own surface is at 1: strongest there, gone by top_fade.
	float column = smoothstep(top_fade, base, UV.y);
	// Two octaves scrolling upward (adding TIME to the sampled y moves features toward smaller y).
	// The second is finer and faster, which is what stops the column reading as one slow ripple.
	float n1 = vnoise(vec2(UV.x * wave_scale, UV.y * wave_scale * 0.7 + TIME * speed));
	float n2 = vnoise(vec2(UV.x * wave_scale * 2.1 + 3.7, UV.y * wave_scale * 1.4 + TIME * speed * 1.7));
	float wob = (n1 - 0.5) * 0.7 + (n2 - 0.5) * 0.3;
	// Mostly sideways: rising air shears horizontally. A vertical-dominant wobble reads as the
	// whole picture bouncing, which is a camera shake, not heat.
	vec2 off = vec2(wob, wob * 0.35) * strength * column;
	COLOR = texture(screen_tex, SCREEN_UV + off);
}
