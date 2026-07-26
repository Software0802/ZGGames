class_name TerrainStreamer
extends Node
## 维护两张跟着玩家走的真实 DEM 高程窗口纹理，喂给 terrain.gdshader。
##
##   fine   —— L2 (z=12, 28 m/px)，6×6 瓦片 = 1536² px，覆盖约 43 km
##   coarse —— L0 (z=8, 447 m/px)，4×4 瓦片 = 1024² px，覆盖约 458 km
##
## 窗口按**瓦片**对齐而不是按米对齐：这样每块瓦片可以整块 blit 进去，
## 不需要重采样。着色器那边做完整的墨卡托逆投影，所以对齐方式不影响精度。
##
## 重建策略：分帧构建 + 双缓冲。窗口有整整一圈瓦片的余量（fine ≈ 7 km），
## 玩家跑到边缘之前一定建完，所以既不用线程（不会和 TerrainDB 的缓存打架），
## 也不会出现一次性的掉帧。

const FINE_LAYER := "L2"
const COARSE_LAYER := "L0"
const FINE_TILES := 6   ## 6×6 = 1536² px
const COARSE_TILES := 4 ## 4×4 = 1024² px
const TILE_PX := 256

## 每帧最多 blit 几块。36 块窗口 → 最多 6 帧建完。
const TILES_PER_FRAME := 6

class DemWindow:
	var layer_id: String
	var tiles: int
	var tex: ImageTexture
	var origin := Vector2i(-9999, -9999)   ## 窗口左上角瓦片坐标
	var zoom: int = 0

	func tile_min() -> Vector2:
		return Vector2(origin)

	func tile_span() -> Vector2:
		return Vector2(tiles, tiles)

var fine := DemWindow.new()
var coarse := DemWindow.new()

# 分帧构建状态
var _building: DemWindow = null
var _build_img: Image = null
var _build_origin := Vector2i.ZERO
var _build_queue: Array[Vector2i] = []

signal window_ready(which: String)

## 打开后每次窗口重建都报告数据来源与值域。定位「地形空洞」类问题时必开。
var verbose := false
var _stat_fallback := 0
var _stat_missing := 0


func _ready() -> void:
	fine.layer_id = FINE_LAYER
	fine.tiles = FINE_TILES
	coarse.layer_id = COARSE_LAYER
	coarse.tiles = COARSE_TILES
	for w: DemWindow in [fine, coarse]:
		var layer := TerrainDB.layer_by_id(w.layer_id)
		if layer == null:
			push_warning("TerrainStreamer: 缺少 %s 层，先跑 node tools/fetch_dem.mjs" % w.layer_id)
			continue
		w.zoom = layer.zoom


## 按玩家当前经纬度更新窗口。每帧调用；没到边界就什么都不做。
func update_for(lon: float, lat: float) -> void:
	if _building != null:
		_step_build()
		return
	# fine 优先：它决定脚下地形，coarse 换得少
	if _needs_rebuild(fine, lon, lat):
		_begin_build(fine, _desired_origin(fine, lon, lat))
	elif _needs_rebuild(coarse, lon, lat):
		_begin_build(coarse, _desired_origin(coarse, lon, lat))


func _desired_origin(w: DemWindow, lon: float, lat: float) -> Vector2i:
	var tc: Array = GeoRef.lonlat_to_tile(lon, lat, w.zoom)
	# 让玩家落在窗口正中那一块上，四周留同样多的余量
	return Vector2i(
		floori(float(tc[0])) - w.tiles / 2 + 1,
		floori(float(tc[1])) - w.tiles / 2 + 1,
	)


func _needs_rebuild(w: DemWindow, lon: float, lat: float) -> bool:
	if w.zoom == 0:
		return false
	return _desired_origin(w, lon, lat) != w.origin


func _begin_build(w: DemWindow, origin: Vector2i) -> void:
	_building = w
	_build_origin = origin
	var px := w.tiles * TILE_PX
	# 新窗口在独立的 Image 上拼，拼完再一次性换上去 —— 双缓冲，
	# 避免玩家看到半张拼好的地形。
	_build_img = Image.create_empty(px, px, false, Image.FORMAT_RF)
	_build_queue.clear()
	for j in w.tiles:
		for i in w.tiles:
			_build_queue.append(Vector2i(i, j))


