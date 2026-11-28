// P2 terminal (plan 2026-11-28, Task 2): the small fetch client that replaces
// supabase-js on Chrome 56.
//
//   node tests/terminalSunucu.check.mjs
//
// Imports the real terminal/src/sunucu.ts with a scripted fake fetch.
import { sunucuKur, ZAMAN_ASIMI_METNI, OTURUM_ANAHTARI } from '../terminal/src/sunucu.ts'
import { rpcErrorText } from '../src/lib/errors.ts'

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

const URL0 = 'https://x.supabase.co'
const ANAHTAR = 'sb_publishable_x'

function depoKur(ilk = {}) {
  const m = new Map(Object.entries(ilk))
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => m.set(k, String(v)),
    removeItem: (k) => m.delete(k),
    _m: m,
  }
}
function cevap(status, govde) {
  return { ok: status >= 200 && status < 300, status, json: async () => govde, text: async () => JSON.stringify(govde) }
}
// Each call takes the next scripted answer; records [url, init].
function fetchKur(cevaplar) {
  const kayit = []
  const f = async (url, init = {}) => {
    kayit.push({ url, method: init.method ?? 'GET', headers: init.headers ?? {}, body: init.body })
    const c = cevaplar.shift()
    if (typeof c === 'function') return c()
    if (!c) throw new Error('beklenmeyen istek: ' + url)
    return c
  }
  f.kayit = kayit
  return f
}
const SIMDI = 1_800_000_000_000
const oturum = (o = {}) => ({ access_token: 'eski', refresh_token: 'r1', expires_at: SIMDI / 1000 + 3600, user_id: 'u1', ...o })
const kur = (fetch, depo, ek = {}) => sunucuKur({ url: URL0, anahtar: ANAHTAR, fetch, depo, simdi: () => SIMDI, hataMetni: rpcErrorText, ...ek })

// --- rpc: URL, headers, body -----------------------------------------------------
{
  const f = fetchKur([cevap(200, 'b-1')])
  const s = kur(f, depoKur())
  const r = await s.rpc('bilet_ac', { p_plaka: '34ABC123' })
  esit('rpc sonucu', r, 'b-1')
  esit('rpc adresi', f.kayit[0].url, `${URL0}/rest/v1/rpc/bilet_ac`)
  esit('rpc POST', f.kayit[0].method, 'POST')
  esit('rpc apikey', f.kayit[0].headers.apikey, ANAHTAR)
  esit('oturumsuz Bearer anahtar', f.kayit[0].headers.Authorization, `Bearer ${ANAHTAR}`)
  esit('rpc gövde', JSON.parse(f.kayit[0].body), { p_plaka: '34ABC123' })
}
{
  const f = fetchKur([cevap(200, null)])
  const s = kur(f, depoKur({ [OTURUM_ANAHTARI]: JSON.stringify(oturum()) }))
  await s.rpc('x', {})
  esit('oturumla Bearer token', f.kayit[0].headers.Authorization, 'Bearer eski')
}

// --- errors: the server's Turkish sentence --------------------------------------
{
  const s = kur(fetchKur([cevap(400, { message: 'Bu plaka için zaten açık bir bilet var.' })]), depoKur())
  esit('rpc hata cümlesi', await hata(s.rpc('bilet_ac', {})), 'Bu plaka için zaten açık bir bilet var.')
}
{
  const s = kur(fetchKur([cevap(404, { code: 'PGRST202', message: 'Could not find the function' })]), depoKur())
  esit('PGRST202', await hata(s.rpc('yok', {})), 'Bu özellik sunucuda henüz etkin değil.')
}
{
  const f = fetchKur([cevap(400, { hata: 'PIN yanlış. 4 deneme hakkınız kaldı.' })])
  const s = kur(f, depoKur())
  esit('fn hata cümlesi', await hata(s.fn('terminal-giris', { islem: 'giris' })), 'PIN yanlış. 4 deneme hakkınız kaldı.')
  esit('fn adresi', f.kayit[0].url, `${URL0}/functions/v1/terminal-giris`)
}
{
  const s = kur(fetchKur([cevap(200, { personel: [] })]), depoKur())
  esit('fn sonucu', await s.fn('terminal-giris', { islem: 'liste' }), { personel: [] })
}

