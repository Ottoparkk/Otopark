import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { gunEkle, istanbulGun, istanbulSaat } from '../../lib/dates'
import { dakikaFarki } from '../../lib/sure'
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

/* ------------------------------------------------- client-side breakdowns */

export interface RaporDetay {
  /** Entry counts per Istanbul hour, index 0–23. */
  saatlik: number[]
  tipler: { tip: AracTipi; sayi: number }[]
  sureler: { etiket: string; sayi: number }[]
  girisSayisi: number
  cikanSayisi: number
  /** True when the row cap was hit, so the charts are a partial view. */
  kesildi: boolean
}

const SURE_KOVALARI: { etiket: string; max: number }[] = [
  { etiket: '0–1 saat', max: 60 },
  { etiket: '1–3 saat', max: 180 },
  { etiket: '3–6 saat', max: 360 },
  { etiket: '6–12 saat', max: 720 },
  { etiket: '12 saat+', max: Infinity },
]

const DETAY_LIMIT = 10000

/**
 * The breakdowns that `rapor_gunluk` / `rapor_ozet` do not return: arrivals by
 * hour, vehicle mix, and how long cars stayed.
 *
 * Computed on the client from `biletler` rather than in a new RPC, because
 * Yönetici already has full SELECT on that table (`biletler_select`), so this
 * adds no migration, no grant, and no new security surface. Personel cannot
 * reach it: RLS hands them only open tickets and their own shift, and Raporlar
 * is a Yönetici-only route on top of that.
 *
 * EVERY figure here is keyed off `giris_at` — one basis, deliberately. The
 * duration chart therefore reads "of the cars that ARRIVED in this period, how
 * long did the ones that have left stay", which is a coherent question. Mixing
 * in exits that belong to earlier arrivals would put two different
 * denominators in one card, and nobody reading it would know which was which.
 */
export function useRaporDetay(bas: string, bit: string) {
  return useQuery({
    queryKey: ['rapor_detay', bas, bit],
    queryFn: async (): Promise<RaporDetay> => {
      // Widened by a day on each side because these bounds are UTC instants
      // while `bas`/`bit` are ISTANBUL calendar days. The exact day test
      // happens below with the same Intl-based helper the rest of the app
      // uses, so this only has to be a superset — no offset is assumed here.
      const { data, error } = await supabase
        .from('biletler')
        .select('arac_tipi,giris_at,cikis_at,durum')
        .gte('giris_at', `${gunEkle(-1, bas)}T00:00:00Z`)
        .lte('giris_at', `${gunEkle(1, bit)}T23:59:59Z`)
        .limit(DETAY_LIMIT)

      if (error) throw error
      const satirlar = (data ?? []) as Pick<
        Bilet,
        'arac_tipi' | 'giris_at' | 'cikis_at' | 'durum'
      >[]

      const saatlik = Array.from({ length: 24 }, () => 0)
      const tipSayac = new Map<AracTipi, number>()
      const sureSayac = SURE_KOVALARI.map(() => 0)
      let girisSayisi = 0
      let cikanSayisi = 0

      for (const b of satirlar) {
        // A cancelled ticket is not an arrival that happened — counting it
        // would inflate the hourly peaks the staffing decision is read from.
        if (b.durum === 'IPTAL') continue
        const gun = istanbulGun(new Date(b.giris_at))
        if (gun < bas || gun > bit) continue

        girisSayisi++
        saatlik[istanbulSaat(b.giris_at)]!++
        tipSayac.set(b.arac_tipi, (tipSayac.get(b.arac_tipi) ?? 0) + 1)

        if (b.cikis_at) {
          cikanSayisi++
          const dk = dakikaFarki(b.giris_at, b.cikis_at)
          const i = SURE_KOVALARI.findIndex((k) => dk < k.max)
          sureSayac[i === -1 ? SURE_KOVALARI.length - 1 : i]!++
        }
      }

      return {
        saatlik,
        tipler: [...tipSayac.entries()].map(([tip, sayi]) => ({ tip, sayi })),
        sureler: SURE_KOVALARI.map((k, i) => ({ etiket: k.etiket, sayi: sureSayac[i]! })),
        girisSayisi,
        cikanSayisi,
        kesildi: satirlar.length >= DETAY_LIMIT,
      }
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
