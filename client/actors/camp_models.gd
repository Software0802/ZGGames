class_name CampModels
extends RefCounted
## CampModels —— 那拉提夏牧场营地的程序化模型库。
##
## 结构依据交接文档 docs/reference/handoff.dc.html：
##   「柳木哈那（菱格围墙）+ 乌尼（辐条）+ 香纳勒克（天窗圈）。红色门框朝东。
##     围毡下缘压蓝色织带。原型已按此结构建模，可直接细化。」
## 本文件即对原型（prototype.dc.html yurtGeo/sheepGeo/horseGeo/foldGeo）的细化：
## 毡房墙与穹顶改用旋成面（lathe）做出真实弧度，部件全部对齐六色色板。
##
## 每种物件返回单个带顶点色的 ArrayMesh，配合 PropFactory 的共用材质链，
## 与原型同一合批策略：90 只羊 = 2 次 draw call（含描边）。

const FELT := Color(0.949, 0.925, 0.878)          ## 羊毛毡白（色板）
const FELT_ROOF := Color(0.906, 0.870, 0.796)     ## 顶毡略深，拉开墙/顶层次
const WOOL := Color(0.937, 0.906, 0.839)          ## 羊身暖白
const WOOD := Color(0.478, 0.322, 0.188)          ## 沙枣褐（色板）
const WOOD_DARK := Color(0.352, 0.231, 0.133)
const RED := Color(0.698, 0.227, 0.227)           ## 石榴红（色板）
const INDIGO := Color(0.180, 0.361, 0.541)        ## 天山靛（色板）
const GOLD := Color(0.851, 0.643, 0.255)          ## 錾金（色板）
const DARK := Color(0.231, 0.200, 0.173)          ## 羊头/四肢的深褐
const MUZZLE := Color(0.847, 0.804, 0.729)        ## 吻部浅驼
const COAT := Color(0.420, 0.290, 0.200)          ## 枣红马
const COAT_DARK := Color(0.165, 0.125, 0.094)     ## 鬃尾
const GREEN_HI := Color(0.247, 0.420, 0.290)      ## 草原绿（色板）—— 树冠受光层
const GREEN_MID := Color(0.184, 0.322, 0.220)
const GREEN_LO := Color(0.145, 0.259, 0.176)      ## 树冠背光底层

static var _cache: Dictionary = {}


static func mesh(kind: String) -> ArrayMesh:
	if not _cache.has(kind):
		_cache[kind] = _build(kind)
	return _cache[kind]


static func _build(kind: String) -> ArrayMesh:
	match kind:
		"yurt": return _yurt()
		"sheep": return _sheep()
		"horse": return _horse(false)
		"horse_saddled": return _horse(true)
		"fold": return _fold()
		"spruce": return _spruce()
	push_error("CampModels: 未知模型 " + kind)
	return ArrayMesh.new()


## 圆柱按两点连线摆位（辐条、围栏横杆用）。
static func _cyl_between(p1: Vector3, p2: Vector3, r: float, segs := 6) -> Dictionary:
	var dir := p2 - p1
	var mid := (p1 + p2) * 0.5
	var basis := Basis.looking_at(dir.normalized(), Vector3.UP) * Basis.from_euler(Vector3(PI * 0.5, 0.0, 0.0))
	return PropFactory.part(PropFactory.prim_cylinder(r, r, dir.length(), segs), Transform3D(basis, mid), WOOD)


# ── 毡房（直径 5 m 级，红门框朝 +X 即朝东） ──

