# v004 · S0 风险突刺实施记录：Google 实景瓦片进 Godot

状态：已实施，待评审
建立日期：2026-07-27
覆盖范围：v002 路线图的 S0 阶段（`docs/plans/v002-global-travel-vision.md:125-128`）

本文件不修改 v001–v003 的任何决策，只记录 S0 突刺实际做到哪一步、实测数字是多少。

---

## 一、一句话结论

**S0 的核心假设成立：Google Photorealistic 3D Tiles 能在 Godot 4.7.1 里流式加载，天池与乌鲁木齐两处均达 170+ fps、内存不足 100 MB，远超「1080p 稳定 ≥ 30 fps」的达标线。**

v002 因此没有触发「插件不达标即转 UE5」的提前评估条款。
但达标的是**性能**，不是**观感**——「动漫写实」风格验证尚未做，见第六节。

---

## 二、实际安装的东西

| 项 | 值 | 依据 |
|---|---|---|
| 插件 | 3D Tiles for Godot v1.0.1，预编译 Win64 | [GitHub Releases](https://github.com/Battle-Road-Labs/3D-Tiles-For-Godot/releases) |
| 发布日期 | 2025-08-31 | 同上 |
| GDExtension 声明的最低版本 | `compatibility_minimum = 4.2` | `bin/Godot3DTiles.gdextension` |
| 本机引擎 | Godot 4.7.1.stable.official | `godot --version` |
| 入库体积 | 16.8 MB（已剔除未被引用的 `~...template_debug.dll` 12.7 MB 与 `.exp`/`.lib`） | `bin/`、`addons/` |

插件按 `addons/cesium_godot/` + `bin/` 两个顶层目录安装。
注意 README 只说复制 `addons/`，但 release zip 的 `.gdextension` 位于 `bin/` 且内部路径写死 `res://bin/*.dll`，**两个目录都要复制到项目根**，只复制 `addons/` 会加载不到动态库。

### 刻意没做的两件事

**没有启用 `cesium_godot` 这个 EditorPlugin。**
它的全部职责是 Cesium ion 的 OAuth 面板与资产按钮（`addons/cesium_godot/cesium_godot.gd`）。
本突刺直连 Google，不需要 ion 账号；不启用还能避免编辑器启动时那次必然失败的 ion 资产列表请求。
GDExtension 注册的类（`Cesium3DTileset` 等）与 EditorPlugin 是否启用无关，照常可用。

**没有走 Cesium ion 中转。**
`Cesium3DTileset` 的 `data_source` 属性 hint 为 `From Cesium Ion,From Url`，取 `From Url`（值 1）即可直连。
这避免了引入第二个账号体系与第二层计费。

---

## 三、实测数据

硬件：RTX 5060 Laptop / Vulkan 1.4.312 / Forward+ / 1920×1080。
每组数据来自一次独立运行，采样 33 秒（前 2 秒不计入帧率统计）。

| 观测点 | 平均 fps | 1% low fps | 静态内存峰值 | 首批瓦片 | 收敛后三角面 | draw call |
|---|---|---|---|---|---|---|
| 天山天池（3400 m 空中） | 172.5 | 87 | 97 MB | 0.64 s | 130 998 | 451 |
| 乌鲁木齐市区（1450 m 空中） | 172.9 | 88 | 95 MB | 0.52 s | 91 157 | 391 |

对照 v001 自研地形管线在那拉提的实测（150 fps / 80 draw call / 551 k 面，`docs/plans/v003-session-handoff-01.md:94-95`）：
实景瓦片的三角面少一个数量级，但 draw call 高 5 倍——瓦片是大量独立网格，合批不了。
draw call 400+ 仍在交接文档 §07 的 <180 预算之外，**这是目前唯一越界的指标**，在 170 fps 下没有造成问题，但叠加角色、载具、UI 后需要复测。

值得注意：**城市比山地更轻**（91 k vs 131 k 面）。
摄影测量的城市网格在空中视距下 LOD 收得更狠，密集建筑并没有带来预期的几何爆炸。

### 瓦片加载行为

瓦片节点数在 10–15 秒收敛后完全静止（天池 504 个、乌市 434 个），此后不再增减。
`is_initial_loading_finished()` **始终返回 false**，即使画面早已收敛。
这个 API 不能用作加载完成的判据，S1 若要做加载进度条得另找信号。

---

## 四、成本核算（S0 必须产出的数字，v002 第三节遗留项）

| 项 | 值 | 依据 |
|---|---|---|
| SKU 归属 | Map Tiles API: Photorealistic 3D Tiles，Enterprise 级 | [Google 计费文档](https://developers.google.com/maps/documentation/tile/usage-and-billing) |
| 每月免费额度 | 1 000 次事件 | 同上（Enterprise SKU 免费额度） |
| 超出后单价 | $6.00 CPM，即 $0.006 / 次 | 同上 |
| 计费单位 | **root tileset 请求**，不是单张瓦片 | 同上：「Tile requests for Photorealistic 3D Tiles 不计入配额」 |
| 单次会话有效期 | 至少 3 小时 | [Photorealistic 3D Tiles 文档](https://developers.google.com/maps/documentation/tile/3d-tiles) |
| 每日上限 | 10 000 次 root tileset 查询 | 同上 |

**推算单用户成本：一次游戏启动 = 1 次 root 请求 = $0.006，且该会话可连续用 3 小时以上。**
按玩家每天启动一次、每月 30 次计，单用户月成本约 **$0.18**。
这个量级对任何商业模式都不构成压力，v002 第三节「商用规模下的单用户月成本待验证」一项到此关闭。

需要保留的警告：Google 的服务条款对**缓存与离线使用有限制**，本突刺未测试离线路径；
「买断制单机游戏 + 强制联网」的产品形态问题是商务问题，不是技术问题，留待 S5 决策。

免费额度对原型期完全够用：本次全部实测（含两次 curl 探测与 6 次引擎运行）共消耗约 8 次会话。

---

## 五、踩过的坑

这一节的写法沿用 v003 第五节：每条都已写进对应代码的注释里。

1. **首次导入必崩，第二次正常。**
   全新项目第一次 `godot --headless --path . --import` 在导入完成后以 `0xC0000005`（访问违例）退出，第二次起干净退出 0。
   对照实验（同一工程移除 `bin/` 后导入）退出 0，确认崩溃来自 GDExtension 的首次加载时序。
   不影响使用，但 CI 里不能把首次导入的退出码当失败。

2. **属性必须在 `add_child` 之前设完。**
   `Cesium3DTileset` 进入场景树时就按当时的 `data_source`/`url` 初始化 cesium-native 的 Tileset，之后再改 `url` 不会重建。
   先 `add_child` 再设属性的写法表现为：一切参数回读都正确，但画面永远空白、一个网络请求都不发。

3. **不调 `update_tileset()` 就永远不会加载。**
   LOD 选择与瓦片请求调度全部由每帧 `tileset.update_tileset(engine→ECEF 的相机变换)` 驱动。
   插件自带的 `GeoreferenceCameraController` 在 `_process` 里做这件事；不用那个控制器就必须自己调。

4. **引擎空间的 +Y 是地轴北极，不是当地天顶。**
   实测 `get_tx_ecef_to_engine()` 的基为 `x=(1,0,0) y=(0,0,-1) z=(0,1,0)`，即 ECEF 只做了一次轴交换（`v_engine = (vx, vz, -vy)`）。
   于是在 43.9°N，引擎 +Y 与当地天顶差约 46°。
   直接对 `Camera3D` 设欧拉角，得到的俯角是相对**地轴**的——设 -26° 实际拍出近乎垂直的卫星视角。
   正确做法是按经纬度构造当地 ENU 基，见 `client/spike/tiles_spike.gd` 的 `_local_basis()`。
   这个坑与 v003 第一节「怀疑画面不对时先分清数据/几何/着色」是同一类：先把坐标系问出来，别调参数。

5. **插件对加载失败完全静默。**
   用一个格式合法但无效的 key 运行，没有任何报错、没有超时提示，画面就是空的。
   因此判断成败只能看「画面上是否真的出现了三角面」，不能看有没有报错。
   突刺脚本据此用 `RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME` 做判据。

6. **退出时必然刷一屏渲染资源泄漏。**
   `Pages in use exist at exit`、`187 RID allocations ... were leaked at exit` 等。
   是插件没有在退出时释放瓦片网格，运行期无影响，但会淹没真正的报错，排查时要先过滤。

7. **cesium-native 会自动传播 key 与 session。**
   Google 的 root.json 里子瓦片 URI 是相对路径且**不含 key**（实测 120 个 child uri 均如此），session token 另在响应里。
   原本担心需要自己拼接，实测插件底层已处理，直接给 `root.json?key=...` 即可。
   这一条是 `From Url` 路线可行的关键，也是本次最不确定、最需要实测的一点。

---

## 六、诚实边界：S0 尚未完成的部分

v002 第 125–128 行给 S0 定的验收项里，以下两项**没有做**，不能算作已验证：

**「动漫写实」滤镜对比组没有做。**
这是 v002 第 59–62 行标注的美术假设（动漫角色 vs 照片级世界的风格冲突），也是 S5 引擎决策的关键输入之一。
本次只产出了原始写实观感的截图。

**近距离/步行视角没有测。**
全部实测都在 1450–3400 m 空中。
v002 第 47–50 行预判的「贴近后几何与纹理明显劣化」这一条，本次既没有证实也没有证伪。
这直接关系到 S1「精修步行区」的工作量估算，应当在 S1 动工前补测。

已经能看到的观感瑕疵：天池那组截图右侧有一块矩形色差，是不同批次航拍影像的拼接缝。
这类接缝在空中视角下会周期性出现，属于数据源固有特征，不是渲染问题。

---

## 七、本次新增的代码

```
client/spike/tiles_spike.gd     S0 突刺场景，纯代码构建，不依赖项目地形管线
client/spike/tiles_spike.tscn
addons/cesium_godot/            插件（原样，未改动）
bin/                            GDExtension 动态库与描述文件
google_maps_key.txt             API key，已 gitignore，不进版本库
```

突刺场景刻意与项目现有渲染管线完全隔离：
不引用 `client/render/terrain.gdshader`，因此 v003 第四节记录的着色器编译故障不会影响它，反之亦然。

常用命令：

```bash
godot --path . client/spike/tiles_spike.tscn -- --site tianchi --seconds 33 --capture out/
```

```bash
godot --path . client/spike/tiles_spike.tscn -- --site urumqi --pitch -22 --yaw 200
```

```bash
godot --path . client/spike/tiles_spike.tscn -- --scan --capture out/
```

`--scan` 会在一次会话里把俯角依次打到 0/-20/-40/-60/-90/+20 各截一张。
瓦片按 root 请求计费，一次跑完六个角度比跑六次省 5 次配额——这是配额友好的调试方式。

API key 按 `--key` > 环境变量 `GOOGLE_MAPS_API_KEY` > `google_maps_key.txt` 的优先级解析，
且日志里一律脱敏成 `AIza…5ex0`。

---

## 八、建议的下一步

1. **补 S0 剩余两项**：动漫写实滤镜对比组、步行视角实测。
   后者决定 S1 精修区的人时估算，优先级高于前者。
2. **修 v003 第四节第 1 条的着色器故障**。
   它与本突刺互不影响，但项目主场景 `client/main.tscn` 目前仍是坏的，不能长期挂着。
3. **决定实景瓦片与自研 clipmap 地形的合成策略**（v002 第 103 行已提出方向）。
   两套地形现在各自能跑，但没有共存过；瓦片区内 clipmap 如何让位是 S1 的前置设计。
4. **给 API key 加使用限制**。
   Google Cloud Console 里可对 key 设置 API 限制（只允许 Map Tiles API）与配额上限，
   避免 key 泄漏后产生非预期账单。这是运维动作，不是代码动作。
