// Rules for one card on "Çözülmemiş kayıtlar": the one-line status, the plate
// the field starts with, which buttons show, and the long explanation that now
// sits behind "Ayrıntı". Type-only imports, so `node tests/istisna.check.mjs`
// can run this file directly.
import type { Istisna, IstisnaTur } from '../../lib/types'

/** What the operator should actually DO — shown only under "Ayrıntı". */
const TUR_ACIKLAMA: Record<IstisnaTur, string> = {
  GELECEK:
    'Olayın saati ileri tarihli olduğu için kabul edilmedi. Kameranın saati yanlış olabilir.',
  BAYAT:
    'Olay çok geç ulaştı; araç çoktan çıkmış olabilir, bu yüzden bilet açılmadı.',
  ACIK_BILET_YOK:
    'Çıkışta bu plakaya ait açık bilet bulunamadı. Plaka yanlış okunmuş ya da giriş kaydedilmemiş olabilir.',
  COKLU_ESLESME:
    'Çıkan aracın plakası içerideki bir ya da birkaç aracınkine benziyor (son dört karakter). Kamera bileti kendiliğinden kapatmadı; doğru aracı Çıkış ekranından seçin.',
  YON_BELIRSIZ:
    'Bu plaka, içerideki bir aracın plakasına bir karakter uzak. O araç çıkıyorsa Çıkış ekranından tahsil edin; yeni gelen başka bir araçsa girişini elle açın.',
  // Entrance lane. The single gate gets its own text below: there the car may
  // have been LEAVING, and opening an entry for it would leave a phantom
  // ticket that blocks that plate's next real entry.
  OKUNAMADI:
    'Kamera bir araç gördü ama plakasını okuyamadı; bilet açılmadı. Araç içerideyse ve bileti yoksa girişini elle açın. Zaten bileti varsa kaydı çözüldü olarak işaretleyin.',
  // 056: the bridge saw the direction, and it contradicts the ticket state.
  GIRISTE_ACIK_BILET:
    'Kamera bu aracı tek kapıdan GİRERKEN gördü ama plakasının eski bir açık bileti var; araç önceki çıkışında görülmemiş olabilir. Eski bileti kontrol edin: araç çıkıp yeniden girdiyse eski bileti Çıkış ekranından kapatın ve yeni girişi elle açın; araç hiç çıkmadıysa kaydı çözüldü olarak işaretleyin.',
  ICERIDE_BILETSIZ:
    'Otoparkın içinde hareket eden bu aracın plakası okundu ama açık bileti yok. Kamera bu aracın biletini yakın zamanda çıkış diye kapattıysa (Çıktı listesinde, ödeme bekliyor) yeni giriş açmayın; o bilette "Araç çıkmadı"yı kullanın. Öyle değilse ve araç içerideyse girişini açın — giriş saati aracın içeride görüldüğü an olur; bileti varsa ya da araç çıktıysa kaydı çözüldü olarak işaretleyin.',
  // 071: before, the bridge dropped this car with only a line in its log.
  REDDEDILDI:
    'Kamera bu aracı gördü ama sunucu kaydı kabul etmedi; bilet açılmadı ya da kapanmadı. Araç içerideyse ve bileti yoksa girişini elle açın (Gişe, Giriş); çıkan bir araçsa Çıkış ekranından işlem yapın. Aynı sebep tekrar ediyorsa Yöneticiye haber verin.',
  // 072 (owner 2026-11-18): the camera closed this ticket as an exit, then saw
  // the same plate inside within minutes. The card leads to that ticket.
  CIKMAMIS_OLABILIR:
    'Kamera bu aracın biletini çıkış diye kapattı, ama birkaç dakika sonra araç otoparkın içinde görüldü. Araç gerçekten çıkmadıysa bilete gidip "Araç çıkmadı"yı kullanın. Araç çıktıysa kaydı çözüldü olarak işaretleyin.',
}

// The last sentence matches the entrance text's "Zaten bileti varsa…": a later
// photo of the same car is a new event, opens its ticket and leaves this row
// open.
const OKUNAMADI_TEK_KAPI =
  'Tek kapıda bir araç görüldü ama plakası okunamadı; girdiği mi çıktığı mı bilinmiyor. İçeride bileti olmayan bir araç varsa girişini elle açın; çıkan bir araçsa kaydı çözüldü olarak işaretleyin. Kamera plakayı başka bir karede okumuş olabilir: aracın zaten bileti varsa kaydı çözüldü olarak işaretleyin.'

export function aciklama(i: Istisna): string {
  if (i.tur === 'OKUNAMADI' && i.yon === 'ORTAK') return OKUNAMADI_TEK_KAPI
  // 071: the status line cuts the server's sentence to one line; here it is whole.
  const ret = i.tur === 'REDDEDILDI' && i.ham_yanit ? i.ham_yanit.ret_sebebi : null
  if (typeof ret === 'string' && ret.trim()) {
    return TUR_ACIKLAMA.REDDEDILDI + ' Sunucunun cevabı: ' + ret.trim()
  }
  return TUR_ACIKLAMA[i.tur]
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
  GELECEK: 'Kamera saati ileri — kabul edilmedi',
  BAYAT: 'Olay çok geç ulaştı',
  ACIK_BILET_YOK: 'Çıkışta açık bilet bulunamadı',
  COKLU_ESLESME: 'İçeride benzer plakalı bilet var',
  YON_BELIRSIZ: 'İçerideki bir plakaya çok benziyor',
  OKUNAMADI: 'Plaka tam olarak okunamadı',
  GIRISTE_ACIK_BILET: 'Girerken görüldü — eski açık bileti var',
  ICERIDE_BILETSIZ: 'İçeride, bileti yok',
  REDDEDILDI: 'Sunucu kaydı reddetti',
  CIKMAMIS_OLABILIR: 'Çıktı sayıldı ama içeride görüldü',
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
    return 'Plaka okuma servisi çalışmıyordu'
  }
  const ret = retSebebi(i)
  if (ret) return 'Sunucu reddetti: ' + ret
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
