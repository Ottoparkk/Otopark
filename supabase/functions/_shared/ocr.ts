/**
 * Shared plate-reading providers.
 *
 * Both plaka-oku (phone, JWT-authenticated) and kamera-webhook (hardware,
 * shared-secret) read plates through THIS module, so the two paths cannot
 * drift apart in accuracy or behaviour. The bridge topology's quality is
 * identical to the phone flow by construction, because it is the phone flow.
 *
 * SSRF control: every host below is a hardcoded constant. The database says
 * WHICH model to use; it never says where to send the request.
 */
import { z } from 'npm:zod@4.4.3'

const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages'
const PLATE_RECOGNIZER_URL = 'https://api.platerecognizer.com/v1/plate-reader/'

/** Allowlist for otopark_ayarlari.plaka_model — an unknown value fails closed. */
export const VLM_MODELS = new Set(['claude-haiku-4-5', 'claude-sonnet-5'])
export const DEFAULT_VLM = 'claude-haiku-4-5'

/**
 * Models that still accept sampling parameters.
 *
 * OPT-IN ON PURPOSE, and this is the whole point of the set. Sampling was
 * REMOVED from the Claude 5 family: sending `temperature` to claude-sonnet-5
 * is a 400, not a warning. An opt-out list would mean every model added to
 * VLM_MODELS later is assumed to accept it and breaks plate reading outright
 * the day someone switches; an opt-in list means an unknown model merely
 * misses a small win. Fail closed.
 *
 * Reading a plate has exactly one right answer, so the default temperature of
 * 1.0 buys nothing and can only sample a lower-probability character in place
 * of the correct one. Structured outputs already fix the response SHAPE; this
 * is about the characters inside it.
 *
 * Cost, if it ever matters: at 0 two reads of one photo are identical, so a
 * second independent read stops being an independent check. That trade only
 * arises if the borderline-double-read idea is ever built.
 */
const SICAKLIK_DESTEKLI = new Set(['claude-haiku-4-5'])

/**
 * Below this the caller must treat the read as "no result". A bad read should
 * cost a manual entry, never a wrong plate that gets waved through.
 */
export const GUVEN_ESIGI = 0.75

/**
 * The bar a read must clear when it does NOT look like a Turkish plate.
 *
 * Not a rejection, on purpose. The registration rules below cover civilian
 * plates; diplomatic, military and temporary series exist and this code has
 * no business refusing one at a barrier. So a shape we do not recognise is
 * treated as weaker evidence rather than as proof of a misread — it still
 * gets through if the model is genuinely sure.
 */
export const GUVEN_ESIGI_BICIMSIZ = 0.92

/**
 * Turkish civilian plate grammar: a province code 01-81, then letters, then
 * digits — 5 or 6 characters after the code, in one of three shapes.
 *
 *   1 harf + 4-5 rakam   34 A 1234
 *   2 harf + 3-4 rakam   48 AZ 518
 *   3 harf + 2-3 rakam   02 ABG 585
 *
 * `[A-PR-VYZ]` is A-Z minus Q, W and X, which the regulation does not use —
 * so a Q here is almost always a misread O, and saying so lets the check
 * catch a real error class rather than merely counting characters.
 */
const TR_PLAKA =
  /^(?:0[1-9]|[1-7][0-9]|8[01])(?:[A-PR-VYZ][0-9]{4,5}|[A-PR-VYZ]{2}[0-9]{3,4}|[A-PR-VYZ]{3}[0-9]{2,3})$/

/** True when the text has the shape of a Turkish civilian plate. */
export function plakaBicimiUygun(plaka: string): boolean {
  return TR_PLAKA.test(plaka)
}

/**
 * The threshold this particular read has to clear. One helper, so the phone
 * and the camera cannot end up judging the same photo differently.
 */
export function okumaGuvenilir(plaka: string, guven: number, okunamadi: boolean): boolean {
  if (okunamadi || plaka.length < 4) return false
  return guven >= (plakaBicimiUygun(plaka) ? GUVEN_ESIGI : GUVEN_ESIGI_BICIMSIZ)
}

export const ModelYanitSchema = z.object({
  plaka: z.string().max(32),
  guven: z.number().min(0).max(1),
  okunamadi: z.boolean(),
  // The same plate, decomposed. Optional because the prompt-only fallback
  // path cannot enforce a schema, and because non-civilian plates have no
  // three groups to give.
  il: z.string().max(4).optional().default(''),
  harfler: z.string().max(8).optional().default(''),
  rakamlar: z.string().max(8).optional().default(''),
})
export type ModelYanit = z.infer<typeof ModelYanitSchema>

