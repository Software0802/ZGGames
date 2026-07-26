# 天山牧歌 · Tianshan Pastorale

多人草原模拟经营，跑在**真实新疆地形**上。
Godot 4 / GDScript。

游戏的世界不是手捏的：地形来自公开的 SRTM / GMTED2010 高程数据，河湖与道路来自 OpenStreetMap。
吐鲁番艾丁湖在游戏里真的低于海平面 155 米，喀纳斯湖面真的在 1363 米。

---

## 数据来源与署名

本项目使用的开放数据，署名依其许可要求保留，不得删除。

**高程**
AWS Open Data «Terrain Tiles»（terrarium 编码），经 `tools/fetch_dem.mjs` 离线烘焙。
新疆范围内的数据源为 SRTM 与 GMTED2010，按 [tilezen/joerd 署名要求](https://github.com/tilezen/joerd/blob/master/docs/attribution.md)：

> 3DEP (formerly NED) and global GMTED2010 and SRTM data courtesy of U.S. Geological Survey

**矢量（河流 / 湖泊 / 道路 / 地名）**
OpenStreetMap，经 Overpass API 拉取。许可 ODbL。

> © OpenStreetMap contributors

**精度的诚实边界**
真实高程数据的上限是 z=12（43°N 约 27.9 m/px，与 SRTM 1 弧秒原生 30 m 相当）。
比这更细的地表起伏由分形噪声合成，**不是**实测地貌。
游戏内按 `F3` 打开调试 HUD，会标出脚下高程来自哪一层数据。

---

## 环境要求

| 工具 | 版本 | 用途 |
|---|---|---|
| Godot | 4.7.x（4.6.2 亦可） | 引擎，无 GDExtension 依赖 |
| Node.js | ≥ 18 | `tools/` 烘焙管线，不进运行时 |

## 首次运行

烘焙地形数据（需联网，约 20 MB，只需跑一次）：

```bash
node tools/fetch_dem.mjs
```

拉取矢量数据：

```bash
node tools/fetch_osm.mjs
```

然后用 Godot 打开本目录。启动场景会对 9 个基准点跑 DEM 回归自检，全绿即数据正确。

---

## 目录

```
docs/reference/   原型与技术交接文档（只读参考，勿改）
docs/plans/       实施方案，vNNN 三位递增，不覆盖历史版本
docs/reviews/     评审意见（评审方写入）
tools/            Node 烘焙管线，不进运行时
assets/terrain/   烘焙后的 .r16 高程瓦片 + index.json
assets/vector/    河湖路与地名 GeoJSON
shared/           客户端与服务器共用；禁止依赖场景树
client/           渲染、世界、角色、玩法、网络、界面
server/           权威服务器（M2，当前为骨架）
```

## 一条红线

任何**长期存储**的位置一律存经纬度（`float`，64 位）。
`Vector3` 的分量是 32 位，只能作为当帧相对锚点的局部米制偏移。
把经纬度塞进 `Vector3` 会在离锚点几百公里处静默丢精度 —— 见 `shared/sim/georef.gd`。
