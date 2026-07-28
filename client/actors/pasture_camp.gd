class_name PastureCamp
extends Node3D
## PastureCamp —— 那拉提夏牧场营地（本工程第一处「精修建模」场景）。
##
## 组成：3 座毡房（红门框朝东）+ 羊圈 + 羊群（游走/低头吃草的轻量 AI）
##   + 2 匹伊犁马（其一备鞍）+ 营地边缘的雪岭云杉。
##
## 两条工程红线：
##   1. 落地：所有物件的高度每帧由 TerrainHeight.surface_height 复算
##      （与 GPU 地形逐比特一致的细节层），否则高海拔细节起伏上会悬空/陷土。
##      细节层随视距淡出，所以落地必须按当帧相机距离重算 —— 静态物件也一样。
##   2. 浮动原点：锚点存经纬度真值，每帧用 GeoRef.geo_to_local 重算局部位置 ——
##      幂等，天然兼容重锚与 _goto_region 里不发信号的 set_origin（GeoRef 头注的
##      「长期存储一律存经纬度」原则）。羊的位置是营地局部量，不存经纬度。

const SHEEP_COUNT := 70
const HERD_CENTER := Vector2(-4.0, 18.0)
const HERD_R_MIN := 6.0
## 上限保证羊群离默认贴地机位（z=60）≥16 m，不会有半只羊贴到画框边缘
const HERD_R_MAX := 26.0
## 羊不进毡房 4.2 m 半径以内（营内三座的局部坐标）
const YURT_DISCS: Array[Vector2] = [Vector2(-16.0, 42.0), Vector2(17.0, 36.0), Vector2(-4.0, 24.0)]
## 钉住的羊：前三只是默认机位的前景羊，后四只圈在羊圈里（牧场的日常景象）
const PINNED_SHEEP: Array[Vector2] = [
	Vector2(-6.0, 45.0), Vector2(-2.5, 47.5), Vector2(-9.0, 41.0),
	Vector2(-34.0, 4.0), Vector2(-30.0, 7.5), Vector2(-33.5, 9.0), Vector2(-29.5, 3.5)]
const SKIP_DIST := 6000.0  ## 相机比此更远时羊群休眠（看不见就不算）

var _agents: Array[Dictionary] = []
var _sheep_mm: MultiMesh
var _statics: Array[Dictionary] = []  ## {node: Node3D, sink: float}
var _rng := RandomNumberGenerator.new()
var _last_cam_x := 0.0
var _last_cam_z := 0.0
var _anchor_lon := 0.0
var _anchor_lat := 0.0


## 用经纬度真值重算局部位置（幂等；浮动原点或静默 set_origin 后都正确）。
func _sync_anchor() -> void:
	var o := GeoRef.geo_to_local(_anchor_lon, _anchor_lat)
	position.x = o.x
	position.z = o.z
	position.y = 0.0


func _ready() -> void:
	_rng.seed = 20260728


## 在那拉提中心铺开营地。region 需含 lon/lat（shared/data/regions.json 的结构）。
func build(region: Dictionary) -> void:
	_anchor_lon = float(region["lon"])
	_anchor_lat = float(region["lat"])
	_sync_anchor()

	# 布局围绕默认贴地机位（正南 60 m 朝北）构图：
	# 毡房群在 20–45 m 的中近景，羊群铺满 30 m 内的草甸，云杉压住画框边缘。
	# 红门框保持朝东（交接文档的构造约定），同时略转向南，
	# 让默认机位能看到最精雕细琢的门脸 —— 朝向角是 yaw，门框本在 +X。
	_place_static(CampModels.mesh("yurt"), PropFactory.OUTLINE_BUILDING,
		Vector3(-16.0, 0, 42.0), -0.75, 1.0, 0.06)
	_place_static(CampModels.mesh("yurt"), PropFactory.OUTLINE_BUILDING,
		Vector3(17.0, 0, 36.0), -1.0, 0.9, 0.06)
	_place_static(CampModels.mesh("yurt"), PropFactory.OUTLINE_BUILDING,
		Vector3(-4.0, 0, 24.0), -1.25, 0.82, 0.06)
	_place_static(CampModels.mesh("fold"), PropFactory.OUTLINE_BUILDING,
		Vector3(-32.0, 0, 6.0), 0.9, 1.0, 0.05)
	_place_static(CampModels.mesh("horse_saddled"), PropFactory.OUTLINE_ANIMAL,
		Vector3(10.0, 0, 30.0), -2.2, 1.0, 0.03)
	_place_static(CampModels.mesh("horse"), PropFactory.OUTLINE_ANIMAL,
		Vector3(13.0, 0, 27.0), 2.4, 0.97, 0.03)
	# 云杉：营地四周，大小错开（确定性排布，不加随机）
	var spruces: Array = [
		[-34.0, 40.0, 1.25], [-42.0, 16.0, 1.0], [32.0, 30.0, 1.15],
		[40.0, 6.0, 0.9], [-22.0, -16.0, 1.3], [28.0, -12.0, 0.95]]
	for s: Array in spruces:
		_place_static(CampModels.mesh("spruce"), PropFactory.OUTLINE_BUILDING,
			Vector3(s[0], 0, s[1]), s[0] * 0.37, s[2], 0.12)

	# 炊烟：三座毡房各一缕（共用材质，相位按位置自动错开）
	_place_smoke(Vector3(-16.0, 0, 42.0), 1.0)
	_place_smoke(Vector3(17.0, 0, 36.0), 0.9)
	_place_smoke(Vector3(-4.0, 0, 24.0), 0.82)

	_build_flock()


