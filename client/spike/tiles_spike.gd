extends Node3D

## S0 风险突刺：把 Google Photorealistic 3D Tiles 流式加载进 Godot，实测性能与观感。
##
## 这个场景刻意不依赖项目的地形管线（clipmap / terrain.gdshader），也不启用
## cesium_godot 的 EditorPlugin —— 后者只负责 Cesium ion 的 OAuth 面板，而本突刺
## 直连 Google Map Tiles API，不需要 ion 账号。整个场景由代码构建，便于 headless 跑指标。
##
## 用法：
##   godot --path . client/spike/tiles_spike.tscn
##   godot --path . client/spike/tiles_spike.tscn -- --site tianchi --seconds 60 --capture out/
##
## API key 来源（按优先级）：
##   1. 命令行 --key <KEY>
##   2. 环境变量 GOOGLE_MAPS_API_KEY
##   3. 项目根的 google_maps_key.txt（已 gitignore）

const GOOGLE_ROOT_URL := "https://tile.googleapis.com/v1/3dtiles/root.json"
const KEY_FILE := "res://google_maps_key.txt"

## data_source 的枚举取值，来自 Cesium3DTileset 的属性 hint："From Cesium Ion,From Url"。
const DATA_SOURCE_ION := 0
const DATA_SOURCE_URL := 1

## origin_type 的枚举取值，来自 CesiumGeoreference 的属性 hint："Cartographic Origin,True Origin"。
## Cartographic 模式下相机停在引擎原点，移动的是地球（浮动原点），与项目 georef.gd 的红线一致。
const ORIGIN_CARTOGRAPHIC := 0

## 观测点。altitude 是相机所在高度（米，椭球高），不是地面高程。
## 天池湖面 1910 m（Wikipedia），项目 DEM 在该点读出 1911 m —— 两者互证，见 docs/plans/v004。
## yaw 是绕「上」轴的朝向：引擎局部系是 EUS（+X 东 / +Y 上 / +Z 南），相机默认朝 -Z 即正北，
## 所以 yaw=180 是朝南。天池湖体在观测点以南，故默认朝南。
const SITES := {
	# 观景位取在湖北岸上空、朝南偏东：湖体（43.865–43.895N）整个落进画面，
	# 背景正对博格达峰方向（43.81N 88.35E）。湖心本身是 43.886028/88.132389。
	"tianchi": {
		"name": "天山天池",
		"lat": 43.9180,
		"lon": 88.1180,
		"ground_m": 1910.0,
		"altitude": 3400.0,
		"yaw": 168.0,
		"pitch": -20.0,
	},
	"urumqi": {
		"name": "乌鲁木齐市区",
		"lat": 43.825592,
		"lon": 87.616848,
		"ground_m": 800.0,
		"altitude": 1450.0,
		"yaw": 200.0,
		"pitch": -22.0,
	},
}

var _site_key: String = "tianchi"
var _run_seconds: float = 0.0
var _capture_dir: String = ""
var _cli_key: String = ""
var _pitch: float = NAN   ## NAN = 用观测点自带的默认角度
var _yaw: float = NAN

var _georeference: Node3D = null
var _tileset: Node = null
var _camera: Camera3D = null
var _hud: Label = null

var _elapsed: float = 0.0
var _first_tile_time: float = -1.0
var _loading_done_time: float = -1.0
var _fps_samples: PackedFloat32Array = PackedFloat32Array()
var _peak_mem_mb: float = 0.0
var _captured: int = 0
var _fatal: String = ""
var _last_diag: float = 0.0

## --scan：一次会话里把相机俯角依次打到这几档并各截一张。
## 瓦片会话按 root.json 请求计费，一次跑完六个角度比跑六次省 5 次配额。
const SCAN_PITCHES: Array[float] = [0.0, -20.0, -40.0, -60.0, -90.0, 20.0]
const SCAN_LEAD_IN := 5.0   ## 先给瓦片 5 秒加载，再开始扫描
const SCAN_STEP := 4.0      ## 每档停留时长
const SCAN_SETTLE := 3.0    ## 转到位后等多久再截图，留给该角度的瓦片换入

