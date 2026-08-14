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
 * Below this the caller must treat the read as "no result". A bad read should
 * cost a manual entry, never a wrong plate that gets waved through.
 */
export const GUVEN_ESIGI = 0.75

export const ModelYanitSchema = z.object({
  plaka: z.string().max(32),
  guven: z.number().min(0).max(1),
  okunamadi: z.boolean(),
})
export type ModelYanit = z.infer<typeof ModelYanitSchema>

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
  },
  required: ['plaka', 'guven', 'okunamadi'],
  additionalProperties: false,
} as const

// Claude refuses to identify people, and a gate photo often catches the
// driver. Asking only for the plate keeps the request inside what the model
// will answer, and the schema has no field that could carry a person.
const ISTEM = [
  'Bu görselde bir aracın plakası var.',
  'SADECE plaka karakterlerini oku ve şemaya uygun JSON döndür.',
  'Görseldeki insanları tarif etme, tanımlama veya sayma.',
  'Emin olmadığın karakterler varsa guven değerini düşür; uydurma.',
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
      : `${ISTEM} Yanıtı yalnızca şu JSON olarak ver: {"plaka":"...","guven":0.0,"okunamadi":false}`

    const payload: Record<string, unknown> = {
      model,
      max_tokens: 200,
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

  return { parsed: ModelYanitSchema.parse(extractJson(text)), raw, saglayici: model }
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
