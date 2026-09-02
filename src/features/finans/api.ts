import { useMemo } from 'react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { donemAralik, type Donem, type DonemAralik } from '../yonetim/components'
import { gunEkle, istanbulGun, istanbulSaat } from '../../lib/dates'
import { dakikaFarki } from '../../lib/sure'
import type {
  Bilet,
  BiletDurum,
  KasaHareketi,
  KasaTur,
  OdemeYontemi,
  OnayDurum,
  RaporGun,
  RaporOzet,
  Tahsilat,
  TahsilatTur,
  Tarife,
  Vardiya,
} from '../../lib/types'

/**
 * Everything the Finans section reads or writes.
 *
 * Split out of `yonetim/api.ts` when Finans became its own section: money and
 * management were two concerns sharing one file, and the boundary was already
 * clean — no hook here is used by a Yönetim screen, and none there by a
 * finance one.
 *
 * Every table behind these is Yönetici-only in RLS (`kasa_all`,
 * `tahsilatlar_select`, `biletler_select`), so the route guard is UX; the
 * database is the boundary.
 */

/* =============================================================== period === */

/**
 * The Istanbul date of the earliest money this system knows about.
 *
 * "Tümü" needs a REAL start date, not a sentinel like 2000-01-01, because
 * `rapor_gunluk` builds its result with `generate_series` over the range: a
 * 26-year window would return ~9,700 rows — nearly all of them zeros — for a
 * car park that has been open a month, and the daily chart would be unusable.
 * Two indexed `limit 1` reads bound the range to reality instead.
 *
 * Both tables are Yönetici-only in RLS, same as everything else in this file.
 * `biletler.giris_at` is an instant and `kasa_hareketleri.tarih` is already an
 * Istanbul calendar date, so only the first needs converting — mixing the two
 * without that would drift by a day for anything booked after 21:00 UTC.
 *
 * Falls back to today when the lot has no history at all, which makes "Tümü"
 * degenerate to "Bugün" — correct, and it keeps every caller free of a
 * null-range special case.
 */
export function useIlkGun(enabled = true) {
  return useQuery({
    queryKey: ['ilk_gun'],
    enabled,
    // The first ticket ever written does not change; re-asking on every
    // period switch would be a round trip for a constant.
    staleTime: 60 * 60_000,
    queryFn: async (): Promise<string> => {
      const [bilet, kasa] = await Promise.all([
        supabase.from('biletler').select('giris_at').order('giris_at').limit(1),
        supabase.from('kasa_hareketleri').select('tarih').order('tarih').limit(1),
      ])
      if (bilet.error) throw bilet.error
      if (kasa.error) throw kasa.error

      const ilkBilet = (bilet.data ?? [])[0]?.giris_at ?? null
      const gunler = [
        ilkBilet ? istanbulGun(new Date(ilkBilet)) : null,
        (kasa.data ?? [])[0]?.tarih ?? null,
      ].filter((g): g is string => g !== null)

      // Lexicographic min is the real min for 'YYYY-MM-DD'.
      return gunler.length ? gunler.reduce((a, b) => (a < b ? a : b)) : istanbulGun()
    },
  })
}

/**
 * Resolves a period chip to a concrete `[bas, bit]` range.
 *
 * `hazir` is the part that matters: for "Tümü" the start date has to be
 * fetched, and firing the report queries before it arrives would show a
 * day's figures and then swap them for all-time ones a moment later. On a
 * money screen that is not a flicker, it is a wrong number being read.
 */
export function useDonemAralik(donem: Donem, ozel?: DonemAralik | null) {
  const ilk = useIlkGun(donem === 'TUMU')
  const aralik = useMemo(() => donemAralik(donem, ilk.data, ozel), [donem, ilk.data, ozel])
  return {
    ...aralik,
    hazir: donem !== 'TUMU' || ilk.data != null,
    ilkGunHatasi: ilk.error,
  }
}

/* ============================================================== reports === */

/** rpc -> TABLE with exactly one row. */
export function useRaporOzet(bas: string, bit: string, enabled = true) {
  return useQuery({
    queryKey: ['rapor_ozet', bas, bit],
    enabled,
    queryFn: async (): Promise<RaporOzet | null> => {
      const { data, error } = await supabase.rpc('rapor_ozet', { p_bas: bas, p_bit: bit })
      if (error) throw error
      return ((data ?? [])[0] as RaporOzet) ?? null
    },
  })
}

