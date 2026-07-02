// Recolors button_shademap_*.png by base_color: values below 0.5 multiply-darken (so the
// shademap's near-black ink outline stays near-black regardless of hue — there's no separate
// ink uniform, the outline color is implicit in how dark the shademap's darkest pixels are),
// values above 0.5 screen-lighten toward white. From design_handoff_glossy_buttons's Option A
// (nine-patch) — this is the whole recolor step; all the button's actual geometry (shoulder,
// socket, riser, candy split, sheen, glint, gradient outline) is baked into the shademap texture.
shader_type canvas_item;

uniform vec4 base_color : source_color = vec4(0.96, 0.53, 0.11, 1.0);

void fragment() {
	vec4 tex = texture(TEXTURE, UV);
	float shade = tex.r;
	vec3 col;
	if (shade < 0.5) {
		col = base_color.rgb * (shade * 2.0);
	} else {
		float t = (shade - 0.5) * 2.0;
		col = base_color.rgb + (vec3(1.0) - base_color.rgb) * t;
	}
	COLOR = vec4(col, tex.a);
}