var _scan: bool = false
var _scan_step: int = -1
var _scan_shot_at: float = -1.0


func _scan_tick() -> void:
	if _elapsed < SCAN_LEAD_IN:
		return
	var step := int((_elapsed - SCAN_LEAD_IN) / SCAN_STEP)
	if step < SCAN_PITCHES.size() and step != _scan_step:
		_scan_step = step
		_camera.rotation_degrees = Vector3(SCAN_PITCHES[step], 0.0, 0.0)
		_scan_shot_at = _elapsed + SCAN_SETTLE
		print("[S0][扫描] 俯角 → %+.0f°" % SCAN_PITCHES[step])
	if _scan_shot_at > 0.0 and _elapsed >= _scan_shot_at:
		_scan_shot_at = -1.0
		_save_shot("pitch%+03d" % int(SCAN_PITCHES[_scan_step]))


func _save_shot(tag: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var dir := _capture_dir
	if not dir.ends_with("/"):
		dir += "/"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var p := "%s%s_%s.png" % [dir, _site_key, tag]
	img.save_png(p)
	print("[S0] 截图 → %s（三角面 %d）" % [
		p, RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)])


## 每帧把「引擎坐标 → ECEF」的相机变换喂给 tileset：cesium-native 的 LOD 选择与瓦片
## 请求调度全部由这一次调用驱动，不调用就永远不会有任何网络请求。
func _drive_tileset() -> void:
	if _tileset == null or _camera == null or _georeference == null:
		return
	var to_ecef: Transform3D = _georeference.call("get_tx_engine_to_ecef")
	_tileset.call("update_tileset", to_ecef * _camera.global_transform)


func _ready() -> void:
	_parse_cli()
	var key := _resolve_api_key()
	if key.is_empty():
		_fatal = "未找到 Google Map Tiles API key"
		_build_hud()
		push_error(_fatal + "。见 docs/plans 中 S0 的申请步骤；把 key 写进项目根的 google_maps_key.txt。")
		return
	if not ClassDB.class_exists("Cesium3DTileset"):
		_fatal = "GDExtension 未加载：Cesium3DTileset 类不存在"
		_build_hud()
		push_error(_fatal + "。确认 bin/Godot3DTiles.gdextension 与同目录 dll 存在，并重新 --import。")
		return
	_build_world(key)
	_build_hud()


func _parse_cli() -> void:
	var args := OS.get_cmdline_user_args()
	var i := 0
	while i < args.size():
		var a := args[i]
		match a:
			"--site":
				i += 1
				if i < args.size():
					_site_key = args[i]
			"--seconds":
				i += 1
				if i < args.size():
					_run_seconds = float(args[i])
			"--capture":
				i += 1
				if i < args.size():
					_capture_dir = args[i]
			"--key":
				i += 1
				if i < args.size():
					_cli_key = args[i]
			"--scan":
				_scan = true
			"--pitch":
				i += 1
				if i < args.size():
					_pitch = float(args[i])
			"--yaw":
				i += 1
				if i < args.size():
					_yaw = float(args[i])
		i += 1
	if not SITES.has(_site_key):
		push_warning("未知观测点 '%s'，回退到 tianchi。可选：%s" % [_site_key, ", ".join(SITES.keys())])
		_site_key = "tianchi"


## key 只在内存里用于拼 URL，不写进任何存档或日志（日志里一律用 _redact 脱敏）。
func _resolve_api_key() -> String:
	if not _cli_key.is_empty():
		return _cli_key.strip_edges()
	var env := OS.get_environment("GOOGLE_MAPS_API_KEY")
	if not env.is_empty():
		return env.strip_edges()
	if FileAccess.file_exists(KEY_FILE):
		var f := FileAccess.open(KEY_FILE, FileAccess.READ)
		if f != null:
			return f.get_as_text().strip_edges()
	return ""