export interface YontemOzet {
  yontem: OdemeYontemi
  gelir_kurus: number
  gider_kurus: number
}

/**
 * Money per payment channel for the period.
 *
 * Server-side on purpose, from the same two tables and the same date rules
 * `rapor_ozet` uses — summing it here from separately-fetched rows would give
 * two numbers that drift apart and no way to say which is right.
 *
 * Rows with no method are counted by NEITHER bucket, so the three can total
 * less than Net. That is missing data, not a bug: `yontem` is optional on a
 * kasa entry, and inventing a bucket for it would state something nobody
 * recorded.
 */
export function useYontemOzet(bas: string, bit: string, enabled = true) {
  return useQuery({
    queryKey: ['yontem_ozet', bas, bit],
    enabled,
    queryFn: async (): Promise<YontemOzet[]> => {
      const { data, error } = await supabase.rpc('yontem_ozet', { p_bas: bas, p_bit: bit })
      if (error) throw error
      return (data ?? []) as YontemOzet[]
    },
  })
}

/* ------------------------------------------------- client-side breakdowns */

export interface RaporDetay {
  /** Entry counts per Istanbul hour, index 0–23. */
  saatlik: number[]
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
export function useRaporDetay(bas: string, bit: string, enabled = true) {
  return useQuery({
    queryKey: ['rapor_detay', bas, bit],
    enabled,
    queryFn: async (): Promise<RaporDetay> => {
      // Widened by a day on each side because these bounds are UTC instants
      // while `bas`/`bit` are ISTANBUL calendar days. The exact day test
      // happens below with the same Intl-based helper the rest of the app
      // uses, so this only has to be a superset — no offset is assumed here.
      const { data, error } = await supabase
        .from('biletler')
        .select('giris_at,cikis_at,durum')
        .gte('giris_at', `${gunEkle(-1, bas)}T00:00:00Z`)
        .lte('giris_at', `${gunEkle(1, bit)}T23:59:59Z`)
        .limit(DETAY_LIMIT)

      if (error) throw error
      const satirlar = (data ?? []) as Pick<Bilet, 'giris_at' | 'cikis_at' | 'durum'>[]

      const saatlik = Array.from({ length: 24 }, () => 0)
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

        if (b.cikis_at) {
          cikanSayisi++
          const dk = dakikaFarki(b.giris_at, b.cikis_at)
          const i = SURE_KOVALARI.findIndex((k) => dk < k.max)
          sureSayac[i === -1 ? SURE_KOVALARI.length - 1 : i]!++
        }
      }

      return {
        saatlik,
        sureler: SURE_KOVALARI.map((k, i) => ({ etiket: k.etiket, sayi: sureSayac[i]! })),
        girisSayisi,
        cikanSayisi,
        kesildi: satirlar.length >= DETAY_LIMIT,
      }
    },
  })
}

/** rpc -> TABLE, one row per day including days with no revenue. */
export function useRaporGunluk(bas: string, bit: string, enabled = true) {
  return useQuery({
    queryKey: ['rapor_gunluk', bas, bit],
    enabled,
    queryFn: async (): Promise<RaporGun[]> => {
      const { data, error } = await supabase.rpc('rapor_gunluk', { p_bas: bas, p_bit: bit })
      if (error) throw error
      return (data ?? []) as RaporGun[]
    },
  })
}

/* ============================================================== tariffs === */

/**
 * Closed tariff versions, newest first.
 *
 * The ACTIVE tariff is deliberately excluded — it lives at the top of the
 * screen as the current price, and `tarife_sil` refuses it anyway (deleting it
 * would leave the gate with no price at all).
 *
 * `biletler.tarife_id` is ON DELETE RESTRICT, so most rows here cannot be
 * deleted either: any version that ever priced a ticket is pinned by it. That
 * is not something the client can know without counting tickets, so the delete
 * is offered and the RPC answers — in Turkish — when it is refused.
 */
export function useTarifeGecmisi() {
  return useQuery({
    queryKey: ['tarifeler', 'gecmis'],
    queryFn: async (): Promise<Tarife[]> => {
      const { data, error } = await supabase
        .from('tarifeler')
        .select('*')
        .not('gecerli_bitis', 'is', null)
        .order('gecerli_bitis', { ascending: false })
        .limit(50)
      if (error) throw error
      return data as Tarife[]
    },
  })
}

/* ================================================================= kasa === */