static func _yurt() -> ArrayMesh:
	var P := PropFactory
	var parts: Array = []
	# 墙体：微鼓的弧形（柳木哈那外覆毛毡），旋成面
	parts.append(P.part(P.lathe([
		Vector2(2.40, 0.02), Vector2(2.50, 0.35), Vector2(2.56, 0.90),
		Vector2(2.57, 1.35), Vector2(2.52, 1.85), Vector2(2.46, 2.00)], 24),
		P.xf(Vector3.ZERO), FELT))
	# 穹顶：旋成面收拢到天窗圈
	parts.append(P.part(P.lathe([
		Vector2(2.46, 2.00), Vector2(2.38, 2.45), Vector2(2.12, 2.90),
		Vector2(1.68, 3.28), Vector2(1.15, 3.52), Vector2(0.62, 3.62)], 24),
		P.xf(Vector3.ZERO), FELT_ROOF))
	# 檐口压绳（墙顶一圈深色收边）
	parts.append(P.part(P.lathe([Vector2(2.475, 1.96), Vector2(2.49, 2.06)], 24),
		P.xf(Vector3.ZERO), WOOD_DARK))
	# 香纳勒克（天窗圈）+ 十字撑
	parts.append(P.part(P.prim_torus(0.62, 0.09, 20, 8), P.xf(Vector3(0, 3.63, 0)), WOOD))
	parts.append(P.part(P.prim_box(Vector3(1.14, 0.05, 0.07)), P.xf(Vector3(0, 3.60, 0)), WOOD))
	parts.append(P.part(P.prim_box(Vector3(0.07, 0.05, 1.14)), P.xf(Vector3(0, 3.60, 0)), WOOD))
	# 天窗毡盖（防风的小帽子）
	parts.append(P.part(P.lathe([
		Vector2(0.52, 3.68), Vector2(0.47, 3.90), Vector2(0.14, 4.07), Vector2(0.001, 4.11)], 16),
		P.xf(Vector3.ZERO), FELT))
	# 乌尼辐条：12 根，从天窗圈外缘搭到檐口
	for i in 12:
		var a := TAU * float(i) / 12.0
		var p1 := Vector3(cos(a) * 0.64, 3.55, sin(a) * 0.64)
		var p2 := Vector3(cos(a) * 2.32, 2.04, sin(a) * 2.32)
		parts.append(_cyl_between(p1, p2, 0.028))
	# 石榴红腰带 + 上下錾金压边
	parts.append(P.part(P.lathe([
		Vector2(2.575, 1.28), Vector2(2.60, 1.33), Vector2(2.60, 1.71), Vector2(2.575, 1.76)], 24),
		P.xf(Vector3.ZERO), RED))
	parts.append(P.part(P.lathe([Vector2(2.605, 1.26), Vector2(2.605, 1.32)], 24), P.xf(Vector3.ZERO), GOLD))
	parts.append(P.part(P.lathe([Vector2(2.605, 1.72), Vector2(2.605, 1.78)], 24), P.xf(Vector3.ZERO), GOLD))
	# 靛蓝基带（围毡下缘压蓝色织带）+ 上缘金线
	parts.append(P.part(P.lathe([
		Vector2(2.50, 0.22), Vector2(2.535, 0.25), Vector2(2.535, 0.49), Vector2(2.50, 0.52)], 24),
		P.xf(Vector3.ZERO), INDIGO))
	parts.append(P.part(P.lathe([Vector2(2.545, 0.49), Vector2(2.545, 0.54)], 24), P.xf(Vector3.ZERO), GOLD))
	# 红色门框朝东（+X）：两柱 + 门楣 + 楣上金饰
	parts.append(P.part(P.prim_box(Vector3(0.10, 1.50, 0.10)), P.xf(Vector3(2.50, 0.75, 0.42)), RED))
	parts.append(P.part(P.prim_box(Vector3(0.10, 1.50, 0.10)), P.xf(Vector3(2.50, 0.75, -0.42)), RED))
	parts.append(P.part(P.prim_box(Vector3(0.10, 0.12, 0.96)), P.xf(Vector3(2.50, 1.53, 0)), RED))
	parts.append(P.part(P.prim_box(Vector3(0.07, 0.06, 0.80)), P.xf(Vector3(2.52, 1.63, 0)), GOLD))
	# 门扇（深木 + 红芯板 + 錾金铺首）与门槛
	parts.append(P.part(P.prim_box(Vector3(0.07, 1.42, 0.72)), P.xf(Vector3(2.47, 0.73, 0)), WOOD_DARK))
	parts.append(P.part(P.prim_box(Vector3(0.03, 1.02, 0.50)), P.xf(Vector3(2.515, 0.75, 0)), RED))
	parts.append(P.part(P.prim_sphere(0.04, 8, 6), P.xf(Vector3(2.54, 0.82, 0.24)), GOLD))
	parts.append(P.part(P.prim_box(Vector3(0.20, 0.07, 0.86)), P.xf(Vector3(2.45, 0.035, 0)), WOOD))
	return P.merge(parts)


# ── 阿勒泰大尾羊（朝 +X，尾脂双瓣是品种特征） ──