## 当地 ENU 基（以引擎坐标表达）。
##
## 这一步是必须的，不是锦上添花：CesiumGeoreference 交出来的引擎空间只是 ECEF 做了一次
## 轴交换（实测 ecef→engine 基为 x=(1,0,0) y=(0,0,-1) z=(0,1,0)，即 v_engine = (vx, vz, -vy)），
## 于是引擎的 +Y 指向**地轴北极**而不是当地天顶。在 43.9°N，两者差了约 46°——直接对
## Camera3D 设欧拉角，得到的俯角是相对地轴的，画面会变成近乎垂直的卫星视角。
##
## 返回的 Basis 满足：x=正东，y=当地天顶，-z=正北（Godot 相机看向 -Z，故朝北）。
static func _local_basis(lat_deg: float, lon_deg: float) -> Basis:
	var phi := deg_to_rad(lat_deg)
	var lam := deg_to_rad(lon_deg)
	var up_ecef := Vector3(cos(phi) * cos(lam), cos(phi) * sin(lam), sin(phi))
	var east_ecef := Vector3(-sin(lam), cos(lam), 0.0)
	var north_ecef := Vector3(-sin(phi) * cos(lam), -sin(phi) * sin(lam), cos(phi))
	var up := Vector3(up_ecef.x, up_ecef.z, -up_ecef.y)
	var east := Vector3(east_ecef.x, east_ecef.z, -east_ecef.y)
	var north := Vector3(north_ecef.x, north_ecef.z, -north_ecef.y)
	return Basis(east, up, -north)


static func _redact(key: String) -> String:
	if key.length() <= 8:
		return "***"
	return key.substr(0, 4) + "…" + key.substr(key.length() - 4, 4)


