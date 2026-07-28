class_name GrassField
extends Node3D
## 草地。两圈 MultiMesh 跟着玩家吸附移动。
##
## 为什么要分圈：MultiMeshInstance3D 的**所有实例共用同一个 LOD 级别**
## （见 Godot 文档 tutorials/3d/mesh_lod），所以近处的密草和远处的稀草
## 必须拆成两个节点，否则要么近处不够密，要么远处白烧三角面。
##
## 草叶的落地高度由 grass.gdshader 自己从高程纹理采样，CPU 不参与 ——
## 移动时只需要把节点吸附到新格子，几万株草的位置一个都不用重算。

class Ring:
	var node: MultiMeshInstance3D
	var extent: float   ## 覆盖范围（米，方形边长的一半）
	var snap: float     ## 吸附步长（米）

## count 实例数 / extent 覆盖半径(米) / hole 中间挖空半径(米) / segments 叶片段数
## / width 叶宽 / height 叶高
##
## 段数决定草叶能不能弯：近圈 3 段能被风吹出弧线，远圈 1 段是直片，够用。
##
## 【远圈必须挖洞】远圈用「少而大」的叶片换密度：12000 株铺 260 m，株距 4.7 m，
## 单株 1.05 m 高 × 0.52 m 宽（再乘 vary 与 height_scale，那拉提实际到 2.6 m × 0.7 m）。
## 那个尺寸在几十米外读起来是草，出现在脚边就是灌木 —— 而不挖洞的话，远圈的
## 方形范围整个盖住近圈，脚边同时长着 1.4 m 的细草和 2.6 m 的巨叶，
## 近圈那 21000 株密草全被压在底下看不见。这与 clipmap 每级挖掉上一级覆盖范围
## 是同一件事，见 Clipmap.HOLE_SHRINK_CELLS 的说明。
##
## 【洞口必须留足重叠】两圈吸附到各自的栅格（近圈 9.75 m，远圈 32.5 m），
## 中心每轴最多能差 9.75/2 + 32.5/2 ≈ 21.1 m。洞口若正好等于近圈的覆盖范围，
## 这个偏移就会在某一侧留出一条**光秃的缝**。
## 按 clipmap 的同一条规矩取「重叠 ≥ 2 倍最大偏移」（见 Clipmap.HOLE_SHRINK_CELLS）：
## 需要 78 − hole ≥ 42.3，故 hole ≤ 35.8，取 34 m。
## 代价只是 34–78 m 这一带两圈同时长草（密一点，无害），换来脚边不会出现巨叶。
## 【叶片尺寸的依据】草出来之后第一件事就是它读起来不像草，是一根根锥体。
## 原因是尺寸：原来近圈单株 0.55 m 高 × 0.24 m 宽，乘上 vary(≤1.40) 与那拉提的
## height_scale 1.8 之后是 1.39 m × 0.34 m —— 一株「草」比人还高、比手掌还宽。
##
## 重新定标，两个锚点：
##   * 高度：数值表说那拉提「草深过膝」（carrying_capacity 1.8）。过膝是 0.5–0.6 m。
##     倒推基准高度 0.34 m：0.34 × 1.8 × vary(1.06 典型) ≈ 0.65 m，峰值 0.86 m。
##     基准值是 height_scale = 1.0（普通草场）时的高度，那时约 0.36 m，及踝到小腿。
##   * 宽度：交接文档 §07 的原型全场景只有 13000 株草，靠的是宽片凑覆盖率。
##     但 0.24 m 是「一丛」的宽度而不是一片叶子，近处一眼就露馅。
##     收到 0.13 m，覆盖率靠加密补回来（见下）。
##
## 【成丛，不是均匀撒点】叶片一收窄，均匀网格立刻露出问题：每株都孤零零站着，
## 读起来是「草坪上的杂草」而不是草原。真实的草是**一丛一丛**长的，
## 所以撒点分两级：抖动网格定丛心，每丛在 tuft_radius 内再撒几片，各自随机朝向与倾角。
## 同样的三角面预算下，成丛的覆盖感远好于均匀撒点 —— 因为叶片互相叠着，
## 远看连成一片，近看仍是一片片独立的叶子。
##
## 【三角面预算怎么分】预算 900 k（交接文档 §07），地形约 50 k，草能用 800 k 左右。
## 近圈段数从 3 降到 2（12 面/株 → 8 面/株）：一个弯折点仍然能被风吹出弧线，
## 换来株数能翻一倍多。14000 丛 × 4 片 = 56000 片 × 8 面 = 448 k，
## 加远圈 16000 × 4 = 64 k，草共约 512 k，总计约 56 万，留足余量。
##
## 【近圈覆盖范围从 78 m 收到 55 m】覆盖范围是比株数更划算的密度旋钮：
## 株数不变、三角面一面不多，密度按面积反比涨 2 倍（0.77 → 1.5 丛/m²，
## 丛心间距 1.14 m → 0.82 m，对上一丛草 0.34 m 的直径才勉强连成片）。
## 原来 78 m 里绝大多数叶片落在几十米外，那个距离上单片草不到一个像素，
## 纯属白烧三角面 —— 远处本来就该由远圈和地形基色顶替。
##
## 密度是旋钮不是定论：这里只把它推到三角面预算的边上（预算 900 k，现约 76 万），
## 再往上加得先在真机上测帧。**软件渲染下的 fps 不可信**，只有三角面与 draw call 可信，
## 所以本次没有继续加密（见 v010）。
##
## tufts 丛数 / blades 每丛片数 / tuft_radius 丛内半径(米) / extent 覆盖半径(米)
## / hole 中间挖空半径(米) / segments 叶片段数 / width 叶宽 / height 叶高
##
## 【洞口必须留足重叠】两圈吸附到各自的栅格（近圈 9.75 m，远圈 32.5 m），
## 中心每轴最多能差 9.75/2 + 32.5/2 ≈ 21.1 m。洞口若正好等于近圈的覆盖范围，
## 这个偏移就会在某一侧留出一条**光秃的缝**。
## 按 clipmap 的同一条规矩取「重叠 ≥ 2 倍最大偏移」（见 Clipmap.HOLE_SHRINK_CELLS）。
## 近圈收到 55 m 后：近圈 snap 6.875 m、远圈 32.5 m，每轴最大偏移
## 6.875/2 + 32.5/2 ≈ 19.7 m，需要 55 − hole ≥ 39.4，故 hole ≤ 15.6，取 14 m。
## 代价只是 14–55 m 这一带两圈同时长草（密一点，无害），换来脚边不会出现巨叶。
const RINGS := [
	{
		"tufts": 14000, "blades": 4, "tuft_radius": 0.17,
		"extent": 55.0, "hole": 0.0,
		"segments": 2, "width": 0.13, "height": 0.34,
	},
	{
		# 远圈不成丛：4.7 m 株距下丛与丛之间根本挨不上，成丛只是白花三角面。
		# 单片给宽一点、高一点顶替覆盖率，几十米外读不出单株。
		"tufts": 16000, "blades": 1, "tuft_radius": 0.0,
		"extent": 260.0, "hole": 14.0,
		"segments": 1, "width": 0.30, "height": 0.62,
	},
]

