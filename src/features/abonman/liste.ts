// Abonmanlar list (owner, 27.11): grouped by payment day by default, or sorted
// by price; Doldu / İptal by end date, just ended first. Plus the search, the
// short "1.12.26" date, the header totals and the "N gün kaldı" chip.
//
// Pure and type-only (tests/abonmanListe.check.mjs runs it in Node), so the
// header text (`ayinGunu`) and the money format stay with the screen.
import type { Abonman, AbonmanDurum } from '../../lib/types'

export type AbonmanSiralama = 'VARSAYILAN' | 'ARTAN' | 'AZALAN'

export interface AbonmanGrubu {
  /** Payment day 1–31 for a day group; null for a flat (sorted) list. */
  gun: number | null
  adet: number
  toplamKurus: number
  ogeler: Abonman[]
}

/** '2026-12-01' → '1.12.26'. Anything else comes back as it was. */
export function kisaTarih(gun: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(gun)
  if (!m) return gun
  return `${Number(m[3])}.${Number(m[2])}.${(m[1] ?? '').slice(2)}`
}

/** The payment day; a row without one falls back to its end date's day. */
export function odemeGunu(a: Pick<Abonman, 'yenileme_gunu' | 'bitis'>): number {
  return a.yenileme_gunu ?? Number(a.bitis.slice(8, 10))
}

const plakaSirasi = (x: Abonman, y: Abonman) => (x.plaka < y.plaka ? -1 : x.plaka > y.plaka ? 1 : 0)
const tarihSirasi = (x: string, y: string) => (x < y ? -1 : x > y ? 1 : 0)

function grup(gun: number | null, ogeler: Abonman[]): AbonmanGrubu {
  return { gun, adet: ogeler.length, toplamKurus: ogeler.reduce((t, a) => t + a.ucret_kurus, 0), ogeler }
}

export function abonmanGruplari(
  liste: readonly Abonman[],
  sekme: AbonmanDurum,
  siralama: AbonmanSiralama,
): AbonmanGrubu[] {
  if (liste.length === 0) return []
  const l = [...liste]
  if (siralama !== 'VARSAYILAN') {
    const yon = siralama === 'ARTAN' ? 1 : -1
    // Ties by plate, ascending either way: the order never flickers.
    l.sort((x, y) => (x.ucret_kurus - y.ucret_kurus) * yon || plakaSirasi(x, y))
    return [grup(null, l)]
  }
  if (sekme !== 'AKTIF') {
    // Just ended first: the customers most likely to come back and renew.
    l.sort((x, y) => tarihSirasi(y.bitis, x.bitis) || plakaSirasi(x, y))
    return [grup(null, l)]
  }
  // One group per payment day, 1 → 31; inside, the one ending soonest first.
  l.sort((x, y) => odemeGunu(x) - odemeGunu(y) || tarihSirasi(x.bitis, y.bitis) || plakaSirasi(x, y))
  const gruplar: AbonmanGrubu[] = []
  let gun = -1
  let ogeler: Abonman[] = []
  for (const a of l) {
    const g = odemeGunu(a)
    if (g !== gun && ogeler.length) {
      gruplar.push(grup(gun, ogeler))
      ogeler = []
    }
    gun = g
    ogeler.push(a)
  }
  gruplar.push(grup(gun, ogeler))
  return gruplar
}

/**
 * Plate or name. The plate side ignores spaces and case (plates are stored
 * normalised: no spaces, ASCII capitals); the name side is Turkish
 * lower-case, so "İSMAİL" finds "İsmail".
 */
export function abonmanAra(liste: readonly Abonman[], q: string): Abonman[] {
  const ham = q.trim()
  if (!ham) return [...liste]
  const plaka = ham.replace(/\s+/g, '').toLocaleUpperCase('tr').replace(/İ/g, 'I')
  const isim = ham.toLocaleLowerCase('tr')
  return liste.filter(
    (a) => a.plaka.includes(plaka) || (a.musteri_ad ?? '').toLocaleLowerCase('tr').includes(isim),
  )
}

export function abonmanOzeti(liste: readonly Abonman[]): { adet: number; toplamKurus: number } {
  return { adet: liste.length, toplamKurus: liste.reduce((t, a) => t + a.ucret_kurus, 0) }
}

/** Calendar days from `bugun` to `gun`, both 'YYYY-MM-DD' (UTC math: no zone). */
function gunFarki(bugun: string, gun: string): number {
  const [ty = 0, tm = 1, td = 1] = bugun.split('-').map(Number)
  const [hy = 0, hm = 1, hd = 1] = gun.split('-').map(Number)
  return Math.round((Date.UTC(hy, hm - 1, hd) - Date.UTC(ty, tm - 1, td)) / 86_400_000)
}

/**
 * The card's warning: only an AKTIF abonman within 4 days of its end — the
 * same window as the "Abonman bitiyor" notice (083). A past end date can still
 * read AKTIF until the nightly job runs.
 */
export function kalanRozeti(a: Pick<Abonman, 'durum' | 'bitis'>, bugun: string): string | null {
  if (a.durum !== 'AKTIF') return null
  const kalan = gunFarki(bugun, a.bitis)
  if (kalan > 4) return null
  if (kalan < 0) return 'Süresi doldu'
  if (kalan === 0) return 'Bugün bitiyor'
  return `${kalan} gün kaldı`
}
