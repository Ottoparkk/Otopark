/**
 * The P2 terminal's server client (spec 2026-11-28): plain fetch against
 * Supabase's REST endpoints, instead of supabase-js, which leans on things
 * Chrome 56 lacks (AbortController, Web Locks) and is large. Same URL, same
 * publishable key, same RPCs and rules as the app.
 *
 * Pure apart from what it is given: fetch, storage and the clock come in
 * through `SunucuAyar`, so tests/terminalSunucu.check.mjs drives it in Node.
 * Type-only imports (CLAUDE.md): the error helper is passed in too.
 */

export interface Oturum {
  access_token: string
  refresh_token: string
  /** Unix seconds. */
  expires_at: number
  user_id: string
}

export interface Depo {
  getItem(k: string): string | null
  setItem(k: string, v: string): void
  removeItem(k: string): void
}

export interface SunucuAyar {
  url: string
  anahtar: string
  fetch: typeof fetch
  depo: Depo | null
  /** Milliseconds, like Date.now. */
  simdi: () => number
  /** `rpcErrorText` from src/lib/errors.ts. */
  hataMetni: (err: unknown, fallback: string) => string
  /** Default 15000. */
  zamanAsimiMs?: number
}

export interface Sunucu {
  rpc<T>(ad: string, args: Record<string, unknown>): Promise<T>
  sec<T>(tablo: string, sorgu: string): Promise<T[]>
  fn<T>(ad: string, govde: unknown): Promise<T>
  yukle(kova: string, yol: string, veri: Blob | string, tur: string): Promise<void>
  imzaliUrl(kova: string, yol: string, saniye: number): Promise<string>
  dogrula(tokenHash: string): Promise<Oturum>
  sifreyleGir(eposta: string, sifre: string): Promise<Oturum>
  cikis(): Promise<void>
  oturum(): Oturum | null
}

export const ZAMAN_ASIMI_METNI = 'Bağlantı yavaş — tekrar deneyin.'
export const OTURUM_ANAHTARI = 'op.terminal.oturum'
const AG_YOK_METNI = 'Bağlantı yok. İnterneti kontrol edin.'
const OTURUM_BITTI_METNI = 'Oturum sona erdi. PIN ile tekrar girin.'
/** Refresh when fewer than this many seconds are left. */
const YENILEME_PAYI_SN = 60

interface Yanit {
  ok: boolean
  status: number
  json(): Promise<unknown>
}

class OturumBitti extends Error {}

