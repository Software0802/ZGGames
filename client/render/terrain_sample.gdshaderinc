// 真实 DEM 高程采样。地形与草地（以及后续的树、建筑落地）共用这一份，
// 保证所有东西站在**完全相同**的地面上 —— 各写各的采样代码迟早会漂移，
// 表现为草浮空或陷进地里。
//
// 使用方在自己的 shader 里 #include 本文件，然后把下面这些 uniform 交给
// TerrainStreamer.apply_to() 统一填写。

// ── 坐标系（与 shared/sim/georef.gd 保持同步） ──
uniform float origin_lon;
uniform float origin_lat;
uniform float m_per_deg_lon;
uniform float m_per_deg_lat;

// ── 高程窗口 ──
uniform sampler2D tex_fine : filter_linear, repeat_disable, hint_default_black;
uniform sampler2D tex_coarse : filter_linear, repeat_disable, hint_default_black;
uniform vec2 fine_tile_min;
uniform vec2 fine_tile_span;
uniform float fine_n = 4096.0;
uniform vec2 coarse_tile_min;
uniform vec2 coarse_tile_span;
uniform float coarse_n = 256.0;
uniform float fine_fade_uv = 0.04;

// ── 程序化细节（DEM 奈奎斯特以下的合成起伏，不是实测地貌） ──
uniform float detail_gain = 1.0;
uniform float detail_base_freq = 0.018;
uniform float detail_amp = 2.6;
uniform float detail_slope_boost = 3.4;
uniform float detail_fade_dist = 2600.0;

// ── 噪声 ──
// 哈希梯度噪声。不用查表贴图：省一张纹理，不受纹理过滤影响，
// 且 CPU 侧能用同样的公式复算出完全一致的结果。
vec2 ts_hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float ts_gnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(dot(ts_hash2(i + vec2(0.0, 0.0)), f - vec2(0.0, 0.0)),
			dot(ts_hash2(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0)), u.x),
		mix(dot(ts_hash2(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0)),
			dot(ts_hash2(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0)), u.x),
		u.y);
}

float ts_fbm3(vec2 p) {
	float s = ts_gnoise(p);
	s += 0.5 * ts_gnoise(p * 2.03);
	s += 0.25 * ts_gnoise(p * 4.11);
	return s * 0.571;
}

// ── 坐标换算 ──
/// 局部米制 (x, z) → Web Mercator 分数瓦片坐标。
/// 与 GeoRef.geo_to_local / lonlat_to_tile 互为逆运算。
///
/// 为什么要走完整逆投影而不是「窗口矩形 + 线性插值」：瓦片按 Web Mercator 排列，
/// 而游戏世界是以锚点为中心的局部米制切平面，两者之间不是线性关系
/// （墨卡托纬向尺度按 sec(lat) 变化，48°N 跨 29 km 就变了约 0.6%）。
/// 线性映射会把窗口边缘的地形特征搬走最多约 40 米。
vec2 ts_local_to_tile(vec2 xz, float n) {
	float lon = origin_lon + xz.x / m_per_deg_lon;
	float lat = origin_lat - xz.y / m_per_deg_lat;
	float tx = (lon + 180.0) / 360.0 * n;
	// asinh(tan(lat))。写成 log 形式而不是调 asinh：后者在部分驱动的
	// GLSL ES 实现上精度差异较大，log 形式各处一致。
	float t = tan(radians(lat));
	float ty = (1.0 - log(t + sqrt(t * t + 1.0)) / PI) * 0.5 * n;
	return vec2(tx, ty);
}

/// 点在 fine 窗口内的权重：1 = 深在窗口里，0 = 已在窗口外。
float ts_fine_weight(vec2 uv) {
	vec2 d = min(uv, 1.0 - uv);
	return clamp(min(d.x, d.y) / max(fine_fade_uv, 0.001), 0.0, 1.0);
}

/// 真实 DEM 高程（米），不含程序化细节。
float ts_dem_height(vec2 xz) {
	vec2 cuv = (ts_local_to_tile(xz, coarse_n) - coarse_tile_min) / coarse_tile_span;
	float coarse = texture(tex_coarse, cuv).r;

	vec2 fuv = (ts_local_to_tile(xz, fine_n) - fine_tile_min) / fine_tile_span;
	float w = ts_fine_weight(fuv);
	if (w <= 0.0) {
		return coarse;
	}
	return mix(coarse, texture(tex_fine, fuv).r, w);
}

/// 程序化细节位移（米）。
float ts_detail_height(vec2 xz, float amp) {
	if (amp <= 0.001) {
		return 0.0;
	}
	return ts_fbm3(xz * detail_base_freq) * amp;
}

/// DEM 法线。差分步长要贴着**数据的分辨率**（fine 层 28 m/px），
/// 给大了会把真实的山脊磨平。
vec3 ts_dem_normal(vec2 xz, float e) {
	float hl = ts_dem_height(xz - vec2(e, 0.0));
	float hr = ts_dem_height(xz + vec2(e, 0.0));
	float hd = ts_dem_height(xz - vec2(0.0, e));
	float hu = ts_dem_height(xz + vec2(0.0, e));
	return normalize(vec3(hl - hr, 2.0 * e, hd - hu));
}

/// 地表最终高度（真实 DEM + 程序化细节）。草、树、建筑都必须用这个函数落地，
/// 否则会和地形对不齐。view_dist 用于按距离淡出细节，与地形着色器保持一致。
float ts_surface_height(vec2 xz, float view_dist) {
	float h = ts_dem_height(xz);
	float dfade = clamp(1.0 - view_dist / detail_fade_dist, 0.0, 1.0);
	if (detail_gain > 0.001 && dfade > 0.0) {
		vec3 n = ts_dem_normal(xz, 30.0);
		float slope = 1.0 - n.y;
		float amp = detail_amp * detail_gain * dfade * (1.0 + slope * detail_slope_boost);
		h += ts_detail_height(xz, amp);
	}
	return h;
}
