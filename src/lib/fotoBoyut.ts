/**
 * How far a camera photo is shrunk (same limits as src/lib/image.ts): the
 * long edge to 1568 px for plate reading, 1280 px for the stored photo; a
 * small photo is never enlarged. The same contract as
 * tools/cihaz-testi/yazici/kamera.mjs, which "Deneme 4" ran on the P2.
 * Pure (tests/terminalGiris.check.mjs).
 */
export const OKUMA_KENAR = 1568
export const KANIT_KENAR = 1280

export function hedefBoyut(en: number, boy: number, sinir: number): { en: number; boy: number } {
  const uzun = Math.max(en, boy)
  if (uzun <= sinir) return { en, boy }
  const oran = sinir / uzun
  return { en: Math.round(en * oran), boy: Math.round(boy * oran) }
}
