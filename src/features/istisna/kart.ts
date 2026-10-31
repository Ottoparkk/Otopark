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
    'Aramaya birden fazla açık bilet uydu. Doğru aracı Çıkış ekranından seçin.',
  YON_BELIRSIZ:
    'Bu plaka, içerideki bir aracın plakasına bir karakter uzak. O araç çıkıyorsa Çıkış ekranından tahsil edin; yeni gelen başka bir araçsa girişini elle açın.',
  // Entrance lane. The single gate gets its own text below: there the car may
  // have been LEAVING, and opening an entry for it would leave a phantom
  // ticket that blocks that plate's next real entry.
  OKUNAMADI:
    'Kamera bir araç gördü ama plakasını okuyamadı; bilet açılmadı. Araç içerideyse ve bileti yoksa girişini elle açın. Zaten bileti varsa kaydı çözüldü olarak işaretleyin.',
}

// The last sentence matches the entrance text's "Zaten bileti varsa…": a later
// photo of the same car is a new event, opens its ticket and leaves this row
// open (see KENDILIGINDEN_COZULMEZ below).
const OKUNAMADI_TEK_KAPI =
  'Tek kapıda bir araç görüldü ama plakası okunamadı; girdiği mi çıktığı mı bilinmiyor. İçeride bileti olmayan bir araç varsa girişini elle açın; çıkan bir araçsa kaydı çözüldü olarak işaretleyin. Kamera plakayı başka bir karede okumuş olabilir: aracın zaten bileti varsa kaydı çözüldü olarak işaretleyin.'

export function aciklama(i: Istisna): string {
  return i.tur === 'OKUNAMADI' && i.yon === 'ORTAK' ? OKUNAMADI_TEK_KAPI : TUR_ACIKLAMA[i.tur]
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
  COKLU_ESLESME: 'Birden fazla açık bilet uydu',
  YON_BELIRSIZ: 'İçerideki bir plakaya çok benziyor',
  OKUNAMADI: 'Plaka tam olarak okunamadı',
}

/** The card's single status line. */
export function kisaDurum(i: Istisna): string {
  if (i.tur === 'OKUNAMADI' && okumaBilgisi(i).servisHatasi) {
    return 'Plaka okuma servisi çalışmıyordu'
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

/**
 * Buttons on an open row. "Giriş aç" only for an unreadable plate — the only
 * kind istisna_bilet_ac accepts (044). "Çıkış" keeps the old rule exactly: an
 * exit-lane event, a doubtful single-gate read, or an unreadable plate on the
 * single gate (that car may have been leaving). A resolved row has none.
 */
export function eylemler(i: Istisna): { girisAc: boolean; cikis: boolean; kapat: boolean } {
  if (i.cozuldu_at !== null) return { girisAc: false, cikis: false, kapat: false }
  return {
    girisAc: i.tur === 'OKUNAMADI',
    cikis:
      (i.tur !== 'GELECEK' && i.yon === 'CIKIS') ||
      i.tur === 'YON_BELIRSIZ' ||
      (i.tur === 'OKUNAMADI' && i.yon === 'ORTAK'),
    kapat: true,
  }
}

/**
 * Exceptions a person has to act on. The camera deliberately declined to act,
 * so the "do not enter it by hand" note would be exactly the wrong advice for
 * these. An unreadable plate is one: the bridge does not retry a 422 it
 * receives, and a failed read is only recorded on its last attempt. The car
 * CAN be read later, but rarely and not in a way worth waiting for:
 *   - if the 422 reply is lost, the bridge retries the same event within
 *     about two minutes; on the single gate 041 then closes this row (or adds
 *     the plate), on the entrance lane the retry opens the ticket and this
 *     row stays open;
 *   - a later photo of the same car is a new event: it opens the ticket and
 *     leaves this row open.
 */
const KENDILIGINDEN_COZULMEZ: ReadonlySet<IstisnaTur> = new Set(['YON_BELIRSIZ', 'OKUNAMADI'])

/** The one-line "camera may still fix this — don't enter it by hand" warning. */
export function elleGirmeUyarisi(i: Istisna): boolean {
  return i.kaynak === 'KAMERA' && i.cozuldu_at === null && !KENDILIGINDEN_COZULMEZ.has(i.tur)
}
