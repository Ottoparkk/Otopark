/**
 * Becoming a terminal, the Personel list, PIN sign-in, and who is signed in
 * (spec 2026-11-28; the same 084 server flow as src/features/terminal).
 * Type-only imports; the terminal helpers come in as `araclar`
 * (tests/terminalOturum.check.mjs).
 */
import type { TerminalKaydi, TerminalDeposu, pinGecerli, terminalYaz } from '../../src/features/terminal/terminal'
import type { Sunucu } from './sunucu'

export interface OturumAraclari {
  terminalYaz: typeof terminalYaz
  pinGecerli: typeof pinGecerli
}

export interface TerminalPersonel {
  id: string
  ad_soyad: string
}

export interface Ben {
  id: string
  ad_soyad: string
  rol: string | null
}

/**
 * Kurulum: a Yönetici signs in once on the P2, the device is registered
 * (terminal_kaydet keeps only the secret's hash) and the Yönetici is signed
 * out again — also when registering fails, so nobody stays signed in as a
 * Yönetici on the shared device.
 */
export async function kurulumYap(
  s: Sunucu,
  depo: TerminalDeposu,
  g: { eposta: string; sifre: string; ad: string },
  a: OturumAraclari,
): Promise<TerminalKaydi> {
  const ad = g.ad.trim()
  if (!ad) throw new Error('Cihaza bir ad verin.')
  await s.sifreyleGir(g.eposta.trim(), g.sifre)
  try {
    const kayit = await s.rpc<TerminalKaydi>('terminal_kaydet', { p_ad: ad })
    a.terminalYaz(depo, kayit)
    return kayit
  } finally {
    await s.cikis()
  }
}

export async function personelListesi(s: Sunucu, t: TerminalKaydi): Promise<TerminalPersonel[]> {
  const g = await s.fn<{ personel?: TerminalPersonel[] }>('terminal-giris', { islem: 'liste', gizli: t.gizli })
  return (g && g.personel) || []
}

/** PIN sign-in; the server also hands the open shift over (vardiya_devret). */
export async function pinIleGir(
  s: Sunucu,
  t: TerminalKaydi,
  profileId: string,
  pin: string,
  a: OturumAraclari,
): Promise<void> {
  if (!a.pinGecerli(pin)) throw new Error('PIN 4 rakam olmalı.')
  const g = await s.fn<{ token_hash?: string }>('terminal-giris', {
    islem: 'giris',
    gizli: t.gizli,
    profile_id: profileId,
    pin,
  })
  const tokenHash = g && g.token_hash
  if (!tokenHash) throw new Error('Giriş yapılamadı.')
  await s.dogrula(tokenHash)
}

export async function benKimim(s: Sunucu): Promise<Ben> {
  const o = s.oturum()
  if (!o) throw new Error('Oturum sona erdi. PIN ile tekrar girin.')
  const satirlar = await s.sec<Ben>('profiles', `select=id,ad_soyad,rol&id=eq.${o.user_id}`)
  const ben = satirlar[0]
  if (!ben) throw new Error('Hesap bulunamadı.')
  return ben
}
