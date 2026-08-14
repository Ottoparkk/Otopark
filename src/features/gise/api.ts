import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { compressEvidence, fotoYolu } from '../../lib/image'
import type {
  AbonmanGecerlilik,
  AcikBilet,
  Bilet,
  BiletKapatSonuc,
  GunlukOzet,
  OdemeYontemi,
  OtoparkAyarlari,
  ParkYeri,
  PuanDurumu,
  Tarife,
  AracTipi,
} from '../../lib/types'

/**
 * ⚠ A note on shapes that is easy to get wrong and expensive to debug:
 *
 * A Postgres function declared `returns table(...)` comes back through
 * PostgREST as an ARRAY of rows, even when it always produces exactly one.
 * `returns uuid` / `returns integer` come back as a bare scalar.
 *
 * Every `.rpc()` below is annotated with which it is. Treating a one-row
 * table as an object yields `undefined` everywhere with no error — the fee
 * simply renders blank.
 */

/* ============================================================== queries === */

export function useAyarlar() {
  return useQuery({
    queryKey: ['ayarlar'],
    queryFn: async (): Promise<OtoparkAyarlari> => {
      const { data, error } = await supabase
        .from('otopark_ayarlari')
        .select('*')
        .eq('id', 1)
        .single()
      if (error) throw error
      return data as OtoparkAyarlari
    },
    staleTime: 5 * 60_000, // settings barely change
  })
}

export function useAktifTarifeler() {
  return useQuery({
    queryKey: ['tarifeler', 'aktif'],
    queryFn: async (): Promise<Tarife[]> => {
      const { data, error } = await supabase
        .from('tarifeler')
        .select('*')
        .is('gecerli_bitis', null)
        .order('arac_tipi')
      if (error) throw error
      return data as Tarife[]
    },
    staleTime: 5 * 60_000,
  })
}

export function useParkYerleri() {
  return useQuery({
    queryKey: ['park_yerleri'],
    queryFn: async (): Promise<ParkYeri[]> => {
      const { data, error } = await supabase
        .from('park_yerleri')
        .select('*')
        .eq('is_active', true)
        .order('kod')
      if (error) throw error
      return data as ParkYeri[]
    },
    staleTime: 5 * 60_000,
  })
}

/** rpc -> TABLE, so this is an array. Empty query string returns everything. */
export function useAcikBiletler(sorgu = '') {
  return useQuery({
    queryKey: ['acik_biletler', sorgu],
    queryFn: async (): Promise<AcikBilet[]> => {
      const { data, error } = await supabase.rpc('acik_bilet_ara', { p_q: sorgu })
      if (error) throw error
      return (data ?? []) as AcikBilet[]
    },
    // The lot changes constantly; a stale open-ticket list at a barrier is
    // worse than a brief spinner.
    staleTime: 5_000,
    refetchInterval: 30_000,
  })
}

export function useBilet(id: string | undefined) {
  return useQuery({
    queryKey: ['bilet', id],
    enabled: Boolean(id),
    queryFn: async (): Promise<Bilet> => {
      const { data, error } = await supabase.from('biletler').select('*').eq('id', id!).single()
      if (error) throw error
      return data as Bilet
    },
  })
}

/** rpc -> TABLE with exactly one row. */
export function useGunlukOzet() {
  return useQuery({
    queryKey: ['gunluk_ozet'],
    queryFn: async (): Promise<GunlukOzet | null> => {
      const { data, error } = await supabase.rpc('gunluk_ozet')
      if (error) throw error
      return ((data ?? [])[0] as GunlukOzet) ?? null
    },
    staleTime: 20_000,
    refetchInterval: 60_000,
  })
}

/**
 * The live fee shown on the exit screen.
 *
 * The SERVER prices it — the same `ucret_hesapla` that `bilet_kapat` uses
 * internally, so the quote and the charge come from one implementation and
 * cannot drift. The exit time sent here is the device's clock, which is fine
 * for a PREVIEW; the amount actually charged is whatever `bilet_kapat`
 * returns, computed server-side at the moment of closing.
 */
export function useUcretOnizleme(bilet: AcikBilet | Bilet | null | undefined) {
  return useQuery({
    queryKey: ['ucret', bilet?.id],
    enabled: Boolean(bilet),
    queryFn: async (): Promise<number> => {
      // A subscriber's stay is free, and the RPC would price it as if it
      // were not. bilet_kapat applies the same rule server-side.
      if (bilet!.abonman_id) return 0
      const { data, error } = await supabase.rpc('ucret_hesapla', {
        p_giris: bilet!.giris_at,
        p_cikis: new Date().toISOString(),
        p_tarife_id: bilet!.tarife_id,
      })
      if (error) throw error
      return (data as number) ?? 0 // rpc -> scalar integer
    },
    // Re-price every 30s so a car sitting at the barrier does not show a
    // number that quietly goes stale while the operator hunts for change.
    refetchInterval: 30_000,
    staleTime: 0,
  })
}

