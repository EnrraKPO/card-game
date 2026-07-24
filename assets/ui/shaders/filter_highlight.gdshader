// The SELECTION HIGHLIGHT treatment: a thick solid outline hugging a silhouette, wrapped in a
// dense outer glow — both derived from the source texture's alpha (the composited silhouette a
// SilhouetteBaker provides), so they follow the widget's true shape: card corners, overhanging
// badges, a charm chip's circle. Companion to filter_glow.gdshader (same padded-quad contract,
// same mip-tap economics); texture mode only — the highlight always rides the composited path.
//
// Anatomy, inside-out:
//   silhouette (transparent here — the widget draws itself)
//   → OUTLINE: a hard ring `outline_width` px thick (the silhouette dilated, minus itself)
//   → GLOW: light reaching `glow_span` px past the outline, `glow_spread` shaping its density
//     (higher = hugging the outline denser; lower = spread thinner across the span)
shader_type canvas_item;

uniform sampler2D src_tex : filter_linear_mipmap, repeat_disable;

uniform vec2 u_size = vec2(64.0, 64.0);              // this quad's size in px (set from script)
uniform vec4 u_src_rect = vec4(0.0, 0.0, 1.0, 1.0);  // source's sub-rect in our UV: xy = pos, zw = size

uniform vec4 outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float outline_width = 6.0;   // ring thickness, px
uniform vec4 glow_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float glow_span = 30.0;      // how far the glow reaches past the outline, px
uniform float glow_spread = 2.0;     // density curve: >1 packs light near the outline, 1 = linear
uniform float intensity = 1.0;       // glow brightness (the animate handle); outline stays solid

const int RINGS = 3;
const int TAPS = 12;

// Alpha of the source at a UV in OUR space, or 0 outside it (see filter_glow for the remap).
float src_alpha(vec2 uv, float lod) {
	vec2 s = (uv - u_src_rect.xy) / u_src_rect.zw;
	if (s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0) {
		return 0.0;
	}
	return textureLod(src_tex, s, lod).a;
}

// The silhouette DILATED by `radius` px: the max alpha found on rings out to that distance.
// Max (not average) keeps the edge HARD — this is what makes the outline a band, not a blur.
float dilated(vec2 uv, float radius) {
	float m = src_alpha(uv, 0.0);
	for (int r = 1; r <= RINGS; r++) {
		float dist = radius * float(r) / float(RINGS);
		float phase = float(r) * 0.7;   // stagger so taps don't align into spokes
		for (int t = 0; t < TAPS; t++) {
			float ang = TAU * float(t) / float(TAPS) + phase;
			vec2 off = vec2(cos(ang), sin(ang)) * dist / u_size;
			m = max(m, src_alpha(uv + off, 0.0));
		}
	}
	return m;
}

void fragment() {
	float a_src = src_alpha(UV, 0.0);

	// OUTLINE: dilated silhouette minus the silhouette itself = a ring outside the shape.
	// The smoothstep is a ~1px antialias on the dilation's mip-filtered edge, not a fade.
	float band = dilated(UV, max(outline_width, 0.001));
	float outline_a = smoothstep(0.35, 0.65, band) * (1.0 - a_src) * outline_color.a;

	// GLOW: filter_glow's ring taps, reaching outline_width + glow_span so the light starts at
	// the OUTLINE's outer edge (it's masked off the band below). Coarser mips further out.
	float total = max(outline_width, 0.0) + max(glow_span, 0.001);
	float acc = src_alpha(UV, 0.0);
	float wsum = 1.0;
	for (int r = 1; r <= RINGS; r++) {
		float rr = float(r) / float(RINGS);
		float dist = total * rr;
		float w = pow(1.0 - rr, glow_spread);
		float lod = max(log2(dist * 0.5), 0.0);
		float phase = float(r) * 0.7;
		for (int t = 0; t < TAPS; t++) {
			float ang = TAU * float(t) / float(TAPS) + phase;
			vec2 off = vec2(cos(ang), sin(ang)) * dist / u_size;
			acc += src_alpha(UV + off, lod) * w;
			wsum += w;
		}
	}
	float glow_a = clamp(acc / max(wsum, 0.0001) * intensity, 0.0, 1.0);
	// Hollow: no glow over the silhouette (badges/pips stay uncovered) or over the outline band.
	glow_a *= (1.0 - a_src) * (1.0 - outline_a);
	glow_a *= glow_color.a;

	// Outline over glow. Un-premultiplied compose for the canvas item's standard alpha blend.
	float a = outline_a + glow_a * (1.0 - outline_a);
	vec3 rgb = outline_color.rgb * outline_a + glow_color.rgb * glow_a * (1.0 - outline_a);
	COLOR = vec4(rgb / max(a, 0.0001), a);
}
