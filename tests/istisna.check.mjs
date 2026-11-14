// Çözülmemiş kayıtlar — kart kuralları (kısa durum satırı, başlangıç plakası,
// hangi düğmeler, "elle girmeyin" uyarısı).
//
//   node tests/istisna.check.mjs
//
// Gerçek dosyayı içe aktarır; dosya yalnızca `import type` kullanır ki Node
// onu doğrudan çalıştırabilsin.
import {
  okumaBilgisi,
  kisaDurum,
  baslangicPlakasi,
  eylemler,
  elleGirmeUyarisi,
  aciklama,
} from '../src/features/istisna/kart.ts'

let gecen = 0
let kalan = 0

function esit(ad, gercek, beklenen) {
  const a = JSON.stringify(gercek)
  const b = JSON.stringify(beklenen)
  if (a === b) {
    gecen += 1
  } else {
    kalan += 1
    console.error(`FAIL ${ad}\n  beklenen: ${b}\n  gelen:    ${a}`)
  }
}

/** A row as the API returns it; only what each case changes is passed. */
function kayit(o = {}) {
  return {
    id: 'x',
    tur: 'OKUNAMADI',
    yon: 'GIRIS',
    plaka: null,
    kaynak: 'KAMERA',
    islem_id: 'i',
    ham_yanit: null,
    foto_path: null,
    kaynak_zaman: null,
    alindi_zaman: '2026-10-31T10:00:00Z',
    aday_bilet_ids: null,
    cozuldu_by: null,
    cozuldu_at: null,
    cozum_notu: null,
    created_at: '2026-10-31T10:00:00Z',
    ...o,
  }
}
const COZULDU = { cozuldu_at: '2026-10-31T11:00:00Z' }
const TURLER = ['GELECEK', 'BAYAT', 'ACIK_BILET_YOK', 'COKLU_ESLESME', 'YON_BELIRSIZ', 'OKUNAMADI']
const YONLER = ['GIRIS', 'CIKIS', 'ORTAK']

// --- okumaBilgisi: modelin tahmini yalnızca OKUNAMADI satırından okunur ----------
esit('tahmin + güven', okumaBilgisi(kayit({ ham_yanit: { tahmin: '34ABC12', guven: 0.4 } })),
  { tahmin: '34ABC12', guven: 0.4, servisHatasi: false })
esit('servis hatası', okumaBilgisi(kayit({ ham_yanit: { hata: 'Anthropic 529' } })),
  { tahmin: null, guven: null, servisHatasi: true })
esit('boş tahmin yok sayılır', okumaBilgisi(kayit({ ham_yanit: { tahmin: '' } })).tahmin, null)
esit('metin olmayan tahmin yok sayılır', okumaBilgisi(kayit({ ham_yanit: { tahmin: 42 } })).tahmin, null)
esit('ham_yanit null', okumaBilgisi(kayit()), { tahmin: null, guven: null, servisHatasi: false })
esit('başka türde tahmin okunmaz',
  okumaBilgisi(kayit({ tur: 'ACIK_BILET_YOK', yon: 'CIKIS', ham_yanit: { tahmin: '34ABC12' } })).tahmin, null)

// --- kisaDurum: her tür için TEK kısa satır --------------------------------------
esit('okunamadı', kisaDurum(kayit()), 'Plaka tam olarak okunamadı')
esit('okunamadı, servis yok', kisaDurum(kayit({ ham_yanit: { hata: 'x' } })), 'Plaka okuma servisi çalışmıyordu')
esit('açık bilet yok', kisaDurum(kayit({ tur: 'ACIK_BILET_YOK', yon: 'CIKIS' })), 'Çıkışta açık bilet bulunamadı')
// 054: son dört karakter tek araca da uysa kamera kapatmaz; kart bunu söyler.
esit('çoklu eşleşme', kisaDurum(kayit({ tur: 'COKLU_ESLESME', yon: 'CIKIS' })), 'İçeride benzer plakalı bilet var')
esit('yön belirsiz', kisaDurum(kayit({ tur: 'YON_BELIRSIZ', yon: 'ORTAK' })), 'İçerideki bir plakaya çok benziyor')
esit('gelecek', kisaDurum(kayit({ tur: 'GELECEK' })), 'Kamera saati ileri — kabul edilmedi')
esit('bayat', kisaDurum(kayit({ tur: 'BAYAT' })), 'Olay çok geç ulaştı')
for (const tur of TURLER) {
  for (const yon of YONLER) {
    const s = kisaDurum(kayit({ tur, yon }))
    esit(`kısa ve tek satır ${tur}/${yon}`, typeof s === 'string' && s.length > 0 && s.length <= 40 && !s.includes('\n'), true)
  }
}

