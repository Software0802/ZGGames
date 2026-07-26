class_name Clipmap
extends Node3D
## 几何 clipmap 地形网格。
##
## 一组以相机为中心的同心方环，每往外一级顶点间距翻倍。网格本身是**静态**的 ——
## 顶点的 y 全部由 terrain.gdshader 从真实 DEM 纹理采样得到，CPU 每帧只做一件事：
## 把每一级吸附到它自己的顶点栅格上。吸附是为了防抖：如果环跟着相机连续平移，
## 顶点会在高程场上滑动，远处山脊就会像水面一样蠕动。
##
## 为什么不用 Terrain3D：它上限 65.5×65.5 km（新疆约 1600×1100 km），只支持到
## Godot 4.6，而且它的核心价值是可编辑地形 —— 我们的高程是烘焙的只读真实 DEM，
## 用不上雕刻与绘制，反倒是它的 PBR 着色要跟四阶 ramp + 描边打架。见 docs/plans/v001。

## 每级每边的格子数。必须是 4 的倍数：环的厚度是 GRID/4 格。
const GRID := 128
## 最内一级的顶点间距（米）。真实 DEM 只有 28 m 分辨率，比这更细的起伏来自
## 着色器里的分形细节层 —— 1 m 是为了让细节层有地方落笔，不是在假装数据更精细。
const BASE_SPACING := 1.0
## 级数。最外一级的覆盖半径 = GRID * BASE_SPACING * 2^(LEVELS-1) / 2 = 16.4 km。
## GRID 从 64 提到 128 是因为 64 时中距离的环间距（96–192 m）明显粗于 DEM 的 28 m，
## 山体轮廓被切成大块平板。128 下约 23 万三角面，仍远低于 90 万的预算。
const LEVELS := 9
## 每级的洞比「上一级的覆盖范围」小多少格。
##
## 【为什么需要重叠】
## 第 L 级吸附到 2·s_L 的栅格，第 L−1 级吸附到 s_L 的栅格，两者中心最多能差 s_L。
## 如果洞的尺寸正好等于上一级的覆盖范围，这个偏移就会在某一侧留下最宽 s_L 的**缺口**，
## 透过去直接看到天空下半球 —— 本工程在那拉提实际渲染出过大片这样的「空洞」，
## 而且极易被误判成着色或数据问题（排查了很久才定位）。
## 洞每边内缩 2 格（共 4 格）后重叠量恒为 2·s_L，大于最大偏移 s_L，缺口不可能出现。
const HOLE_SHRINK_CELLS := 4

## 裙边下垂量 = 该级顶点间距 × 这个系数。
##
## 有了上面的重叠，裙边不再承担「补洞」的职责，只用来盖住接缝处两级面片之间
## 那一点高差，所以系数很小就够。系数给大了会适得其反：裙边是垂直墙面，
## 深到几百米时会从低视角挡住整片远景（实测系数 14 时前景变成一堵绿墙）。
const SKIRT_FACTOR := 3.0
## 材质里 skirt_drop 这个 uniform 的初值；实际每级都会用 instance uniform 覆盖。
const SKIRT_DROP := 3.0

## 高程可能出现的范围，用于 custom_aabb。艾丁湖 −154 m 到乔戈里峰 8611 m，
## 两头各留余量 —— 给错了 Godot 会在相机贴近地面时把整级剔除掉。
const AABB_Y_MIN := -600.0
const AABB_Y_MAX := 9200.0

var _levels: Array[MeshInstance3D] = []
var material: ShaderMaterial


func _init(mat: ShaderMaterial = null) -> void:
	material = mat


func _ready() -> void:
	_build()


func _build() -> void:
	for i in LEVELS:
		var spacing := BASE_SPACING * pow(2.0, float(i))
		# 第 0 级是完整方块；往外每一级中间挖掉上一级的覆盖范围，只留一圈方环。
		# 洞要比上一级的覆盖再小 HOLE_SHRINK_CELLS 格，留出重叠余量，见其说明。
		var hole := 0 if i == 0 else GRID / 2 - HOLE_SHRINK_CELLS
		var mesh := _build_grid(GRID, spacing, hole)

		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = material
		# 地形不投影，只接收阴影。
		#
		# 试过开自阴影（想让几公里外的山脊有明暗层次），结果两个问题都很实在：
		#   1. 高度场自投影在低视角下必然出 shadow acne —— 整片坡把自己遮黑，
		#      实测贴地机位下那拉提整个山坡变成近乎纯黑；
		#   2. 阴影通道要把几何再提交一遍，开到第 5 级三角面就冲到 92.8 万，
		#      超过交接文档 §07 给的 90 万预算。
		# 起伏靠 N·L 分阶 + 片元法线已经能读出来。阴影留给真正需要它的东西：
		# 毡房、角色、牲畜（P4）—— 那些是有体积的物体，投影收益远大于代价。
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# 顶点的 y 是着色器给的，Godot 不知道，必须手工告诉它包围盒，
		# 否则相机一低头整级就被视锥剔除掉了。
		var half := GRID * spacing * 0.5
		mi.custom_aabb = AABB(
			Vector3(-half, AABB_Y_MIN, -half),
			Vector3(half * 2.0, AABB_Y_MAX - AABB_Y_MIN, half * 2.0),
		)
		mi.name = "L%d_%.1fm" % [i, spacing]
		add_child(mi)
		_levels.append(mi)
		# 裙边按本级格子尺寸缩放，见 SKIRT_FACTOR 的说明。
		mi.set_instance_shader_parameter("skirt_drop", spacing * SKIRT_FACTOR)
		# 调试着色用（debug_mode == 4）。色相按级递进，相邻两级一眼能分开。
		mi.set_instance_shader_parameter(
			"level_tint", Color.from_hsv(fmod(float(i) * 0.13, 1.0), 0.72, 0.95)
		)


