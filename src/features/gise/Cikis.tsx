import { useEffect, useMemo, useRef, useState } from 'react'
import {
  Button,
  Card,
  EmptyState,
  FloatingBar,
  Input,
  ListeDurumu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { YontemSecici } from '../../components/ui/YontemSecici'
import { FormModal } from '../../components/ui/FormModal'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { Spinner } from '../../components/ui/Spinner'
import { AracTipiSecici, BiletKart } from './components'
import {
  useAcikBiletler,
  useAyarlar,
  useBiletKapat,
  useKayipBilet,
  usePuanDurumu,
  usePuanGeriAl,
  usePuanKullan,
  useUcretOnizleme,
} from './api'
import { formatPlaka } from '../../lib/plaka'
import { formatTutar, formatTL, digitsOnly, parseTLToKurus, kurusToInput } from '../../lib/money'
import { sureMetni } from '../../lib/sure'
import { formatGoreceli } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconAra, IconAraba, IconTik } from '../../components/ui/icons'
import {
  ARAC_TIPI_ETIKET,
  type AcikBilet,
  type AracTipi,
  type OdemeYontemi,
} from '../../lib/types'

export default function Cikis() {
  const [sorgu, setSorgu] = useState('')
  const [secili, setSecili] = useState<AcikBilet | null>(null)

  const { data: biletler = [], isPending, error, refetch } = useAcikBiletler(sorgu)

  // Keep the selected ticket in step with refetches (points may have been
  // applied, the camera may have flagged it at the gate).
  useEffect(() => {
    if (!secili) return
    const guncel = biletler.find((b) => b.id === secili.id)
    if (guncel && guncel !== secili) setSecili(guncel)
  }, [biletler, secili])

  if (secili) {
    return <Tahsilat bilet={secili} onKapat={() => setSecili(null)} />
  }

  return (
    <div className="flex min-h-dvh flex-col md:min-h-0">
      <ScreenHeader title="Araç Çıkışı" subtitle="Plakayı arayın ya da listeden seçin" />

      <div className="px-5">
        <div className="relative">
          <IconAra
            size={20}
            className="pointer-events-none absolute top-1/2 left-4 -translate-y-1/2 text-faint"
          />
          <Input
            label="Plaka ara"
            hideLabel
            value={sorgu}
            onChange={(e) => setSorgu(e.target.value.toUpperCase())}
            placeholder="Plaka ara — son rakamlar da yeterli"
            inputMode="text"
            autoCapitalize="characters"
            autoCorrect="off"
            spellCheck={false}
            className="pl-11 tnum"
          />
        </div>
      </div>

      <div className="mt-4 flex-1 space-y-2 px-5">
        {/* "İçeride araç yok" must never stand in for "the list did not
            load" — an operator who believes the lot is empty stops charging. */}
        <ListeDurumu
          pending={isPending}
          error={error}
          onRetry={() => void refetch()}
          empty={biletler.length === 0}
          bos={
            <EmptyState
              icon={<IconAraba size={44} />}
              title={sorgu ? 'Eşleşen araç yok' : 'İçeride araç yok'}
              hint={
                sorgu
                  ? 'Plakanın tamamını değil, son rakamlarını da arayabilirsiniz. Kaydı hiç yoksa kayıp bilet ücreti alın.'
                  : 'Giriş yapılan araçlar burada listelenir.'
              }
            />
          }
        >
          {biletler.map((b) => (
            <BiletKart key={b.id} bilet={b} onClick={() => setSecili(b)} />
          ))}
        </ListeDurumu>
      </div>

      <KayipBiletBolumu />
    </div>
  )
}

/* ==================================================== the collect screen === */

