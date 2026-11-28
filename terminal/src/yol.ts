/**
 * The terminal's screens as hash routes (spec 2026-11-28: no router library,
 * no 404 trick for deep links). Pure (tests/terminalYol.check.mjs).
 */

export type Yol =
  | { ekran: 'kurulum' }
  | { ekran: 'pin' }
  | { ekran: 'gise' }
  | { ekran: 'giris' }
  | { ekran: 'fis'; biletId: string }
  // Whole terminal (owner 28.11): the rest of the Personel app.
  | { ekran: 'kayip' }
  | { ekran: 'istisnalar' }
  | { ekran: 'abonman' }
  | { ekran: 'profil' }
  | { ekran: 'cfis'; biletId: string }
  | { ekran: 'bilet'; biletId: string }
  | { ekran: 'abonmanDetay'; id: string }

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const TEK = ['kurulum', 'pin', 'gise', 'giris', 'kayip', 'istisnalar', 'abonman', 'profil'] as const

/** '#/fis/<uuid>' → {ekran:'fis', biletId}; anything unknown → null. */
export function yolOku(hash: string): Yol | null {
  const parca = hash.replace(/^#\/?/, '').split('/')
  const [ad, id, fazla] = parca
  if (fazla !== undefined) return null
  if (ad === 'fis') return id && UUID.test(id) ? { ekran: 'fis', biletId: id } : null
  if (ad === 'cfis') return id && UUID.test(id) ? { ekran: 'cfis', biletId: id } : null
  if (ad === 'bilet') return id && UUID.test(id) ? { ekran: 'bilet', biletId: id } : null
  if (ad === 'abonman' && id !== undefined) return UUID.test(id) ? { ekran: 'abonmanDetay', id } : null
  if (id !== undefined) return null
  const tek = TEK.find((t) => t === ad)
  return tek ? { ekran: tek } : null
}

export function yolYaz(y: Yol): string {
  switch (y.ekran) {
    case 'fis':
    case 'cfis':
    case 'bilet':
      return `#/${y.ekran}/${y.biletId}`
    case 'abonmanDetay':
      return `#/abonman/${y.id}`
    default:
      return `#/${y.ekran}`
  }
}

/**
 * The screen to show. Not yet a terminal → Kurulum. Nobody signed in → PIN.
 * Signed in → the asked screen (PIN there means Devral), else Gişe; Kurulum
 * is never shown to a signed-in device.
 */
export function acilisYolu(terminalVar: boolean, oturumVar: boolean, istenen: Yol | null): Yol {
  if (!terminalVar) return { ekran: 'kurulum' }
  if (!oturumVar) return { ekran: 'pin' }
  if (!istenen || istenen.ekran === 'kurulum') return { ekran: 'gise' }
  return istenen
}
