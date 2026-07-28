class_name RegionEnv
extends RefCounted
## EnvProfile —— 季节 × 地标的环境参数表（交接文档 §07）。
##
## 交接文档把这张表定义为「季节基表 + 地标覆写」，`toon.gd` 的注释也一直写着
## 「地标覆写在 region_env.gd 里叠加」—— 但这个文件此前并不存在，
## 覆写从来没做过，而且各处的派生量（雪线、干旱带、林线、草线、草的长势）
## 散在 `main.gd` 与 `grass.gd` 两处各算各的。这里把它们收拢到一个函数里：
## **一次解析，出一份完整档案**，渲染侧只负责读。
##
## 不依赖场景树，客户端与服务器共用（M2 时服务器也要按季节算牧草产量）。

## 地标覆写。交接文档 §07 原文：
##   turpan 非冬季 grass→'#b09a52' ground→'#c0a163'（戈壁）
##   kanas  秋季   grass→'#c98f3a' ground→'#a8813c'（金色泰加林）
## 键是地标 key，值是 { 季节或 "*": { 字段: 值 } }。
const OVERRIDES := {
	"turpan": {
		"spring": {"grass": "#b09a52", "ground": "#c0a163"},
		"summer": {"grass": "#b09a52", "ground": "#c0a163"},
		"autumn": {"grass": "#b09a52", "ground": "#c0a163"},
	},
	"kanas": {
		"autumn": {"grass": "#c98f3a", "ground": "#a8813c"},
	},
}

## 地表分层配色。这几个不随季节变（岩石与沙子四季一个样），
## 但仍然放进档案里，免得渲染侧又出现一处硬编码。
const COLOR_DRY := "#a89050"
const COLOR_ROCK := "#6b675e"
const COLOR_SNOW := "#eaf0f2"
const COLOR_SAND := "#bfa068"

## 地表基色相对 ground 压暗多少。草会盖在它上面，压一点点才分得出
## 「草是长出来的一层」；压多了叶片之间的缝会读成黑洞（见 v010）。
const GROUND_DARKEN := 0.12

## 世界尺度的深度雾。
##
## 【为什么不用 §07 的 fogNear/fogFar】表里是 90–480 m，那是原型那个房间尺度的
## 世界的数字；本工程 clipmap 的可视半径是 16.4 km，480 m 的雾会把整片天山
## 糊成一堵墙 —— 而「远处真实的雪山轮廓」正是这个项目的招牌。
## 所以绝对值按世界尺度重新给，只把**季节之间的相对关系**从表里继承下来：
## 冬季 340/480 ≈ 0.71，于是冬天的雾在 0.71 倍距离上就到底。
## §07 的原值仍保留在 Toon.SEASON_ENV 里，作为原型记录，不要删。
const FOG_BEGIN_M := 4000.0
const FOG_END_M := 34000.0
## 相对基准取夏季的 far（480 m），其余季节按比例缩放。
const FOG_REF_FAR := 480.0


## 解析出一份完整档案。region 是 regions.json 里的一条；
## season 留空则取该地标 seasons 列表的第一项。
static func resolve(region: Dictionary, season: String = "") -> Dictionary:
	var seasons: Array = region.get("seasons", ["summer"])
	var key := season if season != "" else String(seasons[0])
	var base: Dictionary = Toon.season_env(key)

	var grass_hex := String(base["grass"])
	var ground_hex := String(base["ground"])
	var region_key := String(region.get("key", ""))
	var ov: Dictionary = OVERRIDES.get(region_key, {})
	if ov.has(key):
		var o: Dictionary = ov[key]
		grass_hex = String(o.get("grass", grass_hex))
		ground_hex = String(o.get("ground", ground_hex))

	var water := float(region["resource_mul"]["water"])
	var cap := float(region.get("carrying_capacity", 1.0))
	var lat := float(region["lat"])
	var density := float(base.get("grass_density", 1.0))
	var fog_scale := float(base.get("fog_far", FOG_REF_FAR)) / FOG_REF_FAR

	return {
		"season": key,

		# ── 交接文档 §07 的 EnvProfile 字段 ──
		"grass": grass_hex,
		"ground": ground_hex,
		# 水色目前没有消费方（水面是 P3 未做项），先按季节给个占位值，
		# 免得做水面时又去别处新造一份。
		"water": "#5b7f8c" if key != "winter" else "#8fa6ad",
		"fog": String(base["fog"]),
		"fog_near": float(base["fog_near"]),   ## 原型记录，见 FOG_BEGIN_M 的说明
		"fog_far": float(base["fog_far"]),     ## 同上
		"grass_density": density,
		"snow_particles": bool(base.get("snow", false)),
		# 林木密度：湿润地标多树，干旱地标几乎没有；冬季不落叶但视觉上稀疏。
		"tree_density": clampf(water, 0.0, 1.6) / 1.6 * (0.6 if key == "winter" else 1.0),
		# 坎儿井只在吐鲁番有（regions.json 里吐鲁番一处就有 1369 条 water 要素）
		"karez_visible": region_key == "turpan",
		"mountains_visible": true,

		# ── 世界尺度的雾（不是 §07 的房间尺度值） ──
		"fog_begin": FOG_BEGIN_M * fog_scale,
		"fog_end": FOG_END_M * fog_scale,

		# ── 地表分层 ──
		"ground_base": Color(ground_hex).darkened(GROUND_DARKEN).to_html(false),
		"color_dry": COLOR_DRY,
		"color_rock": COLOR_ROCK,
		"color_snow": COLOR_SNOW,
		"color_sand": COLOR_SAND,
		"snow_line": float(base["snow_line"]),
		# 干旱带阈值按水资源乘数走：吐鲁番戈壁的沙色要一直铺到很高，
		# 而伊犁河谷同样高度上是草。资源表在视觉上的直接体现。
		"dry_below": lerpf(1700.0, 400.0, clampf(water, 0.0, 1.6) / 1.6),
		# 林线随纬度降低：阿尔泰山（48°N）的云杉线远低于天山（43°N）。
		"tree_line": lerpf(2900.0, 2100.0, clampf((lat - 39.0) / 10.0, 0.0, 1.0)),

		# ── 草地 ──
		# 草的高矮直接反映草场质量：那拉提承载 1.8×，草深过膝；冬窝子 0.6×，草稀且矮。
		"grass_height_scale": clampf(cap * density, 0.15, 1.9),
		# 干旱地标的草线更高（低处是戈壁），湿润地标可以一直长到河谷底
		"grass_alt_min": lerpf(1500.0, 350.0, clampf(water, 0.0, 1.6) / 1.6),
		"grass_patch_bias": lerpf(0.55, 0.05, clampf(cap, 0.5, 1.8) / 1.8),
	}
