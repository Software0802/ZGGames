// 共用的地理换算与 PNG 解码。零依赖 —— 只用 Node 内置模块。
// 与 shared/sim/georef.gd 的换算必须完全一致；改一边就要改另一边。

import zlib from 'node:zlib';

export const TILE_PX = 256;

/** 经纬度 → 分数瓦片坐标（Web Mercator / EPSG:3857，terrarium 用的就是这个）。 */
export function lonlatToTile(lon, lat, zoom) {
  const n = 2 ** zoom;
  const x = ((lon + 180) / 360) * n;
  const y = ((1 - Math.asinh(Math.tan((lat * Math.PI) / 180)) / Math.PI) / 2) * n;
  return [x, y];
}

/** 分数瓦片坐标 → 经纬度。 */
export function tileToLonlat(x, y, zoom) {
  const n = 2 ** zoom;
  const lon = (x / n) * 360 - 180;
  const lat = (Math.atan(Math.sinh(Math.PI * (1 - (2 * y) / n))) * 180) / Math.PI;
  return [lon, lat];
}

/** 某缩放级在给定纬度下的地面分辨率（米/像素，256 px 瓦片）。 */
export function metersPerPixel(lat, zoom) {
  return (156543.03392804097 * Math.cos((lat * Math.PI) / 180)) / 2 ** zoom;
}

/** 大圆距离（米）。 */
export function haversine(lon1, lat1, lon2, lat2) {
  const R = 6371008.8;
  const p1 = (lat1 * Math.PI) / 180;
  const p2 = (lat2 * Math.PI) / 180;
  const dp = p2 - p1;
  const dl = ((lon2 - lon1) * Math.PI) / 180;
  const a =
    Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return 2 * R * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

/**
 * 最小 PNG 解码器：8 位、非隔行、颜色类型 0/2/4/6。
 * terrarium 瓦片就在这个子集内；碰到调色板(3)或 16 位直接抛错，不静默出错值。
 * 返回 { width, height, channels, data: Uint8Array }。
 */
export function decodePng(buf) {
  const SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  for (let i = 0; i < 8; i++) {
    if (buf[i] !== SIG[i]) throw new Error('不是 PNG 文件');
  }

  let width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0;
  const idat = [];
  let p = 8;
  while (p < buf.length) {
    const len = buf.readUInt32BE(p);
    const type = buf.toString('ascii', p + 4, p + 8);
    const data = buf.subarray(p + 8, p + 8 + len);
    p += 12 + len; // 4 长度 + 4 类型 + len + 4 CRC
    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colorType = data[9];
      interlace = data[12];
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') {
      break;
    }
  }

  if (bitDepth !== 8) throw new Error(`只支持 8 位 PNG，实际 ${bitDepth} 位`);
  if (interlace !== 0) throw new Error('不支持隔行 PNG');
  const CHANNELS = { 0: 1, 2: 3, 4: 2, 6: 4 };
  const ch = CHANNELS[colorType];
  if (!ch) throw new Error(`不支持的颜色类型 ${colorType}（调色板需查表）`);

  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * ch;
  const out = new Uint8Array(height * stride);
  let prev = new Uint8Array(stride);
  let rp = 0;

  for (let row = 0; row < height; row++) {
    const filter = raw[rp++];
    const line = new Uint8Array(raw.subarray(rp, rp + stride));
    rp += stride;
    // PNG 逐行滤波器还原（RFC 2083 §6）
    switch (filter) {
      case 0:
        break;
      case 1:
        for (let x = ch; x < stride; x++) line[x] = (line[x] + line[x - ch]) & 0xff;
        break;
      case 2:
        for (let x = 0; x < stride; x++) line[x] = (line[x] + prev[x]) & 0xff;
        break;
      case 3:
        for (let x = 0; x < stride; x++) {
          const a = x >= ch ? line[x - ch] : 0;
          line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff;
        }
        break;
      case 4:
        for (let x = 0; x < stride; x++) {
          const a = x >= ch ? line[x - ch] : 0;
          const b = prev[x];
          const c = x >= ch ? prev[x - ch] : 0;
          const pp = a + b - c;
          const pa = Math.abs(pp - a), pb = Math.abs(pp - b), pc = Math.abs(pp - c);
          const pred = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
          line[x] = (line[x] + pred) & 0xff;
        }
        break;
      default:
        throw new Error(`未知 PNG 滤波器 ${filter}`);
    }
    out.set(line, row * stride);
    prev = line;
  }

  return { width, height, channels: ch, data: out };
}

/**
 * terrarium 解码：高程(米) = (R * 256 + G + B / 256) - 32768
 * 出处 https://github.com/tilezen/joerd/blob/master/docs/formats.md
 * 返回 Float32Array，长度 width*height。
 */
export function terrariumToElevation(png) {
  const { width, height, channels, data } = png;
  if (channels < 3) throw new Error('terrarium 瓦片需要 RGB 三通道');
  const out = new Float32Array(width * height);
  for (let i = 0; i < width * height; i++) {
    const o = i * channels;
    out[i] = data[o] * 256 + data[o + 1] + data[o + 2] / 256 - 32768;
  }
  return out;
}

/**
 * 高程数组 → .r16（有符号 16 位小端，单位米）。
 * int16 范围 −32768~32767 覆盖了地球全部陆地高程（−155 的艾丁湖到 8848 的珠峰），
 * 不需要偏移量。1 米量化在 28 m 的水平分辨率下不可察觉。
 */
export function elevationToR16(elev) {
  const buf = Buffer.allocUnsafe(elev.length * 2);
  for (let i = 0; i < elev.length; i++) {
    let v = Math.round(elev[i]);
    if (v > 32767) v = 32767;
    if (v < -32768) v = -32768;
    buf.writeInt16LE(v, i * 2);
  }
  return buf;
}

/** 从 .r16 缓冲区做双线性采样，像素坐标可为分数。 */
export function sampleR16(buf, px, py, size = TILE_PX) {
  const clamp = (v) => Math.max(0, Math.min(size - 1, v));
  const x0 = Math.floor(px), y0 = Math.floor(py);
  const wx = px - x0, wy = py - y0;
  const at = (x, y) => buf.readInt16LE((clamp(y) * size + clamp(x)) * 2);
  const top = at(x0, y0) * (1 - wx) + at(x0 + 1, y0) * wx;
  const bot = at(x0, y0 + 1) * (1 - wx) + at(x0 + 1, y0 + 1) * wx;
  return top * (1 - wy) + bot * wy;
}