func _place_static(mesh: ArrayMesh, outline: float, offset: Vector3, yaw: float, scale: float, sink: float) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = PropFactory.material_for(outline)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.position = offset
	mi.rotation.y = yaw
	mi.scale = Vector3.ONE * scale
	add_child(mi)
	_statics.append({"node": mi, "sink": sink})


## 草地踩踏圈掩码（每帧由 main 写入草材质；浮动原点下必须是当帧局部坐标）。
func tramp_mask() -> PackedVector4Array:
	return PackedVector4Array([
		Vector4(position.x - 16.0, position.z + 42.0, 3.4, 0.88),
		Vector4(position.x + 17.0, position.z + 36.0, 3.1, 0.88),
		Vector4(position.x - 4.0, position.z + 24.0, 2.8, 0.88),
		Vector4(position.x - 32.0, position.z + 6.0, 7.2, 0.72),
		Vector4(position.x + 10.0, position.z + 30.0, 1.4, 0.5),
		Vector4(position.x + 13.0, position.z + 27.0, 1.4, 0.5),
	])


static var _smoke_mat: ShaderMaterial


func _place_smoke(yurt_offset: Vector3, yurt_scale: float) -> void:
	if _smoke_mat == null:
		_smoke_mat = ShaderMaterial.new()
		_smoke_mat.shader = load("res://client/render/smoke.gdshader")
		_smoke_mat.set_shader_parameter("grad_lut", TerrainHeight.lut_texture())
	var quad := QuadMesh.new()
	quad.size = Vector2(1.7, 3.4)
	var mi := MeshInstance3D.new()
	mi.mesh = quad
	mi.material_override = _smoke_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 烟柱底部贴住天窗毡盖顶（4.11 倍毡房缩放），略微上浮避免穿插。
	# 注册进 _statics：高度随地表复算（负 sink = 离地上浮量），与毡房同源。
	mi.position = yurt_offset
	mi.scale = Vector3.ONE * yurt_scale
	add_child(mi)
	_statics.append({"node": mi, "sink": -(4.11 + 1.6) * yurt_scale})


func _build_flock() -> void:
	_sheep_mm = MultiMesh.new()
	_sheep_mm.transform_format = MultiMesh.TRANSFORM_3D
	_sheep_mm.mesh = CampModels.mesh("sheep")
	_sheep_mm.instance_count = SHEEP_COUNT
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _sheep_mm
	mmi.material_override = PropFactory.material_for(PropFactory.OUTLINE_ANIMAL)
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# 实例散布在营地周边 50 m，AABB 给足，避免视锥剔除整群消失
	mmi.custom_aabb = AABB(Vector3(-140, -10, -140), Vector3(280, 40, 280))
	add_child(mmi)

	for i in SHEEP_COUNT:
		var pinned := i < PINNED_SHEEP.size()
		var a := _rng.randf() * TAU
		var r := HERD_R_MIN + _rng.randf() * (HERD_R_MAX - HERD_R_MIN)
		var p := PINNED_SHEEP[i] if pinned else HERD_CENTER + Vector2(cos(a), sin(a)) * r
		_agents.append({
			"p": p,
			"h": _rng.randf() * TAU,
			"t": 1.0e9 if pinned else _rng.randf_range(2.0, 7.0),
			"st": 0,
			"tx": p,
			"sp": _rng.randf_range(0.38, 0.55),
			"ph": _rng.randf() * TAU,
			"s": _rng.randf_range(0.9, 1.08),
			"pitch": 0.0,
			"roll": 0.0,
		})


