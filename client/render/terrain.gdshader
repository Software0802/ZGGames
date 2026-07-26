shader_type spatial;
render_mode cull_back, specular_disabled, depth_draw_opaque;

// 地形着色器：GPU 顶点位移 clipmap + 卡通分阶着色。
//
// 高程采样、坐标换算、程序化细节都在 terrain_sample.gdshaderinc 里，
// 与草地/树木/建筑落地共用同一份实现 —— 各写各的迟早会漂移，
// 表现为草浮空或陷进地里。
//
// ── 真实数据与程序化细节的分界 ────────────────────────────────────────
// 真实高程的极限是 28 m/px（SRTM 1 弧秒原生分辨率）。比这更细的起伏由 fbm
// 合成，**不是**实测地貌。detail_gain 设为 0 即可关掉，直接看纯 DEM。
// 这条分界在游戏内 F3 调试 HUD 上会标出来。

#include "res://client/render/terrain_sample.gdshaderinc"

// clipmap 相邻两级顶点密度差一倍，接缝必然对不齐。裙边顶点在 UV.x 标 1，
// 这里把它们压到地形以下挡住裂缝。
// 必须是 instance uniform：每级需要的深度正比于该级的格子尺寸，
// 用一个全局值会让外层几级的接缝漏出天空。见 client/render/clipmap.gd。
instance uniform float skirt_drop = 3.0;

// ── 季节与配色 ────────────────────────────────────────────────────────
// 这些都是**线性**颜色。GDScript 侧传参前必须 srgb_to_linear()：
// `source_color` 提示只影响编辑器取色器，引擎不会替你转换，不转会整片过曝。
uniform vec3 color_grass : source_color = vec3(0.16, 0.33, 0.06);
uniform vec3 color_dry : source_color = vec3(0.39, 0.28, 0.08);
uniform vec3 color_rock : source_color = vec3(0.15, 0.14, 0.11);
uniform vec3 color_snow : source_color = vec3(0.80, 0.85, 0.87);
uniform vec3 color_sand : source_color = vec3(0.50, 0.35, 0.15);

uniform float snow_line = 3000.0;
uniform float snow_blend = 320.0;
uniform float tree_line = 2600.0;
uniform float dry_below = 900.0;
uniform float dry_blend = 400.0;
uniform float rock_slope = 0.62;
uniform float rock_blend = 0.18;

// 卡通分阶。
// 地形用的是 Toon.RAMP_TERRAIN（七阶、窄动态范围），不是给角色的四阶硬 ramp ——
// 四阶铺到几公里宽的山体上每一阶跨上百像素，看起来是地质阶地而不是笔触。
uniform sampler2D ramp_near : filter_nearest, repeat_disable;
uniform sampler2D ramp_far : filter_nearest, repeat_disable;
uniform float ramp_blend_dist = 12000.0;
/// N·L 到 ramp 坐标的展开系数。半兰伯特（ndl*0.5+0.5）会把 t 压在 0.5–1.0，
/// 地形法线大多朝上，结果只用到 ramp 最上面两格，分阶等于白设。
uniform float wrap_factor = 0.35;
/// 大面积单色像塑料。按地表位置加一点低频明度扰动，不改色相。
uniform float albedo_variation = 0.09;

// 诊断用：0 正常 / 1 单色 / 2 高程等值带 / 3 法线 / 4 分级着色
uniform int debug_mode = 0;
// 每一级 clipmap 环一个颜色。instance uniform 让 9 级共用同一个材质。
instance uniform vec4 level_tint = vec4(1.0, 1.0, 1.0, 1.0);

varying vec3 v_world;
varying float v_view_dist;


void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_view_dist = length(world - CAMERA_POSITION_WORLD);

	float h = ts_surface_height(world.xz, v_view_dist);
	v_world = vec3(world.x, h, world.z);

	// 裙边压到地形以下。放在记录 v_world 之后，这样裙边的着色仍按它所在
	// 位置的地表算，从上往下看颜色连续，不会露出一圈异色。
	VERTEX.y = h - UV.x * skirt_drop - MODEL_MATRIX[3][1];
}


