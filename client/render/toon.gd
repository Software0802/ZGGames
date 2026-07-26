class_name Toon
extends RefCounted
## 卡通渲染的共用参数与工具。
##
## 这些数值不是重新调的，是从 three.js 原型里搬过来的 —— 原型在 1920×1080 下
## 稳定 60 fps 验证过，交接文档 §07 明确说「以下参数可直接搬走」。

## 近景与角色用四阶硬 ramp。
const RAMP_NEAR: Array[float] = [0.46, 0.68, 0.86, 1.0]
## 远山与云用三阶柔和 ramp。
## 交接文档记录的坑：远景用硬阶会在地平线压出一道死黑带。
const RAMP_FAR: Array[float] = [0.66, 0.84, 1.0]

## 地形专用 ramp。
##
## 为什么不能直接用 RAMP_NEAR：那四阶是给角色和动物的 —— 它们在屏幕上只占几十像素，
## 硬分阶读起来是笔触。同一套阶数铺到几公里宽的山体上，每一阶会横跨上百像素，
## 看起来就是地质阶地，而不是卡通笔触（实测截图确认过：单色调试模式下整片山被切成
## 纯白与深绿两块硬边）。
##
## 所以地形用更多阶、更窄的动态范围：仍保留分阶的「块面感」，但不会把山切成台阶。
const RAMP_TERRAIN: Array[float] = [0.56, 0.67, 0.76, 0.84, 0.91, 0.96, 1.0]

## 描边外扩量（世界单位），按对象类别取。
const OUTLINE_CHARACTER := 0.014
const OUTLINE_ANIMAL := 0.025
const OUTLINE_BUILDING := 0.030

## 全游戏色板。交接文档 §08：禁止引入渐变背景、霓虹色，以及任何表外强调色。
const POMEGRANATE := Color("#B23A3A")  ## 石榴红
const TIANSHAN_INDIGO := Color("#2E5C8A")  ## 天山靛
const CHASED_GOLD := Color("#D9A441")  ## 錾金
const FELT_WHITE := Color("#F2ECE0")  ## 羊毛毡白
const JUJUBE_BROWN := Color("#7A5230")  ## 沙枣褐
const STEPPE_GREEN := Color("#3F6B4A")  ## 草原绿


## 把分阶值做成 N×1 的 R32F 查找纹理。
## 用 FORMAT_RF 而不是 L8：分阶边界值要精确，8 位量化会让台阶位置抖动。
static func make_ramp(steps: Array[float]) -> ImageTexture:
	var n := steps.size()
	var bytes := PackedByteArray()
	bytes.resize(n * 4)
	for i in n:
		bytes.encode_float(i * 4, steps[i])
	var img := Image.create_from_data(n, 1, false, Image.FORMAT_RF, bytes)
	return ImageTexture.create_from_image(img)


static func ramp_near() -> ImageTexture:
	return make_ramp(RAMP_NEAR)


static func ramp_far() -> ImageTexture:
	return make_ramp(RAMP_FAR)


static func ramp_terrain() -> ImageTexture:
	return make_ramp(RAMP_TERRAIN)


## 季节环境参数。数值来自交接文档 §07 的 SEASON_ENV 表。
## 地标覆写（吐鲁番戈壁、喀纳斯金色泰加林）在 region_env.gd 里叠加。
const SEASON_ENV := {
	"spring": {
		"grass": "#8bbd52", "ground": "#7aa845", "fog": "#cfe0d6",
		"fog_near": 150.0, "fog_far": 470.0,
		"grass_density": 1.0, "snow_line": 3300.0, "snow": false,
	},
	"summer": {
		"grass": "#79ad46", "ground": "#6f9e3f", "fog": "#bfd2cf",
		"fog_near": 160.0, "fog_far": 480.0,
		"grass_density": 1.0, "snow_line": 3800.0, "snow": false,
	},
	"autumn": {
		"grass": "#c2a049", "ground": "#b08c3e", "fog": "#dcd0b0",
		"fog_near": 140.0, "fog_far": 440.0,
		"grass_density": 0.8, "snow_line": 3100.0, "snow": false,
	},
	"winter": {
		"grass": "#d9e2df", "ground": "#e6ecea", "fog": "#dfe8ea",
		"fog_near": 90.0, "fog_far": 340.0,
		"grass_density": 0.28, "snow_line": 1200.0, "snow": true,
	},
}


static func season_env(season: String) -> Dictionary:
	return SEASON_ENV.get(season, SEASON_ENV["summer"])
