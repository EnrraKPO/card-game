// Outer glow derived from a SOURCE TEXTURE'S ALPHA — a real glow filter, not a halo decal.
// The silhouette in the alpha channel is what radiates: a ring of taps at increasing distance
// is blurred and weighted by a falloff curve, so light spreads out of the shape itself. An
// anvil emits an anvil-shaped glow; a circle emits a circular one. Nothing here is told what
// shape the source is, which is the whole point.
//
// WHY A PADDED QUAD: canvas_item shaders are clipped to their node's rect, so a glow drawn on
// the source can never spill past it. RenderFilterLayer instead sizes ITSELF to
// source + 2*pad and hands us `u_src_rect` — where the source sits inside this bigger quad, in
// our UV space. We remap UV back into the source to sample it, and everything outside that
// sub-rect is the margin the light bleeds into.
//
// COST: the taps are `RINGS * TAPS` per pixel, but each ring samples a coarser mipmap
// (textureLod) the further out it goes — a wide, soft spread costs little more than a tight
// one, and the source's own mip chain does the smoothing that extra taps would otherwise pay
// for. Requires mipmaps/generate=true on the source texture's import.
shader_type canvas_item;

// Sampled explicitly rather than via TEXTURE: the quad is larger than the source, so the
// node's own texture mapping is the wrong space. repeat_disable makes taps that fall outside
// the source clamp to its transparent border instead of wrapping the silhouette back in.
uniform sampler2D src_tex : filter_linear_mipmap, repeat_disable;

uniform vec4 glow_color : source_color = vec4(1.0, 0.65, 0.12, 1.0);
uniform vec2 u_size = vec2(64.0, 64.0);              // this quad's size in px (set from script)
uniform vec4 u_src_rect = vec4(0.0, 0.0, 1.0, 1.0);  // source's sub-rect in our UV: xy = pos, zw = size
uniform float spread = 40.0;      // how far the light reaches past the silhouette, px
uniform float intensity = 1.0;    // brightness multiplier — the handle animation drives
uniform float falloff = 2.0;      // >1 concentrates light near the edge; 1.0 = linear fade

// SOURCE MODE — where the silhouette comes from. 0 = the source texture's alpha (the general
// case). 1 = an ANALYTIC rounded rect, for targets that have no texture to sample: a procedural
// GlossyButton, or a composed card scene. This is not the bounding-box approximation this
// system was built to replace — for a rounded-rect control the analytic shape IS the exact
// silhouette, and being exact it needs no tap-averaging at all: the signed distance gives a
// perfectly smooth falloff for free, cheaper and cleaner than sampling ever is.
uniform int shape_mode = 0;
uniform vec2 u_src_size = vec2(64.0, 64.0);   // the source's size in px (shape mode)
uniform float corner_radius = 18.0;           // the target's REAL corner radius, px (shape mode)

const int RINGS = 3;
const int TAPS = 12;

// Signed distance to a rounded rect, in px: negative inside, positive outside.
float rrect_sd(vec2 p, vec2 half_size, float r) {
	r = min(r, min(half_size.x, half_size.y));
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Distance from this fragment to the analytic silhouette's edge, px.
float shape_distance(vec2 uv) {
	vec2 s = (uv - u_src_rect.xy) / u_src_rect.zw;   // 0..1 across the source
	vec2 p = (s - 0.5) * u_src_size;                 // px, centred on the source
	return rrect_sd(p, u_src_size * 0.5, corner_radius);
}

// Alpha of the source at a UV in OUR space, or 0 outside it. `lod` picks how blurred a mip to
// read — wider rings read coarser levels, which is what keeps a large spread cheap and smooth.
float src_alpha(vec2 uv, float lod) {
	vec2 s = (uv - u_src_rect.xy) / u_src_rect.zw;
	if (s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0) {
		return 0.0;
	}
	return textureLod(src_tex, s, lod).a;
}

void fragment() {
	if (shape_mode == 1) {
		// Exact silhouette -> exact falloff, no sampling. Inside the shape the value saturates,
		// which is occluded anyway since the glow draws behind an opaque target.
		float sd = shape_distance(UV);
		float d = max(sd, 0.0);
		float a = pow(clamp(1.0 - d / max(spread, 0.001), 0.0, 1.0), falloff);
		// Zero INSIDE the silhouette (1px antialiased). Behind an opaque target that costs
		// nothing, and it makes the same filter safe to draw ABOVE one — which matters because
		// clipping/container parents don't always leave the "behind" slot available.
		a *= clamp(sd + 0.5, 0.0, 1.0);
		COLOR = vec4(glow_color.rgb, glow_color.a * clamp(a * intensity, 0.0, 1.0));
	} else {
	float acc = 0.0;
	float wsum = 0.0;

	// Centre tap: full weight, sharpest mip. Behind an opaque source this is occluded, but it
	// matters wherever the source is semi-transparent.
	acc += src_alpha(UV, 0.0);
	wsum += 1.0;

	for (int r = 1; r <= RINGS; r++) {
		float rr = float(r) / float(RINGS);        // 0..1 across the spread
		float dist = spread * rr;                  // this ring's radius, px
		float w = pow(1.0 - rr, falloff);          // outer rings contribute least
		float lod = max(log2(dist * 0.5), 0.0);    // further out = coarser, pre-smoothed mip
		// Stagger each ring's start angle so the taps don't line up into visible spokes.
		float phase = float(r) * 0.7;
		for (int t = 0; t < TAPS; t++) {
			float ang = TAU * float(t) / float(TAPS) + phase;
			vec2 off = vec2(cos(ang), sin(ang)) * dist / u_size;
			acc += src_alpha(UV + off, lod) * w;
			wsum += w;
		}
	}

	float a = clamp(acc / max(wsum, 0.0001) * intensity, 0.0, 1.0);
	// Hollow the interior: an OUTER glow is the blurred halo MINUS the source itself, so where the
	// source is opaque the glow vanishes. Without this the fill only stays hidden when the glow is
	// drawn BEHIND the source; on an overlay (drawn ON TOP) it would wash the whole silhouette —
	// and it is exactly what keeps a composited card glow off the card's own badges/pips.
	a *= 1.0 - src_alpha(UV, 0.0);
	COLOR = vec4(glow_color.rgb, glow_color.a * a);
	}
}
