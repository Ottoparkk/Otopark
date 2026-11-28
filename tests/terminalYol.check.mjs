// P2 terminal (plan 2026-11-28, Task 3): hash routes and which screen opens.
//
//   node tests/terminalYol.check.mjs
import { yolOku, yolYaz, acilisYolu } from '../terminal/src/yol.ts'

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

const ID = '1a2b3c4d-0000-4000-8000-000000000001'

esit('boş', yolOku(''), null)
esit('yalnız #', yolOku('#'), null)
esit('bilinmeyen', yolOku('#/xyz'), null)
esit('kurulum', yolOku('#/kurulum'), { ekran: 'kurulum' })
esit('pin', yolOku('#/pin'), { ekran: 'pin' })
esit('gise', yolOku('#/gise'), { ekran: 'gise' })
esit('giris', yolOku('#/giris'), { ekran: 'giris' })
esit('fiş uuid', yolOku(`#/fis/${ID}`), { ekran: 'fis', biletId: ID })
esit('fiş uuid değil', yolOku('#/fis/abc'), null)
esit('fiş id yok', yolOku('#/fis'), null)
esit('fazla parça', yolOku(`#/fis/${ID}/x`), null)

for (const h of ['#/kurulum', '#/pin', '#/gise', '#/giris', `#/fis/${ID}`]) {
  esit(`gidiş-dönüş ${h}`, yolYaz(yolOku(h)), h)
}

const GIRIS = { ekran: 'giris' }
esit('terminal değil → kurulum', acilisYolu(false, false, GIRIS), { ekran: 'kurulum' })
esit('terminal değil, oturum var → kurulum', acilisYolu(false, true, GIRIS), { ekran: 'kurulum' })
esit('oturum yok → pin', acilisYolu(true, false, GIRIS), { ekran: 'pin' })
esit('oturum yok, kurulum istense de → pin', acilisYolu(true, false, { ekran: 'kurulum' }), { ekran: 'pin' })
esit('oturum var, yol yok → gişe', acilisYolu(true, true, null), { ekran: 'gise' })
esit('oturum var, istenen yol', acilisYolu(true, true, GIRIS), GIRIS)
esit('oturum var, pin = Devral', acilisYolu(true, true, { ekran: 'pin' }), { ekran: 'pin' })
esit('oturum var, kurulum → gişe', acilisYolu(true, true, { ekran: 'kurulum' }), { ekran: 'gise' })

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
