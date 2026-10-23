/**
 * The plate-reading models the settings screen offers.
 *
 * Must equal VLM_MODELS in supabase/functions/_shared/vlm.ts — the server's
 * allowlist decides what is accepted, this decides what can be picked.
 * tests/vlm.check.mjs fails if the two lists differ. No imports, so that check
 * can load this file with plain Node.
 */
export interface PlakaModeli {
  id: string
  etiket: string
  aciklama: string
  onerilen?: boolean
}

export const PLAKA_MODELLERI: readonly PlakaModeli[] = [
  {
    id: 'claude-haiku-5-5',
    etiket: 'Claude Haiku 5.5',
    aciklama: 'Önerilen. Haiku 4.5’ten yaklaşık %85 daha ucuz.',
    onerilen: true,
  },
  {
    id: 'claude-haiku-4-5',
    etiket: 'Claude Haiku 4.5',
    aciklama: 'Önceki model.',
  },
  {
    id: 'claude-sonnet-5-5',
    etiket: 'Claude Sonnet 5.5',
    aciklama: 'En iyi okuma. Okuma başına Haiku 5.5’ten yaklaşık 20 kat pahalı.',
  },
  {
    id: 'claude-sonnet-5',
    etiket: 'Claude Sonnet 5',
    aciklama: 'Sonnet 5.5’ten önceki sürüm.',
  },
]

/** What an empty `plaka_model` means on the server (DEFAULT_VLM). */
export const VARSAYILAN_PLAKA_MODELI = 'claude-haiku-4-5'

/**
 * A stored `plaka_model` in words, for the picker and the save confirmation.
 *
 * A value outside the list is named as invalid rather than hidden: the server
 * quietly reads with the default in that case, and the screen must not let
 * that look like a deliberate choice.
 */
export function plakaModeliMetni(id: string | null): string {
  if (!id) {
    const v = PLAKA_MODELLERI.find((m) => m.id === VARSAYILAN_PLAKA_MODELI)
    return `Varsayılan (${v ? v.etiket : VARSAYILAN_PLAKA_MODELI})`
  }
  const m = PLAKA_MODELLERI.find((x) => x.id === id)
  return m ? m.etiket : `${id} (geçersiz — varsayılan kullanılıyor)`
}
