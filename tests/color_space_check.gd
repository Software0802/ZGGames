extends Node3D
## 确认：从 GDScript 用 set_shader_parameter 给 `source_color` uniform 传 Color 时，
## 引擎到底会不会替你做 sRGB → 线性 转换。
##
## 为什么必须问清楚：全工程的季节配色都走这条路（`Toon.SEASON_ENV` 的十六进制
## → `Color(hex)` → 送进着色器）。v003 §五.2 断言「引擎不会替你转换，
## 必须自己 .srgb_to_linear()，否则整片过曝」，代码就是按这个断言写的。
## 若断言是反的，全工程的配色就被**转换了两次**，整体偏暗偏冷一档 ——
## v010 在地表渲染结果里量到蓝通道几乎为零（RGB 43,108,3，而 #628b38 的蓝是 56/255），
## 正是二次转换的典型特征。
##
## 做法：四块 unshaded 方片并排，各自用不同的传参方式设同一个颜色。
## unshaded 时屏幕像素 = 线性→sRGB(ALBEDO)，中间没有光照掺和，
## 所以哪一块渲出原始十六进制，哪一种传法就是对的。
##
## 这个判断与渲染后端无关（Forward+ / Compatibility 都一样），
## 所以在没有显卡的软件光栅化环境里跑出来的结论同样可信。
##
## 跑：
##   godot --path . --rendering-method gl_compatibility --rendering-driver opengl3 \
##     tests/color_space_check.tscn

## 拿夏季地表色做样本。选它而不是纯色，是因为三个通道差异大，
## 二次转换在低通道（蓝）上放大得最明显，一眼能看出来。
const SAMPLE_HEX := "#6f9e3f"

const SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform vec3 plain;
uniform vec3 tinted : source_color;
uniform int which = 0;
void fragment() {
	ALBEDO = which == 0 ? plain : tinted;
}
"""

## [名称, 是否用 source_color 那个 uniform, 是否自己先转成线性]
const CASES := [
	["A 无 hint + 原始 sRGB 分量", false, false],
	["B  source_color + Color（不自己转）", true, false],
	["C  source_color + srgb_to_linear（现工程的写法）", true, true],
	["D 无 hint + 自己转成线性（基准）", false, true],
]


var _cam: Camera3D
var _quads: Array[MeshInstance3D] = []


func _ready() -> void:
	# 【必须有 WorldEnvironment】没有它，Godot 会跳过色调映射/输出解析这一趟，
	# 取回来的图是**线性**的；而 client/main.tscn 有环境，取回来的图是 sRGB 编码的。
	# 两条捕获路径不一样，拿没有环境的测试结论去解释主场景的截图会得出相反的答案
	# —— 第一版就踩了这个坑：测试里 A（不转换）看起来是对的，
	# 而主场景实测天顶像素明明是按 sRGB 编码输出的。
	# 这里照抄主场景的关键设置：tonemap 线性、不加环境光，让 ALBEDO 尽量原样通过。
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	we.environment = env
	add_child(we)

	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 4.0
	_cam.position = Vector3(0.0, 0.0, 5.0)
	add_child(_cam)

	var shader := Shader.new()
	shader.code = SHADER
	var base := Color(SAMPLE_HEX)

	for i in CASES.size():
		var cfg: Array = CASES[i]
		var mat := ShaderMaterial.new()
		mat.shader = shader
		var value := base.srgb_to_linear() if bool(cfg[2]) else base
		if bool(cfg[1]):
			mat.set_shader_parameter("which", 1)
			mat.set_shader_parameter("tinted", value)
		else:
			mat.set_shader_parameter("which", 0)
			# 不带 hint 的 vec3：用 Vector3 传，绕开「Color 会不会被特殊对待」这件事本身
			mat.set_shader_parameter("plain", Vector3(value.r, value.g, value.b))

		var mi := MeshInstance3D.new()
		mi.mesh = QuadMesh.new()
		(mi.mesh as QuadMesh).size = Vector2(1.0, 3.0)
		mi.material_override = mat
		mi.position = Vector3(-1.5 + float(i), 0.0, 0.0)
		add_child(mi)
		_quads.append(mi)

	# 等几帧让着色器编译完再取图
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	_report()
	get_tree().quit()


func _report() -> void:
	var img := get_viewport().get_texture().get_image()

	# 【判据是「和基准 D 比」，不是「和原始十六进制比」】
	# 取回来的图究竟是线性还是已做 sRGB 编码，取决于捕获路径（有没有环境、
	# 色调映射走没走），本自检不该也不必去猜它 —— 第一版拿「渲出原始十六进制」
	# 当判据，结论会随捕获路径整个翻个面。
	#
	# D 是**构造上正确**的那一格：不带 hint 就没有引擎介入的余地，
	# 自己转成线性喂给 ALBEDO，无论捕获路径如何，它渲出来的就是「对」的样子。
	# 于是问题化简成一句：B 和 C，哪个和 D 一样？
	var got := PackedVector3Array()
	for i in CASES.size():
		# 用 unproject_position 反算方片中心落在屏幕哪个像素。
		# 不要按「每块占屏宽 1/4」去猜：正交相机的 size 是**纵向**的，
		# 横向范围还要乘宽高比，按 1/4 均分会有两块采到背景上去
		# —— 第一版就是这么写的，结果 A 与 D 报的是清屏色，看起来像「两种传法都错」。
		var px := _cam.unproject_position(_quads[i].global_position)
		var c := img.get_pixel(int(px.x), int(px.y))
		got.append(Vector3(c.r * 255.0, c.g * 255.0, c.b * 255.0))

	var base: Vector3 = got[3]  # D
	var lines := PackedStringArray([
		"",
		"source_color 转换行为自检   样本 %s" % SAMPLE_HEX,
		"判据：与基准 D（无 hint + 自己转成线性）是否一致。",
		"",
	])
	var same := PackedStringArray()
	for i in CASES.size():
		var d := (got[i] - base).abs()
		var ok := d.x + d.y + d.z <= 3.0
		if ok and i != 3:
			same.append(String(CASES[i][0]).strip_edges().substr(0, 1))
		lines.append("  %s  %-44s → (%3d, %3d, %3d)" % [
			"＝D" if ok else "≠D", CASES[i][0], roundi(got[i].x), roundi(got[i].y), roundi(got[i].z),
		])

	lines.append("")
	if same.has("C"):
		lines.append("  → 引擎**不会**替 source_color 做 sRGB→线性：v003 §五.2 的断言成立，")
		lines.append("    工程里 set_shader_parameter 前的 .srgb_to_linear() 是必需的，别删。")
	elif same.has("B"):
		lines.append("  → 引擎**会**替 source_color 转换：工程里的 .srgb_to_linear() 是多余的，要去掉。")
	else:
		lines.append("  → B 与 C 都不等于 D，source_color 还做了别的事，需要单独查。")
	print("\n".join(lines))
