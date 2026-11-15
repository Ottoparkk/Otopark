// Çözülmemiş kayıtlar → "Çıkış": Gişe'ye hangi aramayla gelinir.
//
//   node tests/cikisLink.check.mjs
//
// Hata (2026-11-15): düğme /gise/cikis'e gidiyordu ama o adres artık düz
// Gişe'yi açıyor — araç hakkında hiçbir şey yok, "hiçbir şey olmadı" gibi
// görünüyor. Artık kartın plakası Gişe'nin aramasına taşınır.
import { cikisLinki, cikisAramasi } from '../src/features/gise/cikisLink.ts'

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

// 1. Bağlantı: adres ve taşınan plaka
esit('plakalı', cikisLinki('34ABC123'), { to: '/gise/cikis', state: { cikisAra: '34ABC123' } })
esit('boş plaka', cikisLinki(''), { to: '/gise/cikis', state: { cikisAra: '' } })
esit('boşluklar atılır', cikisLinki('  34 abc 123 '), { to: '/gise/cikis', state: { cikisAra: '34ABC123' } })

// 2. Gişe tarafı: yalnızca /cikis adresinde ve yalnızca bu state ile
esit('gelen arama', cikisAramasi('/gise/cikis', { cikisAra: '34ABC123' }), '34ABC123')
esit('boş arama da geçerli (odak yine aramaya)', cikisAramasi('/gise/cikis', { cikisAra: '' }), '')
esit('state yoksa da /cikis aramaya odaklar', cikisAramasi('/gise/cikis', null), '')
esit('düz Gişe: yok', cikisAramasi('/gise', { cikisAra: '34ABC123' }), null)
esit('Giriş: yok', cikisAramasi('/gise/giris', { cikisAra: '34ABC123' }), null)
esit('bozuk state', cikisAramasi('/gise/cikis', { cikisAra: 42 }), '')
esit('küçük harf büyür', cikisAramasi('/gise/cikis', { cikisAra: '34abc' }), '34ABC')

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan) process.exit(1)
