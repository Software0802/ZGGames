# v003 · 会话交接（第 1 次实施会话）

状态：交接
建立日期：2026-07-27
覆盖范围：v001 技术底座的 P0–P3 实施进度

本文件不改变 v001 与 v002 的任何决策，只如实记录**代码走到了哪一步**。
v002 已明确「v001 的地形数据管线、坐标系红线、渲染管线全部继续有效」——
本次会话做的正是这三样，所以这份进度对全球旅游地图方向同样有效，不是沉没成本。

---

## 一、一句话现状

**真实地形数据管线与大世界流式地形已经跑通并验证；卡通渲染管线（P3）做到一半，当前 HEAD 是坏的。**

坏在哪：最后一次渲染里地形变成一整块纯白平面，这是 Godot 着色器编译失败后的回退材质。
起因是修 `light()` 时的改动，**尚未定位到具体报错**（诊断命令被中断，没跑完）。
下一步第一件事就是把它查出来，见第七节。

---

## 二、已完成并验证

### P0 · 工程地基（完成）

- Godot 4.7.1 经 scoop 安装（`D:\tools\scoop\shims\godot.exe`）。
- `project.godot`（Forward+，物理 60 Hz，`config_version=5`，`features=("4.7")`）。
  版本号格式是从 `godotengine/godot-demo-projects` 的实际文件确认的，不是猜的。
- `git init` 完成，尚无提交。
- 原 zip 解包到 `docs/reference/`（`prototype.dc.html`、`handoff.dc.html`、`support.js`），只读参考。
- 输入映射在运行时用 `KEY_*` 枚举注册（`client/input_actions.gd`），不写进 `project.godot`——
  后者是硬编码 keycode 整数，跨版本没有稳定性保证。

### P1 · 地形数据管线（完成，9/9 回归通过）

数据源 AWS Open Data «Terrain Tiles»（terrarium 编码 PNG，无需 API key）。
`tools/fetch_dem.mjs` 下载 → 解码 → 裁成 `.r16`（有符号 int16，单位米）→ 写 `assets/terrain/`。
零依赖：PNG 解码器（含逐行滤波器还原）自己实现在 `tools/geo.mjs`。

烘焙结果：三层金字塔共 **764 块瓦片**。

| 层 | zoom | 分辨率 @43°N | 覆盖 |
|---|---|---|---|
| L0 | 8 | 447 m/px | 全疆 288 块 |
| L1 | 10 | 112 m/px | 地标与牧道周边 138 块 |
| L2 | 12 | 28 m/px | 核心可行走区与走廊 338 块 |

z=12 与 SRTM 1 弧秒原生 30 m 相当，**这是真实数据的上限**，更细的起伏由着色器分形合成。

**DEM 回归自检 9/9 通过**（`shared/data/regions.json` 的 `dem_fixtures`）。
同一组断言在 Node 侧（`node tools/fetch_dem.mjs --verify`）与 Godot 侧（启动时自动跑）各跑一遍，逐点一致——
这证明两边的墨卡托换算实现是等价的。

| 采样点 | 解码值 | 公认值 | 落在 |
|---|---|---|---|
| 艾丁湖 | −152 m | −154 m | L1 |
| 吐鲁番市 | 35 m | 35 m | L2 |
| 火焰山 | 561 m | 559 m | L1 |
| 那拉提河谷 | 1399 m | 1399 m | L2 |
| 喀纳斯湖面 | 1363 m | 1374 m | L2 |
| 阿勒泰市 | 849 m | 850 m | L1 |
| 喀什市 | 1294 m | 1289 m | L2 |
| 汗腾格里峰 | 6919 m | 7010 m | L0（447 m/px，峰顶必然被平滑） |
| 乔戈里峰 K2 | 8265 m | 8611 m | L0（同上） |

矢量层由 `tools/fetch_osm.mjs` 从 Overpass 拉取，共 1.6 MB GeoJSON（`assets/vector/`）。
吐鲁番一处就有 1369 条 water 要素——那正是坎儿井渠网。
**有 4 组查询超时未返回**：`kanas/places`、`narati/land`、`kashgar/ways`、`altay_winter/places`。
脚本有缓存，重跑只补缺的。

### 考据修正：牧场选点是实测出来的，不是拍的

原方案的「中山带春秋牧场」选点实测只有 **548 m**，还在准噶尔盆地底上，春季转场爬升仅 63 m——
垂直迁徙根本不成立。

于是给 `tools/probe.mjs` 加了 `--site` 自动选址：在框内按「高程接近目标 + 6 km 半径内起伏最小」打分。
牧场要的是山间草甸而不是悬崖面，起伏必须量化，不能靠肉眼在等高线上挑。

重选后阿勒泰系统的四季爬升为 **498 → 1307 → 1992 → 1397 → 498 m**，单圈 582 km，对得上「千里转场」。
中山带选点 6 km 半径内起伏标准差仅 58 m，伊犁河谷冬牧场仅 3 m——是真能放牧的地形。
为此在交接文档的 5 个地标之外增加了 `altay_spring` / `altay_summer` / `ili_winter` 三个中继牧场，
否则垂直迁徙没有中间站。全部记录在 `shared/data/regions.json` 的 `_deviation` 字段里。

