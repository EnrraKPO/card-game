// Inner glow — light hugging the INSIDE of a silhouette's edge, derived from the source
// texture's alpha. The companion to filter_glow: where that one blurs the silhouette outward
// so light escapes the shape, this blurs the silhouette's ABSENCE and masks the result by the
// shape, so the light lands just inside the outline and fades toward the middle. The object
// reads as lit from within rather than surrounded.
//
// GEOMETRY, opposite to the outer glow: it never spills, so its filter entry authors pad = 0
// (the quad equals the source) and layer = "above" — the light is inside the silhouette, so it
// has to draw OVER the art it is lighting rather than behind it.
//
// Taps that fall beyond the source rect count as "outside the shape", which is what makes the
// light hug the outline correctly at the texture's own border.
shader_type canvas_item;
// ADDITIVE, and it matters: alpha-blending this over the art tints it (a warm wash) instead of
// lighting it. At subtle intensities a tint is invisible, so the effect reads as broken rather
// than as understated — the first version of this shader looked like nothing at all.
render_mode blend_add;

uniform sampler2D src_tex : filter_linear_mipmap, repeat_disable;

uniform vec4 glow_color : source_color = vec4(1.0, 0.82, 0.45, 1.0);
uniform vec2 u_size = vec2(64.0, 64.0);              // this quad's size in px (set from script)
uniform vec4 u_src_rect = vec4(0.0, 0.0, 1.0, 1.0);  // source's sub-rect in our UV
uniform float spread = 24.0;      // how far INWARD the light reaches, px
uniform float intensity = 0.5;    // brightness multiplier — the handle animation drives
uniform float falloff = 2.0;      // >1 keeps the light tight to the outline

const int RINGS = 3;
const int TAPS = 12;

vec2 to_src(vec2 uv) { return (uv - u_src_rect.xy) / u_src_rect.zw; }
bool outside_rect(vec2 s) { return s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0; }

// How ABSENT the silhouette is at a UV: 1 outside the shape (and beyond the source rect, which
// is empty space), 0 deep inside it.
float src_absence(vec2 uv, float lod) {
	vec2 s = to_src(uv);
	if (outside_rect(s)) {
		return 1.0;
	}
	return 1.0 - textureLod(src_tex, s, lod).a;
}

void fragment() {
	vec2 s = to_src(UV);
	float here = outside_rect(s) ? 0.0 : texture(src_tex, s).a;
	if (here <= 0.001) {
		// Outside the silhouette there is nothing to light from within.
		COLOR = vec4(0.0);
	} else {
		float acc = 0.0;
		float wsum = 0.0;
		for (int r = 1; r <= RINGS; r++) {
			float rr = float(r) / float(RINGS);
			float dist = spread * rr;
			float w = pow(1.0 - rr, falloff);
			float lod = max(log2(dist * 0.5), 0.0);
			float phase = float(r) * 0.7;
			for (int t = 0; t < TAPS; t++) {
				float ang = TAU * float(t) / float(TAPS) + phase;
				vec2 off = vec2(cos(ang), sin(ang)) * dist / u_size;
				acc += src_absence(UV + off, lod) * w;
				wsum += w;
			}
		}
		// Near the outline the neighbourhood is mostly empty -> bright; deep inside -> dark.
		float edge = clamp(acc / max(wsum, 0.0001), 0.0, 1.0);
		COLOR = vec4(glow_color.rgb, glow_color.a * edge * here * intensity);
	}
}
