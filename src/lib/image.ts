/**
 * TWO compression profiles, because the same photo has two different jobs and
 * the storage-optimised settings actively break the other one.
 *
 *   compressEvidence() — the stored ticket photo. Small, cheap to upload on
 *                        mobile data, only ever looked at by a human.
 *   compressForOcr()   — what the model reads. Heavy JPEG compression makes
 *                        text hard to read, and a plate read IS text reading.
 *
 * The library is imported lazily so it stays out of the main bundle; it is
 * only needed at the moment a photo is taken.
 */

/**
 * The resolution cap is PER MODEL, not a constant — getting this wrong costs
 * accuracy silently.
 *
 *   standard tier (Haiku 4.5 and earlier)  1568 px long edge, 1568 visual tokens
 *   high-res tier (Claude 4.7 and later)   2576 px long edge, 4784 visual tokens
 *
 * Anything larger is downscaled server-side, so sending more is pure waste —
 * but sending 1568 to a high-res model throws away 2.7x the pixels ON THE
 * PLATE, and pixels on the plate is the variable we measured as dominant.
 * High-res needs no beta header or opt-in; it is automatic on those models.
 *
 * Kept in step with VLM_MODELS in supabase/functions/_shared/ocr.ts — that
 * allowlist decides which models may be configured at all; this decides how
 * much image each one is worth sending.
 */
const OCR_EDGE_STANDARD = 1568
const OCR_EDGE_YUKSEK = 2576
const YUKSEK_COZUNURLUK = new Set(['claude-sonnet-5'])

export function ocrMaxEdge(model: string | null | undefined): number {
  return model && YUKSEK_COZUNURLUK.has(model) ? OCR_EDGE_YUKSEK : OCR_EDGE_STANDARD
}

export async function compressEvidence(file: File): Promise<File> {
  const { default: imageCompression } = await import('browser-image-compression')
  return imageCompression(file, {
    maxSizeMB: 0.2,
    maxWidthOrHeight: 1280,
    useWebWorker: true,
    fileType: 'image/jpeg',
    initialQuality: 0.8,
  })
}

/**
 * Gentle quality, capped at the model's resolution tier.
 *
 * Cost note: a 4K photo and a 1456x819 downscale cost the SAME number of
 * visual tokens (the cap binds first), so uploading 4K over mobile data at a
 * barrier buys nothing but latency.
 *
 * How CLOSE the photo is taken is the lever, and it is an ACCURACY lever, not
 * just a cost one. Measured on one car photographed twice: from far away the
 * model got three of eight characters wrong and scored itself 0.55; framed
 * close it read the plate cleanly. No prompt wording moves accuracy that far.
 *
 * There is deliberately no in-app framing guide: `capture="environment"` hands
 * the screen to the OS camera app, which cannot be drawn on. A guide would
 * mean replacing it with getUserMedia + video + canvas — a real feature with
 * a permissions flow of its own. Until then the capture button carries the
 * instruction in words.
 */
export async function compressForOcr(file: File, maxEdge = OCR_EDGE_STANDARD): Promise<File> {
  const { default: imageCompression } = await import('browser-image-compression')
  return imageCompression(file, {
    maxSizeMB: 1.5,
    maxWidthOrHeight: maxEdge,
    useWebWorker: true,
    fileType: 'image/jpeg',
    initialQuality: 0.92,
  })
}

/** Bare base64 (no data: prefix) — the shape the Edge Function expects. */
export async function fileToBase64(file: File): Promise<string> {
  const buf = await file.arrayBuffer()
  const bytes = new Uint8Array(buf)
  let binary = ''
  const chunk = 0x8000 // chunked: String.fromCharCode(...bigArray) blows the stack
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk))
  }
  return btoa(binary)
}

/**
 * Storage path for a plate photo. Date-prefixed so the nightly KVKK purge and
 * a human browsing the bucket both see the same ordering.
 */
export function fotoYolu(yon: 'giris' | 'cikis', plaka: string): string {
  const now = new Date()
  const stamp = now.toISOString().slice(0, 10)
  const rand = crypto.randomUUID().slice(0, 8)
  return `${stamp}/${yon}-${plaka || 'bilinmiyor'}-${rand}.jpg`
}
