import { useMemo } from 'react'
import { BrandPanel, Card, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { DonemSecici, IstatKutu, useDonem } from '../yonetim/components'
import {
  GrafikKart,
  HalkaGrafik,
  OranSerit,
  SaatGrafigi,
  SiraliCubuklar,
  Sparkline,
  SutunGrafik,
  ciroCubuklari,
} from './charts'
import { useDonemAralik, useRaporDetay, useRaporGunluk, useRaporOzet } from './api'
import { formatTL } from '../../lib/money'
import { formatSure } from '../../lib/sure'

const kisaTL = (kurus: number) => formatTL(kurus, { decimals: 0 })

export default function Raporlar() {
  // Stays on 7 gün, unlike Finans and Kasa: these are comparison charts —
  // arrivals by hour, stay length — and they say more about a recent window
  // than about an all-time average. "Tümü" is available, just not the default.
  const { donem, ozel, secim } = useDonem('HAFTA')
  const { bas, bit, hazir, ilkGunHatasi } = useDonemAralik(donem, ozel)

  const ozet = useRaporOzet(bas, bit, hazir)
  const gunluk = useRaporGunluk(bas, bit, hazir)
  const detay = useRaporDetay(bas, bit, hazir)

  // Collapses to monthly totals past ~2 months of days, and says so in the
  // card title — "Tümü" on an old car park would otherwise draw a year of
  // sub-pixel bars. See ciroCubuklari.
  const grafik = useMemo(
    () => ciroCubuklari((gunluk.data ?? []).map((g) => ({ gun: g.gun, kurus: g.ciro_kurus }))),
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
      <ScreenHeader title="Raporlar" back="/finans" />

      <div className="space-y-4 px-5">
        {ilkGunHatasi ?? ozet.error ? (
          <LoadError
            error={ilkGunHatasi ?? ozet.error}
            onRetry={() => void ozet.refetch()}
          />
        ) : !hazir || ozet.isPending ? (
          <div className="py-14">
            <Spinner label="Rapor hazırlanıyor" />
          </div>
        ) : (
          /* ---- headline: the money, with its own trend ----------------- */
          <BrandPanel>
            <p className="text-label font-medium tracking-wide text-on-brand-soft uppercase">
              Ciro
            </p>
            <p className="mt-1.5 text-hero font-semibold tnum">{kisaTL(ciro)}</p>
            <p className="mt-0.5 text-label text-on-brand-soft">
              {ozet.data?.bilet_sayisi ?? 0} tamamlanan çıkış
            </p>

            {grafik.veri.length > 1 && (
              <div className="mt-4 text-on-brand">
                <Sparkline veri={grafik.veri.map((g) => g.kurus)} />
              </div>
            )}
          </BrandPanel>
        )}

        {/* Under the headline figure, same as Finans and Kasa: the number is
            the answer, the period is the follow-up question. Outside the
            loading branch on purpose — the period must stay switchable while
            figures load and after one fails. */}
        <DonemSecici value={donem} ozel={ozel} onChange={secim} />

        {!(ilkGunHatasi ?? ozet.error) && hazir && !ozet.isPending && (
          <>
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
            {grafik.veri.length > 1 && (
              <GrafikKart baslik={grafik.aylik ? 'Aylık ciro' : 'Günlük ciro'}>
                {gunluk.isPending ? (
                  <div className="py-8">
                    <Spinner />
                  </div>
                ) : (
                  <SutunGrafik veri={grafik.veri} format={kisaTL} />
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
