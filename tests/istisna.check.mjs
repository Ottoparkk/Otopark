// Çözülmemiş kayıtlar — kart kuralları (kısa durum satırı, başlangıç plakası,
// hangi düğmeler).
//
//   node tests/istisna.check.mjs
//
// Gerçek dosyayı içe aktarır; dosya yalnızca `import type` kullanır ki Node
// onu doğrudan çalıştırabilsin.
import * as kart from '../src/features/istisna/kart.ts'
import {
  okumaBilgisi,
  kisaDurum,
  baslangicPlakasi,
  eylemler,
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
esit('okunamadı giriş', eylemler(kayit()), { girisAc: true, cikis: false, kapat: true, girisAcSaatli: false, bileteGit: null })
esit('okunamadı tek kapı', eylemler(kayit({ yon: 'ORTAK' })), { girisAc: true, cikis: true, kapat: true, girisAcSaatli: false, bileteGit: null })
esit('çözülmüş: hiçbir düğme', eylemler(kayit(COZULDU)), { girisAc: false, cikis: false, kapat: false, girisAcSaatli: false, bileteGit: null })
esit('çözülmüş tek kapı: hiçbir düğme', eylemler(kayit({ yon: 'ORTAK', ...COZULDU })),
  { girisAc: false, cikis: false, kapat: false, girisAcSaatli: false, bileteGit: null })
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

// --- "elle girmeyin" uyarısı kaldırıldı (sahip 2026-11-18) ----------------------
// 1.4.3'ten beri hiçbir kart türü kendiliğinden çözülmüyordu, uyarı hiç
// görünemiyordu; ölü kod silindi.
esit('elleGirmeUyarisi artık yok', 'elleGirmeUyarisi' in kart, false)

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
// İkisinde de bir insan karar vermeli.
const GIRISTE = kayit({ tur: 'GIRISTE_ACIK_BILET', yon: 'ORTAK', plaka: '34ABC123' })
const ICERIDE = kayit({ tur: 'ICERIDE_BILETSIZ', yon: 'ORTAK', plaka: '34ABC123' })
esit('girişte eski bilet: düğmeler', eylemler(GIRISTE), { girisAc: false, cikis: true, kapat: true, girisAcSaatli: false, bileteGit: null })
esit('içeride biletsiz: düğmeler', eylemler(ICERIDE), { girisAc: true, cikis: false, kapat: true, girisAcSaatli: false, bileteGit: null })
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
  { girisAc: false, cikis: false, kapat: false, girisAcSaatli: false, bileteGit: null })
// Tek kapıda "çıkan araç, bileti yok" (ACIK_BILET_YOK): araç aslında girmiş
// olabilir (sahip 2026-11-17/18). Kamera kartında "Giriş aç" — giriş saatini
// personel yazar (kart saati ücreti yanlış hesaplar), sebep zorunlu (072).
esit('tek kapı açık bilet yok: düğmeler', eylemler(kayit({ tur: 'ACIK_BILET_YOK', yon: 'ORTAK', plaka: '34ABC123' })),
  { girisAc: false, cikis: false, kapat: true, girisAcSaatli: true, bileteGit: null })
esit('çıkış şeridinde açık bilet yok: saatli giriş yok',
  eylemler(kayit({ tur: 'ACIK_BILET_YOK', yon: 'CIKIS', plaka: '34ABC123' })).girisAcSaatli, false)
esit('elle yazılmış (kamera değil) açık bilet yok: saatli giriş yok',
  eylemler(kayit({ tur: 'ACIK_BILET_YOK', yon: 'ORTAK', kaynak: 'MOBIL' })).girisAcSaatli, false)
esit('çözülmüş tek kapı açık bilet yok: düğme yok',
  eylemler(kayit({ tur: 'ACIK_BILET_YOK', yon: 'ORTAK', ...COZULDU })).girisAcSaatli, false)
for (const tur of TURLER) {
  if (tur === 'ACIK_BILET_YOK') continue
  esit(`saatli giriş yalnız ACIK_BILET_YOK ${tur}`, eylemler(kayit({ tur, yon: 'ORTAK' })).girisAcSaatli, false)
}

