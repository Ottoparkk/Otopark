import type { Profile } from './types'

/**
 * Client-side role helpers.
 *
 * ⚠ These are for LAYOUT ONLY — showing the right nav, hiding a button that
 * would only produce an error. They are NOT the security boundary and must
 * never be the only thing standing between a Personel and a Yönetici
 * surface. Every protected read is refused by RLS and every protected write
 * by the RPC itself; hiding a button is cosmetic.
 */

export function isYonetici(profile: Profile | null): boolean {
  return profile?.rol === 'YONETICI' && profile.durum === 'ACTIVE'
}

export function isStaff(profile: Profile | null): boolean {
  return profile != null && profile.rol !== null && profile.durum === 'ACTIVE'
}

/** Signed in but not yet approved — gets the waiting screen, not the app. */
export function isPending(profile: Profile | null): boolean {
  return profile != null && (profile.durum === 'PENDING' || profile.rol === null)
}

export function isDisabled(profile: Profile | null): boolean {
  return profile?.durum === 'DISABLED'
}

/** Where a signed-in user belongs when they land on "/". */
export function anaSayfa(profile: Profile | null): string {
  return isYonetici(profile) ? '/yonetim' : '/gise'
}
