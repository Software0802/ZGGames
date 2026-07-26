shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled;

// S0 的「动漫写实」验证滤镜（新海诚式：真实地理与轮廓 + 动画质感光影）。
//
// 目的不是做最终美术，而是给 v002 第 59-62 行那个美术假设一个可看的对比组：
// 照片动漫化的角色走在完全写实的世界里是否违和，动漫化处理能否顺带掩盖
// 摄影测量的纹理瑕疵与瓦片接缝。因此只做三件影响观感判断的事：
//   1. 空气透视 + 提饱和 —— 动画片的天空与远山比实拍更浓、更蓝
//   2. 亮度色阶分离 —— 让光影出现「面」而不是连续渐变，卡通感的来源
//   3. 深度描边 —— 给地物轮廓加线
//
// 写成 spatial 而不是 canvas_item：canvas_item 拿不到 hint_depth_texture，
// 也没有 INV_PROJECTION_MATRIX，描边与空气透视都做不了。
// 用法是挂在相机下的一张 QuadMesh(2,2)，vertex 里直接把顶点写成 NDC 全屏。

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;

uniform float saturation : hint_range(1.0, 2.0) = 1.35;
uniform float contrast : hint_range(0.5, 2.0) = 1.08;
uniform float lift : hint_range(0.0, 0.2) = 0.03;      // 抬黑，动画里阴影很少纯黑
uniform int levels : hint_range(2, 16) = 8;            // 亮度色阶数
uniform float posterize_mix : hint_range(0.0, 1.0) = 0.55;
uniform float outline_strength : hint_range(0.0, 1.0) = 0.7;
uniform float outline_threshold : hint_range(0.0001, 0.05) = 0.006;
uniform vec3 outline_color : source_color = vec3(0.06, 0.08, 0.10);
uniform vec3 haze_color : source_color = vec3(0.62, 0.74, 0.88);
uniform float haze_strength : hint_range(0.0, 1.0) = 0.40;
uniform float haze_range = 14000.0;

varying flat mat4 inv_proj;

// 深度缓冲非线性（且 Godot 4 是 reverse-Z），直接做差在远处没有区分度，先还原成线性深度。
float linear_depth(vec2 uv) {
	float d = texture(depth_tex, uv).r;
	vec4 view = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	view.xyz /= view.w;
	return -view.z;
}

void vertex() {
	inv_proj = INV_PROJECTION_MATRIX;
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;
	float dpt = linear_depth(SCREEN_UV);

	// --- 空气透视：远处按线性深度往天空色靠 ---
	float fog_t = pow(clamp(dpt / haze_range, 0.0, 1.0), 0.65);
	col = mix(col, haze_color, fog_t * haze_strength);

	// --- 饱和度与对比 ---
	float luma = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(luma), col, saturation);
	col = (col - 0.5) * contrast + 0.5;
	col = col * (1.0 - lift) + lift;

	// --- 亮度色阶分离：只量化亮度，保留原色相，否则实景的色彩关系会碎成色块 ---
	float l = max(dot(col, vec3(0.2126, 0.7152, 0.0722)), 0.0001);
	float steps = float(levels);
	float lq = floor(l * steps + 0.5) / steps;
	col = mix(col, col * (lq / l), posterize_mix);

	// --- 深度描边：四邻域线性深度差超阈值就上线 ---
	vec2 px = 1.0 / VIEWPORT_SIZE;
	float dl = linear_depth(SCREEN_UV + vec2(-px.x, 0.0));
	float dr = linear_depth(SCREEN_UV + vec2(px.x, 0.0));
	float du = linear_depth(SCREEN_UV + vec2(0.0, -px.y));
	float dd = linear_depth(SCREEN_UV + vec2(0.0, px.y));
	// 阈值随深度放大：远处同样的绝对差属于正常透视压缩，不该出线。
	float tol = outline_threshold * max(dpt, 1.0);
	float diff = abs(dl - dpt) + abs(dr - dpt) + abs(du - dpt) + abs(dd - dpt);
	col = mix(col, outline_color, step(tol, diff) * outline_strength);

	ALBEDO = clamp(col, vec3(0.0), vec3(1.0));
}
