import { PARK_YERI_TIP_ETIKET, type ParkYeri, type ParkYeriDurumu } from './types'

/**
 * The park-spot naming scheme — P-01 (normal), E-01 (engelli), R-01 (rezerve).
 *
 * This mirrors `park_yerleri_uret` in migration 009 exactly, and it has to:
 * the settings screen previews what the RPC is about to do, so the two must
 * produce the same codes from the same numbers or the preview is a lie. The
 * server is still the one that decides — this file only reads and predicts.
 */

export type YerGrup = 'NORMAL' | 'ENGELLI' | 'REZERVE'

export const YER_GRUPLARI: {
  grup: YerGrup
  onek: string
  etiket: string
}[] = [
  { grup: 'NORMAL', onek: 'P', etiket: 'Normal' },
  { grup: 'ENGELLI', onek: 'E', etiket: 'Engelli' },
  { grup: 'REZERVE', onek: 'R', etiket: 'Rezerve' },
]

/**
 * Two digits, always — P-01 … P-99, then P-100.
 *
 * NOT padded to the width of the capacity: that would rename P-01 to P-001 the
 * moment a lot passed 99 spots, orphaning every row and every ticket pointing
 * at one. The code for spot N is fixed for the life of the lot. (Rule 4 in
 * migration 009.)
 */
export function yerKodu(onek: string, sira: number): string {
  return `${onek}-${String(sira).padStart(2, '0')}`
}

/** Six digits max, matching the `{1,6}` bound the RPC uses to keep its cast safe. */
const KOD_DESENI = /^([PER])-(\d{1,6})$/

/** The group a code belongs to, or null when it is outside the scheme. */
export function kodGrubu(kod: string): { grup: YerGrup; sira: number } | null {
  const m = KOD_DESENI.exec(kod)
  if (!m) return null
  const grup = YER_GRUPLARI.find((g) => g.onek === m[1])
  if (!grup) return null
  return { grup: grup.grup, sira: Number(m[2]) }
}

export interface YerDuzeni {
  normal: number
  engelli: number
  rezerve: number
  /** Active spots the scheme does not own — sample rows, hand-made bays. */
  digerleri: ParkYeri[]
}

/**
 * What the lot looks like right now, in the scheme's terms.
 *
 * Counts are of ACTIVE spots only, because that is what the generator is asked
 * to produce: a retired P-40 is a bay the lot does not currently have.
 */
export function yerDuzeni(yerler: ParkYeri[]): YerDuzeni {
  const d: YerDuzeni = { normal: 0, engelli: 0, rezerve: 0, digerleri: [] }
  for (const y of yerler) {
    if (!y.is_active) continue
    const k = kodGrubu(y.kod)
    if (!k) {
      d.digerleri.push(y)
    } else if (k.grup === 'NORMAL') d.normal++
    else if (k.grup === 'ENGELLI') d.engelli++
    else d.rezerve++
  }
  return d
}

/** "P-01 … P-36", "P-01, P-02", "P-01" — or null when the group is empty. */
export function kodAraligi(onek: string, adet: number): string | null {
  if (adet <= 0) return null
  if (adet === 1) return yerKodu(onek, 1)
  if (adet === 2) return `${yerKodu(onek, 1)}, ${yerKodu(onek, 2)}`
  return `${yerKodu(onek, 1)} … ${yerKodu(onek, adet)}`
}

/**
 * Natural order: P-9 before P-10 before P-100.
 *
 * Plain string ordering — which is what `.order('kod')` gives us from the
 * server — puts "P-100" between "P-10" and "P-11", because it compares the
 * third character. Sorting here rather than padding to three digits is what
 * lets rule 4 above hold. Codes outside the scheme keep locale ordering and
 * sort after the generated ones, so a stray A-01 never lands in the middle of
 * the numbered run.
 */
export function kodKarsilastir(a: string, b: string): number {
  const ka = kodGrubu(a)
  const kb = kodGrubu(b)
  if (ka && kb) {
    if (ka.grup !== kb.grup) {
      return (
        YER_GRUPLARI.findIndex((g) => g.grup === ka.grup) -
        YER_GRUPLARI.findIndex((g) => g.grup === kb.grup)
      )
    }
    return ka.sira - kb.sira
  }
  if (ka) return -1
  if (kb) return 1
  return a.localeCompare(b, 'tr')
}

/** Sorted copy — the callers hold query data, which must not be mutated. */
export function yerleriSirala<T extends { kod: string }>(yerler: T[]): T[] {
  return [...yerler].sort((a, b) => kodKarsilastir(a.kod, b.kod))
}

/**
 * The block a code belongs to — the letters in front of its number.
 *
 * Deliberately NOT `kodGrubu`: that one only knows the generated P/E/R scheme
 * and would drop every hand-made bay (A-01, S-01, the seed's own rows) into
 * one undifferentiated pile. A lot is signposted by its blocks on the ground,
 * so the plan follows the code the operator is standing in front of.
 */
