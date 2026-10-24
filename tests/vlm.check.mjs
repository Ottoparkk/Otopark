// Plaka okuma isteği ve yanıtı — model başına kurallar.
//
//   node tests/vlm.check.mjs
//
// Gerçek dosyaları içe aktarır: supabase/functions/_shared/vlm.ts (içe aktarmasız,
// Node doğrudan çalıştırır) ve src/lib/plakaModelleri.ts. ocr.ts `npm:zod` içe
// aktardığı için burada çalışamaz; saf kurallar bu yüzden vlm.ts'te.
import {
  VLM_MODELS,
  DEFAULT_VLM,
  REDDE_YEDEK,
  IKINCI_GORUS,
  IKINCI_GORUS_UST,
  PLAKA_SEMASI,
  ISTEM,
  istekGovdesi,
  yanitOku,
  ikinciGorusGerekir,
  aracYokMu,
  okumaGuvenilir,
  plakaBicimiUygun,
  tidyPlaka,
} from '../supabase/functions/_shared/vlm.ts'
import { PLAKA_MODELLERI } from '../src/lib/plakaModelleri.ts'

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

function atar(ad, fn) {
  try {
    fn()
    kalan += 1
    console.error(`FAIL ${ad}\n  hata bekleniyordu, atmadı`)
  } catch {
    gecen += 1
  }
}

const RESIM = 'QUJD'
const TUR = 'image/jpeg'

// --- izin listesi -----------------------------------------------------------
esit('izinli modeller', [...VLM_MODELS].sort(), [
  'claude-haiku-4-5',
  'claude-haiku-5-5',
  'claude-sonnet-5',
  'claude-sonnet-5-5',
])
// Dağıtım tek başına hiçbir şeyi değiştirmesin: model ayarı boşsa eskisi sürer.
esit('varsayılan değişmedi', DEFAULT_VLM, 'claude-haiku-4-5')
esit('redde yedek', REDDE_YEDEK, 'claude-haiku-4-5')
esit('ikinci görüş', IKINCI_GORUS, 'claude-sonnet-5-5')
esit('ikinci görüş izinli', VLM_MODELS.has(IKINCI_GORUS), true)
// Sahip kararı 2026-10-24 (maliyet): Sonnet yalnızca 0.50–0.65 bandında sorulur.
esit('ikinci görüş üst sınırı', IKINCI_GORUS_UST, 0.65)
esit('yedek izinli', VLM_MODELS.has(REDDE_YEDEK), true)

// --- istek gövdesi: Haiku 4.5 bugünkünün aynısı -----------------------------
{
  const g = istekGovdesi('claude-haiku-4-5', RESIM, TUR, true)
  esit('h45: model', g.model, 'claude-haiku-4-5')
  esit('h45: max_tokens', g.max_tokens, 200)
  esit('h45: temperature 0', g.temperature, 0)
  esit('h45: thinking yok', 'thinking' in g, false)
  esit('h45: effort yok', g.output_config?.effort, undefined)
  esit('h45: şema', g.output_config?.format, { type: 'json_schema', schema: PLAKA_SEMASI })
  esit('h45: görsel önce', g.messages[0].content[0], {
    type: 'image',
    source: { type: 'base64', media_type: TUR, data: RESIM },
  })
  esit('h45: metin sonra', g.messages[0].content[1], { type: 'text', text: ISTEM })
  esit('h45: tek kullanıcı mesajı', g.messages.map((m) => m.role), ['user'])
}
{
  const g = istekGovdesi('claude-haiku-4-5', RESIM, TUR, false)
  esit('h45 düz: output_config yok', 'output_config' in g, false)
  esit('h45 düz: temperature 0', g.temperature, 0)
  esit(
    'h45 düz: JSON talimatı arac_yok içerir',
    g.messages[0].content[1].text.includes('"arac_yok"'),
    true,
  )
}

