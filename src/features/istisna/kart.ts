// Rules for one card on "Çözülmemiş kayıtlar": the one-line status, the short
// what-to-do line, the plate the field starts with, which buttons show, which
// tab the card is in and who did what. Type-only imports, so
// `node tests/istisna.check.mjs` can run this file directly.
import type { Istisna, IstisnaTur } from '../../lib/types'
import type { KimSatiri } from '../../lib/kimYapti'

/**
 * What to DO, in one short line (owner 2026-11-23: the detail is short, gives
 * the context directly, and is always shown — no "Ayrıntı" tap). It names
 * only buttons the card actually has (eylemler); `tests/istisna.check.mjs`
 * checks every type, lane and source for that and for ≤ 100 characters.
 * What HAPPENED is the status line above it (kisaDurum).
 */
const TUR_ACIKLAMA: Record<IstisnaTur, string> = {
  GELECEK: 'Yöneticiye haber verin. Araç içerideyse girişini Gişe\'den açın.',
  BAYAT: 'Araç içerideyse girişini Gişe\'den açın. Değilse Kapat\'a basın.',
  ACIK_BILET_YOK: 'Plaka yanlış okunmuş olabilir. Doğru bileti Çıkış\'tan bulun.',
  COKLU_ESLESME: 'Doğru aracı Çıkış\'tan seçin.',
  YON_BELIRSIZ: 'Araç çıkıyorsa Çıkış\'a basın. Yeni gelen araçsa girişini Gişe\'den açın.',
  OKUNAMADI: 'Bileti yoksa plakayı yazıp Giriş aç\'a, varsa Kapat\'a basın.',
  GIRISTE_ACIK_BILET:
    'Araç çıkıp döndüyse eski bileti Çıkış\'tan kapatın. Hiç çıkmadıysa Kapat\'a basın.',
  // 054: the camera may have closed this car's ticket as an exit by mistake —
  // then the fix is "Araç çıkmadı" on that ticket, not a new entry.
  ICERIDE_BILETSIZ:
    'Kamera az önce çıkış saydıysa o bileti açıp "Araç çıkmadı"ya basın. Değilse Giriş aç\'a basın.',
  // 071: the refusal sentence is on the status line; this says what to do.
  REDDEDILDI: 'Araç içerideyse ve bileti yoksa girişini Gişe\'den açın. Değilse Kapat\'a basın.',
  CIKMAMIS_OLABILIR: 'Araç çıkmadıysa Bilete git\'e basıp "Araç çıkmadı"yı seçin. Çıktıysa Kapat\'a basın.',
}

// Single gate: the car may have been LEAVING, and an entry for it would leave
// a phantom ticket that blocks that plate's next real entry.
const OKUNAMADI_TEK_KAPI =
  'Araç girdi mi çıktı mı belli değil. Girdiyse Giriş aç\'a, çıktıysa Kapat\'a basın.'
// 072: a camera "exit, no open ticket" on the single gate may have been a car
// coming in; Giriş aç then asks for the entry time and a reason.
const ACIK_BILET_YOK_TEK_KAPI =
  'Araç girdiyse Giriş aç\'a basıp giriş saatini yazın. Çıktıysa Kapat\'a basın.'
// 071: on the exit lane and the single gate the refused car may have been leaving.
const REDDEDILDI_CIKIS = 'Araç içerideyse girişini Gişe\'den açın. Çıkıyorsa Çıkış\'a basın.'

export function aciklama(i: Istisna): string {
  if (i.tur === 'OKUNAMADI' && i.yon === 'ORTAK') return OKUNAMADI_TEK_KAPI
  if (eylemler(i).girisAcSaatli) return ACIK_BILET_YOK_TEK_KAPI
  if (i.tur === 'REDDEDILDI' && i.yon !== 'GIRIS') return REDDEDILDI_CIKIS
  return TUR_ACIKLAMA[i.tur]
}

/**
 * When the plate field starts with the camera's GUESS (an OKUNAMADI row has
 * no plate), say so — with the confidence when there is one. Null otherwise.
 */
export function tahminNotu(i: Istisna): string | null {
  if (i.cozuldu_at !== null || i.plaka) return null
  const { tahmin, guven } = okumaBilgisi(i)
  if (!tahmin) return null
  return guven === null
    ? 'Plaka kameranın tahmini, kontrol edin.'
    : `Plaka kameranın tahmini (%${Math.round(guven * 100)}), kontrol edin.`
}

/**
 * What an OKUNAMADI row carries in `ham_yanit` (039): the model's guess and
 * confidence, or that plate reading itself failed. The raw error goes to the
 * Yönetici's alert only — it is not for the gate.
 */
export function okumaBilgisi(i: Istisna): {
  tahmin: string | null
  guven: number | null
  servisHatasi: boolean
} {
  const ham: Record<string, unknown> = i.tur === 'OKUNAMADI' && i.ham_yanit ? i.ham_yanit : {}
  return {
    tahmin: typeof ham.tahmin === 'string' && ham.tahmin ? ham.tahmin : null,
    guven: typeof ham.guven === 'number' ? ham.guven : null,
    servisHatasi: typeof ham.hata === 'string',
  }
}

const KISA: Record<IstisnaTur, string> = {
  GELECEK: 'Kamera saati ileri, kayıt alınmadı',
  BAYAT: 'Kayıt çok geç geldi',
  ACIK_BILET_YOK: 'Çıkan aracın açık bileti yok',
  COKLU_ESLESME: 'Birden çok bilete benziyor',
  YON_BELIRSIZ: 'İçerideki bir araca benziyor',
  OKUNAMADI: 'Plaka okunamadı',
  GIRISTE_ACIK_BILET: 'Giren aracın eski bileti açık',
  ICERIDE_BILETSIZ: 'İçerideki aracın bileti yok',
  REDDEDILDI: 'Sistem kaydı almadı',
  CIKMAMIS_OLABILIR: 'Çıktı sayıldı, içeride görüldü',
}

