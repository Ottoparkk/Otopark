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

/**
 * The open shift row itself, for the one thing `vardiya_ozetim()` does not
 * carry: whether a close request is waiting on it (035).
 *
 * Read straight from the table rather than by widening the RPC. Changing that
 * function's return type means drop + re-grant, and 032 exists because the
 * re-grant was missed once already — a plain SELECT the policy already allows
 * (staff see the OPEN shift) costs nothing and risks nothing.
 */
export function useAcikVardiya() {
  return useQuery({
    queryKey: ['acik_vardiya'],
    queryFn: async (): Promise<Vardiya | null> => {
      const { data, error } = await supabase
        .from('vardiyalar')
        .select('*')
        .is('kapanis_at', null)
        .maybeSingle()
      if (error) throw error
      return (data as Vardiya) ?? null
    },
    staleTime: 10_000,
    refetchInterval: 60_000,
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
      void qc.invalidateQueries({ queryKey: ['acik_vardiya'] })
    },
  })
}

export function useVardiyaKapat() {
  const qc = useQueryClient()
  return useMutation({
    // Counting the drawer can raise a discrepancy alert, and for a Personel it
    // files a request a Yönetici will read. Retrying it blind would re-run
    // that against a shift that has already moved on.
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
      // The request lands on the open shift row, so this is what makes the
      // "waiting for approval" banner appear without a reload.
      void qc.invalidateQueries({ queryKey: ['acik_vardiya'] })
      void qc.invalidateQueries({ queryKey: ['vardiya_talepleri'] })
    },
  })
}
