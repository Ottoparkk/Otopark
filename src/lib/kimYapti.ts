import type { OnayDurum } from './types'

// Who did it (063, owner 2026-11-15): every money record says who collected
// it, who approved or rejected it, who entered a kasa line. Only the Yönetici
// sees these lines. The screens build them here so every screen words them
// the same way.
//
// Rule: an unknown person is never shown as a WRONG name. A missing approver
// gives no line at all; an id that no longer resolves reads "Bilinmiyor".
// Type-only imports: `node tests/kimYapti.check.mjs` runs this file directly.

/** One "Etiket: Ad · zaman" line. `zaman` is an ISO timestamp or null. */
export interface KimSatiri {
  etiket: string
  ad: string
  zaman: string | null
}

/**
 * A profile id → its name. Null for no id (or a column the server does not
 * send yet); "Bilinmiyor" for an id that no longer resolves.
 */
export function adCoz(id: string | null | undefined, adlar: Map<string, string>): string | null {
  if (!id) return null
  return adlar.get(id) ?? 'Bilinmiyor'
}

/**
 * A payment's people: who collected it ("Geri alan" for a counter-entry),
 * then — once decided — "Onaylayan" or "Reddeden". A pending payment has no
 * second line, and neither has one a reversal rejected on its own (017's
 * trigger sets no approver). Names are already resolved; a null collector is
 * a system write ("Otomatik", as `onay_listesi` says too).
 */
export function tahsilatKisileri(t: {
  tutar_kurus: number
  iptal_of?: string | null
  durum: OnayDurum
  toplayan: string | null
  onaylayan?: string | null
  onay_at?: string | null
}): KimSatiri[] {
  const geriAlma = (t.iptal_of ?? null) !== null || t.tutar_kurus < 0
  const satirlar: KimSatiri[] = [
    { etiket: geriAlma ? 'Geri alan' : 'Ödeme toplayan', ad: t.toplayan ?? 'Otomatik', zaman: null },
  ]
  if (t.durum !== 'BEKLIYOR' && t.onaylayan) {
    satirlar.push({
      etiket: t.durum === 'ONAYLANDI' ? 'Onaylayan' : 'Reddeden',
      ad: t.onaylayan,
      zaman: t.onay_at ?? null,
    })
  }
  return satirlar
}

/** A kasa line's "Kaydeden"; null when nobody was recorded (pre-063 rows). */
export function kaydedenSatiri(ad: string | null, duzenli: boolean): KimSatiri | null {
  if (!ad) return null
  return { etiket: 'Kaydeden', ad: duzenli ? `${ad} (düzenli)` : ad, zaman: null }
}

/** A shift-close or ticket-cancel decision: "İsteyen", then "Onaylayan"/"Reddeden". */
export function kararKisileri(k: {
  sonuc: 'ONAY' | 'RET'
  karar_at: string
  isteyen: string | null
  karar_veren: string | null
}): KimSatiri[] {
  const satirlar: KimSatiri[] = []
  if (k.isteyen) satirlar.push({ etiket: 'İsteyen', ad: k.isteyen, zaman: null })
  if (k.karar_veren) {
    satirlar.push({
      etiket: k.sonuc === 'ONAY' ? 'Onaylayan' : 'Reddeden',
      ad: k.karar_veren,
      zaman: k.karar_at,
    })
  }
  return satirlar
}

/** The audit_log columns this file reads (a subset of kararlar.ts's AuditSatiri). */
export interface KararAuditSatiri {
  actor: string | null
  action: string
  row_id: string | null
  detay?: unknown
  created_at: string
}

export interface SonKarar {
  action: string
  actor: string | null
  created_at: string
  /** `detay.talep_eden` when the decision answered a request (035, 050). */
  talep_eden: string | null
}

/**
 * The LATEST decision per row among `actions`, whatever order the rows come
 * in. A malformed `detay` gives a null requester, never a crash.
 */
export function sonKararHaritasi(
  satirlar: KararAuditSatiri[],
  actions: string[],
): Map<string, SonKarar> {
  const harita = new Map<string, SonKarar>()
  for (const s of satirlar) {
    if (!s.row_id || !actions.includes(s.action)) continue
    const onceki = harita.get(s.row_id)
    if (onceki && onceki.created_at >= s.created_at) continue
    const d = s.detay
    const talep =
      d !== null && typeof d === 'object' && !Array.isArray(d)
        ? (d as Record<string, unknown>).talep_eden
        : null
    harita.set(s.row_id, {
      action: s.action,
      actor: s.actor ?? null,
      created_at: s.created_at,
      talep_eden: typeof talep === 'string' && talep !== '' ? talep : null,
    })
  }
  return harita
}

/**
 * Who ended a shift from the Yönetici's side: approved a close request
 * ("Onaylayan") or force-closed it ("Kapatan"). No decision or a deleted
 * profile → no line.
 */
export function vardiyaKapatanSatiri(
  karar: Pick<SonKarar, 'action' | 'created_at'> | undefined,
  ad: string | null,
): KimSatiri | null {
  if (!karar || !ad) return null
  return {
    etiket: karar.action === 'vardiya_zorla_kapat' ? 'Kapatan' : 'Onaylayan',
    ad,
    zaman: karar.created_at,
  }
}
