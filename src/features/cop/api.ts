import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'

/**
 * The recycle bin.
 *
 * Every delete in the app routes through an RPC that snapshots the row first
 * (migration 007), so this file never deletes anything directly — a client
 * `.delete()` would bypass both the snapshot and the money reversal, which is
 * why 007 revokes the DELETE grants those calls used to rely on.
 *
 * `cop` is Yönetici-only in RLS; the route guard is UX.
 */

export interface CopKaydi {
  id: string
  tablo: string
  kayit_id: string
  ozet: string
  silen: string | null
  silindi_at: string
  silen_profil: { ad_soyad: string } | null
}

/** Turkish names for the record types the bin can hold. */
export const COP_TABLO_ETIKET: Record<string, string> = {
  biletler: 'Bilet',
  abonmanlar: 'Abonman',
  kasa_hareketleri: 'Kasa hareketi',
  park_yerleri: 'Park yeri',
  rezervasyonlar: 'Rezervasyon',
  hesaplar: 'Puan hesabı',
  hesap_araclari: 'Hesap aracı',
  istisnalar: 'Çözülmemiş kayıt',
  tarifeler: 'Tarife',
}

export function useCop() {
  return useQuery({
    queryKey: ['cop'],
    queryFn: async (): Promise<CopKaydi[]> => {
      const { data, error } = await supabase
        .from('cop')
        .select('id, tablo, kayit_id, ozet, silen, silindi_at, silen_profil:profiles(ad_soyad)')
        .order('silindi_at', { ascending: false })
      if (error) throw error
      return data as unknown as CopKaydi[]
    },
  })
}

/**
 * Restoring can put money back, so everything the deletion touched has to be
 * re-read: the ticket lists, the reports, the shift whose variance moved.
 *
 * These are the real query-key roots, checked against every `queryKey` in
 * `src/features` — a key that matches nothing invalidates nothing, and the
 * screen quietly keeps showing the pre-delete number. Shifts are the ones
 * that must not be missed: `bilet_sil` recomputes a shift's cash variance
 * server-side, so a stale `tum_vardiyalar` is a wrong money figure on screen.
 */
function useCopInvalidate() {
  const qc = useQueryClient()
  return () => {
    for (const k of [
      'cop',
      // tickets and everything derived from them
      'acik_biletler',
      'cikan_biletler',
      'bilet',
      'bilet_gecmisi',
      'gunluk_ozet',
      // money
      'kasa',
      'rapor_ozet',
      'rapor_gunluk',
      'rapor_detay',
      'ilk_gun',
      // shifts — a deleted ticket changes the counted-cash variance
      'tum_vardiyalar',
      'vardiyalarim',
      'vardiya_ozetim',
      // subscriptions
      'abonmanlar',
      'abonman',
      'abonman_tahsilat',
      'abonman_kontrol',
      // spots and reservations
      'park_yerleri',
      'dolu_yerler',
      'rezervasyonlar',
      // loyalty
      'hesap_ozet',
      'hesap',
      'hesap_bakiye',
      'hesap_araclari',
      'puan_hareketleri',
      'puan_durumu',
      // unresolved events
      'istisnalar',
      'istisna_sayisi',
      // tariffs
      'tarifeler',
    ]) {
      void qc.invalidateQueries({ queryKey: [k] })
    }
  }
}

export function useCopGeriAl() {
  const invalidate = useCopInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async (cop_id: string) => {
      const { error } = await supabase.rpc('cop_geri_al', { p_cop_id: cop_id })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

export function useCopKaliciSil() {
  const invalidate = useCopInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async (cop_id: string) => {
      const { error } = await supabase.rpc('cop_kalici_sil', { p_cop_id: cop_id })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

/* ============================================================== deletes === */

/** Deletes a ticket AND reverses everything it collected (007). */
export function useBiletSil() {
  const invalidate = useCopInvalidate()
  return useMutation({
    retry: false, // it moves money
    mutationFn: async (bilet_id: string) => {
      const { error } = await supabase.rpc('bilet_sil', { p_bilet_id: bilet_id })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

export function useAbonmanSil() {
  const invalidate = useCopInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async (abonman_id: string) => {
      const { error } = await supabase.rpc('abonman_sil', { p_abonman_id: abonman_id })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

export function useTarifeSil() {
  const invalidate = useCopInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async (tarife_id: string) => {
      const { error } = await supabase.rpc('tarife_sil', { p_tarife_id: tarife_id })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

/**
 * The plain records. `tablo` is checked against a fixed allowlist inside the
 * RPC as well — this type only stops a typo reaching the network.
 */
export type SilinebilirTablo =
  | 'kasa_hareketleri'
  | 'park_yerleri'
  | 'rezervasyonlar'
  | 'hesaplar'
  | 'hesap_araclari'
  | 'istisnalar'

export function useKayitSil() {
  const invalidate = useCopInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async ({ tablo, id }: { tablo: SilinebilirTablo; id: string }) => {
      const { error } = await supabase.rpc('kayit_sil', { p_tablo: tablo, p_id: id })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}
