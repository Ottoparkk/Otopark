import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { useAuth } from '../../app/providers/AuthProvider'
import { fisYazdirir } from './fisIste'
import { parcala } from './fisSecenek'
import type { Tarife } from '../../lib/types'

/** Whether this account gets the fiş buttons (Personel, owner 28.11). */
export function useFisYazdirir(): boolean {
  return fisYazdirir(useAuth().profile)
}

/** One print of a fiş (088 `fis_basimlari`). */
export interface FisBasimi {
  id: string
  bilet_id: string
  tur: 'GIRIS' | 'CIKIS'
  basan: string | null
  tahmin_dk: number | null
  created_at: string
}

export type FisTur = FisBasimi['tur']

/**
 * Records a print and returns its number for this ticket and type (1 = first,
 * 2+ prints "TEKRAR BASIM"). `returns integer` → a bare scalar. The server
 * refuses an exit fiş while money is owed or the 082 decision is pending —
 * its Turkish text is what the sheet shows.
 */
export function useFisBasildi() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (v: { biletId: string; tur: FisTur; tahminDk: number | null }): Promise<number> => {
      const { data, error } = await supabase.rpc('fis_basildi', {
        p_bilet_id: v.biletId,
        p_tur: v.tur,
        p_tahmin_dk: v.tahminDk,
      })
      if (error) throw error
      return data as number
    },
    onSuccess: (_n, v) => {
      void qc.invalidateQueries({ queryKey: ['fis_basimlari', v.biletId] })
      void qc.invalidateQueries({ queryKey: ['giris_fisleri'] })
    },
  })
}

/**
 * The tariff the ticket was priced with — its own snapshot (`tarife_id`), not
 * today's active one, so the choices match what the car will really pay.
 */
export function useBiletTarifesi(tarifeId: string | undefined) {
  return useQuery({
    queryKey: ['tarife', tarifeId],
    enabled: Boolean(tarifeId),
    staleTime: 5 * 60_000,
    queryFn: async (): Promise<Pick<Tarife, 'id' | 'tur' | 'kademeler'>> => {
      const { data, error } = await supabase
        .from('tarifeler')
        .select('id, tur, kademeler')
        .eq('id', tarifeId!)
        .single()
      if (error) throw error
      return data as Pick<Tarife, 'id' | 'tur' | 'kademeler'>
    },
  })
}

/**
 * The entry fiş's estimates, priced by the server at the full tariff (088
 * `fis_tahmini`). `returns table` → an array of rows. Map minute → kuruş.
 * The server takes at most 6 minutes a call, so longer lists go in parts.
 */
export function useFisTahmini(biletId: string | undefined, dakikalar: number[], enabled: boolean) {
  return useQuery({
    queryKey: ['fis_tahmini', biletId, dakikalar],
    enabled: enabled && Boolean(biletId) && dakikalar.length > 0,
    staleTime: 60_000,
    queryFn: async (): Promise<Map<number, number>> => {
      const m = new Map<number, number>()
      for (const parca of parcala(dakikalar, 6)) {
        const { data, error } = await supabase.rpc('fis_tahmini', {
          p_bilet_id: biletId!,
          p_dakikalar: parca,
        })
        if (error) throw error
        for (const r of data as { dakika: number; kurus: number }[]) m.set(r.dakika, r.kurus)
      }
      return m
    },
  })
}

/** A ticket's prints, oldest first (the detail screen's "Fiş: 14:05 · 2 kez"). */
export function useFisBasimlari(biletId: string | undefined, enabled = true) {
  return useQuery({
    queryKey: ['fis_basimlari', biletId],
    enabled: enabled && Boolean(biletId),
    queryFn: async (): Promise<FisBasimi[]> => {
      const { data, error } = await supabase
        .from('fis_basimlari')
        .select('*')
        .eq('bilet_id', biletId!)
        .order('created_at')
      if (error) throw error
      return data as FisBasimi[]
    },
  })
}

/**
 * Which of these tickets already have an entry fiş — Gişe marks recent camera
 * entries without one ("Gişe asks to print", owner 28.11).
 */
export function useGirisFisleri(biletIdleri: string[], enabled: boolean) {
  const ids = [...biletIdleri].sort()
  return useQuery({
    queryKey: ['giris_fisleri', ids],
    enabled: enabled && ids.length > 0,
    staleTime: 30_000,
    queryFn: async (): Promise<Set<string>> => {
      const { data, error } = await supabase
        .from('fis_basimlari')
        .select('bilet_id')
        .eq('tur', 'GIRIS')
        .in('bilet_id', ids)
      if (error) throw error
      return new Set((data as { bilet_id: string }[]).map((r) => r.bilet_id))
    },
  })
}