static func _sheep() -> ArrayMesh:
	var P := PropFactory
	var parts: Array = []
	# 躯干 + 绒球（蓬松感的层叠球）
	parts.append(P.part(P.prim_sphere(0.46, 12, 9), P.xf(Vector3(0, 0.68, 0), Vector3.ZERO, Vector3(1.28, 0.95, 1.0)), WOOL))
	for v: Vector3 in [Vector3(0.28, 0.88, 0.14), Vector3(-0.28, 0.86, -0.16), Vector3(0.02, 0.96, 0.28),
			Vector3(0.02, 0.93, -0.28), Vector3(-0.50, 0.72, 0), Vector3(0.50, 0.72, 0.08), Vector3(-0.12, 0.96, 0.02)]:
		parts.append(P.part(P.prim_sphere(0.23, 9, 7), P.xf(v), WOOL))
	# 头 + 吻 + 额绒 + 耳 + 眼
	parts.append(P.part(P.prim_sphere(0.19, 10, 8), P.xf(Vector3(0.74, 0.78, 0), Vector3.ZERO, Vector3(1.3, 1.0, 0.9)), DARK))
	parts.append(P.part(P.prim_sphere(0.105, 9, 7), P.xf(Vector3(0.92, 0.70, 0), Vector3.ZERO, Vector3(1.15, 0.85, 0.85)), MUZZLE))
	parts.append(P.part(P.prim_sphere(0.16, 9, 7), P.xf(Vector3(0.64, 0.94, 0), Vector3.ZERO, Vector3(1.0, 0.9, 1.0)), WOOL))
	for z in [0.19, -0.19]:
		parts.append(P.part(P.prim_sphere(0.085, 8, 6), P.xf(Vector3(0.72, 0.84, z), Vector3.ZERO, Vector3(0.7, 0.45, 1.4)), DARK))
	for z in [0.085, -0.085]:
		parts.append(P.part(P.prim_sphere(0.034, 8, 6), P.xf(Vector3(0.86, 0.82, z)), Color(0.05, 0.04, 0.03)))
	# 四肢
	for v: Vector3 in [Vector3(0.32, 0.22, 0.22), Vector3(0.32, 0.22, -0.22),
			Vector3(-0.32, 0.22, 0.22), Vector3(-0.32, 0.22, -0.22)]:
		parts.append(P.part(P.prim_cylinder(0.05, 0.045, 0.46, 6), P.xf(v), DARK))
	# 大尾：双瓣 + 尾垫（阿勒泰大尾羊的尾脂）
	for z in [0.10, -0.10]:
		parts.append(P.part(P.prim_sphere(0.15, 9, 7), P.xf(Vector3(-0.58, 0.72, z), Vector3.ZERO, Vector3(1.0, 0.9, 1.0)), WOOL))
	parts.append(P.part(P.prim_sphere(0.17, 9, 7), P.xf(Vector3(-0.60, 0.64, 0), Vector3.ZERO, Vector3(0.9, 0.85, 0.8)), WOOL))
	return P.merge(parts)


# ── 伊犁马（朝 +X；saddled 加鞍具） ──