// --- istek gövdesi: düşünen modeller ----------------------------------------
for (const model of ['claude-haiku-5-5', 'claude-sonnet-5', 'claude-sonnet-5-5']) {
  const g = istekGovdesi(model, RESIM, TUR, true)
  esit(`${model}: model`, g.model, model)
  // 200 düşünmeye yetmez: düşünce bütçeyi yerse metin hiç gelmez.
  esit(`${model}: max_tokens`, g.max_tokens, 2048)
  esit(`${model}: temperature yok`, 'temperature' in g, false)
  esit(`${model}: top_p yok`, 'top_p' in g, false)
  esit(`${model}: top_k yok`, 'top_k' in g, false)
  esit(`${model}: thinking gönderilmez`, 'thinking' in g, false)
  esit(`${model}: effort low`, g.output_config?.effort, 'low')
  esit(`${model}: şema`, g.output_config?.format, { type: 'json_schema', schema: PLAKA_SEMASI })
  esit(`${model}: görsel önce`, g.messages[0].content[0].type, 'image')

  const d = istekGovdesi(model, RESIM, TUR, false)
  esit(`${model} düz: effort korunur`, d.output_config, { effort: 'low' })
  esit(`${model} düz: temperature yok`, 'temperature' in d, false)
}

atar('bilinmeyen model reddedilir', () => istekGovdesi('claude-opus-9', RESIM, TUR, true))
atar('boş model reddedilir', () => istekGovdesi('', RESIM, TUR, true))

// --- şema ve istem: arac_yok -------------------------------------------------
esit('şema: arac_yok zorunlu', PLAKA_SEMASI.required.includes('arac_yok'), true)
esit('şema: arac_yok boolean', PLAKA_SEMASI.properties.arac_yok?.type, 'boolean')
esit('şema: fazladan alan yok', PLAKA_SEMASI.additionalProperties, false)
esit('şema: eski alanlar duruyor', PLAKA_SEMASI.required, [
  'plaka',
  'guven',
  'okunamadi',
  'arac_yok',
  'il',
  'harfler',
  'rakamlar',
])
esit('istem: arac_yok anlatılıyor', ISTEM.includes('arac_yok'), true)

// --- yanıt okuma -------------------------------------------------------------
esit(
  'yanıt: düz metin',
  yanitOku({ stop_reason: 'end_turn', content: [{ type: 'text', text: '{"a":1}' }] }),
  { tur: 'metin', metin: '{"a":1}' },
)
esit(
  'yanıt: önce düşünce bloğu',
  yanitOku({
    stop_reason: 'end_turn',
    content: [
      { type: 'thinking', thinking: '', signature: 'x' },
      { type: 'text', text: '{"b":2}' },
    ],
  }),
  { tur: 'metin', metin: '{"b":2}' },
)
esit(
  'yanıt: ret',
  yanitOku({ stop_reason: 'refusal', content: [{ type: 'text', text: 'yarım' }] }),
  { tur: 'red' },
)
esit(
  'yanıt: kesildi, metin yok',
  yanitOku({ stop_reason: 'max_tokens', content: [{ type: 'thinking', thinking: '' }] }),
  { tur: 'kesik' },
)
// Yarım JSON da kesiktir: ayrıştırmaya gönderilmez.
esit(
  'yanıt: kesildi, yarım metin',
  yanitOku({ stop_reason: 'max_tokens', content: [{ type: 'text', text: '{"pla' }] }),
  { tur: 'kesik' },
)
esit('yanıt: içerik yok', yanitOku({ stop_reason: 'end_turn', content: [] }), { tur: 'bos' })
esit('yanıt: boşluk metni', yanitOku({ content: [{ type: 'text', text: '  ' }] }), { tur: 'bos' })
esit('yanıt: null', yanitOku(null), { tur: 'bos' })

// --- güven kararı: bugünkü davranış aynen ------------------------------------
esit('güven: eşikte', okumaGuvenilir('34ABC123', 0.75, false), true)
esit('güven: eşiğin altı', okumaGuvenilir('34ABC123', 0.74, false), false)
esit('güven: okunamadı', okumaGuvenilir('34ABC123', 0.99, true), false)
esit('güven: kısa', okumaGuvenilir('ABC', 0.99, false), false)
esit('güven: biçimsiz 0.91', okumaGuvenilir('CD1234X', 0.91, false), false)
esit('güven: biçimsiz 0.92', okumaGuvenilir('CD1234X', 0.92, false), true)
esit('biçim: 01A1234', plakaBicimiUygun('01A1234'), true)
esit('biçim: 82 il kodu yok', plakaBicimiUygun('82A1234'), false)
esit('biçim: Q kullanılmaz', plakaBicimiUygun('34QBC123'), false)
esit('biçim: 2 harf 2 rakam olmaz', plakaBicimiUygun('34AB12'), false)
esit('tidy', tidyPlaka('34 abç-12ş'), '34ABC12S')