func _build_world(key: String) -> void:
	var site: Dictionary = SITES[_site_key]

	# 太阳。实景瓦片的纹理已烘焙了真实光照，这里只补一点方向光让几何起伏可读。
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 1.0
	sun.rotation_degrees = Vector3(-45.0, 135.0, 0.0)
	add_child(sun)

	var env := WorldEnvironment.new()
	env.name = "Env"
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.45, 0.6, 0.8)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.65, 0.72)
	e.ambient_light_energy = 0.55
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	add_child(env)

	# 地球参考系。Cartographic 模式把这个经纬度钉在引擎原点上。
	_georeference = ClassDB.instantiate("CesiumGeoreference")
	_georeference.name = "CesiumGeoreference"
	add_child(_georeference)
	_georeference.set("origin_type", ORIGIN_CARTOGRAPHIC)
	_georeference.set("latitude", site["lat"])
	_georeference.set("longitude", site["lon"])
	_georeference.set("altitude", site["altitude"])

	# 瓦片集。data_source = From Url 时走 url，完全不碰 Cesium ion。
	# 属性必须在 add_child 之前设完：tileset 在进入场景树时就按当时的 data_source/url
	# 去初始化 cesium-native 的 Tileset，之后再改 url 不会重建。
	_tileset = ClassDB.instantiate("Cesium3DTileset")
	_tileset.name = "GoogleTileset"
	_tileset.set("data_source", DATA_SOURCE_URL)
	_tileset.set("url", "%s?key=%s" % [GOOGLE_ROOT_URL, key])
	_tileset.set("maximum_screen_space_error", 16.0)
	_tileset.set("create_physics_meshes", false)
	_georeference.add_child(_tileset)

	# 坐标系对齐：Cesium 是 Z-up，Godot 是 Y-up。这一对相反的 90° 来自插件自带的
	# CesiumAssetBuilder.instantiate_tileset()，照搬以免与插件内部假设打架。
	_georeference.rotation_degrees.x = -90.0
	_tileset.rotation_degrees.x = 90.0

	# 相机自己驱动，不挂插件的 GeoreferenceCameraController：那个控制器每帧都会把相机
	# basis 覆写成 surface_basis（update_camera_rotation），设好的俯角会被吃掉；而且它的
	# tilesets 是 Array[Cesium3DTileset]，从 GDScript 塞普通 Array 未必转换成功。
	# LOD 选择只依赖每帧调用 tileset.update_tileset(engine→ECEF 的相机变换)，自己调更可控。
	_camera = Camera3D.new()
	_camera.name = "SpikeCamera"
	_camera.near = 9.0
	_camera.far = 35358652.0
	_camera.fov = 55.0
	_camera.current = true
	add_child(_camera)
	# 俯角取 20–30°：实景瓦片最扬长避短的「观光视角」——高到看不出摄影测量的融化，低到有纵深。
	var pitch: float = _pitch if not is_nan(_pitch) else float(site["pitch"])
	var yaw: float = _yaw if not is_nan(_yaw) else float(site["yaw"])
	var b := _local_basis(site["lat"], site["lon"])
	b = b.rotated(b.y, deg_to_rad(-yaw))    # 绕当地天顶转方位
	b = b.rotated(b.x, deg_to_rad(pitch))   # 再绕转过之后的「右」轴压俯角
	_camera.global_transform = Transform3D(b, _camera.global_position)

	print("[S0] 观测点=%s (%.6f, %.6f) 相机高度=%.0f m" % [
		site["name"], site["lat"], site["lon"], site["altitude"]])
	print("[S0] tileset url = %s?key=%s" % [GOOGLE_ROOT_URL, _redact(key)])
	print("[S0] 回读 data_source=%s url_len=%d ssE=%s" % [
		_tileset.get("data_source"), String(_tileset.get("url")).length(),
		_tileset.get("maximum_screen_space_error")])
	print("[S0] 回读 georef lat=%.6f lon=%.6f alt=%.1f origin_type=%s" % [
		_georeference.get("latitude"), _georeference.get("longitude"),
		_georeference.get("altitude"), _georeference.get("origin_type")])

	# 「下」是哪个方向，必须问出来而不是假设。地心在引擎空间的位置，其方向就是重力方向；
	# 由此才能判断俯角该往哪边打，以及 Cesium 的 Z-up 是否已经被 georeference 转成 Y-up。
	var center: Vector3 = _georeference.call("get_global_center_position")
	print("[S0] 地心在引擎空间 = %s  长度 %.0f m  归一化方向 %s" % [center, center.length(), center.normalized()])
	var to_engine: Transform3D = _georeference.call("get_tx_ecef_to_engine")
	print("[S0] ecef→engine basis: x=%s y=%s z=%s" % [to_engine.basis.x, to_engine.basis.y, to_engine.basis.z])


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HUD"
	add_child(layer)
	_hud = Label.new()
	_hud.position = Vector2(16, 16)
	_hud.add_theme_font_size_override("font_size", 16)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(_hud)


func _process(delta: float) -> void:
	_elapsed += delta

	if not _fatal.is_empty():
		if _hud != null:
			_hud.text = "[S0] 失败：%s\n详见控制台。" % _fatal
		if _run_seconds > 0.0 and _elapsed >= _run_seconds:
			get_tree().quit(1)
		return

	var fps := float(Engine.get_frames_per_second())
	# 头 2 秒是着色器编译与首批请求，不计入统计，否则平均帧率没有参考价值。
	if _elapsed > 2.0 and fps > 0.0:
		_fps_samples.append(fps)

	var mem_mb := float(OS.get_static_memory_usage()) / 1048576.0
	_peak_mem_mb = maxf(_peak_mem_mb, mem_mb)

	_drive_tileset()

	# 判定瓦片是否真的进了画面：以渲染出来的三角面为准。HUD 文字自身约 500 面，
	# 所以用一个明显高于它的阈值；headless 没有渲染统计，退回看子节点数。
	if _first_tile_time < 0.0:
		var tris := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
		if tris > 3000 or (_tileset != null and _tileset.get_child_count() > 0):
			_first_tile_time = _elapsed
			print("[S0] 首批瓦片进入画面：%.2f s（三角面 %d / 子节点 %d）" % [
				_first_tile_time, tris, _tileset.get_child_count()])

	if _elapsed - _last_diag > 5.0:
		_last_diag = _elapsed
		print("[S0][诊断] t=%.0fs 三角面=%d tileset子节点=%d 初始加载完成=%s" % [
			_elapsed,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
			_tileset.get_child_count(),
			_tileset.call("is_initial_loading_finished") if _tileset.has_method("is_initial_loading_finished") else "?"])

	if _loading_done_time < 0.0 and _tileset != null and _tileset.has_method("is_initial_loading_finished"):
		if _tileset.call("is_initial_loading_finished"):
			_loading_done_time = _elapsed
			print("[S0] 初始加载完成：%.2f s" % _loading_done_time)

	if _hud != null:
		_hud.text = _hud_text(fps, mem_mb)

	if not _capture_dir.is_empty():
		if _scan:
			_scan_tick()
		else:
			_maybe_capture()

	if _run_seconds > 0.0 and _elapsed >= _run_seconds:
		_report()
		get_tree().quit(0)