### P2 · 地形渲染与流式（完成）

- `client/render/clipmap.gd`：9 级同心方环，GRID=128，最内 1 m 间距，覆盖半径 16.4 km。
- `client/render/terrain.gdshader` + `terrain_sample.gdshaderinc`：GPU 顶点位移，
  逐顶点做 局部米 → 经纬度 → 瓦片坐标 的**完整逆投影**（不是线性映射，理由见 include 文件注释）。
- `client/world/terrain_streamer.gd`：两张跟随玩家的高程窗口纹理（fine 6×6 瓦片 ≈ 43 km，coarse 4×4 ≈ 458 km），
  分帧构建 + 双缓冲，不用线程也不掉帧。
- `shared/sim/georef.gd`：地理真值用 `float`（64 位），`Vector3`（32 位）只作当帧局部坐标，2048 m 浮动原点重锚。

实测（那拉提，1920×1080，RTX 5060 Laptop）：**150 fps / 80 draw call / 551 k 三角面**，
全部在交接文档 §07 的预算内（60 fps / <180 draw call / <900 k 面）。

八处地标均已实机截图验证：吐鲁番洼地脚下 −27 m（低于海平面）且地貌平坦，
那拉提有真实山脊与远处天山雪线，喀纳斯是冰川湖谷。

---

## 三、进行中：P3 · 卡通渲染管线

已做：

- `client/render/toon.gd`：ramp 查找纹理、色板常量、`SEASON_ENV` 表。
- 地形专用七阶 ramp（`RAMP_TERRAIN`）。
- `client/render/grass.gd` + `grass.gdshader`：两圈 MultiMesh 草地（近 21000 株 / 78 m，远 12000 株 / 260 m），
  十字双面片、顶点渐窄、按高度加权的风摆动。
  **草的落地高度在着色器里复用 `ts_surface_height` 算**，CPU 完全不参与，移动时只吸附节点。
- 太阳角改为用方向向量 + `look_at` 设定（欧拉角顺序太容易把仰角方位角搞反）。

未做：天空 shader、云、雪、水面、树木、昼夜循环、完整 EnvProfile 切换、描边（`next_pass` + `cull_front`）。

---

## 四、当前的已知问题（按优先级）

1. **【阻塞】地形着色器疑似编译失败**，画面是回退材质（纯白平面、无位移）。
   出现在修 `light()` 的那一轮改动之后。具体报错未确认。
2. 上一条掩盖了一个刚修好、但**尚未通过视觉验证**的问题：见第五节第 6 条（ALBEDO 二次相乘）。
3. OSM 4 组查询缺失（见第二节）。
4. 草与地表的配色对比、季节色饱和度都还没调好——这是 P3 剩下的主要工作。
5. `tools/build_routes.mjs`（牧道折线的最小代价路径生成）未做，推迟到 P6。

---

## 五、踩过的坑（这一节是本次会话最有价值的产出）

每条都已写进对应文件的注释里，避免重犯。

1. **三角形绕序反了。** `cull_back` 把地形的可见面整片剔掉，画面上表现为大片「空洞」，
   透过去看到的是天空下半球。这个现象极像着色或数据问题，先后误判成 ramp 分阶、法线、缺瓦片，
   最后靠「把天空的 `ground_bottom_color` 改成品红」才定位。
   → 教训：怀疑「画面上少了东西」时，先把背景改成刺眼的纯色，一步就能区分「没画」和「画黑了」。

2. **色彩空间。** `source_color` 提示只影响编辑器取色器；从 GDScript 用 `set_shader_parameter`
   传 `Color` 时引擎**不会**替你转换，必须自己 `.srgb_to_linear()`，否则整片过曝。

3. **卡通 ramp 不能一套走天下。** 四阶硬 ramp 是给角色的（屏幕上几十像素，读起来是笔触），
   铺到几公里宽的山体上每一阶跨上百像素，看起来是地质阶地。地形另配七阶窄动态范围 ramp。
   而且半兰伯特（`ndl*0.5+0.5`）会把 t 压在 0.5–1.0，地形法线大多朝上，
   六阶 ramp 实际只出两档——要用 wrap 把 t 拉开。

4. **法线差分步长要贴数据分辨率，不是贴网格密度。** 之前按视距放大到 260 m，把真实山脊磨成了折纸。
   fine 层 28 m/px 就用 30 m 差分。

5. **精细层的烘焙范围永远是有限的。** 窗口边缘缺格若留 0，那片地形会塌到海拔 0 m
   （在 2500 m 的那拉提就是往下掉 2500 m），画面上是「空洞 + 垂直墙」。
   `TerrainDB.tile_image_or_coarser()` 从粗层抠子区域放大补上，回退不是可选项。