// 072 (sahip 2026-11-18): kameranın çıkış diye kapattığı bilet, birkaç dakika
// içinde aynı plaka içeride görülünce CIKMAMIS_OLABILIR kartı olur. Kart
// bilete götürür ("Araç çıkmadı" orada); giriş / çıkış düğmesi yok.
const CIKMAMIS = (o = {}) => kayit({ tur: 'CIKMAMIS_OLABILIR', yon: 'ORTAK', plaka: '34ABC123',
  aday_bilet_ids: ['b-1'], ...o })
esit('çıkmamış olabilir: düğmeler', eylemler(CIKMAMIS()),
  { girisAc: false, cikis: false, kapat: true, girisAcSaatli: false, bileteGit: 'b-1' })
esit('çıkmamış olabilir: bilet yoksa bilete git yok', eylemler(CIKMAMIS({ aday_bilet_ids: null })).bileteGit, null)
esit('çıkmamış olabilir: çözülmüş', eylemler(CIKMAMIS(COZULDU)),
  { girisAc: false, cikis: false, kapat: false, girisAcSaatli: false, bileteGit: null })
esit('başka türde aday bilet: bilete git yok',
  eylemler(kayit({ tur: 'YON_BELIRSIZ', yon: 'ORTAK', aday_bilet_ids: ['b-1'] })).bileteGit, null)
esit('çıkmamış olabilir: kısa durum', kisaDurum(CIKMAMIS()), 'Çıktı sayıldı ama içeride görüldü')
esit('çıkmamış olabilir: açıklama', aciklama(CIKMAMIS()).startsWith('Kamera bu aracın biletini çıkış diye kapattı'), true)
esit('çıkmamış olabilir: "Araç çıkmadı" söylenir', aciklama(CIKMAMIS()).includes('"Araç çıkmadı"'), true)
esit('çıkmamış olabilir: plaka alanı', baslangicPlakasi(CIKMAMIS()), '34ABC123')

// 071: sunucunun reddettiği kamera aracı (REDDEDILDI). Kısa durum ret
// cümlesini taşır; bir insan karar vermeli.
// Çıkış şeridinde ve tek kapıda araç çıkıyor olabilir: "Çıkış" düğmesi.
const RED = (o = {}) => kayit({ tur: 'REDDEDILDI', plaka: '34ABC123',
  ham_yanit: { ret_sebebi: 'Bu plakanın zaten açık bir bileti var.' }, ...o })
esit('reddedildi: kısa durum ret cümlesiyle', kisaDurum(RED()), 'Sunucu reddetti: Bu plakanın zaten açık bir bileti var.')
esit('reddedildi: cümle yoksa', kisaDurum(RED({ ham_yanit: null })), 'Sunucu kaydı reddetti')
esit('reddedildi: uzun cümle kısalır', kisaDurum(RED({ ham_yanit: { ret_sebebi: 'x'.repeat(200) } })).length <= 100, true)
esit('reddedildi giriş: düğmeler', eylemler(RED()), { girisAc: false, cikis: false, kapat: true, girisAcSaatli: false, bileteGit: null })
esit('reddedildi çıkış: düğmeler', eylemler(RED({ yon: 'CIKIS' })), { girisAc: false, cikis: true, kapat: true, girisAcSaatli: false, bileteGit: null })
esit('reddedildi tek kapı: düğmeler', eylemler(RED({ yon: 'ORTAK' })), { girisAc: false, cikis: true, kapat: true, girisAcSaatli: false, bileteGit: null })
esit('reddedildi: açıklama', aciklama(RED()).startsWith('Kamera bu aracı gördü ama sunucu kaydı kabul etmedi'), true)
esit('reddedildi: ayrıntıda tam ret cümlesi', aciklama(RED({ ham_yanit: { ret_sebebi: 'y'.repeat(150) } })).includes('y'.repeat(150)), true)
esit('reddedildi: cümle yoksa ayrıntı yine çalışır', aciklama(RED({ ham_yanit: null })).startsWith('Kamera bu aracı gördü'), true)
esit('reddedildi: plaka alanı okunan plakayla', baslangicPlakasi(RED()), '34ABC123')

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
