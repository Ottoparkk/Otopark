// P2 terminal (plan 2026-11-28, Task 5): photo size, photo path, plate
// reading and opening the ticket.
//
//   node tests/terminalGiris.check.mjs
import { hedefBoyut, OKUMA_KENAR, KANIT_KENAR } from '../src/lib/fotoBoyut.ts'
import { fotoYolu, yeniKimlik } from '../src/lib/fotoYolu.ts'
import { normalizePlaka, plakaGecerli } from '../src/lib/plaka.ts'
import { plakaOku, girisAc } from '../terminal/src/girisIslem.ts'

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

// --- photo size (same contract as the P2-proven kamera.mjs) ---------------------
esit('sınırlar', [OKUMA_KENAR, KANIT_KENAR], [1568, 1280])
esit('yatay küçülür', hedefBoyut(4000, 3000, 1568), { en: 1568, boy: 1176 })
esit('dikey küçülür', hedefBoyut(3000, 4000, 1568), { en: 1176, boy: 1568 })
esit('küçük büyütülmez', hedefBoyut(800, 600, 1568), { en: 800, boy: 600 })
esit('tam sınırda', hedefBoyut(1568, 1000, 1568), { en: 1568, boy: 1000 })

// --- ids and the photo path (no crypto.randomUUID: Chrome 92) ---------------------
const UUID4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
const k1 = yeniKimlik()
esit('v4 uuid', UUID4.test(k1), true)
esit('her seferinde farklı', yeniKimlik() !== k1, true)
esit('foto yolu', fotoYolu('giris', '34ABC123', 'abcdef12-0000-4000-8000-000000000000', new Date('2026-11-28T10:00:00Z')),
  '2026-11-28/giris-34ABC123-abcdef12.jpg')
esit('plakasız foto yolu', fotoYolu('cikis', '', 'abcdef12-0000-4000-8000-000000000000', new Date('2026-11-28T10:00:00Z')),
  '2026-11-28/cikis-bilinmiyor-abcdef12.jpg')
esit('varsayılan kimlik', /^\d{4}-\d{2}-\d{2}\/giris-34ABC123-[0-9a-f]{8}\.jpg$/.test(fotoYolu('giris', '34ABC123')), true)

// --- a fake Sunucu --------------------------------------------------------------------
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
    fn: (ad, govde) => yanit(`fn:${ad}`, govde),
    yukle: (kova, yol, veri, tur) => yanit('yukle', { kova, yol, veri, tur }),
  }
}
const adlar = (s) => s.kayit.map((k) => k[0])
const ARACLAR = {
  normalizePlaka,
  plakaGecerli,
  fotoYolu: (yon, plaka) => fotoYolu(yon, plaka, 'abcdef12-0000-4000-8000-000000000000', new Date('2026-11-28T10:00:00Z')),
}
const ISLEM = '11111111-2222-4333-8444-555555555555'
const g = (o = {}) => ({ plaka: '34 abc 123', islemId: ISLEM, kanit: null, okuma: null, aracBilgi: null, ...o })

// --- plakaOku -------------------------------------------------------------------------
{
  const s = sahte({ 'fn:plaka-oku': { plaka: '34ABC123', guven: 0.9, saglayici: 'x', log_id: 'l1', dusuk_guven: false } })
  esit('okuma', await plakaOku(s, 'QkFTRTY0'), { plaka: '34ABC123', log_id: 'l1' })
  esit('okuma gövdesi', s.kayit[0][1], { foto_base64: 'QkFTRTY0', media_type: 'image/jpeg' })
}
{
  const s = sahte({ 'fn:plaka-oku': { hata: 'Plaka okunamadı.' } })
  esit('okuma hatası', await hata(plakaOku(s, 'x')), 'Plaka okunamadı.')
}
{
  const s = sahte({ 'fn:plaka-oku': { plaka: null, guven: 0.2, saglayici: 'x', log_id: 'l2', dusuk_guven: true } })
  esit('zayıf okuma: alan boş', await plakaOku(s, 'x'), { plaka: null, log_id: 'l2' })
}