func _hud_text(fps: float, mem_mb: float) -> String:
	var site: Dictionary = SITES[_site_key]
	var lines := PackedStringArray()
	lines.append("S0 · %s  %.4f°N %.4f°E" % [site["name"], site["lat"], site["lon"]])
	lines.append("fps %.0f   avg %.1f   1%%low %.1f" % [fps, _avg_fps(), _low_fps()])
	lines.append("静态内存 %.0f MB (峰值 %.0f)" % [mem_mb, _peak_mem_mb])
	lines.append("draw call %d   三角面 %d" % [
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
	])
	lines.append("首批瓦片 %s   初始加载完成 %s" % [
		("%.2f s" % _first_tile_time) if _first_tile_time >= 0.0 else "—",
		("%.2f s" % _loading_done_time) if _loading_done_time >= 0.0 else "—",
	])
	lines.append("t = %.1f s   右键拖动转视角 · WASD 平移 · QE 升降 · +/- 调速")
	lines[lines.size() - 1] = lines[lines.size() - 1] % _elapsed
	return "\n".join(lines)


func _avg_fps() -> float:
	if _fps_samples.is_empty():
		return 0.0
	var sum := 0.0
	for v in _fps_samples:
		sum += v
	return sum / float(_fps_samples.size())


## 1% low：帧率曲线的下尾，比平均值更能反映瓦片换入时的卡顿。
func _low_fps() -> float:
	if _fps_samples.is_empty():
		return 0.0
	var sorted := Array(_fps_samples)
	sorted.sort()
	var idx := maxi(0, int(float(sorted.size()) * 0.01))
	return float(sorted[idx])


func _maybe_capture() -> void:
	# 在固定时刻各截一张：早期(瓦片刚进)、中期、末期(LOD 收敛)，用于观感对比。
	var marks := [5.0, 15.0, 30.0]
	if _captured >= marks.size():
		return
	if _elapsed < float(marks[_captured]):
		return
	_save_shot("t%02d" % int(marks[_captured]))
	_captured += 1


func _report() -> void:
	print("=== S0 突刺指标 · %s ===" % SITES[_site_key]["name"])
	print("采样时长      : %.1f s（前 2 s 不计）" % _elapsed)
	print("平均 fps      : %.1f" % _avg_fps())
	print("1%% low fps    : %.1f" % _low_fps())
	print("静态内存峰值  : %.0f MB" % _peak_mem_mb)
	print("首批瓦片      : %s" % (("%.2f s" % _first_tile_time) if _first_tile_time >= 0.0 else "未出现"))
	print("初始加载完成  : %s" % (("%.2f s" % _loading_done_time) if _loading_done_time >= 0.0 else "未完成"))
	print("瓦片会话数    : 1（一次 root.json 请求 = 1 次计费事件，至少可用 3 小时）")
