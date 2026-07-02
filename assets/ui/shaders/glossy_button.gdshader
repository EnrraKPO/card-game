// Glossy "Bold & Punchy" card-game button — fully procedural, self-contained.
// Ported from design_handoff_glossy_buttons (v8 recipe, the handoff's own numbered checklist —
// see its README "The recipe, as a checklist"): a shoulder ring with a dark socket cut into it,
// and a cap that sits SMALLER + HIGHER than the socket so its own base tone peeks out as a real
// riser band at the bottom — not a brightness gradient standing in for depth — plus a gradient
// outline (the border stroke brightens near corners, dims toward the middle of each flat edge,
// on both the cap and the shoulder) replacing the earlier flat ink line.
shader_type canvas_item;

uniform vec4 base_color : source_color = vec4(0.96, 0.53, 0.11, 1.0); // cap hue
uniform vec4 ink : source_color = vec4(0.11, 0.13, 0.21, 1.0);        // outline #1C2136
uniform vec2 u_size = vec2(160.0, 64.0); // button size in px (set from script)
uniform float radius = 18.0;             // outer shoulder corner radius
uniform float shoulder_inset = 9.0;      // shoulder ring thickness (socket margin)
uniform float riser_strength = 1.0;      // multiplier on how tall the riser peek is
uniform float pressed = 0.0;

