// Fotoğraf temizliği döngüsü — supabase/functions/_shared/temizlik.ts.
//
//   node tests/temizlik.check.mjs
//
// temizlik.ts içe aktarmasız; Node doğrudan çalıştırır. Liste ve silme
// taklit edilir (gerçekte RPC + Storage API remove).
//
// Neden: 025'in gece işi fotoğrafları SQL ile siliyordu. Supabase'e göre bu
// yalnızca kayıt satırını siler, dosya kovada kalır — 1 GB'ı doldurmaya ve
// saklama süresini aşmaya devam eder (KVKK). Döngü artık Storage API ile siler
// ve hiçbir durumda sonsuza dek dönmez, hata yutmaz.
import {
  TEMIZLIK_PARCA,
  TEMIZLIK_EN_COK_TUR,
  TEMIZLIK_BUTCE_MS,
  fotoTemizle,
} from '../supabase/functions/_shared/temizlik.ts'

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

// Sahte kova: listele en eskiden `limit` kadar ad verir, sil gerçekten siler.
function kova(n) {
  const adlar = Array.from({ length: n }, (_, i) => `2026-09-01/giris-${String(i).padStart(5, '0')}.jpg`)
  const kalanlar = new Set(adlar)
  const silCagrilari = []
  const listeLimitleri = []
  return {
    kalanlar,
    silCagrilari,
    listeLimitleri,
    listele: async (limit) => {
      listeLimitleri.push(limit)
      return [...kalanlar].slice(0, limit)
    },
    sil: async (ad) => {
      silCagrilari.push(ad.length)
      let n = 0
      for (const a of ad) if (kalanlar.delete(a)) n += 1
      return n
    },
  }
}

esit('parça 1000 (Storage remove sınırı)', TEMIZLIK_PARCA, 1000)
esit('gece başına en çok 20 tur', TEMIZLIK_EN_COK_TUR, 20)
esit('süre bütçesi fonksiyon sınırının altında', TEMIZLIK_BUTCE_MS > 0 && TEMIZLIK_BUTCE_MS <= 120_000, true)

// 1) Silinecek bir şey yok.
{
  const k = kova(0)
  const r = await fotoTemizle({ listele: k.listele, sil: k.sil })
  esit('boş: sonuç', r, { silinen: 0, tur: 0, hata: null, bitti: true })
  esit('boş: silme çağrılmadı', k.silCagrilari, [])
}

// 2) 2.500 fotoğraf → üç tur, hepsi silinir, her silme ≤ 1000.
{
  const k = kova(2500)
  const r = await fotoTemizle({ listele: k.listele, sil: k.sil })
  esit('2500: sonuç', r, { silinen: 2500, tur: 3, hata: null, bitti: true })
  esit('2500: parçalar', k.silCagrilari, [1000, 1000, 500])
  esit('2500: kovada kalmadı', k.kalanlar.size, 0)
  esit('2500: liste hep 1000 istedi', k.listeLimitleri.every((l) => l === 1000), true)
}

// 3) Liste 1000'den fazla verse bile silme 1000'i aşmaz.
{
  const k = kova(1500)
  const r = await fotoTemizle({ listele: async () => [...k.kalanlar], sil: k.sil })
  esit('fazla liste: parçalar', k.silCagrilari, [1000, 500])
  esit('fazla liste: hepsi silindi', r.silinen, 1500)
}

// 4) Silme hata verirse durur ve hatayı söyler — sessizce devam etmez.
{
  const k = kova(2500)
  let n = 0
  const r = await fotoTemizle({
    listele: k.listele,
    sil: async () => {
      n += 1
      throw new Error('Storage 503')
    },
  })
  esit('silme hatası: tek deneme', n, 1)
  esit('silme hatası: silinen 0', r.silinen, 0)
  esit('silme hatası: bitmedi', r.bitti, false)
  esit('silme hatası: mesaj', /Storage 503/.test(String(r.hata)), true)
}

// 5) Liste hata verirse durur ve hatayı söyler.
{
  const r = await fotoTemizle({
    listele: async () => {
      throw new Error('rpc yok')
    },
    sil: async () => 0,
  })
  esit('liste hatası: mesaj', /rpc yok/.test(String(r.hata)), true)
  esit('liste hatası: bitmedi', r.bitti, false)
}

// 6) Silme "başarılı" deyip hiçbir şey silmezse aynı adlar yeniden gelir:
//    sonsuza dek dönmek yerine HATA ile durur.
{
  const k = kova(1500)
  let n = 0
  const r = await fotoTemizle({
    listele: k.listele,
    sil: async (ad) => {
      n += 1
      return ad.length // yalan: hiçbir şey silinmedi
    },
  })
  esit('ilerleme yok: bir silme sonra dur', n, 1)
  esit('ilerleme yok: hata var', typeof r.hata === 'string' && r.hata.length > 0, true)
  esit('ilerleme yok: bitmedi', r.bitti, false)
}

// 7) Tur sınırı: kalan iş bir sonraki geceye kalır, hata DEĞİL.
{
  const k = kova(5000)
  const r = await fotoTemizle({ listele: k.listele, sil: k.sil, enCokTur: 2 })
  esit('tur sınırı: sonuç', r, { silinen: 2000, tur: 2, hata: null, bitti: false })
}

// 8) Süre bütçesi: dolunca yeni tura başlamaz, hata değil.
{
  const k = kova(5000)
  let saat = 0
  const r = await fotoTemizle({
    listele: async (limit) => {
      saat += 60
      return k.listele(limit)
    },
    sil: k.sil,
    butceMs: 100,
    simdi: () => saat,
  })
  esit('bütçe: iki turdan sonra durdu', r, { silinen: 2000, tur: 2, hata: null, bitti: false })
}

// 9) Silinen sayısı Storage'ın bildirdiğidir (dosya zaten yoksa sayılmaz).
{
  const k = kova(10)
  const r = await fotoTemizle({
    listele: k.listele,
    sil: async (ad) => {
      await k.sil(ad)
      return 7
    },
  })
  esit('sayım: bildirilen', r.silinen, 7)
}

console.log(`${gecen} geçti, ${kalan} kaldı`)
process.exit(kalan > 0 ? 1 : 0)