void fragment() {
	// 法线在片元里算：clipmap 远环顶点很稀，靠顶点法线会把山脊抹成平板。
	vec2 fuv = (ts_local_to_tile(v_world.xz, fine_n) - fine_tile_min) / fine_tile_span;
	// 差分步长贴数据分辨率：fine 层 28 m/px 用 30 m，coarse 层 447 m/px 用 420 m。
	float e = mix(420.0, 30.0, ts_fine_weight(fuv));
	vec3 n = ts_dem_normal(v_world.xz, e);

	float dfade = clamp(1.0 - v_view_dist / detail_fade_dist, 0.0, 1.0);
	if (detail_gain > 0.001 && dfade > 0.0) {
		float slope0 = 1.0 - n.y;
		float amp = detail_amp * detail_gain * dfade * (1.0 + slope0 * detail_slope_boost);
		float de = 6.0;
		float dl = ts_detail_height(v_world.xz - vec2(de, 0.0), amp);
		float dr = ts_detail_height(v_world.xz + vec2(de, 0.0), amp);
		float dd = ts_detail_height(v_world.xz - vec2(0.0, de), amp);
		float du = ts_detail_height(v_world.xz + vec2(0.0, de), amp);
		n = normalize(n + vec3(dl - dr, 0.0, dd - du) / (2.0 * de) * 1.6);
	}

	NORMAL = (VIEW_MATRIX * vec4(n, 0.0)).xyz;

	// ── 地表配色：按高程与坡度分层 ──
	float alt = v_world.y;
	float slope_c = n.y; // 1 = 水平

	vec3 base = color_grass;
	// 低海拔干旱带（吐鲁番戈壁、准噶尔盆地沙地）
	base = mix(color_sand, base, smoothstep(dry_below - dry_blend, dry_below + dry_blend, alt));
	// 林线以上草色转枯
	base = mix(base, color_dry, smoothstep(tree_line, tree_line + 500.0, alt) * 0.55);
	// 陡坡露岩
	base = mix(color_rock, base, smoothstep(rock_slope - rock_blend, rock_slope + rock_blend, slope_c));
	// 雪线：陡坡挂不住雪，再乘一次坡度
	float snow_t = smoothstep(snow_line - snow_blend, snow_line + snow_blend, alt)
		* smoothstep(0.42, 0.72, slope_c);
	base = mix(base, color_snow, snow_t);

	// 低频明度扰动：两个尺度（约 340 m 与 90 m），只动明度不动色相。
	float v = ts_fbm3(v_world.xz * 0.0029) * 0.6 + ts_fbm3(v_world.xz * 0.011) * 0.4;
	base *= 1.0 + v * albedo_variation;

	if (debug_mode == 1) {
		base = vec3(0.62);
	} else if (debug_mode == 2) {
		// 每 25 m 一条等值带。数据平滑的话带子应均匀连续。
		float band = fract(alt / 25.0);
		base = mix(vec3(0.22, 0.26, 0.30), vec3(0.86, 0.82, 0.64), step(0.5, band));
	} else if (debug_mode == 3) {
		base = n * 0.5 + 0.5;
	} else if (debug_mode == 4) {
		base = level_tint.rgb;
	} else if (debug_mode >= 5) {
		// 光照诊断模式：ALBEDO 置 1，让 light() 里输出的诊断值原样可见
		base = vec3(1.0);
	}

	ALBEDO = base;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}


void light() {
	float ndl = dot(normalize(NORMAL), normalize(LIGHT));
	float t = clamp((ndl + wrap_factor) / (1.0 + wrap_factor), 0.0, 1.0);
	float near_v = texture(ramp_near, vec2(t, 0.5)).r;
	float far_v = texture(ramp_far, vec2(t, 0.5)).r;
	float k = mix(near_v, far_v, clamp(v_view_dist / ramp_blend_dist, 0.0, 1.0));

	// 诊断：把光照链路上每一环单独显示出来（配合 fragment 里把 ALBEDO 置 1）。
	//
	// 【不要在 light() 里写 return】Godot 明确禁止：
	// 「Using 'return' in the 'light' processor function is incorrect.」
	// 这不是警告而是编译错误，整个着色器会编译失败并回退到默认材质 ——
	// 画面表现为地形变成一整块**纯白平面、无顶点位移**，看起来极像数据或
	// 流式加载出了问题，与着色器完全联系不起来。诊断分支必须写成 if/else 链。
	if (debug_mode == 5) {
		DIFFUSE_LIGHT += vec3(ATTENUATION);
	} else if (debug_mode == 6) {
		DIFFUSE_LIGHT += vec3(ndl * 0.5 + 0.5);
	} else if (debug_mode == 7) {
		DIFFUSE_LIGHT += vec3(k);
	} else if (debug_mode == 8) {
		DIFFUSE_LIGHT += LIGHT_COLOR / PI;
	} else {
		// 【不要乘 ALBEDO】DIFFUSE_LIGHT 只累加**光**，引擎在之后自己乘上 ALBEDO。
		// 官方 light() 示例即 `DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0, 1)
		//  * ATTENUATION * LIGHT_COLOR / PI;`，同样没有 ALBEDO。
		// 这里若再乘一次，albedo 会被平方：中绿 0.16 变成 0.026，整片地形黑掉，
		// 而且极难定位 —— 本工程实际按「阴影 / 太阳角 / 色彩空间」查了好几轮才找到。
		// LIGHT_COLOR 已含 energy × PI，所以要除回 PI。
		DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * k / PI;
	}
}