static func _horse(saddled: bool) -> ArrayMesh:
	var P := PropFactory
	var parts: Array = []
	parts.append(P.part(P.prim_sphere(0.56, 12, 9), P.xf(Vector3(0, 1.20, 0), Vector3.ZERO, Vector3(1.7, 1.0, 0.95)), COAT))
	# 颈 + 头 + 吻
	parts.append(P.part(P.prim_cylinder(0.20, 0.30, 0.98, 8), P.xf(Vector3(0.82, 1.62, 0), Vector3(0, 0, -0.62)), COAT))
	parts.append(P.part(P.prim_sphere(0.24, 10, 8), P.xf(Vector3(1.26, 1.97, 0), Vector3.ZERO, Vector3(1.4, 0.85, 0.8)), COAT))
	parts.append(P.part(P.prim_sphere(0.11, 8, 6), P.xf(Vector3(1.52, 1.90, 0), Vector3.ZERO, Vector3(1.3, 0.8, 0.8)), COAT_DARK))
	# 耳 + 鬃 + 眼
	for z in [0.08, -0.08]:
		parts.append(P.part(P.prim_cone(0.05, 0.14, 6), P.xf(Vector3(1.13, 2.15, z), Vector3(0, 0, -0.15)), COAT))
	parts.append(P.part(P.prim_box(Vector3(0.58, 0.36, 0.09)), P.xf(Vector3(0.85, 2.0, 0), Vector3(0, 0, -0.62)), COAT_DARK))
	parts.append(P.part(P.prim_box(Vector3(0.16, 0.14, 0.08)), P.xf(Vector3(1.18, 2.18, 0), Vector3(0, 0, -0.5)), COAT_DARK))
	for z in [0.12, -0.12]:
		parts.append(P.part(P.prim_sphere(0.042, 8, 6), P.xf(Vector3(1.38, 2.02, z)), Color(0.05, 0.04, 0.03)))
	# 腿 + 蹄
	for v: Vector3 in [Vector3(0.50, 0.52, 0.28), Vector3(0.50, 0.52, -0.28),
			Vector3(-0.55, 0.52, 0.28), Vector3(-0.55, 0.52, -0.28)]:
		parts.append(P.part(P.prim_cylinder(0.085, 0.065, 1.0, 7), P.xf(v), COAT))
		parts.append(P.part(P.prim_cylinder(0.07, 0.075, 0.12, 7), P.xf(Vector3(v.x, 0.06, v.z)), COAT_DARK))
	# 尾（下垂的圆锥）
	parts.append(P.part(P.prim_cone(0.11, 0.78, 7), P.xf(Vector3(-1.02, 1.02, 0), Vector3(0, 0, 2.72)), COAT_DARK))
	if saddled:
		parts.append(P.part(P.prim_box(Vector3(0.52, 0.10, 0.64)), P.xf(Vector3(-0.02, 1.53, 0)), RED))
		parts.append(P.part(P.prim_box(Vector3(0.56, 0.04, 0.68)), P.xf(Vector3(-0.02, 1.50, 0)), GOLD))
		parts.append(P.part(P.prim_box(Vector3(0.42, 0.10, 0.40)), P.xf(Vector3(-0.02, 1.62, 0)), WOOD_DARK))
	return P.merge(parts)


# ── 羊圈（半径 6.5 m 木栅，朝 +X 留门） ──

static func _fold() -> ArrayMesh:
	var P := PropFactory
	var parts: Array = []
	const N := 20
	const R := 6.5
	const GATE := 0.22  ## 门洞半角（弧度）
	for i in N:
		var a := TAU * float(i) / float(N)
		if absf(a) < GATE or absf(TAU - a) < GATE:
			continue
		var wobble := 1.0 + 0.06 * sin(float(i) * 7.3)
		var col := WOOD if i % 2 == 0 else WOOD_DARK
		parts.append(P.part(P.prim_cylinder(0.055, 0.07, 1.15 * wobble, 6),
			P.xf(Vector3(cos(a) * R, 0.55 * wobble, sin(a) * R)), col))
		# 横杆：与下一根柱之间两道
		var a2 := TAU * float(i + 1) / float(N)
		if absf(a2) < GATE or absf(TAU - a2) < GATE:
			continue
		for h in [0.52, 0.94]:
			var p1 := Vector3(cos(a) * R, h, sin(a) * R)
			var p2 := Vector3(cos(a2) * R, h, sin(a2) * R)
			parts.append(_cyl_between(p1, p2, 0.035))
	# 门柱两根加高 + 门楣
	for z in [sin(GATE) * R, -sin(GATE) * R]:
		parts.append(P.part(P.prim_cylinder(0.07, 0.085, 1.5, 6), P.xf(Vector3(cos(GATE) * R, 0.72, z)), WOOD))
	parts.append(_cyl_between(Vector3(cos(GATE) * R, 1.42, -sin(GATE) * R), Vector3(cos(GATE) * R, 1.42, sin(GATE) * R), 0.05))
	return P.merge(parts)


# ── 雪岭云杉（那拉提林线的标志树种） ──

static func _spruce() -> ArrayMesh:
	var P := PropFactory
	var parts: Array = []
	parts.append(P.part(P.prim_cylinder(0.14, 0.22, 1.7, 7), P.xf(Vector3(0, 0.85, 0)), WOOD_DARK))
	parts.append(P.part(P.prim_cone(1.55, 1.7, 9), P.xf(Vector3(0, 2.4, 0)), GREEN_LO))
	parts.append(P.part(P.prim_cone(1.18, 1.5, 9), P.xf(Vector3(0, 3.45, 0)), GREEN_MID))
	parts.append(P.part(P.prim_cone(0.78, 1.4, 9), P.xf(Vector3(0, 4.4, 0)), GREEN_HI))
	return P.merge(parts)
