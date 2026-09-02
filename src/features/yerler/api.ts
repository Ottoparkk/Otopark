import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { gunAraligi } from '../../lib/aralik'
import { yerleriSirala } from '../../lib/yerkodu'
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
      // Sorted here, not by the server: the codes pad to two digits, so plain
      // string ordering puts P-100 between P-10 and P-11. See lib/yerkodu.
      return yerleriSirala(data as ParkYeri[])
    },
  })
}

export interface DoluYer {
  /** The open ticket standing on the bay — what a move is addressed to. */
  bilet_id: string
  plaka: string
}

/**
 * Which spots currently hold a car, so a spot is never retired blind.
 *
 * It carries the TICKET id, not just the plate, because moving a car names
 * the ticket rather than the bay it is sitting on. Addressing the bay instead
 * would let a stale grid move whichever car happens to be there now; naming
 * the ticket means a stale view is refused by the server rather than acted on.
 */
export function useDoluYerler() {
  return useQuery({
    queryKey: ['dolu_yerler'],
    queryFn: async (): Promise<Record<string, DoluYer>> => {
      const { data, error } = await supabase
        .from('biletler')
        .select('id, park_yeri_id, plaka')
        .eq('durum', 'ACIK')
        .not('park_yeri_id', 'is', null)
      if (error) throw error
      const harita: Record<string, DoluYer> = {}
      for (const r of (data ?? []) as {
        id: string
        park_yeri_id: string | null
        plaka: string
      }[]) {
        if (r.park_yeri_id) harita[r.park_yeri_id] = { bilet_id: r.id, plaka: r.plaka }
      }
      return harita
    },
    staleTime: 15_000,
  })
}

/**
 * Move a car that is already inside to another bay (011).
 *
 * `retry: false`: it is a correction somebody is watching happen, and the two
 * ways it fails — the bay was taken a moment ago, the car has already left —
 * are both things to be told rather than retried into.
 */
export function useBiletYerDegistir() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (g: { bilet_id: string; yeni_yer_id: string }) => {
      const { error } = await supabase.rpc('bilet_yer_degistir', {
        p_bilet_id: g.bilet_id,
        p_yeni_yer_id: g.yeni_yer_id,
      })
      if (error) throw error
    },
    onSuccess: (_d, g) => {
      void qc.invalidateQueries({ queryKey: ['dolu_yerler'] })
      // The entry picker proposes a bay from this, and the open-ticket list
      // and detail both print one.
      void qc.invalidateQueries({ queryKey: ['park_yeri_durumu'] })
      void qc.invalidateQueries({ queryKey: ['acik_biletler'] })
      void qc.invalidateQueries({ queryKey: ['bilet', g.bilet_id] })
    },
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

export interface YerDuzeniGirdi {
  normal: number
  engelli: number
  rezerve: number
  digerlerini_kapat: boolean
}

export interface YerDuzeniSonuc {
  eklenen: number
  guncellenen: number
  kapanan: number
  /** Codes that were left alone because a car or a reservation is on them. */
  atlanan: string[]
  aktif: number
}

/**
 * Applies the P/E/R layout for a capacity, server-side and in one transaction.
 *
 * Deliberately NOT a loop of inserts from here: growing or shrinking a lot is
 * one decision, and half of it applying would leave a layout nobody asked for.
 * The RPC also refuses to touch an occupied bay and never deletes a row — both
 * of which a client loop would have no safe way to guarantee.
 *
 * No retry. It is idempotent, so a retry would be harmless, but a silent one
 * would hide a real failure behind an eventual success and the operator would
 * never learn the settings save was flaky.
 */
export function useYerDuzeniUret() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (g: YerDuzeniGirdi): Promise<YerDuzeniSonuc> => {
      const { data, error } = await supabase.rpc('park_yerleri_uret', {
        p_normal: g.normal,
        p_engelli: g.engelli,
        p_rezerve: g.rezerve,
        p_digerlerini_kapat: g.digerlerini_kapat,
      })
      if (error) throw error
      return data as YerDuzeniSonuc
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['park_yerleri'] })
      void qc.invalidateQueries({ queryKey: ['dolu_yerler'] })
    },
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
      const { error } = await supabase.rpc('kayit_sil', {
        p_tablo: 'rezervasyonlar',
        p_id: id,
      })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}