/**
 * Confidence ceiling for a read that contradicts itself. 0.5 is below both
 * thresholds, so such a read is never offered — it costs a manual entry,
 * which is the cheap failure.
 */
export const CELISKI_TAVANI = 0.5

/**
 * Reconciles the decomposed read with the whole-string read.
 *
 * Asking for il/harfler/rakamlar separately makes the grammar operative
 * rather than advisory: the model must commit to which characters are the
 * province, which are letters and which are digits, instead of emitting one
 * blob and hoping. Asking for BOTH forms buys a second thing for free — two
 * spellings of one plate in a single call, so a disagreement is a
 * self-consistency signal costing no extra request and no extra latency.
 *
 * Diplomatic, military and temporary plates do not decompose, so the groups
 * are allowed to be empty and the whole string stays authoritative there.
 */
export function birlestirOkuma(y: ModelYanit): {
  plaka: string
  guven: number
  celiski: boolean
} {
  const gruplu = tidyPlaka(`${y.il}${y.harfler}${y.rakamlar}`)
  const butun = tidyPlaka(y.plaka)
  const celiski = gruplu !== '' && butun !== '' && gruplu !== butun
  // A decomposition that parses as a real plate is the better evidence; if it
  // does not, fall back to whatever the model wrote as one string.
  const plaka = plakaBicimiUygun(gruplu) ? gruplu : butun || gruplu
  return { plaka, guven: celiski ? Math.min(y.guven, CELISKI_TAVANI) : y.guven, celiski }
}

export interface OkumaSonucu {
  parsed: ModelYanit
  raw: unknown
  saglayici: string
}

const PLAKA_SEMASI = {
  type: 'object',
  properties: {
    plaka: {
      type: 'string',
      description:
        'Görseldeki Türk plakasının karakterleri, boşluksuz ve büyük harf (örn. 34ABC123). Okunamıyorsa boş metin.',
    },
    guven: { type: 'number', description: '0-1 arası okuma güveni. Emin değilsen düşük ver.' },
    okunamadi: { type: 'boolean', description: 'Plaka hiç seçilemiyorsa true.' },
    il: { type: 'string', description: '2 rakamlı il kodu (01-81). Standart olmayan plakada boş.' },
    harfler: { type: 'string', description: 'Ortadaki harf grubu. Standart olmayan plakada boş.' },
    rakamlar: { type: 'string', description: 'Sondaki rakam grubu. Standart olmayan plakada boş.' },
  },
  required: ['plaka', 'guven', 'okunamadi', 'il', 'harfler', 'rakamlar'],
  additionalProperties: false,
} as const