// --- sec: GET with the query --------------------------------------------------------
{
  const f = fetchKur([cevap(200, [{ id: 'p1' }])])
  const s = kur(f, depoKur())
  esit('sec sonucu', await s.sec('profiles', 'select=id&id=eq.p1'), [{ id: 'p1' }])
  esit('sec adresi', f.kayit[0].url, `${URL0}/rest/v1/profiles?select=id&id=eq.p1`)
  esit('sec GET', f.kayit[0].method, 'GET')
}

// --- dogrula: token_hash → session stored ---------------------------------------
{
  const depo = depoKur()
  const f = fetchKur([cevap(200, { access_token: 'a1', refresh_token: 'r1', expires_in: 3600, user: { id: 'u9' } })])
  const s = kur(f, depo)
  const o = await s.dogrula('th')
  esit('verify adresi', f.kayit[0].url, `${URL0}/auth/v1/verify`)
  esit('verify gövde', JSON.parse(f.kayit[0].body), { type: 'email', token_hash: 'th' })
  esit('oturum user_id', o.user_id, 'u9')
  esit('oturum bitiş', o.expires_at, SIMDI / 1000 + 3600)
  esit('oturum depoda', JSON.parse(depo.getItem(OTURUM_ANAHTARI)).access_token, 'a1')
  esit('oturum()', s.oturum()?.user_id, 'u9')
}
{
  const f = fetchKur([cevap(400, { error: 'invalid', msg: 'Token has expired or is invalid' })])
  const s = kur(f, depoKur())
  esit('verify hatası Türkçe', await hata(s.dogrula('th')), 'Giriş yapılamadı. Tekrar deneyin.')
}
{
  const f = fetchKur([cevap(200, { access_token: 'a2', refresh_token: 'r2', expires_in: 3600, user: { id: 'y1' } })])
  const s = kur(f, depoKur())
  await s.sifreyleGir('a@b.c', 'gizli')
  esit('şifre adresi', f.kayit[0].url, `${URL0}/auth/v1/token?grant_type=password`)
  esit('şifre gövde', JSON.parse(f.kayit[0].body), { email: 'a@b.c', password: 'gizli' })
}
{
  const f = fetchKur([cevap(400, { error: 'invalid_grant' })])
  const s = kur(f, depoKur())
  esit('şifre yanlış', await hata(s.sifreyleGir('a@b.c', 'x')), 'E-posta ya da şifre yanlış.')
}

// --- refresh before expiry ---------------------------------------------------------
{
  const depo = depoKur({ [OTURUM_ANAHTARI]: JSON.stringify(oturum({ expires_at: SIMDI / 1000 + 30 })) })
  const f = fetchKur([
    cevap(200, { access_token: 'yeni', refresh_token: 'r2', expires_in: 3600, user: { id: 'u1' } }),
    cevap(200, 1),
  ])
  const s = kur(f, depo)
  await s.rpc('x', {})
  esit('önce yenile', f.kayit[0].url, `${URL0}/auth/v1/token?grant_type=refresh_token`)
  esit('yenileme gövdesi', JSON.parse(f.kayit[0].body), { refresh_token: 'r1' })
  esit('sonra yeni token', f.kayit[1].headers.Authorization, 'Bearer yeni')
}

// Two calls at once near expiry share ONE refresh (a rotated refresh token
// used twice could sign the device out).
{
  const depo = depoKur({ [OTURUM_ANAHTARI]: JSON.stringify(oturum({ expires_at: SIMDI / 1000 + 30 })) })
  const f = fetchKur([
    cevap(200, { access_token: 'yeni', refresh_token: 'r2', expires_in: 3600, user: { id: 'u1' } }),
    cevap(200, 1),
    cevap(200, 2),
  ])
  const s = kur(f, depo)
  await Promise.all([s.rpc('a', {}), s.rpc('b', {})])
  esit('tek yenileme', f.kayit.filter((k) => k.url.includes('grant_type=refresh_token')).length, 1)
}

