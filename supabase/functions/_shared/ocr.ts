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
 *
 * The pure half — allowlist, request bodies, answer reading, thresholds,
 * prompt and schema — lives in vlm.ts so it can be tested with plain Node.
 * It is re-exported here, so callers import from this file as before.
 */
import { z } from 'npm:zod@4.4.3'
import {
  CELISKI_TAVANI,
  DEFAULT_VLM,
  IKINCI_GORUS,
  REDDE_YEDEK,
  VLM_MODELS,
  aracYokMu,
  ikinciGorusGerekir,
  istekGovdesi,
  okumaGuvenilir,
  plakaBicimiUygun,
  tidyPlaka,
  yanitOku,
} from './vlm.ts'

export {
  CELISKI_TAVANI,
  DEFAULT_VLM,
  GUVEN_ESIGI,
  GUVEN_ESIGI_BICIMSIZ,
  VLM_MODELS,
  aracYokMu,
  okumaGuvenilir,
  plakaBicimiUygun,
  tidyPlaka,
} from './vlm.ts'

const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages'
const PLATE_RECOGNIZER_URL = 'https://api.platerecognizer.com/v1/plate-reader/'

export const ModelYanitSchema = z.object({
  plaka: z.string().max(32),
  guven: z.number().min(0).max(1),
  okunamadi: z.boolean(),
  // Optional because the prompt-only fallback path cannot enforce a schema.
  // A missing answer is `false` — the safe direction: a wrong `false` costs
  // one more paid read, a wrong `true` could teach the camera to skip a car.
  arac_yok: z.boolean().optional().default(false),
  // The same plate, decomposed. Optional because the prompt-only fallback
  // path cannot enforce a schema, and because non-civilian plates have no
  // three groups to give.
  il: z.string().max(4).optional().default(''),
  harfler: z.string().max(8).optional().default(''),
  rakamlar: z.string().max(8).optional().default(''),
})
export type ModelYanit = z.infer<typeof ModelYanitSchema>

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

/** The model declined the request (`stop_reason: "refusal"`). */
class ModelReddetti extends Error {
  ham: unknown
  constructor(model: string, ham: unknown) {
    super(`${model} isteği reddetti`)
    this.ham = ham
  }
}

/**
 * Adds a note to a raw response before it is logged, so `ham_yanit` keeps the
 * answer that was USED at the top level (the cost query reads `usage` there)
 * and the other read beside it.
 */
function notEkle(raw: unknown, anahtar: string, not: unknown): Record<string, unknown> {
  const taban =
    typeof raw === 'object' && raw !== null && !Array.isArray(raw)
      ? (raw as Record<string, unknown>)
      : { yanit: raw }
  return { ...taban, [anahtar]: not }
}

/** One read with one model. Throws on any failure, including a refusal. */
async function anthropicOku(
  model: string,
  image: string,
  mediaType: string,
  apiKey: string,
): Promise<OkumaSonucu> {
  const call = (yapisal: boolean) =>
    fetch(ANTHROPIC_URL, {
      method: 'POST',
      headers: {
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
        'content-type': 'application/json',
        ...(yapisal ? { 'anthropic-beta': 'structured-outputs-2025-11-13' } : {}),
      },
      body: JSON.stringify(istekGovdesi(model, image, mediaType, yapisal)),
    })

  // Structured outputs is the guarantee we want. If this account rejects the
  // beta, fall back to prompt-only JSON rather than failing an operator at the
  // gate — zod validates the shape either way. A rejected request is not
  // billed, so the retry costs a moment, not money.
  let res = await call(true)
  if (res.status === 400) {
    console.warn('structured outputs reddedildi, düz JSON ile tekrar deneniyor')
    res = await call(false)
  }
  if (!res.ok) {
    throw new Error(`Anthropic ${res.status}: ${(await res.text()).slice(0, 300)}`)
  }

  const raw = await res.json()
  const yanit = yanitOku(raw)
  if (yanit.tur === 'red') throw new ModelReddetti(model, raw)
  if (yanit.tur === 'kesik') throw new Error(`${model} yanıtı kesildi (max_tokens)`)
  if (yanit.tur === 'bos') throw new Error(`${model} metin döndürmedi`)

  const parsed = ModelYanitSchema.parse(extractJson(yanit.metin))
  // `raw` keeps the model's untouched answer, so the log can still show what
  // it originally claimed; `parsed.guven` is the number the gate actually
  // judged, which is the one worth tuning the threshold against.
  const { plaka, guven } = birlestirOkuma(parsed)
  return { parsed: { ...parsed, plaka, guven }, raw, saglayici: model }
}

