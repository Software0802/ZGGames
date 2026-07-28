extends Node3D
## 世界根节点。
##
## P2 阶段它负责：把真实 DEM 铺成可飞行的地形，维持浮动原点，并提供验证手段
## （DEM 回归自检、调试 HUD、地标跳转、纯 DEM / 带细节对比、自动截图）。
## P4 接入第三人称角色后，FreeCam 退到 F4。
##
## 命令行：
##   godot --headless --path . --quit-after 120      跑 DEM 自检
##   godot --path . -- --capture out/               逐个地标截图后退出
##   godot --path . -- --region kanas                指定起始地标
##   godot --path . -- --region narati --cam ground --shot out/   单张速拍
##   godot --path . -- --region narati --cam ground --grass-debug 2 --shot out/

const START_REGION_DEFAULT := "narati"
## 截图模式下每处地标停留多少帧：要给分帧构建的窗口纹理留出建完的时间。
const CAPTURE_FRAMES := 150

var clipmap: Clipmap
var grass: GrassField
var streamer: TerrainStreamer
var terrain_mat: ShaderMaterial
## 世界时钟。模拟状态，不是渲染状态 —— M2 上服务器持有它，客户端跟随。
var clock := WorldClock.new()
## 当前地标的完整环境档案（RegionEnv.resolve 的结果）
var _env: Dictionary = {}
## 上次重算天空时的钟面分钟数，用于限频，见 _process
var _last_sky_minute := -999.0

var _region_keys: PackedStringArray
var _region_idx := 0
var _detail_on := true
var _skirt_on := true
var _hud_visible := true

# 截图模式
var _capture_dir := ""
var _capture_timer := 0
var _capture_idx := 0
var _variants_dir := ""
var _variant_idx := -1
## "overview" 俯瞰 / "ground" 贴地
var _cam_mode := "overview"
## 单张速拍：只对当前地标、当前机位拍一张就退出。
## --capture 要跑 8 地标 × 2 机位 = 16 张，验证一处改动时太慢（软件渲染下几分钟）。
var _shot_dir := ""
var _shot_frames := CAPTURE_FRAMES

@onready var _cam: FreeCam = $FreeCam
@onready var _sun: DirectionalLight3D = $Sun
@onready var _hud: RichTextLabel = $UI/Hud


func _ready() -> void:
	_run_dem_selftest()

	_region_keys = Regions.keys()
	var args := _parse_args()
	if args.has("time"):
		var m := WorldClock.parse_hhmm(String(args["time"]))
		if m < 0.0:
			push_error("--time 要 HH:MM，收到 %s" % args["time"])
		else:
			clock.minute_of_day = m
	# 截图时时间必须停住，否则同一组对照图各拍在不同时刻，没法比
	if args.has("shot") or args.has("capture") or args.has("variants"):
		clock.running = false
	_capture_dir = args.get("capture", "")
	var start: String = args.get("region", START_REGION_DEFAULT)
	_region_idx = maxi(0, _region_keys.find(start))

	_variants_dir = args.get("variants", "")
	_shot_dir = args.get("shot", "")
	_shot_frames = int(args.get("frames", CAPTURE_FRAMES))
	if args.has("cam"):
		_cam_mode = String(args["cam"])

	_build_terrain()
	if args.has("grass-debug"):
		grass.set_debug(int(args["grass-debug"]))
	_goto_region(_region_keys[_region_idx])
	# 放在 _goto_region 之后：_apply_sky 要读 _env，而 _env 是在那里面解析出来的
	_apply_sun()

	if _shot_dir != "":
		DirAccess.make_dir_recursive_absolute(_shot_dir)
	elif _variants_dir != "":
		DirAccess.make_dir_recursive_absolute(_variants_dir)
		_hud.visible = false
		_hud_visible = false
	elif _capture_dir != "":
		DirAccess.make_dir_recursive_absolute(_capture_dir)
		_region_idx = 0
		_goto_region(_region_keys[0])


