// P2 terminal, whole app (owner 28.11): every call the Gişe, ticket,
// Çözülmemiş kayıtlar and Abonman screens make — same RPCs and arguments as
// the main app (src/features/gise/api.ts, istisna/api.ts, abonman/api.ts).
//
//   node tests/terminalIslem.check.mjs
import * as G from '../terminal/src/giseIslem.ts'
import * as I from '../terminal/src/istisnaIslem.ts'
import * as A from '../terminal/src/abonmanIslem.ts'
import { cikisFisiBas } from '../terminal/src/fisIslem.ts'
import { girisFisi, cikisFisi, sureMetni } from '../src/features/fis/fisIcerik.ts'
import { fisTahminSecenekleri, parcala } from '../src/features/fis/fisSecenek.ts'
import { kademeAraliklari } from '../src/features/finans/kademe.ts'
import { formatTL } from '../src/lib/money.ts'
import { formatSaat, formatTam } from '../src/lib/dates.ts'
import { ucretsizEtiket } from '../src/lib/ucretsiz.ts'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../src/lib/plaka.ts'

let gecen = 0
let kalan = 0
function esit(ad, gercek, beklenen) {
  const a = JSON.stringify(gercek)
  const b = JSON.stringify(beklenen)
  if (a === b) gecen += 1
  else {
    kalan += 1
    console.error(`FAIL ${ad}\n  beklenen: ${b}\n  gelen:    ${a}`)
  }
}
async function hata(p) {
  try {
    await p
    return null
  } catch (e) {
    return e.message
  }
}
function sahte(cevaplar = {}) {
  const kayit = []
  const yanit = (ad, arg) => {
    kayit.push([ad, arg])
    const c = cevaplar[ad]
    if (c instanceof Error) return Promise.reject(c)
    return Promise.resolve(typeof c === 'function' ? c(arg) : c)
  }
  return {
    kayit,
    rpc: (ad, args) => yanit(`rpc:${ad}`, args),
    sec: (tablo, sorgu) => yanit(`sec:${tablo}`, sorgu),
  }
}
const ID = '1a2b3c4d-0000-4000-8000-000000000001'
const PLAKA = { normalizePlaka, plakaGecerli }

