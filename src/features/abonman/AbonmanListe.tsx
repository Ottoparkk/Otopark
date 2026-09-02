import { useState } from 'react'
import { useNavigate } from 'react-router'
import {
  Card,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
  Select,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { useAbonmanEkle, useAbonmanlar } from './api'
import { useParkYerleri } from '../gise/api'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../lib/plaka'
import { formatTL, parseTLToKurus } from '../../lib/money'
import { normalizeTel } from '../../lib/telefon'
import { formatTarih, gunEkle, gunFarki, istanbulGun } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconAbonman, IconArti } from '../../components/ui/icons'
import type { AbonmanDurum } from '../../lib/types'

const FILTRELER: { value: AbonmanDurum | 'TUMU'; label: string }[] = [
  { value: 'AKTIF', label: 'Aktif' },
  { value: 'DOLDU', label: 'Doldu' },
  { value: 'TUMU', label: 'Tümü' },
]

export default function AbonmanListe() {
  const navigate = useNavigate()
  const [filtre, setFiltre] = useState<AbonmanDurum | 'TUMU'>('AKTIF')
  const { data: liste = [], isPending, error, refetch } = useAbonmanlar(filtre)
  const { data: yerler = [] } = useParkYerleri()
  const ekle = useAbonmanEkle()

  const [acik, setAcik] = useState(false)
  const [plaka, setPlaka] = useState('')
  const [ad, setAd] = useState('')
  const [tel, setTel] = useState('')
  const [bas, setBas] = useState(istanbulGun())
  const [bit, setBit] = useState(gunEkle(29))
  const [ucret, setUcret] = useState('')
  const [yer, setYer] = useState('')
  const [hata, setHata] = useState<string | null>(null)

  return (
    <div>
      <ScreenHeader
        title="Abonmanlar"
        back="/yonetim"
        right={
          <button
            type="button"
            onClick={() => {
              setPlaka('')
              setAd('')
              setTel('')
              setBas(istanbulGun())
              setBit(gunEkle(29))
              setUcret('')
              setYer('')
              setHata(null)
              setAcik(true)
            }}
            aria-label="Abonman ekle"
            className="flex size-11 items-center justify-center rounded-chip bg-accent text-accent-ink"
          >
            <IconArti size={20} />
          </button>
        }
      />

      <div className="space-y-3 px-5">
        <div className="flex gap-2">
          {FILTRELER.map((f) => (
            <button
              key={f.value}
              type="button"
              onClick={() => setFiltre(f.value)}
              className={[
                'min-h-[40px] flex-1 rounded-chip px-3 text-body font-medium transition-colors',
                filtre === f.value ? 'bg-ink text-bg' : 'bg-field text-soft',
              ].join(' ')}
            >
              {f.label}
            </button>
          ))}
        </div>

        <div className="space-y-2">
          <ListeDurumu
            pending={isPending}
            error={error}
            onRetry={() => void refetch()}
            empty={liste.length === 0}
            bos={
              <EmptyState
                icon={<IconAbonman size={44} />}
                title="Abonman yok"
                hint="Aylık müşterileri buradan ekleyin; girişte otomatik tanınırlar."
              />
            }
          >
            {liste.map((a) => {
              const kalan = gunFarki(a.bitis)
              return (
                <Card key={a.id} as="div">
                  <button
                    type="button"
                    onClick={() => navigate(`/yonetim/abonman/${a.id}`)}
                    className="w-full text-left"
                  >
                    <div className="flex items-baseline justify-between gap-3">
                      <span className="text-lead font-semibold tracking-wide text-ink tnum">
                        {formatPlaka(a.plaka)}
                      </span>
                      <span className="shrink-0 text-body font-medium text-soft tnum">
                        {formatTL(a.ucret_kurus)}
                      </span>
                    </div>
                    <p className="mt-1 truncate text-label text-faint">
                      {a.musteri_ad || 'İsimsiz'} · {formatTarih(a.bitis)} tarihine kadar
                    </p>
                    {a.durum === 'AKTIF' && kalan <= 7 && (
                      <p className="mt-2 inline-block rounded-chip bg-warn-soft px-2.5 py-1 text-label font-medium text-warn">
                        {kalan < 0
                          ? 'Süresi doldu'
                          : kalan === 0
                            ? 'Bugün bitiyor'
                            : `${kalan} gün kaldı`}
                      </p>
                    )}
                    {a.durum === 'DOLDU' && (
                      <p className="mt-2 inline-block rounded-chip bg-field px-2.5 py-1 text-label font-medium text-soft">
                        Doldu
                      </p>
                    )}
                  </button>
                </Card>
              )
            })}
          </ListeDurumu>
        </div>
      </div>

      <FormModal
        open={acik}
        onOpenChange={setAcik}
        title="Yeni abonman"
        submitLabel="Ekle"
        loading={ekle.isPending}
        error={hata}
        onSubmit={() => {
          const p = normalizePlaka(plaka)
          if (!plakaGecerli(p)) {
            setHata('Geçerli bir plaka girin.')
            return
          }
          const kurus = parseTLToKurus(ucret || '0')
          if (kurus === null) {
            setHata('Geçerli bir ücret girin.')
            return
          }
          if (bit < bas) {
            setHata('Bitiş tarihi başlangıçtan önce olamaz.')
            return
          }
          void ekle
            .mutateAsync({
              plaka: p,
              musteri_ad: ad.trim(),
              // normalizeTel, not a bare digit strip: an operator types the
              // trunk zero and the server refuses eleven digits outright.
              musteri_tel: normalizeTel(tel) || null,
              baslangic: bas,
              bitis: bit,
              ucret_kurus: kurus,
              park_yeri_id: yer || null,
              notlar: null,
            })
            .then(() => setAcik(false))
            .catch((e) =>
              setHata(
                rpcErrorText(
                  e,
                  'Abonman eklenemedi. Aynı plakada çakışan bir dönem olabilir.',
                ),
              ),
            )
        }}
      >
        <Input
          label="Plaka"
          value={plaka}
          onChange={(e) => setPlaka(normalizePlaka(e.target.value))}
          placeholder="34ABC123"
          autoCapitalize="characters"
          className="tracking-widest tnum"
        />
        <Input label="Müşteri adı" value={ad} onChange={(e) => setAd(e.target.value)} maxLength={80} />
        <Input
          label="Telefon (isteğe bağlı)"
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
          label="Ayrılmış yer (isteğe bağlı)"
          value={yer}
          onChange={(e) => setYer(e.target.value)}
        >
          <option value="">Yer atanmadı</option>
          {yerler
            .filter((y) => y.rezerve)
            .map((y) => (
              <option key={y.id} value={y.id}>
                {y.kod}
              </option>
            ))}
        </Select>
      </FormModal>
    </div>
  )
}
