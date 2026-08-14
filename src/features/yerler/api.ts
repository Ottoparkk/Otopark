import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { gunAraligi } from '../../lib/aralik'
import type { ParkYeri, ParkYeriTip, Rezervasyon } from '../../lib/types'

/**
 * The management view of the car park's spots.
 *
 * `useParkYerleri` in features/gise only returns ACTIVE spots, because a gate
 * operator must never be offered a spot that no longer exists. This one
 * returns everything, so a retired spot can be brought back.
 */
export function useTumParkYerleri() {
  return useQuery({
    queryKey: ['park_yerleri', 'tum'],
    queryFn: async (): Promise<ParkYeri[]> => {
      const { data, error } = await supabase.from('park_yerleri').select('*').order('kod')
      if (error) throw error
      return data as ParkYeri[]
    },
  })
}

/** Which spots currently hold a car, so a spot is never retired blind. */
export function useDoluYerler() {
  return useQuery({
    queryKey: ['dolu_yerler'],
    queryFn: async (): Promise<Record<string, string>> => {
      const { data, error } = await supabase
        .from('biletler')
        .select('park_yeri_id, plaka')
        .eq('durum', 'ACIK')
        .not('park_yeri_id', 'is', null)
      if (error) throw error
      const harita: Record<string, string> = {}
      for (const r of (data ?? []) as { park_yeri_id: string | null; plaka: string }[]) {
        if (r.park_yeri_id) harita[r.park_yeri_id] = r.plaka
      }
      return harita
    },
    staleTime: 15_000,
  })
}

function useYerInvalidate() {
  const qc = useQueryClient()
  // The prefix matches both ['park_yerleri'] and ['park_yerleri','tum'], so
  // the gate's spot picker refreshes along with this screen.
  return () => void qc.invalidateQueries({ queryKey: ['park_yerleri'] })
}

export interface YerGirdi {
  kod: string
  tip: ParkYeriTip
  rezerve: boolean
}

export function useYerEkle() {
  const invalidate = useYerInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async (g: YerGirdi) => {
      const { error } = await supabase.from('park_yerleri').insert(g)
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

export function useYerGuncelle() {
  const invalidate = useYerInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async ({ id, ...yama }: Partial<ParkYeri> & { id: string }) => {
      const { error } = await supabase.from('park_yerleri').update(yama).eq('id', id)
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

/* ========================================================= reservations === */

export interface RezervasyonSatir extends Rezervasyon {
  park_yeri: { kod: string } | null
}

export function useRezervasyonlar() {
  return useQuery({
    queryKey: ['rezervasyonlar'],
    queryFn: async (): Promise<RezervasyonSatir[]> => {
      const { data, error } = await supabase
        .from('rezervasyonlar')
        .select('*, park_yeri:park_yerleri(kod)')
        .order('created_at', { ascending: false })
        .limit(200)
      if (error) throw error
      return data as RezervasyonSatir[]
    },
  })
}

function useRezervasyonInvalidate() {
  const qc = useQueryClient()
  return () => void qc.invalidateQueries({ queryKey: ['rezervasyonlar'] })
}

/**
 * The overlap check is NOT done here.
 *
 * `rezervasyonlar_cakisma_ex` refuses a double-booked spot in the database,
 * which is the only place it can be refused correctly — two operators can
 * always race, and a client-side check would pass for both of them.
 */
export function useRezervasyonEkle() {
  const invalidate = useRezervasyonInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async (g: {
      park_yeri_id: string
      plaka: string
      bas_gun: string
      bit_gun: string
      notlar: string | null
    }) => {
      const { error } = await supabase.from('rezervasyonlar').insert({
        park_yeri_id: g.park_yeri_id,
        plaka: g.plaka,
        gecerlilik: gunAraligi(g.bas_gun, g.bit_gun),
        notlar: g.notlar,
      })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

export function useRezervasyonSil() {
  const invalidate = useRezervasyonInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('rezervasyonlar').delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}
