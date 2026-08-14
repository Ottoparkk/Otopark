import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type { Vardiya, VardiyaKapatSonuc, VardiyaOzet } from '../../lib/types'

/**
 * rpc -> TABLE, and it returns ZERO rows when there is no open shift. That
 * empty case is normal, not an error: an operator who has not clocked in yet
 * simply has nothing to summarise.
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

/** Own past shifts. RLS limits this to the caller unless they are Yönetici. */
export function useVardiyalarim() {
  return useQuery({
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
