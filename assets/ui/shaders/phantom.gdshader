shader_type canvas_item;

// Phantom: the "this card isn't real" colour transform, applied to a canvas item's OWN pixels.
//
// This is a transform of existing RGB, not a veil laid over it — lower the saturation, raise the
// brightness, tilt the hue cool. Because each pixel's alpha is passed through untouched, the
// transform reaches exactly the pixels the item actually draws: a transparent pixel has no colour
// to transform, so it stays transparent no matter what RGB is written into it. There is no mask,
// no silhouette and no bounding shape to get wrong — including for parts that overhang whatever
// rect their owner occupies.
//
// Meant to be hung on a whole widget subtree (material on the root, use_parent_material on the
// descendants), so frame, art, badges, glyphs and pips all transform together.

// 1.0 = untouched, 0.0 = fully grey. Mixes each pixel toward its own luminance.
uniform float saturation : hint_range(0.0, 1.0) = 0.45;
// Brightness, as a mix toward white rather than a multiply. A multiply can never lift a black
// pixel and blows the brights out to a clipped, detail-free white; a mix raises everything and
// still lands inside the gamut. Note it has to out-run the desaturation above, which LOWERS
// brightness on its own (a pixel mixed toward its luma loses the peak channel that defined it).
uniform float lighten : hint_range(0.0, 1.0) = 0.38;
// The hue tilt, applied last and multiplicatively so it biases the card cool without disturbing
// the brightness ordering the step above just established.
uniform vec3 tint : source_color = vec3(0.93, 0.98, 1.08);

// Rec. 709 luma — the perceptual grey a pixel desaturates toward.
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

void fragment() {
	// COLOR arrives as the item's modulate; TEXTURE is a 1x1 white for untextured draws
	// (StyleBoxes, ColorRects), so this one line covers textured and flat items alike.
	vec4 src = texture(TEXTURE, UV) * COLOR;
	vec3 rgb = mix(vec3(dot(src.rgb, LUMA)), src.rgb, saturation);
	rgb = mix(rgb, vec3(1.0), lighten);
	COLOR = vec4(clamp(rgb * tint, vec3(0.0), vec3(1.0)), src.a);
}
