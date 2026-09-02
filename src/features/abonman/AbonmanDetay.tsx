import { useState } from 'react'
import { useNavigate, useParams } from 'react-router'
import {
  Button,
  Card,
  Chip,
  DataPoint,
  Input,
  ListeDurumu,
  LoadError,
  ScreenHeader,
  Select,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { Spinner } from '../../components/ui/Spinner'
import { YontemSecici } from '../../components/ui/YontemSecici'
import {
  useAbonman,
  useAbonmanGuncelle,
  useAbonmanTahsil,
  useAbonmanTahsilatlari,
} from './api'
import { useAbonmanSil } from '../cop/api'
import { useParkYerleri } from '../gise/api'
import { formatPlaka } from '../../lib/plaka'
import { formatTL, kurusToInput, parseTLToKurus } from '../../lib/money'
import { normalizeTel } from '../../lib/telefon'
import { formatTam, formatTarih, gunEkle, gunFarki, istanbulGun } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconCop } from '../../components/ui/icons'
import { ODEME_CHIP, ODEME_ETIKET, ONAY_ETIKET, type OdemeYontemi } from '../../lib/types'

export default function AbonmanDetay() {
  const { id } = useParams<{ id: string }>()
  const navigate = useNavigate()
  const { data: a, isPending, error, refetch } = useAbonman(id)
  const {
    data: tahsilatlar = [],
    isPending: tahsilatPending,
    error: tahsilatError,
    refetch: tahsilatRefetch,
  } = useAbonmanTahsilatlari(id)
  const { data: yerler = [] } = useParkYerleri()
  const guncelle = useAbonmanGuncelle()
  const tahsil = useAbonmanTahsil()
  const sil = useAbonmanSil()

  /* ---- collect ---- */
  const [tahsilAcik, setTahsilAcik] = useState(false)
  const [yontem, setYontem] = useState<OdemeYontemi | null>('NAKIT')
  const [tutar, setTutar] = useState('')
  /**
   * Renewal rides along with the collection, because that is how it actually
   * happens: the customer pays for the next month and the period moves. Two
   * separate screens would let one be done without the other.
   */
  const [yenile, setYenile] = useState(true)
  /**
   * The collection succeeded but the renewal did not, so the modal is still
   * open showing why. Without this flag a second tap on "Tahsil et" would
   * charge the customer AGAIN — the dialog stays open precisely so the
   * operator can fix the period, not so they can re-run the payment.
   */
  const [tahsilEdildi, setTahsilEdildi] = useState(false)

  /* ---- edit ---- */
  const [duzenle, setDuzenle] = useState(false)
  const [silAcik, setSilAcik] = useState(false)
  const [silHata, setSilHata] = useState<string | null>(null)
  const [ad, setAd] = useState('')
  const [tel, setTel] = useState('')
  const [bas, setBas] = useState('')
  const [bit, setBit] = useState('')
  const [ucret, setUcret] = useState('')
  const [yer, setYer] = useState('')
  const [notlar, setNotlar] = useState('')

  const [iptalAcik, setIptalAcik] = useState(false)
  const [hata, setHata] = useState<string | null>(null)

  if (error) {
    return (
      <div>
        <ScreenHeader title="Abonman" back="/yonetim/abonman" />
        <div className="px-5">
          <LoadError error={error} onRetry={() => void refetch()} />
        </div>
      </div>
    )
  }

  if (isPending || !a) {
    return (
      <div>
        <ScreenHeader title="Abonman" back="/yonetim/abonman" />
        <div className="py-14">
          <Spinner label="Yükleniyor" />
        </div>
      </div>
    )
  }

  const kalan = gunFarki(a.bitis)
  const yerKod = yerler.find((y) => y.id === a.park_yeri_id)?.kod ?? null

  /**
   * A renewal always buys 30 more days, but WHERE it starts depends on whether
   * the subscription is still running:
   *
   * - still valid  → the end moves out by 30 days and the original start is
   *   kept, so "customer since" survives the renewal.
   * - already lapsed → a fresh period starting today. Extending the old end
   *   would sell 30 days that are already in the past, and a subscription that
   *   ran out in May would still be expired after being paid for.
   */
  const suresiVar = kalan >= 0
  const yeniBas = suresiVar ? a.baslangic : istanbulGun()
  const yeniBit = suresiVar ? gunEkle(30, a.bitis) : gunEkle(29, istanbulGun())

  function tahsilAc() {
    if (!a) return
    setYontem('NAKIT')
    setTutar(kurusToInput(a.ucret_kurus))
    setYenile(true)
    setTahsilEdildi(false)
    setHata(null)
    setTahsilAcik(true)
  }

  function duzenleAc() {
    if (!a) return
    setAd(a.musteri_ad)
    setTel(a.musteri_tel ?? '')
    setBas(a.baslangic)
    setBit(a.bitis)
    setUcret(kurusToInput(a.ucret_kurus))
    setYer(a.park_yeri_id ?? '')
    setNotlar(a.notlar ?? '')
    setHata(null)
    setDuzenle(true)
  }

  return (
    <div>
      <ScreenHeader
        title={formatPlaka(a.plaka)}
        subtitle={a.musteri_ad || 'İsimsiz müşteri'}
        back="/yonetim/abonman"
        right={
          <div className="flex items-center gap-1">
            {/* Deleting and cancelling are different answers: İptal (below)
                keeps the record and reverses the money with a counter-entry,
                this removes both — recoverable from Çöp Kutusu. */}
            <button
              type="button"
              onClick={() => {
                setSilHata(null)
                setSilAcik(true)
              }}
              aria-label="Abonmanı sil"
              className="flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field"
            >
              <IconCop size={20} />
            </button>
            <button
              type="button"
              onClick={duzenleAc}
              className="min-h-[44px] px-2 text-body font-medium text-accent"
            >
              Düzenle
            </button>
          </div>
        }
      />

      <div className="space-y-4 px-5">
        <Card>
          <div className="flex items-start justify-between gap-4">
            <DataPoint
              value={formatTL(a.ucret_kurus)}
              caption="aylık ücret"
              size="lg"
            />
            {a.durum === 'IPTAL' ? (
              <Chip tone="neutral">İptal</Chip>
            ) : a.durum === 'DOLDU' ? (
              <Chip tone="neutral">Süresi doldu</Chip>
            ) : kalan <= 7 ? (
              <Chip tone="warn">
                {kalan < 0 ? 'Süresi doldu' : kalan === 0 ? 'Bugün bitiyor' : `${kalan} gün kaldı`}
              </Chip>
            ) : (
              <Chip tone="success">Aktif</Chip>
            )}
          </div>

          <dl className="mt-4 space-y-1.5 border-t border-divider pt-3">
            <Satir k="Dönem" v={`${formatTarih(a.baslangic)} — ${formatTarih(a.bitis)}`} />
            {a.musteri_tel && (
              <div className="flex items-baseline justify-between gap-3">
                <dt className="text-body text-faint">Telefon</dt>
                <dd>
                  <a
                    href={`tel:+90${a.musteri_tel}`}
                    className="text-body font-medium text-accent tnum"
                  >
                    0{a.musteri_tel}
                  </a>
                </dd>
              </div>
            )}
            {yerKod && <Satir k="Ayrılmış yer" v={yerKod} />}
            {a.notlar && <Satir k="Not" v={a.notlar} />}
          </dl>
        </Card>

        {a.durum !== 'IPTAL' && (
          <Button size="lg" block onClick={tahsilAc}>
            Tahsilat al
          </Button>
        )}

        <section>
          <h2 className="mb-2 text-label font-medium tracking-wide text-faint uppercase">
            Tahsilatlar
          </h2>
          <ListeDurumu
            pending={tahsilatPending}
            error={tahsilatError}
            onRetry={() => void tahsilatRefetch()}
            empty={tahsilatlar.length === 0}
            bos={
              <Card>
                <p className="text-body text-faint">Bu abonman için henüz tahsilat yok.</p>
              </Card>
            }
          >
            <div className="space-y-2">
              {tahsilatlar.map((t) => (
                <Card key={t.id} className="flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <p className="text-body font-medium text-ink tnum">
                      {formatTL(t.tutar_kurus)}
                    </p>
                    <p className="mt-0.5 text-label text-faint">{formatTam(t.created_at)}</p>
                    {/* Only when it is not the ordinary case. A collection
                        still waiting for the Yönetici has been taken but is
                        not in the revenue figures yet, and this is the only
                        screen that would otherwise imply it is. */}
                    {/* The truthiness check is not redundant: this row is
                        read with select('*'), so on a deployment that ran
                        ahead of migration 017 the column simply is not
                        there and an undefined would print as an empty
                        status line. */}
                    {t.durum && t.durum !== 'ONAYLANDI' && (
                      <p
                        className={
                          'mt-0.5 text-label ' +
                          (t.durum === 'REDDEDILDI' ? 'text-danger' : 'text-warn')
                        }
                      >
                        {ONAY_ETIKET[t.durum]}
                        {t.onay_notu ? ' · ' + t.onay_notu : ''}
                      </p>
                    )}
                  </div>
                  <span
                    className={`shrink-0 rounded-chip px-2.5 py-1 text-label font-medium ${ODEME_CHIP[t.yontem]}`}
                  >
                    {ODEME_ETIKET[t.yontem]}
                  </span>
                </Card>
              ))}
            </div>
          </ListeDurumu>
        </section>

        {a.durum !== 'IPTAL' && (
          <Button variant="danger" block onClick={() => setIptalAcik(true)}>
            Abonmanı iptal et
          </Button>
        )}

      </div>

      <ConfirmDialog
        open={silAcik}
        onOpenChange={setSilAcik}
        tone="danger"
        title="Abonmanı sil"
        description="Abonman ve alınan tahsilatlar silinecek; ilgili vardiyanın kasa farkı yeniden hesaplanır. Çöp Kutusu'ndan geri alınabilir."
        confirmLabel="Sil"
        loading={sil.isPending}
        error={silHata}
        onConfirm={() => {
          void sil
            .mutateAsync(a.id)
            .then(() => {
              setSilAcik(false)
              navigate('/yonetim/abonman')
            })
            .catch((e) => setSilHata(rpcErrorText(e, 'Abonman silinemedi.')))
        }}
      />

      {/* ------------------------------------------------------- collect --- */}
      <FormModal
        open={tahsilAcik}
        onOpenChange={setTahsilAcik}
        title="Abonman tahsilatı"
        submitLabel={tahsilEdildi ? 'Dönemi uzat' : 'Tahsil et'}
        loading={tahsil.isPending || guncelle.isPending}
        error={hata}
        onSubmit={() => {
          const kurus = parseTLToKurus(tutar)
          if (kurus === null || kurus <= 0) {
            setHata('Geçerli bir tutar girin.')
            return
          }
          if (!yontem) {
            setHata('Ödeme yöntemi seçin.')
            return
          }
          setHata(null)
          // The money moves first, and the two steps report SEPARATELY. If
          // the renewal fails (an overlapping period for this plate) the
          // collection still stands, and the operator must be told exactly
          // that — a single shared error message would leave them guessing
          // whether the customer was charged.
          void (async () => {
            if (!tahsilEdildi) {
              try {
                await tahsil.mutateAsync({ abonman_id: a.id, yontem, tutar_kurus: kurus })
                setTahsilEdildi(true)
              } catch (e) {
                setHata(rpcErrorText(e, 'Tahsilat kaydedilemedi.'))
                return
              }
            }
            if (yenile) {
              try {
                await guncelle.mutateAsync({
                  id: a.id,
                  baslangic: yeniBas,
                  bitis: yeniBit,
                  durum: 'AKTIF',
                })
              } catch (e) {
                setHata(
                  `Tahsilat kaydedildi, ancak dönem uzatılamadı: ${rpcErrorText(
                    e,
                    'aynı plakada çakışan bir abonman olabilir.',
                  )}`,
                )
                return
              }
            }
            setTahsilAcik(false)
          })()
        }}
      >
        {tahsilEdildi && (
          <p className="rounded-field bg-success-soft px-3 py-2.5 text-body text-success">
            Tahsilat kaydedildi. Geriye yalnızca dönemi uzatmak kaldı.
          </p>
        )}

        {/* Locked once the money has moved — editing them would suggest the
            charge could still be changed, and it cannot. */}
        <Input
          label="Tutar (₺)"
          value={tutar}
          onChange={(e) => setTutar(e.target.value)}
          inputMode="decimal"
          disabled={tahsilEdildi}
        />
        <YontemSecici value={yontem} onChange={setYontem} disabled={tahsilEdildi} />

        <button
          type="button"
          onClick={() => setYenile((v) => !v)}
          aria-pressed={yenile}
          className={[
            'w-full rounded-field px-4 py-3.5 text-left transition-colors',
            yenile ? 'bg-accent-soft' : 'bg-field',
          ].join(' ')}
        >
          <span className={`block text-body font-medium ${yenile ? 'text-accent' : 'text-soft'}`}>
            {suresiVar ? 'Dönemi 30 gün uzat' : 'Yeni 30 günlük dönem başlat'}
          </span>
          <span className="mt-0.5 block text-label text-faint tnum">
            {formatTarih(yeniBas)} — {formatTarih(yeniBit)} tarihine kadar
          </span>
        </button>
      </FormModal>

      {/* ---------------------------------------------------------- edit --- */}
      <FormModal
        open={duzenle}
        onOpenChange={setDuzenle}
        title="Abonmanı düzenle"
        loading={guncelle.isPending}
        error={hata}
        onSubmit={() => {
          const kurus = parseTLToKurus(ucret || '0')
          if (kurus === null) {
            setHata('Geçerli bir ücret girin.')
            return
          }
          if (bit < bas) {
            setHata('Bitiş tarihi başlangıçtan önce olamaz.')
            return
          }
          void guncelle
            .mutateAsync({
              id: a.id,
              musteri_ad: ad.trim(),
              // normalizeTel, not a bare digit strip: an operator types the
              // trunk zero and the server refuses eleven digits outright.
              musteri_tel: normalizeTel(tel) || null,
              baslangic: bas,
              bitis: bit,
              ucret_kurus: kurus,
              park_yeri_id: yer || null,
              notlar: notlar.trim() || null,
            })
            .then(() => setDuzenle(false))
            .catch((e) =>
              setHata(
                rpcErrorText(
                  e,
                  'Güncellenemedi. Aynı plakada çakışan bir dönem olabilir.',
                ),
              ),
            )
        }}
      >
        <Input label="Müşteri adı" value={ad} onChange={(e) => setAd(e.target.value)} maxLength={80} />
        <Input
          label="Telefon"
          value={tel}
          onChange={(e) => setTel(e.target.value)}
          inputMode="tel"
          placeholder="5XXXXXXXXX"
          maxLength={10}
        />
        <div className="grid grid-cols-2 gap-3">
          <Input label="Başlangıç" type="date" value={bas} onChange={(e) => setBas(e.target.value)} />
          <Input label="Bitiş" type="date" value={bit} onChange={(e) => setBit(e.target.value)} />
        </div>
        <Input
          label="Aylık ücret (₺)"
          value={ucret}
          onChange={(e) => setUcret(e.target.value)}
          inputMode="decimal"
        />
        <Select
          id="abonman-yer"
          label="Ayrılmış yer"
          value={yer}
          onChange={(e) => setYer(e.target.value)}
        >
          <option value="">Yer atanmadı</option>
          {yerler
            .filter((y) => y.rezerve || y.id === a.park_yeri_id)
            .map((y) => (
              <option key={y.id} value={y.id}>
                {y.kod}
              </option>
            ))}
        </Select>
        <Input
          label="Not"
          value={notlar}
          onChange={(e) => setNotlar(e.target.value)}
          maxLength={200}
        />
      </FormModal>

      {/* -------------------------------------------------------- cancel --- */}
      <ConfirmDialog
        open={iptalAcik}
        onOpenChange={setIptalAcik}
        tone="danger"
        title="Abonmanı iptal et"
        description={`${formatPlaka(a.plaka)} artık ücretsiz giriş yapamaz. Geçmiş tahsilatlar korunur.`}
        confirmLabel="İptal et"
        loading={guncelle.isPending}
        error={hata}
        onConfirm={() => {
          setHata(null)
          void guncelle
            .mutateAsync({ id: a.id, durum: 'IPTAL' })
            .then(() => setIptalAcik(false))
            .catch((e) => setHata(rpcErrorText(e, 'İptal edilemedi.')))
        }}
      />
    </div>
  )
}

function Satir({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="shrink-0 text-body text-faint">{k}</dt>
      <dd className="text-right text-body text-soft">{v}</dd>
    </div>
  )
}