// --- baslangicPlakasi: önce kayıttaki plaka, yoksa modelin tahmini, yoksa boş --
esit('plaka varsa o', baslangicPlakasi(kayit({ plaka: '34ABC123', ham_yanit: { tahmin: '34ABC128' } })), '34ABC123')
esit('plaka yoksa tahmin', baslangicPlakasi(kayit({ ham_yanit: { tahmin: '34 abc 128' } })), '34 abc 128')
esit('ikisi de yoksa boş', baslangicPlakasi(kayit()), '')
esit('servis hatasında boş', baslangicPlakasi(kayit({ ham_yanit: { hata: 'x' } })), '')
esit('başka türde plaka', baslangicPlakasi(kayit({ tur: 'ACIK_BILET_YOK', yon: 'CIKIS', plaka: '06XY77' })), '06XY77')

// --- eylemler -------------------------------------------------------------------
// Giriş aç: yalnızca açık OKUNAMADI (sunucu da yalnızca onu kabul eder, 044).
esit('okunamadı giriş', eylemler(kayit()), { girisAc: true, cikis: false, kapat: true })
esit('okunamadı tek kapı', eylemler(kayit({ yon: 'ORTAK' })), { girisAc: true, cikis: true, kapat: true })
esit('çözülmüş: hiçbir düğme', eylemler(kayit(COZULDU)), { girisAc: false, cikis: false, kapat: false })
esit('çözülmüş tek kapı: hiçbir düğme', eylemler(kayit({ yon: 'ORTAK', ...COZULDU })),
  { girisAc: false, cikis: false, kapat: false })
// Çıkış: bugünkü kuralın birebir aynısı (Istisnalar.tsx eski 313–315).
for (const tur of TURLER) {
  for (const yon of YONLER) {
    const eski = (tur !== 'GELECEK' && yon === 'CIKIS') || tur === 'YON_BELIRSIZ' || (tur === 'OKUNAMADI' && yon === 'ORTAK')
    const e = eylemler(kayit({ tur, yon }))
    esit(`çıkış kuralı ${tur}/${yon}`, e.cikis, eski)
    esit(`giriş yalnız OKUNAMADI ${tur}/${yon}`, e.girisAc, tur === 'OKUNAMADI')
    esit(`kapat her açık kayıtta ${tur}/${yon}`, e.kapat, true)
  }
}

// --- elleGirmeUyarisi: bugünkü kural (kamera + açık + kendiliğinden çözülebilir) -
esit('kamera bayat → uyarı', elleGirmeUyarisi(kayit({ tur: 'BAYAT' })), true)
esit('kamera açık bilet yok → uyarı', elleGirmeUyarisi(kayit({ tur: 'ACIK_BILET_YOK', yon: 'CIKIS' })), true)
esit('okunamadı → uyarı yok', elleGirmeUyarisi(kayit()), false)
esit('yön belirsiz → uyarı yok', elleGirmeUyarisi(kayit({ tur: 'YON_BELIRSIZ', yon: 'ORTAK' })), false)
esit('mobil kaynak → uyarı yok', elleGirmeUyarisi(kayit({ tur: 'BAYAT', kaynak: 'MOBIL' })), false)
esit('çözülmüş → uyarı yok', elleGirmeUyarisi(kayit({ tur: 'BAYAT', ...COZULDU })), false)

