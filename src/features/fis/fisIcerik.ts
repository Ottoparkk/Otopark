import type { Bilet, OdemeYontemi, OtoparkAyarlari, UcretsizSebep } from '../../lib/types'

/**
 * What a 58 mm fiş says (088; owner 22.11 / 28.11: "so we don't argue with
 * the customers on money"). Pure: the lines only, as data — FisBaski draws
 * them for print, FisSayfasi for the preview. No runtime imports (Node check:
 * `node tests/fis.check.mjs`); formatters are passed in as `araclar`.
 *
 * Rules the owner set:
 *  - no "Mali değeri yoktur." line (owner 28.11) — the legal receipt is still the till's;
 *  - no grace or "leave within N minutes" text, ever ("No grace on the fiş");
 *  - no QR — nothing scans it yet, and it took a third of the paper (owner 28.11);
 *  - a reprint says so ("TEKRAR BASIM (n)"), n from `fis_basildi`;
 *  - the entry fiş's estimate is only an estimate: the fee is the real time;
 *  - only the car park's name on top — no address, no phone (owner 28.11);
 *  - no price list: money appears only where it was set beforehand (an
 *    agreed price, a wash, the stay the customer named) — owner 28.11.
 * Every amount is read from the server (ticket row, `fis_tahmini`); nothing
 * here computes what anyone owes.
 */

export type FisSatiri =
  | { t: 'baslik'; metin: string }
  | { t: 'alt'; metin: string }
  | { t: 'buyuk'; metin: string }
  | { t: 'satir'; sol: string; sag: string; kalin?: boolean }
  | { t: 'cizgi' }
  | { t: 'not'; metin: string }

export interface FisAraclari {
  /** Integer kuruş → "150 ₺" (lib/money formatTL). */
  tl: (kurus: number) => string
  /** Istanbul "14:05" (lib/dates formatSaat). */
  saat: (iso: string) => string
  /** Istanbul "28.11.2026 14:05" (lib/dates formatTam). */
  tam: (iso: string) => string
  /** lib/ucretsiz ucretsizEtiket. */
  ucretsizEtiket: (s: UcretsizSebep | null | undefined) => string | null
  /** "34ABC123" → "34 ABC 123" (lib/plaka formatPlaka). */
  plaka: (p: string) => string
}

export type FisOtopark = Pick<OtoparkAyarlari, 'ad'>

export type FisBileti = Pick<
  Bilet,
  | 'id'
  | 'plaka'
  | 'giris_at'
  | 'cikis_at'
  | 'ucret_kurus'
  | 'indirim_kurus'
  | 'puan_kullanilan'
  | 'tahsil_kurus'
  | 'odeme_yontemi'
  | 'abonman_id'
  | 'yikama_kurus'
  | 'anlasma_kurus'
  | 'anlasma_bitis'
  | 'ucretsiz_sebep'
>

export interface GirisFisiGirdisi {
  otopark: FisOtopark
  bilet: FisBileti
  /** This print's number for this ticket and type (1 = first). */
  basim: number
  basimAt: string
  /** The customer's stated stay, priced by `fis_tahmini`; null = none. */
  tahmin: { dakika: number; kurus: number } | null
}

export interface CikisFisiGirdisi {
  otopark: FisOtopark
  bilet: FisBileti
  basim: number
  basimAt: string
}

const ODEME: Record<OdemeYontemi, string> = {
  NAKIT: 'Nakit',
  KREDI_KARTI: 'Kredi kartı',
  HAVALE: 'Havale',
}

/** First 8 characters of the ticket id — what staff read out on the phone. */
export function fisNo(id: string): string {
  return id.replace(/-/g, '').slice(0, 8).toUpperCase()
}

/** 127 → "2 sa 7 dk", 1625 → "1 gün 3 sa 5 dk", 0 → "0 dk". */
export function sureMetni(dakika: number): string {
  const d = Math.max(0, Math.floor(dakika))
  const gun = Math.floor(d / 1440)
  const sa = Math.floor((d % 1440) / 60)
  const dk = d % 60
  const parca: string[] = []
  if (gun) parca.push(`${gun} gün`)
  if (sa) parca.push(`${sa} sa`)
  if (dk || parca.length === 0) parca.push(`${dk} dk`)
  return parca.join(' ')
}

function bas(o: FisOtopark, tur: string, basim: number): FisSatiri[] {
  const s: FisSatiri[] = [{ t: 'baslik', metin: o.ad }, { t: 'cizgi' }]
  if (basim > 1) s.push({ t: 'baslik', metin: `TEKRAR BASIM (${basim})` })
  s.push({ t: 'baslik', metin: tur })
  return s
}

