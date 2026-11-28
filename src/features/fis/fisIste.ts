import type { AcikBilet, Profile } from '../../lib/types'

/**
 * Who gets the fiş buttons (owner 28.11): Personel — they work on the P2, the
 * terminal with the printer. A Yönetici has no printer, so no button.
 * Layout only: `fis_basildi` checks staff on the server.
 */
export function fisYazdirir(profile: Pick<Profile, 'rol' | 'durum'> | null): boolean {
  return profile?.rol === 'PERSONEL' && profile.durum === 'ACTIVE'
}

/** How long Gişe keeps asking for a camera entry's fiş (owner 28.11, my number). */
export const FIS_ISTE_DK = 60

/**
 * The camera tickets Gişe should ask a fiş for ("Gişe asks to print", owner
 * 28.11): opened by the camera in the last hour, not an abonman. Whether one
 * was already printed is the caller's second step (`useGirisFisleri`).
 * A hand entry is not here — whoever typed it is standing at the car.
 */
export function fisAdaylari(
  biletler: Pick<AcikBilet, 'id' | 'giris_kaynak' | 'giris_at' | 'abonman_id'>[],
  simdi: number,
): string[] {
  const sinir = simdi - FIS_ISTE_DK * 60_000
  return biletler
    .filter((b) => b.giris_kaynak === 'KAMERA' && !b.abonman_id && new Date(b.giris_at).getTime() >= sinir)
    .map((b) => b.id)
}
