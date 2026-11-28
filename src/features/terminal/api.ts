import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { ekranHafizasiniTemizle } from '../../lib/useEkranDurumu'
import { getPushSubscription, enablePush } from '../../lib/push'
import type { TerminalKaydi } from './terminal'
import type { PersonelVardiyaSaati } from '../../lib/types'

export interface TerminalPersonel {
  id: string
  ad_soyad: string
}

export interface TerminalSatiri {
  id: string
  ad: string
  aktif: boolean
  son_gorulme: string | null
  olusturan: string | null
  created_at: string
}

/**
 * The message an Edge Function put in its `hata` field. A non-2xx answer
 * arrives as an error whose `context` is the Response; its body is ours.
 */
export async function edgeHatasi(error: unknown, varsayilan: string): Promise<string> {
  const ctx = (error as { context?: unknown })?.context
  if (ctx && typeof (ctx as Response).json === 'function') {
    try {
      const govde = (await (ctx as Response).clone().json()) as { hata?: unknown }
      if (typeof govde?.hata === 'string' && govde.hata) return govde.hata
    } catch {
      /* not JSON */
    }
  }
  return varsayilan
}

/** Names on the terminal's Devral list (workers who have a PIN). */
export function useTerminalListe(terminal: TerminalKaydi | null, acik: boolean) {
  return useQuery({
    queryKey: ['terminal_liste', terminal?.id],
    enabled: Boolean(terminal) && acik,
    staleTime: 0,
    retry: false,
    queryFn: async (): Promise<TerminalPersonel[]> => {
      const { data, error } = await supabase.functions.invoke('terminal-giris', {
        body: { islem: 'liste', gizli: terminal!.gizli },
      })
      if (error) throw new Error(await edgeHatasi(error, 'Personel listesi alınamadı.'))
      return ((data as { personel?: TerminalPersonel[] })?.personel ?? [])
    },
  })
}

/**
 * Name + PIN → the worker's own session on this device. Screen memory goes
 * first (the next person starts clean); AuthProvider drops the query cache
 * when the identity changes. Push is moved to the new worker if this device
 * already had permission, so the shift's notices reach whoever holds it.
 */
export function useDevral() {
  return useMutation({
    retry: false,
    mutationFn: async ({
      terminal,
      profileId,
      pin,
    }: {
      terminal: TerminalKaydi
      profileId: string
      pin: string
    }) => {
      const { data, error } = await supabase.functions.invoke('terminal-giris', {
        body: { islem: 'giris', gizli: terminal.gizli, profile_id: profileId, pin },
      })
      if (error) throw new Error(await edgeHatasi(error, 'Giriş yapılamadı.'))
      const tokenHash = (data as { token_hash?: string })?.token_hash
      if (!tokenHash) throw new Error('Giriş yapılamadı.')

      ekranHafizasiniTemizle()
      const { error: otpHata } = await supabase.auth.verifyOtp({
        token_hash: tokenHash,
        type: 'email',
      })
      if (otpHata) throw new Error('Giriş yapılamadı. Tekrar deneyin.')

      // Best effort: never block the handover on push.
      try {
        if (await getPushSubscription()) await enablePush()
      } catch {
        /* ignore */
      }
    },
  })
}

// ------------------------------------------------------------- Yönetici --

export function useTerminaller() {
  return useQuery({
    queryKey: ['terminaller'],
    queryFn: async (): Promise<TerminalSatiri[]> => {
      const { data, error } = await supabase
        .from('terminaller')
        .select('id,ad,aktif,son_gorulme,olusturan,created_at')
        .order('created_at', { ascending: true })
      if (error) throw error
      return (data ?? []) as TerminalSatiri[]
    },
  })
}

export function useTerminalKaydet() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (ad: string): Promise<TerminalKaydi> => {
      const { data, error } = await supabase.rpc('terminal_kaydet', { p_ad: ad })
      if (error) throw error
      return data as TerminalKaydi
    },
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['terminaller'] }),
  })
}

export function useTerminalKaldir() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await supabase.rpc('terminal_kaldir', { p_id: id })
      if (error) throw error
    },
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['terminaller'] }),
  })
}

export function usePinAyarla() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ profileId, pin }: { profileId: string; pin: string }) => {
      const { error } = await supabase.rpc('pin_ayarla', { p_profile_id: profileId, p_pin: pin })
      if (error) throw error
    },
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['personel_listesi'] }),
  })
}

/** Yönetici adds a worker with only a name and a PIN (personel-olustur). */
export function usePersonelOlustur() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({ adSoyad, pin }: { adSoyad: string; pin: string }) => {
      const { data, error } = await supabase.functions.invoke('personel-olustur', {
        body: { ad_soyad: adSoyad, pin },
      })
      if (error) throw new Error(await edgeHatasi(error, 'Personel eklenemedi.'))
      return data as { id: string }
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['personel_listesi'] })
      void qc.invalidateQueries({ queryKey: ['profiller'] })
    },
  })
}

// ------------------------------------------------- 085: shift hours --

/** Active Personel with their shift hours (everyone can read these). */
export function useVardiyaSaatleri() {
  return useQuery({
    queryKey: ['vardiya_saatleri'],
    queryFn: async (): Promise<PersonelVardiyaSaati[]> => {
      const { data, error } = await supabase
        .from('profiles')
        .select('id,ad_soyad,vardiya_baslangic,vardiya_bitis')
        .eq('rol', 'PERSONEL')
        .eq('durum', 'ACTIVE')
        .order('ad_soyad')
      if (error) throw error
      return (data ?? []) as PersonelVardiyaSaati[]
    },
  })
}

export function usePersonelVardiyaSaati() {
  const qc = useQueryClient()
  return useMutation({
    mutationFn: async ({
      profileId,
      baslangic,
      bitis,
    }: {
      profileId: string
      baslangic: string | null
      bitis: string | null
    }) => {
      const { error } = await supabase.rpc('personel_vardiya_saati', {
        p_id: profileId,
        p_baslangic: baslangic,
        p_bitis: bitis,
      })
      if (error) throw error
    },
    onSuccess: () => void qc.invalidateQueries({ queryKey: ['vardiya_saatleri'] }),
  })
}
