#!/usr/bin/env node
/**
 * 烘焙真实新疆地形高程。
 *
 * 数据源：AWS Open Data «Terrain Tiles»，terrarium 编码 PNG，无需 API key。
 *   https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png
 * 新疆(34–49.5°N)范围内底层数据为 SRTM 与 GMTED2010。
 * 署名要求见 https://github.com/tilezen/joerd/blob/master/docs/attribution.md
 *
 * 产物 assets/terrain/ 是**派生数据**，已 gitignore：
 * 体积约 80 MB 且完全可由本脚本重建，不进版本库。原始瓦片缓存在 tools/.cache/
 * 便于重跑时不重复下载。
 *
 * 用法：
 *   node tools/fetch_dem.mjs              完整烘焙
 *   node tools/fetch_dem.mjs --dry-run    只算瓦片数与体积，不下载
 *   node tools/fetch_dem.mjs --verify     只对基准点跑回归，不下载
 *   node tools/fetch_dem.mjs --layers L2  只烘焙指定层
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  TILE_PX, lonlatToTile, tileToLonlat, metersPerPixel, haversine,
  decodePng, terrariumToElevation, elevationToR16, sampleR16,
} from './geo.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT_DIR = path.join(ROOT, 'assets', 'terrain');
const CACHE_DIR = path.join(ROOT, 'tools', '.cache', 'tiles');
const REGIONS_PATH = path.join(ROOT, 'shared', 'data', 'regions.json');

const TILE_URL = (z, x, y) =>
  `https://s3.amazonaws.com/elevation-tiles-prod/terrarium/${z}/${x}/${y}.png`;

const ATTRIBUTION =
  '3DEP (formerly NED) and global GMTED2010 and SRTM data courtesy of U.S. Geological Survey. ' +
  'Terrain Tiles via AWS Open Data (tilezen/joerd).';

/**
 * 三层金字塔。
 *   L0 全疆，供远山天际线与战略地图，也是所有地方的兜底。
 *   L1 地标与牧道周边的中景。
 *   L2 核心可行走区与牧道走廊 —— z=12 在 43°N 约 27.9 m/px，与 SRTM 原生 30 m 相当，
 *      这是真实数据的上限，再细就是插值了。
 * pad 单位是度。经度 pad 比纬度大，因为 43°N 处 1° 经度只有约 81 km 而 1° 纬度约 111 km，
 * 这样围出来的框才接近正方形。
 */
const LAYERS = [
  { id: 'L0', zoom: 8, bbox: [73.0, 34.0, 96.5, 49.5] },
  { id: 'L1', zoom: 10, regionPad: [0.55, 0.40], corridorPad: [0.35, 0.26] },
  { id: 'L2', zoom: 12, regionPad: [0.14, 0.10], corridorPad: [0.07, 0.05] },
];

const CONCURRENCY = 8;
const MAX_RETRY = 4;

const args = process.argv.slice(2);
const DRY_RUN = args.includes('--dry-run');
const VERIFY_ONLY = args.includes('--verify');
const ONLY_LAYERS = (() => {
  const i = args.indexOf('--layers');
  return i >= 0 && args[i + 1] ? args[i + 1].split(',') : null;
})();

// ─────────────────────────────────────────────────────────────── 瓦片集合计算

/** bbox = [lonMin, latMin, lonMax, latMax] → 覆盖它的整数瓦片列表。 */
function tilesForBbox(bbox, zoom) {
  const [lonMin, latMin, lonMax, latMax] = bbox;
  // 注意：瓦片 y 随纬度**降低**而增大，所以上下要反过来取。
  const [x0f, y0f] = lonlatToTile(lonMin, latMax, zoom);
  const [x1f, y1f] = lonlatToTile(lonMax, latMin, zoom);
  const out = [];
  const n = 2 ** zoom;
  for (let x = Math.floor(x0f); x <= Math.floor(x1f); x++) {
    for (let y = Math.floor(y0f); y <= Math.floor(y1f); y++) {
      if (x < 0 || y < 0 || x >= n || y >= n) continue;
      out.push([x, y]);
    }
  }
  return out;
}

