class_name PropFactory
extends RefCounted
## PropFactory —— 程序化建模工具包。
##
## 与 three.js 原型（docs/reference/prototype.dc.html）同一结构：
## 每种物件的所有部件合并成**一个带顶点色的 ArrayMesh**，再实例化铺开。
## 材质链只有两套：prop_toon.gdshader（顶点色 + 四阶 ramp）
##   + prop_outline.gdshader（next_pass 反壳描边，宽度按类别区分）。
##
## 部件用 Transform3D 摆位，法线随逆转置矩阵变换，合批后可平滑着色。
## lathe() 是毡房弧形墙与穹顶的关键：内置图元给不出旋成曲面。

const TOON_SHADER := preload("res://client/render/prop_toon.gdshader")
const OUTLINE_SHADER := preload("res://client/render/prop_outline.gdshader")

## 描边宽度（交接文档 §07）：动物 0.022–0.028，建筑 0.030。
const OUTLINE_ANIMAL := 0.024
const OUTLINE_BUILDING := 0.030

static var _mat_cache: Dictionary = {}


## 按描边宽度取共用材质链（底 + next_pass 反壳）。
static func material_for(outline_width: float) -> ShaderMaterial:
	if _mat_cache.has(outline_width):
		return _mat_cache[outline_width]
	var base := ShaderMaterial.new()
	base.shader = TOON_SHADER
	base.set_shader_parameter("ramp", Toon.ramp_near())
	var outline := ShaderMaterial.new()
	outline.shader = OUTLINE_SHADER
	outline.set_shader_parameter("width", outline_width)
	base.next_pass = outline
	_mat_cache[outline_width] = base
	return base


## 摆位辅助：位置 + 欧拉角（弧度）+ 缩放。
static func xf(pos: Vector3, euler := Vector3.ZERO, scl := Vector3.ONE) -> Transform3D:
	return Transform3D(Basis.from_euler(euler).scaled(scl), pos)


## 打包一个部件：图元/旋成面的数组 + 摆位 + 顶点色。
static func part(arrays: Array, xform: Transform3D, color: Color) -> Dictionary:
	return {"arrays": arrays, "xform": xform, "color": color}


## ── 图元（直接取 Godot PrimitiveMesh 的生成结果，只保留 顶点/法线/索引） ──

static func prim_box(size: Vector3) -> Array:
	var m := BoxMesh.new()
	m.size = size
	return m.surface_get_arrays(0)


static func prim_sphere(radius: float, segs := 10, rings := 8) -> Array:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = segs
	m.rings = rings
	return m.surface_get_arrays(0)


static func prim_cylinder(r_top: float, r_bottom: float, height: float, segs := 8, capped := true) -> Array:
	var m := CylinderMesh.new()
	m.top_radius = r_top
	m.bottom_radius = r_bottom
	m.height = height
	m.radial_segments = segs
	m.rings = 1
	m.cap_top = capped
	m.cap_bottom = capped
	return m.surface_get_arrays(0)


static func prim_cone(radius: float, height: float, segs := 8) -> Array:
	return prim_cylinder(0.001, radius, height, segs)


static func prim_torus(ring_radius: float, tube_radius: float, ring_segs := 16, tube_segs := 8) -> Array:
	var m := TorusMesh.new()
	m.inner_radius = tube_radius
	m.outer_radius = ring_radius
	m.rings = ring_segs
	m.ring_segments = tube_segs
	return m.surface_get_arrays(0)


## 旋成面：profile 为自下而上的 (半径, 高度) 折线，绕 Y 轴旋转 segments 份。
## 法线沿剖面切线的垂直方向平滑过渡；首尾半径可为 0（封口尖点）。
static func lathe(profile: Array[Vector2], segments: int) -> Array:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var n := profile.size()
	for i in n:
		var p := profile[i]
		# 剖面切线：中心差分；端点用前/后差分
		var t: Vector2
		if i == 0:
			t = (profile[1] - profile[0]).normalized()
		elif i == n - 1:
			t = (profile[n - 1] - profile[n - 2]).normalized()
		else:
			t = (profile[i + 1] - profile[i - 1]).normalized()
		# 剖面外法线（径向分量, y 分量）；切线朝上行进时外法线朝外
		var nrad := Vector2(t.y, -t.x)
		for j in segments + 1:
			var a := TAU * float(j) / float(segments)
			var ca := cos(a)
			var sa := sin(a)
			verts.append(Vector3(ca * p.x, p.y, sa * p.x))
			normals.append(Vector3(ca * nrad.x, nrad.y, sa * nrad.x).normalized())
	for i in n - 1:
		for j in segments:
			var i0 := i * (segments + 1) + j
			var i1 := i0 + 1
			var i2 := i0 + segments + 2
			var i3 := i0 + segments + 1
			# 外表面逆时针（从外侧看）
			indices.append_array([i0, i2, i1, i0, i3, i2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	return arrays


## 合批：所有部件压进一个 ArrayMesh，顶点色携带反照率。
static func merge(parts: Array) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	for p: Dictionary in parts:
		var arrays: Array = p["arrays"]
		var src_v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var src_n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var src_i: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var xform: Transform3D = p["xform"]
		var col: Color = p["color"]
		var nml_xf := xform.basis.inverse().transposed()
		var base := verts.size()
		for i in src_v.size():
			verts.append(xform * src_v[i])
			normals.append((nml_xf * src_n[i]).normalized())
			colors.append(col)
		for idx in src_i:
			indices.append(base + idx)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
