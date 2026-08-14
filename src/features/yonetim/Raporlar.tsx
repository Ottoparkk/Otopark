import { useMemo, useState } from 'react'
import { Card, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { DonemSecici, IstatKutu, SutunGrafik, donemAralik, type Donem } from './components'
import { useRaporGunluk, useRaporOzet } from './api'
import { formatTL } from '../../lib/money'
import { formatSure } from '../../lib/sure'

export default function Raporlar() {
  const [donem, setDonem] = useState<Donem>('HAFTA')
  const { bas, bit } = useMemo(() => donemAralik(donem), [donem])

  const ozet = useRaporOzet(bas, bit)
  const gunluk = useRaporGunluk(bas, bit)

  const grafik = useMemo(
    () => (gunluk.data ?? []).map((g) => ({ gun: g.gun, kurus: g.ciro_kurus })),
    [gunluk.data],
  )

  const yontemToplam = useMemo(() => {
    const g = gunluk.data ?? []
    return {
      nakit: g.reduce((a, x) => a + x.nakit_kurus, 0),
      kart: g.reduce((a, x) => a + x.kart_kurus, 0),
      havale: g.reduce((a, x) => a + x.havale_kurus, 0),
    }
  }, [gunluk.data])

  return (
    <div>
      <ScreenHeader title="Raporlar" back="/yonetim" />

      <div className="space-y-4 px-5">
        <DonemSecici value={donem} onChange={setDonem} />

        {ozet.error ? (
          <LoadError error={ozet.error} onRetry={() => void ozet.refetch()} />
        ) : ozet.isPending ? (
          <div className="py-14">
            <Spinner label="Rapor hazırlanıyor" />
          </div>
        ) : (
          <>
            <Card>
              <p className="text-label font-medium tracking-wide text-faint uppercase">Ciro</p>
              <p className="mt-2 text-hero font-semibold text-ink tnum">
                {formatTL(ozet.data?.ciro_kurus ?? 0, { decimals: 0 })}
              </p>
              <p className="mt-0.5 text-label text-faint">
                {ozet.data?.bilet_sayisi ?? 0} tamamlanan çıkış
              </p>

              <div className="mt-5 grid grid-cols-3 gap-2 border-t border-divider pt-4">
                <IstatKutu
                  deger={formatTL(yontemToplam.nakit, { decimals: 0 })}
                  etiket="nakit"
                />
                <IstatKutu deger={formatTL(yontemToplam.kart, { decimals: 0 })} etiket="kart" />
                <IstatKutu
                  deger={formatTL(yontemToplam.havale, { decimals: 0 })}
                  etiket="havale"
                />
              </div>
            </Card>

            {grafik.length > 1 && (
              <Card>
                <p className="mb-3 text-label font-medium tracking-wide text-faint uppercase">
                  Günlük ciro
                </p>
                {gunluk.isPending ? <Spinner /> : <SutunGrafik veri={grafik} />}
              </Card>
            )}

            <Card>
              <div className="grid grid-cols-2 gap-4">
                <IstatKutu
                  deger={
                    ozet.data?.ortalama_dakika
                      ? formatSure(Math.round(ozet.data.ortalama_dakika))
                      : '—'
                  }
                  etiket="ortalama kalış"
                />
                <IstatKutu deger={String(ozet.data?.saatlik_giris ?? 0)} etiket="ücretli giriş" />
                <IstatKutu deger={String(ozet.data?.abonman_giris ?? 0)} etiket="abonman girişi" />
                <IstatKutu deger={String(ozet.data?.iptal_sayisi ?? 0)} etiket="iptal" />
              </div>
            </Card>

            {/* The two numbers that matter most in a cash business, kept
                together and out of the headline stats so they are noticed. */}
            <Card>
              <p className="mb-3 text-label font-medium tracking-wide text-faint uppercase">
                Denetim
              </p>
              <div className="grid grid-cols-2 gap-4">
                <IstatKutu
                  deger={String(ozet.data?.ucret_degisiklik_sayisi ?? 0)}
                  etiket="elle değiştirilen ücret"
                  tone={(ozet.data?.ucret_degisiklik_sayisi ?? 0) > 0 ? 'danger' : 'default'}
                />
                <IstatKutu
                  deger={formatTL(ozet.data?.puan_borcu_kurus ?? 0, { decimals: 0 })}
                  etiket="dolaşımdaki puan borcu"
                />
              </div>
              <p className="mt-3 text-label text-faint">
                Puan borcu, müşterilere karşı birikmiş yükümlülüktür — dönemden
                bağımsız, anlık toplamdır.
              </p>
            </Card>
          </>
        )}
      </div>
    </div>
  )
}
