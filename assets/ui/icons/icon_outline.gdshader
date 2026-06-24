shader_type canvas_item;

// Adds a solid outline/halo around a flat silhouette texture, derived from its alpha.
// Lets the black composition-chip icons pop on saturated chip colours without recolouring
// them. `width` is in UV fraction (resolution-independent, so 512px element icons and 256px
// piece icons get a matching on-screen rim). Disable texture repeat on the node so edge
// samples clamp to the transparent margin instead of wrapping.
uniform vec4 outline_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float width : hint_range(0.0, 0.2) = 0.05;

void fragment() {
	vec4 col = texture(TEXTURE, UV);
	float d = width * 0.70711;   // diagonal step, kept equal-length to the axis steps
	float a = 0.0;
	a = max(a, texture(TEXTURE, UV + vec2( width, 0.0)).a);
	a = max(a, texture(TEXTURE, UV + vec2(-width, 0.0)).a);
	a = max(a, texture(TEXTURE, UV + vec2(0.0,  width)).a);
	a = max(a, texture(TEXTURE, UV + vec2(0.0, -width)).a);
	a = max(a, texture(TEXTURE, UV + vec2( d,  d)).a);
	a = max(a, texture(TEXTURE, UV + vec2( d, -d)).a);
	a = max(a, texture(TEXTURE, UV + vec2(-d,  d)).a);
	a = max(a, texture(TEXTURE, UV + vec2(-d, -d)).a);

	vec4 rim = vec4(outline_color.rgb, outline_color.a * a);
	// Draw the rim where the icon itself is transparent; the icon sits on top of it.
	COLOR = mix(rim, col, col.a);
}