6. **`light()` 里不要乘 ALBEDO。** Godot 官方示例是
   `DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0, 1) * ATTENUATION * LIGHT_COLOR / PI;`——
   没有 ALBEDO，引擎在之后自己乘。再乘一次等于 albedo 平方：中绿 0.16 变成 0.026，整片黑掉。
   这个坑排查了好几轮（先后误判成阴影自遮挡、太阳角、色彩空间），最后是靠
   「把 ATTENUATION / N·L / ramp k 逐个可视化」才定位。
   `LIGHT_COLOR` 已含 energy × PI，所以要除回 PI。
   **修改已提交但尚未通过视觉验证**（被第四节第 1 条挡住）。

7. **clipmap 分级接缝需要重叠，不能只靠裙边。** 第 L 级吸附到 2·s_L，第 L−1 级吸附到 s_L，
   中心最多差 s_L，洞口尺寸若正好等于上一级覆盖范围就会留缺口。
   洞每边内缩 2 格后重叠恒为 2·s_L。裙边深度按级缩放（`spacing × 3`），
   给大了会适得其反：系数 14 时裙边变成一堵挡住整片远景的墙。

8. **地形自阴影得不偿失。** 高度场自投影在低视角下必出 shadow acne，整片坡把自己遮黑；
   阴影通道还要把几何再提交一遍，开到第 5 级三角面就冲到 92.8 万，超预算。
   已关闭，阴影留给 P4 的毡房、角色、牲畜。

9. **`Window` 撞 Godot 原生类名**，内部类不能这么起名。

10. **新增 `class_name` 脚本后必须先 `godot --headless --path . --import`**，
    否则无头启动时全局类名注册表还没建好，会报「Identifier not declared」。

11. **`floor()` 返回 Variant**，静态类型推导不出来；要用 `floorf()` / `floori()`。

---

## 六、工程结构与命令速查

```
docs/reference/   原型与技术交接文档（只读）
docs/plans/       v001 技术方案 / v002 全球愿景 / v003 本文件
tools/            Node 烘焙管线，不进运行时
  geo.mjs           瓦片换算 + 零依赖 PNG 解码 + terrarium 解码
  fetch_dem.mjs     高程烘焙 + 回归自检 + 牧道剖面校验
  fetch_osm.mjs     Overpass 矢量拉取（串行 + 限流，勿改并发）
  probe.mjs         高程查询 / 网格扫描 / 剖面 / --site 自动选址
assets/terrain/   764 块 .r16 + index.json（已 gitignore，可重建）
assets/vector/    GeoJSON（已 gitignore）
shared/sim/georef.gd        坐标系红线
shared/data/regions.json    地标与牧道唯一真相源（GDScript 与 Node 都读它）
client/render/    clipmap / terrain.gdshader / terrain_sample.gdshaderinc / grass / toon
client/world/     terrain_db / terrain_streamer / freecam
client/main.gd    世界根节点 + 调试 HUD + 变体截图
tests/            dem_texture_check / image_api_check（.tscn 跑）
```

常用命令：

```bash
node tools/fetch_dem.mjs --dry-run
```

```bash
node tools/fetch_dem.mjs --verify
```

```bash
node tools/probe.mjs --site 86.85 48.35 87.45 48.75 2000 6000
```

```bash
godot --headless --path . --import
```

```bash
godot --headless --path . --quit-after 120
```

```bash
godot --path . -- --capture out/ 
```

```bash
godot --path . -- --region narati --variants out/
```

游戏内：`[` `]` 切换地标，`F3` HUD，`F5` 纯 DEM / 叠加程序化细节对照，`F6` 裙边开关。

---

## 七、下一步（建议顺序）

1. **查清着色器编译失败**：`godot --headless --path . -- --region narati 2>&1 | grep -iE "shader|line"`。
   怀疑点是 `light()` 里的 `return` 早退分支，或 `debug_mode >= 5` 那段。
   修好后先确认第五节第 6 条（去掉 ALBEDO 二次相乘）在画面上确实生效——
   预期地表从近黑变成中绿。
2. 把「渲染回归」做成自动化：目前每次改完都要人眼看 16 张图。
   可以在 `--capture` 之后加一步，对若干固定像素做亮度断言，
   一旦画面整体变黑/变白就直接报错，而不是等人去看。
   本次会话在「画面黑了」上花的时间远超写代码的时间，值得先把这道闸门补上。
3. 调平草与地表的配色对比、季节饱和度。
4. 补 P3 剩余项：天空 shader（注意交接文档记录的坑：手动做线性→sRGB 编码）、水面（用已烘焙的 OSM water）、
   树木（用 OSM `natural=wood` 多边形约束位置，不要随机撒）、描边、昼夜。
5. 补 OSM 缺失的 4 组查询。

---

## 八、给下一位（或下一轮）的三句话

- 地形数据是真的，且有 9 点回归断言守着；**动了 `TerrainDB` 或烘焙管线就必须让它继续全绿**。
- 坐标系那条红线（geo 存 `float`，`Vector3` 只当帧用）比看起来重要，离锚点几百公里处才会暴露。
- 这个项目里「画面不对」有至少三类原因：数据、几何、着色。
  别在着色器里猜——先用调试变体把它们分开（`--variants` 已经把常用的几种做好了）。
