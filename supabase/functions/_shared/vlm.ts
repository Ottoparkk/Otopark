/**
 * Plate reading with a Claude model — the PURE half.
 *
 * Everything here is data or arithmetic: which models may be configured, what
 * request each one gets, how an answer is read, and how a read is judged. No
 * imports and no I/O, on purpose: Deno is not on the development machine, so
 * this file is what `tests/vlm.check.mjs` executes with plain Node. The
 * network half (fetch, zod, the provider dispatch) stays in ocr.ts, which
 * re-exports everything below so its callers did not change.
 */

/**
 * Allowlist for otopark_ayarlari.plaka_model — an unknown value fails closed
 * to DEFAULT_VLM. Kept equal to src/lib/plakaModelleri.ts (the settings
 * screen's list); tests/vlm.check.mjs fails if the two drift apart.
 */
export const VLM_MODELS = new Set([
  'claude-haiku-4-5',
  'claude-haiku-5-5',
  'claude-sonnet-5',
  'claude-sonnet-5-5',
])

/**
 * Deliberately still Haiku 4.5: deploying this code must not change which
 * model reads plates. The switch is the owner's, made on the settings screen,
 * and reverting it is the same one tap.
 */
export const DEFAULT_VLM = 'claude-haiku-4-5'

/**
 * Haiku 5.5 can refuse a request (`stop_reason: "refusal"`) and has no
 * server-side fallback, so a refused read is retried once on this model —
 * which has no such classifier — instead of failing an operator at the gate.
 */
export const REDDE_YEDEK = 'claude-haiku-4-5'

/**
 * Asked only when the first read is borderline (see ikinciGorusGerekir). The
 * stronger reader, paid for on the few photos where it can change the outcome.
 */
export const IKINCI_GORUS = 'claude-sonnet-5-5'

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
 * Models that think by default and take `output_config.effort`.
 *
 * Opt-in for the same reason as the set above: `effort` is a 400 on Haiku 4.5.
 * These models run adaptive thinking when `thinking` is not sent, and the
 * thinking counts toward `max_tokens` — at the 200 tokens Haiku 4.5 gets,
 * thinking could use the whole budget and leave no answer at all (the request
 * then fails as "no text"). So they get room, and `low` effort: a plate is a
 * short read, and a car is waiting at the barrier. Only tokens actually used
 * are billed, so the larger cap costs nothing by itself.
 */
const DUSUNEN = new Set(['claude-haiku-5-5', 'claude-sonnet-5', 'claude-sonnet-5-5'])
const DUSUNEN_MAX_TOKENS = 2048
const ESKI_MAX_TOKENS = 200

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
 * Confidence ceiling for a read that contradicts itself. 0.5 is below both
 * thresholds, so such a read is never offered — it costs a manual entry,
 * which is the cheap failure.
 */
export const CELISKI_TAVANI = 0.5

/**
 * Upper edge of the second-opinion band, inclusive. A Sonnet read costs about
 * 20× a Haiku 5.5 read, so only the low part of the borderline band is asked
 * again (owner decision 2026-10-24); from here up to the bar, an unsure read
 * costs a manual entry instead.
 */
export const IKINCI_GORUS_UST = 0.65

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

export const PLAKA_SEMASI = {
  type: 'object',
  properties: {
    plaka: {
      type: 'string',
      description:
        'Görseldeki Türk plakasının karakterleri, boşluksuz ve büyük harf (örn. 34ABC123). Okunamıyorsa boş metin.',
    },
    guven: { type: 'number', description: '0-1 arası okuma güveni. Emin değilsen düşük ver.' },
    okunamadi: { type: 'boolean', description: 'Plaka hiç seçilemiyorsa true.' },
    // Separate from okunamadi on purpose. "There is no car" and "there is a car
    // I cannot read" lead to opposite actions at the camera: the first is the
    // empty gate the bridge may learn to stop sending, the second is a real
    // vehicle it must keep sending. One flag for both made them inseparable.
    arac_yok: {
      type: 'boolean',
      description:
        'Görselde HİÇ ARAÇ yoksa (boş yol, boş şerit) true. Araç var ama plakası okunamıyorsa false.',
    },
    il: { type: 'string', description: '2 rakamlı il kodu (01-81). Standart olmayan plakada boş.' },
    harfler: { type: 'string', description: 'Ortadaki harf grubu. Standart olmayan plakada boş.' },
    rakamlar: { type: 'string', description: 'Sondaki rakam grubu. Standart olmayan plakada boş.' },
  },
  required: ['plaka', 'guven', 'okunamadi', 'arac_yok', 'il', 'harfler', 'rakamlar'],
  additionalProperties: false,
} as const

// Claude refuses to identify people, and a gate photo often catches the
// driver. Asking only for the plate keeps the request inside what the model
// will answer, and the schema has no field that could carry a person.
export const ISTEM = [
  // "usually", not "there is": a fixed camera also photographs the empty gate
  // after a car leaves, and an opening line that promises a plate pushes the
  // model to find one in an empty road.
  'Bu görselde genellikle bir TÜRK araç plakası olur.',
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
  // The camera learns the empty gate from this flag, so a wrong `true` on a
  // real car is the expensive mistake: say plainly which way to err.
  'arac_yok: görselde HİÇ ARAÇ yoksa (boş yol, boş şerit) true ver; o zaman',
  'okunamadi=true ve plaka="" olur. Görselde bir araç varsa — plakası görünmese ya da',
  'okunamasa bile — arac_yok=false ver. Emin değilsen arac_yok=false ver.',
].join(' ')

