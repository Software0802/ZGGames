extends Node
## 验证 DEM 上传链路：.r16 字节 → tile_image(FORMAT_RF) → blit_rect 拼接 →
## ImageTexture 往返，每一步都要和原始 int16 对得上。
##
## 起因：地形渲染出来有明显的阶地状台阶，怀疑高程在某一步被量化了。
## 与其在着色器里猜，不如把链路逐段量出来。
##
## 跑法：godot --headless --path . tests/dem_texture_check.tscn

func _ready() -> void:
	if TerrainDB.layers.is_empty():
		printerr("未烘焙 DEM：先跑 node tools/fetch_dem.mjs")
		get_tree().quit(1)
		return

	var layer := TerrainDB.layer_by_id("L2")
	if layer == null:
		printerr("没有 L2 层")
		get_tree().quit(1)
		return

	# 那拉提所在的瓦片
	var lon := 84.4308
	var lat := 43.2960
	var tc: Array = GeoRef.lonlat_to_tile(lon, lat, layer.zoom)
	var tx := floori(float(tc[0]))
	var ty := floori(float(tc[1]))
	print("L2 瓦片 %d/%d/%d" % [layer.zoom, tx, ty])

	# ── 1. 原始 int16 ──
	var raw := TerrainDB._tile_bytes(layer, tx, ty)
	if raw.is_empty():
		printerr("瓦片未烘焙")
		get_tree().quit(1)
		return
	var lo := 99999
	var hi := -99999
	var uniq := {}
	for i in 65536:
		var v := raw.decode_s16(i * 2)
		lo = mini(lo, v)
		hi = maxi(hi, v)
		uniq[v] = true
	print("  int16 原始：min %d  max %d  不同取值 %d 个" % [lo, hi, uniq.size()])

	# ── 2. tile_image 转出的 FORMAT_RF ──
	var img := TerrainDB.tile_image(layer, tx, ty)
	print("  tile_image：%dx%d  format=%d (RF=%d)" % [
		img.get_width(), img.get_height(), img.get_format(), Image.FORMAT_RF,
	])
	var maxerr := 0.0
	for j in range(0, 256, 7):
		for i in range(0, 256, 7):
			var want := float(raw.decode_s16((j * 256 + i) * 2))
			maxerr = maxf(maxerr, absf(img.get_pixel(i, j).r - want))
	print("  int16→RF 最大误差 %.4f m" % maxerr)

	# ── 3. blit_rect 拼接 ──
	var big := Image.create_empty(512, 512, false, Image.FORMAT_RF)
	big.blit_rect(img, Rect2i(0, 0, 256, 256), Vector2i(256, 0))
	var blit_err := 0.0
	for j in range(0, 256, 11):
		for i in range(0, 256, 11):
			blit_err = maxf(blit_err, absf(big.get_pixel(256 + i, j).r - img.get_pixel(i, j).r))
	print("  blit_rect 最大误差 %.4f m" % blit_err)

	# ── 4. ImageTexture 往返（GPU 上传格式是否被降精度） ──
	var tex := ImageTexture.create_from_image(big)
	var back := tex.get_image()
	var tex_err := 0.0
	for j in range(0, 256, 11):
		for i in range(0, 256, 11):
			tex_err = maxf(tex_err, absf(back.get_pixel(256 + i, j).r - img.get_pixel(i, j).r))
	print("  ImageTexture 往返：format=%d  最大误差 %.4f m" % [back.get_format(), tex_err])

	# ── 5. 横切剖面：真实数据本身有没有台阶 ──
	print("\n  横切剖面（沿经度，每步约 28 m，共 24 步）：")
	var vals := PackedFloat64Array()
	for i in 24:
		vals.append(TerrainDB.sample(lon + float(i) * 0.00035, lat))
	var s := ""
	for v in vals:
		s += "%d " % roundi(v)
	print("  " + s)

	var maxjump := 0.0
	for i in range(1, vals.size()):
		maxjump = maxf(maxjump, absf(vals[i] - vals[i - 1]))
	print("  相邻最大跳变 %.1f m（28 m 水平间距下，>40 m 即坡度 >55°）" % maxjump)

	get_tree().quit(0)
