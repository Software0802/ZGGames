class_name WorldClock
extends RefCounted
## 世界时钟：一天的分钟数，以及由它导出的太阳位置与光色。
##
## 为什么放在 shared/sim 而不是做成 autoload：时间是**模拟状态**，M2 上权威服务器
## 要拿它驱动放牧、转场、事件，客户端只是跟随显示。做成 autoload 就等于绑在场景树上，
## 搬去 server/ 时又得拆一遍（见 README 的目录约定：shared 禁止依赖场景树）。
##
## 太阳角公式来自交接文档 §07，原样照搬：
##
##     太阳角 = ((minuteOfDay/60 − 6) / 24) × 2π
##
## 即 6:00 为 0（日出）、12:00 为 π/2（正午）、18:00 为 π（日落）、0:00 为 −π/2。

## 一天多少分钟。
const DAY_MINUTES := 1440.0

## 现实 1 秒 = 游戏多少分钟。24 现实分钟过完一天 —— 这个值以后由玩法定，
## 先给一个能在实机上肉眼看出昼夜变化、又不至于晃眼的速度。
const DEFAULT_TIME_SCALE := 60.0

## 正午时太阳的最大仰角（度）。
##
## 【为什么不直接用 sin(太阳角) 当仰角】那等于正午太阳在天顶，只有赤道才成立；
## 新疆在 39–49°N，夏至正午也就 65–70°，而且 v003 已经实测过：仰角再高
## 会把山坡的明暗差压没（正午卫星图效果），起伏就读不出来了。
## 所以公式只用来定**相位**，幅度由这里限住。58° 是「够亮但山脊仍有明暗面」的折中，
## 与 v003 手调的那个 50° 同一量级。
const SUN_ELEVATION_MAX_DEG := 58.0

## 天亮/天黑的判定阈值（仰角度数）。低于 −6° 是天文意义上的暮色结束。
const CIVIL_TWILIGHT_DEG := -6.0

## 日出日落时的暖色与正午的白光。两端插值，插值系数用仰角而不是时间 ——
## 冬夏日照长度不同，按时间插会让冬天整天都是「黄昏色」。
const SUN_COLOR_HORIZON := Color("#ffb26b")
const SUN_COLOR_NOON := Color("#fff1da")
## 太阳最大光照强度。v003 手调的静态太阳用的是 1.55，这里作为正午值沿用。
const SUN_ENERGY_MAX := 1.55

## 时区所依据的中央经线。全中国统一用北京时间（UTC+8），中央经线 120°E。
const TIMEZONE_MERIDIAN := 120.0

## 钟面时刻（北京时间的分钟数）。这是 NPC 作息、事件、UI 显示用的时间。
var minute_of_day: float = 9.0 * 60.0
var time_scale: float = DEFAULT_TIME_SCALE
var running: bool = true

## 真太阳时相对钟面时刻的偏移（分钟），由当前经度定，见 set_longitude()。
var solar_offset_min: float = 0.0


## 【新疆的时差是真的】全疆用北京时间，而中央经线在 120°E ——
## 那拉提在 84.43°E，差了 35.6 个经度，合 2 小时 22 分。
## 也就是说那拉提的太阳最高点不在 12:00，而在**14:22**；夏天太阳落山要到 21 点多。
## 「新疆天黑得晚」不是错觉，是钟面时间和太阳时差了两个多小时。
##
## 这件事必须做对，否则一到傍晚画面就和常识对不上：按 §07 的公式直接算，
## 19:30 的那拉提会是全黑的，而真实的那拉提那会儿太阳还挂着。
##
## 钟面时间照常走北京时间（玩法与 UI 用它），只有太阳位置用真太阳时。
func set_longitude(lon: float) -> void:
	solar_offset_min = (lon - TIMEZONE_MERIDIAN) * 4.0  # 每经度 4 分钟


## 真太阳时的分钟数。太阳的一切都由它算，钟面时刻只管显示。
func solar_minute() -> float:
	return fposmod(minute_of_day + solar_offset_min, DAY_MINUTES)


func advance(delta: float) -> void:
	if not running:
		return
	minute_of_day = fposmod(minute_of_day + delta * time_scale, DAY_MINUTES)


func set_time(hour: int, minute: int) -> void:
	minute_of_day = fposmod(float(hour) * 60.0 + float(minute), DAY_MINUTES)


## "07:30" → 分钟数。解析失败返回 -1，调用方自己决定怎么处理。
static func parse_hhmm(s: String) -> float:
	var parts := s.split(":")
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return -1.0
	return fposmod(float(int(parts[0])) * 60.0 + float(int(parts[1])), DAY_MINUTES)


func hhmm() -> String:
	var m := int(minute_of_day)
	return "%02d:%02d" % [m / 60, m % 60]


## 交接文档 §07 的太阳角。只决定相位，不直接当仰角用。
func sun_angle() -> float:
	return (solar_minute() / 60.0 - 6.0) / 24.0 * TAU


## 太阳仰角（弧度）。负数表示在地平线以下。
func sun_elevation() -> float:
	return sin(sun_angle()) * deg_to_rad(SUN_ELEVATION_MAX_DEG)


## 太阳方位角（弧度，0 = 正北，顺时针为正）。
## 北半球：日出偏东（90°）、正午偏南（180°）、日落偏西（270°）。
func sun_azimuth() -> float:
	return deg_to_rad(90.0 + (solar_minute() / 60.0 - 6.0) / 12.0 * 180.0)


## 「从原点指向太阳」的单位向量。世界约定：+X 东，−Z 北（与 main.gd 一致）。
func to_sun() -> Vector3:
	var el := sun_elevation()
	var az := sun_azimuth()
	return Vector3(
		sin(az) * cos(el), sin(el), -cos(az) * cos(el)
	).normalized()


## 0 = 完全天黑，1 = 正午。用仰角而不是时间，冬夏都对。
func daylight() -> float:
	var el_deg := rad_to_deg(sun_elevation())
	return clampf(
		(el_deg - CIVIL_TWILIGHT_DEG) / (SUN_ELEVATION_MAX_DEG - CIVIL_TWILIGHT_DEG),
		0.0, 1.0
	)


func is_night() -> bool:
	return rad_to_deg(sun_elevation()) < CIVIL_TWILIGHT_DEG


## 太阳光色。贴近地平线时偏暖。
func sun_color() -> Color:
	# 用 daylight 的平方根：太阳刚出地平线那一小段仰角变化最快，
	# 线性插值会让暖色只闪一下就没了。
	return SUN_COLOR_HORIZON.lerp(SUN_COLOR_NOON, sqrt(daylight()))


func sun_energy() -> float:
	return SUN_ENERGY_MAX * daylight()
