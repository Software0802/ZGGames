#!/usr/bin/env node
/**
 * 烘焙矢量层：河流、湖泊、林地、冰川、牧道、地名。
 *
 * 数据源：OpenStreetMap，经 Overpass API 拉取。许可 ODbL，须署名「© OpenStreetMap contributors」。
 *
 * 这些不是装饰：河道决定渡河点与水源，林地决定树木实例的位置（不能随机撒），
 * 冰川决定夏牧场的雪线，track/path 是真实存在的牧道，用来校正我们的转场折线。
 *
 * Overpass 是免费公共服务且有配额（通常 2 个并发槽），所以本脚本**串行**请求并在
 * 每次之间等待。请勿改成并发 —— 会被限流甚至封禁，也不礼貌。
 *
 * 用法：
 *   node tools/fetch_osm.mjs             拉全部地标
 *   node tools/fetch_osm.mjs narati      只拉指定地标
 *   node tools/fetch_osm.mjs --status    只看 Overpass 配额
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT_DIR = path.join(ROOT, 'assets', 'vector');
const CACHE_DIR = path.join(ROOT, 'tools', '.cache', 'osm');
const REGIONS_PATH = path.join(ROOT, 'shared', 'data', 'regions.json');

const OVERPASS = 'https://overpass-api.de/api/interpreter';
const ATTRIBUTION = '© OpenStreetMap contributors (ODbL)';

/** 每个地标取多大的框（度）。比 L2 高程覆盖略小 —— 矢量只在可行走区用得上。 */
const PAD_LON = 0.16;
const PAD_LAT = 0.12;

const PAUSE_MS = 6000;   // 两次请求之间的间隔，对公共服务的基本礼貌
const MAX_RETRY = 3;

/**
 * 分成几组查询而不是一次拉全部：单个 Overpass 查询越大越容易超时被拒，
 * 分组后失败只影响一组，重试成本也低。
 */
const QUERIES = [
  {
    id: 'water',
    desc: '河流 湖泊 溪流',
    body: (bbox) => `
      way["waterway"~"^(river|stream|canal)$"](${bbox});
      way["natural"="water"](${bbox});
      relation["natural"="water"](${bbox});`,
  },
  {
    id: 'land',
    desc: '林地 草地 冰川 裸岩 沙地',
    body: (bbox) => `
      way["natural"~"^(wood|glacier|scree|bare_rock|sand|grassland|wetland)$"](${bbox});
      way["landuse"~"^(forest|meadow|farmland|orchard|vineyard)$"](${bbox});`,
  },
  {
    id: 'ways',
    desc: '道路 小径 牧道',
    body: (bbox) => `
      way["highway"~"^(track|path|bridleway|unclassified|residential|tertiary|secondary|primary)$"](${bbox});`,
  },
  {
    id: 'places',
    desc: '地名 居民点 山峰',
    body: (bbox) => `
      node["place"](${bbox});
      node["natural"="peak"](${bbox});
      node["natural"="spring"](${bbox});`,
  },
];

const args = process.argv.slice(2);
const STATUS_ONLY = args.includes('--status');
const ONLY = args.filter((a) => !a.startsWith('--'));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function overpassStatus() {
  const res = await fetch('https://overpass-api.de/api/status', {
    signal: AbortSignal.timeout(30000),
  });
  return res.text();
}

