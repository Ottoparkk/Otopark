/**
 * Kademeli tarife (051) — the band rows of the Tarife form, their validation,
 * and a fee preview.
 *
 * No runtime imports on purpose: Node cannot resolve the app's extensionless
 * paths, so the money helpers come in as `araclar` — the screen passes the
 * real ones from lib/money, and so does `tests/kademe.check.mjs`.
 *
 * The SERVER prices every ticket (`ucret_hesapla` → `ucret_kademeli`) and
 * validates the list (`kademeler_gecerli`, a CHECK and the RPC). These rules
 * mirror it so the form explains a refusal before sending, and `kademeUcret`
 * exists only to show examples on screen; the test pins both to the same
 * numbers as smoke test PASS 73.
 *
 * Rules (owner, 2026-11-07): a band is "N saate kadar X ₺"; the boundary
 * belongs to the LOWER band (2:00 = 200, 2:01 = 300); the last band ends at
 * 24 h; past 24 h every FULL day costs the last band's price and the remainder
 * is priced by the bands again.
 */

export interface KademeAraclari {
  parseTLToKurus: (input: string) => number | null
  kurusToInput: (kurus: number) => string
}

/** One row as stored: upper bound in minutes (inclusive) and its price. */
export interface Kademe {
  dakika: number
  kurus: number
}

/** One row as typed: hours ("2") and lira ("200"). */
export interface KademeSatiri {
  saat: string
  tutar: string
}

/** Mirrors `kademeler_gecerli` (051). */
export const KADEME_EN_COK = 12
const GUN_DAKIKA = 1440

export function kademeBaslangic(
  liste: Kademe[] | null | undefined,
  araclar: KademeAraclari,
): KademeSatiri[] {
  if (!liste || liste.length === 0) return [{ saat: '24', tutar: '' }]
  return liste.map((k) => ({
    saat: String(k.dakika / 60),
    // kurusToInput, NOT formatTL: grouped thousands are refused by
    // parseTLToKurus, so the field would reject the value it was filled with.
    tutar: araclar.kurusToInput(k.kurus),
  }))
}

/** The single validation site; null = the server will accept the list. */
export function kademeHatasi(satirlar: KademeSatiri[], araclar: KademeAraclari): string | null {
  if (satirlar.length === 0) return 'En az bir kademe girin.'
  if (satirlar.length > KADEME_EN_COK) return `En fazla ${KADEME_EN_COK} kademe olabilir.`
  let oncekiSaat = 0
  let oncekiKurus = 0
  for (const s of satirlar) {
    const saatMetni = s.saat.trim()
    const saat = /^\d+$/.test(saatMetni) ? Number(saatMetni) : NaN
    if (!(saat >= 1 && saat <= 24)) return 'Kademe saatleri 1-24 arası tam sayı olmalı.'
    if (saat <= oncekiSaat) return 'Kademe saatleri artan sırada olmalı.'
    const kurus = araclar.parseTLToKurus(s.tutar.trim())
    if (kurus === null) return 'Kademe ücretlerini geçerli girin (örn. 200 ya da 200,50).'
    if (kurus < oncekiKurus) return 'Daha uzun kalan araç daha az ödeyemez — ücretler azalmamalı.'
    oncekiSaat = saat
    oncekiKurus = kurus
  }
  if (oncekiSaat !== 24) return 'Son kademe 24 saate kadar olmalı.'
  return null
}

/** Rows → the list the RPC stores. Call only after kademeHatasi() returned null. */
export function kademeListesi(satirlar: KademeSatiri[], araclar: KademeAraclari): Kademe[] {
  return satirlar.map((s) => ({
    dakika: Number(s.saat.trim()) * 60,
    kurus: araclar.parseTLToKurus(s.tutar.trim()) ?? 0,
  }))
}

/**
 * The fee for a stay of `dakika` minutes (already rounded up), exactly as
 * `ucret_kademeli` computes it. For on-screen examples only.
 */
export function kademeUcret(dakika: number, ucretsizDakika: number, liste: Kademe[]): number {
  if (dakika <= ucretsizDakika) return 0
  const gun = Math.floor(dakika / GUN_DAKIKA)
  const kalan = dakika % GUN_DAKIKA
  const son = liste[liste.length - 1]
  if (!son) throw new Error('Kademe listesi boş.')
  const gunluk = son.kurus
  let parca = 0
  if (kalan > 0) {
    const kademe = liste.find((k) => k.dakika >= kalan)
    if (!kademe) throw new Error('Kademe bulunamadı.')
    parca = kademe.kurus
  }
  return gun * gunluk + parca
}

/** "0–2 saat · ₺200"-style rows for the list card. */
export function kademeAraliklari(liste: Kademe[]): { etiket: string; kurus: number }[] {
  let onceki = 0
  return liste.map((k) => {
    const saat = k.dakika / 60
    const etiket = `${onceki}–${saat} saat`
    onceki = saat
    return { etiket, kurus: k.kurus }
  })
}
