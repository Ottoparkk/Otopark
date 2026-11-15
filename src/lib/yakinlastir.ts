/**
 * Zoom and pan maths for the full-screen photo viewer (FotoGoruntuleyici).
 *
 * Pure, no imports — checked by `node tests/yakinlastir.check.mjs`.
 *
 * Coordinates are px relative to the CENTRE of the frame (the screen). The
 * picture is drawn with `translate(x, y) scale(s)` around its own centre, and
 * `resim` is its size at 1×, i.e. already fitted inside the frame
 * (object-contain, see `sigdir`). So at 1× the whole picture is visible.
 *
 * The one rule every function ends with (`sinirla`): the scale stays within
 * 1–EN_COK, and the picture never slides away from the frame. At 1× it is
 * centred; zoomed in, its edge stops at the frame's edge; along an axis where
 * even the zoomed picture is smaller than the frame, it stays centred.
 */

export type Boyut = { w: number; h: number }
export type Nokta = { x: number; y: number }
export type Durum = { s: number; x: number; y: number }

/** Deepest zoom: enough to read a plate in a wide camera frame. */
export const EN_COK = 5
/** Where a double tap zooms to. */
export const CIFT_DOKUNUS = 2.5

export const BASLANGIC: Durum = { s: 1, x: 0, y: 0 }

/** The picture's size at 1× inside the frame (object-contain). */
export function sigdir(kap: Boyut, dogal: Boyut): Boyut {
  if (!(dogal.w > 0) || !(dogal.h > 0)) return { w: kap.w, h: kap.h }
  const r = Math.min(kap.w / dogal.w, kap.h / dogal.h)
  return { w: dogal.w * r, h: dogal.h * r }
}

function aralik(v: number, sinir: number): number {
  if (!Number.isFinite(v)) return 0
  return Math.min(sinir, Math.max(-sinir, v))
}

/** Clamp a state: scale 1–EN_COK, pan so no edge comes inside the frame. */
export function sinirla(d: Durum, kap: Boyut, resim: Boyut): Durum {
  const s = Number.isFinite(d.s) ? Math.min(EN_COK, Math.max(1, d.s)) : 1
  const mx = Math.max(0, (resim.w * s - kap.w) / 2)
  const my = Math.max(0, (resim.h * s - kap.h) / 2)
  // `+ 0` turns a -0 into 0 (a clamp to a zero range can give -0).
  return { s, x: aralik(d.x, mx) + 0, y: aralik(d.y, my) + 0 }
}

/**
 * Pinch. `bas` = the state when the two fingers went down, `d0` / `d1` = the
 * distance between them then and now, `odak0` / `odak1` = their midpoint then
 * and now. The picture point that was under the midpoint stays under it (and
 * follows it, so pinching also pans).
 */
export function kistir(
  bas: Durum,
  d0: number,
  d1: number,
  odak0: Nokta,
  odak1: Nokta,
  kap: Boyut,
  resim: Boyut,
): Durum {
  if (!(d0 > 0) || !(d1 > 0)) return sinirla(bas, kap, resim)
  const s = Math.min(EN_COK, Math.max(1, (bas.s * d1) / d0))
  const k = s / bas.s
  return sinirla(
    { s, x: odak1.x - (odak0.x - bas.x) * k, y: odak1.y - (odak0.y - bas.y) * k },
    kap,
    resim,
  )
}

/** One-finger pan (does nothing at 1×: there is nowhere to go). */
export function kaydir(d: Durum, dx: number, dy: number, kap: Boyut, resim: Boyut): Durum {
  return sinirla({ s: d.s, x: d.x + dx, y: d.y + dy }, kap, resim)
}

/** Double tap: at 1× zoom to CIFT_DOKUNUS on the tapped point; zoomed → back to 1×. */
export function ciftDokunus(d: Durum, nokta: Nokta, kap: Boyut, resim: Boyut): Durum {
  if (d.s > 1.01) return { ...BASLANGIC }
  return kistir(d, 1, CIFT_DOKUNUS / d.s, nokta, nokta, kap, resim)
}