function Tahsilat({ bilet, onKapat }: { bilet: AcikBilet; onKapat: () => void }) {
  const { data: ayarlar } = useAyarlar()
  const { data: onizleme, isPending: ucretYukleniyor } = useUcretOnizleme(bilet)
  const { data: puan } = usePuanDurumu(bilet.plaka, Boolean(ayarlar?.puan_aktif))

  const kapat = useBiletKapat()
  const puanKullan = usePuanKullan()
  const puanGeriAl = usePuanGeriAl()

  const [yontem, setYontem] = useState<OdemeYontemi | null>('NAKIT')
  const [hata, setHata] = useState<string | null>(null)
  const [puanModal, setPuanModal] = useState(false)
  const [puanGirdi, setPuanGirdi] = useState('')
  const [puanHata, setPuanHata] = useState<string | null>(null)
  const [degistirModal, setDegistirModal] = useState(false)
  const [yeniTutar, setYeniTutar] = useState('')
  const [sebep, setSebep] = useState('')
  const [degistirHata, setDegistirHata] = useState<string | null>(null)
  const [override, setOverride] = useState<{ kurus: number; sebep: string } | null>(null)
  const [sonuc, setSonuc] = useState<{ tahsil: number; ucret: number; indirim: number } | null>(
    null,
  )

  const abonman = Boolean(bilet.abonman_id)
  const brutKurus = override?.kurus ?? onizleme ?? 0
  const netKurus = Math.max(0, brutKurus - bilet.indirim_kurus)
  const odemeGerekli = netKurus > 0

  const kurusPerPuan = useMemo(() => {
    if (!puan || puan.bakiye <= 0) return 0
    return Math.round(puan.karsiligi_kurus / puan.bakiye)
  }, [puan])

  const maxPuan = useMemo(() => {
    if (!puan || kurusPerPuan <= 0) return 0
    return Math.min(puan.bakiye, Math.floor(netKurus / kurusPerPuan))
  }, [puan, kurusPerPuan, netKurus])

  async function tahsilEt() {
    setHata(null)
    if (odemeGerekli && !yontem) {
      setHata('Ödeme yöntemi seçin.')
      return
    }
    try {
      const r = await kapat.mutateAsync({
        bilet_id: bilet.id,
        odeme_yontemi: odemeGerekli ? yontem : null,
        ucret_override_kurus: override?.kurus ?? null,
        sebep: override?.sebep ?? null,
      })
      // The RECEIPT shows what the server actually charged, not the preview.
      setSonuc({ tahsil: r.tahsil_kurus, ucret: r.ucret_kurus, indirim: r.indirim_kurus })
    } catch (err) {
      setHata(
        rpcErrorText(
          err,
          'Tahsilat kaydedilemedi. Tekrar deneyin — tahsilat otomatik tekrarlanmaz.',
        ),
      )
    }
  }

  if (sonuc) {
    return <Fis plaka={bilet.plaka} sonuc={sonuc} onTamam={onKapat} />
  }

  return (
    <div className="flex min-h-dvh flex-col md:min-h-0">
      {/* onBack, not `back`: this is a sub-view of the same route, so
          navigate(-1) would leave Çıkış entirely instead of returning to the
          search list. */}
      <ScreenHeader title="Tahsilat" onBack={onKapat} />

      <div className="flex-1 space-y-5 px-5">
        {/* ---- the one thing at full contrast -------------------------- */}
        <Card className="text-center">
          <p className="text-lead font-medium tracking-wide text-soft tnum">
            {formatPlaka(bilet.plaka)}
          </p>

          <div className="mt-3 mb-1 no-select">
            {ucretYukleniyor && !override ? (
              <div className="py-3">
                <Spinner label="Ücret hesaplanıyor" görünürEtiket />
              </div>
            ) : (
              <p className="text-hero font-semibold text-ink tnum">
                {formatTutar(netKurus)}
                <span className="ml-1 text-title font-medium text-faint">₺</span>
              </p>
            )}
          </div>

          {/* Everything else steps down. No labels — a duration looks like a
              duration and an entry time looks like an entry time. */}
          <p className="text-label text-faint">
            {sureMetni(bilet.giris_at)} · {formatGoreceli(bilet.giris_at)} ·{' '}
            {ARAC_TIPI_ETIKET[bilet.arac_tipi]}
          </p>

          {abonman && (
            <p className="mt-3 rounded-field bg-success-soft px-3 py-2 text-body text-success">
              Abonman — ücretsiz çıkış
            </p>
          )}

          {bilet.indirim_kurus > 0 && (
            <p className="mt-3 flex items-center justify-center gap-2 text-label text-accent">
              {bilet.puan_kullanilan} puan kullanıldı · −{formatTL(bilet.indirim_kurus)}
              <button
                type="button"
                onClick={() => void puanGeriAl.mutateAsync(bilet.id)}
                className="min-h-[44px] font-medium underline"
              >
                geri al
              </button>
            </p>
          )}

          {override && (
            <p className="mt-3 rounded-field bg-warn-soft px-3 py-2 text-label text-warn">
              Ücret elle değiştirildi ({formatTL(onizleme ?? 0)} → {formatTL(override.kurus)}).
              Yönetici bilgilendirilecek.
            </p>
          )}
        </Card>

        {/* ---- points ------------------------------------------------- */}
        {!abonman && puan?.hesap_var && bilet.indirim_kurus === 0 && maxPuan > 0 && (
          <button
            type="button"
            onClick={() => {
              setPuanGirdi(String(maxPuan))
              setPuanHata(null)
              setPuanModal(true)
            }}
            className="flex w-full items-center justify-between rounded-card bg-accent-soft px-4 py-3.5 text-left"
          >
            <span className="text-body text-accent">
              <strong className="font-semibold">{puan.hesap_adi}</strong> · {puan.bakiye} puan
            </span>
            <span className="text-body font-medium text-accent">Kullan</span>
          </button>
        )}

        {/* ---- payment ------------------------------------------------ */}
        {odemeGerekli && <YontemSecici value={yontem} onChange={setYontem} />}

        {!abonman && (
          <button
            type="button"
            onClick={() => {
              setYeniTutar(kurusToInput(netKurus))
              setSebep('')
              setDegistirHata(null)
              setDegistirModal(true)
            }}
            className="min-h-[44px] w-full text-label text-faint underline"
          >
            Ücreti elle değiştir
          </button>
        )}

        {hata && (
          <p role="alert" className="rounded-card bg-danger-soft px-4 py-3 text-body text-danger">
            {hata}
          </p>
        )}
      </div>

      <FloatingBar>
        <Button size="lg" block loading={kapat.isPending} onClick={() => void tahsilEt()}>
          {odemeGerekli ? `${formatTL(netKurus)} Tahsil Et` : 'Çıkışı Kaydet'}
        </Button>
      </FloatingBar>

      {/* ---- points modal --------------------------------------------- */}
      <FormModal
        open={puanModal}
        onOpenChange={setPuanModal}
        title="Puan kullan"
        submitLabel="Uygula"
        loading={puanKullan.isPending}
        error={puanHata}
        onSubmit={() => {
          const adet = Number(puanGirdi)
          if (!adet || adet <= 0) {
            setPuanHata('Geçerli bir puan girin.')
            return
          }
          void puanKullan
            .mutateAsync({ bilet_id: bilet.id, puan: adet })
            .then(() => setPuanModal(false))
            .catch((e) => setPuanHata(rpcErrorText(e, 'Puan kullanılamadı.')))
        }}
      >
        <Input
          label="Kullanılacak puan"
          value={puanGirdi}
          onChange={(e) => setPuanGirdi(digitsOnly(e.target.value, 6))}
          inputMode="numeric"
          hint={`En fazla ${maxPuan} puan · 1 puan = ${formatTL(kurusPerPuan)}`}
        />
      </FormModal>

      {/* ---- manual fee override -------------------------------------- */}
      <FormModal
        open={degistirModal}
        onOpenChange={setDegistirModal}
        title="Ücreti değiştir"
        submitLabel="Uygula"
        error={degistirHata}
        onSubmit={() => {
          const kurus = parseTLToKurus(yeniTutar)
          if (kurus === null) {
            setDegistirHata('Geçerli bir tutar girin (örn. 250 ya da 250,50).')
            return
          }
          if (!sebep.trim()) {
            setDegistirHata('Sebep zorunludur — bu değişiklik Yöneticiye bildirilir.')
            return
          }
          if (kurus < bilet.indirim_kurus) {
            setDegistirHata('Yeni ücret kullanılan puandan düşük olamaz.')
            return
          }
          setOverride({ kurus, sebep: sebep.trim() })
          setDegistirModal(false)
        }}
      >
        <p className="text-body text-soft">
          Hesaplanan ücret <strong className="text-ink">{formatTL(onizleme ?? 0)}</strong>. Bunu
          değiştirmek denetim kaydına yazılır ve Yöneticiye bildirim gider.
        </p>
        <Input
          label="Yeni tutar (₺)"
          value={yeniTutar}
          onChange={(e) => setYeniTutar(e.target.value)}
          inputMode="decimal"
        />
        <Input
          label="Sebep"
          value={sebep}
          onChange={(e) => setSebep(e.target.value)}
          placeholder="Örn. cihaz arızası, müşteri itirazı"
          maxLength={200}
        />
      </FormModal>
    </div>
  )
}