// --- araç yok ----------------------------------------------------------------
esit('araç yok: boş plaka', aracYokMu({ arac_yok: true, plaka: '' }), true)
esit('araç yok: boşluklu plaka', aracYokMu({ arac_yok: true, plaka: ' - ' }), true)
esit('araç yok: plaka varsa çelişki', aracYokMu({ arac_yok: true, plaka: '34ABC123' }), false)
esit('araç yok: alan false', aracYokMu({ arac_yok: false, plaka: '' }), false)
esit('araç yok: alan yok (eski sunucu)', aracYokMu({ plaka: '' }), false)

// --- ikinci görüş ------------------------------------------------------------
const H55 = 'claude-haiku-5-5'
esit('2. görüş: sınırda', ikinciGorusGerekir('34ABC123', 0.6, false, false, H55), true)
esit('2. görüş: çelişki tavanı dahil', ikinciGorusGerekir('34ABC123', 0.5, false, false, H55), true)
esit('2. görüş: tahmin (0.49)', ikinciGorusGerekir('34ABC123', 0.49, false, false, H55), false)
esit('2. görüş: zaten güvenilir', ikinciGorusGerekir('34ABC123', 0.8, false, false, H55), false)
esit('2. görüş: okunamadı', ikinciGorusGerekir('34ABC123', 0.6, true, false, H55), false)
esit('2. görüş: araç yok', ikinciGorusGerekir('', 0.9, false, true, H55), false)
esit('2. görüş: kısa', ikinciGorusGerekir('34A', 0.6, false, false, H55), false)
// Bant 0.50–0.65, iki uç dâhil, her plaka biçimi için. Üstü (kapının altında
// kalsa bile) Sonnet'e gitmez, doğrudan elle girişe düşer.
esit('2. görüş: üst uç dâhil (0.65)', ikinciGorusGerekir('34ABC123', 0.65, false, false, H55), true)
esit('2. görüş: bant dışı (0.66)', ikinciGorusGerekir('34ABC123', 0.66, false, false, H55), false)
esit('2. görüş: kapı altı ama bant dışı (0.70)', ikinciGorusGerekir('34ABC123', 0.7, false, false, H55), false)
esit('2. görüş: kapı altı ama bant dışı (0.74)', ikinciGorusGerekir('34ABC123', 0.74, false, false, H55), false)
esit('2. görüş: biçimsiz 0.60', ikinciGorusGerekir('CD1234X', 0.6, false, false, H55), true)
esit('2. görüş: biçimsiz 0.85 bant dışı', ikinciGorusGerekir('CD1234X', 0.85, false, false, H55), false)
esit('2. görüş: zaten Sonnet 5.5', ikinciGorusGerekir('34ABC123', 0.6, false, false, IKINCI_GORUS), false)
esit('2. görüş: Haiku 4.5 de alır', ikinciGorusGerekir('34ABC123', 0.6, false, false, 'claude-haiku-4-5'), true)

// --- ekrandaki liste sunucuyla aynı ------------------------------------------
esit(
  'ekran listesi = izin listesi',
  PLAKA_MODELLERI.map((m) => m.id).sort(),
  [...VLM_MODELS].sort(),
)
esit(
  'ekran listesi: her modelin etiketi var',
  PLAKA_MODELLERI.every((m) => typeof m.etiket === 'string' && m.etiket.length > 0),
  true,
)
esit(
  'ekran listesi: tek önerilen Haiku 5.5',
  PLAKA_MODELLERI.filter((m) => m.onerilen).map((m) => m.id),
  ['claude-haiku-5-5'],
)

console.log(`${gecen} geçti, ${kalan} kaldı`)
if (kalan > 0) process.exit(1)
