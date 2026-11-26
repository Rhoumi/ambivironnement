shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;
// Acoustic intensity "balloon": every vertex sits on a unit sphere and is pushed
// outwards by the decoded field intensity interpolated from 64 measured directions.

uniform vec3 dirs[64];
uniform float inten[64];
uniform float base_r = 0.12;
uniform float gain_r = 0.9;
uniform float sharp = 14.0;
uniform float brightness = 1.0;
uniform float hot = 0.75;   // intensity above which the accent colour bleeds in

varying float v_i;

void vertex() {
	vec3 n = normalize(VERTEX);
	float acc = 0.0;
	float ws = 0.0;
	for (int i = 0; i < 64; i++) {
		float d = max(dot(n, dirs[i]), 0.0);
		float w = pow(d, sharp);
		acc += w * inten[i];
		ws += w;
	}
	float I = acc / max(ws, 1e-5);
	v_i = I;
	VERTEX = n * (base_r + gain_r * I);
}

void fragment() {
	float b = clamp(0.12 + v_i * 1.1, 0.0, 1.0) * brightness;
	vec3 col = vec3(b);
	float h = smoothstep(hot, 1.0, v_i);
	col = mix(col, vec3(b, 0.05, 0.03), h);
	ALBEDO = col;
}
