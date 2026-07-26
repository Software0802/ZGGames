extends Node
## TerrainDB —— 烘焙真实 DEM 的只读访问层。
##
## 数据来源：AWS Open Data «Terrain Tiles» 的 terrarium 编码 PNG，
## 由 tools/fetch_dem.mjs 离线下载、解码、裁成本工程的 .r16 格式。
## 游戏运行时**不联网**。
##
## 署名要求（tilezen/joerd attribution.md）：新疆范围内的高程来自
## SRTM 与 GMTED2010 —— "3DEP (formerly NED) and global GMTED2010 and
## SRTM data courtesy of U.S. Geological Survey"。见 README 与游戏内致谢页。
##
## 精度诚实边界：
##   L2 (z=12) 在 43°N 约 27.9 m/px，与 SRTM 1 弧秒原生 30 m 相当 —— 这是真实数据的上限。
##   比这更细的起伏由 client/render 的分形细节层合成，**不是**真实地貌。
##   调试 HUD (F3) 会标出当前脚下高程有多少来自实测数据。

const INDEX_PATH := "res://assets/terrain/index.json"
const TILE_PX := 256

## 无数据时的回退高程（米）。刻意取一个明显不真实的值，便于在画面上一眼看出缺数据。
const NO_DATA := -9999.0

class Layer:
	var id: String
	var zoom: int
	var tiles: Dictionary = {}  ## "x_y" -> 相对 res://assets/terrain/ 的文件路径

	func key(tx: int, ty: int) -> String:
		return str(tx) + "_" + str(ty)

var layers: Array[Layer] = []          ## 按 zoom 降序：先查最精细的层
var attribution: String = ""
var _cache: Dictionary = {}            ## "layerId:x_y" -> PackedByteArray
var _cache_order: Array[String] = []
var _img_cache: Dictionary = {}        ## "img:layerId:x_y" -> Image (FORMAT_RF)
var _img_order: Array[String] = []
var _warned_missing := false

const CACHE_LIMIT := 96                ## 96 × 128 KB ≈ 12 MB 常驻
## fine 窗口是 6×6=36 块，coarse 4×4=16 块，留出平移时的进出余量。
const IMG_CACHE_LIMIT := 80            ## 80 × 256 KB ≈ 20 MB


func _ready() -> void:
	_load_index()


