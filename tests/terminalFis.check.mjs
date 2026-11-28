// P2 terminal (plan 2026-11-28, Task 6): the entry fiş — what it loads, its
// number first, then its lines.
//
//   node tests/terminalFis.check.mjs
import { fisVerisi, girisFisiBas } from '../terminal/src/fisIslem.ts'
import { girisFisi, sureMetni } from '../src/features/fis/fisIcerik.ts'
import { fisTahminSecenekleri, parcala } from '../src/features/fis/fisSecenek.ts'
import { kademeAraliklari } from '../src/features/finans/kademe.ts'
import { formatTL } from '../src/lib/money.ts'
import { formatSaat, formatTam } from '../src/lib/dates.ts'
import { ucretsizEtiket } from '../src/lib/ucretsiz.ts'
import { formatPlaka } from '../src/lib/plaka.ts'

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

const Y = {
  fis: { tl: formatTL, saat: formatSaat, tam: formatTam, ucretsizEtiket, plaka: formatPlaka },
  girisFisi,
  sureMetni,
  fisTahminSecenekleri,
  parcala,
  kademeAraliklari,
}

const BILET = {
  id: '1a2b3c4d-0000-4000-8000-000000000001',
  plaka: '34ABC123',
  giris_at: '2026-11-28T11:05:00.000Z',
  cikis_at: null,
  ucret_kurus: 0,
  indirim_kurus: 0,
  puan_kullanilan: 0,
  tahsil_kurus: 0,
  odeme_yontemi: null,
  abonman_id: null,
  yikama_kurus: null,
  anlasma_kurus: null,
  anlasma_bitis: null,
  ucretsiz_sebep: null,
  tarife_id: 't1',
  durum: 'ACIK',
}
const KADEMELER = [60, 120, 180, 240, 360, 480, 720, 1440].map((dakika, i) => ({ dakika, kurus: (i + 1) * 5000 }))

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
const adlar = (s) => s.kayit.map((k) => k[0])
const fiyatla = (args) => args.p_dakikalar.map((d) => ({ dakika: d, kurus: d * 100 }))

// --- fisVerisi ---------------------------------------------------------------------
{
  const s = sahte({
    'sec:biletler': [BILET],
    'sec:tarifeler': [{ id: 't1', tur: 'KADEMELI', kademeler: KADEMELER }],
    'sec:otopark_ayarlari': [{ ad: 'Merkez Otopark' }],
    'rpc:fis_tahmini': fiyatla,
  })
  const v = await fisVerisi(s, BILET.id, Y)
  esit('bilet sorgusu', s.kayit[0][1],
    `select=id,plaka,giris_at,cikis_at,ucret_kurus,indirim_kurus,puan_kullanilan,tahsil_kurus,odeme_yontemi,abonman_id,yikama_kurus,anlasma_kurus,anlasma_bitis,ucretsiz_sebep,tarife_id,durum&id=eq.${BILET.id}`)
  esit('biletin kendi tarifesi', s.kayit.find((k) => k[0] === 'sec:tarifeler')[1], 'select=id,tur,kademeler&id=eq.t1')
  esit('otopark adı', v.otopark, { ad: 'Merkez Otopark' })
  esit('seçenekler kademeler', v.secenekler.map((x) => x.dakika), [60, 120, 180, 240, 360, 480, 720, 1440])
  const tahminler = s.kayit.filter((k) => k[0] === 'rpc:fis_tahmini').map((k) => k[1])
  esit('8 kademe → 2 çağrı', tahminler.length, 2)
  esit('parçalar 6 + 2', tahminler.map((t) => t.p_dakikalar.length), [6, 2])
  esit('parça gövdesi', tahminler[0].p_bilet_id, BILET.id)
  esit('fiyatlar', [...v.fiyatlar.entries()].slice(0, 2), [[60, 6000], [120, 12000]])
}
{
  const s = sahte({
    'sec:biletler': [{ ...BILET, abonman_id: 'a1' }],
    'sec:otopark_ayarlari': [{ ad: 'Merkez Otopark' }],
  })
  const v = await fisVerisi(s, BILET.id, Y)
  esit('abonmanda seçenek yok', v.secenekler, [])
  esit('abonmanda tarife/tahmin sorulmaz', adlar(s).some((a) => a === 'sec:tarifeler' || a === 'rpc:fis_tahmini'), false)
}
{
  const s = sahte({
    'sec:biletler': [{ ...BILET, durum: 'KAPALI' }],
    'sec:otopark_ayarlari': [{ ad: 'Merkez Otopark' }],
  })
  esit('kapalı bilette seçenek yok', (await fisVerisi(s, BILET.id, Y)).secenekler, [])
}
{
  const s = sahte({ 'sec:biletler': [], 'sec:otopark_ayarlari': [{ ad: 'X' }] })
  esit('bilet yok', await hata(fisVerisi(s, BILET.id, Y)), 'Bilet bulunamadı.')
}

// --- girisFisiBas: number first, then lines ------------------------------------------------
const OTOPARK = { ad: 'Merkez Otopark' }
const simdi = () => '2026-11-28T11:06:00.000Z'
const metin = (satirlar) => satirlar.map((x) => x.metin ?? `${x.sol ?? ''} ${x.sag ?? ''}`).join('\n')
{
  const s = sahte({ 'rpc:fis_basildi': 1 })
  const satirlar = await girisFisiBas(s, { bilet: BILET, otopark: OTOPARK, tahmin: { dakika: 120, kurus: 12000 } }, simdi, Y)
  esit('önce numara', s.kayit[0], ['rpc:fis_basildi', { p_bilet_id: BILET.id, p_tur: 'GIRIS', p_tahmin_dk: 120 }])
  esit('aynı satırlar', satirlar, girisFisi({ otopark: OTOPARK, bilet: BILET, basim: 1, basimAt: simdi(), tahmin: { dakika: 120, kurus: 12000 } }, Y.fis))
  esit('ilk basım tekrar yazmaz', metin(satirlar).includes('TEKRAR BASIM'), false)
}
{
  const s = sahte({ 'rpc:fis_basildi': 2 })
  const satirlar = await girisFisiBas(s, { bilet: BILET, otopark: OTOPARK, tahmin: null }, simdi, Y)
  esit('tahminsiz gövde', s.kayit[0][1], { p_bilet_id: BILET.id, p_tur: 'GIRIS', p_tahmin_dk: null })
  esit('ikinci basım belli', metin(satirlar).includes('TEKRAR BASIM (2)'), true)
}
{
  const s = sahte({ 'rpc:fis_basildi': new Error('Bu bilet kapanmış.') })
  esit('numara alınamazsa basılmaz', await hata(girisFisiBas(s, { bilet: BILET, otopark: OTOPARK, tahmin: null }, simdi, Y)), 'Bu bilet kapanmış.')
}

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