## 丛内叶片的最大倾角。全部竖直会像一排钉子，散开成扇形才像一丛草。
const TUFT_TILT_MAX := deg_to_rad(16.0)

var material: ShaderMaterial
var _rings: Array[Ring] = []
var _time := 0.0


func _ready() -> void:
	material = ShaderMaterial.new()
	material.shader = load("res://client/render/grass.gdshader")
	material.set_shader_parameter("ramp", Toon.ramp_near())

	for cfg: Dictionary in RINGS:
		var mesh := _blade_mesh(
			int(cfg["segments"]), float(cfg["width"]), float(cfg["height"])
		)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		_scatter(mm, cfg)

		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.material_override = material
		# 草不投影：几万株草的阴影通道会把三角面预算直接翻倍，而卡通草的
		# 自阴影几乎看不出来。只接收阴影就够。
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# 顶点 y 由着色器给，Godot 不知道，必须手工给包围盒，否则相机一转
		# 整圈草就被视锥剔除。y 范围要盖住全疆高程。
		var e := float(cfg["extent"])
		mi.custom_aabb = AABB(Vector3(-e, -600.0, -e), Vector3(e * 2.0, 9800.0, e * 2.0))
		mi.name = "Ring_%.0fm" % e
		add_child(mi)

		var r := Ring.new()
		r.node = mi
		r.extent = e
		# 吸附步长取覆盖范围的 1/16：步长太大草会成片跳变，太小则失去吸附的意义
		r.snap = e / 8.0
		_rings.append(r)


