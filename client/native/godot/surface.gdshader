shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;
uniform vec4 colour : source_color = vec4(1.0);
uniform float metal = 0.0;
uniform float rough = 0.9;
uniform float emission = 0.0;
uniform bool has_base = false;
uniform bool has_normal = false;
uniform bool has_orm = false;
uniform sampler2D base_map : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D normal_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D orm_map : filter_linear_mipmap, repeat_enable;
uniform vec2 base_repeat = vec2(1.0);
uniform vec2 normal_repeat = vec2(1.0);
uniform vec2 orm_repeat = vec2(1.0);
void fragment() {
    ALBEDO = colour.rgb * (has_base ? texture(base_map, UV * base_repeat).rgb : vec3(1.0));
    METALLIC = metal;
    ROUGHNESS = rough;
    EMISSION = colour.rgb * emission;
    if (has_normal) { NORMAL_MAP = texture(normal_map, UV * normal_repeat).rgb; }
    if (has_orm) {
        vec3 orm = texture(orm_map, UV * orm_repeat).rgb;
        AO = orm.r; ROUGHNESS *= orm.g; METALLIC *= orm.b;
    }
}
