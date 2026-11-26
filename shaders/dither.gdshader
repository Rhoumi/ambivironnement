shader_type canvas_item;
// Ordered (Bayer 4x4) dithering onto the current theme palette (see palette.gd):
// greys -> 4-level ramp (bg / g1 / g2 / fg), and three content colours chosen by
// the dominant channel of saturated scene pixels: red -> c_r, green -> c_g, blue -> c_b.
// aspect = 2 -> double-wide pixels (C64 multicolour). ruled > 0 -> paper lines every
// `ruled` pixels drawn on the background (DS PictoChat).

uniform vec4 c_bg : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec4 c_g1 : source_color = vec4(0.471, 0.471, 0.471, 1.0);
uniform vec4 c_g2 : source_color = vec4(0.706, 0.706, 0.706, 1.0);
uniform vec4 c_fg : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform vec4 c_r : source_color = vec4(0.314, 0.902, 0.902, 1.0);
uniform vec4 c_g : source_color = vec4(1.0, 0.627, 0.235, 1.0);
uniform vec4 c_b : source_color = vec4(0.784, 0.471, 1.0, 1.0);
uniform vec4 c_line : source_color = vec4(0.7, 0.7, 0.8, 1.0);
uniform float aspect = 1.0;
uniform float ruled = 0.0;
uniform float sat_threshold = 0.22;
uniform float contrast = 1.1;

const float BAYER[16] = float[](
	0.0, 8.0, 2.0, 10.0,
	12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0,
	15.0, 7.0, 13.0, 5.0);

void fragment() {
	vec2 px = floor(UV / TEXTURE_PIXEL_SIZE);
	px.x = floor(px.x / aspect);
	vec2 uv = vec2((px.x + 0.5) * aspect, px.y + 0.5) * TEXTURE_PIXEL_SIZE;
	int idx = int(mod(px.x, 4.0)) + int(mod(px.y, 4.0)) * 4;
	float t = (BAYER[idx] + 0.5) / 16.0;
	vec3 c = texture(TEXTURE, uv).rgb;
	vec3 paper = (ruled > 0.5 && mod(px.y + 0.5, ruled) < 1.0) ? c_line.rgb : c_bg.rgb;
	float mx = max(c.r, max(c.g, c.b));
	float mn = min(c.r, min(c.g, c.b));
	if (mx - mn > sat_threshold) {
		vec3 acc = (c.r >= c.g && c.r >= c.b) ? c_r.rgb : ((c.g >= c.b) ? c_g.rgb : c_b.rgb);
		float v = clamp(mx * contrast, 0.0, 1.0);
		COLOR = vec4(v > t ? acc : paper, 1.0);
	} else {
		float lum = clamp(dot(c, vec3(0.299, 0.587, 0.114)) * contrast, 0.0, 1.0) * 3.0;
		float base = floor(lum);
		float level = base + ((lum - base) > t ? 1.0 : 0.0);
		vec3 o = level < 0.5 ? paper : (level < 1.5 ? c_g1.rgb : (level < 2.5 ? c_g2.rgb : c_fg.rgb));
		COLOR = vec4(o, 1.0);
	}
}