/** rpc -> TABLE, always exactly one row. */
export function useAbonmanKontrol(plaka: string, enabled = true) {
  return useQuery({
    queryKey: ['abonman_kontrol', plaka],
    enabled: enabled && plaka.length >= 4,
    queryFn: async (): Promise<AbonmanGecerlilik | null> => {
      const { data, error } = await supabase.rpc('abonman_gecerli_mi', { p_plaka: plaka })
      if (error) throw error
      return ((data ?? [])[0] as AbonmanGecerlilik) ?? null
    },
    staleTime: 60_000,
  })
}

/** rpc -> TABLE. Scoped to ONE plate: Personel never sees an account list. */
export function usePuanDurumu(plaka: string, enabled = true) {
  return useQuery({
    queryKey: ['puan_durumu', plaka],
    enabled: enabled && plaka.length >= 4,
    queryFn: async (): Promise<PuanDurumu | null> => {
      const { data, error } = await supabase.rpc('hesap_puan_durumu', { p_plaka: plaka })
      if (error) throw error
      return ((data ?? [])[0] as PuanDurumu) ?? null
    },
    staleTime: 30_000,
  })
}

/* ============================================================== photos === */

export interface FotoSonuc {
  path: string | null
  /** Non-null when the upload failed. Reported to the operator, never swallowed. */
  hata: string | null
}

/**
 * Uploads the evidence photo and returns its path.
 *
 * A failed upload must NOT block the ticket: at a barrier the record of the
 * car matters more than the picture of it. So this reports the failure and
 * the caller carries on without a path — visible, not silent.
 */
export async function fotoYukle(
  file: File,
  yon: 'giris' | 'cikis',
  plaka: string,
): Promise<FotoSonuc> {
  try {
    const sikistirilmis = await compressEvidence(file)
    const path = fotoYolu(yon, plaka)
    const { error } = await supabase.storage.from('plaka-foto').upload(path, sikistirilmis, {
      contentType: 'image/jpeg',
      upsert: false,
    })
    if (error) return { path: null, hata: 'Fotoğraf yüklenemedi, kayıt fotoğrafsız açıldı.' }
    return { path, hata: null }
  } catch {
    return { path: null, hata: 'Fotoğraf hazırlanamadı, kayıt fotoğrafsız açıldı.' }
  }
}

/** Signed URL for a private-bucket photo. */
export function useFotoUrl(path: string | null | undefined) {
  return useQuery({
    queryKey: ['foto', path],
    enabled: Boolean(path),
    queryFn: async (): Promise<string | null> => {
      const { data, error } = await supabase.storage
        .from('plaka-foto')
        .createSignedUrl(path!, 60 * 10)
      if (error) return null
      return data?.signedUrl ?? null
    },
    staleTime: 8 * 60_000, // refresh before the 10-minute signature expires
  })
}

/* ============================================================ mutations === */

function useGiseInvalidate() {
  const qc = useQueryClient()
  return () => {
    void qc.invalidateQueries({ queryKey: ['acik_biletler'] })
    void qc.invalidateQueries({ queryKey: ['gunluk_ozet'] })
    void qc.invalidateQueries({ queryKey: ['vardiya_ozetim'] })
  }
}

export interface BiletAcGirdi {
  plaka: string
  arac_tipi: AracTipi
  /** Generated ONCE per form session and reused across retries — this is what
   *  makes retry-on-blip and a double-tap both idempotent. */
  islem_id: string
  foto?: string | null
  park_yeri_id?: string | null
}

/**
 * Opening a ticket RETRIES — roughly 3 attempts over ~10 seconds.
 *
 * This is not an offline queue: nothing touches the device, nothing survives
 * an app close, nothing syncs later. It is one in-flight request being
 * retried, which covers the 2-second signal drop that happens constantly at a
 * barrier without pretending to cover a real outage.
 *
 * Safe by construction because `p_islem_id` is idempotent server-side: a
 * retry that actually succeeded but lost its response returns the original
 * ticket instead of opening a second one.
 */
export function useBiletAc() {
  const invalidate = useGiseInvalidate()
  return useMutation({
    mutationKey: ['bilet_ac'],
    retry: 3,
    retryDelay: (attempt) => Math.min(1000 * 2 ** attempt, 4000),
    mutationFn: async (girdi: BiletAcGirdi): Promise<string | null> => {
      const { data, error } = await supabase.rpc('bilet_ac', {
        p_plaka: girdi.plaka,
        p_arac_tipi: girdi.arac_tipi,
        p_islem_id: girdi.islem_id,
        // MOBIL: the server deliberately IGNORES any client timestamp and
        // uses its own clock. Only the camera path supplies a time.
        p_kaynak: 'MOBIL',
        p_zaman: null,
        p_foto: girdi.foto ?? null,
        p_park_yeri_id: girdi.park_yeri_id ?? null,
        p_ham_yanit: null,
      })
      if (error) throw error
      return (data as string | null) ?? null // rpc -> scalar uuid
    },
    onSuccess: invalidate,
  })
}