// Claude refuses to identify people, and a gate photo often catches the
// driver. Asking only for the plate keeps the request inside what the model
// will answer, and the schema has no field that could carry a person.
const ISTEM = [
  'Bu görselde bir TÜRK araç plakası var.',
  'SADECE plaka karakterlerini oku ve şemaya uygun JSON döndür.',

  // The grammar. Without it the model reads the plate as free text and has no
  // way to resolve the confusions below, which are most of the error rate.
  'Türk plakası şu yapıdadır: önce 2 rakamlı il kodu (01-81),',
  'sonra 1-3 harf, sonra 2-5 rakam.',
  'Geçerli biçimler: 1 harf + 4-5 rakam, 2 harf + 3-4 rakam, 3 harf + 2-3 rakam.',
  'Örnek: 34 A 1234, 48 AZ 518, 02 ABG 585.',
  'Harf grubunda Q, W ve X KULLANILMAZ.',

  // Forcing the three groups into their own fields is what makes the grammar
  // above binding instead of advisory — the model has to decide which
  // characters are the province before it can answer at all.
  'Plakayı önce üç gruba AYIR ve alanları ayrı ayrı doldur:',
  'il (2 rakam), harfler, rakamlar.',
  'plaka alanına da bu üçünün birleşik hâlini yaz; ikisi birbirini tutmalıdır.',
  'Standart olmayan bir plakada (diplomatik, askerî, geçici) üç grubu BOŞ bırak',
  've yalnızca plaka alanını doldur.',

  // Position is the disambiguator: the first two characters are always digits
  // and the last group is always digits, so an O in slot 1 is a 0 and an O in
  // the letter group is an O.
  'Konumu kullanarak karar ver: ilk iki karakter HER ZAMAN rakamdır,',
  'son grup HER ZAMAN rakamdır, ortadaki grup HER ZAMAN harftir.',
  'Bu yüzden O/0, I/1, B/8, S/5, Z/2, G/6 karışıklıklarını konuma göre çöz.',

  // ...but position only resolves LETTER/digit confusions. Two digits in the
  // same slot are both legal, so a digit-for-digit misread survives every
  // downstream check: 58 and 68 are equally valid province codes belonging to
  // different cars. Measured on a real photo — the model returned 68 for a 58
  // plate, the format check passed it, and only the fuzzy exit search would
  // have caught it. Naming the confusion is the only lever the prompt has.
  'İl kodundaki iki rakamı AYRICA kontrol et: 5/6, 3/8, 6/8, 0/8, 1/7 gibi',
  'rakam-rakam karışıklıkları konumdan ÇÖZÜLEMEZ; şüphedeysen guven değerini düşür.',

  // Things physically on the plate that are not the plate. The decoration
  // case came from a real photo: an owner had stuck a round ornament between
  // the letter and number groups, which is an O/0 waiting to happen. Owners
  // add whatever they like, so the rule is stated by position — anything
  // between the groups is not a character — rather than by listing objects.
  'Soldaki mavi şeritteki "TR" ülke kodudur, plakanın parçası DEĞİLDİR; okuma.',
  'Plaka üzerindeki süsler, vidalar, mühürler ve yuvarlak etiketler karakter DEĞİLDİR;',
  'gruplar arasındaki yuvarlak ya da süs amaçlı nesneleri O ya da 0 diye okuma.',
  'Plaka iki satırlıysa (motosiklet/kare plaka) önce üst satırı,',
  'sonra alt satırı oku ve birleştir.',

  // A phone photo is a tight crop framed by an operator; a fixed camera sends
  // a whole scene, which routinely contains other parked cars and sometimes an
  // ANPR display board showing plate text. The phone path has a human to catch
  // the wrong pick, the webhook has nobody.
  'Karede birden fazla plaka ya da plaka benzeri yazı olabilir: park hâlindeki',
  'başka araçlar, tabelalar, LED ekranlar. YALNIZCA kameraya en yakın ve en',
  'büyük görünen aracın plakasını oku; arka plandaki yazıları okuma.',

  'Boşluk, tire ve noktalama koyma; yalnızca harf ve rakam döndür.',
  'Görseldeki insanları tarif etme, tanımlama veya sayma.',
  // Without an anchor "lower it if unsure" is unmeasurable, and the whole
  // acceptance gate is a function of this one number.
  'guven değerini şu ölçeğe göre ver: 1.0 = her karakter net ve tartışmasız;',
  '0.8 = tek bir karakterden şüphelisin; 0.5 = birden fazla karakterden şüphelisin;',
  '0.3 ve altı = tahmin ediyorsun.',
  'guven, fotoğrafın kalitesine değil KARAKTERLERİN okunabilirliğine göre verilir:',
  'karanlık ya da bulanık bir fotoğrafta bile her karakteri net seçebiliyorsan guven yüksektir.',
  'Karakter uydurma; okuyamadığını okumuş gibi yapma.',
  'Plaka net değilse okunamadi=true ve plaka="" döndür.',
].join(' ')

/**
 * Display-side tidy-up only. `public.normalize_plaka()` in Postgres is the
 * authoritative version and runs inside every write — this exists so the
 * value we hand back for a prefilled input already looks right.
 */
export function tidyPlaka(raw: string): string {
  return raw
    .replace(/[ıİ]/g, 'I')
    .replace(/[çÇ]/g, 'C')
    .replace(/[ğĞ]/g, 'G')
    .replace(/[öÖ]/g, 'O')
    .replace(/[şŞ]/g, 'S')
    .replace(/[üÜ]/g, 'U')
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '')
}

/** Accepts a data: URL or bare base64; returns bare base64 plus its byte size. */
export function normalizeImage(raw: string): { data: string; bytes: number } {
  const data = raw.startsWith('data:') ? (raw.split(',')[1] ?? '') : raw
  const padding = data.endsWith('==') ? 2 : data.endsWith('=') ? 1 : 0
  return { data, bytes: Math.max(0, Math.floor((data.length * 3) / 4) - padding) }
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = ''
  const chunk = 0x8000 // avoid blowing the argument limit on large images
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk))
  }
  return btoa(binary)
}

function extractJson(text: string): unknown {
  const cleaned = text
    .trim()
    .replace(/^```(?:json)?\s*/i, '')
    .replace(/\s*```$/, '')
  return JSON.parse(cleaned)
}

