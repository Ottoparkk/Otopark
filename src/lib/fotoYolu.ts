/**
 * Storage path for a plate photo, and a v4 uuid that also works in the P2's
 * Chrome 56 (crypto.randomUUID is Chrome 92; getRandomValues is everywhere).
 * No imports, so the app, the terminal and tests/terminalGiris.check.mjs all
 * use this file directly.
 */

export function yeniKimlik(): string {
  const b = new Uint8Array(16)
  crypto.getRandomValues(b)
  b[6] = (b[6]! & 0x0f) | 0x40
  b[8] = (b[8]! & 0x3f) | 0x80
  let h = ''
  for (let i = 0; i < 16; i++) h += (b[i]! + 0x100).toString(16).slice(1)
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`
}

/**
 * Date-prefixed so the nightly KVKK purge and a human browsing the bucket
 * both see the same ordering.
 */
export function fotoYolu(
  yon: 'giris' | 'cikis',
  plaka: string,
  kimlik: string = yeniKimlik(),
  simdi: Date = new Date(),
): string {
  const stamp = simdi.toISOString().slice(0, 10)
  return `${stamp}/${yon}-${plaka || 'bilinmiyor'}-${kimlik.slice(0, 8)}.jpg`
}