func _step_build() -> void:
	if _building.zoom == 0:
		_finish_build()
		return

	var n := mini(TILES_PER_FRAME, _build_queue.size())
	for _k in n:
		var cell: Vector2i = _build_queue.pop_front()
		var gx := _build_origin.x + cell.x
		var gy := _build_origin.y + cell.y
		# 必须走 tile_image_or_coarser：精细层的烘焙范围是有限的，窗口边缘
		# 常有没烘焙的格子。留 0 的话那片地形会塌到海拔 0 m，画面上是大片空洞。
		var img := TerrainDB.tile_image_or_coarser(_building.zoom, gx, gy)
		if img == null:
			_stat_missing += 1
			continue
		if not TerrainDB.has_exact_tile(_building.zoom, gx, gy):
			_stat_fallback += 1
		_build_img.blit_rect(
			img, Rect2i(0, 0, TILE_PX, TILE_PX), Vector2i(cell.x * TILE_PX, cell.y * TILE_PX)
		)

	if _build_queue.is_empty():
		_finish_build()


func _finish_build() -> void:
	var w := _building
	if verbose:
		# 窗口里若还残留 0（或极端值），说明有格子既没精细数据也没粗层兜底 ——
		# 那片地形会塌到海拔 0 m。这个统计就是为了让它无处遁形。
		var lo := 1e9
		var hi := -1e9
		var zeros := 0
		for j in range(0, _build_img.get_height(), 8):
			for i in range(0, _build_img.get_width(), 8):
				var v := _build_img.get_pixel(i, j).r
				lo = minf(lo, v)
				hi = maxf(hi, v)
				if absf(v) < 0.001:
					zeros += 1
		print("[streamer] %s z=%d 原点(%d,%d) 高程 %.0f~%.0f m  精确瓦片 %d  粗层回退 %d  完全缺失 %d  采样到 0 的点 %d" % [
			w.layer_id, w.zoom, _build_origin.x, _build_origin.y, lo, hi,
			w.tiles * w.tiles - _stat_fallback - _stat_missing, _stat_fallback, _stat_missing, zeros,
		])
	_stat_fallback = 0
	_stat_missing = 0
	if w.tex == null:
		w.tex = ImageTexture.create_from_image(_build_img)
	else:
		# 尺寸不变时 update 比重建便宜得多
		w.tex.update(_build_img)
	w.origin = _build_origin
	_building = null
	_build_img = null
	window_ready.emit(w.layer_id)


## 所有 #include 了 terrain_sample.gdshaderinc 的材质都要登记进来 ——
## 地形、草、树、水面都靠这组 uniform 定位，漏掉一个那类物体就会整体错位。
var _materials: Array[ShaderMaterial] = []


func register(mat: ShaderMaterial) -> void:
	if mat != null and not _materials.has(mat):
		_materials.append(mat)
		apply_to(mat)


## 把当前窗口状态写进所有已登记的材质。每帧调用；GeoRef 重锚后必须立即调。
func apply_all() -> void:
	for m in _materials:
		apply_to(m)


## 把当前窗口状态写进指定材质。
func apply_to(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter("origin_lon", GeoRef.origin_lon)
	mat.set_shader_parameter("origin_lat", GeoRef.origin_lat)
	mat.set_shader_parameter("m_per_deg_lon", GeoRef.meters_per_deg_lon())
	mat.set_shader_parameter("m_per_deg_lat", GeoRef.meters_per_deg_lat())

	if fine.tex != null:
		mat.set_shader_parameter("tex_fine", fine.tex)
		mat.set_shader_parameter("fine_tile_min", fine.tile_min())
		mat.set_shader_parameter("fine_tile_span", fine.tile_span())
		mat.set_shader_parameter("fine_n", float(1 << fine.zoom))
	if coarse.tex != null:
		mat.set_shader_parameter("tex_coarse", coarse.tex)
		mat.set_shader_parameter("coarse_tile_min", coarse.tile_min())
		mat.set_shader_parameter("coarse_tile_span", coarse.tile_span())
		mat.set_shader_parameter("coarse_n", float(1 << coarse.zoom))


func is_ready() -> bool:
	return fine.tex != null and coarse.tex != null


## 强制立即建好两张窗口（阻塞）。开场加载时用，避免玩家看到空地形。
func build_now(lon: float, lat: float) -> void:
	for w: DemWindow in [coarse, fine]:
		if w.zoom == 0:
			continue
		_begin_build(w, _desired_origin(w, lon, lat))
		while _building != null:
			_step_build()