// --- Gişe ---------------------------------------------------------------------------
{
  const s = sahte({ 'rpc:gunluk_ozet': [{ toplam_kurus: 5000, arac_sayisi: 3, doluluk: 2, kapasite: 40 }] })
  esit('günlük özet', await G.gunlukOzet(s), { toplam_kurus: 5000, arac_sayisi: 3, doluluk: 2, kapasite: 40 })
  esit('günlük özet çağrısı', s.kayit[0], ['rpc:gunluk_ozet', {}])
  esit('özet boş → null', await G.gunlukOzet(sahte({ 'rpc:gunluk_ozet': [] })), null)
}
{
  const s = sahte({ 'rpc:acik_bilet_ara': null })
  esit('içeride boş', await G.acikBiletler(s, '34'), [])
  esit('içeride arama', s.kayit[0], ['rpc:acik_bilet_ara', { p_q: '34' }])
}
{
  const s = sahte({ 'sec:biletler': [] })
  await G.cikanlar(s, '2026-11-27T21:00:00.000Z')
  esit(
    'çıkanlar sorgusu',
    s.kayit[0][1],
    'select=id,plaka,giris_at,cikis_at,ucret_kurus,indirim_kurus,tahsil_kurus,abonman_id,yikama_kurus,ucretsiz_sebep,cikis_kaynak,durum' +
      '&durum=eq.KAPALI&cikis_at=gte.2026-11-27T21%3A00%3A00.000Z&order=cikis_at.desc,id.desc&limit=30',
  )
}
{
  const s = sahte({ 'sec:biletler': [{ id: ID }] })
  esit('bilet', await G.biletAl(s, ID), { id: ID })
  esit('bilet sorgusu', s.kayit[0][1], `select=*&id=eq.${ID}`)
  esit('bilet yok', await hata(G.biletAl(sahte({ 'sec:biletler': [] }), ID)), 'Bilet bulunamadı.')
}
{
  const s = sahte({ 'rpc:bilet_ucret_onizle': null })
  esit('ücret null → 0', await G.ucretOnizle(s, ID), 0)
  esit('ücret çağrısı', s.kayit[0], ['rpc:bilet_ucret_onizle', { p_bilet_id: ID }])
}
{
  const s = sahte({ 'rpc:vardiya_ozetim': [{ vardiya_id: 'v1' }] })
  esit('vardiyam', await G.vardiyamId(s), 'v1')
  esit('vardiya yok', await G.vardiyamId(sahte({ 'rpc:vardiya_ozetim': [] })), null)
}
{
  const s = sahte({ 'sec:tarifeler': [{ yikama_kurus: 15000 }] })
  esit('yıkama ücreti', await G.yikamaUcreti(s), 15000)
  esit('yıkama sorgusu', s.kayit[0][1], 'select=yikama_kurus&gecerli_bitis=is.null&limit=1')
  esit('yıkama yok', await G.yikamaUcreti(sahte({ 'sec:tarifeler': [] })), null)
}
{
  const s = sahte({ 'rpc:bilet_kapat': [{ ucret_kurus: 15000, indirim_kurus: 0, tahsil_kurus: 15000 }] })
  esit('kapat sonucu', await G.biletKapat(s, ID, 'NAKIT'), { ucret_kurus: 15000, indirim_kurus: 0, tahsil_kurus: 15000 })
  esit('kapat gövdesi', s.kayit[0][1], {
    p_bilet_id: ID,
    p_odeme_yontemi: 'NAKIT',
    p_ucret_override_kurus: null,
    p_sebep: null,
    p_foto: null,
    p_kaynak: 'MOBIL',
    p_tahsil: true,
  })
  esit('kapat sonuçsuz', await hata(G.biletKapat(sahte({ 'rpc:bilet_kapat': [] }), ID, null)), 'Tahsilat sonucu alınamadı.')
}
{
  const s = sahte({})
  await G.biletTahsil(s, ID, 'KREDI_KARTI')
  await G.ucretsizCikis(s, ID, 'POLIS', '  ekip aracı ')
  await G.kameraGeriAc(s, ID)
  await G.cikisGeriAl(s, ID, ' araç içeride ')
  await G.iptalIste(s, ID, ' yanlış plaka ')
  await G.yikama(s, ID, true)
  await G.anlasma(s, ID, 20000, 24)
  await G.asimKarar(s, ID, false)
  esit('tek çağrılar', s.kayit, [
    ['rpc:bilet_tahsil', { p_bilet_id: ID, p_odeme_yontemi: 'KREDI_KARTI' }],
    ['rpc:bilet_ucretsiz_cikis', { p_bilet_id: ID, p_sebep: 'POLIS', p_not: 'ekip aracı' }],
    ['rpc:bilet_kamera_geri_ac', { p_bilet_id: ID }],
    ['rpc:bilet_cikis_geri_al', { p_bilet_id: ID, p_sebep: 'araç içeride' }],
    ['rpc:bilet_iptal', { p_bilet_id: ID, p_sebep: 'yanlış plaka' }],
    ['rpc:bilet_yikama', { p_bilet_id: ID, p_acik: true }],
    ['rpc:bilet_anlasma', { p_bilet_id: ID, p_kurus: 20000, p_saat: 24 }],
    ['rpc:bilet_asim_karar', { p_bilet_id: ID, p_tam: false }],
  ])
}
{
  const s = sahte({})
  esit('geri al sebepsiz', await hata(G.cikisGeriAl(s, ID, '  ')), 'Sebep yazın.')
  esit('iptal sebepsiz', await hata(G.iptalIste(s, ID, '')), 'İptal sebebi zorunludur.')
  esit('sebepsiz çağrı yok', s.kayit.length, 0)
}
{
  const s = sahte({ 'rpc:bilet_asim_onizle': [{ ilk_kurus: 100, tam_kurus: 300 }] })
  esit('aşım önizle', await G.asimOnizle(s, ID), { ilk_kurus: 100, tam_kurus: 300 })
  esit('aşım yok', await G.asimOnizle(sahte({ 'rpc:bilet_asim_onizle': [] }), ID), null)
}
{
  const s = sahte({})
  esit('plaka düzelt geçersiz', await hata(G.plakaDuzelt(s, ID, '3', PLAKA)), 'Plakayı kontrol edin.')
  await G.plakaDuzelt(s, ID, '34 abc 123', PLAKA)
  esit('plaka düzelt', s.kayit, [['rpc:bilet_plaka_duzelt', { p_bilet_id: ID, p_plaka: '34ABC123' }]])
}
{
  const s = sahte({ 'rpc:kayip_bilet_tahsil': 'b2' })
  esit('kayıp geçersiz plaka', await hata(G.kayipBilet(s, '', 'NAKIT', 'i1', PLAKA)), 'Plakayı kontrol edin.')
  esit('kayıp bilet', await G.kayipBilet(s, '06 xy 99', 'NAKIT', 'i1', PLAKA), 'b2')
  esit('kayıp gövdesi', s.kayit[0], ['rpc:kayip_bilet_tahsil', { p_plaka: '06XY99', p_odeme_yontemi: 'NAKIT', p_islem_id: 'i1' }])
}
{
  const s = sahte({ 'sec:istisnalar': [{ id: 'a' }, { id: 'b' }] })
  esit('açık istisna sayısı', await G.acikIstisnaSayisi(s), 2)
  esit('istisna sayım sorgusu', s.kayit[0][1], 'select=id&cozuldu_at=is.null&limit=200')
}

