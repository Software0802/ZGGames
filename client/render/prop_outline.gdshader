shader_type spatial;
render_mode cull_front, unshaded, depth_draw_opaque;

// 反壳描边：正面剔除 + 顶点沿法线外推固定宽度。
// 作为 prop_toon.gdshader 的 next_pass 使用，复用同一份网格与实例变换。
// 宽度按对象类别取（交接文档 §07）：角色 0.010–0.018，动物 0.022–0.028，建筑 0.030。

uniform float width = 0.025;
uniform vec3 outline_color : source_color = vec3(0.075, 0.06, 0.045);

void vertex() {
	VERTEX += NORMAL * width;
}

void fragment() {
	ALBEDO = outline_color;
}
