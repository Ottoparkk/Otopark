import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type { Istisna } from '../../lib/types'
import { useGiseInvalidate } from '../gise/api'

/**
 * Events that could not become a ticket.
 *
 * Staff-readable on purpose: two of the four kinds — an exit with no open
 * ticket, and a plate matching several — are everyday typo problems rather
 * than camera problems, and they happen at the gate where they must be fixed.
 * The rows carry no financial data.
 */
export function useIstisnalar(sadeceAcik: boolean) {
  return useQuery({
    queryKey: ['istisnalar', sadeceAcik],
    queryFn: async (): Promise<Istisna[]> => {
      let q = supabase
        .from('istisnalar')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(200)
      if (sadeceAcik) q = q.is('cozuldu_at', null)
      const { data, error } = await q
      if (error) throw error
      return data as Istisna[]
    },
    refetchInterval: 60_000,
  })
}

/** Unresolved count, for the badge on the vehicles screen. */
export function useAcikIstisnaSayisi() {
  return useQuery({
    queryKey: ['istisna_sayisi'],
    queryFn: async (): Promise<number> => {
      const { count, error } = await supabase
        .from('istisnalar')
        .select('id', { count: 'exact', head: true })
        .is('cozuldu_at', null)
      if (error) throw error
      return count ?? 0
    },
    staleTime: 30_000,
    refetchInterval: 120_000,
  })
}

/**
 * Marking one resolved is an RPC, not an UPDATE: `istisnalar` has no write
 * policy at all, so who resolved it and when are stamped server-side and
 * cannot be back-dated from a client.
 */
export function useIstisnaCoz() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async ({ id, not }: { id: string; not: string | null }) => {
      const { error } = await supabase.rpc('istisna_coz', { p_id: id, p_not: not })
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['istisnalar'] })
      void qc.invalidateQueries({ queryKey: ['istisna_sayisi'] })
    },
  })
}

export interface IstisnaBiletSonuc {
  bilet_id: string
  plaka: string
  yer_kod: string | null
  /** The camera (or an earlier tap) had already opened this event's ticket. */
  zaten_vardi: boolean
}

/**
 * One tap on an unreadable plate: opens the entry ticket at the moment the
 * camera saw the car and closes the card, in one transaction (044). No
 * automatic retry: a refusal ("plate already inside") must reach the operator
 * as it is, and a repeated tap is safe — the server answers it with the same
 * ticket.
 */
export function useIstisnaBiletAc() {
  const qc = useQueryClient()
  const giseYenile = useGiseInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async ({ id, plaka }: { id: string; plaka: string }) => {
      const { data, error } = await supabase.rpc('istisna_bilet_ac', { p_id: id, p_plaka: plaka })
      if (error) throw error
      return data as IstisnaBiletSonuc
    },
    onSettled: () => {
      // Settled, not success: on a refusal the row may still have changed
      // under us (another tap, a camera retry) and the list must show it.
      void qc.invalidateQueries({ queryKey: ['istisnalar'] })
      void qc.invalidateQueries({ queryKey: ['istisna_sayisi'] })
      giseYenile()
    },
  })
}
