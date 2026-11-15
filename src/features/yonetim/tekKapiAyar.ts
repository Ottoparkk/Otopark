/**
 * The two single-gate windows (037, 068), checked the way Postgres checks them.
 *
 *   tek_kapi_giris_yoksay_dk  2-60  a car seen again this soon after its
 *                                   ticket opened is ignored, not flagged as
 *                                   leaving (the bridge re-sends a car that
 *                                   stays in view; 068 lowered the minimum
 *                                   from 3 to 2 because 1.4.x re-sends carry a
 *                                   direction hint; camera and hand-typed
 *                                   tickets alike)
 *   tek_kapi_cikis_yoksay_dk  1-60  a car seen again this soon after its
 *                                   ticket closed is ignored, not given a new
 *                                   ticket
 *
 * Mirrors otopark_ayarlari_tek_kapi_giris_ck / _cikis_ck, so a bad value is
 * explained on the screen instead of arriving as a refusal after Kaydet.
 * No imports: tests/ayar.check.mjs loads this file with plain Node.
 */
const TAM_SAYI = /^[0-9]+$/

function aralikta(deger: string, en_az: number, en_cok: number): boolean {
  if (!TAM_SAYI.test(deger)) return false
  const n = Number(deger)
  return n >= en_az && n <= en_cok
}

export function tekKapiHatasi(giris: string, cikis: string): string | null {
  if (!aralikta(giris, 2, 60)) {
    return 'Tek kapı: girişten sonra yok sayma 2-60 dakika arasında olmalı.'
  }
  if (!aralikta(cikis, 1, 60)) {
    return 'Tek kapı: çıkıştan sonra yok sayma 1-60 dakika arasında olmalı.'
  }
  return null
}