/* ============================================================== receipt === */

function Fis({
  plaka,
  sonuc,
  onTamam,
}: {
  plaka: string
  sonuc: { tahsil: number; ucret: number; indirim: number }
  onTamam: () => void
}) {
  return (
    <div className="flex min-h-dvh flex-col items-center justify-center px-6 text-center">
      <div className="mb-5 flex size-16 items-center justify-center rounded-chip bg-success-soft text-success">
        <IconTik size={34} />
      </div>

      <p className="text-lead font-medium tracking-wide text-soft tnum">{formatPlaka(plaka)}</p>

      <p className="mt-2 text-hero font-semibold text-ink tnum">
        {formatTutar(sonuc.tahsil)}
        <span className="ml-1 text-title font-medium text-faint">₺</span>
      </p>
      <p className="mt-1 text-label text-faint">tahsil edildi</p>

      {sonuc.indirim > 0 && (
        <p className="mt-3 text-label text-faint">
          {formatTL(sonuc.ucret)} ücret · −{formatTL(sonuc.indirim)} puan indirimi
        </p>
      )}

      <div className="safe-bottom mt-10 w-full max-w-[360px]">
        <Button size="lg" block onClick={onTamam}>
          Tamam
        </Button>
      </div>
    </div>
  )
}

/* ========================================================== lost ticket === */

