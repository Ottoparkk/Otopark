// Tam ekran fotoğrafta yakınlaştırma / kaydırma hesabı.
//
//   node tests/yakinlastir.check.mjs
//
// Gerçek dosyayı içe aktarır; lib/yakinlastir.ts hiçbir şey içe aktarmaz.
// Koordinatlar: kabın (ekranın) ORTASINA göre px; d = { s, x, y } →
// resim `translate(x, y) scale(s)` ile çizilir. `resim` = 1×'te sığdırılmış
// (object-contain) resmin boyutu.
import {
  EN_COK,
  CIFT_DOKUNUS,
  sigdir,
  sinirla,
  kistir,
  kaydir,
  ciftDokunus,
} from '../src/lib/yakinlastir.ts'

let gecen = 0
let kalan = 0

function esit(ad, gercek, beklenen) {
  const a = JSON.stringify(gercek)
  const b = JSON.stringify(beklenen)
  if (a === b) {
    gecen += 1
  } else {
    kalan += 1
    console.error(`✗ ${ad}\n    beklenen: ${b}\n    gelen:    ${a}`)
  }
}

// Sayıları yuvarlar (kayan nokta kırıntısı testi bozmasın).
const y = (d) => ({ s: +d.s.toFixed(6), x: +d.x.toFixed(6), y: +d.y.toFixed(6) })

const TELEFON = { w: 400, h: 800 }
const GENIS = { w: 400, h: 225 } // 16:9 kamera karesi telefonda: üstte altta boşluk
const DOLU = { w: 400, h: 800 } // ekranı tam dolduran resim

// ---- sigdir: object-contain boyutu --------------------------------------------
esit('geniş kare telefona sığar', sigdir(TELEFON, { w: 1920, h: 1080 }), { w: 400, h: 225 })
esit('uzun foto telefona sığar', sigdir(TELEFON, { w: 1080, h: 2400 }), { w: 360, h: 800 })
esit('boyut bilinmiyor → kabın kendisi', sigdir(TELEFON, { w: 0, h: 0 }), { w: 400, h: 800 })

// ---- sinirla: ölçek 1-EN_COK, 1×'te ortada, büyütünce kenar içeri girmez -------
esit('EN_COK 5', EN_COK, 5)
esit('ölçek 1 altına inmez', y(sinirla({ s: 0.4, x: 0, y: 0 }, TELEFON, GENIS)), { s: 1, x: 0, y: 0 })
esit('ölçek EN_COK üstüne çıkmaz', y(sinirla({ s: 9, x: 0, y: 0 }, TELEFON, GENIS)).s, 5)
esit('bozuk ölçek → 1', y(sinirla({ s: NaN, x: 3, y: 3 }, TELEFON, GENIS)), { s: 1, x: 0, y: 0 })
esit('1×: kaydırma ne olursa olsun ortada', y(sinirla({ s: 1, x: 120, y: -90 }, TELEFON, GENIS)), { s: 1, x: 0, y: 0 })
// 2×: geniş resim 800 x 450. Yatayda (800-400)/2 = 200'e kadar; dikeyde 450 < 800 → ortada.
esit('2× geniş resim: yatay sınır 200, dikey ortada', y(sinirla({ s: 2, x: 999, y: 300 }, TELEFON, GENIS)), { s: 2, x: 200, y: 0 })
esit('2× geniş resim: öbür kenar −200', y(sinirla({ s: 2, x: -999, y: -300 }, TELEFON, GENIS)), { s: 2, x: -200, y: 0 })
// 4×: 1600 x 900 → yatay 600, dikey (900-800)/2 = 50.
esit('4× geniş resim: dikeyde de 50 kayar', y(sinirla({ s: 4, x: 0, y: 999 }, TELEFON, GENIS)), { s: 4, x: 0, y: 50 })
esit('sınır içindeki kaydırma değişmez', y(sinirla({ s: 2, x: 37, y: 0 }, TELEFON, GENIS)), { s: 2, x: 37, y: 0 })