## main._process 每帧调用。cam_pos 是当前相机局部坐标。
func tick(delta: float, cam_pos: Vector3) -> void:
	_sync_anchor()
	var cam_xz := Vector2(cam_pos.x, cam_pos.z)
	_last_cam_x = cam_xz.x
	_last_cam_z = cam_xz.y
	# 静态物件落地（细节层随视距淡出，必须按当帧视距重算）
	for s: Dictionary in _statics:
		var node: Node3D = s["node"]
		var wx: float = position.x + node.position.x
		var wz: float = position.z + node.position.z
		node.position.y = TerrainHeight.surface_height(wx, wz, cam_xz.distance_to(Vector2(wx, wz))) - float(s["sink"])

	if position.distance_to(cam_pos) > SKIP_DIST:
		return
	var t := Time.get_ticks_msec() * 0.001
	for i in _agents.size():
		_tick_sheep(_agents[i], delta, t, cam_xz)
		_sheep_mm.set_instance_transform(i, _sheep_transform(_agents[i]))


func _tick_sheep(a: Dictionary, delta: float, t: float, cam_xz: Vector2) -> void:
	a["t"] = float(a["t"]) - delta
	if int(a["st"]) == 0:
		# 吃草：头缓慢埋低/抬起（刚性网格，整体微俯即可）
		var want := 0.16 if sin(t * 0.6 + float(a["ph"])) > -0.3 else 0.0
		a["pitch"] = lerpf(float(a["pitch"]), want, minf(1.0, delta * 2.0))
		a["roll"] = 0.0
		if float(a["t"]) <= 0.0:
			a["tx"] = _pick_graze_target()
			a["st"] = 1
			a["t"] = 20.0
	else:
		var p: Vector2 = a["p"]
		var to: Vector2 = a["tx"] - p
		var dist := to.length()
		var want_h := to.angle()
		var h: float = a["h"]
		var dh := wrapf(want_h - h, -PI, PI)
		h += clampf(dh, -2.4 * delta, 2.4 * delta)
		a["h"] = h
		var sp: float = a["sp"]
		a["p"] = p + Vector2(cos(h), sin(h)) * sp * delta
		# 走起来的小摇摆 + 抬头
		a["roll"] = sin(t * 7.0 + float(a["ph"])) * 0.05
		a["pitch"] = lerpf(float(a["pitch"]), -0.03, minf(1.0, delta * 3.0))
		if dist < 0.6 or float(a["t"]) <= 0.0:
			a["st"] = 0
			a["t"] = _rng.randf_range(3.0, 8.0)


func _pick_graze_target() -> Vector2:
	for _try in 8:
		var ang := _rng.randf() * TAU
		var r := HERD_R_MIN + _rng.randf() * (HERD_R_MAX - HERD_R_MIN)
		var p := HERD_CENTER + Vector2(cos(ang), sin(ang)) * r
		var clear := true
		for d: Vector2 in YURT_DISCS:
			if p.distance_to(d) < 4.2:
				clear = false
				break
		if clear:
			return p
	return HERD_CENTER


## 由姿态算出实例变换：位置落地 + 朝向 + 坡度对齐 + 吃草俯角 + 摇摆。
func _sheep_transform(a: Dictionary) -> Transform3D:
	var p: Vector2 = a["p"]
	var wx := position.x + p.x
	var wz := position.z + p.y
	var cam_d := Vector2(wx, wz).distance_to(Vector2(_last_cam_x, _last_cam_z))
	var y := TerrainHeight.surface_height(wx, wz, cam_d) + 0.02

	var yaw := -float(a["h"])  ## 局部 +X 朝东，heading 逆时针为正 → 绕 Y 取负
	var basis := Basis.from_euler(Vector3(0, yaw, 0))
	basis = basis * Basis.from_euler(Vector3(0, 0, -float(a["pitch"])))
	basis = basis * Basis.from_euler(Vector3(float(a["roll"]), 0, 0))
	# 部分贴合坡度（0.55），脚不至于明显悬空
	var n := TerrainHeight.dem_normal(wx, wz, 30.0)
	var axis := Vector3.UP.cross(n)
	if axis.length() > 0.001:
		basis = Basis(axis.normalized(), acos(clampf(Vector3.UP.dot(n), -1.0, 1.0)) * 0.55) * basis
	var s: float = a["s"]
	basis = basis.scaled(Vector3.ONE * s)
	return Transform3D(basis, Vector3(p.x, y - position.y, p.y))
