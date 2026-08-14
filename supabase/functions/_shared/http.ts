/** Shared HTTP plumbing for the Edge Functions. */

/**
 * CORS is NOT the security boundary — the JWT (plaka-oku) and the shared
 * secret (kamera-webhook) are. Pinning it just narrows drive-by use of a
 * stolen token from a hostile page. Set ALLOWED_ORIGINS to the deployed
 * origin; unset means "*", which is fine for local development only.
 */
export function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = (Deno.env.get('ALLOWED_ORIGINS') ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean)

  const allow =
    allowed.length === 0 ? '*' : origin && allowed.includes(origin) ? origin : (allowed[0] ?? '*')

  return {
    'Access-Control-Allow-Origin': allow,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    Vary: 'Origin',
  }
}

export function json(body: unknown, status: number, origin: string | null = null): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), 'Content-Type': 'application/json' },
  })
}

/**
 * Constant-time string comparison. A plain `===` on a shared secret leaks its
 * length and prefix through response timing; this always walks the full
 * length. Compares UTF-8 bytes so multi-byte characters cannot short-circuit.
 */
export function safeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder()
  const ba = enc.encode(a)
  const bb = enc.encode(b)
  // Length inequality is unavoidable to leak; fold it into the result rather
  // than returning early, so equal-length wrong guesses cost the same.
  let diff = ba.length ^ bb.length
  const len = Math.max(ba.length, bb.length)
  for (let i = 0; i < len; i++) {
    diff |= (ba[i] ?? 0) ^ (bb[i] ?? 0)
  }
  return diff === 0
}

/**
 * Derives a stable UUID from the parts of an event, so a camera that retries
 * the same POST collapses onto one ticket.
 *
 * This is load-bearing: ANPR cameras retry, none of them send a UUID, and
 * bilet_ac REQUIRES an idempotency key. Hashing (device, direction, time,
 * plate) means the second delivery of one event derives the same key and
 * becomes a no-op, while a genuinely new car at the same second derives a
 * different one.
 */
export async function deriveIslemId(parts: (string | null | undefined)[]): Promise<string> {
  const canonical = parts.map((p) => (p ?? '').trim()).join('|')
  const digest = new Uint8Array(
    await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonical)),
  )
  const b = digest.subarray(0, 16)
  // Stamp version 5 / RFC 4122 variant bits so the value is a well-formed UUID.
  b[6] = (b[6]! & 0x0f) | 0x50
  b[8] = (b[8]! & 0x3f) | 0x80
  const hex = Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`
}

/**
 * Parses whatever a camera calls a timestamp into a real instant.
 *
 * Turkey is UTC+3 all year (no DST since 2016), so a bare local wall-clock
 * string maps to +03:00 with no ambiguity. Getting this wrong is not cosmetic:
 * a three-hour offset bills every single car wrong, silently, forever — which
 * is why camera NTP is treated as a money invariant, not housekeeping.
 */
export function parseCameraTime(value: unknown): string | null {
  if (value === null || value === undefined) return null

  if (typeof value === 'number' || /^\d{10}$|^\d{13}$/.test(String(value))) {
    const n = Number(value)
    const ms = String(value).length === 13 ? n : n * 1000
    const d = new Date(ms)
    return Number.isNaN(d.getTime()) ? null : d.toISOString()
  }

  const s = String(value).trim()

  // TP-Link VIGI and friends: "20260812153000" = local wall clock.
  const compact = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(s)
  if (compact) {
    const [, y, mo, d, h, mi, sec] = compact
    const iso = `${y}-${mo}-${d}T${h}:${mi}:${sec}+03:00`
    const parsed = new Date(iso)
    return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString()
  }

  // "2026-08-12 15:30:00" with no zone — also local wall clock.
  const loose = /^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})$/.exec(s)
  if (loose) {
    const parsed = new Date(`${loose[1]}T${loose[2]}+03:00`)
    return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString()
  }

  // Anything already carrying an offset or Z is unambiguous.
  const direct = new Date(s)
  return Number.isNaN(direct.getTime()) ? null : direct.toISOString()
}