// --- aciklama: uzun metin "Ayrıntı"nın arkasında, metinler değişmedi ------------
esit('tek kapı okunamadı kendi metni', aciklama(kayit({ yon: 'ORTAK' })).startsWith('Tek kapıda bir araç görüldü'), true)
esit('giriş okunamadı metni', aciklama(kayit()).startsWith('Kamera bir araç gördü ama plakasını okuyamadı'), true)
for (const tur of TURLER) {
  esit(`açıklama var ${tur}`, aciklama(kayit({ tur, yon: tur === 'OKUNAMADI' ? 'GIRIS' : 'CIKIS' })).length > 20, true)
}

// --- 056: tek kapıda köprünün yön ipucu iki yeni kayıt türü doğurur ---------------
// GIRISTE_ACIK_BILET: araç GİRERKEN görüldü ama eski açık bileti var — eski
// bilet Çıkış ekranından kapatılabilir, giriş açılmaz (plaka zaten içeride).
// ICERIDE_BILETSIZ: içeride gezen aracın bileti yok — "Giriş aç" (056 kabul eder).
// İkisinde de bir insan karar vermeli: "elle girmeyin" uyarısı çıkmaz.
const GIRISTE = kayit({ tur: 'GIRISTE_ACIK_BILET', yon: 'ORTAK', plaka: '34ABC123' })
const ICERIDE = kayit({ tur: 'ICERIDE_BILETSIZ', yon: 'ORTAK', plaka: '34ABC123' })
esit('girişte eski bilet: düğmeler', eylemler(GIRISTE), { girisAc: false, cikis: true, kapat: true })
esit('içeride biletsiz: düğmeler', eylemler(ICERIDE), { girisAc: true, cikis: false, kapat: true })
esit('girişte eski bilet: uyarı yok', elleGirmeUyarisi(GIRISTE), false)
esit('içeride biletsiz: uyarı yok', elleGirmeUyarisi(ICERIDE), false)
esit('girişte eski bilet: kısa durum', kisaDurum(GIRISTE), 'Girerken görüldü — eski açık bileti var')
esit('içeride biletsiz: kısa durum', kisaDurum(ICERIDE), 'İçeride, bileti yok')
esit('girişte eski bilet: açıklama', aciklama(GIRISTE).startsWith('Kamera bu aracı tek kapıdan GİRERKEN gördü'), true)
esit('içeride biletsiz: açıklama', aciklama(ICERIDE).startsWith('Otoparkın içinde hareket eden bu aracın'), true)
esit('içeride biletsiz: giriş saati açıklanır', aciklama(ICERIDE).includes('içeride görüldüğü an'), true)
// Kamera aracı yanlışlıkla "çıktı" diye kapattıysa (054) doğru eylem eski
// bilette "Araç çıkmadı"dır, yeni giriş değil — metin bunu söylemeli.
esit('içeride biletsiz: yanlış çıkışta "Araç çıkmadı" söylenir', aciklama(ICERIDE).includes('Araç çıkmadı'), true)
esit('içeride biletsiz: plaka alanı okunan plakayla başlar', baslangicPlakasi(ICERIDE), '34ABC123')
esit('çözülmüş içeride biletsiz: düğme yok', eylemler(kayit({ tur: 'ICERIDE_BILETSIZ', yon: 'ORTAK', ...COZULDU })),
  { girisAc: false, cikis: false, kapat: false })
// Tek kapıda "çıkan araç, bileti yok" mevcut ACIK_BILET_YOK türüdür: kapatılacak
// bilet yok — yalnızca "kapat"; davranışı değişmez.
esit('tek kapı açık bilet yok: düğmeler', eylemler(kayit({ tur: 'ACIK_BILET_YOK', yon: 'ORTAK', plaka: '34ABC123' })),
  { girisAc: false, cikis: false, kapat: true })

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