// --- Çözülmemiş kayıtlar ---------------------------------------------------------------
{
  const s = sahte({ 'sec:istisnalar': [], 'rpc:istisna_bilet_ac': { bilet_id: 'b1' }, 'rpc:istisna_bilet_ac_saatli': { bilet_id: 'b3' } })
  await I.bekleyenIstisnalar(s)
  esit('bekleyen sorgusu', s.kayit[0][1], 'select=*&cozuldu_at=is.null&order=created_at.desc&limit=200')
  await I.istisnaKapat(s, 'i1', '  ')
  await I.istisnaKapat(s, 'i2', ' çift kayıt ')
  esit('kapat notsuz', s.kayit[1], ['rpc:istisna_coz', { p_id: 'i1', p_not: null }])
  esit('kapat notlu', s.kayit[2], ['rpc:istisna_coz', { p_id: 'i2', p_not: 'çift kayıt' }])
  esit('giriş aç', await I.istisnaBiletAc(s, 'i3', '34 abc 1', PLAKA), { bilet_id: 'b1' })
  esit('giriş aç gövdesi', s.kayit[3], ['rpc:istisna_bilet_ac', { p_id: 'i3', p_plaka: '34ABC1' }])
  esit('giriş aç geçersiz', await hata(I.istisnaBiletAc(s, 'i3', 'x', PLAKA)), 'Plakayı kontrol edin.')
  await I.istisnaBiletAcSaatli(s, 'i4', '34abc1', '2026-11-28T08:00:00.000Z', ' çıkmıyordu ', PLAKA)
  esit('saatli gövdesi', s.kayit[4], ['rpc:istisna_bilet_ac_saatli', { p_id: 'i4', p_plaka: '34ABC1', p_giris_at: '2026-11-28T08:00:00.000Z', p_sebep: 'çıkmıyordu' }])
  esit('saatli sebepsiz', await hata(I.istisnaBiletAcSaatli(s, 'i4', '34abc1', '2026-11-28T08:00:00.000Z', ' ', PLAKA)), 'Sebep yazın.')
}

// --- Abonman ---------------------------------------------------------------------------
{
  const s = sahte({ 'sec:abonmanlar': [{ id: 'a1' }], 'sec:tahsilatlar': [] })
  await A.abonmanlar(s)
  esit('abonman listesi', s.kayit[0], ['sec:abonmanlar', 'select=*&order=bitis.asc'])
  esit('abonman', await A.abonmanAl(s, 'a1'), { id: 'a1' })
  esit('abonman sorgusu', s.kayit[1][1], 'select=*&id=eq.a1')
  esit('abonman yok', await hata(A.abonmanAl(sahte({ 'sec:abonmanlar': [] }), 'a1')), 'Abonman bulunamadı.')
  await A.abonmanTahsilatlari(s, 'a1')
  esit('abonman tahsilatları', s.kayit[2][1], 'select=*&abonman_id=eq.a1&order=created_at.desc')
}
{
  const s = sahte({})
  esit('tutar 0', await hata(A.abonmanTahsil(s, { id: 'a1', yontem: 'NAKIT', tutar: 0, yenile: true })), 'Tutar girin.')
  await A.abonmanTahsil(s, { id: 'a1', yontem: 'HAVALE', tutar: 150000, yenile: false })
  esit('abonman tahsil', s.kayit, [['rpc:abonman_tahsil', { p_abonman_id: 'a1', p_yontem: 'HAVALE', p_tutar_kurus: 150000, p_yenile: false }]])
}

// --- Çıkış fişi: number first, then lines ---------------------------------------------------
{
  const Y = {
    fis: { tl: formatTL, saat: formatSaat, tam: formatTam, ucretsizEtiket, plaka: formatPlaka },
    girisFisi,
    cikisFisi,
    sureMetni,
    fisTahminSecenekleri,
    parcala,
    kademeAraliklari,
  }
  const BILET = {
    id: ID, plaka: '34ABC123', giris_at: '2026-11-28T08:00:00.000Z', cikis_at: '2026-11-28T10:00:00.000Z',
    ucret_kurus: 15000, indirim_kurus: 0, puan_kullanilan: 0, tahsil_kurus: 15000, odeme_yontemi: 'NAKIT',
    abonman_id: null, yikama_kurus: null, anlasma_kurus: null, anlasma_bitis: null, ucretsiz_sebep: null,
  }
  const OTOPARK = { ad: 'Merkez Otopark' }
  const simdi = () => '2026-11-28T10:01:00.000Z'
  const s = sahte({ 'rpc:fis_basildi': 1 })
  const satirlar = await cikisFisiBas(s, { bilet: BILET, otopark: OTOPARK }, simdi, Y)
  esit('çıkış önce numara', s.kayit[0], ['rpc:fis_basildi', { p_bilet_id: ID, p_tur: 'CIKIS', p_tahmin_dk: null }])
  esit('çıkış satırları', satirlar, cikisFisi({ otopark: OTOPARK, bilet: BILET, basim: 1, basimAt: simdi() }, Y.fis))
  const r = sahte({ 'rpc:fis_basildi': new Error('Önce ödeme toplayın.') })
  esit('çıkış numarası alınamazsa basılmaz', await hata(cikisFisiBas(r, { bilet: BILET, otopark: OTOPARK }, simdi, Y)), 'Önce ödeme toplayın.')
}

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
