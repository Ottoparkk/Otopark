import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type { Hesap, HesapAraci, HesapDurum, PuanHareketi } from '../../lib/types'

/**
 * Loyalty accounts. Yönetici-only at the RLS layer — Personel reach exactly
 * one plate's balance through `hesap_puan_durumu()` and never a list.
 *
 * Note what is NOT here: there is no delete, and no way to edit or remove a
 * points movement. `puan_hareketleri` is an append-only ledger whose balance
 * is a real lira liability, so an account is retired by going PASIF and a
 * mistake is corrected with a counter-entry — the same rule the kasa follows.
 */

export interface HesapOzet {
  hesap_id: string
  ad: string
  durum: HesapDurum
  bakiye: number
}

/** Balance comes from the view, never from a stored counter. */
export function useHesapOzetleri() {
  return useQuery({
    queryKey: ['hesap_ozet'],
    queryFn: async (): Promise<HesapOzet[]> => {
      const { data, error } = await supabase.from('v_hesap_puan').select('*').order('ad')
      if (error) throw error
      return data as HesapOzet[]
    },
  })
}

/**
 * One account's balance, read from the same view as the list.
 *
 * Deliberately NOT summed from the movements list on screen: that list is
 * capped at the most recent 100 rows, so a long-standing account would show a
 * balance that quietly excluded its older history.
 */
export function useHesapBakiye(id: string | undefined) {
  return useQuery({
    queryKey: ['hesap_bakiye', id],
    enabled: Boolean(id),
    queryFn: async (): Promise<number> => {
      const { data, error } = await supabase
        .from('v_hesap_puan')
        .select('bakiye')
        .eq('hesap_id', id!)
        .maybeSingle()
      if (error) throw error
      return (data as { bakiye: number } | null)?.bakiye ?? 0
    },
  })
}

export function useHesap(id: string | undefined) {
  return useQuery({
    queryKey: ['hesap', id],
    enabled: Boolean(id),
    queryFn: async (): Promise<Hesap> => {
      const { data, error } = await supabase.from('hesaplar').select('*').eq('id', id!).single()
      if (error) throw error
      return data as Hesap
    },
  })
}

export function useHesapAraclari(hesapId: string | undefined) {
  return useQuery({
    queryKey: ['hesap_araclari', hesapId],
    enabled: Boolean(hesapId),
    queryFn: async (): Promise<HesapAraci[]> => {
      const { data, error } = await supabase
        .from('hesap_araclari')
        .select('*')
        .eq('hesap_id', hesapId!)
        .order('created_at')
      if (error) throw error
      return data as HesapAraci[]
    },
  })
}

export interface PuanHareketSatir extends PuanHareketi {
  bilet: { plaka: string } | null
}

export function usePuanHareketleri(hesapId: string | undefined) {
  return useQuery({
    queryKey: ['puan_hareketleri', hesapId],
    enabled: Boolean(hesapId),
    queryFn: async (): Promise<PuanHareketSatir[]> => {
      const { data, error } = await supabase
        .from('puan_hareketleri')
        .select('*, bilet:biletler(plaka)')
        .eq('hesap_id', hesapId!)
        .order('created_at', { ascending: false })
        .limit(100)
      if (error) throw error
      return data as PuanHareketSatir[]
    },
  })
}

function useHesapInvalidate() {
  const qc = useQueryClient()
  return () => {
    void qc.invalidateQueries({ queryKey: ['hesap_ozet'] })
    void qc.invalidateQueries({ queryKey: ['hesap'] })
  }
}

function useAracInvalidate() {
  const qc = useQueryClient()
  return () => void qc.invalidateQueries({ queryKey: ['hesap_araclari'] })
}

/**
 * A new account and its first vehicle, together.
 *
 * The plate is not optional: entry recognises a customer BY plate, so an
 * account with none earns nothing and is a row that does nothing until someone
 * remembers to finish it.
 *
 * Two inserts, because there is no RPC for this and neither row is money. If
 * the plate is refused — `hesap_araclari_plaka_ux` gives it to exactly one
 * account — the account just created is deleted again, so a rejected plate
 * cannot leave an empty account behind. The delete is best-effort: if IT
 * fails the account survives with no vehicle, which the detail screen can fix,
 * and the error the operator sees is still the real one.
 */
export function useHesapEkle() {
  const invalidate = useHesapInvalidate()
  const aracInvalidate = useAracInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async (g: {
      ad: string
      telefon: string | null
      notlar: string | null
      plaka: string
    }) => {
      const { plaka, ...hesap } = g
      const { data, error } = await supabase.from('hesaplar').insert(hesap).select('id').single()
      if (error) throw error
      const id = (data as { id: string }).id

      const { error: aracHata } = await supabase
        .from('hesap_araclari')
        .insert({ hesap_id: id, plaka })
      if (aracHata) {
        await supabase.from('hesaplar').delete().eq('id', id)
        throw aracHata
      }
      return id
    },
    onSuccess: () => {
      invalidate()
      aracInvalidate()
    },
  })
}

export function useHesapGuncelle() {
  const invalidate = useHesapInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async ({ id, ...yama }: Partial<Hesap> & { id: string }) => {
      const { error } = await supabase.from('hesaplar').update(yama).eq('id', id)
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

/**
 * `hesap_araclari_plaka_ux` makes one plate belong to exactly one account —
 * otherwise entry could not decide who earns. A plate already claimed
 * elsewhere is refused by the database, not by a lookup here.
 */
export function useAracEkle() {
  const invalidate = useAracInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async (g: { hesap_id: string; plaka: string }) => {
      const { error } = await supabase.from('hesap_araclari').insert(g)
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

/** Removing a vehicle stops future earning; past movements are untouched. */
export function useAracSil() {
  const invalidate = useAracInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc('kayit_sil', {
        p_tablo: 'hesap_araclari',
        p_id: id,
      })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}