async function overpass(query, cacheKey) {
  const cachePath = path.join(CACHE_DIR, `${cacheKey}.json`);
  if (fs.existsSync(cachePath)) {
    return JSON.parse(fs.readFileSync(cachePath, 'utf8'));
  }

  let lastErr;
  for (let attempt = 0; attempt < MAX_RETRY; attempt++) {
    try {
      const res = await fetch(OVERPASS, {
        method: 'POST',
        body: new URLSearchParams({ data: query }),
        headers: { 'User-Agent': 'tianshan-pastorale/1.0 (vector bake)' },
        signal: AbortSignal.timeout(180000),
      });
      if (res.status === 429 || res.status === 504) {
        // 被限流 / 网关超时：等久一点再来，别硬刷
        await sleep(30000 * (attempt + 1));
        throw new Error(`HTTP ${res.status}（配额或超时）`);
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = await res.json();
      fs.mkdirSync(path.dirname(cachePath), { recursive: true });
      fs.writeFileSync(cachePath, JSON.stringify(json));
      return json;
    } catch (e) {
      lastErr = e;
      await sleep(5000 * (attempt + 1));
    }
  }
  throw new Error(`Overpass 请求失败：${lastErr?.message}`);
}

/**
 * Overpass JSON → GeoJSON FeatureCollection。
 * 只保留渲染与玩法真正会用到的标签，其余丢弃 —— 原始响应里 90% 是我们用不上的元数据。
 */
function toGeoJson(osm) {
  const nodes = new Map();
  for (const el of osm.elements) {
    if (el.type === 'node') nodes.set(el.id, [el.lon, el.lat]);
  }

  const KEEP = [
    'name', 'name:zh', 'name:ug', 'name:kk',
    'waterway', 'natural', 'landuse', 'highway', 'place', 'ele', 'width', 'intermittent',
  ];
  const pick = (tags) => {
    const out = {};
    for (const k of KEEP) if (tags?.[k] != null) out[k] = tags[k];
    return out;
  };

  const features = [];
  for (const el of osm.elements) {
    if (el.type === 'node' && el.tags) {
      features.push({
        type: 'Feature',
        properties: pick(el.tags),
        geometry: { type: 'Point', coordinates: [el.lon, el.lat] },
      });
    } else if (el.type === 'way' && el.nodes) {
      const coords = el.nodes.map((id) => nodes.get(id)).filter(Boolean);
      if (coords.length < 2) continue;
      const closed =
        coords.length > 3 &&
        coords[0][0] === coords[coords.length - 1][0] &&
        coords[0][1] === coords[coords.length - 1][1];
      // 闭合环且带面状标签的当多边形，其余当线
      const isArea = closed && (el.tags?.natural || el.tags?.landuse);
      features.push({
        type: 'Feature',
        properties: pick(el.tags),
        geometry: isArea
          ? { type: 'Polygon', coordinates: [coords] }
          : { type: 'LineString', coordinates: coords },
      });
    }
  }
  return { type: 'FeatureCollection', attribution: ATTRIBUTION, features };
}

/**
 * Douglas–Peucker 折线抽稀。OSM 的河道在 20 km 框里能有上万个点，
 * 而游戏里 5 m 以内的顶点差别看不出来 —— 不抽稀纯粹是浪费内存与解析时间。
 */
function simplify(coords, toleranceDeg) {
  if (coords.length <= 2) return coords;
  const sqTol = toleranceDeg * toleranceDeg;

  const sqSegDist = (p, a, b) => {
    let [x, y] = a;
    let dx = b[0] - x, dy = b[1] - y;
    if (dx !== 0 || dy !== 0) {
      const t = ((p[0] - x) * dx + (p[1] - y) * dy) / (dx * dx + dy * dy);
      if (t > 1) { x = b[0]; y = b[1]; }
      else if (t > 0) { x += dx * t; y += dy * t; }
    }
    dx = p[0] - x; dy = p[1] - y;
    return dx * dx + dy * dy;
  };

  const keep = new Uint8Array(coords.length);
  keep[0] = keep[coords.length - 1] = 1;
  const stack = [[0, coords.length - 1]];
  while (stack.length) {
    const [first, last] = stack.pop();
    let maxSq = 0, index = -1;
    for (let i = first + 1; i < last; i++) {
      const sq = sqSegDist(coords[i], coords[first], coords[last]);
      if (sq > maxSq) { maxSq = sq; index = i; }
    }
    if (maxSq > sqTol && index > 0) {
      keep[index] = 1;
      stack.push([first, index], [index, last]);
    }
  }
  return coords.filter((_, i) => keep[i]);
}

function simplifyFeatures(fc, toleranceDeg) {
  let before = 0, after = 0;
  for (const f of fc.features) {
    const g = f.geometry;
    if (g.type === 'LineString') {
      before += g.coordinates.length;
      g.coordinates = simplify(g.coordinates, toleranceDeg);
      after += g.coordinates.length;
    } else if (g.type === 'Polygon') {
      g.coordinates = g.coordinates.map((ring) => {
        before += ring.length;
        const s = simplify(ring, toleranceDeg);
        // 环必须闭合，抽稀后补回首点
        if (s.length >= 3 && (s[0][0] !== s[s.length - 1][0] || s[0][1] !== s[s.length - 1][1])) {
          s.push(s[0]);
        }
        after += s.length;
        return s;
      }).filter((r) => r.length >= 4);
    }
  }
  fc.features = fc.features.filter(
    (f) => f.geometry.type !== 'Polygon' || f.geometry.coordinates.length > 0,
  );
  return { before, after };
}

async function main() {
  if (STATUS_ONLY) {
    console.log(await overpassStatus());
    return;
  }

  const cfg = JSON.parse(fs.readFileSync(REGIONS_PATH, 'utf8'));
  const regions = ONLY.length
    ? cfg.regions.filter((r) => ONLY.includes(r.key))
    : cfg.regions;
  if (!regions.length) throw new Error(`没有匹配的地标：${ONLY.join(', ')}`);

  console.log('天山牧歌 · 矢量烘焙（OpenStreetMap / Overpass）');
  console.log(`  ${regions.length} 处地标 × ${QUERIES.length} 组查询，串行请求\n`);
  fs.mkdirSync(OUT_DIR, { recursive: true });

  // 约 5 m，抽稀后的顶点间距在游戏里看不出差别
  const TOL = 5 / 111320;
  const manifest = { attribution: ATTRIBUTION, generated: new Date().toISOString().slice(0, 10), regions: {} };

  for (const r of regions) {
    const bbox = [
      (r.lat - PAD_LAT).toFixed(4), (r.lon - PAD_LON).toFixed(4),
      (r.lat + PAD_LAT).toFixed(4), (r.lon + PAD_LON).toFixed(4),
    ].join(',');
    console.log(`  ${r.name}  (${bbox})`);
    const files = {};

    for (const q of QUERIES) {
      const query = `[out:json][timeout:120];(${q.body(bbox)});out body geom;>;out skel qt;`;
      let osm;
      try {
        osm = await overpass(query, `${r.key}_${q.id}`);
      } catch (e) {
        console.log(`    ✗ ${q.id.padEnd(7)} ${e.message}`);
        continue;
      }
      const fc = toGeoJson(osm);
      const stat = simplifyFeatures(fc, TOL);
      const file = `${r.key}_${q.id}.geojson`;
      fs.writeFileSync(path.join(OUT_DIR, file), JSON.stringify(fc));
      files[q.id] = file;
      const kb = (fs.statSync(path.join(OUT_DIR, file)).size / 1024).toFixed(0);
      console.log(
        `    ✓ ${q.id.padEnd(7)} ${String(fc.features.length).padStart(5)} 要素  ` +
        `顶点 ${stat.before}→${stat.after}  ${kb} KB   ${q.desc}`,
      );
      await sleep(PAUSE_MS);
    }

    manifest.regions[r.key] = files;
  }

  fs.writeFileSync(path.join(OUT_DIR, 'index.json'), JSON.stringify(manifest, null, 1));
  console.log('\n  索引写入 assets/vector/index.json');
}

try {
  await main();
} catch (e) {
  console.error(`\n矢量烘焙失败：${e.message}`);
  process.exitCode = 1;
}