// ---- kistir: parmak arasındaki nokta parmakların altında kalır -----------------
{
  const bas = { s: 1, x: 0, y: 0 }
  const odak = { x: 50, y: 100 }
  const d = kistir(bas, 100, 200, odak, odak, TELEFON, DOLU)
  esit('kıstır 2×', y(d), { s: 2, x: -50, y: -100 })
  // Odaktaki resim noktası: (odak - t) / s → kıstırmadan önce ve sonra aynı.
  esit('odak noktası yerinde', [(odak.x - d.x) / d.s, (odak.y - d.y) / d.s], [50, 100])
}
{
  // Zaten büyütülmüşken: 2× (x=-50,y=-100) → 3×, odak (−80, 40).
  const bas = { s: 2, x: -50, y: -100 }
  const odak = { x: -80, y: 40 }
  const d = kistir(bas, 100, 150, odak, odak, TELEFON, DOLU)
  esit('büyütülmüşken kıstır: ölçek 3', +d.s.toFixed(6), 3)
  esit(
    'büyütülmüşken kıstır: odak yerinde',
    [+((odak.x - d.x) / d.s).toFixed(6), +((odak.y - d.y) / d.s).toFixed(6)],
    [+((odak.x - bas.x) / bas.s).toFixed(6), +((odak.y - bas.y) / bas.s).toFixed(6)],
  )
}
{
  // Parmaklar kıstırırken kayar: odak 0,0 → 30,−20 (2×): resim de o kadar kayar.
  const d = kistir({ s: 1, x: 0, y: 0 }, 100, 200, { x: 0, y: 0 }, { x: 30, y: -20 }, TELEFON, DOLU)
  esit('kıstırırken kaydırma', y(d), { s: 2, x: 30, y: -20 })
}
esit(
  '1 altına kıstırma ortaya döner',
  y(kistir({ s: 1.5, x: 40, y: 40 }, 200, 100, { x: 10, y: 10 }, { x: 10, y: 10 }, TELEFON, DOLU)),
  { s: 1, x: 0, y: 0 },
)
esit(
  'EN_COK üstüne kıstırılamaz',
  y(kistir({ s: 4, x: 0, y: 0 }, 100, 1000, { x: 0, y: 0 }, { x: 0, y: 0 }, TELEFON, DOLU)).s,
  5,
)
esit(
  'parmak mesafesi 0 → değişmez (bölme hatası yok)',
  y(kistir({ s: 2, x: 10, y: 10 }, 0, 50, { x: 0, y: 0 }, { x: 0, y: 0 }, TELEFON, DOLU)),
  { s: 2, x: 10, y: 10 },
)

// ---- kaydir: tek parmak -------------------------------------------------------
esit('1×: kaydırılamaz', y(kaydir({ s: 1, x: 0, y: 0 }, 80, 80, TELEFON, GENIS)), { s: 1, x: 0, y: 0 })
esit('2×: kayar', y(kaydir({ s: 2, x: 0, y: 0 }, 80, 80, TELEFON, GENIS)), { s: 2, x: 80, y: 0 })
esit('2×: kenarda durur', y(kaydir({ s: 2, x: 150, y: 0 }, 80, 0, TELEFON, GENIS)), { s: 2, x: 200, y: 0 })

// ---- ciftDokunus: 1× → 2.5× dokunulan yerde; büyükken → 1× ----------------------
esit('CIFT_DOKUNUS 2.5', CIFT_DOKUNUS, 2.5)
{
  const nokta = { x: 40, y: -60 }
  const d = ciftDokunus({ s: 1, x: 0, y: 0 }, nokta, TELEFON, DOLU)
  esit('çift dokunuş büyütür', y(d), { s: 2.5, x: -60, y: 90 })
  esit('dokunulan nokta yerinde', [(nokta.x - d.x) / d.s, (nokta.y - d.y) / d.s], [40, -60])
  esit('ikinci çift dokunuş geri döner', y(ciftDokunus(d, nokta, TELEFON, DOLU)), { s: 1, x: 0, y: 0 })
}
esit(
  'çift dokunuş kenarda sınırlanır',
  y(ciftDokunus({ s: 1, x: 0, y: 0 }, { x: 200, y: 0 }, TELEFON, GENIS)),
  // 2.5×: 1000 x 562.5 → yatay sınır 300; ham x = 200 - 200*2.5 = −300 (sınırda).
  { s: 2.5, x: -300, y: 0 },
)

console.log(`\n${gecen} geçti, ${kalan} kaldı`)
if (kalan) process.exit(1)
