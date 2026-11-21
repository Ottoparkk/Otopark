/**
 * The camera banner on Gişe (070). Owner 2026-11-17 said all staff; changed
 * 2026-11-18 to the Yönetici only (Gise.tsx renders it only for them and
 * kamera_durum_ozet refuses Personel).
 *
 * `kamera_durum_ozet` answers one of six words and nothing else — no plate,
 * no count, no camera name. Anything this does not know stays SILENT: a
 * banner that cries wolf is the first thing staff learn to ignore.
 *
 * No imports, so `tests/kameraSaglik.check.mjs` can run it from Node.
 */
export type KameraSeridi = { ton: 'danger' | 'warn'; metin: string }

export function kameraSeridi(durum: string | null | undefined): KameraSeridi | null {
  switch (durum) {
    case 'HABER_YOK':
      return {
        ton: 'danger',
        metin: 'Kameradan haber yok — araçlar kendiliğinden kaydedilmiyor olabilir',
      }
    case 'REDDEDILIYOR':
      return {
        ton: 'danger',
        metin: 'Sunucu kamera araçlarını reddediyor — bazı araçlar kaydedilmedi',
      }
    case 'KUYRUK_TAKILDI':
      return { ton: 'warn', metin: 'Kamera araçları sunucuya gönderemiyor — kayıtlar gecikiyor' }
    case 'IZLEME_KAPANDI':
      return {
        ton: 'warn',
        metin: 'Kamera araç izlemesi kapandı — daha çok çözülmemiş kayıt çıkabilir',
      }
    // 073: camera input switched off in Ayarlar — the cars the camera sees
    // are thrown away (owner, 2026-11-20), so they must be entered by hand.
    case 'KAPALI':
      return { ton: 'warn', metin: 'Kamera girişi kapalı — araçları elle kaydedin' }
    default:
      return null
  }
}
