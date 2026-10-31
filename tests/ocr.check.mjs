// Plaka okuma — süre sınırı, GERÇEK ocr.ts üzerinde.
//
//   node tests/ocr.check.mjs        (~9 sn: bir senaryo 8 sn'lik eşiği bekler)
//
// ocr.ts `npm:zod@…` içe aktarır; Node bu belirteci tanımaz. Aşağıdaki çözümleme
// kancası onu kurulu `zod` paketine yönlendirir, başka hiçbir şeyi değiştirmez —
// yani çalışan kod dağıtılan kodun kendisidir (Node 24 tipleri kendisi atar).
// Ağ (`fetch`) ve `Deno.env` taklit edilir; sağlayıcıya hiçbir istek gitmez.
//
// Neden: sağlayıcı asılı kalırsa okuma hiç bitmiyordu. kamera-webhook'un hata
// dalı (istisna satırı + uyarı) yalnızca bir HATA atılınca çalışır; asılı bir
// istek Supabase fonksiyonu öldürene kadar bekler, köprü 4 denemeden sonra
// aracı bırakır ve personelin bulacağı hiçbir iz kalmaz.
import { register } from 'node:module'

const kanca =
  'export async function resolve(s, c, n) {' +
  ' if (s.startsWith("npm:zod@")) return n("zod", c);' +
  ' return n(s, c) }'
register('data:text/javascript,' + encodeURIComponent(kanca), import.meta.url)

globalThis.Deno = {
  env: { get: (k) => ({ ANTHROPIC_API_KEY: 'test', PLATE_RECOGNIZER_TOKEN: 'test' })[k] },
}

const { plakaOku } = await import('../supabase/functions/_shared/ocr.ts')
const vlm = await import('../supabase/functions/_shared/vlm.ts')
const IKINCI_GORUS = vlm.IKINCI_GORUS
// Eski kodda bu sınıf yok; testin çökmesi değil FAIL yazması için yer tutucu.
const OkumaSuresiDoldu = vlm.OkumaSuresiDoldu ?? class Yok {}

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

// --- sahte ağ -----------------------------------------------------------------
let cagrilar = []
let isleyici = null
globalThis.fetch = (url, init = {}) => {
  const govde = typeof init.body === 'string' ? JSON.parse(init.body) : null
  const c = { url: String(url), model: govde?.model ?? null, sinyal: init.signal ?? null }
  cagrilar.push(c)
  return isleyici(c)
}

const OKUMA = { plaka: '34ABC123', okunamadi: false, arac_yok: false, il: '34', harfler: 'ABC', rakamlar: '123' }
function cevap(guven) {
  return new Response(
    JSON.stringify({
      stop_reason: 'end_turn',
      content: [{ type: 'text', text: JSON.stringify({ ...OKUMA, guven }) }],
    }),
    { status: 200 },
  )
}
const RED = () => new Response(JSON.stringify({ stop_reason: 'refusal', content: [] }), { status: 200 })
// Asılı istek: hiç cevap vermez, yalnızca iptal edilirse biter (gerçek fetch gibi).
function asili(c) {
  return new Promise((_, ret) => {
    c.sinyal?.addEventListener('abort', () => ret(new DOMException('aborted', 'AbortError')))
  })
}
// Başlıklar geldi ama gövde hiç gelmiyor — ve iptali dinlemiyor.
const asiliGovde = () =>
  Promise.resolve({ ok: true, status: 200, json: () => new Promise(() => {}), text: () => new Promise(() => {}) })

// Testin kendisi asılı kalmasın: bugünkü (süresiz) kod burada "ASILI" döner.
async function oku(saglayici, model, butceMs, korumaMs = 3_000) {
  cagrilar = []
  const t0 = Date.now()
  const koruma = new Promise((coz) => setTimeout(() => coz({ asili: true }), korumaMs))
  const is = plakaOku(saglayici, model, 'QUJD', 'image/jpeg', butceMs).then(
    (sonuc) => ({ sonuc }),
    (hata) => ({ hata }),
  )
  const r = await Promise.race([is, koruma])
  return { ...r, ms: Date.now() - t0, cagrilar: [...cagrilar] }
}

// 1) Asılı Anthropic → okuma süre hatasıyla biter, bütçe içinde.
isleyici = asili
{
  const r = await oku('VLM', 'claude-haiku-5-5', 300)
  esit('asılı sağlayıcı: okuma bitti (asılı kalmadı)', r.asili ?? false, false)
  esit('asılı sağlayıcı: süre hatası', r.hata instanceof OkumaSuresiDoldu, true)
  esit('asılı sağlayıcı: bütçe içinde', r.ms < 1_000, true)
  esit('asılı sağlayıcı: isteğe iptal sinyali verildi', r.cagrilar[0]?.sinyal instanceof AbortSignal, true)
  esit('asılı sağlayıcı: istek iptal edildi', r.cagrilar[0]?.sinyal?.aborted ?? false, true)
}

