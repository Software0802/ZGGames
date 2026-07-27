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
/// 光照链路诊断（ALBEDO 置 1，把 light() 里的中间量原样显示出来，同 terrain.gdshader）：
///   5 ramp 输出 k    6 N·L（0.5+0.5 编码）  7 FRONT_FACING（白=正面 红=背面）
/// 【注意 5 与 6 会被环境光顶到饱和】ALBEDO=1 时 ambient 就有大半档，
/// 诊断值再叠上去往往直接切到 255，两个不同的 k 看起来一样白。
/// 要比较亮度差就用 8：配色正常，只把 k 强制为 1 且不压根部 ——
/// 若草仍比地表暗，问题就不在 ramp 与根部压暗上。
///   8 配色正常 + k≡1 + 不压根部
///   9 light() 生效探针：草应变成纯红。**不红就说明当前渲染后端根本没在调 light()**，
///     此时一切关于明暗/配色的观察都不代表 Forward+ 的结果（见 v010 的验证边界）。
///  10 配色正常 + 完全绕开 LIGHT_COLOR / ATTENUATION（平光 1.0）。
///     和 8 配对使用就能把「ramp/根部」与「LIGHT_COLOR/ATTENUATION」分开：
///     8 与正常一样而 10 亮很多 ⇒ 问题在 ATTENUATION（阴影）或 LIGHT_COLOR，不在 ramp。
///     v010 就是这么定位到「没有投影体的阴影灯把草压暗一个数量级」的。
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

	// 每片的随机相位与高矮，用根部坐标做种子 —— 同一片在任何一帧、任何一台
	// 机器上都算出同样的值，不需要往实例里塞额外数据。
	//
	// 【频率必须细于丛内半径】乘 7.31 时格子是 0.137 m，而一丛草的半径是 0.17 m ——
	// 同一丛里的几片会落进同一格，拿到一样的相位与高矮，整丛齐刷刷同高同步摆，
	// 成丛反而比均匀撒点更假。乘 53 后格子 0.019 m，丛内每片都不同。
	vec2 seed = ts_hash2(floor(root.xz * 53.0));
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
	} else if (debug_mode == 7) {
		// 十字双面片必然有一半三角面背向相机（render_mode 是 cull_disabled）。
		// 这一档用来确认背面到底有没有被当成背面着色。
		c = FRONT_FACING ? vec3(1.0) : vec3(1.0, 0.0, 0.0);
	} else if (debug_mode >= 5 && debug_mode <= 6) {
		c = vec3(1.0);  // 让 light() 里输出的诊断值原样可见
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
	// 根部压暗一点，让草丛底部有厚度感，而不是一片平的绿。
	// 注意 root_color 那边也压了一道，两处相乘 —— 各留一点就够，
	// 给多了整丛草会比脚下的地表还暗（见 grass.gd 里 root_color 的说明）。
	k *= mix(0.90, 1.0, v_up);
	// 【不要在 light() 里写 return】Godot 明令禁止，那不是警告而是编译错误，
	// 整个着色器会失效并回退默认材质（见 v007）。诊断分支必须写成 if/else。
	if (debug_mode == 5) {
		DIFFUSE_LIGHT += vec3(k);
	} else if (debug_mode == 6) {
		DIFFUSE_LIGHT += vec3(ndl * 0.5 + 0.5);
	} else if (debug_mode == 8) {
		DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION / PI;
	} else if (debug_mode == 9) {
		DIFFUSE_LIGHT += vec3(4.0, 0.0, 0.0);
	} else if (debug_mode == 10) {
		DIFFUSE_LIGHT += vec3(1.0);
	} else if (debug_mode >= 2 && debug_mode <= 4) {
		// 诊断模式把光照置平，让 ALBEDO 里编码的诊断值原样可见
		DIFFUSE_LIGHT += vec3(1.0);
	} else {
		// 【不要乘 ALBEDO】理由同 terrain.gdshader 的 light()：引擎会在之后自己乘，
		// 这里再乘一次等于 albedo 平方，草会黑成一片。LIGHT_COLOR 已含 energy × PI。
		DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * k / PI;
	}
}
