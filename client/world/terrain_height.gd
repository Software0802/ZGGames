class_name TerrainHeight
extends RefCounted
## 渲染地表高度的 CPU 复算：与 terrain_sample.gdshaderinc 逐比特一致。
##
## 地形在 GPU 上的最终高度 = 双线性 DEM + 程序化细节层（fbm，幅度随坡度与
## 视距变化）。CPU 放置的物件（毡房、羊、马、树）必须用**同一个函数**落地，
## 否则在高海拔、有细节起伏的地面上会悬空或陷进地里（细节幅度最大 ±2.6 m）。
## 这与「草用 ts_surface_height 落地」是同一条原则，见 grass.gdshader 头注。
##
## 噪声走查表：本脚本生成 256×256 RG8 梯度表，既上传给 GPU（grad_lut uniform）
## 也留在 CPU 供逐像素读取 —— 同一份字节，两侧天然一致（缘由见
## terrain_sample.gdshaderinc 的 ts_hash2 注释）。

## 与 terrain_sample.gdshaderinc 的 uniform 默认值保持一致。
## 这些值运行时不变（除 detail_gain，见下方静态变量），所以镜像为常量。
const DETAIL_BASE_FREQ := 0.018
const DETAIL_AMP := 2.6
const DETAIL_SLOPE_BOOST := 3.4
const DETAIL_FADE_DIST := 2600.0
const LUT_SIZE := 256
## 梯度表种子：改动即改变全图细节纹理，没有别的语义。
const LUT_SEED := 20260728

## F5 切换「纯 DEM / 带细节」时由 main.gd 写入；0 = 细节层关。
static var detail_gain := 1.0

static var _lut_img: Image
static var _lut_tex: ImageTexture


## 梯度表（懒加载）。返回值同时用于 set_shader_parameter("grad_lut")。
static func lut_texture() -> ImageTexture:
	if _lut_tex == null:
		_lut_img = Image.create(LUT_SIZE, LUT_SIZE, false, Image.FORMAT_RG8)
		var rng := RandomNumberGenerator.new()
		rng.seed = LUT_SEED
		for y in LUT_SIZE:
			for x in LUT_SIZE:
				# 单位圆上均匀随机方向的梯度（Perlin 式）
				var a := rng.randf() * TAU
				_lut_img.set_pixel(x, y, Color(cos(a) * 0.5 + 0.5, sin(a) * 0.5 + 0.5, 0.0))
		_lut_tex = ImageTexture.create_from_image(_lut_img)
	return _lut_tex


## 局部米制 (x, z) 处的渲染地表高度。cam_xz_dist 是该点到相机的水平距离，
## 细节层随视距淡出 —— 与 GPU 侧 ts_surface_height 的 dfade 同一语义。
static func surface_height(x: float, z: float, cam_xz_dist: float) -> float:
	var geo: Array = GeoRef.local_to_geo(Vector3(x, 0.0, z))
	var h := TerrainDB.sample(geo[0], geo[1])
	if h == TerrainDB.NO_DATA:
		h = 0.0
	var dfade := clampf(1.0 - cam_xz_dist / DETAIL_FADE_DIST, 0.0, 1.0)
	if detail_gain > 0.001 and dfade > 0.0:
		var n := dem_normal(x, z, 30.0)
		var slope := 1.0 - n.y
		var amp := DETAIL_AMP * detail_gain * dfade * (1.0 + slope * DETAIL_SLOPE_BOOST)
		h += fbm3(Vector2(x, z) * DETAIL_BASE_FREQ) * amp
	return h


## 双线性 DEM 高程（不含细节层）。
static func dem_height(x: float, z: float) -> float:
	var geo: Array = GeoRef.local_to_geo(Vector3(x, 0.0, z))
	var h := TerrainDB.sample(geo[0], geo[1])
	return 0.0 if h == TerrainDB.NO_DATA else h


## DEM 法线。差分步长贴数据分辨率（fine 层 28 m/px），与 GPU 侧 ts_dem_normal 一致。
static func dem_normal(x: float, z: float, e: float) -> Vector3:
	var hl := dem_height(x - e, z)
	var hr := dem_height(x + e, z)
	var hd := dem_height(x, z - e)
	var hu := dem_height(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


# ── 噪声：ts_hash2 / ts_gnoise / ts_fbm3 的逐行镜像 ──

static func _ihash2(px: float, py: float) -> Vector2:
	if _lut_img == null:
		lut_texture()
	var c := _lut_img.get_pixel(int(floorf(px)) & 255, int(floorf(py)) & 255)
	return Vector2(c.r * 2.0 - 1.0, c.g * 2.0 - 1.0)


static func gnoise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	var u := f * f * (Vector2(3.0, 3.0) - 2.0 * f)
	return lerpf(
		lerpf(_ihash2(i.x, i.y).dot(f), _ihash2(i.x + 1.0, i.y).dot(f - Vector2(1.0, 0.0)), u.x),
		lerpf(_ihash2(i.x, i.y + 1.0).dot(f - Vector2(0.0, 1.0)), _ihash2(i.x + 1.0, i.y + 1.0).dot(f - Vector2(1.0, 1.0)), u.x),
		u.y)


static func fbm3(p: Vector2) -> float:
	var s := gnoise(p)
	s += 0.5 * gnoise(p * 2.03)
	s += 0.25 * gnoise(p * 4.11)
	return s * 0.571
