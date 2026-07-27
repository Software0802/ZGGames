shader_type spatial;
render_mode cull_disabled, specular_disabled, depth_draw_opaque;

// 草地。十字双面片 + 顶点渐窄，按高度加权摆动 —— 结构照搬 three.js 原型
// （交接文档 §07 明确说这套参数可直接搬走）。
//
// 关键设计：草叶的**落地高度在着色器里算**，复用地形那套 ts_surface_height。
// 好处有两个：
//   1. CPU 完全不参与，玩家移动时只需要把整块 MultiMesh 吸附到新位置，
//      不用重算几万个实例的高度；
//   2. 草和地形用的是同一个高度函数，绝不会出现草浮空或陷进地里。
//
// 实例的 y 一律为 0，真实高度由本着色器加上去。

#include "res://client/render/terrain_sample.gdshaderinc"

/// 草色。色相全由这里控制 —— 换季一行代码把整片草原染白（交接文档 §07）。
uniform vec3 grass_color : source_color = vec3(0.16, 0.36, 0.06);
/// 叶尖偏黄，根部偏深，纯靠顶点高度插值，不需要贴图。
uniform vec3 tip_color : source_color = vec3(0.30, 0.45, 0.09);
uniform vec3 root_color : source_color = vec3(0.06, 0.14, 0.04);

uniform float wind_time = 0.0;
uniform float wind_strength = 0.16;
uniform float wind_freq = 1.9;

/// 草长的条件。牧场看得见的「草深过膝」就靠 height_scale 拉高。
uniform float height_scale = 1.0;
uniform float slope_min = 0.62;   ///< 坡度余弦低于此值不长草（陡坡是碎石）
uniform float slope_max = 0.82;
uniform float alt_min = 400.0;    ///< 低于此高度是戈壁
uniform float alt_max = 3100.0;   ///< 高于此高度是流石滩与雪线
uniform float alt_blend = 260.0;
/// 成片的疏密变化。真实草场不是均匀的，靠低频噪声开洞。
uniform float patch_freq = 0.006;
uniform float patch_bias = 0.18;

/// 超过这个距离草完全消失（改由地形基色顶替）。
uniform float fade_dist = 220.0;
uniform float fade_band = 60.0;

uniform sampler2D ramp : filter_nearest, repeat_disable;
uniform float wrap_factor = 0.45;

/// 诊断模式。0 正常。诊断模式一律**强制 ok = 1**（无条件长草）并把光照置平，
/// 这样「画面上有没有草」与「草为什么不长」是两个能分开问的问题。
///   1 无条件长草（正常配色）—— 区分「条件把草掐掉了」和「几何/落地有问题」
///   2 ALBEDO = 真实 ok  —— 直接读出生长条件的值，全黑就是条件把草掐掉了
///   3 ALBEDO 按落地高度分带（每 500 m 换色）—— 看草落在哪个海拔
///   4 纯品红 —— 只问「几何到底在不在画面上」
uniform int debug_mode = 0;

varying vec3 v_normal;
varying float v_up;      ///< 顶点在草叶上的相对高度 0..1
varying float v_shade;   ///< 每株的明度扰动
varying float v_ok;      ///< 诊断用：真实的生长条件系数
varying float v_gh;      ///< 诊断用：这株草的落地高度（米）


