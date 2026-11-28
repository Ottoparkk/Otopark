// P2 terminal (plan 2026-11-28, Task 4): Kurulum, the Personel list, PIN
// sign-in and "who am I".
//
//   node tests/terminalOturum.check.mjs
import { kurulumYap, personelListesi, pinIleGir, benKimim } from '../terminal/src/oturumIslem.ts'
import { terminalYaz, terminalOku, pinGecerli } from '../src/features/terminal/terminal.ts'

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

const ARACLAR = { terminalYaz, pinGecerli }
const GIZLI = 'a'.repeat(64)
const TERMINAL = { id: 't1', ad: 'Gişe P2', gizli: GIZLI }

function depoKur() {
  const m = new Map()
  return { getItem: (k) => (m.has(k) ? m.get(k) : null), setItem: (k, v) => m.set(k, v), removeItem: (k) => m.delete(k) }
}
// A fake Sunucu: records calls, answers from a table.
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
    fn: (ad, govde) => yanit(`fn:${ad}`, govde),
    dogrula: (th) => yanit('dogrula', th),
    sifreyleGir: (e, s) => yanit('sifreyleGir', [e, s]),
    cikis: () => yanit('cikis', null),
    oturum: () => cevaplar.oturum ?? null,
  }
}
const adlar = (s) => s.kayit.map((k) => k[0])

// --- kurulumYap -------------------------------------------------------------------
{
  const depo = depoKur()
  const s = sahte({ 'rpc:terminal_kaydet': TERMINAL })
  const t = await kurulumYap(s, depo, { eposta: 'y@x.tr', sifre: 'gizli', ad: '  Gişe P2 ' }, ARACLAR)
  esit('kurulum sırası', adlar(s), ['sifreyleGir', 'rpc:terminal_kaydet', 'cikis'])
  esit('şifreyle giriş', s.kayit[0][1], ['y@x.tr', 'gizli'])
  esit('cihaz adı kırpılır', s.kayit[1][1], { p_ad: 'Gişe P2' })
  esit('dönen kayıt', t, TERMINAL)
  esit('kayıt depoda', terminalOku(depo), TERMINAL)
}
{
  const depo = depoKur()
  const s = sahte({ 'rpc:terminal_kaydet': new Error('Yalnızca Yönetici terminal kaydedebilir.') })
  const h = await hata(kurulumYap(s, depo, { eposta: 'p@x.tr', sifre: 'x', ad: 'P2' }, ARACLAR))
  esit('kayıt reddi iletilir', h, 'Yalnızca Yönetici terminal kaydedebilir.')
  esit('reddedilse de çıkış yapılır', adlar(s), ['sifreyleGir', 'rpc:terminal_kaydet', 'cikis'])
  esit('reddedilince kayıt yok', terminalOku(depo), null)
}
{
  const s = sahte({ sifreyleGir: new Error('E-posta ya da şifre yanlış.') })
  esit('şifre yanlış', await hata(kurulumYap(s, depoKur(), { eposta: 'y@x.tr', sifre: 'x', ad: 'P2' }, ARACLAR)), 'E-posta ya da şifre yanlış.')
  esit('giriş olmadıysa kaydet yok', adlar(s).includes('rpc:terminal_kaydet'), false)
}
{
  const s = sahte()
  esit('boş ad', await hata(kurulumYap(s, depoKur(), { eposta: 'y@x.tr', sifre: 'x', ad: '   ' }, ARACLAR)), 'Cihaza bir ad verin.')
  esit('boş adda çağrı yok', s.kayit.length, 0)
}

// --- personelListesi ------------------------------------------------------------------
{
  const liste = [{ id: 'p1', ad_soyad: 'Ayşe' }]
  const s = sahte({ 'fn:terminal-giris': { personel: liste } })
  esit('liste', await personelListesi(s, TERMINAL), liste)
  esit('liste gövdesi', s.kayit[0][1], { islem: 'liste', gizli: GIZLI })
}
{
  const s = sahte({ 'fn:terminal-giris': {} })
  esit('liste boş gelirse', await personelListesi(s, TERMINAL), [])
}

// --- pinIleGir ---------------------------------------------------------------------------
{
  const s = sahte({ 'fn:terminal-giris': { token_hash: 'th1' }, dogrula: { user_id: 'p1' } })
  await pinIleGir(s, TERMINAL, 'p1', '1234', ARACLAR)
  esit('pin sırası', adlar(s), ['fn:terminal-giris', 'dogrula'])
  esit('pin gövdesi', s.kayit[0][1], { islem: 'giris', gizli: GIZLI, profile_id: 'p1', pin: '1234' })
  esit('token_hash doğrulanır', s.kayit[1][1], 'th1')
}
{
  const s = sahte()
  esit('kısa pin', await hata(pinIleGir(s, TERMINAL, 'p1', '12', ARACLAR)), 'PIN 4 rakam olmalı.')
  esit('harfli pin', await hata(pinIleGir(s, TERMINAL, 'p1', '12a4', ARACLAR)), 'PIN 4 rakam olmalı.')
  esit('geçersiz pinde çağrı yok', s.kayit.length, 0)
}
{
  const s = sahte({ 'fn:terminal-giris': {} })
  esit('token yok', await hata(pinIleGir(s, TERMINAL, 'p1', '1234', ARACLAR)), 'Giriş yapılamadı.')
  esit('token yoksa doğrulama yok', adlar(s), ['fn:terminal-giris'])
}
{
  const s = sahte({ 'fn:terminal-giris': new Error('Çok fazla hatalı deneme. 15 dakika sonra tekrar deneyin.') })
  esit('kilit mesajı aynen', await hata(pinIleGir(s, TERMINAL, 'p1', '1234', ARACLAR)), 'Çok fazla hatalı deneme. 15 dakika sonra tekrar deneyin.')
}

// --- benKimim ---------------------------------------------------------------------------
{
  const s = sahte({ oturum: { user_id: 'p1' }, 'sec:profiles': [{ id: 'p1', ad_soyad: 'Ayşe', rol: 'PERSONEL' }] })
  esit('ben', await benKimim(s), { id: 'p1', ad_soyad: 'Ayşe', rol: 'PERSONEL' })
  esit('ben sorgusu', s.kayit[0][1], 'select=id,ad_soyad,rol&id=eq.p1')
}
{
  esit('oturum yoksa', await hata(benKimim(sahte())), 'Oturum sona erdi. PIN ile tekrar girin.')
  esit('profil yoksa', await hata(benKimim(sahte({ oturum: { user_id: 'p1' }, 'sec:profiles': [] }))), 'Hesap bulunamadı.')
}

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