/** The refusal sentence on a REDDEDILDI row (071), cut to fit one line. */
function retSebebi(i: Istisna): string | null {
  const s = i.tur === 'REDDEDILDI' && i.ham_yanit ? i.ham_yanit.ret_sebebi : null
  if (typeof s !== 'string' || !s.trim()) return null
  const t = s.trim()
  return t.length > 80 ? t.slice(0, 79) + '…' : t
}

/** The card's single status line. */
export function kisaDurum(i: Istisna): string {
  if (i.tur === 'OKUNAMADI' && okumaBilgisi(i).servisHatasi) {
    return 'Plaka okuma çalışmıyordu'
  }
  const ret = retSebebi(i)
  if (ret) return 'Sistem almadı: ' + ret
  // 077 E2: the entry card's plate was read a little later inside the yard.
  if (i.tur === 'OKUNAMADI' && i.ham_yanit?.sonradan_sebep === 'ICERIDE') {
    return 'Girişte okunamadı, içeride okundu'
  }
  return KISA[i.tur]
}

/**
 * What the plate field starts with: the row's plate, else the model's guess
 * (an OKUNAMADI row has no plate — the guess is the best start), else empty.
 * Not normalised here: the field normalises every keystroke.
 */
export function baslangicPlakasi(i: Istisna): string {
  return i.plaka ?? okumaBilgisi(i).tahmin ?? ''
}

/** Buttons on a card. */
export type Eylemler = {
  girisAc: boolean
  cikis: boolean
  kapat: boolean
  /** 072: Giriş aç with a typed entry time and a reason (tek kapı ACIK_BILET_YOK). */
  girisAcSaatli: boolean
  /** 072: the ticket to open ("Araç çıkmadı" lives there), or null. */
  bileteGit: string | null
}

/**
 * Buttons on an open row. "Giriş aç" for an unreadable plate and, since 056,
 * a car seen inside with no ticket — the kinds istisna_bilet_ac accepts.
 * "Çıkış" keeps the old rule exactly — an exit-lane event, a doubtful
 * single-gate read, or an unreadable plate on the single gate (that car may
 * have been leaving) — plus, since 056, a car seen entering whose OLD ticket
 * is still open (close that one from the exit screen). A resolved row has none.
 *
 * 072 (owner 2026-11-18): on the single gate a camera "exit with no open
 * ticket" may really have been a car coming in — "Giriş aç" there asks for
 * the entry time (typed, never the card's time) and a reason
 * (istisna_bilet_ac_saatli). A CIKMAMIS_OLABILIR card leads to its ticket.
 */
export function eylemler(i: Istisna): Eylemler {
  if (i.cozuldu_at !== null) {
    return { girisAc: false, cikis: false, kapat: false, girisAcSaatli: false, bileteGit: null }
  }
  return {
    girisAc: i.tur === 'OKUNAMADI' || i.tur === 'ICERIDE_BILETSIZ',
    cikis:
      (i.tur !== 'GELECEK' && i.tur !== 'CIKMAMIS_OLABILIR' && i.yon === 'CIKIS') ||
      i.tur === 'YON_BELIRSIZ' ||
      (i.tur === 'OKUNAMADI' && i.yon === 'ORTAK') ||
      i.tur === 'GIRISTE_ACIK_BILET' ||
      // 071: on the single gate the refused car may have been leaving.
      (i.tur === 'REDDEDILDI' && i.yon === 'ORTAK'),
    kapat: true,
    girisAcSaatli: i.tur === 'ACIK_BILET_YOK' && i.yon === 'ORTAK' && i.kaynak === 'KAMERA',
    bileteGit: i.tur === 'CIKMAMIS_OLABILIR' ? (i.aday_bilet_ids?.[0] ?? null) : null,
  }
}

/** The three tabs (owner 2026-11-23, 075). */
export type Sekme = 'BEKLEYEN' | 'COZULMUS' | 'KAPATILAN'

/**
 * Which tab a row belongs to. Waiting = not resolved. Closed = resolved with
 * "Kapat" (`kapatildi`, set only by istisna_coz). Everything else resolved —
 * by an action (Giriş aç) or by the camera itself — is "Çözülmüş".
 */
export function sekme(i: Istisna): Sekme {
  if (i.cozuldu_at === null) return 'BEKLEYEN'
  return i.kapatildi === true ? 'KAPATILAN' : 'COZULMUS'
}

/**
 * Who did what, for the Yönetici (063 pattern). `ad` is the resolver's name,
 * already looked up by the caller (adCoz); a resolved row with no resolver was
 * closed by the camera itself. An unknown person is never shown as a wrong
 * name: "Bilinmiyor".
 */
export function kimSatirlari(i: Istisna, ad: string | null): KimSatiri[] {
  const s = sekme(i)
  if (s === 'BEKLEYEN') return []
  const kim = i.cozuldu_by ? (ad ?? 'Bilinmiyor') : 'Kamera'
  const satirlar: KimSatiri[] = [
    { etiket: s === 'KAPATILAN' ? 'Kapatan' : 'Çözen', ad: kim, zaman: i.cozuldu_at },
  ]
  if (i.cozum_notu) {
    satirlar.push({ etiket: s === 'KAPATILAN' ? 'Not' : 'Ne yapıldı', ad: i.cozum_notu, zaman: null })
  }
  return satirlar
}
