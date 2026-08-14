import { useState } from 'react'
import { useParams } from 'react-router'
import {
  Card,
  Chip,
  DataPoint,
  Input,
  ListeDurumu,
  LoadError,
  ScreenHeader,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { Spinner } from '../../components/ui/Spinner'
import { Toggle } from '../../components/ui/Toggle'
import { PlakaInput } from '../../components/ui/PlakaInput'
import {
  useAracEkle,
  useAracSil,
  useHesap,
  useHesapAraclari,
  useHesapBakiye,
  useHesapGuncelle,
  usePuanHareketleri,
} from './api'
import { usePuanKurali } from '../yonetim/api'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../lib/plaka'
import { formatTL } from '../../lib/money'
import { formatTam } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconCop, IconPuan } from '../../components/ui/icons'
import type { PuanHareketTur } from '../../lib/types'

const HAREKET_ETIKET: Record<PuanHareketTur, string> = {
  KAZANIM: 'Giriş kazanımı',
  KULLANIM: 'Kullanım',
  IPTAL: 'İptal düzeltmesi',
  DUZELTME: 'Düzeltme',
}

export default function HesapDetay() {
  const { id } = useParams<{ id: string }>()
  const { data: h, isPending, error, refetch } = useHesap(id)
  const { data: bakiye = 0 } = useHesapBakiye(id)
  const {
    data: araclar = [],
    isPending: aracPending,
    error: aracError,
    refetch: aracRefetch,
  } = useHesapAraclari(id)
  const {
    data: hareketler = [],
    isPending: hareketPending,
    error: hareketError,
    refetch: hareketRefetch,
  } = usePuanHareketleri(id)
  const { data: kural } = usePuanKurali()

  const guncelle = useHesapGuncelle()
  const aracEkle = useAracEkle()
  const aracSil = useAracSil()

  const [duzenle, setDuzenle] = useState(false)
  const [ad, setAd] = useState('')
  const [tel, setTel] = useState('')
  const [notlar, setNotlar] = useState('')
  const [aktif, setAktif] = useState(true)
  const [hata, setHata] = useState<string | null>(null)

  const [aracAcik, setAracAcik] = useState(false)
  const [plaka, setPlaka] = useState('')
  const [aracHata, setAracHata] = useState<string | null>(null)
  const [silinecek, setSilinecek] = useState<string | null>(null)

  if (error) {
    return (
      <div>
        <ScreenHeader title="Hesap" back="/yonetim/hesaplar" />
        <div className="px-5">
          <LoadError error={error} onRetry={() => void refetch()} />
        </div>
      </div>
    )
  }

  if (isPending || !h) {
    return (
      <div>
        <ScreenHeader title="Hesap" back="/yonetim/hesaplar" />
        <div className="py-14">
          <Spinner label="Yükleniyor" />
        </div>
      </div>
    )
  }

  const kurusPerPuan = kural?.kurus_per_puan ?? 0

  function duzenleAc() {
    if (!h) return
    setAd(h.ad)
    setTel(h.telefon ?? '')
    setNotlar(h.notlar ?? '')
    setAktif(h.durum === 'AKTIF')
    setHata(null)
    setDuzenle(true)
  }

  return (
    <div>
      <ScreenHeader
        title={h.ad}
        subtitle={h.telefon ? `0${h.telefon}` : undefined}
        back="/yonetim/hesaplar"
        right={
          <button
            type="button"
            onClick={duzenleAc}
            className="min-h-[44px] px-2 text-body font-medium text-accent"
          >
            Düzenle
          </button>
        }
      />

      <div className="space-y-4 px-5">
        <Card>
          <div className="flex items-start justify-between gap-4">
            <DataPoint
              value={`${bakiye} puan`}
              caption={kurusPerPuan > 0 ? `${formatTL(bakiye * kurusPerPuan)} karşılığı` : undefined}
              size="lg"
            />
            {h.durum === 'PASIF' && <Chip tone="neutral">Pasif</Chip>}
          </div>
          {h.notlar && <p className="mt-3 border-t border-divider pt-3 text-body text-soft">{h.notlar}</p>}
        </Card>

        {/* ---------------------------------------------------- vehicles --- */}
        <section>
          <div className="mb-2 flex items-baseline justify-between gap-3">
            <h2 className="text-label font-medium tracking-wide text-faint uppercase">Araçlar</h2>
            <button
              type="button"
              onClick={() => {
                setPlaka('')
                setAracHata(null)
                setAracAcik(true)
              }}
              className="min-h-[36px] text-label font-medium text-accent"
            >
              Araç ekle
            </button>
          </div>

          <ListeDurumu
            pending={aracPending}
            error={aracError}
            onRetry={() => void aracRefetch()}
            empty={araclar.length === 0}
            bos={
              <Card>
                <p className="text-body text-faint">
                  Bu hesapta araç yok — puan kazanmak için en az bir plaka gerekir.
                </p>
              </Card>
            }
          >
            <div className="space-y-2">
              {araclar.map((a) => (
                <Card key={a.id} className="flex items-center gap-3">
                  <span className="min-w-0 flex-1 truncate text-lead font-semibold tracking-wide text-ink tnum">
                    {formatPlaka(a.plaka)}
                  </span>
                  <button
                    type="button"
                    onClick={() => setSilinecek(a.id)}
                    aria-label="Aracı kaldır"
                    className="flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field"
                  >
                    <IconCop size={18} />
                  </button>
                </Card>
              ))}
            </div>
          </ListeDurumu>
        </section>

        {/* ------------------------------------------------------ ledger --- */}
        <section>
          <h2 className="mb-2 text-label font-medium tracking-wide text-faint uppercase">
            Puan hareketleri
          </h2>

          <ListeDurumu
            pending={hareketPending}
            error={hareketError}
            onRetry={() => void hareketRefetch()}
            empty={hareketler.length === 0}
            bos={
              <Card>
                <div className="flex items-center gap-3">
                  <IconPuan size={20} className="shrink-0 text-faint" />
                  <p className="text-body text-faint">Henüz hareket yok.</p>
                </div>
              </Card>
            }
          >
            <div className="space-y-2">
              {hareketler.map((m) => (
                <Card key={m.id} className="flex items-center gap-3">
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-body text-ink">
                      {m.aciklama || HAREKET_ETIKET[m.tur]}
                    </p>
                    <p className="mt-0.5 truncate text-label text-faint">
                      {formatTam(m.created_at)}
                      {m.bilet?.plaka ? ` · ${formatPlaka(m.bilet.plaka)}` : ''}
                    </p>
                  </div>
                  <span
                    className={`shrink-0 text-body font-semibold tnum ${
                      m.puan > 0 ? 'text-success' : 'text-danger'
                    }`}
                  >
                    {m.puan > 0 ? '+' : '−'}
                    {Math.abs(m.puan)}
                  </span>
                </Card>
              ))}
            </div>
          </ListeDurumu>

          {/* The ledger is append-only on purpose — there is no edit here. */}
          <p className="mt-2 text-label text-faint">
            Hareketler silinemez; düzeltmeler ters kayıtla yapılır.
          </p>
        </section>
      </div>

      {/* ---------------------------------------------------------- edit --- */}
      <FormModal
        open={duzenle}
        onOpenChange={setDuzenle}
        title="Hesabı düzenle"
        loading={guncelle.isPending}
        error={hata}
        onSubmit={() => {
          if (!ad.trim()) {
            setHata('Hesap adı zorunludur.')
            return
          }
          const t = tel.replace(/\D/g, '')
          if (t && !/^[1-9][0-9]{9}$/.test(t)) {
            setHata('Telefonu 10 hane olarak girin (örn. 5321234567).')
            return
          }
          void guncelle
            .mutateAsync({
              id: h.id,
              ad: ad.trim(),
              telefon: t || null,
              notlar: notlar.trim() || null,
              durum: aktif ? 'AKTIF' : 'PASIF',
            })
            .then(() => setDuzenle(false))
            .catch((e) => setHata(rpcErrorText(e, 'Kaydedilemedi.')))
        }}
      >
        <Input label="Ad" value={ad} onChange={(e) => setAd(e.target.value)} maxLength={80} />
        <Input
          label="Telefon"
          value={tel}
          onChange={(e) => setTel(e.target.value)}
          inputMode="tel"
          placeholder="5321234567"
          maxLength={10}
        />
        <Input label="Not" value={notlar} onChange={(e) => setNotlar(e.target.value)} maxLength={200} />
        <Toggle
          checked={aktif}
          onChange={setAktif}
          label="Hesap aktif"
          hint="Pasif hesap puan kazanmaz ve puanı kullanılamaz. Bakiye ve geçmiş korunur."
        />
      </FormModal>

      {/* --------------------------------------------------- add vehicle --- */}
      <FormModal
        open={aracAcik}
        onOpenChange={setAracAcik}
        title="Araç ekle"
        submitLabel="Ekle"
        loading={aracEkle.isPending}
        error={aracHata}
        onSubmit={() => {
          const p = normalizePlaka(plaka)
          if (!plakaGecerli(p)) {
            setAracHata('Geçerli bir plaka girin.')
            return
          }
          void aracEkle
            .mutateAsync({ hesap_id: h.id, plaka: p })
            .then(() => setAracAcik(false))
            .catch((e) =>
              setAracHata(
                rpcErrorText(e, 'Eklenemedi. Bu plaka başka bir hesaba kayıtlı olabilir.'),
              ),
            )
        }}
      >
        <PlakaInput value={plaka} onChange={setPlaka} autoFocus />
        <p className="text-label text-faint">
          Bir plaka yalnızca tek bir hesaba bağlanabilir.
        </p>
      </FormModal>

      <ConfirmDialog
        open={silinecek !== null}
        onOpenChange={() => setSilinecek(null)}
        tone="danger"
        title="Aracı kaldır"
        description="Bu plaka artık puan kazanmaz. Kazanılmış puanlar hesapta kalır."
        confirmLabel="Kaldır"
        loading={aracSil.isPending}
        onConfirm={() => {
          if (!silinecek) return
          void aracSil.mutateAsync(silinecek).then(() => setSilinecek(null))
        }}
      />
    </div>
  )
}
