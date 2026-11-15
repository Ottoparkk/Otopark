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
  ucret_kurus: number
  /** 062: payment day of the month, 1–31. The server sets the dates. */
  yenileme_gunu: number
  park_yeri_id: string | null
  notlar: string | null
  /** The first month, taken in the same form. 0 only for a Yönetici. */
  tutar_kurus: number
  yontem: OdemeYontemi | null
}

/**
 * New abonman with its first payment, in one call (062 `abonman_ekle`):
 * the server sets the period (today → the next payment day), writes the
 * payment into the open shift (it waits in Onay) and tells the Yönetici who
 * added it. Personel need an open shift. Never retried — it takes money.
 */
export function useAbonmanEkle() {
  const invalidate = useAbonmanInvalidate()
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (g: AbonmanGirdi) => {
      const { data, error } = await supabase.rpc('abonman_ekle', {
        p_plaka: g.plaka,
        p_musteri_ad: g.musteri_ad,
        p_musteri_tel: g.musteri_tel,
        p_ucret_kurus: g.ucret_kurus,
        p_yenileme_gunu: g.yenileme_gunu,
        p_park_yeri_id: g.park_yeri_id,
        p_notlar: g.notlar,
        p_tutar_kurus: g.tutar_kurus,
        // A free (₺0) abonman takes no method — never send the picker's default.
        p_yontem: g.tutar_kurus > 0 ? g.yontem : null,
      })
      if (error) throw error
      return data as string
    },
    onSuccess: () => {
      invalidate()
      odemeInvalidate(qc)
    },
  })
}

/** Direct update — Yönetici only by RLS (Düzenle, İptal). */
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

/** Everything a new payment changes: Onay, the till, the shift's own sums. */
function odemeInvalidate(qc: ReturnType<typeof useQueryClient>) {
  void qc.invalidateQueries({ queryKey: ['abonman_tahsilat'] })
  void qc.invalidateQueries({ queryKey: ['rapor_ozet'] })
  void qc.invalidateQueries({ queryKey: ['onay'] })
  void qc.invalidateQueries({ queryKey: ['onay_ozet'] })
  void qc.invalidateQueries({ queryKey: ['kasa'] })
  void qc.invalidateQueries({ queryKey: ['vardiya_ozetim'] })
}

/**
 * A payment, and with `yenile` the period renewed to the next payment day —
 * ONE call (062 `abonman_tahsil`), so a payment can no longer land without
 * its renewal. Any staff; Personel need an open shift (the cash belongs to
 * it). Waits in Onay like every collection.
 */
export function useAbonmanTahsil() {
  const invalidate = useAbonmanInvalidate()
  const qc = useQueryClient()
  return useMutation({
    retry: false, // it takes money
    mutationFn: async (g: {
      abonman_id: string
      yontem: OdemeYontemi
      tutar_kurus: number
      yenile: boolean
    }) => {
      const { error } = await supabase.rpc('abonman_tahsil', {
        p_abonman_id: g.abonman_id,
        p_yontem: g.yontem,
        p_tutar_kurus: g.tutar_kurus,
        p_yenile: g.yenile,
      })
      if (error) throw error
    },
    onSuccess: () => {
      invalidate()
      odemeInvalidate(qc)
    },
  })
}