## 太阳。位置与光色全部由 WorldClock 驱动 —— 交接文档 §07 的公式
## `太阳角 = ((minuteOfDay/60 − 6)/24) × 2π`，实现见 shared/sim/world_clock.gd。
##
## v003 手调的那组静态值（仰角 50°、方位 150°）不再需要，但它当时的两条取值理由
## 已经搬进 WorldClock：仰角上限 58°（再高会把山坡明暗差压没），
## 正午能量 1.55（沿用）。
func _apply_sun() -> void:
	# 用方向向量 + look_at 定向，而不是直接写 rotation_degrees。
	# 欧拉角的旋转顺序（Godot 默认 YXZ）很容易把仰角与方位角的语义搞反 ——
	# 之前用 rotation_degrees(-52, 34, 0) 就把太阳放到了地形背面，
	# 整片近景全黑，还一度被误判成阴影自遮挡。方向向量没有这种歧义。
	var to_sun := clock.to_sun()
	# 太阳落到地平线以下时 look_at 仍然有效，但光要关掉，否则会从地底往上打光。
	# DirectionalLight3D 沿自身 −Z 发光，look_at 让 −Z 指向目标，
	# 所以要看向「太阳的反方向」，光才是从太阳照过来。
	_sun.look_at_from_position(Vector3.ZERO, -to_sun, Vector3.UP)
	_sun.light_color = clock.sun_color()
	_sun.light_energy = clock.sun_energy()
	# 夜里直接关灯：能量为 0 时 Godot 仍会为这盏灯跑一遍光照通道，白花。
	_sun.visible = not clock.is_night()

	# 【阴影先关掉】现在场景里**一个投影体都没有**：地形与草都是
	# SHADOW_CASTING_SETTING_OFF（地形是因为高度场自投影必出 acne 且超三角面预算，
	# 见 v003；草是因为几万株草的阴影通道会把预算直接翻倍）。
	# 开着一盏没有投影体的阴影灯不是「无害的空转」—— 实测草地的 ATTENUATION
	# 被压到约 0.1，整片草暗了一个数量级，而地形几乎不受影响，
	# 于是草比它脚下的地表还暗，明暗关系正好反了（见 v010 的定位过程）。
	# P4 接入毡房、角色、牲畜时再打开 —— 那时才真的有东西需要投影。
	_sun.shadow_enabled = false


## 天空与环境光随时刻走。
##
## 交接文档 §07 记着「天空为自定义 shader，注意手动做线性→sRGB 编码，
## 否则整片天会暗掉两档」—— 自定义天空 shader 尚未做（见 v011 未完成项），
## 这里先驱动 ProceduralSkyMaterial：昼夜关系先立起来，换成自定义 shader 时
## 驱动逻辑照搬即可。
func _apply_sky() -> void:
	if _env.is_empty():
		return
	var e := ($WorldEnvironment as WorldEnvironment).environment
	var d := clock.daylight()
	var fog := Color(String(_env["fog"]))

	var sky_mat := e.sky.sky_material
	if sky_mat is ProceduralSkyMaterial:
		var sm := sky_mat as ProceduralSkyMaterial
		sm.sky_top_color = SKY_TOP_NIGHT.lerp(SKY_TOP_DAY, d)
		# 地平线用当季的雾色，天黑时一起压下去 —— 雾色与天空地平线必须同色，
		# 否则远山的轮廓会浮在一条色带上（v003 §五.1 就是靠改这个色定位到绕序问题的）。
		var horizon := SKY_HORIZON_NIGHT.lerp(fog, d)
		sm.sky_horizon_color = horizon
		sm.ground_horizon_color = horizon
	e.fog_light_color = SKY_HORIZON_NIGHT.lerp(fog, d)
	# 夜里只剩天光，压到很低但不给 0：全黑的话地形会变成纯黑剪影，读不出地貌。
	e.ambient_light_energy = lerpf(AMBIENT_ENERGY_NIGHT, AMBIENT_ENERGY_DAY, d)

