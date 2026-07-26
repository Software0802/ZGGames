class_name Regions
extends RefCounted
## 地标与牧道的访问层。
##
## 数据本体在 shared/data/regions.json —— 那是唯一真相源，因为 Node 烘焙工具
## (tools/fetch_dem.mjs) 也要读同一份来决定下载哪些瓦片。任何一侧手抄副本都会漂移。
##
## Godot 4 不把 .json 当资源导入（JSON 不是 Resource，ResourceLoader.load 读不了），
## 所以走 FileAccess + JSON.parse_string。
## 导出时须在「资源 → 导出非资源文件的过滤器」里加上 *.json,*.r16。

const PATH := "res://shared/data/regions.json"

static var _cache: Dictionary = {}


static func _data() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	if not FileAccess.file_exists(PATH):
		push_error("Regions: 缺少 %s" % PATH)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Regions: %s 解析失败" % PATH)
		return {}
	_cache = parsed
	return _cache


## 重新读盘。烘焙工具回填 altitude_m 之后调用。
static func reload() -> void:
	_cache = {}
	_data()


static func all() -> Array:
	return _data().get("regions", [])


static func get_region(key: String) -> Dictionary:
	for r: Dictionary in all():
		if r["key"] == key:
			return r
	push_error("Regions: 无此地标 '%s'" % key)
	return {}


static func keys() -> PackedStringArray:
	var out := PackedStringArray()
	for r: Dictionary in all():
		out.append(String(r["key"]))
	return out


static func base_capacity_units() -> float:
	return float(_data().get("base_capacity_units", 90.0))


## 该地标的承载上限（羊单位）。防风林加成由 economy.gd 另加，不在这里。
static func capacity_units(key: String) -> float:
	var r := get_region(key)
	if r.is_empty():
		return 0.0
	return base_capacity_units() * float(r["carrying_capacity"])


## 地标高程（米）。由烘焙工具从真实 DEM 回填；未回填时回退到实时采样。
static func altitude_m(key: String) -> float:
	var r := get_region(key)
	if r.is_empty():
		return 0.0
	var a: Variant = r.get("altitude_m")
	if a != null:
		return float(a)
	return TerrainDB.sample(float(r["lon"]), float(r["lat"]))


static func routes() -> Array:
	return _data().get("routes", [])


static func route(key: String) -> Dictionary:
	for rt: Dictionary in routes():
		if rt["key"] == key:
			return rt
	return {}


static func caravan_links() -> Array:
	return _data().get("caravan_links", [])


## DEM 回归断言基准点。启动自检与 tools 侧共用同一组。
static func dem_fixtures() -> Array:
	return _data().get("dem_fixtures", [])


## 某地标在某季节是否开放。
static func is_open_in(key: String, season: String) -> bool:
	var r := get_region(key)
	return not r.is_empty() and season in r.get("seasons", [])


## 找出某条牧道在某季节的行程段。没有则返回空字典。
static func stage_for(route_key: String, season: String) -> Dictionary:
	var rt := route(route_key)
	for st: Dictionary in rt.get("stages", []):
		if st["season"] == season:
			return st
	return {}
