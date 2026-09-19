// Genera web/icon.png (192x192) sin dependencias: rasteriza barras redondeadas sobre un degradé y escribe el PNG a mano.
// Uso: node scripts/make-icon.mjs
import { deflateSync } from "node:zlib";
import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const SIZE = 192, SS = 4; // SS×SS subpíxeles por píxel = antialiasing
const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));

// Cuadrado a sangre completa: iOS aplica su propia máscara de esquinas redondeadas.
const TOP = hex("#1E2A4A"), BOTTOM = hex("#0B1020");
const BLUE = hex("#3B82F6"), ORANGE = hex("#F97316");

// Barras: x, ancho, alto, color. La última (naranja) es "hoy", igual que en el dashboard.
const BASE = 146, W = 24, GAP = 12, R = 7;
const alturas = [46, 78, 60, 104];
const x0 = Math.round((SIZE - (alturas.length * W + (alturas.length - 1) * GAP)) / 2);
const barras = alturas.map((h, i) => ({ x: x0 + i * (W + GAP), y: BASE - h, w: W, h, c: i === alturas.length - 1 ? ORANGE : BLUE }));

// ¿(px,py) dentro de la barra? Esquinas superiores redondeadas, base recta.
function dentro(b, px, py) {
  if (px < b.x || px > b.x + b.w || py < b.y || py > b.y + b.h) return false;
  const cx = px < b.x + R ? b.x + R : px > b.x + b.w - R ? b.x + b.w - R : null;
  if (cx !== null && py < b.y + R) return (px - cx) ** 2 + (py - (b.y + R)) ** 2 <= R * R;
  return true;
}

const raw = Buffer.alloc(SIZE * (SIZE * 4 + 1));
for (let y = 0; y < SIZE; y++) {
  raw[y * (SIZE * 4 + 1)] = 0; // filtro "none"
  for (let x = 0; x < SIZE; x++) {
    const t = y / (SIZE - 1);
    const bg = TOP.map((v, i) => v + (BOTTOM[i] - v) * t);
    let r = 0, g = 0, b = 0;
    for (let sy = 0; sy < SS; sy++) for (let sx = 0; sx < SS; sx++) {
      const px = x + (sx + 0.5) / SS, py = y + (sy + 0.5) / SS;
      const barra = barras.find((bb) => dentro(bb, px, py));
      const c = barra ? barra.c : bg;
      r += c[0]; g += c[1]; b += c[2];
    }
    const n = SS * SS, o = y * (SIZE * 4 + 1) + 1 + x * 4;
    raw[o] = Math.round(r / n); raw[o + 1] = Math.round(g / n); raw[o + 2] = Math.round(b / n); raw[o + 3] = 255;
  }
}

const crcTable = Array.from({ length: 256 }, (_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc32 = (buf) => { let c = 0xffffffff; for (const byte of buf) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
const chunk = (tipo, datos) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(datos.length);
  const cuerpo = Buffer.concat([Buffer.from(tipo, "ascii"), datos]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(cuerpo));
  return Buffer.concat([len, cuerpo, crc]);
};
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(SIZE, 0); ihdr.writeUInt32BE(SIZE, 4); ihdr[8] = 8; ihdr[9] = 6; // 8 bits, RGBA

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk("IHDR", ihdr), chunk("IDAT", deflateSync(raw, { level: 9 })), chunk("IEND", Buffer.alloc(0)),
]);
const destino = join(dirname(fileURLToPath(import.meta.url)), "..", "web", "icon.png");
writeFileSync(destino, png);
console.log(`icon.png escrito (${png.length} bytes) → ${destino}`);