## 夜空与白天天顶的颜色。夜色偏靛（呼应色板里的天山靛 #2E5C8A），不是纯黑。
const SKY_TOP_NIGHT := Color("#0b1626")
const SKY_TOP_DAY := Color("#3f7fc4")
const SKY_HORIZON_NIGHT := Color("#1b2536")
const AMBIENT_ENERGY_NIGHT := 0.06
const AMBIENT_ENERGY_DAY := 0.50
## 天空底色每隔多少**游戏分钟**重算一次。见 _process 里的说明。
const SKY_UPDATE_MINUTES := 2.0


## 取值型参数一律 `--key value`。放在一张表里而不是写一串 elif，
## 是为了加参数时不用再碰解析逻辑。
const ARG_KEYS := [
	"capture", "region", "variants",
	"cam",          ## overview | ground
	"shot",         ## 只拍一张就退出（目录）
	"frames",       ## 拍照前等多少帧
	"grass-debug",  ## 草地诊断模式，见 grass.gdshader 的 debug_mode
	"time",         ## HH:MM，设定世界时钟。截图模式下时钟自动停走
]


func _parse_args() -> Dictionary:
	var out := {}
	var a := OS.get_cmdline_user_args()
	for i in a.size():
		if not a[i].begins_with("--") or i + 1 >= a.size():
			continue
		var key := a[i].substr(2)
		if ARG_KEYS.has(key):
			out[key] = a[i + 1]
	return out


## 同一机位、同一地标，逐个改一个渲染开关各截一张。
## 用来把「台阶从哪来」这类问题一次问清楚，而不是改一次跑一次靠印象比对。
const VARIANTS := [
	{"name": "a_full", "desc": "全开"},
	{"name": "b_no_detail", "desc": "关程序化细节", "detail": 0.0},
	{"name": "c_no_skirt", "desc": "关裙边", "skirt_scale": 0.0},
	{"name": "d_flat_color", "desc": "单色（只看几何与光照）", "flat": true},
	{"name": "e_height_bands", "desc": "高程等值带（看数据本身有无台阶）", "bands": true},
	{"name": "f_normal", "desc": "法线可视化", "normal": true},
	{"name": "g_lv0", "desc": "只显示第 0 级", "level": 0},
	{"name": "h_lv2", "desc": "只显示第 2 级", "level": 2},
	{"name": "i_lv4", "desc": "只显示第 4 级", "level": 4},
	{"name": "j_lv6", "desc": "只显示第 6 级", "level": 6},
	{"name": "k_lv8", "desc": "只显示第 8 级", "level": 8},
	{"name": "l_levels", "desc": "分级着色（每级一个颜色，看覆盖与缺口）", "levels": true},
	{"name": "p_atten", "desc": "光照诊断：ATTENUATION（阴影）", "dbg": 5},
	{"name": "q_ndl", "desc": "光照诊断：N·L", "dbg": 6},
	{"name": "r_rampk", "desc": "光照诊断：ramp 输出 k", "dbg": 7},
	{"name": "s_lightcol", "desc": "光照诊断：LIGHT_COLOR", "dbg": 8},
	{"name": "l2_levels_noskirt", "desc": "分级着色 + 关裙边", "levels": true, "skirt_scale": 0.0},
	{"name": "m_topdown_4km", "desc": "正交俯视 4 km（看分级是否严丝合缝）", "ortho": 4000.0},
	{"name": "n_topdown_34km", "desc": "正交俯视 34 km（看整张 clipmap）", "ortho": 34000.0},
]