// --- girisAc ----------------------------------------------------------------------------
{
  const s = sahte()
  // The database's floor is 2–15 of [A-Z0-9] (plaka.ts); one character is refused.
  esit('geçersiz plaka', await hata(girisAc(s, g({ plaka: '3' }), ARACLAR)), 'Plakayı kontrol edin.')
  esit('geçersizde çağrı yok', s.kayit.length, 0)
}
{
  const s = sahte({ 'rpc:bilet_ac': 'b-1' })
  const r = await girisAc(s, g({ kanit: 'JPEG' }), ARACLAR)
  esit('fotoğraflı sıra', adlar(s), ['yukle', 'rpc:bilet_ac'])
  esit('yükleme', s.kayit[0][1], { kova: 'plaka-foto', yol: '2026-11-28/giris-34ABC123-abcdef12.jpg', veri: 'JPEG', tur: 'image/jpeg' })
  esit('bilet_ac parametreleri', s.kayit[1][1], {
    p_plaka: '34ABC123',
    p_islem_id: ISLEM,
    p_kaynak: 'MOBIL',
    p_zaman: null,
    p_foto: '2026-11-28/giris-34ABC123-abcdef12.jpg',
    p_park_yeri_id: null,
    p_ham_yanit: null,
    p_arac_bilgi: null,
    p_musteri_ad: null,
    p_musteri_tel: null,
    p_notlar: null,
  })
  esit('sonuç', r, { biletId: 'b-1', uyari: null })
}
{
  const s = sahte({ yukle: new Error('x'), 'rpc:bilet_ac': 'b-2' })
  const r = await girisAc(s, g({ kanit: 'JPEG', aracBilgi: '  Beyaz Doblo ' }), ARACLAR)
  esit('yükleme olmazsa fotoğrafsız', s.kayit[1][1].p_foto, null)
  esit('araç bilgisi kırpılır', s.kayit[1][1].p_arac_bilgi, 'Beyaz Doblo')
  esit('yükleme uyarısı', r, { biletId: 'b-2', uyari: 'Fotoğraf yüklenemedi, kayıt fotoğrafsız açıldı.' })
}
{
  const s = sahte({ 'rpc:bilet_ac': 'b-3', 'rpc:bilet_okuma_bagla': null })
  await girisAc(s, g({ okuma: { plaka: '34ABC128', log_id: 'l1' } }), ARACLAR)
  esit('okuma bağlanır', s.kayit[1], ['rpc:bilet_okuma_bagla', { p_bilet_id: 'b-3', p_okuma_id: 'l1', p_kabul: '34ABC123' }])
}
{
  const s = sahte({ 'rpc:bilet_ac': 'b-4', 'rpc:bilet_okuma_bagla': new Error('x') })
  esit('bağlama hatası girişi bozmaz', await girisAc(s, g({ okuma: { plaka: null, log_id: 'l1' } }), ARACLAR), { biletId: 'b-4', uyari: null })
}
{
  const s = sahte({ 'rpc:bilet_ac': 'b-5' })
  await girisAc(s, g({ okuma: { plaka: null, log_id: null } }), ARACLAR)
  esit('log yoksa bağlama yok', adlar(s), ['rpc:bilet_ac'])
}
{
  const s = sahte({ 'rpc:bilet_ac': new Error('Bu plaka için zaten açık bir bilet var.') })
  esit('sunucu reddi', await hata(girisAc(s, g(), ARACLAR)), 'Bu plaka için zaten açık bir bilet var.')
}
{
  let coz
  const s = sahte({ 'rpc:bilet_ac': () => new Promise((r) => (coz = r)) })
  const p1 = girisAc(s, g(), ARACLAR)
  const p2 = girisAc(s, g(), ARACLAR)
  await new Promise((r) => setTimeout(r, 0))
  coz('b-6')
  const [r1, r2] = await Promise.all([p1, p2])
  esit('çift dokunuş tek bilet', adlar(s).filter((a) => a === 'rpc:bilet_ac').length, 1)
  esit('ikisi aynı sonuç', [r1.biletId, r2.biletId], ['b-6', 'b-6'])
}
{
  const s = sahte({ 'rpc:bilet_ac': 'b-7' })
  await girisAc(s, g(), ARACLAR)
  await girisAc(s, g(), ARACLAR)
  esit('bittikten sonra yeni giriş açılabilir', adlar(s).filter((a) => a === 'rpc:bilet_ac').length, 2)
}

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
