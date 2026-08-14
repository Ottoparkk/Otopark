/**
 * Generates the PWA icon set (public/icons/*.png) with zero dependencies.
 *
 * Why hand-rolled: the icons are a flat "P" on a dark rounded square, which is
 * pure arithmetic — pulling in a raster library to draw two shapes would be a
 * dependency in the supply chain (OWASP A03) for no benefit. Node's own zlib
 * does the only hard part.
 *
 *   npm run icons
 */
import { deflateSync } from 'node:zlib'
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const OUT = join(dirname(fileURLToPath(import.meta.url)), '..', 'public', 'icons')

// Must match --color-ink / white in src/styles/index.css.
const BG = [0x14, 0x16, 0x1a]
const FG = [0xff, 0xff, 0xff]
const SS = 3 // supersampling factor per axis (9 samples/pixel)

/* ---------------------------------------------------------------- PNG ---- */

const CRC_TABLE = (() => {
  const t = new Int32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    t[n] = c
  }
  return t
})()

function crc32(buf) {
  let c = 0xffffffff
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

function chunk(type, data) {
  const len = Buffer.alloc(4)
  len.writeUInt32BE(data.length, 0)
  const typed = Buffer.concat([Buffer.from(type, 'ascii'), data])
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(typed), 0)
  return Buffer.concat([len, typed, crc])
}

function encodePng(size, rgba) {
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(size, 0)
  ihdr.writeUInt32BE(size, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 6 // colour type: RGBA
  // 10..12 = compression, filter, interlace — all 0

  const stride = size * 4
  const raw = Buffer.alloc((stride + 1) * size)
  for (let y = 0; y < size; y++) {
    raw[y * (stride + 1)] = 0 // filter type: None
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride)
  }

  return Buffer.concat([
    signature,
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

/* -------------------------------------------------------------- shapes ---- */

/**
 * Signed-distance test for a rounded square spanning [-0.5, 0.5]².
 * Clamping to zero before the hypot is what makes one expression cover all
 * four regions: inside the cross it yields 0, along an edge it collapses to
 * the single overhang, and only in a corner does it measure a real diagonal.
 */
function inRoundedSquare(u, v, radius) {
  const half = 0.5 - radius
  const dx = Math.max(Math.abs(u) - half, 0)
  const dy = Math.max(Math.abs(v) - half, 0)
  return Math.hypot(dx, dy) <= radius
}

/**
 * The letter P, centred on the origin: a stem rectangle unioned with the
 * right half of an annulus. Extents are ±0.1375 horizontally and ±0.255
 * vertically, which sits well inside the 80% maskable safe zone.
 */
function inGlyph(u, v) {
  if (u >= -0.1375 && u <= -0.0375 && v >= -0.255 && v <= 0.255) return true
  const dx = u - -0.0375
  const dy = v - -0.08
  const d = Math.hypot(dx, dy)
  return u >= -0.0375 && d >= 0.075 && d <= 0.175
}

function render(size, { maskable }) {
  const rgba = Buffer.alloc(size * size * 4)
  const radius = maskable ? 0 : 0.22

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      let bg = 0
      let fg = 0
      for (let sy = 0; sy < SS; sy++) {
        for (let sx = 0; sx < SS; sx++) {
          const u = (x + (sx + 0.5) / SS) / size - 0.5
          const v = (y + (sy + 0.5) / SS) / size - 0.5
          if (maskable || inRoundedSquare(u, v, radius)) bg++
          if (inGlyph(u, v)) fg++
        }
      }
      const samples = SS * SS
      const bgA = bg / samples
      const fgA = Math.min(fg / samples, bgA) // glyph never spills past the tile
      const i = (y * size + x) * 4
      // Composite foreground over background, then over transparency.
      for (let c = 0; c < 3; c++) {
        const colour = bgA > 0 ? (BG[c] * (bgA - fgA) + FG[c] * fgA) / bgA : 0
        rgba[i + c] = Math.round(colour)
      }
      rgba[i + 3] = Math.round(bgA * 255)
    }
  }
  return encodePng(size, rgba)
}

/* ---------------------------------------------------------------- main ---- */

mkdirSync(OUT, { recursive: true })

const targets = [
  ['icon-192.png', 192, { maskable: false }],
  ['icon-512.png', 512, { maskable: false }],
  ['icon-512-maskable.png', 512, { maskable: true }],
  // iOS applies its own corner mask, so the full-bleed render is the right one.
  ['apple-touch-icon.png', 180, { maskable: true }],
  ['favicon-32.png', 32, { maskable: false }],
]

for (const [name, size, opts] of targets) {
  const buf = render(size, opts)
  writeFileSync(join(OUT, name), buf)
  console.log(`${name.padEnd(24)} ${size}x${size}  ${(buf.length / 1024).toFixed(1)} KB`)
}