func _apply_variant(v: Dictionary) -> void:
	terrain_mat.set_shader_parameter("detail_gain", float(v.get("detail", 1.0)))
	clipmap.set_skirt_scale(float(v.get("skirt_scale", 1.0)))
	var dbg := 0
	if v.get("flat", false):
		dbg = 1
	elif v.get("bands", false):
		dbg = 2
	elif v.get("normal", false):
		dbg = 3
	elif v.get("levels", false):
		dbg = 4
	dbg = int(v.get("dbg", dbg))
	terrain_mat.set_shader_parameter("debug_mode", dbg)
	clipmap.show_only_level(int(v.get("level", -1)))

	# 正交俯视：透视图里分不清「空洞」和「被山挡住」，垂直往下看就一目了然。
	var ortho := float(v.get("ortho", 0.0))
	var env := ($WorldEnvironment as WorldEnvironment).environment
	if ortho > 0.0:
		_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
		_cam.size = ortho
		_cam.position = Vector3(0.0, 9000.0, 0.0)
		_cam.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
		_cam.set_process(false)
		# 俯视时相机离地几千米，深度雾会把整幅画面糊成一片，看不出结构
		env.fog_enabled = false
	else:
		_cam.projection = Camera3D.PROJECTION_PERSPECTIVE
		_cam.set_process(true)
		env.fog_enabled = true


# ───────────────────────────────────────────────────────────── 地形搭建

func _build_terrain() -> void:
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = load("res://client/render/terrain.gdshader")
	# 地形用专用 ramp（阶多、动态范围窄）。RAMP_NEAR 的四阶是给角色和动物的，
	# 铺到几公里宽的山体上会变成地质台阶 —— 见 Toon.RAMP_TERRAIN 的说明。
	terrain_mat.set_shader_parameter("ramp_near", Toon.ramp_terrain())
	terrain_mat.set_shader_parameter("ramp_far", Toon.ramp_far())

	streamer = TerrainStreamer.new()
	streamer.name = "TerrainStreamer"
	streamer.verbose = OS.get_cmdline_user_args().has("--verbose")
	add_child(streamer)

	clipmap = Clipmap.new(terrain_mat)
	clipmap.name = "Clipmap"
	add_child(clipmap)

	grass = GrassField.new()
	grass.name = "Grass"
	add_child(grass)

	# 地形与草必须用同一组高程窗口 uniform，否则草会浮空或陷进地里
	streamer.register(terrain_mat)
	streamer.register(grass.material)


## 跳到某个地标：重设锚点、强制建好窗口、把相机放到地面之上。
func _goto_region(key: String) -> void:
	var r := Regions.get_region(key)
	if r.is_empty():
		return
	var lon := float(r["lon"])
	var lat := float(r["lat"])

	GeoRef.set_origin(lon, lat)
	# 太阳按**真太阳时**走，而真太阳时取决于经度：全疆用北京时间，
	# 中央经线却在 120°E，那拉提差了 2 小时 22 分。见 WorldClock.set_longitude()。
	clock.set_longitude(lon)
	streamer.build_now(lon, lat)
	streamer.apply_all()
	_apply_season_for(r)

	# 两套机位：
	#   overview —— 正南 4 km、离地 1.4 km 俯瞰，读河谷走向与山脊格局；
	#   ground   —— 正南 60 m、离地 12 m 平视，看草、看脚下的质感。
	# 一个尺度回答不了两个问题，所以两套都要出。
	#
	# 离地高度必须按**相机所在位置**的地面算，不能拿地标中心的高程去减：
	# 那拉提中心 2217 m，南边几百米处却是 2496 m，用中心值会把相机放到地里。
	var is_ground := _cam_mode == "ground"
	var back := 40.0 if is_ground else 4000.0
	var up := 2.2 if is_ground else 1400.0
	var pitch := -0.10 if is_ground else -0.30

	var cam_geo: Array = GeoRef.local_to_geo(Vector3(0.0, 0.0, back))
	var ground := TerrainDB.sample(cam_geo[0], cam_geo[1])
	if ground == TerrainDB.NO_DATA:
		ground = TerrainDB.sample(lon, lat)
	if ground == TerrainDB.NO_DATA:
		ground = 0.0

	_cam.position = Vector3(0.0, ground + up, back)
	_cam.rotation = Vector3(pitch, 0.0, 0.0)
	_cam._yaw = 0.0
	_cam._pitch = pitch
	clipmap.snap_to(_cam.position)
	grass.snap_to(_cam.position)
	_update_hud()


