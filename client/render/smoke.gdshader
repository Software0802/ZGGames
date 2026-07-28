shader_type spatial;
render_mode unshaded, depth_draw_never, cull_disabled, blend_mix;

// 炊烟：毡房天窗上的一缕烟。公告板 quad（绕 Y 柱面朝向相机，保持烟柱竖直），
// 用与地形同一张梯度表拉两层滚动噪声，成本约等于零。
// 相位按世界坐标错开，三座毡房共用一份材质也不会同步冒烟。

uniform sampler2D grad_lut : filter_nearest, repeat_disable;
uniform vec3 smoke_color : source_color = vec3(0.93, 0.91, 0.87);
uniform float scroll_speed = 0.22;
uniform float opacity = 0.42;

// 值噪声：梯度表的 r 通道当随机数用（同一份字节，见 terrain_height.gd）
float smoke_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	ivec2 ii = ivec2(i) & ivec2(255);
	float a = texelFetch(grad_lut, (ii + ivec2(0, 0)) & ivec2(255), 0).r;
	float b = texelFetch(grad_lut, (ii + ivec2(1, 0)) & ivec2(255), 0).r;
	float c = texelFetch(grad_lut, (ii + ivec2(0, 1)) & ivec2(255), 0).r;
	float d = texelFetch(grad_lut, (ii + ivec2(1, 1)) & ivec2(255), 0).r;
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}


void vertex() {
	// 绕 Y 的柱面公告板：右向量朝向相机，up 保持世界竖直
	vec3 to_cam = normalize(CAMERA_POSITION_WORLD - NODE_POSITION_WORLD);
	vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), to_cam));
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(right, 0.0),
		vec4(0.0, 1.0, 0.0, 0.0),
		vec4(cross(right, vec3(0.0, 1.0, 0.0)), 0.0),
		vec4(NODE_POSITION_WORLD, 1.0));
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
}


void fragment() {
	// UV：PlaneMesh 的 (0,0) 在左上。烟从底部（uv.y=1）升起，到顶部散开。
	float phase = NODE_POSITION_WORLD.x * 0.37 + NODE_POSITION_WORLD.z * 0.21;
	float t = TIME * scroll_speed;
	vec2 p = vec2(UV.x * 2.2 + phase, UV.y * 3.2 + t);
	float n = smoke_noise(p) * 0.65 + smoke_noise(p * 2.13 + 5.7) * 0.35;
	// 底部浓、顶部散；左右软边；随高度略收窄前的摆动
	float sway = sin(UV.y * 4.0 + t * 2.0 + phase) * 0.08 * UV.y;
	float a = n * pow(UV.y, 1.35);
	a *= smoothstep(0.0, 0.28, UV.x + sway) * smoothstep(1.0, 0.72, UV.x + sway);
	ALPHA = clamp(a * 1.35 - 0.22, 0.0, 1.0) * opacity;
	ALBEDO = smoke_color;
}
