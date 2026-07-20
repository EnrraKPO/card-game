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
uniform float luma_bias = 0.7;    // 0 = flat lift over the whole shape, 1 = follow the art's own brightness

void fragment() {
	vec2 s = (UV - u_src_rect.xy) / u_src_rect.zw;
	if (s.x < 0.0 || s.x > 1.0 || s.y < 0.0 || s.y > 1.0) {
		COLOR = vec4(0.0);
	} else {
		vec4 src = texture(src_tex, s);
		float luma = dot(src.rgb, vec3(0.299, 0.587, 0.114));
		float lift = mix(1.0, luma, luma_bias);
		// src.a masks it to the silhouette, so the light stops exactly where the object does.
		COLOR = vec4(glow_color.rgb, glow_color.a * src.a * lift * intensity);
	}
}