## 一株草：十字双面片，顶点沿高度渐窄。
## 双面片而不是单片，是为了从任何角度看过去都有厚度；渐窄是为了叶尖收成尖。
func _blade_mesh(segments: int, width: float, height: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()

	for quad in 2:
		var ang := float(quad) * PI * 0.5
		var dir := Vector3(cos(ang), 0.0, sin(ang))
		var base := verts.size()
		for s in segments + 1:
			var t := float(s) / float(segments)
			# 渐窄：叶尖收到 18% 宽
			var hw := width * 0.5 * (1.0 - t * 0.82)
			verts.append(-dir * hw + Vector3(0.0, t * height, 0.0))
			verts.append(dir * hw + Vector3(0.0, t * height, 0.0))
			uvs.append(Vector2(0.0, t))
			uvs.append(Vector2(1.0, t))
		for s in segments:
			var a := base + s * 2
			idx.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


## 撒点。丛心用抖动网格（纯随机会出现明显的空洞与结块，抖动网格既均匀又不规则），
## 每个丛心周围再撒 blades 片。可选挖掉中间 hole×hole（半径，米）的方形。
## 实例的 y 一律为 0，真实高度由着色器加。
##
## 先收进数组再一次性写进 MultiMesh：挖洞后实际片数少于 tufts×blades，
## 而 instance_count 必须在 set_instance_transform 之前定下来。
func _scatter(mm: MultiMesh, cfg: Dictionary) -> void:
	var tufts := int(cfg["tufts"])
	var blades := int(cfg["blades"])
	var radius := float(cfg["tuft_radius"])
	var extent := float(cfg["extent"])
	var hole := float(cfg["hole"])

	var side := int(ceil(sqrt(float(tufts))))
	var step := extent * 2.0 / float(side)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x8ACE  # 固定种子：每次启动的草分布一致，便于比对截图
	var placed: Array[Transform3D] = []
	var n := 0
	for gz in side:
		for gx in side:
			if n >= tufts:
				break
			n += 1
			var cx := -extent + (float(gx) + rng.randf()) * step
			var cz := -extent + (float(gz) + rng.randf()) * step
			# 洞里不撒。判据用**方形**（切比雪夫距离）而不是圆：
			# 近圈的覆盖范围本身就是方形，用圆会在四个角上留下秃缝。
			var skip := hole > 0.0 and maxf(absf(cx), absf(cz)) < hole
			for b in blades:
				# 随机数无论跳不跳都要抽掉，否则挖洞会改变后面所有丛的分布，
				# 固定种子就失去「换个参数还能比对截图」的意义。
				var ang := rng.randf() * TAU
				var r := radius * sqrt(rng.randf())  # sqrt 让丛内均匀而不是挤在中心
				var yaw := rng.randf() * TAU
				var tilt := rng.randf() * TUFT_TILT_MAX
				var tilt_dir := rng.randf() * TAU
				if skip:
					continue
				var t := Transform3D()
				# 先绕自身竖轴转（决定叶片朝哪面），再倾倒（决定这一丛的扇形）
				t.basis = Basis(Vector3(cos(tilt_dir), 0.0, sin(tilt_dir)), tilt) \
					* Basis(Vector3.UP, yaw)
				t.origin = Vector3(cx + cos(ang) * r, 0.0, cz + sin(ang) * r)
				placed.append(t)

	mm.instance_count = placed.size()
	for i in placed.size():
		mm.set_instance_transform(i, placed[i])
	mm.visible_instance_count = placed.size()


## 诊断模式，取值见 grass.gdshader 的 debug_mode。
## 排查「草看不见」时的固定顺序：先 4（几何在不在）→ 再 3（落地高度对不对）
## → 再 2（生长条件把它掐掉了没有）→ 最后才是配色。
func set_debug(mode: int) -> void:
	material.set_shader_parameter("debug_mode", mode)


func _process(delta: float) -> void:
	_time += delta
	material.set_shader_parameter("wind_time", _time)


## 跟随玩家吸附。传入相机/玩家的局部坐标。
func snap_to(focus: Vector3) -> void:
	for r: Ring in _rings:
		r.node.position = Vector3(
			snappedf(focus.x, r.snap), 0.0, snappedf(focus.z, r.snap)
		)


## 按环境档案设置草色与长势。
## 档案由 RegionEnv.resolve() 一次算好（季节基表 + 地标覆写 + 派生量），
## 这里只负责读 —— 以前长势的几个派生量是在这个函数里另算一遍的，
## 和 main.gd 那边各算各的，迟早漂移。
func apply_env(env: Dictionary) -> void:
	var hex := String(env["grass"])
	material.set_shader_parameter("grass_color", Color(hex).srgb_to_linear())
	# 叶尖明显提亮、根部只压一点：地表基色用的是同一套季节色，
	# 草若不比地表亮就会糊成一片，看不出「草铺在地上」这一层。
	material.set_shader_parameter(
		"tip_color", Color(hex).lightened(0.42).srgb_to_linear()
	)
	# 【根部只压一点点】原来压 0.28，加上 light() 里还有一道 k *= mix(0.82, 1.0, v_up)，
	# 根部被**压了两次**（0.72 × 0.82 ≈ 0.59）。叶片收窄成丛之后可见面积大半是中下段，
	# 于是整丛草读起来比它脚下的地表还暗 —— 草原变成「亮草坪上一丛丛深色杂草」，
	# 明暗关系正好反了。两道压暗各留一点就够，这里降到 0.12。
	material.set_shader_parameter(
		"root_color", Color(hex).darkened(0.12).srgb_to_linear()
	)

	# 长势三项的算法与理由都在 RegionEnv.resolve() 里，这里只搬运。
	material.set_shader_parameter("height_scale", float(env["grass_height_scale"]))
	material.set_shader_parameter("alt_min", float(env["grass_alt_min"]))
	material.set_shader_parameter("patch_bias", float(env["grass_patch_bias"]))