/** The answer shape spelled out for the prompt-only fallback (no schema). */
const DUZ_JSON_ORNEGI =
  '{"plaka":"...","guven":0.0,"okunamadi":false,"arac_yok":false,"il":"..","harfler":"...","rakamlar":"..."}'

/**
 * The Messages API request body for one read.
 *
 * `yapisal` = structured outputs (the schema is enforced by the API); false is
 * the prompt-only fallback, which asks for the same JSON in words. Throws on a
 * model outside the allowlist: the caller validates first, and a request for
 * an unknown model must never be built by accident.
 */
export function istekGovdesi(
  model: string,
  image: string,
  mediaType: string,
  yapisal: boolean,
): Record<string, unknown> {
  if (!VLM_MODELS.has(model)) throw new Error(`İzin verilmeyen model: ${model}`)

  const metin = yapisal ? ISTEM : `${ISTEM} Yanıtı yalnızca şu JSON olarak ver: ${DUZ_JSON_ORNEGI}`
  const dusunen = DUSUNEN.has(model)

  const govde: Record<string, unknown> = {
    model,
    max_tokens: dusunen ? DUSUNEN_MAX_TOKENS : ESKI_MAX_TOKENS,
    ...(SICAKLIK_DESTEKLI.has(model) ? { temperature: 0 } : {}),
    // Image BEFORE text — documented to perform better for extraction.
    messages: [
      {
        role: 'user',
        content: [
          { type: 'image', source: { type: 'base64', media_type: mediaType, data: image } },
          { type: 'text', text: metin },
        ],
      },
    ],
    // `thinking` is never sent. Haiku 4.5 does not think unless asked; the
    // newer models think adaptively when it is absent, and turning it off is
    // refused at some effort levels — effort is the lever instead.
  }

  const outputConfig: Record<string, unknown> = {}
  if (dusunen) outputConfig.effort = 'low'
  if (yapisal) outputConfig.format = { type: 'json_schema', schema: PLAKA_SEMASI }
  if (Object.keys(outputConfig).length > 0) govde.output_config = outputConfig

  return govde
}

export type Yanit =
  | { tur: 'metin'; metin: string }
  | { tur: 'red' }
  | { tur: 'kesik' }
  | { tur: 'bos' }

/**
 * What came back, before any JSON parsing.
 *
 * `stop_reason` is checked FIRST: a refusal can carry partial text, and a
 * response cut off at `max_tokens` can carry half a JSON object — neither is
 * an answer. Text blocks are found by type, so the `thinking` blocks the newer
 * models put in front are skipped.
 */
export function yanitOku(raw: unknown): Yanit {
  const r = (raw ?? {}) as { stop_reason?: unknown; content?: unknown }
  if (r.stop_reason === 'refusal') return { tur: 'red' }
  if (r.stop_reason === 'max_tokens') return { tur: 'kesik' }

  const bloklar = Array.isArray(r.content) ? r.content : []
  const metin = bloklar
    .filter(
      (b): b is { type: string; text: string } =>
        typeof b === 'object' && b !== null && b.type === 'text' && typeof b.text === 'string',
    )
    .map((b) => b.text)
    .join('')

  return metin.trim() === '' ? { tur: 'bos' } : { tur: 'metin', metin }
}

/**
 * "The model saw no vehicle at all" — the only answer the camera bridge may
 * learn an empty-gate picture from.
 *
 * A contradictory answer (no vehicle, yet a plate) counts as false: the cost
 * of a wrong `false` is one more paid read, the cost of a wrong `true` could
 * be a car the bridge learns to ignore.
 */
export function aracYokMu(p: { arac_yok?: boolean; plaka: string }): boolean {
  return p.arac_yok === true && tidyPlaka(p.plaka) === ''
}

/**
 * Whether a read is worth a second opinion from IKINCI_GORUS.
 *
 * Only the band CELISKI_TAVANI..IKINCI_GORUS_UST (0.50–0.65, both ends
 * included, every plate shape): a plate-length answer the model was not sure
 * enough of, but not a guess (below CELISKI_TAVANI the model itself says
 * several characters are doubtful). Self-contradicting reads are capped at
 * exactly CELISKI_TAVANI, so they are included — they are the clearest case
 * of "two plausible readings". Above IKINCI_GORUS_UST an unsure read goes to
 * manual entry unasked, to keep the cost down. Never for an empty scene or an
 * unreadable plate, and never when the first reader already was the
 * second-opinion model. The okumaGuvenilir guard stays even though the band
 * sits under both bars today: a read that already passes is never re-read.
 */
export function ikinciGorusGerekir(
  plaka: string,
  guven: number,
  okunamadi: boolean,
  aracYok: boolean,
  model: string,
): boolean {
  if (model === IKINCI_GORUS) return false
  if (okunamadi || aracYok) return false
  if (plaka.length < 4) return false
  if (okumaGuvenilir(plaka, guven, okunamadi)) return false
  return guven >= CELISKI_TAVANI && guven <= IKINCI_GORUS_UST
}