void vertex() {
	// MultiMesh 的实例变换已经乘进 MODEL_MATRIX，第四列就是这株草的根部世界坐标。
	vec3 root = MODEL_MATRIX[3].xyz;

	// 【必须是水平距离】不能写 length(root - CAMERA_POSITION_WORLD)：
	// root.y 恒为 0（真实高度是下面才加上去的），而相机的 y 是海拔。
	// 那样算出来的 dist 在那拉提恒 ≥ 2231 m，远超 fade_dist=220，
	// 每一株草都被淡出成零面积 —— 全疆一株草都不显示。详见 ts_plan_dist 的说明。
	float plan_dist = ts_plan_dist(root.xz, CAMERA_POSITION_WORLD);

	// plan_dist 必须原样传给 ts_surface_height：地形传的是同一个值，
	// 两边算出的高度才会完全一致（否则草浮空或陷进地里）。
	float gh = ts_surface_height(root.xz, plan_dist);
	vec3 n = ts_dem_normal(root.xz, 30.0);

	// 落地高度出来之后，才算得出真正的「离相机多远」。它只用于淡出与着色，
	// 绝不能回头喂给 ts_surface_height。
	float view_dist = length(vec3(root.x, gh, root.z) - CAMERA_POSITION_WORLD);

	// ── 能不能长草 ──
	float ok = smoothstep(slope_min, slope_max, n.y);
	ok *= smoothstep(alt_min - alt_blend, alt_min + alt_blend, gh);
	ok *= 1.0 - smoothstep(alt_max - alt_blend, alt_max + alt_blend, gh);
	// 成片疏密：噪声低于阈值的地方直接秃掉
	ok *= smoothstep(patch_bias - 0.25, patch_bias + 0.35, ts_fbm3(root.xz * patch_freq) + 0.5);
	// 远处淡出
	ok *= 1.0 - smoothstep(fade_dist - fade_band, fade_dist, view_dist);

	v_ok = ok;
	v_gh = gh;
	if (debug_mode > 0) {
		ok = 1.0;
	}

	// 每株的随机相位与高矮，用根部坐标做种子 —— 同一株在任何一帧、任何一台
	// 机器上都算出同样的值，不需要往实例里塞额外数据。
	vec2 seed = ts_hash2(floor(root.xz * 7.31));
	float phase = (seed.x + 1.0) * 3.14159;
	float vary = 0.72 + (seed.y + 1.0) * 0.34;

	// 用 UV.y 而不是 VERTEX.y / 0.5：两圈草的叶高不同（近圈 0.55 m、远圈 1.05 m），
	// 除以写死的 0.5 会让远圈有一半叶片的 v_up 都被 clamp 到 1 —— 整片远草
	// 全是 tip_color，根深叶浅的层次只在近圈成立。UV.y 建网格时就是归一化高度。
	v_up = UV.y;
	v_shade = 0.86 + (seed.x + 1.0) * 0.14;

	// 缩到 0 就等于剔除掉这一株（顶点全部退化到一点，光栅化直接丢弃）
	vec3 local = VERTEX * vec3(vary, vary * height_scale * ok, vary);

	// ── 风 ──
	// 按顶点高度加权：根部不动，叶尖摆幅最大。两个频率叠加，避免整片同步摆动。
	float sway = sin(wind_time * wind_freq + phase) * 0.72
		+ sin(wind_time * wind_freq * 0.41 + phase * 0.3) * 0.28;
	float w = sway * wind_strength * v_up * v_up * local.y;
	local.x += w;
	local.z += w * 0.55;

	vec3 world = (MODEL_MATRIX * vec4(local, 1.0)).xyz;
	world.y += gh;

	// 草叶法线取「地面法线与竖直方向的混合」：真按片面法线算会让每片叶子
	// 明暗跳动，成片看过去像噪点。卡通草要的是整体块面感。
	v_normal = normalize(mix(n, vec3(0.0, 1.0, 0.0), 0.55));

	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
}


void fragment() {
	vec3 c = mix(root_color, grass_color, smoothstep(0.0, 0.45, v_up));
	c = mix(c, tip_color, smoothstep(0.55, 1.0, v_up));
	c *= v_shade;

	if (debug_mode == 2) {
		c = vec3(v_ok);
	} else if (debug_mode == 3) {
		// 每 500 m 换一次色。草若落在海平面（高程纹理没送到）就是最底那一档，
		// 与地形的颜色对不上，一眼能看出来。
		float band = fract(v_gh / 500.0);
		c = mix(vec3(0.10, 0.10, 0.45), vec3(0.95, 0.85, 0.25), band);
	} else if (debug_mode == 4) {
		c = vec3(1.0, 0.0, 1.0);
	}
	ALBEDO = c;
	NORMAL = (VIEW_MATRIX * vec4(v_normal, 0.0)).xyz;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}


void light() {
	float ndl = dot(normalize(NORMAL), normalize(LIGHT));
	float t = clamp((ndl + wrap_factor) / (1.0 + wrap_factor), 0.0, 1.0);
	float k = texture(ramp, vec2(t, 0.5)).r;
	// 根部压暗一档，让草丛底部有厚度感，而不是一片平的绿
	k *= mix(0.82, 1.0, v_up);
	// 【不要在 light() 里写 return】Godot 明令禁止，那不是警告而是编译错误，
	// 整个着色器会失效并回退默认材质（见 v007）。诊断分支必须写成 if/else。
	if (debug_mode >= 2) {
		// 诊断模式把光照置平，让 ALBEDO 里编码的诊断值原样可见
		DIFFUSE_LIGHT += vec3(1.0);
	} else {
		// 【不要乘 ALBEDO】理由同 terrain.gdshader 的 light()：引擎会在之后自己乘，
		// 这里再乘一次等于 albedo 平方，草会黑成一片。LIGHT_COLOR 已含 energy × PI。
		DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * k / PI;
	}
}
