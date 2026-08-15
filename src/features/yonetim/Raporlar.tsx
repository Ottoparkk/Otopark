import { useMemo, useState } from 'react'
import { BrandPanel, Card, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { DonemSecici, IstatKutu, donemAralik, type Donem } from './components'
import {
  GrafikKart,
  HalkaGrafik,
  OranSerit,
  SaatGrafigi,
  SiraliCubuklar,
  Sparkline,
  SutunGrafik,
} from './charts'
import { useRaporDetay, useRaporGunluk, useRaporOzet } from './api'
import { formatTL } from '../../lib/money'
import { formatSure } from '../../lib/sure'
import { ARAC_TIPI_ETIKET } from '../../lib/types'

const kisaTL = (kurus: number) => formatTL(kurus, { decimals: 0 })

export default function Raporlar() {
  const [donem, setDonem] = useState<Donem>('HAFTA')
  const { bas, bit } = useMemo(() => donemAralik(donem), [donem])

  const ozet = useRaporOzet(bas, bit)
  const gunluk = useRaporGunluk(bas, bit)
  const detay = useRaporDetay(bas, bit)

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

  const ciro = ozet.data?.ciro_kurus ?? 0

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
            {/* ---- headline: the money, with its own trend ---------------- */}
            <BrandPanel>
              <p className="text-label font-medium tracking-wide text-on-brand-soft uppercase">
                Ciro
              </p>
              <p className="mt-1.5 text-hero font-semibold tnum">{kisaTL(ciro)}</p>
              <p className="mt-0.5 text-label text-on-brand-soft">
                {ozet.data?.bilet_sayisi ?? 0} tamamlanan çıkış
              </p>

              {grafik.length > 1 && (
                <div className="mt-4 text-on-brand">
                  <Sparkline veri={grafik.map((g) => g.kurus)} />
                </div>
              )}
            </BrandPanel>

            {/* ---- where the money came from ----------------------------- */}
            <GrafikKart baslik="Ödeme yöntemi">
              <HalkaGrafik
                merkez={kisaTL(yontemToplam.nakit + yontemToplam.kart + yontemToplam.havale)}
                merkezAlt="toplam"
                dilimler={[
                  {
                    etiket: 'Nakit',
                    deger: yontemToplam.nakit,
                    renk: 'text-nakit',
                    gosterim: kisaTL(yontemToplam.nakit),
                  },
                  {
                    etiket: 'Kredi Kartı',
                    deger: yontemToplam.kart,
                    renk: 'text-kart',
                    gosterim: kisaTL(yontemToplam.kart),
                  },
                  {
                    etiket: 'Havale',
                    deger: yontemToplam.havale,
                    renk: 'text-havale',
                    gosterim: kisaTL(yontemToplam.havale),
                  },
                ]}
              />
            </GrafikKart>

            {/* ---- daily shape ------------------------------------------- */}
            {grafik.length > 1 && (
              <GrafikKart baslik="Günlük ciro">
                {gunluk.isPending ? (
                  <div className="py-8">
                    <Spinner />
                  </div>
                ) : (
                  <SutunGrafik veri={grafik} format={kisaTL} />
                )}
              </GrafikKart>
            )}

            {/* ---- when the lot is busy ---------------------------------- */}
            <GrafikKart baslik="Saatlik yoğunluk" aciklama="Girişlerin saate göre dağılımı">
              {detay.error ? (
                <LoadError error={detay.error} onRetry={() => void detay.refetch()} />
              ) : detay.isPending ? (
                <div className="py-8">
                  <Spinner />
                </div>
              ) : (
                <SaatGrafigi saatler={detay.data.saatlik} />
              )}
            </GrafikKart>

            {/* ---- who is coming in -------------------------------------- */}
            <GrafikKart baslik="Araç tipi" aciklama="Bu dönemdeki girişler">
              {detay.error ? (
                <LoadError error={detay.error} onRetry={() => void detay.refetch()} />
              ) : detay.isPending ? (
                <div className="py-8">
                  <Spinner />
                </div>
              ) : (
                <SiraliCubuklar
                  bos="Bu dönemde giriş yok"
                  satirlar={detay.data.tipler.map((t) => ({
                    etiket: ARAC_TIPI_ETIKET[t.tip],
                    deger: t.sayi,
                    gosterim: `${t.sayi}`,
                  }))}
                />
              )}
            </GrafikKart>

            {/* ---- paying vs subscriber ---------------------------------- */}
            <GrafikKart baslik="Abonman / ücretli" aciklama="Bu dönemdeki girişler">
              <OranSerit
                parcalar={[
                  {
                    etiket: 'Ücretli',
                    deger: ozet.data?.saatlik_giris ?? 0,
                    renk: 'text-accent',
                  },
                  {
                    etiket: 'Abonman',
                    deger: ozet.data?.abonman_giris ?? 0,
                    renk: 'text-success',
                  },
                ]}
              />
            </GrafikKart>

            {/* ---- how long they stay ------------------------------------ */}
            <GrafikKart
              baslik="Kalış süresi"
              aciklama="Bu dönemde girip çıkmış araçlar"
              sag={
                detay.data ? (
                  <span className="text-label text-faint tnum">{detay.data.cikanSayisi} araç</span>
                ) : null
              }
            >
              {detay.error ? (
                <LoadError error={detay.error} onRetry={() => void detay.refetch()} />
              ) : detay.isPending ? (
                <div className="py-8">
                  <Spinner />
                </div>
              ) : (
                <SiraliCubuklar
                  bos="Bu dönemde çıkış yapan araç yok"
                  satirlar={detay.data.sureler.map((s) => ({
                    etiket: s.etiket,
                    deger: s.sayi,
                    gosterim: `${s.sayi}`,
                  }))}
                />
              )}
            </GrafikKart>

            {/* A partial dataset must say so — a chart that quietly drops the
                oldest half of a period is worse than no chart. */}
            {detay.data?.kesildi && (
              <p className="rounded-card bg-warn-soft px-4 py-3 text-label text-warn">
                Bu dönemde çok fazla kayıt var; grafikler en yeni kayıtlarla sınırlı. Daha kısa
                bir dönem seçin.
              </p>
            )}

            {/* ---- plain numbers ----------------------------------------- */}
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
                Puan borcu, müşterilere karşı birikmiş yükümlülüktür — dönemden bağımsız, anlık
                toplamdır.
              </p>
            </Card>
          </>
        )}
      </div>
    </div>
  )
}