export function blokKodu(kod: string): string {
  // `noUncheckedIndexedAccess` is on: a matched group is still `| undefined`
  // to the compiler, so it is bound once rather than indexed twice.
  const harf = /^\s*([A-Za-zÇĞİÖŞÜçğıöşü]+)/.exec(kod)?.[1]
  return harf ? harf.toLocaleUpperCase('tr') : ''
}

/** "Normal" / "Engelli" / "Rezerve" for the scheme, "A Blok" for the rest. */
export function blokEtiketi(blok: string): string {
  if (!blok) return 'Diğer'
  const g = YER_GRUPLARI.find((x) => x.onek === blok)
  return g ? g.etiket : `${blok} Blok`
}

export interface YerBlok<T> {
  blok: string
  etiket: string
  yerler: T[]
}

/**
 * Bays grouped into their blocks, in the order they arrive.
 *
 * The caller passes rows already sorted by `yerleriSirala`, and that ordering
 * puts every scheme code before every hand-made one and keeps each prefix
 * contiguous — so first-appearance order here is the same order the list had.
 * Grouping through a Map rather than by run-length also means a stray code
 * that sorts away from its neighbours still lands in its own block instead of
 * opening a second one with the same name.
 */
export function yerleriBloklara<T extends { kod: string }>(yerler: T[]): YerBlok<T>[] {
  const bloklar = new Map<string, YerBlok<T>>()
  for (const y of yerler) {
    const blok = blokKodu(y.kod)
    let g = bloklar.get(blok)
    if (!g) {
      g = { blok, etiket: blokEtiketi(blok), yerler: [] }
      bloklar.set(blok, g)
    }
    g.yerler.push(y)
  }
  return [...bloklar.values()]
}

export interface YerHedef {
  normal: number
  engelli: number
  rezerve: number
}

export interface YerDegisim {
  /** Bays that will appear — newly inserted, or retired ones coming back. */
  eklenecek: number
  /** Bays that will be retired. Never deleted. */
  kapanacak: number
}

/**
 * What pressing Kaydet is about to do, so nobody is surprised by it.
 *
 * Mirrors `park_yerleri_uret` statement for statement: a code is "already
 * there" only under its canonical two-digit spelling, and a row is retired
 * only when its number falls outside 1..adet — exactly the RPC's
 * `not between` test. A hand-made P-1 is therefore counted the way the server
 * treats it: P-01 still gets inserted beside it, and P-1 itself is left alone.
 *
 * It cannot predict SKIPS: whether a bay holds a car or a live reservation is
 * a server-side question, and the RPC reports the ones it protected by code
 * once it has run.
 */
export function yerDegisimi(yerler: ParkYeri[], hedef: YerHedef): YerDegisim {
  const adet: Record<YerGrup, number> = {
    NORMAL: hedef.normal,
    ENGELLI: hedef.engelli,
    REZERVE: hedef.rezerve,
  }
  const satirlar = new Map(yerler.map((y) => [y.kod, y]))

  let eklenecek = 0
  for (const g of YER_GRUPLARI) {
    for (let i = 1; i <= adet[g.grup]; i++) {
      const y = satirlar.get(yerKodu(g.onek, i))
      if (!y || !y.is_active) eklenecek++
    }
  }

  let kapanacak = 0
  for (const y of yerler) {
    if (!y.is_active) continue
    const k = kodGrubu(y.kod)
    if (!k) continue
    if (k.sira < 1 || k.sira > adet[k.grup]) kapanacak++
  }

  return { eklenecek, kapanacak }
}

/**
 * The bay an entry should be proposed for, or null when the lot is full.
 *
 * A deliberate mirror of `bos_park_yeri()` in migration 010, predicate for
 * predicate: an ordinary bay, empty, not reserved and not spoken for by a
 * reservation. The camera path takes its bay from the server function and the
 * operator sees this one pre-selected — if the two rules drifted, the same car
 * would be placed differently depending on which door it came through.
 *
 * The rows arrive already in the server's order, so "first" here is the same
 * "first" the server means. Engelli, şarj and rezerve bays are never proposed
 * automatically: those belong to somebody, and only a person at the barrier
 * knows when that somebody has arrived.
 */
export function ilkBosYer(durumlar: ParkYeriDurumu[]): string | null {
  const y = durumlar.find(
    (d) => !d.dolu_plaka && !d.rezervasyonlu && !d.rezerve && d.tip === 'NORMAL',
  )
  return y?.id ?? null
}

/** How a bay reads in the picker: "P-04 · rezervasyonlu", "P-03 · 34ABC12". */
export function yerSecenekEtiketi(d: ParkYeriDurumu): string {
  if (d.dolu_plaka) return `${d.kod} · ${d.dolu_plaka}`
  const notlar: string[] = []
  if (d.tip !== 'NORMAL') notlar.push(PARK_YERI_TIP_ETIKET[d.tip].toLocaleLowerCase('tr'))
  if (d.rezerve) notlar.push('rezerve')
  if (d.rezervasyonlu) notlar.push('rezervasyonlu')
  return notlar.length ? `${d.kod} · ${notlar.join(' · ')}` : d.kod
}
