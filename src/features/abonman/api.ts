import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type { Abonman, AbonmanDurum, OdemeYontemi, Tahsilat } from '../../lib/types'

export function useAbonmanlar(durum?: AbonmanDurum | 'TUMU') {
  return useQuery({
    queryKey: ['abonmanlar', durum ?? 'TUMU'],
    queryFn: async (): Promise<Abonman[]> => {
      let q = supabase.from('abonmanlar').select('*').order('bitis', { ascending: true })
      if (durum && durum !== 'TUMU') q = q.eq('durum', durum)
      const { data, error } = await q
      if (error) throw error
      return data as Abonman[]
    },
  })
}

export function useAbonman(id: string | undefined) {
  return useQuery({
    queryKey: ['abonman', id],
    enabled: Boolean(id),
    queryFn: async (): Promise<Abonman> => {
      const { data, error } = await supabase.from('abonmanlar').select('*').eq('id', id!).single()
      if (error) throw error
      return data as Abonman
    },
  })
}

export function useAbonmanTahsilatlari(abonmanId: string | undefined) {
  return useQuery({
    queryKey: ['abonman_tahsilat', abonmanId],
    enabled: Boolean(abonmanId),
    queryFn: async (): Promise<Tahsilat[]> => {
      const { data, error } = await supabase
        .from('tahsilatlar')
        .select('*')
        .eq('abonman_id', abonmanId!)
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as Tahsilat[]
    },
  })
}

function useAbonmanInvalidate() {
  const qc = useQueryClient()
  return () => {
    void qc.invalidateQueries({ queryKey: ['abonmanlar'] })
    void qc.invalidateQueries({ queryKey: ['abonman'] })
  }
}

export interface AbonmanGirdi {
  plaka: string
  musteri_ad: string
  musteri_tel: string | null
  baslangic: string
  bitis: string
  ucret_kurus: number
  park_yeri_id: string | null
  notlar: string | null
}

/**
 * Direct insert rather than an RPC: there is no versioning invariant here,
 * and the EXCLUDE constraint already refuses two overlapping subscriptions
 * for one plate at the database level.
 */
export function useAbonmanEkle() {
  const invalidate = useAbonmanInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async (g: AbonmanGirdi) => {
      const { error } = await supabase.from('abonmanlar').insert(g)
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

export function useAbonmanGuncelle() {
  const invalidate = useAbonmanInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async ({ id, ...yama }: Partial<Abonman> & { id: string }) => {
      const { error } = await supabase.from('abonmanlar').update(yama).eq('id', id)
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

/** Yönetici-only by RPC guard — Personel must never handle the price. */
export function useAbonmanTahsil() {
  const qc = useQueryClient()
  return useMutation({
    retry: false, // it takes money
    mutationFn: async (g: {
      abonman_id: string
      yontem: OdemeYontemi
      tutar_kurus: number | null
    }) => {
      const { error } = await supabase.rpc('abonman_tahsil', {
        p_abonman_id: g.abonman_id,
        p_yontem: g.yontem,
        p_tutar_kurus: g.tutar_kurus,
      })
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['abonman_tahsilat'] })
      void qc.invalidateQueries({ queryKey: ['rapor_ozet'] })
    },
  })
}
