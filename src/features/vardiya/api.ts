import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type { Vardiya, VardiyaKapatSonuc, VardiyaOzet } from '../../lib/types'

/**
 * The open TILL shift — one per car park, not one per person (030).
 *
 * rpc -> TABLE, and it returns ZERO rows when no shift is open. That empty
 * case is normal, not an error: before the day starts there is nothing to
 * summarise.
 */
export function useVardiyaOzetim() {
  return useQuery({
    queryKey: ['vardiya_ozetim'],
    queryFn: async (): Promise<VardiyaOzet | null> => {
      const { data, error } = await supabase.rpc('vardiya_ozetim')
      if (error) throw error
      return ((data ?? [])[0] as VardiyaOzet) ?? null
    },
    staleTime: 10_000,
    refetchInterval: 60_000,
  })
}

/**
 * Closed shifts. Yönetici only, and RLS enforces that.
 *
 * Since 030 a shift belongs to the till rather than to a person, so its
 * history is the business's cash record — not something an operator may
 * page through. `enabled` mirrors the policy so Personel does not fire a
 * query that is guaranteed to come back empty.
 */
export function useVardiyalarim(enabled = true) {
  return useQuery({
    enabled,
    queryKey: ['vardiyalarim'],
    queryFn: async (): Promise<Vardiya[]> => {
      const { data, error } = await supabase
        .from('vardiyalar')
        .select('*')
        .not('kapanis_at', 'is', null)
        .order('acilis_at', { ascending: false })
        .limit(30)
      if (error) throw error
      return data as Vardiya[]
    },
  })
}

export function useVardiyaAc() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (acilisNakitKurus: number): Promise<string> => {
      const { data, error } = await supabase.rpc('vardiya_ac', {
        p_acilis_nakit_kurus: acilisNakitKurus,
      })
      if (error) throw error
      return data as string // rpc -> scalar uuid
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['vardiya_ozetim'] })
    },
  })
}

export function useVardiyaKapat() {
  const qc = useQueryClient()
  return useMutation({
    // Closing counts the drawer and can raise a discrepancy alert. Retrying it
    // blind would re-run that decision against a shift that is already closed.
    retry: false,
    mutationFn: async ({
      sayilan,
      notlar,
    }: {
      sayilan: number
      notlar: string | null
    }): Promise<VardiyaKapatSonuc> => {
      const { data, error } = await supabase.rpc('vardiya_kapat', {
        p_sayilan_nakit_kurus: sayilan,
        p_notlar: notlar,
      })
      if (error) throw error
      const row = (data ?? [])[0] as VardiyaKapatSonuc | undefined
      if (!row) throw new Error('Vardiya sonucu alınamadı.')
      return row
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['vardiya_ozetim'] })
      void qc.invalidateQueries({ queryKey: ['vardiyalarim'] })
    },
  })
}
