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

## [实例数, 覆盖半径(米), 叶片段数, 叶宽, 叶高]
## 段数决定草叶能不能弯：近圈 3 段能被风吹出弧线，远圈 1 段是直片，够用。
const RINGS := [
	{"count": 21000, "extent": 78.0, "segments": 3, "width": 0.24, "height": 0.55},
	{"count": 12000, "extent": 260.0, "segments": 1, "width": 0.52, "height": 1.05},
]

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
		mm.instance_count = int(cfg["count"])
		_scatter(mm, float(cfg["extent"]))

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


## 在方形范围里撒点。用抖动网格而不是纯随机：纯随机会出现明显的空洞与结块，
## 抖动网格既均匀又不规则。实例的 y 一律为 0，真实高度由着色器加。
func _scatter(mm: MultiMesh, extent: float) -> void:
	var n := mm.instance_count
	var side := int(ceil(sqrt(float(n))))
	var step := extent * 2.0 / float(side)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x8ACE  # 固定种子：每次启动的草分布一致，便于比对截图
	var t := Transform3D()
	var i := 0
	for gz in side:
		for gx in side:
			if i >= n:
				break
			var x := -extent + (float(gx) + rng.randf()) * step
			var z := -extent + (float(gz) + rng.randf()) * step
			t.basis = Basis(Vector3.UP, rng.randf() * TAU)
			t.origin = Vector3(x, 0.0, z)
			mm.set_instance_transform(i, t)
			i += 1
	mm.visible_instance_count = n


func _process(delta: float) -> void:
	_time += delta
	material.set_shader_parameter("wind_time", _time)


## 跟随玩家吸附。传入相机/玩家的局部坐标。
func snap_to(focus: Vector3) -> void:
	for r: Ring in _rings:
		r.node.position = Vector3(
			snappedf(focus.x, r.snap), 0.0, snappedf(focus.z, r.snap)
		)


## 按季节与地标设置草色与长势。
func apply_env(env: Dictionary, region: Dictionary) -> void:
	var hex := String(env["grass"])
	material.set_shader_parameter("grass_color", Color(hex).srgb_to_linear())
	# 叶尖明显提亮、根部只压一点：地表基色用的是同一套季节色，
	# 草若不比地表亮就会糊成一片，看不出「草铺在地上」这一层。
	material.set_shader_parameter(
		"tip_color", Color(hex).lightened(0.42).srgb_to_linear()
	)
	material.set_shader_parameter(
		"root_color", Color(hex).darkened(0.28).srgb_to_linear()
	)

	# 草的高矮直接反映草场质量：那拉提承载 1.8×，草深过膝；
	# 冬窝子 0.6×，草稀且矮。这是数值表在画面上的直接体现，不是随手调的。
	var cap := float(region.get("carrying_capacity", 1.0))
	var density := float(env.get("grass_density", 1.0))
	material.set_shader_parameter("height_scale", clampf(cap * density, 0.15, 1.9))

	# 干旱地标的草线更高（低处是戈壁），湿润地标可以一直长到河谷底
	var water := float(region["resource_mul"]["water"])
	material.set_shader_parameter("alt_min", lerpf(1500.0, 350.0, clampf(water, 0.0, 1.6) / 1.6))
	material.set_shader_parameter("patch_bias", lerpf(0.55, 0.05, clampf(cap, 0.5, 1.8) / 1.8))