/**
 * A read with the configured model. A REFUSAL is retried once on REDDE_YEDEK
 * (Haiku 5.5 has safety classifiers and no server-side fallback; a gate photo
 * should never trip them, but if one does the car must still be read). Every
 * other failure is thrown as before, so it is logged as a provider error.
 */
async function readWithAnthropic(
  model: string,
  image: string,
  mediaType: string,
  apiKey: string,
): Promise<OkumaSonucu> {
  try {
    return await anthropicOku(model, image, mediaType, apiKey)
  } catch (err) {
    if (!(err instanceof ModelReddetti) || model === REDDE_YEDEK) throw err
    console.warn(`${model} reddetti, ${REDDE_YEDEK} ile tekrar okunuyor`)
    const yedek = await anthropicOku(REDDE_YEDEK, image, mediaType, apiKey)
    return {
      ...yedek,
      raw: notEkle(yedek.raw, 'onceki_okuma', { saglayici: model, ham_yanit: err.ham }),
    }
  }
}

/**
 * The first read, plus a second opinion when the first was borderline.
 *
 * The second read is USED only if it clears the same bar on its own — two
 * unsure reads that happen to agree are not treated as one sure read (not
 * measured yet). Whatever happens to the second read, the first is never lost:
 * a throw or refusal there keeps the first answer, so a second opinion can
 * only ever turn a manual entry into a read, never a read into an error.
 */
async function vlmOku(
  model: string,
  image: string,
  mediaType: string,
  apiKey: string,
): Promise<OkumaSonucu> {
  const ilk = await readWithAnthropic(model, image, mediaType, apiKey)
  const p = ilk.parsed
  if (!ikinciGorusGerekir(p.plaka, p.guven, p.okunamadi, aracYokMu(p), ilk.saglayici)) {
    return ilk
  }

  try {
    const ikinci = await anthropicOku(IKINCI_GORUS, image, mediaType, apiKey)
    const q = ikinci.parsed
    if (okumaGuvenilir(q.plaka, q.guven, q.okunamadi)) {
      return {
        ...ikinci,
        raw: notEkle(ikinci.raw, 'onceki_okuma', { saglayici: ilk.saglayici, ham_yanit: ilk.raw }),
      }
    }
    return {
      ...ilk,
      raw: notEkle(ilk.raw, 'ikinci_gorus', { saglayici: IKINCI_GORUS, ham_yanit: ikinci.raw }),
    }
  } catch (err) {
    console.warn('ikinci görüş alınamadı:', err)
    return {
      ...ilk,
      raw: notEkle(ilk.raw, 'ikinci_gorus', {
        saglayici: IKINCI_GORUS,
        hata: String(err).slice(0, 300),
      }),
    }
  }
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
      // An ALPR answers "no plate found", never "no vehicle": it must not
      // teach the camera bridge an empty gate.
      arac_yok: false,
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
    return vlmOku(chosen, image, mediaType, apiKey)
  }
  if (saglayici === 'ALPR') {
    const token = Deno.env.get('PLATE_RECOGNIZER_TOKEN')
    if (!token) throw new Error('PLATE_RECOGNIZER_TOKEN tanımlı değil.')
    return readWithPlateRecognizer(image, token)
  }
  throw new Error('Plaka okuma kapalı.')
}