func _load_index() -> void:
	if not FileAccess.file_exists(INDEX_PATH):
		push_warning("TerrainDB: 未找到 %s —— 请先跑 `node tools/fetch_dem.mjs`。地形将全为空。" % INDEX_PATH)
		return
	var text := FileAccess.get_file_as_string(INDEX_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("TerrainDB: index.json 解析失败")
		return
	var data: Dictionary = parsed
	attribution = data.get("attribution", "")
	layers.clear()
	for entry: Dictionary in data.get("layers", []):
		var layer := Layer.new()
		layer.id = entry.get("id", "?")
		layer.zoom = int(entry.get("zoom", 0))
		for t: Dictionary in entry.get("tiles", []):
			layer.tiles[layer.key(int(t["x"]), int(t["y"]))] = String(t["file"])
		layers.append(layer)
	# 精细层优先
	layers.sort_custom(func(a: Layer, b: Layer) -> bool: return a.zoom > b.zoom)
	var total := 0
	for l: Layer in layers:
		total += l.tiles.size()
	print("TerrainDB: 载入 %d 层 / %d 瓦片" % [layers.size(), total])


## 查询某经纬度的高程（米）。自动选用覆盖该点的最精细层。
## 返回 NO_DATA 表示该点没有烘焙数据。
func sample(lon: float, lat: float) -> float:
	for layer: Layer in layers:
		var h := _sample_layer(layer, lon, lat)
		if h != NO_DATA:
			return h
	if not _warned_missing:
		_warned_missing = true
		push_warning("TerrainDB: (%.4f, %.4f) 无烘焙数据" % [lon, lat])
	return NO_DATA


## 查询时同时返回数据来源层，供调试 HUD 标注真实/程序化边界。
func sample_with_source(lon: float, lat: float) -> Dictionary:
	for layer: Layer in layers:
		var h := _sample_layer(layer, lon, lat)
		if h != NO_DATA:
			return {"height": h, "layer": layer.id, "zoom": layer.zoom}
	return {"height": NO_DATA, "layer": "none", "zoom": 0}


func _sample_layer(layer: Layer, lon: float, lat: float) -> float:
	var tc: Array = GeoRef.lonlat_to_tile(lon, lat, layer.zoom)
	var fx: float = tc[0]
	var fy: float = tc[1]
	# 瓦片内像素坐标（−0.5 是因为采样点在像素中心）
	# 用 floorf/floori 而不是 floor()：后者接受 Variant 也返回 Variant，静态类型推导不出来。
	var px := (fx - floorf(fx)) * float(TILE_PX) - 0.5
	var py := (fy - floorf(fy)) * float(TILE_PX) - 0.5
	var tx := floori(fx)
	var ty := floori(fy)

	var x0 := floori(px)
	var y0 := floori(py)
	var wx := px - float(x0)
	var wy := py - float(y0)

	# 双线性四角，逐点解析（可能跨瓦片边界）
	var h00 := _texel(layer, tx, ty, x0, y0)
	if h00 == NO_DATA:
		return NO_DATA
	var h10 := _texel(layer, tx, ty, x0 + 1, y0)
	var h01 := _texel(layer, tx, ty, x0, y0 + 1)
	var h11 := _texel(layer, tx, ty, x0 + 1, y0 + 1)
	# 边界外退化为最近可用值，避免在瓦片缝上出现 NO_DATA 裂缝
	if h10 == NO_DATA: h10 = h00
	if h01 == NO_DATA: h01 = h00
	if h11 == NO_DATA: h11 = h10

	var top := lerpf(h00, h10, wx)
	var bot := lerpf(h01, h11, wx)
	return lerpf(top, bot, wy)


## 取单个 texel，自动处理越出瓦片边界到相邻瓦片。
func _texel(layer: Layer, tx: int, ty: int, x: int, y: int) -> float:
	var ax := tx
	var ay := ty
	var lx := x
	var ly := y
	while lx < 0:
		lx += TILE_PX
		ax -= 1
	while lx >= TILE_PX:
		lx -= TILE_PX
		ax += 1
	while ly < 0:
		ly += TILE_PX
		ay -= 1
	while ly >= TILE_PX:
		ly -= TILE_PX
		ay += 1

	var buf := _tile_bytes(layer, ax, ay)
	if buf.is_empty():
		return NO_DATA
	return float(buf.decode_s16((ly * TILE_PX + lx) * 2))


func _tile_bytes(layer: Layer, tx: int, ty: int) -> PackedByteArray:
	var tkey := layer.key(tx, ty)
	if not layer.tiles.has(tkey):
		return PackedByteArray()
	var ckey := layer.id + ":" + tkey
	if _cache.has(ckey):
		return _cache[ckey]

	var path := "res://assets/terrain/" + String(layer.tiles[tkey])
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("TerrainDB: 打不开 %s" % path)
		return PackedByteArray()
	var buf := f.get_buffer(TILE_PX * TILE_PX * 2)
	f.close()

	_cache[ckey] = buf
	_cache_order.append(ckey)
	while _cache_order.size() > CACHE_LIMIT:
		var evict: String = _cache_order.pop_front()
		_cache.erase(evict)
	return buf


## 按 id 取层。找不到返回 null。
func layer_by_id(id: String) -> Layer:
	for l: Layer in layers:
		if l.id == id:
			return l
	return null


## 该缩放级上是否真有这块瓦片（而不是靠粗层放大补出来的）。
func has_exact_tile(zoom: int, tx: int, ty: int) -> bool:
	for l: Layer in layers:
		if l.zoom == zoom:
			return l.tiles.has(l.key(tx, ty))
	return false


## 取指定缩放级的某块瓦片图；该块没烘焙时，从更粗的层抠出对应子区域放大补上。
##
## 【为什么必须有这个回退】
## 窗口纹理是按瓦片拼的，缺的格子若留 0，那片地形会塌到海拔 0 m ——
## 在 2500 m 的那拉提就是往下掉 2500 m，画面上表现为大片「空洞 + 垂直墙」，
## 而且极易被误判成着色或分级接缝的问题（本工程实际排查了很久才定位到这里）。
## 精细层的烘焙范围永远是有限的，所以回退不是可选项，是必需项。
##
## 粗层放大出来的当然不是真实的 28 m 细节，但它是**真实的高程**，
## 只是分辨率低 —— 这与「28 m/px 以下是合成细节」的诚实边界一致。
func tile_image_or_coarser(zoom: int, tx: int, ty: int) -> Image:
	for l: Layer in layers:
		if l.zoom == zoom and l.tiles.has(l.key(tx, ty)):
			return tile_image(l, tx, ty)

	# layers 已按 zoom 降序，从次精细的层依次往粗找
	for l: Layer in layers:
		if l.zoom >= zoom:
			continue
		var dz := zoom - l.zoom
		var ctx := tx >> dz
		var cty := ty >> dz
		if not l.tiles.has(l.key(ctx, cty)):
			continue
		var src := tile_image(l, ctx, cty)
		if src == null:
			continue
		# 目标瓦片在这块粗瓦片里占 (256 >> dz)² 个纹素
		var sub := TILE_PX >> dz
		if sub < 1:
			continue
		var ox := (tx - (ctx << dz)) * sub
		var oy := (ty - (cty << dz)) * sub
		var block := src.get_region(Rect2i(ox, oy, sub, sub))
		block.resize(TILE_PX, TILE_PX, Image.INTERPOLATE_BILINEAR)
		return block

	return null


## 单块瓦片转成 FORMAT_RF 的 Image，供 terrain_streamer 拼进窗口纹理。
## 返回 null 表示该瓦片没烘焙。
##
## int16 → float32 的转换是这里唯一的 GDScript 逐像素循环（每块 65536 次），
## 所以结果按瓦片缓存：窗口平移时只有新进入的那几块需要转换，其余直接复用。
## 转换必须走 float32：R16/RG8 之类的打包格式在硬件双线性插值时会按字节分别
## 插值，跨字节进位处会插出垃圾值，地形上会出现规则的尖刺。
func tile_image(layer: Layer, tx: int, ty: int) -> Image:
	if layer == null:
		return null
	var ckey := "img:" + layer.id + ":" + layer.key(tx, ty)
	if _img_cache.has(ckey):
		return _img_cache[ckey]

	var src := _tile_bytes(layer, tx, ty)
	if src.is_empty():
		return null

	var n := TILE_PX * TILE_PX
	var dst := PackedByteArray()
	dst.resize(n * 4)
	for i in n:
		dst.encode_float(i * 4, float(src.decode_s16(i * 2)))
	var img := Image.create_from_data(TILE_PX, TILE_PX, false, Image.FORMAT_RF, dst)

	_img_cache[ckey] = img
	_img_order.append(ckey)
	while _img_order.size() > IMG_CACHE_LIMIT:
		_img_cache.erase(_img_order.pop_front())
	return img
