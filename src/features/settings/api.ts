import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import type { Bildirim, Profile } from '../../lib/types'

/**
 * Unread badge count.
 *
 * `enabled` is passed in rather than checked here: every notification type is
 * currently Yönetici-only, and the RLS policy re-checks the CURRENT role on
 * every read — so a demoted user correctly sees zero. Skipping the query for
 * Personel just avoids a pointless round trip on every app open.
 */
export function useOkunmamisSayisi(enabled: boolean) {
  return useQuery({
    queryKey: ['bildirim_sayisi'],
    enabled,
    queryFn: async (): Promise<number> => {
      const { count, error } = await supabase
        .from('notifications')
        .select('id', { count: 'exact', head: true })
        .is('read_at', null)
      if (error) throw error
      return count ?? 0
    },
    staleTime: 30_000,
    refetchInterval: 120_000,
  })
}

export function useBildirimler() {
  return useQuery({
    queryKey: ['bildirimler'],
    queryFn: async (): Promise<Bildirim[]> => {
      const { data, error } = await supabase
        .from('notifications')
        .select('*')
        .order('created_at', { ascending: false })
        .limit(100)
      if (error) throw error
      return data as Bildirim[]
    },
  })
}

/** Marks everything currently unread as read — called when the screen opens. */
export function useHepsiniOkundu() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async () => {
      const { error } = await supabase
        .from('notifications')
        .update({ read_at: new Date().toISOString() })
        .is('read_at', null)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['bildirimler'] })
      void qc.invalidateQueries({ queryKey: ['bildirim_sayisi'] })
    },
  })
}

/** Own name and notification preferences. rol/durum have NO client write path. */
export function useProfilGuncelle() {
  const qc = useQueryClient()
  return useMutation({
    retry: false,
    mutationFn: async (yama: Partial<Pick<Profile, 'ad_soyad' | 'notif_prefs'>>) => {
      const { data: sess } = await supabase.auth.getUser()
      const id = sess.user?.id
      if (!id) throw new Error('Oturum bulunamadı.')
      const { error } = await supabase.from('profiles').update(yama).eq('id', id)
      if (error) throw error
    },
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ['profil'] })
    },
  })
}
