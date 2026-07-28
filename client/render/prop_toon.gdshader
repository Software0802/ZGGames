shader_type spatial;
render_mode cull_back, specular_disabled, depth_draw_opaque;

// 道具/建筑/动物共用卡通着色：顶点色即反照率，四阶硬 ramp。
//
// 全部物件合并成一个带顶点色的 ArrayMesh（MultiMesh 实例化铺开），
// 与 three.js 原型同一结构 —— 交接文档 §07：90 只羊 = 2 次 draw call（含描边）。
//
// 描边不走后处理边缘检测，走 next_pass 反壳（prop_outline.gdshader）：
// 实例化对象可共用同一套材质链，描边粗细不随距离抖动。

uniform sampler2D ramp : filter_nearest, repeat_disable;
uniform float wrap_factor = 0.45;

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}


void light() {
	float ndl = dot(normalize(NORMAL), normalize(LIGHT));
	float t = clamp((ndl + wrap_factor) / (1.0 + wrap_factor), 0.0, 1.0);
	float k = texture(ramp, vec2(t, 0.5)).r;
	// 【不要乘 ALBEDO】引擎之后会自己乘，理由同 terrain.gdshader 的 light()。
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * k / PI;
}