## 造一张 cells×cells 的方格网，可选挖掉中间 hole×hole 个格子。
## 外圈（以及挖洞时的内圈）加一圈垂直裙边，裙边顶点在 UV.x 上标 1，
## 着色器据此把它们往下压 SKIRT_DROP。
func _build_grid(cells: int, cell_size: float, hole: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	var n := cells + 1
	var half := cells * cell_size * 0.5
	verts.resize(n * n)
	uvs.resize(n * n)
	for j in n:
		for i in n:
			var k := j * n + i
			verts[k] = Vector3(i * cell_size - half, 0.0, j * cell_size - half)
			uvs[k] = Vector2.ZERO

	var hole_lo := (cells - hole) / 2
	var hole_hi := (cells + hole) / 2
	var in_hole := func(i: int, j: int) -> bool:
		return hole > 0 and i >= hole_lo and i < hole_hi and j >= hole_lo and j < hole_hi

	for j in cells:
		for i in cells:
			if in_hole.call(i, j):
				continue
			# 绕序必须让朝上的面成为正面，否则 cull_back 会把整片地形的可见面剔掉，
			# 只剩背向相机的坡还在画面上 —— 表现为大片「空洞」，极难与数据问题区分。
			# 顶点排列：a=(i,j) b=(i+1,j) c=(i,j+1) d=(i+1,j+1)，+i 是 +x，+j 是 +z。
			var a := j * n + i
			var b := a + 1
			var c := a + n
			var d := c + 1
			idx.append_array([a, b, c, b, d, c])

	# 裙边：沿边界复制一圈顶点，标记后由着色器压到地形以下。
	_add_skirt(verts, uvs, idx, n, 0, 0, cells, cells, true)
	if hole > 0:
		_add_skirt(verts, uvs, idx, n, hole_lo, hole_lo, hole_hi, hole_hi, false)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 沿矩形边界 [i0,i1]×[j0,j1] 加裙边。outward=true 时裙边朝外背面朝内（外圈），
## 否则反向（洞的内圈）。
func _add_skirt(
	verts: PackedVector3Array, uvs: PackedVector2Array, idx: PackedInt32Array,
	n: int, i0: int, j0: int, i1: int, j1: int, outward: bool,
) -> void:
	# 收集边界顶点索引，按环序排列
	var ring: PackedInt32Array = []
	for i in range(i0, i1 + 1):
		ring.append(j0 * n + i)
	for j in range(j0 + 1, j1 + 1):
		ring.append(j * n + i1)
	for i in range(i1 - 1, i0 - 1, -1):
		ring.append(j1 * n + i)
	for j in range(j1 - 1, j0, -1):
		ring.append(j * n + i0)

	var base := verts.size()
	for k in ring.size():
		var v := verts[ring[k]]
		verts.append(v)
		uvs.append(Vector2(1.0, 0.0))  # UV.x = 1 → 着色器识别为裙边

	for k in ring.size():
		var k2 := (k + 1) % ring.size()
		var top_a := ring[k]
		var top_b := ring[k2]
		var bot_a := base + k
		var bot_b := base + k2
		# 绕序与网格面保持一致，理由同上。
		if outward:
			idx.append_array([top_a, top_b, bot_a, top_b, bot_b, bot_a])
		else:
			idx.append_array([top_a, bot_a, top_b, top_b, bot_a, bot_b])


## 每帧把各级吸附到自己的顶点栅格。传入相机的局部坐标。
func snap_to(focus: Vector3) -> void:
	for i in _levels.size():
		var spacing := BASE_SPACING * pow(2.0, float(i))
		# 吸附步长取 2×间距：这样本级的洞口正好落在上一级的顶点上，
		# 只吸附 1×间距的话洞口会在上一级网格里来回半格，接缝一直在抖。
		var step := spacing * 2.0
		_levels[i].position = Vector3(
			snappedf(focus.x, step), 0.0, snappedf(focus.z, step)
		)


## 最外一级的覆盖半径（米）。天空盒与雾的远端要据此设置。
static func view_radius() -> float:
	return GRID * BASE_SPACING * pow(2.0, float(LEVELS - 1)) * 0.5


## 缩放裙边深度。scale = 0 即完全关闭裙边，用于诊断接缝来源。
func set_skirt_scale(scale: float) -> void:
	for i in _levels.size():
		var spacing := BASE_SPACING * pow(2.0, float(i))
		_levels[i].set_instance_shader_parameter("skirt_drop", spacing * SKIRT_FACTOR * scale)


## 只显示指定级（-1 = 全部）。诊断分级接缝与空洞时用。
func show_only_level(idx: int) -> void:
	for i in _levels.size():
		_levels[i].visible = (idx < 0 or i == idx)


func level_count() -> int:
	return _levels.size()


func set_material(mat: ShaderMaterial) -> void:
	material = mat
	for mi in _levels:
		mi.material_override = mat