export function useKasaHareketleri(bas: string, bit: string, enabled = true) {
  return useQuery({
    queryKey: ['kasa', bas, bit],
    enabled,
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

/* ---------------------------------------------------- düzenli kayıtlar --- */

export interface KasaTekrarKurali {
  id: string
  tur: KasaTur
  tutar_kurus: number
  kategori: string | null
  aciklama: string
  yontem: OdemeYontemi | null
  odeme_gunu: number
  next_run: string
  is_active: boolean
}

export function useKasaTekrarKurallari() {
  return useQuery({
    queryKey: ['kasa_tekrar'],
    queryFn: async (): Promise<KasaTekrarKurali[]> => {
      const { data, error } = await supabase
        .from('kasa_tekrar_kurallari')
        .select('*')
        .eq('is_active', true)
        .order('odeme_gunu')
      if (error) throw error
      return (data ?? []) as KasaTekrarKurali[]
    },
  })
}

/**
 * The rule AND this month's entry, in one call.
 *
 * Deliberately an RPC rather than two inserts from here: half of it failing
 * would leave either a rule with no first entry or an entry that never
 * repeats, and the operator would have no way to tell which. The server also
 * decides `next_run` — strictly after today, so tonight's job cannot write
 * the same expense a second time.
 */
export function useKasaTekrarEkle() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (g: {
      tur: KasaTur
      tutar_kurus: number
      aciklama: string
      kategori: string | null
      yontem: OdemeYontemi | null
      gun: number
    }) => {
      const { error } = await supabase.rpc('kasa_tekrar_ekle', {
        p_tur: g.tur,
        p_tutar: g.tutar_kurus,
        p_gun: g.gun,
        p_kategori: g.kategori,
        p_aciklama: g.aciklama,
        p_yontem: g.yontem,
      })
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['kasa'] })
      void qc.invalidateQueries({ queryKey: ['kasa_tekrar'] })
    },
  })
}

/**
 * Stopping is a soft flag, not a delete: the entries a rule already wrote
 * stay in the kasa either way, and keeping the row means the audit trail can
 * still say what produced them.
 */
export function useKasaTekrarDurdur() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (id: string) => {
      const { error } = await supabase
        .from('kasa_tekrar_kurallari')
        .update({ is_active: false })
        .eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['kasa_tekrar'] })
    },
  })
}

export function useKasaSil() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (id: string) => {
      // Via RPC, not a direct DELETE: 007 revoked that grant so no delete
      // can skip the recycle-bin snapshot.
      const { error } = await supabase.rpc('kayit_sil', {
        p_tablo: 'kasa_hareketleri',
        p_id: id,
      })
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['kasa'] })
      void qc.invalidateQueries({ queryKey: ['cop'] })
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
        // The collection rides along so the list can show whether the money
        // has been approved. One query, not a second round trip keyed on 200
        // ids — and RLS still applies to the embedded rows.
        .select('*, tahsilat:tahsilatlar(durum,iptal_of)')
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

/**
 * Approved bilet and abonman collections in a period.
 *
 * The Kasa screen shows these alongside its own entries, so the till reads as
 * one ledger. Only ONAYLANDI rows: unapproved money has not been accepted into
 * the books, and the Onay screen is where it lives until it is.
 *
 * The window is exact rather than widened-and-refiltered, because Turkey is
 * UTC+3 all year (no DST since 2016) — so an Istanbul calendar day IS a fixed
 * instant range, and the server can do the whole filter.
 */