## 按地标所属季节设置雪线与地表配色。P3 会接上完整的 EnvProfile 与昼夜。
##
## 【色彩空间】所有色板都是 sRGB 十六进制，送进着色器前必须 srgb_to_linear()。
## `source_color` 提示只影响编辑器的取色器，从 GDScript 用 set_shader_parameter
## 传进去的 Color 引擎不会替你转换 —— 不转的话整幅画面会过曝，草原会变成荧光黄。
func _apply_season_for(r: Dictionary) -> void:
	# 一次解析出完整档案，渲染侧只负责读 —— 派生量（雪线、干旱带、林线、草线、长势）
	# 以前散在这里和 grass.gd 两处各算各的，现在统一在 RegionEnv.resolve()。
	_env = RegionEnv.resolve(r)

	# 【必须 srgb_to_linear】引擎**不会**替 source_color uniform 做这个转换，
	# 这一条已由 tests/color_space_check.tscn 实测钉死（v011），别按直觉删掉。
	var set_col := func(name: String, hex: String) -> void:
		terrain_mat.set_shader_parameter(name, Color(hex).srgb_to_linear())

	# 地表基色用 ground 而不是 grass：grass 是给草地实例的颜色，
	# 把它铺满整个地表会让喀纳斯的秋色变成一整片火星红。压暗系数见 RegionEnv。
	set_col.call("color_grass", String(_env["ground_base"]))
	set_col.call("color_dry", String(_env["color_dry"]))
	set_col.call("color_rock", String(_env["color_rock"]))
	set_col.call("color_snow", String(_env["color_snow"]))
	set_col.call("color_sand", String(_env["color_sand"]))
	terrain_mat.set_shader_parameter("snow_line", float(_env["snow_line"]))
	terrain_mat.set_shader_parameter("dry_below", float(_env["dry_below"]))
	terrain_mat.set_shader_parameter("tree_line", float(_env["tree_line"]))

	if OS.get_cmdline_user_args().has("--verbose"):
		print("[env] %s season=%s grass=%s ground=%s 雾 %.0f–%.0f m" % [
			r["name"], _env["season"], _env["grass"], _env["ground"],
			_env["fog_begin"], _env["fog_end"],
		])

	grass.apply_env(_env)

	var e := ($WorldEnvironment as WorldEnvironment).environment
	e.fog_light_color = Color(String(_env["fog"]))
	# §07 的 fogNear/fogFar 是原型那个房间尺度世界的值，套到 16.4 km 的视距上
	# 会把整片天山糊没 —— RegionEnv 只继承季节之间的相对关系，绝对值按世界尺度给。
	e.fog_depth_begin = float(_env["fog_begin"])
	e.fog_depth_end = float(_env["fog_end"])
	_apply_sky()


# ───────────────────────────────────────────────────────────── 每帧

