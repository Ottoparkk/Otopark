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

/** Anthropic's standard tier caps the long edge at 1568 px. Beyond that the
 *  image is downscaled server-side anyway, so sending more is pure waste. */
const OCR_MAX_EDGE = 1568

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
 * barrier buys nothing but latency. Cropping is the only real lever, which is
 * why the capture UI shows a plate-shaped guide.
 */
export async function compressForOcr(file: File): Promise<File> {
  const { default: imageCompression } = await import('browser-image-compression')
  return imageCompression(file, {
    maxSizeMB: 1.5,
    maxWidthOrHeight: OCR_MAX_EDGE,
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