export interface BiletKapatGirdi {
  bilet_id: string
  odeme_yontemi: OdemeYontemi | null
  ucret_override_kurus?: number | null
  sebep?: string | null
  foto?: string | null
}

/**
 * Closing a ticket takes money, so it NEVER retries.
 *
 * A silent retry on a payment is how a double charge happens. The operator is
 * standing right there: an explicit failure they can tap again is strictly
 * better than an automatic retry they cannot see.
 */
export function useBiletKapat() {
  const invalidate = useGiseInvalidate()
  return useMutation({
    mutationKey: ['bilet_kapat'],
    retry: false,
    mutationFn: async (girdi: BiletKapatGirdi): Promise<BiletKapatSonuc> => {
      const { data, error } = await supabase.rpc('bilet_kapat', {
        p_bilet_id: girdi.bilet_id,
        p_odeme_yontemi: girdi.odeme_yontemi,
        p_ucret_override_kurus: girdi.ucret_override_kurus ?? null,
        p_sebep: girdi.sebep ?? null,
        p_foto: girdi.foto ?? null,
        p_kaynak: 'MOBIL',
      })
      if (error) throw error
      // rpc -> TABLE: one row, and it carries the amount ACTUALLY charged.
      const row = (data ?? [])[0] as BiletKapatSonuc | undefined
      if (!row) throw new Error('Tahsilat sonucu alınamadı.')
      return row
    },
    onSuccess: invalidate,
  })
}

export function useBiletIptal() {
  const invalidate = useGiseInvalidate()
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async ({ bilet_id, sebep }: { bilet_id: string; sebep: string }) => {
      const { error } = await supabase.rpc('bilet_iptal', {
        p_bilet_id: bilet_id,
        p_sebep: sebep,
      })
      if (error) throw error
    },
    onSuccess: (_d, v) => {
      invalidate()
      void qc.invalidateQueries({ queryKey: ['bilet', v.bilet_id] })
    },
  })
}

export function useAracTipiDuzelt() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async ({ bilet_id, arac_tipi }: { bilet_id: string; arac_tipi: AracTipi }) => {
      const { error } = await supabase.rpc('bilet_arac_tipi_duzelt', {
        p_bilet_id: bilet_id,
        p_arac_tipi: arac_tipi,
      })
      if (error) throw error
    },
    onSuccess: (_d, v) => {
      void qc.invalidateQueries({ queryKey: ['acik_biletler'] })
      void qc.invalidateQueries({ queryKey: ['bilet', v.bilet_id] })
      // The tariff changed, so the quoted fee must be re-fetched.
      void qc.invalidateQueries({ queryKey: ['ucret', v.bilet_id] })
    },
  })
}

export function usePuanKullan() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async ({ bilet_id, puan }: { bilet_id: string; puan: number }): Promise<number> => {
      const { data, error } = await supabase.rpc('puan_kullan', {
        p_bilet_id: bilet_id,
        p_puan: puan,
      })
      if (error) throw error
      return (data as number) ?? 0 // rpc -> scalar integer (indirim, kuruş)
    },
    onSuccess: (_d, v) => {
      void qc.invalidateQueries({ queryKey: ['acik_biletler'] })
      void qc.invalidateQueries({ queryKey: ['bilet', v.bilet_id] })
      void qc.invalidateQueries({ queryKey: ['puan_durumu'] })
    },
  })
}

export function usePuanGeriAl() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (bilet_id: string) => {
      const { error } = await supabase.rpc('puan_kullanim_geri_al', { p_bilet_id: bilet_id })
      if (error) throw error
    },
    onSuccess: (_d, bilet_id) => {
      void qc.invalidateQueries({ queryKey: ['acik_biletler'] })
      void qc.invalidateQueries({ queryKey: ['bilet', bilet_id] })
      void qc.invalidateQueries({ queryKey: ['puan_durumu'] })
    },
  })
}

/** A car at the exit with no entry record — charges the lost-ticket fee. */
export function useKayipBilet() {
  const invalidate = useGiseInvalidate()
  return useMutation({
    retry: false, // it takes money
    mutationFn: async (girdi: {
      plaka: string
      arac_tipi: AracTipi
      odeme_yontemi: OdemeYontemi
      islem_id: string
    }): Promise<string> => {
      const { data, error } = await supabase.rpc('kayip_bilet_tahsil', {
        p_plaka: girdi.plaka,
        p_arac_tipi: girdi.arac_tipi,
        p_odeme_yontemi: girdi.odeme_yontemi,
        p_islem_id: girdi.islem_id,
      })
      if (error) throw error
      return data as string
    },
    onSuccess: invalidate,
  })
}
