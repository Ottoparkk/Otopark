/**
 * Giriş on the P2 (spec 2026-11-28): read the plate from a photo, then open
 * the ticket with the same bilet_ac call as src/features/gise/api.ts. The
 * read is only a suggestion; nothing is saved until a person taps Giriş aç.
 * Type-only imports; helpers come in as `araclar`
 * (tests/terminalGiris.check.mjs).
 */
import type { normalizePlaka, plakaGecerli } from '../../src/lib/plaka'
import type { PlakaOkumaSonuc } from '../../src/lib/types'
import type { Sunucu } from './sunucu'

export interface OkumaSonucu {
  plaka: string | null
  log_id: string | null
}

export interface GirisAraclari {
  normalizePlaka: typeof normalizePlaka
  plakaGecerli: typeof plakaGecerli
  fotoYolu: (yon: 'giris', plaka: string) => string
}

export interface GirisGirdisi {
  plaka: string
  /** The form's idempotency key; renewed after a ticket opens (as Giris.tsx). */
  islemId: string
  kanit: Blob | string | null
  okuma: OkumaSonucu | null
  aracBilgi: string | null
}

export async function plakaOku(s: Sunucu, okumaBase64: string): Promise<OkumaSonucu> {
  const g = await s.fn<PlakaOkumaSonuc & { hata?: string }>('plaka-oku', {
    foto_base64: okumaBase64,
    media_type: 'image/jpeg',
  })
  if (g && g.hata) throw new Error(g.hata)
  return { plaka: g.plaka, log_id: g.log_id }
}

// A double tap (or a tap while the first is still on its way) opens ONE ticket.
let suren: Promise<{ biletId: string; uyari: string | null }> | null = null

export function girisAc(
  s: Sunucu,
  g: GirisGirdisi,
  a: GirisAraclari,
): Promise<{ biletId: string; uyari: string | null }> {
  if (suren) return suren
  const p = girisAcBir(s, g, a)
  suren = p
  const bitir = () => {
    if (suren === p) suren = null
  }
  p.then(bitir, bitir)
  return p
}

async function girisAcBir(
  s: Sunucu,
  g: GirisGirdisi,
  a: GirisAraclari,
): Promise<{ biletId: string; uyari: string | null }> {
  const plaka = a.normalizePlaka(g.plaka)
  if (!a.plakaGecerli(plaka)) throw new Error('Plakayı kontrol edin.')

  let foto: string | null = null
  let uyari: string | null = null
  if (g.kanit) {
    const yol = a.fotoYolu('giris', plaka)
    try {
      await s.yukle('plaka-foto', yol, g.kanit, 'image/jpeg')
      foto = yol
    } catch (e) {
      uyari = 'Fotoğraf yüklenemedi, kayıt fotoğrafsız açıldı.'
    }
  }

  const bilgi = g.aracBilgi ? g.aracBilgi.trim() : ''
  const biletId = await s.rpc<string>('bilet_ac', {
    p_plaka: plaka,
    p_islem_id: g.islemId,
    // MOBIL: the server ignores any client time and uses its own clock.
    p_kaynak: 'MOBIL',
    p_zaman: null,
    p_foto: foto,
    p_park_yeri_id: null,
    p_ham_yanit: null,
    p_arac_bilgi: bilgi || null,
    p_musteri_ad: null,
    p_musteri_tel: null,
    p_notlar: null,
  })

  // The accuracy record (plate read vs plate kept); never blocks the entry.
  if (g.okuma && g.okuma.log_id) {
    try {
      await s.rpc('bilet_okuma_bagla', { p_bilet_id: biletId, p_okuma_id: g.okuma.log_id, p_kabul: plaka })
    } catch (e) {
      /* ignore */
    }
  }
  return { biletId, uyari }
}