/** 沿两点连线的走廊，按 pad 缓冲后取瓦片。 */
function tilesForCorridor(a, b, zoom, pad) {
  const dist = haversine(a.lon, a.lat, b.lon, b.lat);
  const steps = Math.max(2, Math.ceil(dist / 5000)); // 每 5 km 取一个采样点
  const set = new Set();
  const out = [];
  for (let i = 0; i <= steps; i++) {
    const t = i / steps;
    const lon = a.lon + (b.lon - a.lon) * t;
    const lat = a.lat + (b.lat - a.lat) * t;
    const bbox = [lon - pad[0], lat - pad[1], lon + pad[0], lat + pad[1]];
    for (const [x, y] of tilesForBbox(bbox, zoom)) {
      const k = `${x},${y}`;
      if (!set.has(k)) { set.add(k); out.push([x, y]); }
    }
  }
  return out;
}

function planLayer(layer, cfg) {
  const set = new Set();
  const tiles = [];
  const add = (list) => {
    for (const [x, y] of list) {
      const k = `${x},${y}`;
      if (!set.has(k)) { set.add(k); tiles.push([x, y]); }
    }
  };

  if (layer.bbox) {
    add(tilesForBbox(layer.bbox, layer.zoom));
  }
  if (layer.regionPad) {
    for (const r of cfg.regions) {
      add(tilesForBbox(
        [r.lon - layer.regionPad[0], r.lat - layer.regionPad[1],
         r.lon + layer.regionPad[0], r.lat + layer.regionPad[1]],
        layer.zoom,
      ));
    }
  }
  if (layer.corridorPad) {
    const byKey = Object.fromEntries(cfg.regions.map((r) => [r.key, r]));
    for (const route of cfg.routes) {
      for (const st of route.stages) {
        const a = byKey[st.from], b = byKey[st.to];
        if (!a || !b) throw new Error(`牧道 ${route.key} 引用了不存在的地标`);
        add(tilesForCorridor(a, b, layer.zoom, layer.corridorPad));
      }
    }
  }
  return tiles;
}

// ─────────────────────────────────────────────────────────────────── 下载

async function fetchTile(z, x, y) {
  const cachePath = path.join(CACHE_DIR, String(z), String(x), `${y}.png`);
  if (fs.existsSync(cachePath)) return fs.readFileSync(cachePath);

  let lastErr;
  for (let attempt = 0; attempt < MAX_RETRY; attempt++) {
    try {
      const res = await fetch(TILE_URL(z, x, y), {
        signal: AbortSignal.timeout(45000),
        headers: { 'User-Agent': 'tianshan-pastorale/1.0 (terrain bake)' },
      });
      if (res.status === 404) return null; // 该瓦片不存在，正常跳过
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const buf = Buffer.from(await res.arrayBuffer());
      fs.mkdirSync(path.dirname(cachePath), { recursive: true });
      fs.writeFileSync(cachePath, buf);
      return buf;
    } catch (e) {
      lastErr = e;
      // 指数退避：0.6s / 1.2s / 2.4s
      await new Promise((r) => setTimeout(r, 600 * 2 ** attempt));
    }
  }
  throw new Error(`瓦片 ${z}/${x}/${y} 下载失败：${lastErr?.message}`);
}

/** 简单的并发闸门，避免一次打爆 700 个连接。 */
async function pool(items, limit, worker) {
  let idx = 0;
  let done = 0;
  const results = new Array(items.length);
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (true) {
      const i = idx++;
      if (i >= items.length) return;
      results[i] = await worker(items[i], i);
      done++;
      if (done % 25 === 0 || done === items.length) {
        process.stdout.write(`\r    ${done}/${items.length}`);
      }
    }
  });
  await Promise.all(runners);
  process.stdout.write('\n');
  return results;
}

// ─────────────────────────────────────────────────────────────────── 主流程