func _process(delta: float) -> void:
	if clipmap == null:
		return

	if clock.running:
		clock.advance(delta)
		# 太阳每帧更新（改几个属性，很便宜），天空**限频**。
		# 【为什么必须限频】改 ProceduralSkyMaterial 的颜色会让 Godot 重烘一遍
		# 天空的辐照度立方体贴图。每帧改就等于每帧重烘：实测 draw call
		# 从 80 涨到 118（预算 180），而画面上根本看不出区别 ——
		# 太阳颜色和方向本来就是每帧连续变的，天空底色隔两分钟跳一档没人看得出。
		_apply_sun()
		if absf(clock.minute_of_day - _last_sky_minute) >= SKY_UPDATE_MINUTES:
			_last_sky_minute = clock.minute_of_day
			_apply_sky()

	# 浮动原点：相机跑远了就把整个世界拉回锚点附近。
	# Vector3 是 32 位，离原点几千米以上顶点就开始抖。
	if GeoRef.maybe_rebase(_cam.position):
		var flat := Vector3(_cam.position.x, 0.0, _cam.position.z)
		_cam.position -= flat
		streamer.apply_all()

	var geo: Array = GeoRef.local_to_geo(_cam.position)
	streamer.update_for(geo[0], geo[1])
	streamer.apply_all()
	clipmap.snap_to(_cam.position)
	grass.snap_to(_cam.position)

	if _hud_visible:
		_update_hud()
	if _shot_dir != "":
		_step_shot()
	elif _variants_dir != "":
		_step_variants()
	elif _capture_dir != "":
		_step_capture()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.is_pressed() or event.is_echo():
		return
	match (event as InputEventKey).keycode:
		KEY_BRACKETRIGHT:
			_region_idx = (_region_idx + 1) % _region_keys.size()
			_goto_region(_region_keys[_region_idx])
		KEY_BRACKETLEFT:
			_region_idx = (_region_idx - 1 + _region_keys.size()) % _region_keys.size()
			_goto_region(_region_keys[_region_idx])
		KEY_F3:
			_hud_visible = not _hud_visible
			_hud.visible = _hud_visible
		KEY_F5:
			# 纯 DEM / 叠加程序化细节 对照。这是「哪部分是真实数据」的直观答案。
			_detail_on = not _detail_on
			terrain_mat.set_shader_parameter("detail_gain", 1.0 if _detail_on else 0.0)
		KEY_F6:
			# 关掉裙边：用来判断画面上的接缝到底来自 clipmap 分级还是来自数据。
			_skirt_on = not _skirt_on
			clipmap.set_skirt_scale(1.0 if _skirt_on else 0.0)
		KEY_F7:
			# 停住时间。调配色时必须能停 —— 时间一直走，改一个参数
			# 看到的差别里分不清哪些是参数带来的、哪些是太阳挪了。
			clock.running = not clock.running
		KEY_F8:
			# 快进两小时。用来快速走一遍晨昏，不用等真实时间。
			clock.minute_of_day = fposmod(clock.minute_of_day + 120.0, WorldClock.DAY_MINUTES)
			_apply_sun()
			_apply_sky()


# ───────────────────────────────────────────────────────────── 调试 HUD

func _update_hud() -> void:
	var geo: Array = GeoRef.local_to_geo(_cam.position)
	var src := TerrainDB.sample_with_source(geo[0], geo[1])
	var ground: float = src["height"]
	var r := Regions.get_region(_region_keys[_region_idx])

	var layer_note := "无数据"
	if src["layer"] != "none":
		var mpp := GeoRef.meters_per_pixel(geo[1], int(src["zoom"]))
		layer_note = "%s  z=%d  %.0f m/px" % [src["layer"], src["zoom"], mpp]

	var lines := [
		"[b]%s[/b]   [ ] 切换地标" % r.get("name", "?"),
		"时刻  [b]%s[/b] 北京时间  %s   日照 %.0f%%   季节 %s   (F7 停 / F8 +2h)" % [
			clock.hhmm(),
			"[color=#5a6b86]夜[/color]" if clock.is_night() else "[color=#f0cd84]昼[/color]",
			clock.daylight() * 100.0,
			_env.get("season", "?"),
		],
		"[color=#a8b39e]真太阳时 %s（新疆用北京时间，此地时差 %+.0f 分）[/color]" % [
			"%02d:%02d" % [int(clock.solar_minute()) / 60, int(clock.solar_minute()) % 60],
			clock.solar_offset_min,
		],
		"经纬  %.5f, %.5f" % [geo[0], geo[1]],
		"相机  海拔 %.0f m   离地 %.0f m" % [_cam.position.y, _cam.position.y - ground],
		"地面  %.0f m   [color=#8fb8dd]%s[/color]" % [ground, layer_note],
		"",
		"[color=#bfe8cc]真实 DEM 数据[/color]  +  [color=%s]程序化细节 %s[/color]  (F5 切换)" % [
			"#f0cd84" if _detail_on else "#9aa691", "开" if _detail_on else "关",
		],
		"[color=#a8b39e]28 m/px 以下的起伏是合成的，不是实测地貌[/color]",
		"",
		"%.0f fps   %d draw call   %.0f k 三角面" % [
			Engine.get_frames_per_second(),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0,
		],
	]
	_hud.text = "\n".join(lines)


