import { useMemo } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type {
  KullaniciDurum,
  OtoparkAyarlari,
  Profile,
  PuanKurali,
  OdemeYontemi,
  PersonelOdeme,
  Rol,
  TarifeTur,
} from '../../lib/types'

/* ================================================================ staff === */

/**
 * The roster WITH pay, for the Personel screen.
 *
 * An RPC rather than a table read, because pay is not client-readable: 018
 * takes SELECT off `profiles.maas_kurus` for everyone, since RLS lets active
 * staff see each other's rows (a ticket has to be able to name its author) and
 * RLS has no column dimension. The guard inside the function is what limits
 * this to a Yönetici — hiding the screen would not.
 */
export interface PersonelSatiri {
  id: string
  ad_soyad: string
  rol: Rol | null
  durum: KullaniciDurum
  maas_kurus: number
  odeme_gunu: number | null
  maas_yontemi: OdemeYontemi | null
  created_at: string
}

export function usePersonelListesi() {
  return useQuery({
    queryKey: ['personel_listesi'],
    queryFn: async (): Promise<PersonelSatiri[]> => {
      const { data, error } = await supabase.rpc('personel_listesi')
      if (error) throw error
      return (data ?? []) as PersonelSatiri[]
    },
  })
}

export function useProfiller() {
  return useQuery({
    queryKey: ['profiller'],
    queryFn: async (): Promise<Profile[]> => {
      const { data, error } = await supabase
        .from('profiles')
        // See AuthProvider: the salary columns are not client-readable.
        .select('id,ad_soyad,rol,durum,notif_prefs,created_at')
        .order('durum')
        .order('ad_soyad')
      if (error) throw error
      return data as Profile[]
    },
  })
}

/**
 * id -> ad_soyad, for rendering "who created this" on rows.
 *
 * Same query as useProfiller, so a screen showing both pays for one request.
 * Safe for Personel: 003's `profiles_select` already lets active staff read
 * active staff, which is exactly what a creator label needs and nothing more.
 */
export function useAdlar(): Map<string, string> {
  const { data } = useProfiller()
  return useMemo(() => new Map((data ?? []).map((p) => [p.id, p.ad_soyad])), [data])
}

/** Both roster queries, always together — one carries pay, the other does not,
 *  and a screen showing a stale half of the same list is a bug in waiting. */
function useProfilInvalidate() {
  const qc = useQueryClient()
  return () => {
    void qc.invalidateQueries({ queryKey: ['profiller'] })
    void qc.invalidateQueries({ queryKey: ['personel_listesi'] })
  }
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

/* =========================================================== personnel pay === */

export interface PersonelOzet {
  maas_kurus: number
  /** null = no automatic payment; otherwise the day of the month, 1-28. */
  odeme_gunu: number | null
  maas_yontemi: OdemeYontemi | null
  borc_kurus: number
  avans_kurus: number
  prim_kurus: number
  maas_odenen: number
}

/**
 * Salary, outstanding advance debt and lifetime totals — from the server.
 *
 * The debt is NOT recomputed on the client. The same figure decides what a
 * salary payment actually pays out, and two formulas would eventually
 * disagree; the screen would then be confidently wrong about somebody's pay.
 */
export function usePersonelOzet(id: string) {
  return useQuery({
    queryKey: ['personel_ozet', id],
    enabled: Boolean(id),
    queryFn: async (): Promise<PersonelOzet | null> => {
      const { data, error } = await supabase.rpc('personel_ozet', { p_profile: id })
      if (error) throw error
      return ((data ?? [])[0] as PersonelOzet) ?? null
    },
  })
}

export function usePersonelOdemeler(id: string) {
  return useQuery({
    queryKey: ['personel_odemeler', id],
    enabled: Boolean(id),
    queryFn: async (): Promise<PersonelOdeme[]> => {
      const { data, error } = await supabase
        .from('personel_odemeler')
        .select('id, tur, tutar_kurus, aciklama, avans_dusulen, tarih')
        .eq('profile_id', id)
        .order('tarih', { ascending: false })
        .order('created_at', { ascending: false })
      if (error) throw error
      return (data ?? []) as PersonelOdeme[]
    },
  })
}

/** Every payment writes a kasa gider too, so all of these refresh both. */
function useOdemeMutation<T>(fn: (v: T) => Promise<void>) {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: fn,
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['personel_ozet'] })
      void qc.invalidateQueries({ queryKey: ['personel_odemeler'] })
      void qc.invalidateQueries({ queryKey: ['kasa'] })
      void qc.invalidateQueries({ queryKey: ['profiller'] })
      void qc.invalidateQueries({ queryKey: ['personel_listesi'] })
    },
  })
}

export function useMaasGuncelle() {
  return useOdemeMutation(
    async (g: {
      profile_id: string
      maas_kurus: number
      odeme_gunu: number | null
      yontem: OdemeYontemi | null
    }) => {
      // Nulls are sent as nulls, not omitted: the RPC writes them straight
      // through so an automatic payment can actually be switched back off.
      const { error } = await supabase.rpc('maas_guncelle', {
        p_profile: g.profile_id,
        p_maas: g.maas_kurus,
        p_gun: g.odeme_gunu,
        p_yontem: g.yontem,
      })
      if (error) throw error
    },
  )
}

/**
 * No amount parameter, deliberately: the salary is what is on the profile and
 * the advance deduction is the server's to compute. Passing a number from
 * here would be a second opinion about what somebody is owed.
 */
export function useMaasOde() {
  return useOdemeMutation(
    async (g: { profile_id: string; yontem: OdemeYontemi | null; aciklama: string }) => {
      const { error } = await supabase.rpc('maas_ode', {
        p_profile: g.profile_id,
        p_yontem: g.yontem,
        p_aciklama: g.aciklama,
      })
      if (error) throw error
    },
  )
}

export function useAvansVer() {
  return useOdemeMutation(
    async (g: {
      profile_id: string
      tutar_kurus: number
      yontem: OdemeYontemi | null
      aciklama: string
    }) => {
      const { error } = await supabase.rpc('avans_ver', {
        p_profile: g.profile_id,
        p_tutar: g.tutar_kurus,
        p_yontem: g.yontem,
        p_aciklama: g.aciklama,
      })
      if (error) throw error
    },
  )
}

export function usePrimVer() {
  return useOdemeMutation(
    async (g: {
      profile_id: string
      tutar_kurus: number
      yontem: OdemeYontemi | null
      aciklama: string
    }) => {
      const { error } = await supabase.rpc('prim_ver', {
        p_profile: g.profile_id,
        p_tutar: g.tutar_kurus,
        p_yontem: g.yontem,
        p_aciklama: g.aciklama,
      })
      if (error) throw error
    },
  )
}

/* ============================================================== tariffs === */

export interface TarifeGirdi {
  tur: TarifeTur
  /** Ignored by the server unless `tur` is SABIT. */
  sabit_kurus: number
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
        p_ucretsiz_dakika: g.ucretsiz_dakika,
        p_ilk_saat_kurus: g.ilk_saat_kurus,
        p_sonraki_saat_kurus: g.sonraki_saat_kurus,
        p_gunluk_tavan_kurus: g.gunluk_tavan_kurus,
        p_kayip_bilet_kurus: g.kayip_bilet_kurus,
        p_tur: g.tur,
        p_sabit_kurus: g.sabit_kurus,
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

