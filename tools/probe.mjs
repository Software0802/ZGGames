#!/usr/bin/env node
/**
 * 查询已烘焙 DEM 的高程。用于给地标选点、验证牧道剖面，避免手写高程。
 *
 * 用法：
 *   node tools/probe.mjs 87.60 46.35                 单点
 *   node tools/probe.mjs --grid 87.5 47.0 88.6 47.9 6   网格扫描（lon0 lat0 lon1 lat1 步数）
 *   node tools/probe.mjs --profile 87.60 46.35 87.03 48.80 20   两点间高程剖面
 *   node tools/probe.mjs --site 86.8 48.3 87.5 48.8 2000 6000   选址
 *       在框内找「高程接近目标值且局部起伏最小」的点。最后两个参数是目标高程(米)
 *       与可行走区半径(米)。牧场要的是山间草甸，不是悬崖面 —— 起伏必须自动衡量，
 *       不能靠肉眼在网格里挑数字。
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { TILE_PX, lonlatToTile, haversine, sampleR16 } from './geo.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const OUT_DIR = path.join(ROOT, 'assets', 'terrain');

const indexPath = path.join(OUT_DIR, 'index.json');
if (!fs.existsSync(indexPath)) {
  console.error('尚未烘焙：先跑 node tools/fetch_dem.mjs');
  process.exit(1);
}
const index = JSON.parse(fs.readFileSync(indexPath, 'utf8'));
const layers = [...index.layers].sort((a, b) => b.zoom - a.zoom);
for (const l of layers) l.map = new Map(l.tiles.map((t) => [`${t.x},${t.y}`, t.file]));

const cache = new Map();
function readTile(layer, x, y) {
  const key = `${layer.id}:${x},${y}`;
  if (!cache.has(key)) {
    const file = layer.map.get(`${x},${y}`);
    cache.set(key, file ? fs.readFileSync(path.join(OUT_DIR, file)) : null);
  }
  return cache.get(key);
}

export function sample(lon, lat) {
  for (const layer of layers) {
    const [fx, fy] = lonlatToTile(lon, lat, layer.zoom);
    const buf = readTile(layer, Math.floor(fx), Math.floor(fy));
    if (!buf) continue;
    const px = (fx - Math.floor(fx)) * TILE_PX - 0.5;
    const py = (fy - Math.floor(fy)) * TILE_PX - 0.5;
    return { h: sampleR16(buf, px, py), layer: layer.id };
  }
  return null;
}

const a = process.argv.slice(2);
const fmt = (v) => (v == null ? '  --  ' : v.h.toFixed(0).padStart(6));

if (a[0] === '--grid') {
  const [lon0, lat0, lon1, lat1, n] = a.slice(1).map(Number);
  process.stdout.write('  lat\\lon '.padEnd(10));
  for (let i = 0; i < n; i++) {
    process.stdout.write((lon0 + ((lon1 - lon0) * i) / (n - 1)).toFixed(2).padStart(8));
  }
  console.log();
  for (let j = 0; j < n; j++) {
    const lat = lat1 - ((lat1 - lat0) * j) / (n - 1);
    process.stdout.write(lat.toFixed(2).padStart(10));
    for (let i = 0; i < n; i++) {
      const lon = lon0 + ((lon1 - lon0) * i) / (n - 1);
      process.stdout.write(fmt(sample(lon, lat)).padStart(8));
    }
    console.log();
  }
} else if (a[0] === '--profile') {
  const [lon0, lat0, lon1, lat1, n] = a.slice(1).map(Number);
  const total = haversine(lon0, lat0, lon1, lat1) / 1000;
  console.log(`  剖面 ${total.toFixed(0)} km，${n} 个采样点`);
  for (let i = 0; i <= n; i++) {
    const t = i / n;
    const lon = lon0 + (lon1 - lon0) * t;
    const lat = lat0 + (lat1 - lat0) * t;
    const s = sample(lon, lat);
    const bar = s ? '█'.repeat(Math.max(0, Math.round(s.h / 120))) : '';
    console.log(
      `  ${(total * t).toFixed(0).padStart(4)} km  ${lon.toFixed(3)},${lat.toFixed(3)}  ${fmt(s)} m  ${bar}`,
    );
  }
} else if (a[0] === '--site') {
  const [lon0, lat0, lon1, lat1, targetH, radiusM] = a.slice(1).map(Number);
  const R = radiusM || 6000;
  const target = targetH || 2000;
  // 候选点密度：约每 1.5 km 一个
  const stepLat = 1500 / 111320;
  const stepLon = stepLat / Math.cos(((lat0 + lat1) / 2) * Math.PI / 180);

  const relief = (lon, lat) => {
    // 在半径 R 内取 3 环 × 8 方向 + 中心，统计起伏与坡度
    const mLat = R / 111320;
    const mLon = mLat / Math.cos((lat * Math.PI) / 180);
    const hs = [];
    const c = sample(lon, lat);
    if (!c) return null;
    hs.push(c.h);
    for (const frac of [0.4, 0.7, 1.0]) {
      for (let k = 0; k < 8; k++) {
        const ang = (k / 8) * Math.PI * 2;
        const s = sample(lon + Math.cos(ang) * mLon * frac, lat + Math.sin(ang) * mLat * frac);
        if (!s) return null;
        hs.push(s.h);
      }
    }
    const min = Math.min(...hs), max = Math.max(...hs);
    const mean = hs.reduce((s, v) => s + v, 0) / hs.length;
    const sd = Math.sqrt(hs.reduce((s, v) => s + (v - mean) ** 2, 0) / hs.length);
    return { center: c.h, mean, sd, range: max - min };
  };

  const cands = [];
  for (let lat = lat0; lat <= lat1; lat += stepLat) {
    for (let lon = lon0; lon <= lon1; lon += stepLon) {
      const r = relief(lon, lat);
      if (!r) continue;
      // 打分：高程偏离目标每 100 m 记 1 分，局部起伏标准差每 100 m 记 1.6 分。
      // 起伏权重更高 —— 高程差一点无所谓，选到悬崖上就没法放牧了。
      const score = Math.abs(r.center - target) / 100 + (r.sd / 100) * 1.6;
      cands.push({ lon, lat, ...r, score });
    }
  }
  cands.sort((p, q) => p.score - q.score);
  console.log(`  候选 ${cands.length} 个，目标高程 ${target} m，可行走半径 ${R} m`);
  console.log('  经度      纬度      中心高程  邻域均值  起伏σ  极差   评分');
  for (const c of cands.slice(0, 10)) {
    console.log(
      `  ${c.lon.toFixed(4)}  ${c.lat.toFixed(4)}  ${c.center.toFixed(0).padStart(7)}m ` +
      `${c.mean.toFixed(0).padStart(8)}m ${c.sd.toFixed(0).padStart(6)}m ` +
      `${c.range.toFixed(0).padStart(6)}m ${c.score.toFixed(2).padStart(6)}`,
    );
  }
} else {
  for (let i = 0; i + 1 < a.length; i += 2) {
    const lon = Number(a[i]), lat = Number(a[i + 1]);
    const s = sample(lon, lat);
    console.log(`  ${lon},${lat}  ${fmt(s)} m  [${s ? s.layer : '未烘焙'}]`);
  }
}
