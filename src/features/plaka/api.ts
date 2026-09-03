import { useMutation } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { compressForOcr, fileToBase64, ocrMaxEdge } from '../../lib/image'
import type { PlakaOkumaSonuc } from '../../lib/types'
import { useAyarlar } from '../gise/api'

/**
 * The two halves of a read, as the operator experiences them.
 *
 * `HAZIRLIK` is entirely local: decoding a 12 MP photo and resizing it to the
 * model's resolution cap costs seconds of phone CPU before a single byte is
 * sent. Reporting both halves as one "Okunuyor…" made that stretch look like a
 * slow network, and a wait the operator cannot account for reads as a hang.
 */
export type OkumaAsamasi = 'HAZIRLIK' | 'OKUMA'

/**
 * Plate OCR. The result is a SUGGESTION and nothing else — it prefills a
 * focused input the operator must confirm. Nothing bills until a human
 * commits, which is what stops a hallucinated plate becoming a wrong charge.
 */
export function usePlakaOku() {
  // Which model is configured decides how much image is worth sending. The
  // settings row is already fetched with select('*'), so this costs no extra
  // query and adds no column to any select list.
  const { data: ayarlar } = useAyarlar()

  return useMutation({
    // No retry: a second call is a second API charge, and the operator can
    // simply take another photo if the first one was bad.
    retry: false,
    mutationFn: async ({
      file,
      onAsama,
    }: {
      file: File
      /** Optional: the caller may show which half of the wait it is in. */
      onAsama?: (asama: OkumaAsamasi) => void
    }): Promise<PlakaOkumaSonuc> => {
      // The GENTLE profile — heavy JPEG compression makes text hard to read,
      // and a plate read is text reading. The evidence copy is compressed
      // separately and much harder.
      onAsama?.('HAZIRLIK')
      const hazir = await compressForOcr(file, ocrMaxEdge(ayarlar?.plaka_model))
      const foto_base64 = await fileToBase64(hazir)

      onAsama?.('OKUMA')
      const { data, error } = await supabase.functions.invoke('plaka-oku', {
        body: { foto_base64, media_type: 'image/jpeg' },
      })
      if (error) throw error
      if ((data as { hata?: string })?.hata) {
        throw new Error((data as { hata: string }).hata)
      }
      return data as PlakaOkumaSonuc
    },
  })
}

/**
 * Records what the operator actually confirmed against what the model
 * suggested. This single write is the whole accuracy measurement: after a
 * month, `onerilen` vs `kabul_edilen` is a real hit rate, which is how the
 * provider decision gets re-made with data instead of re-argued.
 *
 * Deliberately fire-and-forget — a failure here must never interfere with
 * opening a ticket.
 */
export function usePlakaKabul() {
  return useMutation({
    retry: false,
    mutationFn: async ({ log_id, kabul }: { log_id: string; kabul: string }) => {
      const { error } = await supabase.rpc('plaka_okuma_kabul', {
        p_log_id: log_id,
        p_kabul: kabul,
      })
      if (error) throw error
    },
  })
}