// --- 401: refresh once, retry once ------------------------------------------------
{
  const depo = depoKur({ [OTURUM_ANAHTARI]: JSON.stringify(oturum()) })
  const f = fetchKur([
    cevap(401, { message: 'JWT expired' }),
    cevap(200, { access_token: 'yeni', refresh_token: 'r2', expires_in: 3600, user: { id: 'u1' } }),
    cevap(200, 'tamam'),
  ])
  const s = kur(f, depo)
  esit('401 → yenile → tekrar', await s.rpc('x', {}), 'tamam')
  esit('3 istek', f.kayit.length, 3)
}
{
  const depo = depoKur({ [OTURUM_ANAHTARI]: JSON.stringify(oturum()) })
  const f = fetchKur([
    cevap(401, { message: 'JWT expired' }),
    cevap(200, { access_token: 'yeni', refresh_token: 'r2', expires_in: 3600, user: { id: 'u1' } }),
    cevap(401, { message: 'JWT expired' }),
  ])
  const s = kur(f, depo)
  esit('ikinci 401', await hata(s.rpc('x', {})), 'Oturum sona erdi. PIN ile tekrar girin.')
  esit('oturum silindi', depo.getItem(OTURUM_ANAHTARI), null)
}
{
  const depo = depoKur({ [OTURUM_ANAHTARI]: JSON.stringify(oturum()) })
  const f = fetchKur([cevap(401, { message: 'JWT expired' }), cevap(400, { error: 'invalid_grant' })])
  const s = kur(f, depo)
  esit('yenileme reddedilirse', await hata(s.rpc('x', {})), 'Oturum sona erdi. PIN ile tekrar girin.')
  esit('oturum silindi (yenileme)', depo.getItem(OTURUM_ANAHTARI), null)
}

// --- timeout without AbortController --------------------------------------------------
{
  const f = fetchKur([() => new Promise(() => {})])
  const s = kur(f, depoKur(), { zamanAsimiMs: 50 })
  esit('zaman aşımı', await hata(s.rpc('x', {})), ZAMAN_ASIMI_METNI)
  esit('zaman aşımı metni', ZAMAN_ASIMI_METNI, 'Bağlantı yavaş — tekrar deneyin.')
}
{
  const f = fetchKur([() => Promise.reject(new TypeError('Failed to fetch'))])
  const s = kur(f, depoKur())
  esit('ağ yok', await hata(s.rpc('x', {})), 'Bağlantı yok. İnterneti kontrol edin.')
}

// --- storage ---------------------------------------------------------------------------
{
  const f = fetchKur([cevap(200, { Key: 'plaka-foto/a.jpg' })])
  const s = kur(f, depoKur({ [OTURUM_ANAHTARI]: JSON.stringify(oturum()) }))
  await s.yukle('plaka-foto', '2026-11-28/giris_34ABC123.jpg', 'VERI', 'image/jpeg')
  esit('yükleme adresi', f.kayit[0].url, `${URL0}/storage/v1/object/plaka-foto/2026-11-28/giris_34ABC123.jpg`)
  esit('yükleme türü', f.kayit[0].headers['Content-Type'], 'image/jpeg')
  esit('yükleme gövde ham', f.kayit[0].body, 'VERI')
}
{
  const f = fetchKur([cevap(200, { signedURL: '/object/sign/plaka-foto/a.jpg?token=t' })])
  const s = kur(f, depoKur())
  esit('imzalı url', await s.imzaliUrl('plaka-foto', 'a.jpg', 600), `${URL0}/storage/v1/object/sign/plaka-foto/a.jpg?token=t`)
  esit('imza adresi', f.kayit[0].url, `${URL0}/storage/v1/object/sign/plaka-foto/a.jpg`)
  esit('imza süresi', JSON.parse(f.kayit[0].body), { expiresIn: 600 })
}

// --- cikis keeps the terminal record -------------------------------------------------
{
  const depo = depoKur({ [OTURUM_ANAHTARI]: JSON.stringify(oturum()), 'op.terminal': '{"id":"t"}' })
  const f = fetchKur([cevap(204, null)])
  const s = kur(f, depo)
  await s.cikis()
  esit('logout adresi', f.kayit[0].url, `${URL0}/auth/v1/logout`)
  esit('oturum gitti', depo.getItem(OTURUM_ANAHTARI), null)
  esit('terminal kaldı', depo.getItem('op.terminal'), '{"id":"t"}')
  esit('oturum() null', s.oturum(), null)
}
{
  const depo = depoKur({ [OTURUM_ANAHTARI]: JSON.stringify(oturum()) })
  const s = kur(fetchKur([() => Promise.reject(new TypeError('Failed to fetch'))]), depo)
  await s.cikis()
  esit('ağ yokken de çıkış yerelde olur', depo.getItem(OTURUM_ANAHTARI), null)
}
{
  esit('bozuk oturum kaydı yok sayılır', kur(fetchKur([]), depoKur({ [OTURUM_ANAHTARI]: '{bozuk' })).oturum(), null)
  esit('depo yoksa oturum yok', kur(fetchKur([]), null).oturum(), null)
}

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