function son(basimAt: string, a: FisAraclari): FisSatiri[] {
  return [
    { t: 'cizgi' },
    { t: 'alt', metin: `Basım ${a.tam(basimAt)}` },
  ]
}

/** The entry fiş: who, when, and only the money agreed beforehand. */
export function girisFisi(g: GirisFisiGirdisi, a: FisAraclari): FisSatiri[] {
  const b = g.bilet
  const s = bas(g.otopark, 'GİRİŞ FİŞİ', g.basim)
  s.push({ t: 'buyuk', metin: a.plaka(b.plaka) })
  s.push({ t: 'satir', sol: 'Giriş', sag: a.tam(b.giris_at) })
  s.push({ t: 'satir', sol: 'Fiş no', sag: fisNo(b.id) })

  if (b.abonman_id) {
    s.push({ t: 'satir', sol: 'Abonman', sag: 'Ücret alınmaz' })
    return [...s, ...son(g.basimAt, a)]
  }

  if (b.anlasma_kurus != null) {
    s.push({ t: 'satir', sol: 'Anlaşmalı fiyat', sag: a.tl(b.anlasma_kurus) })
    if (b.anlasma_bitis) s.push({ t: 'satir', sol: 'Anlaşma bitişi', sag: a.saat(b.anlasma_bitis) })
  }
  if (b.yikama_kurus) s.push({ t: 'satir', sol: 'Oto yıkama', sag: a.tl(b.yikama_kurus) })

  if (g.tahmin) {
    const bitis = new Date(new Date(b.giris_at).getTime() + g.tahmin.dakika * 60_000).toISOString()
    s.push({ t: 'cizgi' })
    s.push({ t: 'satir', sol: 'Tahmini çıkış', sag: a.saat(bitis) })
    s.push({ t: 'satir', sol: `Tahmini ücret (${sureMetni(g.tahmin.dakika)})`, sag: a.tl(g.tahmin.kurus) })
  }
  return [...s, ...son(g.basimAt, a)]
}

/**
 * The exit fiş: the stay, what it cost, how it was paid. Only for a ticket
 * that has left and owes nothing — `fis_basildi` refuses the rest (and asks
 * for the 082 over-time decision first); this refuses them too.
 */
export function cikisFisi(g: CikisFisiGirdisi, a: FisAraclari): FisSatiri[] {
  const b = g.bilet
  if (!b.cikis_at) throw new Error('Çıkış fişi araç çıkış yaptıktan sonra basılır.')
  const net = b.ucret_kurus - b.indirim_kurus
  if (net > 0 && b.tahsil_kurus === 0) throw new Error('Önce ödeme toplayın.')

  const s = bas(g.otopark, 'ÇIKIŞ FİŞİ', g.basim)
  s.push({ t: 'buyuk', metin: a.plaka(b.plaka) })
  s.push({ t: 'satir', sol: 'Giriş', sag: a.tam(b.giris_at) })
  s.push({ t: 'satir', sol: 'Çıkış', sag: a.tam(b.cikis_at) })
  const dk = (new Date(b.cikis_at).getTime() - new Date(b.giris_at).getTime()) / 60_000
  s.push({ t: 'satir', sol: 'Süre', sag: sureMetni(dk) })
  s.push({ t: 'satir', sol: 'Fiş no', sag: fisNo(b.id) })
  s.push({ t: 'cizgi' })

  if (b.abonman_id) {
    s.push({ t: 'satir', sol: 'Abonman', sag: 'Ücret alınmaz' })
  } else if (b.ucretsiz_sebep) {
    s.push({ t: 'satir', sol: 'Ücretsiz çıkış', sag: a.ucretsizEtiket(b.ucretsiz_sebep) ?? '' })
  } else if (b.ucret_kurus > 0) {
    const yikama = b.yikama_kurus && b.yikama_kurus <= b.ucret_kurus ? b.yikama_kurus : 0
    s.push({ t: 'satir', sol: 'Park ücreti', sag: a.tl(b.ucret_kurus - yikama) })
    if (yikama) s.push({ t: 'satir', sol: 'Oto yıkama', sag: a.tl(yikama) })
    if (b.indirim_kurus > 0) s.push({ t: 'satir', sol: 'Puan indirimi', sag: a.tl(-b.indirim_kurus) })
  }
  s.push({ t: 'satir', sol: 'TOPLAM', sag: a.tl(Math.max(net, 0)), kalin: true })
  if (b.tahsil_kurus > 0) {
    if (b.odeme_yontemi) s.push({ t: 'satir', sol: 'Ödeme', sag: ODEME[b.odeme_yontemi] })
    s.push({ t: 'baslik', metin: 'ÖDENDİ' })
  }
  return [...s, ...son(g.basimAt, a)]
}