function loadConfig() {
  const cfg = JSON.parse(fs.readFileSync(REGIONS_PATH, 'utf8'));
  if (!cfg.regions?.length) throw new Error('regions.json 里没有地标');
  return cfg;
}

async function bake() {
  const cfg = loadConfig();
  const layers = LAYERS.filter((l) => !ONLY_LAYERS || ONLY_LAYERS.includes(l.id));

  console.log('天山牧歌 · 地形烘焙');
  console.log(`  地标 ${cfg.regions.length} 处 · 牧道 ${cfg.routes.length} 条\n`);

  // 先出计划，让体积一目了然
  const plans = layers.map((l) => ({ layer: l, tiles: planLayer(l, cfg) }));
  let totalTiles = 0;
  for (const { layer, tiles } of plans) {
    const mpp = metersPerPixel(43, layer.zoom);
    const mb = (tiles.length * TILE_PX * TILE_PX * 2) / 1024 / 1024;
    console.log(
      `  ${layer.id}  z=${String(layer.zoom).padEnd(2)}  ${mpp.toFixed(1).padStart(6)} m/px @43°N  ` +
      `${String(tiles.length).padStart(4)} 瓦片  ${mb.toFixed(1).padStart(6)} MB`,
    );
    totalTiles += tiles.length;
  }
  console.log(`  ─────  合计 ${totalTiles} 瓦片\n`);

  if (DRY_RUN) {
    console.log('--dry-run：到此为止，未下载。');
    return;
  }

  fs.mkdirSync(OUT_DIR, { recursive: true });
  const index = { attribution: ATTRIBUTION, tile_px: TILE_PX, layers: [] };

  for (const { layer, tiles } of plans) {
    console.log(`  ${layer.id} 下载并解码…`);
    const layerDir = path.join(OUT_DIR, layer.id);
    fs.mkdirSync(layerDir, { recursive: true });

    const entries = await pool(tiles, CONCURRENCY, async ([x, y]) => {
      const png = await fetchTile(layer.zoom, x, y);
      if (!png) return null;
      let elev;
      try {
        elev = terrariumToElevation(decodePng(png));
      } catch (e) {
        console.warn(`\n    ! ${layer.zoom}/${x}/${y} 解码失败：${e.message}`);
        return null;
      }
      const file = `${layer.id}/${layer.zoom}_${x}_${y}.r16`;
      fs.writeFileSync(path.join(OUT_DIR, file), elevationToR16(elev));
      return { x, y, file };
    });

    const kept = entries.filter(Boolean);
    index.layers.push({ id: layer.id, zoom: layer.zoom, tiles: kept });
    console.log(`    ${layer.id} 完成：${kept.length}/${tiles.length} 瓦片\n`);
  }

  index.generated = new Date().toISOString().slice(0, 10);
  fs.writeFileSync(path.join(OUT_DIR, 'index.json'), JSON.stringify(index, null, 1));
  console.log(`  索引写入 assets/terrain/index.json\n`);
}

// ───────────────────────────────────────────────────────── 校验（回归 + 地标高程）

function makeSampler() {
  const indexPath = path.join(OUT_DIR, 'index.json');
  if (!fs.existsSync(indexPath)) {
    throw new Error('尚未烘焙：先跑 node tools/fetch_dem.mjs');
  }
  const index = JSON.parse(fs.readFileSync(indexPath, 'utf8'));
  const layers = [...index.layers].sort((a, b) => b.zoom - a.zoom); // 精细层优先
  for (const l of layers) {
    l.map = new Map(l.tiles.map((t) => [`${t.x},${t.y}`, t.file]));
  }
  const cache = new Map();

  const readTile = (layer, x, y) => {
    const key = `${layer.id}:${x},${y}`;
    if (cache.has(key)) return cache.get(key);
    const file = layer.map.get(`${x},${y}`);
    const buf = file ? fs.readFileSync(path.join(OUT_DIR, file)) : null;
    cache.set(key, buf);
    return buf;
  };

  return (lon, lat) => {
    for (const layer of layers) {
      const [fx, fy] = lonlatToTile(lon, lat, layer.zoom);
      const buf = readTile(layer, Math.floor(fx), Math.floor(fy));
      if (!buf) continue;
      const px = (fx - Math.floor(fx)) * TILE_PX - 0.5;
      const py = (fy - Math.floor(fy)) * TILE_PX - 0.5;
      return { h: sampleR16(buf, px, py), layer: layer.id, zoom: layer.zoom };
    }
    return null;
  };
}

