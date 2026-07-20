// Luminescence — the WHOLE silhouette lit from within, as if the thing itself were the light
// source. Distinct from filter_inner_glow, which derives light from the silhouette's EDGE and
// therefore only ever lights a rim: this lights every pixel the source covers.
//
// The catch with a whole-body lift is that a flat one reads as a coloured sticker laid over the
// art — it erases the very shading that makes the object look like an object. So the light is
// weighted by the source's OWN luminance (`luma_bias`): highlights take more of it, shadowed
// areas keep their darkness, and the form survives. luma_bias 0 is the flat lift, 1 follows the
// art completely; between them the material reads as glowing rather than repainted.
//
// ADDITIVE for the same reason as the inner glow: alpha-blending a colour over the art tints
// it, and a tint at subtle strength is invisible rather than understated.
shader_type canvas_item;
render_mode blend_add;

uniform sampler2D src_tex : filter_linear, repeat_disable;

uniform vec4 glow_color : source_color = vec4(1.0, 0.77, 0.42, 1.0);
uniform vec4 u_src_rect = vec4(0.0, 0.0, 1.0, 1.0);  // source's sub-rect in our UV
uniform float intensity = 0.35;   // overall strength — the handle animation drives
// How much the light FOLLOWS the object instead of lying flat on it. The available signal
// differs by source mode: with a texture it is the art's own brightness; with an analytic
// shape there are no pixels to read, so it is inward depth (dim at the rim, full in the body).
// Same intent either way — a dead-flat lift reads as a coloured sticker, not as light.
uniform float luma_bias = 0.7;

// SOURCE MODE — see filter_glow.gdshader. 0 = the source texture's alpha, 1 = an analytic
// rounded rect, for targets with no texture to sample (a procedural button, a composed card).
uniform int shape_mode = 0;
uniform vec2 u_src_size = vec2(64.0, 64.0);
uniform float corner_radius = 18.0;

float rrect_sd(vec2 p, vec2 half_size, float r) {
	r = min(r, min(half_size.x, half_size.y));
	vec2 q = abs(p) - half_size + vec2(r);
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

void fragment() {
	vec2 s = (UV - u_src_rect.xy) / u_src_rect.zw;
	if (s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0) {
		COLOR = vec4(0.0);
	} else if (shape_mode == 1) {
		vec2 p = (s - 0.5) * u_src_size;
		float d = rrect_sd(p, u_src_size * 0.5, corner_radius);
		float cover = clamp(0.5 - d, 0.0, 1.0);   // antialiased 1px edge
		// Normalised over a quarter of the short side: the light reaches full strength a little
		// way in rather than only at the dead centre, which on a wide button would be a hotspot.
		float depth = clamp(-d / max(min(u_src_size.x, u_src_size.y) * 0.25, 1.0), 0.0, 1.0);
		float lift = mix(1.0, depth, luma_bias);
		COLOR = vec4(glow_color.rgb, glow_color.a * cover * lift * intensity);
	} else {
		vec4 src = texture(src_tex, s);
		float luma = dot(src.rgb, vec3(0.299, 0.587, 0.114));
		float lift = mix(1.0, luma, luma_bias);
		// src.a masks it to the silhouette, so the light stops exactly where the object does.
		COLOR = vec4(glow_color.rgb, glow_color.a * src.a * lift * intensity);
	}
}
