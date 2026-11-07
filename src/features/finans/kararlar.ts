/**
 * Onay ekranı — the pure parts: decided Vardiya / Bilet iptali requests read
 * back from `audit_log`, which card is open first, and the caption of the
 * Finans "Onay" card.
 *
 * Why audit_log: a decided request leaves no row of its own — approving a
 * close closes the shift, rejecting it erases the request (035); the same is
 * true of ticket-cancel requests (050). The audit entry written inside the
 * same RPC is the only record of the decision, and it is Yönetici-only to
 * read (`audit_select`), which is exactly who sees this screen.
 *
 * `detay` is jsonb written by SQL, so every field is checked rather than
 * trusted: an unexpected shape becomes null and the card shows a dash. It
 * never throws — a history list must not take the pending list down with it.
 *
 * No runtime imports (tests/kararlar.check.mjs imports this file directly).
 */

export type KararTur = 'VARDIYA' | 'BILET_IPTAL'
export type KararSonuc = 'ONAY' | 'RET'
export type OnayKategori = 'VARDIYA' | 'BILET' | 'BILET_IPTAL'

/** The action names the RPCs write (035, 050). One place, so a typo cannot hide history. */
export const KARAR_AKSIYONLARI: Record<KararTur, Record<KararSonuc, string>> = {
  VARDIYA: { ONAY: 'vardiya_kapatma_onay', RET: 'vardiya_kapatma_ret' },
  BILET_IPTAL: { ONAY: 'bilet_iptal_onay', RET: 'bilet_iptal_ret' },
}

export function kararAksiyonu(tur: KararTur, sonuc: KararSonuc): string {
  return KARAR_AKSIYONLARI[tur][sonuc]
}

/** The audit_log columns this module reads. */
export interface AuditSatiri {
  id: number | string
  actor: string | null
  action: string
  row_id: string | null
  detay?: unknown
  created_at: string
}

export interface Karar {
  id: string
  tur: KararTur
  sonuc: KararSonuc
  karar_at: string
  /** Who decided; null if that profile is gone. */
  karar_veren: string | null
  /** The shift or ticket the decision was about. */
  satir_id: string | null
  talep_eden: string | null
  /** Bilet iptali only. */
  plaka: string | null
  /** Bilet iptali: the requester's reason. */
  sebep: string | null
  /** The Yönetici's reason for a rejection. */
  ret_sebep: string | null
  /** Vardiya only: the counted cash. */
  sayilan_kurus: number | null
  /** Vardiya approval only: counted − expected. */
  fark_kurus: number | null
}

function nesne(v: unknown): Record<string, unknown> {
  return v !== null && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {}
}

function metin(v: unknown): string | null {
  if (typeof v !== 'string') return null
  const t = v.trim()
  return t === '' ? null : t
}

/** Integer kuruş only: a float or a string here means the row is not what we think. */
function kurus(v: unknown): number | null {
  return typeof v === 'number' && Number.isSafeInteger(v) ? v : null
}

function cozumle(action: string): { tur: KararTur; sonuc: KararSonuc } | null {
  for (const tur of Object.keys(KARAR_AKSIYONLARI) as KararTur[]) {
    for (const sonuc of ['ONAY', 'RET'] as const) {
      if (KARAR_AKSIYONLARI[tur][sonuc] === action) return { tur, sonuc }
    }
  }
  return null
}

/** One audit row → one decision card; null for any other action. */
export function kararSatiri(r: AuditSatiri): Karar | null {
  const c = cozumle(r.action)
  if (!c) return null
  const d = nesne(r.detay)
  const vardiya = c.tur === 'VARDIYA'
  return {
    id: String(r.id),
    tur: c.tur,
    sonuc: c.sonuc,
    karar_at: r.created_at,
    karar_veren: r.actor ?? null,
    satir_id: r.row_id ?? null,
    talep_eden: metin(d.talep_eden),
    plaka: vardiya ? null : metin(d.plaka),
    // The two migrations use "sebep" for different things: in 035's reject it
    // is the Yönetici's reason, in 050 it is always the requester's.
    sebep: vardiya ? null : metin(d.sebep),
    ret_sebep:
      c.sonuc !== 'RET' ? null : vardiya ? metin(d.sebep) : metin(d.ret_sebep),
    sayilan_kurus: vardiya ? kurus(d.sayilan) : null,
    fark_kurus: vardiya && c.sonuc === 'ONAY' ? kurus(d.fark) : null,
  }
}

/** First card with something waiting, in screen order; else Bilet ve abonman. */
export function varsayilanKategori(n: { vardiya: number; bilet: number; iptal: number }): OnayKategori {
  if (n.vardiya > 0) return 'VARDIYA'
  if (n.bilet > 0) return 'BILET'
  if (n.iptal > 0) return 'BILET_IPTAL'
  return 'BILET'
}

/** Caption of the Finans "Onay" card: every queue that is waiting, by name. */
export function onayAltYazisi(n: { tahsilat: number; vardiya: number; iptal: number }): string {
  const parcalar: string[] = []
  if (n.tahsilat > 0) parcalar.push(n.tahsilat + ' tahsilat')
  if (n.vardiya > 0) parcalar.push('vardiya kapatma')
  if (n.iptal > 0) parcalar.push(n.iptal + ' bilet iptali')
  if (parcalar.length === 0) return 'bekleyen yok'
  if (parcalar.length === 1) return parcalar[0] + ' bekliyor'
  return parcalar.join(' + ')
}
