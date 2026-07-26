extends Node
## 确认 Image.get_region / resize 在 FORMAT_RF（32 位浮点单通道）上可用且不丢精度。
## 补缺失瓦片要靠「从粗层抠一小块再放大」，这两个 API 必须真的支持浮点格式，
## 否则高程会被悄悄量化成 8 位 —— 那正是我们花了半天排查的那类问题。

func _ready() -> void:
	var n := 64
	var bytes := PackedByteArray()
	bytes.resize(n * n * 4)
	for j in n:
		for i in n:
			# 造一个已知的斜面：值域覆盖真实高程范围（含负值，艾丁湖 −154 m）
			bytes.encode_float((j * n + i) * 4, -200.0 + float(i) * 137.0 + float(j) * 3.5)
	var src := Image.create_from_data(n, n, false, Image.FORMAT_RF, bytes)
	print("源图 format=%d  (0,0)=%.2f  (63,63)=%.2f" % [
		src.get_format(), src.get_pixel(0, 0).r, src.get_pixel(63, 63).r,
	])

	# get_region
	var sub := src.get_region(Rect2i(16, 16, 16, 16))
	print("get_region：%dx%d format=%d  (0,0)=%.2f 期望 %.2f" % [
		sub.get_width(), sub.get_height(), sub.get_format(),
		sub.get_pixel(0, 0).r, -200.0 + 16.0 * 137.0 + 16.0 * 3.5,
	])

	# resize 放大
	var up := sub.duplicate() as Image
	up.resize(256, 256, Image.INTERPOLATE_BILINEAR)
	print("resize：%dx%d format=%d  (0,0)=%.2f  (255,255)=%.2f" % [
		up.get_width(), up.get_height(), up.get_format(),
		up.get_pixel(0, 0).r, up.get_pixel(255, 255).r,
	])

	# blit 回大图
	var big := Image.create_empty(512, 512, false, Image.FORMAT_RF)
	big.blit_rect(up, Rect2i(0, 0, 256, 256), Vector2i(0, 0))
	print("blit 后 (10,10)=%.2f  期望 %.2f" % [big.get_pixel(10, 10).r, up.get_pixel(10, 10).r])

	var ok := up.get_format() == Image.FORMAT_RF and absf(up.get_pixel(10, 10).r - big.get_pixel(10, 10).r) < 0.01
	print("结论：%s" % ("可用" if ok else "不可用 —— 需要改走手工上采样"))
	get_tree().quit(0 if ok else 1)
