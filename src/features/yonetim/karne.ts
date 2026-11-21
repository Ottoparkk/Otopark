/**
 * The camera scorecard and the bridge-health line on Kamera Kurulumu (070).
 *
 * The numbers come from Postgres (`kamera_karne`, `kamera_saglik`); this only
 * adds them up and words them. No imports, so `tests/kameraSaglik.check.mjs`
 * can run it from Node.
 */

/** One Istanbul day of `kamera_karne` (070). */
export interface KarneGun {
  gun: string
  kamera_giris: number
  elle_giris: number
  kamera_cikis: number
  elle_cikis: number
  kart: number
  kart_plakasiz: number
  kart_tur: Record<string, number>
  geri_acilan: number
  yon_bilinmiyor: number
  gecikme_sn: number | null
}

/** Share of the cars the camera handled, as a whole percent; null with no cars. */
export function kameraPayi(kamera: number, elle: number): number | null {
  const toplam = kamera + elle
  return toplam > 0 ? Math.round((kamera * 100) / toplam) : null
}

export interface KarneOzeti {
  giris: number
  kameraGirisPayi: number | null
  cikis: number
  kameraCikisPayi: number | null
  kart: number
  kartPlakasiz: number
  geriAcilan: number
  yonBilinmiyor: number
}

export function karneOzeti(gunler: KarneGun[]): KarneOzeti {
  let kg = 0
  let eg = 0
  let kc = 0
  let ec = 0
  let kart = 0
  let plakasiz = 0
  let geri = 0
  let yonsuz = 0
  for (const g of gunler) {
    kg += g.kamera_giris
    eg += g.elle_giris
    kc += g.kamera_cikis
    ec += g.elle_cikis
    kart += g.kart
    plakasiz += g.kart_plakasiz
    geri += g.geri_acilan
    yonsuz += g.yon_bilinmiyor
  }
  return {
    giris: kg + eg,
    kameraGirisPayi: kameraPayi(kg, eg),
    cikis: kc + ec,
    kameraCikisPayi: kameraPayi(kc, ec),
    kart,
    kartPlakasiz: plakasiz,
    geriAcilan: geri,
    yonBilinmiyor: yonsuz,
  }
}

function sayi(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

const IZLEME: Record<string, string> = {
  acik: 'İzleme açık',
  kapali: 'İzleme kapalı',
  kapandi: 'İzleme kapandı',
}

/**
 * The bridge's last heartbeat numbers as short phrases. A number an older
 * bridge does not send is simply not written; a wrong type is dropped.
 */
export function saglikParcalari(bilgi: Record<string, unknown> | null | undefined): string[] {
  if (!bilgi) return []
  const p: string[] = []
  if (typeof bilgi.surum === 'string') p.push('Sürüm ' + bilgi.surum)
  if (typeof bilgi.kume === 'string') p.push(bilgi.kume)
  const fps = sayi(bilgi.fps)
  if (fps !== null) p.push(fps.toFixed(1).replace('.', ',') + ' kare/sn')
  const kuyruk = sayi(bilgi.kuyruk)
  if (kuyruk !== null) {
    if (kuyruk <= 0) {
      p.push('Kuyruk boş')
    } else {
      const eski = sayi(bilgi.kuyruk_en_eski_sn)
      const dk = eski !== null && eski >= 60 ? Math.round(eski / 60) : null
      p.push(`Kuyrukta ${kuyruk} araç` + (dk !== null ? ` (en eskisi ${dk} dk)` : ''))
    }
  }
  const red = sayi(bilgi.reddedilen)
  if (red !== null && red > 0) p.push(`Son saatte ${red} araç reddedildi`)
  // 1.4.3 (1a): kenardaki parça aynı aracın kararına sayılırdı (PARCA_EMME=0) / sayıldı.
  const emilirdi = sayi(bilgi.emilirdi)
  if (emilirdi !== null && emilirdi > 0) p.push(`Son saatte ${emilirdi} parça aynı araca sayılırdı`)
  const emildi = sayi(bilgi.emildi)
  if (emildi !== null && emildi > 0) p.push(`Son saatte ${emildi} parça aynı araca sayıldı`)
  const izleme = typeof bilgi.takip === 'string' ? IZLEME[bilgi.takip] : undefined
  if (izleme) p.push(izleme)
  return p
}