export function useOnayliTahsilatlar(bas: string, bit: string, enabled = true) {
  return useQuery({
    queryKey: ['kasa_tahsilat', bas, bit],
    enabled,
    queryFn: async (): Promise<Tahsilat[]> => {
      const { data, error } = await supabase
        .from('tahsilatlar')
        .select('*')
        .eq('durum', 'ONAYLANDI')
        .gte('created_at', `${bas}T00:00:00+03:00`)
        .lt('created_at', `${gunEkle(1, bit)}T00:00:00+03:00`)
        .order('created_at', { ascending: false })
        // A busy month is a few thousand tickets. The cap keeps a "Tümü" view
        // from pulling years of rows into a phone; the figures on Finans are
        // the server-side ones and are not affected by it.
        .limit(1000)
      if (error) throw error
      return data as Tahsilat[]
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

/**
 * Yönetici closes a shift that its owner cannot.
 *
 * `sayilan` is optional and that is the whole point: an operator who never
 * came back never counted the drawer, and writing a number nobody counted
 * would turn a real shortfall into a permanent "tutuyor". Null in, null
 * stored, question stays visible.
 */
export function useVardiyaZorlaKapat() {
  const qc = useQueryClient()
  return useMutation({
    // Closing decides money and can raise a discrepancy alert. A blind retry
    // would re-run that against a shift that is already closed.
    retry: false,
    mutationFn: async ({
      id,
      sayilan,
      notlar,
    }: {
      id: string
      sayilan: number | null
      notlar: string | null
    }) => {
      const { error } = await supabase.rpc('vardiya_zorla_kapat', {
        p_vardiya_id: id,
        p_sayilan_nakit_kurus: sayilan,
        p_notlar: notlar,
      })
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['tum_vardiyalar'] })
      void qc.invalidateQueries({ queryKey: ['vardiya_ozetim'] })
    },
  })
}

/* ================================================================= onay === */

export interface OnayKayit {
  id: string
  tur: TahsilatTur
  tutar_kurus: number
  yontem: OdemeYontemi
  aciklama: string | null
  created_at: string
  durum: OnayDurum
  etiket: string
  personel: string
  onay_notu: string | null
}

/**
 * The approval gate on collected money.
 *
 * Bilet and abonman collections are born BEKLIYOR and reach Finans only once
 * the Yönetici accepts them. Two consequences worth stating here, because
 * every screen in this file depends on them:
 *
 *  - Ciro, the daily chart and the method split count ONAYLANDI rows only.
 *    That filter lives in the RPCs, not here — a client-side filter would be
 *    a second opinion about revenue, and the server already has one.
 *  - Shift reconciliation (`vardiya_ozetim`, `vardiya_kapat`) counts every
 *    row whatever its state, because the cash is in the drawer whether or not
 *    the owner has accepted it into the books. Do not "fix" that to match
 *    Finans: it would invent a discrepancy on every unapproved shift.
 */
export function useOnayOzet(enabled = true) {
  return useQuery({
    queryKey: ['onay_ozet'],
    enabled,
    queryFn: async (): Promise<{ adet: number; toplam_kurus: number }> => {
      const { data, error } = await supabase.rpc('onay_ozet')
      if (error) throw error
      const r = (data ?? [])[0] as { adet: number; toplam_kurus: number } | undefined
      return r ?? { adet: 0, toplam_kurus: 0 }
    },
  })
}

export function useOnayListesi(durum: OnayDurum) {
  return useQuery({
    queryKey: ['onay', durum],
    queryFn: async (): Promise<OnayKayit[]> => {
      const { data, error } = await supabase.rpc('onay_listesi', { p_durum: durum })
      if (error) throw error
      return (data ?? []) as OnayKayit[]
    },
  })
}

/**
 * Every figure a decision moves. Listed once so approve, bulk-approve and
 * reject cannot drift into refreshing different parts of the screen.
 */
function onayTazele(qc: ReturnType<typeof useQueryClient>) {
  for (const k of ['onay', 'onay_ozet', 'rapor_ozet', 'rapor_gunluk', 'rapor_detay', 'yontem_ozet']) {
    void qc.invalidateQueries({ queryKey: [k] })
  }
}

/**
 * Approve or reject, one row or a hundred, through one path: the client
 * always sends an array.
 *
 * Both RPCs are a single atomic UPDATE filtered on `durum = 'BEKLIYOR'`, so
 * there is no read-then-write race to lose and an already-decided row is
 * skipped rather than failing the batch. They return HOW MANY rows they
 * actually moved — the caller must compare that with what it sent instead of
 * assuming success, because "nothing happened" and "all of it happened" are
 * otherwise indistinguishable.
 */
export function useTahsilatOnayla() {
  const qc = useQueryClient()
  return useMutation({
    // Money decisions never retry themselves: the operator is here and can
    // press it again, and a silent replay is how something gets decided twice.
    retry: false,
    mutationFn: async (ids: string[]): Promise<number> => {
      const { data, error } = await supabase.rpc('tahsilat_onayla', { p_ids: ids })
      if (error) throw error
      return (data as number) ?? 0
    },
    onSuccess: () => onayTazele(qc),
  })
}

export function useTahsilatReddet() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (v: { ids: string[]; sebep: string }): Promise<number> => {
      const { data, error } = await supabase.rpc('tahsilat_reddet', {
        p_ids: v.ids,
        p_sebep: v.sebep.trim() || null,
      })
      if (error) throw error
      return (data as number) ?? 0
    },
    onSuccess: () => onayTazele(qc),
  })
}
