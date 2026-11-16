// Rain: a text whose letters stand still in columns while light falls down
// each column. Everything follows from the place on the face and the time, so
// both eyes see the same rain and nothing is updated per frame.
// A surface below full opacity uses this code with TRANSLUCENT defined.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

uniform vec3 box_size;                 // metres
uniform float cell_height;             // one letter's line, metres
uniform vec3 lit_colour;               // the surface colour, sRGB
uniform float brightness;              // the surface emission, 0 to 1
uniform float opacity;                 // how dark between the letters, 0 to 1
uniform sampler2D letters : filter_linear, repeat_disable;  // one distance-field slot per letter
uniform int letter_slot;               // atlas pixels per slot
uniform float letter_range;            // distance-field range, in slots
uniform sampler2D cells : filter_nearest, repeat_disable;   // letter index per cell, one or two bytes
uniform int cell_count = 0;            // no text yet: no rain
uniform float rollover = 3600.0;       // when the engine's TIME wraps
uniform float held_time = -1.0;        // at or above zero, the rain stands at that moment

varying vec3 at;
varying vec3 facing;

void vertex() {
	at = VERTEX;
	facing = NORMAL;
}

uint mixed(uint n) {
	n ^= n >> 16u; n *= 0x7feb352du; n ^= n >> 15u; n *= 0x846ca68bu; n ^= n >> 16u;
	return n;
}
float unit(uint n, uint salt) { return float(mixed(n * 0x9e3779b9u + salt) >> 8u) / 16777216.0; }
float middle(vec3 v) { return max(min(v.r, v.g), min(max(v.r, v.g), v.b)); }
vec3 linear(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }

// Rows a fall of light runs at full speed in one second, as in the mockup.
const float FALL = 8.6;

void fragment() {
	vec3 light = vec3(0.0);
	float lit = 0.0;
	vec3 n = normalize(facing);
	// Rain falls along the mark's own up-down axis: a face looking up or down shows none.
	if (cell_count > 0 && abs(n.y) < 0.5) {
		// Letters read left to right from whichever side the face is seen.
		float side = FRONT_FACING ? 1.0 : -1.0;
		vec3 right = cross(-side * n, vec3(0.0, 1.0, 0.0));
		float width = abs(n.x) > 0.5 ? box_size.z : box_size.x;
		vec2 extent = vec2(width, box_size.y) / cell_height;
		vec2 grid = floor(extent + 1e-4);
		vec2 g = vec2(dot(at, right) + 0.5 * width, 0.5 * box_size.y - at.y) / cell_height - 0.5 * (extent - grid);
		if (all(greaterThanEqual(g, vec2(0.0))) && all(lessThan(g, grid))) {
			vec2 c = floor(g);
			vec2 f = g - c;
			uint face = (abs(n.x) > 0.5 ? (n.x > 0.0 ? 0u : 1u) : (n.z > 0.0 ? 2u : 3u)) + (FRONT_FACING ? 4u : 0u);
			uint column = face * 1048576u + uint(c.x);
			// Each column has its own speed, tooth length and start. Its falls per
			// wrap of TIME are whole, so the wrap shows no jump.
			float speed = 0.5 + 0.5 * unit(column, 1u);
			float drop = 20.0 + 12.0 * unit(column, 2u);
			float falls = max(1.0, round(rollover * FALL * speed / drop));
			float t = held_time >= 0.0 ? held_time : TIME;
			float fall = t * (falls / rollover) + unit(column, 3u) * falls - c.y / drop;
			float pass = floor(fall);
			float phase = fall - pass;
			// Each fall brings the column's next stretch of the text; a letter
			// changes only when the light reaches it, out of the dark.
			uint stretch = uint(mod(pass, falls));
			uint start = mixed(column ^ 0x5bd1e995u) % uint(cell_count);
			uint index = (start + uint(c.y) + stretch * uint(grid.y)) % uint(cell_count);
			ivec2 rows = textureSize(cells, 0);
			vec4 code = texelFetch(cells, ivec2(int(index % uint(rows.x)), int(index / uint(rows.x))), 0);
			int letter = int(round(code.r * 255.0)) + 256 * int(round(code.g * 255.0));
			ivec2 atlas = textureSize(letters, 0);
			int across = max(1, atlas.x / letter_slot);
			vec2 uv = (vec2(float(letter % across), float(letter / across)) + f) * float(letter_slot) / vec2(atlas);
			vec4 d = texture(letters, uv);
			// Crisp edges at any size; a soft halo from the true distance.
			// Screen pixels per cell along each axis of the face, from the place on
			// the box: it does not jump where a pixel block spans two faces.
			vec2 across_x = vec2(dot(dFdx(at), right), dFdx(at).y), across_y = vec2(dot(dFdy(at), right), dFdy(at).y);
			vec2 cell_pixels = cell_height / max(abs(across_x) + abs(across_y), vec2(1e-9));
			float per_cell = min(cell_pixels.x, cell_pixels.y);
			float shape = clamp((middle(d.rgb) - 0.5) * letter_range * max(0.5 * (cell_pixels.x + cell_pixels.y), 1.0) + 0.5, 0.0, 1.0);
			float halo = 0.4 * pow(smoothstep(0.25, 0.5, d.a), 2.0);
			// Far away a letter melts into a soft streak of the same brightness.
			float streak = mix(0.3, 0.6 * (1.0 - abs(f.x - 0.5) * 2.0), smoothstep(1.0, 2.5, per_cell));
			lit = mix(streak, max(shape, halo), smoothstep(3.0, 8.0, per_cell));
			float behind = phase * drop;
			if (behind < 1.0) {
				float white = 1.0 - clamp((behind - 0.5) * 2.0, 0.0, 1.0);
				light = linear(mix(lit_colour, vec3(0.9, 1.0, 0.91), 0.85 * white)) * (1.0 + 0.6 * white);
			} else {
				float b = 1.0 - phase;
				b *= sqrt(b);
				vec3 deep = lit_colour * vec3(0.0, 0.23, 0.16), mid = lit_colour * vec3(0.0, 0.69, 0.52);
				vec3 trail = b < 0.22 ? mix(vec3(0.0), deep, b / 0.22)
					: b < 0.62 ? mix(deep, mid, (b - 0.22) / 0.4) : mix(mid, lit_colour, (b - 0.62) / 0.38);
				light = linear(trail);
				lit *= step(0.002, b);
			}
		}
	}
	ALBEDO = light * lit * brightness;
#ifdef TRANSLUCENT
	ALPHA = max(opacity, clamp(lit * max(light.g, max(light.r, light.b)), 0.0, 1.0));
#endif
}