// 2) Gövde hiç gelmiyor (iptali dinlemiyor) → yine süre hatası.
isleyici = asiliGovde
{
  const r = await oku('VLM', 'claude-haiku-5-5', 300)
  esit('asılı gövde: okuma bitti', r.asili ?? false, false)
  esit('asılı gövde: süre hatası', r.hata instanceof OkumaSuresiDoldu, true)
}

// 3) Ret → yedek model asılı: yedek de AYNI bütçeye tabi.
isleyici = (c) => (c.model === 'claude-haiku-5-5' ? Promise.resolve(RED()) : asili(c))
{
  const r = await oku('VLM', 'claude-haiku-5-5', 300)
  esit('asılı yedek: okuma bitti', r.asili ?? false, false)
  esit('asılı yedek: süre hatası', r.hata instanceof OkumaSuresiDoldu, true)
  esit('asılı yedek: yedeğe gerçekten gidildi', r.cagrilar.map((c) => c.model), ['claude-haiku-5-5', 'claude-haiku-4-5'])
}

// 4) Sınırda ilk okuma, ama ikinci görüşe yetecek süre yok → Sonnet'e gidilmez,
//    ilk okuma döner ve neden atlandığı yazılır.
isleyici = () => Promise.resolve(cevap(0.55))
{
  const r = await oku('VLM', 'claude-haiku-5-5', 300)
  esit('süre yok: hata yok', r.hata ? String(r.hata) : null, null)
  esit('süre yok: ilk okuma döndü', r.sonuc?.parsed?.plaka, '34ABC123')
  esit('süre yok: Sonnet çağrılmadı', r.cagrilar.map((c) => c.model), ['claude-haiku-5-5'])
  esit('süre yok: atlanma notu', r.sonuc?.raw?.ikinci_gorus, { saglayici: IKINCI_GORUS, atlandi: 'süre' })
}

// 5) Sınırda hızlı ilk okuma + asılı Sonnet → ilk okuma döner, HATA DEĞİL.
//    Bütçe 8 sn'lik eşiğin hemen üstünde: Sonnet sorulur, asılı kalır, süre
//    dolunca kesilir. İkinci görüş bir okumayı asla hataya çeviremez.
isleyici = (c) => (c.model === IKINCI_GORUS ? asili(c) : Promise.resolve(cevap(0.55)))
{
  const r = await oku('VLM', 'claude-haiku-5-5', 8_400, 12_000)
  esit('asılı Sonnet: okuma bitti', r.asili ?? false, false)
  esit('asılı Sonnet: hata yok', r.hata ? String(r.hata) : null, null)
  esit('asılı Sonnet: ilk okuma döndü', r.sonuc?.parsed?.plaka, '34ABC123')
  esit('asılı Sonnet: Sonnet soruldu', r.cagrilar.map((c) => c.model), ['claude-haiku-5-5', IKINCI_GORUS])
  esit('asılı Sonnet: bütçe içinde', r.ms < 9_500, true)
}

// 6) Normal hızlı okuma → aynen eskisi gibi, tek istek, iptal edilmemiş sinyal.
isleyici = () => Promise.resolve(cevap(0.95))
{
  const r = await oku('VLM', 'claude-haiku-5-5', undefined)
  esit('normal: plaka', r.sonuc?.parsed?.plaka, '34ABC123')
  esit('normal: güven', r.sonuc?.parsed?.guven, 0.95)
  esit('normal: tek istek', r.cagrilar.length, 1)
  esit('normal: sinyal var, iptal yok', [r.cagrilar[0]?.sinyal instanceof AbortSignal, r.cagrilar[0]?.sinyal?.aborted], [true, false])
}

// 7) Asılı Plate Recognizer (ALPR) → süre hatası.
isleyici = asili
{
  const r = await oku('ALPR', null, 300)
  esit('asılı ALPR: okuma bitti', r.asili ?? false, false)
  esit('asılı ALPR: süre hatası', r.hata instanceof OkumaSuresiDoldu, true)
  esit('asılı ALPR: Plate Recognizer adresi', r.cagrilar[0]?.url.includes('platerecognizer'), true)
}

console.log(`${gecen} geçti, ${kalan} kaldı`)
process.exit(kalan > 0 ? 1 : 0)