async function readWithAnthropic(
  model: string,
  image: string,
  mediaType: string,
  apiKey: string,
): Promise<OkumaSonucu> {
  // Image BEFORE text — documented to perform better for extraction.
  const imageBlock = {
    type: 'image',
    source: { type: 'base64', media_type: mediaType, data: image },
  }

  const build = (withStructured: boolean): Record<string, unknown> => {
    const text = withStructured
      ? ISTEM
      : `${ISTEM} Yanıtı yalnızca şu JSON olarak ver: {"plaka":"...","guven":0.0,"okunamadi":false,"il":"..","harfler":"...","rakamlar":"..."}`

    const payload: Record<string, unknown> = {
      model,
      max_tokens: 200,
      ...(SICAKLIK_DESTEKLI.has(model) ? { temperature: 0 } : {}),
      messages: [{ role: 'user', content: [imageBlock, { type: 'text', text }] }],
      // `output_config.effort` is NOT sent — it errors on Haiku 4.5. `thinking`
      // is omitted too: a plate read needs no deliberation, and latency matters
      // when a car is waiting at a barrier.
    }
    if (withStructured) {
      payload.output_config = { format: { type: 'json_schema', schema: PLAKA_SEMASI } }
    }
    return payload
  }

  const call = (withStructured: boolean) =>
    fetch(ANTHROPIC_URL, {
      method: 'POST',
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
        ...(withStructured ? { 'anthropic-beta': 'structured-outputs-2025-11-13' } : {}),
      },
      body: JSON.stringify(build(withStructured)),
    })

  // Structured outputs is the guarantee we want. If this account rejects the
  // beta, fall back to prompt-only JSON rather than failing an operator at the
  // gate — zod validates the shape either way.
  let res = await call(true)
  if (res.status === 400) {
    console.warn('structured outputs reddedildi, düz JSON ile tekrar deneniyor')
    res = await call(false)
  }
  if (!res.ok) {
    throw new Error(`Anthropic ${res.status}: ${(await res.text()).slice(0, 300)}`)
  }

  const raw = await res.json()
  const text = (raw.content ?? [])
    .filter((c: { type: string }) => c.type === 'text')
    .map((c: { text: string }) => c.text)
    .join('')

  const parsed = ModelYanitSchema.parse(extractJson(text))
  // `raw` keeps the model's untouched answer, so the log can still show what
  // it originally claimed; `parsed.guven` is the number the gate actually
  // judged, which is the one worth tuning the threshold against.
  const { plaka, guven } = birlestirOkuma(parsed)
  return { parsed: { ...parsed, plaka, guven }, raw, saglayici: model }
}

async function readWithPlateRecognizer(image: string, token: string): Promise<OkumaSonucu> {
  const form = new FormData()
  form.append('upload', `data:image/jpeg;base64,${image}`)
  form.append('regions', 'tr')

  const res = await fetch(PLATE_RECOGNIZER_URL, {
    method: 'POST',
    headers: { Authorization: `Token ${token}` },
    body: form,
  })
  if (!res.ok) {
    throw new Error(`PlateRecognizer ${res.status}: ${(await res.text()).slice(0, 300)}`)
  }
  const raw = await res.json()
  const best = raw?.results?.[0]
  return {
    parsed: {
      plaka: String(best?.plate ?? '').toUpperCase(),
      guven: Number(best?.score ?? 0),
      okunamadi: !best,
      // A dedicated ALPR returns a plate, not a decomposition. Empty groups
      // mean birlestirOkuma() finds no contradiction and leaves it alone.
      il: '',
      harfler: '',
      rakamlar: '',
    },
    raw,
    saglayici: 'plate-recognizer',
  }
}

/**
 * Dispatches to whichever provider the settings row names. `saglayici` is the
 * mode (KAPALI/VLM/ALPR); `model` is the concrete vendor and is validated
 * against the allowlist above, never trusted straight from the database.
 */
export async function plakaOku(
  saglayici: string,
  model: string | null,
  image: string,
  mediaType: string,
): Promise<OkumaSonucu> {
  if (saglayici === 'VLM') {
    const apiKey = Deno.env.get('ANTHROPIC_API_KEY')
    if (!apiKey) throw new Error('ANTHROPIC_API_KEY tanımlı değil.')
    const chosen = model && VLM_MODELS.has(model) ? model : DEFAULT_VLM
    return readWithAnthropic(chosen, image, mediaType, apiKey)
  }
  if (saglayici === 'ALPR') {
    const token = Deno.env.get('PLATE_RECOGNIZER_TOKEN')
    if (!token) throw new Error('PLATE_RECOGNIZER_TOKEN tanımlı değil.')
    return readWithPlateRecognizer(image, token)
  }
  throw new Error('Plaka okuma kapalı.')
}
