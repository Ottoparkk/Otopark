/**
 * Vardiya raporu (086, owner 28.11): the list label and the Turkish names of
 * the actions the report shows. Pure (tests/vardiyaEtiket.check.mjs).
 *
 * Istanbul is fixed UTC+3, whatever the device's zone.
 */

const IST_MS = 3 * 3600_000

function istParca(iso: string): { gun: string; saat: string; dk: number } {
  const d = new Date(Date.parse(iso) + IST_MS)
  const iki = (n: number) => String(n).padStart(2, '0')
  return {
    gun: `${iki(d.getUTCDate())}.${iki(d.getUTCMonth() + 1)}`,
    saat: `${iki(d.getUTCHours())}:${iki(d.getUTCMinutes())}`,
    dk: d.getUTCHours() * 60 + d.getUTCMinutes(),
  }
}

/** Gündüz when the shift opened 06:00–17:59 Istanbul time, otherwise Gece. */
export function vardiyaTuru(acilisAt: string): 'Gündüz' | 'Gece' {
  const { dk } = istParca(acilisAt)
  return dk >= 6 * 60 && dk < 18 * 60 ? 'Gündüz' : 'Gece'
}

/** "28.11 Gündüz 09:04 → 21:35"; with `kisa`, just "28.11 Gündüz". */
export function vardiyaEtiketi(
  acilisAt: string,
  kapanisAt: string | null,
  secenek: { kisa?: boolean } = {},
): string {
  const a = istParca(acilisAt)
  const tur = vardiyaTuru(acilisAt)
  if (secenek.kisa) return `${a.gun} ${tur}`
  const son = kapanisAt ? istParca(kapanisAt).saat : 'şimdi'
  return `${a.gun} ${tur} ${a.saat} → ${son}`
}

export interface Karsilastirma {
  /** Whole percent, always positive; the direction is in `yon`. */
  yuzde: number
  yon: 'yukari' | 'asagi' | 'ayni'
}

/**
 * This shift's total against the previous shift of the same type (Gündüz
 * with Gündüz, Gece with Gece), the one-line comparison of a Rocket Money
 * style summary. Null when there is nothing fair to compare with: no earlier
 * shift of that type, no total yet, or an earlier total of 0.
 */
export function oncekiKarsilastirma(
  liste: readonly { id: string; acilis_at: string }[],
  id: string,
  toplamlar: ReadonlyMap<string, { toplam: number }> | undefined,
): Karsilastirma | null {
  const bu = liste.find((v) => v.id === id)
  const buToplam = toplamlar?.get(id)?.toplam
  if (!bu || buToplam === undefined) return null
  const tur = vardiyaTuru(bu.acilis_at)
  const t0 = Date.parse(bu.acilis_at)
  const onceki = liste
    .filter((v) => Date.parse(v.acilis_at) < t0 && vardiyaTuru(v.acilis_at) === tur)
    .sort((x, y) => Date.parse(y.acilis_at) - Date.parse(x.acilis_at))[0]
  return yuzdeFark(buToplam, onceki ? toplamlar?.get(onceki.id)?.toplam : undefined)
}

/**
 * `simdi` against `once` as a whole percent. Null when `once` is missing or
 * not above 0 — a percentage of nothing is no comparison.
 */
export function yuzdeFark(simdi: number, once: number | null | undefined): Karsilastirma | null {
  if (!once || once <= 0) return null
  const fark = Math.round(((simdi - once) / once) * 100)
  return { yuzde: Math.abs(fark), yon: fark > 0 ? 'yukari' : fark < 0 ? 'asagi' : 'ayni' }
}

/* ------------------------------------------------ günlük rapor (087) --- */

const GUNLER = ['Pazar', 'Pazartesi', 'Salı', 'Çarşamba', 'Perşembe', 'Cuma', 'Cumartesi']
/** Ablative ("-den") of each weekday, lowercase, for "geçen cumadan". */
const GUNDEN = [
  'pazardan',
  'pazartesiden',
  'salıdan',
  'çarşambadan',
  'perşembeden',
  'cumadan',
  'cumartesiden',
]

/** Calendar arithmetic on a bare 'YYYY-MM-DD' — no zone, no DST. */
function gunNo(gun: string): number {
  const [y, m, d] = gun.split('-').map(Number)
  return Date.UTC(y ?? 1970, (m ?? 1) - 1, d ?? 1) / 86_400_000
}

function haftaGunu(gun: string): number {
  return new Date(gunNo(gun) * 86_400_000).getUTCDay()
}

/** "Bugün", "Dün", otherwise "26.11 Perşembe". `bugun` is today, Istanbul. */
export function gunEtiketi(gun: string, bugun: string): string {
  const fark = gunNo(bugun) - gunNo(gun)
  if (fark === 0) return 'Bugün'
  if (fark === 1) return 'Dün'
  const [, m, d] = gun.split('-')
  return `${d}.${m} ${GUNLER[haftaGunu(gun)]}`
}

/** "geçen cumadan" — the chip's tail; the day compared is a week earlier. */
export function gecenGunMetni(gun: string): string {
  return `geçen ${GUNDEN[haftaGunu(gun)]}`
}

/**
 * The Rapor list's day rows: today left out (it is the hero card), and a day
 * with no money and no cars is not worth a row. Newest first.
 */
export function gecmisGunler<T extends { toplam: number; arac: number }>(
  gunler: Map<string, T> | undefined,
  bugun: string,
): [string, T][] {
  return [...(gunler?.entries() ?? [])]
    .filter(([g, t]) => g !== bugun && (t.toplam !== 0 || t.arac > 0))
    .sort(([a], [b]) => (a < b ? 1 : -1))
}

/** 'YYYY-MM' of the month before. */
export function oncekiAy(ay: string): string {
  const [y = 0, m = 1] = ay.split('-').map(Number)
  return m === 1 ? `${y - 1}-12` : `${y}-${String(m - 1).padStart(2, '0')}`
}

/**
 * Whether "Önceki ayı gör" has anything to show: a month older than the oldest
 * one on screen can only hold records if the first record is older still.
 * Unknown first day: offer it (an empty month says "kayıt yok").
 */
export function oncekiAyVar(enEskiAy: string, ilkGun: string | undefined): boolean {
  if (!ilkGun) return true
  return ilkGun.slice(0, 7) < enEskiAy
}

const ISLEMLER: Record<string, string> = {
  bilet_iptal: 'Bilet iptal',
  bilet_iptal_talebi: 'İptal talebi',
  bilet_iptal_onay: 'İptal onaylandı',
  bilet_iptal_ret: 'İptal reddedildi',
  bilet_ucretsiz_cikis: 'Ücretsiz çıkış',
  bilet_odemesiz_cikis: 'Ödemesiz çıkış',
  bilet_cikis_geri_alindi: 'Araç çıkmadı',
  bilet_kamera_geri_acildi: 'Araç çıkmadı (kamera)',
  bilet_asim_karar: 'Süre aşımı kararı',
  bilet_ucret_degisikligi: 'Ücret değişikliği',
  bilet_anlasma: 'Anlaşmalı fiyat',
  kayip_bilet: 'Kayıp bilet',
  bilet_sil: 'Bilet silindi',
  tahsilat_reddet: 'Tahsilat reddedildi',
  vardiya_devir: 'Devraldı',
  pin_kilit: 'PIN kilitlendi',
  odeme_sonrasi_gec_cikis: 'Ödedikten sonra geç çıktı',
}

/** Turkish name of an audit action; an unknown code comes back as is. */
export function islemEtiketi(action: string): string {
  return ISLEMLER[action] ?? action
}