float rrect(vec2 p, vec2 b, float r) {
	vec2 q = abs(p) - b + vec2(r);
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
vec3 lift(vec3 c, float a) { return clamp(c + a, 0.0, 1.0); }
vec3 sink(vec3 c, float a) { return clamp(c - a, 0.0, 1.0); }
vec3 desat(vec3 c, float a) {
	float g = dot(c, vec3(0.299, 0.587, 0.114));
	return mix(c, vec3(g), a);
}

void fragment() {
	vec2 P = UV * u_size;
	vec2 p = P - u_size * 0.5; // centered, y-down
	float minSide = min(u_size.x, u_size.y);
	float aaw = max(fwidth(length(p)), 1.0);
	float outlineW = clamp(minSide * 0.022, 2.0, 7.0);

	// ---------- OUTER SHOULDER ----------
	vec2 halfOuter = u_size * 0.5;
	float dOuter = rrect(p, halfOuter, radius);
	vec3 shoulder = desat(base_color.rgb, 0.62);
	shoulder = lift(shoulder, 0.30);
	shoulder = mix(lift(shoulder, 0.08), sink(shoulder, 0.05), UV.y);

	// ---------- SOCKET (the cavity cut into the shoulder) ----------
	vec2 halfHole = halfOuter - vec2(shoulder_inset);
	float rHole = max(radius - shoulder_inset, 2.0);
	float dHole = rrect(p, halfHole, rHole);
	float holeMask = smoothstep(aaw, -aaw, dHole);

	// ---------- CAP: smaller + higher than the socket, so its own base ----------
	// peeks out as a real riser band at the bottom (not a fake gradient).
	float capSideMargin = clamp(minSide * 0.025, 1.5, 5.0);
	float riserGap = clamp(minSide * 0.14, 7.0, 24.0) * riser_strength; // how tall the riser peek is
	vec2 halfCap = vec2(halfHole.x - capSideMargin, (halfHole.y * 2.0 - riserGap - capSideMargin * 2.0) * 0.5);
	float rCap = max(rHole - capSideMargin, 2.0);
	float capCenterYLocal = -halfHole.y + capSideMargin + halfCap.y; // cap sits toward the socket's TOP
	vec2 q = p - vec2(0.0, capCenterYLocal); // cap-local space
	float dCap = rrect(q, halfCap, rCap);
	float capMask = smoothstep(aaw, -aaw, dCap);

	// riser band = socket area not covered by the cap — the cap's own base tone, in shadow
	float riserMask = clamp(holeMask - capMask, 0.0, 1.0);
	vec3 riserTone = sink(base_color.rgb, 0.32);

	// directional distances FROM THE CAP'S OWN EDGES (cap-local space) — every
	// sheen/glint/dimming placement below is relative to the cap, matching the
	// reference art exactly instead of the outer shoulder.
	float fromTop = q.y + halfCap.y;
	float fromLeft = q.x + halfCap.x;
	float fromBottom = halfCap.y - q.y;
	float fromRight = halfCap.x - q.x;

	// candy split shaped to follow the cap's own rounded silhouette (curved at
	// the top corners, flat cut lower down) — not a straight horizontal line
	float lightBandHalfY = halfCap.y * 0.56;
	float dLightBand = rrect(vec2(q.x, q.y - (-halfCap.y + lightBandHalfY)), vec2(halfCap.x, lightBandHalfY), rCap);
	float lightMask = smoothstep(2.0, -2.0, dLightBand);
	vec3 cap = mix(sink(base_color.rgb, 0.24), lift(base_color.rgb, 0.22), lightMask);
	cap = mix(lift(cap, 0.12), sink(cap, 0.12), UV.y);

	float sheenSpan = clamp(minSide * 0.07, 5.0, 34.0);
	float sheenCore = sheenSpan * 0.18;

	// top + left rim sheen
	cap = lift(cap, smoothstep(sheenSpan, sheenCore, fromTop) * 0.5 * (1.0 - pressed));
	cap = lift(cap, smoothstep(sheenSpan, sheenCore, fromLeft) * 0.3 * (1.0 - pressed));
	// crisp bright rim line right on the cap's flat top edge (not the corners)
	float rimLineW = clamp(minSide * 0.012, 1.0, 3.0);
	float onTopFlat = 1.0 - smoothstep(0.0, rimLineW * 2.0, fromTop);
	float notCorner = step(abs(q.x), halfCap.x - rCap);
	cap = lift(cap, onTopFlat * notCorner * 0.55 * (1.0 - pressed));
	// bottom + right rebound (subtler)
	cap = lift(cap, smoothstep(sheenSpan, sheenCore, fromBottom) * 0.16 * (1.0 - pressed));
	cap = lift(cap, smoothstep(sheenSpan, sheenCore, fromRight) * 0.16 * (1.0 - pressed));

	// corner glint sitting right on the curve of the top-left corner
	float cornerOffset = rCap * 0.293;
	float glintR = clamp(minSide * 0.045, 2.0, 10.0);
	vec2 tl = vec2(-halfCap.x, -halfCap.y) + cornerOffset;
	cap = lift(cap, (1.0 - smoothstep(0.0, glintR * 2.2, length(q - tl))) * 0.7 * capMask * (1.0 - pressed));

	// gentle dimming toward the vertical middle on left/right edges, and toward
	// the horizontal middle on the bottom edge
	float vMid = 1.0 - abs(UV.y - 0.5) * 2.0;
	float edgeDim = smoothstep(sheenCore, sheenSpan, min(fromLeft, fromRight)) * vMid * 0.12;
	cap = sink(cap, edgeDim * capMask);
	float hMid = 1.0 - abs(UV.x - 0.5) * 2.0;
	float bottomDim = smoothstep(sheenCore, sheenSpan, fromBottom) * hMid * 0.10;
	cap = sink(cap, bottomDim * capMask);

	// faint concentric inner plane — same rounded shape, inset a few px, ~5% white
	float innerInset = clamp(minSide * 0.045, 3.0, 8.0);
	vec2 halfInnerPlane = halfCap - vec2(innerInset);
	float rInnerPlane = max(rCap - innerInset, 1.0);
	float dInnerPlane = rrect(q, halfInnerPlane, rInnerPlane);
	float innerPlaneMask = smoothstep(aaw, -aaw, dInnerPlane);
	cap = lift(cap, innerPlaneMask * 0.05);

	// ---------- PRESSED: cap sinks flush, riser band disappears ----------
	float bandDepth = clamp(minSide * 0.09, 8.0, 26.0);
	float bandHard = bandDepth * 0.7;
	float topBand = (1.0 - smoothstep(bandHard, bandDepth, fromTop)) * step(fromTop, bandDepth);
	float leftBand = (1.0 - smoothstep(bandHard, bandDepth, fromLeft)) * step(fromLeft, bandDepth);
	float bottomBand = (1.0 - smoothstep(bandHard, bandDepth, fromBottom)) * step(fromBottom, bandDepth) * 0.6;
	float rightBand = (1.0 - smoothstep(bandHard, bandDepth, fromRight)) * step(fromRight, bandDepth) * 0.6;
	float pressShadow = clamp(max(max(topBand, leftBand), max(bottomBand, rightBand)), 0.0, 1.0) * capMask;
	vec3 shadowTone = sink(desat(base_color.rgb, 0.3), 0.28);
	cap = mix(cap, shadowTone, pressShadow * pressed * 0.85);
	cap = mix(cap, sink(cap, 0.12), pressed);
	// when pressed, the cap expands to fill the socket (riser tucks away)
	float pressedCapMask = mix(capMask, holeMask, pressed);

	// thin dark outline around the cap
	cap = mix(cap, ink.rgb, (1.0 - smoothstep(0.0, aaw + outlineW, -dCap)) * 0.9);
	riserTone = mix(riserTone, ink.rgb, (1.0 - smoothstep(0.0, aaw + outlineW * 0.7, -dHole)) * 0.7);

	// gradient outline: the cap's own border brightens near its corners and
	// dims toward the middle of each flat edge — a colored highlight ring,
	// not the flat ink line, replacing it right where it sits
	float capSideGate = 1.0 - smoothstep(0.0, outlineW * 6.0, min(fromLeft, fromRight));
	float capBottomGate = 1.0 - smoothstep(0.0, outlineW * 6.0, fromBottom);
	float capOutlineDim = clamp(max(capSideGate * vMid, capBottomGate * hMid), 0.0, 1.0);
	vec3 capOutlineBright = lift(base_color.rgb, 0.55);
	vec3 capOutlineColor = mix(capOutlineBright, ink.rgb, pow(capOutlineDim, 0.6));
	float capRingMask = clamp(smoothstep(aaw, -aaw, dCap) - smoothstep(aaw, -aaw, dCap + outlineW * 1.6), 0.0, 1.0);
	cap = mix(cap, capOutlineColor, capRingMask * (1.0 - pressed));

	// ---------- COMPOSITE: shoulder -> socket cavity -> riser -> cap ----------
	vec3 col = shoulder;
	float socketDarkMask = holeMask * (1.0 - pressed); // socket cavity color hidden once pressed fills it
	col = mix(col, sink(base_color.rgb, 0.5), socketDarkMask * (1.0 - riserMask));
	col = mix(col, riserTone, riserMask * (1.0 - pressed));
	col = mix(col, cap, pressedCapMask);

	// thin dark outline right at the outer shoulder edge — same gradient
	// treatment: bright near corners, dim toward the middle of each edge
	float outFromLeft = p.x + halfOuter.x;
	float outFromBottom = halfOuter.y - p.y;
	float outSideGate = 1.0 - smoothstep(0.0, outlineW * 6.0, min(outFromLeft, halfOuter.x * 2.0 - outFromLeft));
	float outBottomGate = 1.0 - smoothstep(0.0, outlineW * 6.0, outFromBottom);
	float outOutlineDim = clamp(max(outSideGate * vMid, outBottomGate * hMid), 0.0, 1.0);
	vec3 outOutlineBright = lift(shoulder, 0.55);
	vec3 outOutlineColor = mix(outOutlineBright, ink.rgb, pow(outOutlineDim, 0.6));
	float outerRing = smoothstep(aaw, -aaw, dOuter) - smoothstep(aaw, -aaw, dOuter + outlineW * 1.6);
	col = mix(col, outOutlineColor, clamp(outerRing, 0.0, 1.0));
	// socket's own outline
	float holeRing = smoothstep(aaw, -aaw, dHole) - smoothstep(aaw, -aaw, dHole + outlineW * 1.0);
	col = mix(col, ink.rgb, clamp(holeRing, 0.0, 1.0) * (1.0 - pressed) * (1.0 - capMask));

	float alpha = smoothstep(aaw, -aaw, dOuter);
	COLOR = vec4(col, alpha);
}