function KayipBiletBolumu() {
  const [acik, setAcik] = useState(false)
  const [plaka, setPlaka] = useState('')
  const [tip, setTip] = useState<AracTipi>('OTOMOBIL')
  const [yontem, setYontem] = useState<OdemeYontemi | null>('NAKIT')
  const [hata, setHata] = useState<string | null>(null)
  const islemIdRef = useRef<string>(crypto.randomUUID())
  const kayip = useKayipBilet()

  return (
    <>
      <div className="safe-bottom px-5 pt-6">
        <button
          type="button"
          onClick={() => {
            setPlaka('')
            setHata(null)
            islemIdRef.current = crypto.randomUUID()
            setAcik(true)
          }}
          className="min-h-[44px] w-full text-label text-faint underline"
        >
          Kaydı olmayan araç — kayıp bilet ücreti al
        </button>
      </div>

      <ConfirmDialog
        open={acik}
        onOpenChange={setAcik}
        title="Kayıp bilet"
        description="Girişi kaydedilmemiş bir araç için tarifedeki kayıp bilet ücreti tahsil edilir."
        confirmLabel="Tahsil Et"
        loading={kayip.isPending}
        error={hata}
        onConfirm={() => {
          setHata(null)
          if (!plaka.trim()) {
            setHata('Plaka girin.')
            return
          }
          if (!yontem) {
            setHata('Ödeme yöntemi seçin.')
            return
          }
          void kayip
            .mutateAsync({
              plaka,
              arac_tipi: tip,
              odeme_yontemi: yontem,
              islem_id: islemIdRef.current,
            })
            .then(() => setAcik(false))
            .catch((e) => setHata(rpcErrorText(e, 'Kayıp bilet tahsil edilemedi.')))
        }}
      >
        <div className="space-y-4">
          <Input
            label="Plaka"
            value={plaka}
            onChange={(e) => setPlaka(e.target.value.toUpperCase())}
            placeholder="34ABC123"
            autoCapitalize="characters"
            autoCorrect="off"
            spellCheck={false}
            className="text-center tracking-widest tnum"
          />
          <AracTipiSecici value={tip} onChange={setTip} />
          <YontemSecici value={yontem} onChange={setYontem} />
        </div>
      </ConfirmDialog>
    </>
  )
}