export function sunucuKur(a: SunucuAyar): Sunucu {
  const sure = a.zamanAsimiMs ?? 15000
  let bellek: Oturum | null = oku()

  function oku(): Oturum | null {
    if (!a.depo) return null
    try {
      const ham = a.depo.getItem(OTURUM_ANAHTARI)
      if (!ham) return null
      const o = JSON.parse(ham) as Partial<Oturum>
      if (
        typeof o.access_token !== 'string' ||
        typeof o.refresh_token !== 'string' ||
        typeof o.expires_at !== 'number' ||
        typeof o.user_id !== 'string'
      ) {
        return null
      }
      return o as Oturum
    } catch (e) {
      return null
    }
  }

  function yaz(o: Oturum | null) {
    bellek = o
    if (!a.depo) return
    try {
      if (o) a.depo.setItem(OTURUM_ANAHTARI, JSON.stringify(o))
      else a.depo.removeItem(OTURUM_ANAHTARI)
    } catch (e) {
      // A locked-down browser: the session lives in memory only.
    }
  }

  /** fetch with a timeout; no AbortController on Chrome 56, so the request is just abandoned. */
  function istek(yol: string, init: RequestInit): Promise<Yanit> {
    return new Promise<Yanit>((coz, reddet) => {
      const zamanlayici = setTimeout(() => reddet(new Error(ZAMAN_ASIMI_METNI)), sure)
      a.fetch(a.url + yol, init).then(
        (y) => {
          clearTimeout(zamanlayici)
          coz(y as unknown as Yanit)
        },
        () => {
          clearTimeout(zamanlayici)
          reddet(new Error(AG_YOK_METNI))
        },
      )
    })
  }

  async function govdeOku(y: Yanit): Promise<unknown> {
    if (y.status === 204) return null
    try {
      return await y.json()
    } catch (e) {
      return null
    }
  }

  function basliklar(ek: Record<string, string> = {}): Record<string, string> {
    return {
      apikey: a.anahtar,
      Authorization: `Bearer ${bellek ? bellek.access_token : a.anahtar}`,
      ...ek,
    }
  }

  function oturumdan(g: unknown): Oturum {
    const d = g as { access_token: string; refresh_token: string; expires_in: number; user: { id: string } }
    return {
      access_token: d.access_token,
      refresh_token: d.refresh_token,
      expires_at: Math.floor(a.simdi() / 1000) + d.expires_in,
      user_id: d.user.id,
    }
  }

  // Calls running at the same time share one refresh: a rotated refresh token
  // sent twice could sign the device out.
  let suren: Promise<void> | null = null
  function yenile(): Promise<void> {
    if (!suren) {
      suren = yenileBir().then(
        () => {
          suren = null
        },
        (e: unknown) => {
          suren = null
          throw e
        },
      )
    }
    return suren
  }

  async function yenileBir(): Promise<void> {
    const eski = bellek
    if (!eski) throw new OturumBitti(OTURUM_BITTI_METNI)
    const y = await istek('/auth/v1/token?grant_type=refresh_token', {
      method: 'POST',
      headers: { apikey: a.anahtar, 'Content-Type': 'application/json' },
      body: JSON.stringify({ refresh_token: eski.refresh_token }),
    })
    if (!y.ok) {
      yaz(null)
      throw new OturumBitti(OTURUM_BITTI_METNI)
    }
    yaz(oturumdan(await govdeOku(y)))
  }

  /** A data call: refresh shortly before expiry, and once more on a 401. */
  async function cagir(yol: string, init: RequestInit, fallback: string, edge = false): Promise<unknown> {
    if (bellek && bellek.expires_at - a.simdi() / 1000 < YENILEME_PAYI_SN) await yenile()
    let y = await istek(yol, { ...init, headers: basliklar(init.headers as Record<string, string>) })
    if (y.status === 401 && bellek) {
      await yenile()
      y = await istek(yol, { ...init, headers: basliklar(init.headers as Record<string, string>) })
      if (y.status === 401) {
        yaz(null)
        throw new OturumBitti(OTURUM_BITTI_METNI)
      }
    }
    const govde = await govdeOku(y)
    if (!y.ok) {
      const h = govde as { hata?: unknown } | null
      if (edge && h && typeof h.hata === 'string' && h.hata) throw new Error(h.hata)
      throw new Error(a.hataMetni(govde, fallback))
    }
    return govde
  }

  const JSON_BASLIK = { 'Content-Type': 'application/json' }

  return {
    async rpc<T>(ad: string, args: Record<string, unknown>) {
      return (await cagir(
        `/rest/v1/rpc/${ad}`,
        { method: 'POST', headers: JSON_BASLIK, body: JSON.stringify(args) },
        'İşlem yapılamadı.',
      )) as T
    },

    async sec<T>(tablo: string, sorgu: string) {
      return (await cagir(`/rest/v1/${tablo}?${sorgu}`, { method: 'GET' }, 'Veri alınamadı.')) as T[]
    },

    async fn<T>(ad: string, govde: unknown) {
      return (await cagir(
        `/functions/v1/${ad}`,
        { method: 'POST', headers: JSON_BASLIK, body: JSON.stringify(govde) },
        'İşlem yapılamadı.',
        true,
      )) as T
    },

    async yukle(kova: string, yol: string, veri: Blob | string, tur: string) {
      await cagir(
        `/storage/v1/object/${kova}/${yol}`,
        { method: 'POST', headers: { 'Content-Type': tur }, body: veri },
        'Dosya yüklenemedi.',
      )
    },

    async imzaliUrl(kova: string, yol: string, saniye: number) {
      const g = (await cagir(
        `/storage/v1/object/sign/${kova}/${yol}`,
        { method: 'POST', headers: JSON_BASLIK, body: JSON.stringify({ expiresIn: saniye }) },
        'Fotoğraf açılamadı.',
      )) as { signedURL: string }
      return `${a.url}/storage/v1${g.signedURL}`
    },

    async dogrula(tokenHash: string) {
      const y = await istek('/auth/v1/verify', {
        method: 'POST',
        headers: { apikey: a.anahtar, 'Content-Type': 'application/json' },
        body: JSON.stringify({ type: 'email', token_hash: tokenHash }),
      })
      if (!y.ok) throw new Error('Giriş yapılamadı. Tekrar deneyin.')
      const o = oturumdan(await govdeOku(y))
      yaz(o)
      return o
    },

    async sifreyleGir(eposta: string, sifre: string) {
      const y = await istek('/auth/v1/token?grant_type=password', {
        method: 'POST',
        headers: { apikey: a.anahtar, 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: eposta, password: sifre }),
      })
      if (!y.ok) throw new Error('E-posta ya da şifre yanlış.')
      const o = oturumdan(await govdeOku(y))
      yaz(o)
      return o
    },

    async cikis() {
      const o = bellek
      // Local first: the device must be signed out even with no network.
      yaz(null)
      if (!o) return
      try {
        await istek('/auth/v1/logout', {
          method: 'POST',
          headers: { apikey: a.anahtar, Authorization: `Bearer ${o.access_token}` },
        })
      } catch (e) {
        // The token expires on its own.
      }
    },

    oturum() {
      return bellek
    },
  }
}