# ───────────────────────────────────────────────────────────── 自动截图

func _step_shot() -> void:
	_capture_timer += 1
	if _capture_timer < _shot_frames:
		return
	var key := _region_keys[_region_idx]
	var img := get_viewport().get_texture().get_image()
	var p := _shot_dir.path_join("%s_%s.png" % [key, _cam_mode])
	img.save_png(p)
	print("截图 %s" % p)
	get_tree().quit()


func _step_variants() -> void:
	_capture_timer += 1
	# 第一次进来先把 variant 应用上，等几帧让窗口纹理和着色器编译完成再截。
	if _variant_idx < 0:
		if _capture_timer < 60:
			return
		_variant_idx = 0
		_apply_variant(VARIANTS[0])
		_capture_timer = 0
		return
	if _capture_timer < 24:
		return
	_capture_timer = 0

	var v: Dictionary = VARIANTS[_variant_idx]
	var img := get_viewport().get_texture().get_image()
	img.save_png(_variants_dir.path_join("%s.png" % v["name"]))
	print("变体 %-14s %s" % [v["name"], v["desc"]])

	_variant_idx += 1
	if _variant_idx >= VARIANTS.size():
		get_tree().quit()
		return
	_apply_variant(VARIANTS[_variant_idx])


func _step_capture() -> void:
	_capture_timer += 1
	if _capture_timer < CAPTURE_FRAMES:
		return
	_capture_timer = 0

	var key := _region_keys[_capture_idx]
	var img := get_viewport().get_texture().get_image()
	var p := _capture_dir.path_join("%d_%s_%s.png" % [_capture_idx, key, _cam_mode])
	img.save_png(p)
	print("截图 %s" % p)

	# 每处地标先出俯瞰、再出贴地，然后换下一处
	if _cam_mode == "overview":
		_cam_mode = "ground"
		_goto_region(key)
		return
	_cam_mode = "overview"

	_capture_idx += 1
	if _capture_idx >= _region_keys.size():
		get_tree().quit()
		return
	_region_idx = _capture_idx
	_goto_region(_region_keys[_capture_idx])


# ───────────────────────────────────────────────────────────── DEM 自检

func _run_dem_selftest() -> void:
	if TerrainDB.layers.is_empty():
		push_error("DEM 未烘焙。先跑：node tools/fetch_dem.mjs")
		return
	var fixtures := Regions.dem_fixtures()
	var passed := 0
	var report := PackedStringArray(["DEM 回归自检 (%d 点)" % fixtures.size()])
	for fx: Dictionary in fixtures:
		var got := TerrainDB.sample(float(fx["lon"]), float(fx["lat"]))
		if got == TerrainDB.NO_DATA:
			report.append("  —  %s：未烘焙" % fx["name"])
			continue
		var diff := absf(got - float(fx["expect_m"]))
		var ok := diff <= float(fx["tol_m"])
		if ok:
			passed += 1
		report.append("  %s  %s  %.0f m (期望 %s, 差 %.0f)" % [
			"✓" if ok else "✗", fx["name"], got, fx["expect_m"], diff,
		])
	report.append("  通过 %d/%d" % [passed, fixtures.size()])
	print("\n".join(report))
	if passed < fixtures.size():
		push_error("DEM 自检未全过 —— 地形数据可能不对，别拿它当真实地貌看")
