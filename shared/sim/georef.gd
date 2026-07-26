extends Node
## GeoRef —— 地理真值坐标系与浮动原点。
##
## 为什么存在：GDScript 的 `float` 是 64 位 double，但 `Vector3` 的分量是 32 位 float
## （见 docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_basics.html）。
## 新疆东西约 1600 km，远超 Godot 第三人称 3D 的单精度推荐范围 −4096~8192 单位
## （见 tutorials/physics/large_world_coordinates.html），而大世界坐标是编译期选项，
## 不是项目设置。因此本工程采用引擎文档推荐的 origin shifting 方案：
##
##   * 任何**长期存储**的位置一律存经纬度（lon/lat，double）。
##   * `Vector3` 只作为**当帧**的渲染/物理坐标，永远是相对当前锚点的局部米制偏移。
##   * 玩家越过 REBASE_RADIUS 时重锚，整个场景树平移。
##
## 这条约束是红线：把经纬度塞进 Vector3 会在离锚点几百公里处静默丢精度。
##
## 本脚本不依赖场景树状态，客户端与服务器共用（M2 时直接搬去 server/）。

## 玩家离锚点超过这个距离（米）就重锚。
## 取 Godot 第三人称推荐区间 −4096~8192 的一半，留足余量给远处的地形与远山。
const REBASE_RADIUS := 2048.0

# ---- WGS84 ----
const WGS84_A := 6378137.0                  ## 长半轴（米）
const WGS84_F := 1.0 / 298.257223563        ## 扁率
const WGS84_E2 := WGS84_F * (2.0 - WGS84_F) ## 第一偏心率平方

## 新疆大致范围，用于烘焙边界与越界断言。
const XJ_LON_MIN := 73.0
const XJ_LON_MAX := 96.5
const XJ_LAT_MIN := 34.0
const XJ_LAT_MAX := 49.5

## 重锚时发出，参数是「新锚点 − 旧锚点」在旧锚点局部系下的米制位移。
## 所有持有局部坐标的节点应订阅此信号并减去该位移（或直接用 geo 真值重算）。
signal rebased(shift: Vector3, new_lon: float, new_lat: float)

## 当前世界锚点（double 精度，绝不放进 Vector3）。
var origin_lon: float = 87.02
var origin_lat: float = 48.77

# 锚点处的投影尺度，重锚时重算一次，避免每次换算都开方。
var _m_per_deg_lon: float = 0.0
var _m_per_deg_lat: float = 0.0


func _ready() -> void:
	_recompute_scale()


func _recompute_scale() -> void:
	var phi := deg_to_rad(origin_lat)
	var s := sin(phi)
	var w := 1.0 - WGS84_E2 * s * s
	# 子午圈曲率半径 M 与卯酉圈曲率半径 N。
	var m_rad := WGS84_A * (1.0 - WGS84_E2) / pow(w, 1.5)
	var n_rad := WGS84_A / sqrt(w)
	_m_per_deg_lat = m_rad * PI / 180.0
	_m_per_deg_lon = n_rad * cos(phi) * PI / 180.0


## 锚点处 1° 经度 / 纬度对应多少米。地形着色器要用同一组数值做逆投影，
## 否则世界坐标与地理坐标会对不上，地形特征就被搬走了。
func meters_per_deg_lon() -> float:
	return _m_per_deg_lon


func meters_per_deg_lat() -> float:
	return _m_per_deg_lat


## 设置锚点（不发信号）。仅用于初始化或读档。
func set_origin(lon: float, lat: float) -> void:
	origin_lon = lon
	origin_lat = lat
	_recompute_scale()


## 经纬度 → 局部米制坐标。
## 约定：+X = 东，−Z = 北（这样相机看向 −Z 时朝北），Y 由地形高度还原。
func geo_to_local(lon: float, lat: float) -> Vector3:
	var east := (lon - origin_lon) * _m_per_deg_lon
	var north := (lat - origin_lat) * _m_per_deg_lat
	return Vector3(east, 0.0, -north)


## 局部米制坐标 → 经纬度。返回 [lon, lat]，两者都是 double。
## 不返回 Vector2 —— Vector2 的分量是 32 位，会把经度精度砍到约 1e-5 度（约 1 米），
## 累计几次往返换算就会漂移。
func local_to_geo(local: Vector3) -> Array:
	var lon := origin_lon + float(local.x) / _m_per_deg_lon
	var lat := origin_lat - float(local.z) / _m_per_deg_lat
	return [lon, lat]


## 玩家局部坐标越界时重锚。返回 true 表示发生了重锚。
## 调用方负责在收到 `rebased` 后平移自己的节点。
func maybe_rebase(player_local: Vector3) -> bool:
	var flat := Vector2(player_local.x, player_local.z)
	if flat.length() < REBASE_RADIUS:
		return false
	var geo := local_to_geo(player_local)
	var shift := geo_to_local(geo[0], geo[1])  # 等于 player_local（去掉 y）
	set_origin(geo[0], geo[1])
	rebased.emit(shift, origin_lon, origin_lat)
	return true


# ---- Web Mercator 瓦片换算（terrarium DEM 用 EPSG:3857） ----

## 经纬度 → 分数瓦片坐标。返回 [x, y]，double 精度。
## 不用 Vector2 的理由同 local_to_geo。
func lonlat_to_tile(lon: float, lat: float, zoom: int) -> Array:
	var n := float(1 << zoom)
	var x := (lon + 180.0) / 360.0 * n
	var phi := deg_to_rad(lat)
	# asinh(tan φ)。不用内建 asinh —— 各版本 GDScript 暴露情况不一，log 形式恒定可用。
	var t := tan(phi)
	var y := (1.0 - log(t + sqrt(t * t + 1.0)) / PI) / 2.0 * n
	return [x, y]


## 分数瓦片坐标 → 经纬度。返回 [lon, lat]。
func tile_to_lonlat(x: float, y: float, zoom: int) -> Array:
	var n := float(1 << zoom)
	var lon := x / n * 360.0 - 180.0
	var k := PI * (1.0 - 2.0 * y / n)
	# atan(sinh k)
	var lat := rad_to_deg(atan((exp(k) - exp(-k)) * 0.5))
	return [lon, lat]


## 某缩放级在给定纬度下的地面分辨率（米/像素，256 px 瓦片）。
## z=12 @ 43°N ≈ 27.9 m/px，与 SRTM 1 弧秒原生 30 m 相当 —— 这是真实数据的上限。
func meters_per_pixel(lat: float, zoom: int) -> float:
	return 156543.03392804097 * cos(deg_to_rad(lat)) / float(1 << zoom)


## 两点大圆距离（米）。用于牧道长度与转场日程校验。
func haversine(lon1: float, lat1: float, lon2: float, lat2: float) -> float:
	var p1 := deg_to_rad(lat1)
	var p2 := deg_to_rad(lat2)
	var dp := p2 - p1
	var dl := deg_to_rad(lon2 - lon1)
	var a := sin(dp * 0.5) * sin(dp * 0.5) + cos(p1) * cos(p2) * sin(dl * 0.5) * sin(dl * 0.5)
	return 2.0 * 6371008.8 * atan2(sqrt(a), sqrt(1.0 - a))


func in_xinjiang(lon: float, lat: float) -> bool:
	return lon >= XJ_LON_MIN and lon <= XJ_LON_MAX and lat >= XJ_LAT_MIN and lat <= XJ_LAT_MAX
