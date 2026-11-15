// Çıkanlar tarih süzgeci (067, sahip 2026-11-15): seçilen İstanbul günleri,
// cikis_at için yarı açık bir aralığa döner — [bas 00:00, bit+1 00:00), +03:00.
// Türkiye 2016'dan beri yıl boyu UTC+3 (lib/dates.ts, lib/aralik.ts).
//
//   node tests/cikisAraligi.check.mjs
import { cikisAraligi } from '../src/lib/cikisAraligi.ts'

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

esit('tek gün', cikisAraligi('2026-11-15', '2026-11-15'), {
  gte: '2026-11-15T00:00:00+03:00',
  lt: '2026-11-16T00:00:00+03:00',
})
esit('3 gün', cikisAraligi('2026-11-13', '2026-11-15'), {
  gte: '2026-11-13T00:00:00+03:00',
  lt: '2026-11-16T00:00:00+03:00',
})
esit('ay sonu', cikisAraligi('2026-10-25', '2026-10-31'), {
  gte: '2026-10-25T00:00:00+03:00',
  lt: '2026-11-01T00:00:00+03:00',
})
esit('yıl sonu', cikisAraligi('2026-12-31', '2026-12-31'), {
  gte: '2026-12-31T00:00:00+03:00',
  lt: '2027-01-01T00:00:00+03:00',
})
esit('şubat (artık olmayan yıl)', cikisAraligi('2027-02-28', '2027-02-28'), {
  gte: '2027-02-28T00:00:00+03:00',
  lt: '2027-03-01T00:00:00+03:00',
})
// Gerçek bir an olarak da doğru: 15 Kasım 00:00 İstanbul = 14 Kasım 21:00 UTC.
esit('UTC karşılığı', new Date(cikisAraligi('2026-11-15', '2026-11-15').gte).toISOString(),
  '2026-11-14T21:00:00.000Z')

console.log(`cikisAraligi: ${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