function verify() {
  const cfg = loadConfig();
  const sample = makeSampler();

  console.log('DEM 回归自检');
  let pass = 0;
  let layerMismatch = 0;
  for (const fx of cfg.dem_fixtures) {
    const got = sample(fx.lon, fx.lat);
    if (!got) {
      console.log(`  —  ${fx.name}：未烘焙该点`);
      continue;
    }
    const diff = Math.abs(got.h - fx.expect_m);
    const ok = diff <= fx.tol_m;
    if (ok) pass++;
    // 层不符要单独报：容差是按层给的，落错层的话即使数值过了也说明覆盖范围变了。
    const layerNote = fx.expect_layer && fx.expect_layer !== got.layer
      ? `  ← 期望落在 ${fx.expect_layer}`
      : '';
    if (layerNote) layerMismatch++;
    console.log(
      `  ${ok ? '✓' : '✗'}  ${fx.name.padEnd(30)} ` +
      `${got.h.toFixed(0).padStart(6)} m  期望 ${String(fx.expect_m).padStart(6)}  ` +
      `差 ${diff.toFixed(0).padStart(4)}  [${got.layer}]${layerNote}`,
    );
  }
  console.log(`  通过 ${pass}/${cfg.dem_fixtures.length}`);
  if (layerMismatch) {
    console.log(`  ! ${layerMismatch} 个基准点落在了非预期的数据层，检查 LAYERS 的覆盖范围`);
  }
  console.log();

  // 地标高程 —— 同时验证「垂直迁徙」这条考据是不是真的成立
  console.log('地标真实高程（从 DEM 采样，非手写）');
  const alt = {};
  for (const r of cfg.regions) {
    const got = sample(r.lon, r.lat);
    alt[r.key] = got ? got.h : null;
    console.log(
      `  ${r.name.padEnd(14)} ${got ? got.h.toFixed(0).padStart(6) + ' m' : '   未烘焙'}` +
      `   [${got ? got.layer : '-'}]`,
    );
  }

  console.log('\n牧道剖面（验证转场确实是垂直迁徙）');
  const byKey = Object.fromEntries(cfg.regions.map((r) => [r.key, r]));
  for (const route of cfg.routes) {
    console.log(`  ${route.name}`);
    for (const st of route.stages) {
      const a = byKey[st.from], b = byKey[st.to];
      const km = haversine(a.lon, a.lat, b.lon, b.lat) / 1000;
      const ha = alt[st.from], hb = alt[st.to];
      const climb = ha != null && hb != null ? hb - ha : null;
      console.log(
        `    ${st.season.padEnd(6)} ${a.name} → ${b.name}` +
        `  ${km.toFixed(0)} km  ${st.days} 天` +
        (climb != null
          ? `  ${climb >= 0 ? '↑' : '↓'}${Math.abs(climb).toFixed(0)} m`
          : ''),
      );
      if (climb != null) {
        const kmPerDay = km / st.days;
        if (kmPerDay > 60) {
          console.log(`      ! 日均 ${kmPerDay.toFixed(0)} km 偏高（真实转场约 30–45 km/日），考虑调整 days`);
        }
      }
    }
  }
  console.log();
}

// ─────────────────────────────────────────────────────────────────── 入口

try {
  if (!VERIFY_ONLY) await bake();
  if (!DRY_RUN) verify();
} catch (e) {
  console.error(`\n烘焙失败：${e.message}`);
  process.exitCode = 1;
}
