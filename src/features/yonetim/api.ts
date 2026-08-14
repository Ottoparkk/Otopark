import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type {
  AracTipi,
  Bilet,
  BiletDurum,
  KasaHareketi,
  KasaTur,
  KullaniciDurum,
  OdemeYontemi,
  OtoparkAyarlari,
  Profile,
  PuanKurali,
  RaporGun,
  RaporOzet,
  Rol,
  Vardiya,
} from '../../lib/types'

/* ============================================================== reports === */

/** rpc -> TABLE with exactly one row. */
export function useRaporOzet(bas: string, bit: string) {
  return useQuery({
    queryKey: ['rapor_ozet', bas, bit],
    queryFn: async (): Promise<RaporOzet | null> => {
      const { data, error } = await supabase.rpc('rapor_ozet', { p_bas: bas, p_bit: bit })
      if (error) throw error
      return ((data ?? [])[0] as RaporOzet) ?? null
    },
  })
}

/** rpc -> TABLE, one row per day including days with no revenue. */
export function useRaporGunluk(bas: string, bit: string) {
  return useQuery({
    queryKey: ['rapor_gunluk', bas, bit],
    queryFn: async (): Promise<RaporGun[]> => {
      const { data, error } = await supabase.rpc('rapor_gunluk', { p_bas: bas, p_bit: bit })
      if (error) throw error
      return (data ?? []) as RaporGun[]
    },
  })
}

/* ================================================================ staff === */

export function useProfiller() {
  return useQuery({
    queryKey: ['profiller'],
    queryFn: async (): Promise<Profile[]> => {
      const { data, error } = await supabase
        .from('profiles')
        .select('*')
        .order('durum')
        .order('ad_soyad')
      if (error) throw error
      return data as Profile[]
    },
  })
}

function useProfilInvalidate() {
  const qc = useQueryClient()
  return () => void qc.invalidateQueries({ queryKey: ['profiller'] })
}

export function useApproveSignup() {
  const invalidate = useProfilInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async ({ id, rol }: { id: string; rol: Rol }) => {
      const { error } = await supabase.rpc('approve_signup', { p_id: id, p_rol: rol })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

export function useSetRole() {
  const invalidate = useProfilInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async ({ id, rol }: { id: string; rol: Rol }) => {
      const { error } = await supabase.rpc('set_role', { p_id: id, p_rol: rol })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

export function useSetStatus() {
  const invalidate = useProfilInvalidate()
  return useMutation({
    retry: false,
    mutationFn: async ({ id, durum }: { id: string; durum: KullaniciDurum }) => {
      const { error } = await supabase.rpc('set_status', { p_id: id, p_durum: durum })
      if (error) throw error
    },
    onSuccess: invalidate,
  })
}

/* ============================================================== tariffs === */

export interface TarifeGirdi {
  arac_tipi: AracTipi
  ucretsiz_dakika: number
  ilk_saat_kurus: number
  sonraki_saat_kurus: number
  gunluk_tavan_kurus: number
  kayip_bilet_kurus: number
}

/**
 * There is deliberately no direct UPDATE path to `tarifeler` — not even for
 * Yönetici. This RPC closes the current row and opens a new one, so a car
 * already inside keeps the price it entered under.
 */
export function useTarifeGuncelle() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (g: TarifeGirdi) => {
      const { error } = await supabase.rpc('tarife_guncelle', {
        p_arac_tipi: g.arac_tipi,
        p_ucretsiz_dakika: g.ucretsiz_dakika,
        p_ilk_saat_kurus: g.ilk_saat_kurus,
        p_sonraki_saat_kurus: g.sonraki_saat_kurus,
        p_gunluk_tavan_kurus: g.gunluk_tavan_kurus,
        p_kayip_bilet_kurus: g.kayip_bilet_kurus,
      })
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['tarifeler'] })
    },
  })
}

export function usePuanKuralGuncelle() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (g: {
      kazanim_puan: number
      kurus_per_puan: number
      bekleme_saat: number
      puan_gecerlilik_gun: number
    }) => {
      const { error } = await supabase.rpc('puan_kural_guncelle', {
        p_kazanim_puan: g.kazanim_puan,
        p_kurus_per_puan: g.kurus_per_puan,
        p_bekleme_saat: g.bekleme_saat,
        p_puan_gecerlilik_gun: g.puan_gecerlilik_gun,
      })
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['puan_kurali'] })
    },
  })
}

/** The one active rule version, or null before any has been set. */
export function usePuanKurali() {
  return useQuery({
    queryKey: ['puan_kurali'],
    queryFn: async (): Promise<PuanKurali | null> => {
      const { data, error } = await supabase
        .from('puan_kurallari')
        .select('*')
        .is('gecerli_bitis', null)
        .maybeSingle()
      if (error) throw error
      return (data as PuanKurali | null) ?? null
    },
  })
}

/* ============================================================= settings === */

export function useAyarGuncelle() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (yama: Partial<OtoparkAyarlari>) => {
      const { error } = await supabase
        .from('otopark_ayarlari')
        .update({ ...yama, updated_at: new Date().toISOString() })
        .eq('id', 1)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['ayarlar'] })
    },
  })
}

/* ================================================================= kasa === */

export function useKasaHareketleri(bas: string, bit: string) {
  return useQuery({
    queryKey: ['kasa', bas, bit],
    queryFn: async (): Promise<KasaHareketi[]> => {
      const { data, error } = await supabase
        .from('kasa_hareketleri')
        .select('*')
        .gte('tarih', bas)
        .lte('tarih', bit)
        .order('tarih', { ascending: false })
        .order('created_at', { ascending: false })
      if (error) throw error
      return data as KasaHareketi[]
    },
  })
}

export function useKasaEkle() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (g: {
      tur: KasaTur
      tutar_kurus: number
      aciklama: string
      kategori: string | null
      yontem: OdemeYontemi | null
    }) => {
      const { error } = await supabase.from('kasa_hareketleri').insert(g)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['kasa'] })
    },
  })
}

export function useKasaSil() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (id: string) => {
      const { error } = await supabase.from('kasa_hareketleri').delete().eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['kasa'] })
    },
  })
}

/* ============================================================== history === */

export function useBiletGecmisi(filtre: { durum?: BiletDurum | 'TUMU'; q?: string }) {
  return useQuery({
    queryKey: ['bilet_gecmisi', filtre.durum ?? 'TUMU', filtre.q ?? ''],
    queryFn: async (): Promise<Bilet[]> => {
      let q = supabase
        .from('biletler')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(200)

      if (filtre.durum && filtre.durum !== 'TUMU') q = q.eq('durum', filtre.durum)
      if (filtre.q) q = q.ilike('plaka', `%${filtre.q}%`)

      const { data, error } = await q
      if (error) throw error
      return data as Bilet[]
    },
  })
}

export function useTumVardiyalar() {
  return useQuery({
    queryKey: ['tum_vardiyalar'],
    queryFn: async (): Promise<Vardiya[]> => {
      const { data, error } = await supabase
        .from('vardiyalar')
        .select('*')
        .order('acilis_at', { ascending: false })
        .limit(100)
      if (error) throw error
      return data as Vardiya[]
    },
  })
}
