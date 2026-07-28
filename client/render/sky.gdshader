shader_type sky;

// 白天穹顶：三段渐变 + HDR 太阳盘 + 程序云。
//
// 为什么不用 ProceduralSkyMaterial：它没有云，太阳只是一片模糊亮斑，
// 截图里半幅画面是天空，纯渐变撑不起「精致」。
//
// 太阳方向由 main.gd 每帧写入（与 DirectionalLight3D 同一个 to_sun），
// 保证天上的太阳盘和地面的受光面严格一致 —— 各算各的迟早会对不上。

// ── 天空渐变（线性色） ──
uniform vec3 zenith_color : source_color = vec3(0.055, 0.19, 0.46);
uniform vec3 mid_color : source_color = vec3(0.24, 0.46, 0.72);
uniform vec3 horizon_color : source_color = vec3(0.62, 0.72, 0.74);
// 地平线以下：地面反光基调，比天空暗，免得地下半球比天还亮
uniform vec3 ground_color : source_color = vec3(0.23, 0.26, 0.24);

// ── 太阳 ──
uniform vec3 sun_dir = vec3(0.5, 0.766, -0.866);
uniform vec3 sun_color : source_color = vec3(1.0, 0.92, 0.76);
uniform float sun_halo = 0.55;

// ── 云 ──
uniform vec3 cloud_lit : source_color = vec3(1.02, 1.0, 0.97);
uniform vec3 cloud_shade : source_color = vec3(0.58, 0.63, 0.68);
uniform float cloud_coverage = 0.42;
uniform float cloud_scale = 1.0;
uniform float cloud_time = 0.0;
uniform vec2 cloud_wind = vec2(0.011, 0.004);

// ── 噪声（与 terrain_sample.gdshaderinc 同源的哈希梯度噪声，
//    复制一份而不是 #include：那份文件带地形采样 uniform，天空不需要） ──
vec2 sky_hash2(vec2 p) {
	p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
	return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float sky_gnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
		mix(dot(sky_hash2(i + vec2(0.0, 0.0)), f - vec2(0.0, 0.0)),
			dot(sky_hash2(i + vec2(1.0, 0.0)), f - vec2(1.0, 0.0)), u.x),
		mix(dot(sky_hash2(i + vec2(0.0, 1.0)), f - vec2(0.0, 1.0)),
			dot(sky_hash2(i + vec2(1.0, 1.0)), f - vec2(1.0, 1.0)), u.x),
		u.y);
}

float sky_fbm(vec2 p) {
	float s = sky_gnoise(p);
	s += 0.5 * sky_gnoise(p * 2.13 + vec2(17.3, 9.1));
	s += 0.25 * sky_gnoise(p * 4.31 + vec2(41.7, 27.9));
	return s * 0.571;
}


void sky() {
	vec3 dir = normalize(EYEDIR);

	// ── 穹顶渐变 ──
	// 0 = 地平线，1 = 天顶。两段曲线：低处暖亮、高处深蓝。
	float t = clamp(dir.y, 0.0, 1.0);
	vec3 col = mix(horizon_color, mid_color, smoothstep(0.0, 0.28, t));
	col = mix(col, zenith_color, smoothstep(0.22, 0.85, t));
	// 地平线以下渐变到地面色
	col = mix(ground_color, col, smoothstep(-0.18, 0.02, dir.y));

	// ── 太阳 ──
	float sd = clamp(dot(dir, sun_dir), 0.0, 1.0);
	// 光盘：HDR（>1），交给 glow 晕开；盘内轻微暖白
	float disc = smoothstep(0.99935, 0.99985, sd) * 5.0;
	// 内晕与外晕：两层幂函数，近太阳的天被染暖
	float halo = pow(sd, 320.0) * sun_halo;
	float glow_wide = pow(sd, 12.0) * 0.16;
	col += sun_color * (halo + glow_wide) * smoothstep(-0.05, 0.12, dir.y);

	// ── 云 ──
	// 把视线投到 y=1 的平面上采样 2D fbm；dir.y 越小投影越拉伸，
	// 正好形成地平线处云的透视压缩。地平线附近淡出，免得贴边。
	if (dir.y > 0.015) {
		vec2 cp = dir.xz / (dir.y + 0.16) * 1.35 * cloud_scale + cloud_wind * cloud_time;
		float f = sky_fbm(cp);
		// fbm 集中在 0 附近（|f|>0.4 不足 15%），阈值要贴着分布走，
		// 否则「覆盖率 0.42」实际只剩几丝云（本工程第一版就因此看不见云）。
		float edge0 = 0.9 - cloud_coverage * 2.1;
		float cov = smoothstep(edge0, edge0 + 0.42, f);
		cov *= smoothstep(0.015, 0.14, dir.y);

		if (cov > 0.001) {
			// 廉价自遮蔽：朝太阳方向再采一次，差值当「厚度受光」。
			// 背光侧压灰、受光侧提白，云才有体积感而不是一层棉絮贴图。
			vec2 sun2d = normalize(sun_dir.xz + vec2(0.0001)) * 0.09;
			float f_lit = sky_fbm(cp - sun2d);
			float lit_t = clamp(0.5 + (f - f_lit) * 3.2, 0.0, 1.0);
			vec3 cloud = mix(cloud_shade, cloud_lit, lit_t);
			// 云底压一点天空色，云才不会浮在天上
			cloud = mix(cloud, col, (1.0 - lit_t) * 0.25);
			col = mix(col, cloud, cov * 0.92);
		}
	}

	col += sun_color * disc;

	COLOR = col;
}
