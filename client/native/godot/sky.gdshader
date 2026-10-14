shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never;
uniform vec4 colour : source_color = vec4(1.0);
uniform bool has_base = false;
uniform sampler2D base_map : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 base_repeat = vec2(1.0);
void fragment() { ALBEDO = colour.rgb * (has_base ? texture(base_map, UV * base_repeat).rgb : vec3(1.0)); }
