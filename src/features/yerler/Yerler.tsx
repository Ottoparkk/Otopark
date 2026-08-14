import { useMemo, useState } from 'react'
import {
  Button,
  Card,
  Chip,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
  SegmentedControl,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { Toggle } from '../../components/ui/Toggle'
import { PlakaInput } from '../../components/ui/PlakaInput'
import {
  useDoluYerler,
  useRezervasyonEkle,
  useRezervasyonSil,
  useRezervasyonlar,
  useTumParkYerleri,
  useYerEkle,
  useYerGuncelle,
} from './api'
import { araliktaMi, araligiGunler } from '../../lib/aralik'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../lib/plaka'
import { formatTarih, gunEkle, istanbulGun } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconArti, IconCop, IconYer } from '../../components/ui/icons'
import { PARK_YERI_TIP_ETIKET, type ParkYeri, type ParkYeriTip } from '../../lib/types'

const TIPLER: { value: ParkYeriTip; label: string }[] = [
  { value: 'NORMAL', label: 'Normal' },
  { value: 'ENGELLI', label: 'Engelli' },
  { value: 'SARJ', label: 'Şarj' },
]

export default function Yerler() {
  const { data: yerler = [], isPending, error, refetch } = useTumParkYerleri()
  const { data: dolu = {} } = useDoluYerler()
  const {
    data: rezervasyonlar = [],
    isPending: rezPending,
    error: rezError,
    refetch: rezRefetch,
  } = useRezervasyonlar()

  const ekle = useYerEkle()
  const guncelle = useYerGuncelle()
  const rezEkle = useRezervasyonEkle()
  const rezSil = useRezervasyonSil()

  const [pasifGoster, setPasifGoster] = useState(false)

  /* ---- spot form ---- */
  const [yerAcik, setYerAcik] = useState(false)
  const [duzenlenen, setDuzenlenen] = useState<ParkYeri | null>(null)
  const [kod, setKod] = useState('')
  const [tip, setTip] = useState<ParkYeriTip>('NORMAL')
  const [rezerve, setRezerve] = useState(false)
  const [aktif, setAktif] = useState(true)
  const [hata, setHata] = useState<string | null>(null)

  /* ---- reservation form ---- */
  const [rezAcik, setRezAcik] = useState(false)
  const [rezYer, setRezYer] = useState('')
  const [rezPlaka, setRezPlaka] = useState('')
  const [rezBas, setRezBas] = useState(istanbulGun())
  const [rezBit, setRezBit] = useState(gunEkle(29))
  const [rezNot, setRezNot] = useState('')
  const [rezHata, setRezHata] = useState<string | null>(null)
  const [silinecek, setSilinecek] = useState<string | null>(null)

  const gorunen = useMemo(
    () => yerler.filter((y) => pasifGoster || y.is_active),
    [yerler, pasifGoster],
  )
  const aktifYerler = useMemo(() => yerler.filter((y) => y.is_active), [yerler])

  function yeniYer() {
    setDuzenlenen(null)
    setKod('')
    setTip('NORMAL')
    setRezerve(false)
    setAktif(true)
    setHata(null)
    setYerAcik(true)
  }

  function yerDuzenle(y: ParkYeri) {
    setDuzenlenen(y)
    setKod(y.kod)
    setTip(y.tip)
    setRezerve(y.rezerve)
    setAktif(y.is_active)
    setHata(null)
    setYerAcik(true)
  }

  function yeniRezervasyon() {
    setRezYer(aktifYerler.find((y) => y.rezerve)?.id ?? aktifYerler[0]?.id ?? '')
    setRezPlaka('')
    setRezBas(istanbulGun())
    setRezBit(gunEkle(29))
    setRezNot('')
    setRezHata(null)
    setRezAcik(true)
  }

  return (
    <div>
      <ScreenHeader
        title="Park yerleri"
        back="/yonetim"
        right={
          <button
            type="button"
            onClick={yeniYer}
            aria-label="Yer ekle"
            className="flex size-11 items-center justify-center rounded-chip bg-accent text-accent-ink"
          >
            <IconArti size={20} />
          </button>
        }
      />

      <div className="space-y-6 px-5">
        {/* ------------------------------------------------------- spots --- */}
        <section>
          <div className="mb-2 flex items-baseline justify-between gap-3">
            <h2 className="text-label font-medium tracking-wide text-faint uppercase">
              Yerler
            </h2>
            <button
              type="button"
              onClick={() => setPasifGoster((v) => !v)}
              className="min-h-[36px] text-label font-medium text-accent"
            >
              {pasifGoster ? 'Pasifleri gizle' : 'Pasifleri göster'}
            </button>
          </div>

          <ListeDurumu
            pending={isPending}
            error={error}
            onRetry={() => void refetch()}
            empty={gorunen.length === 0}
            bos={
              <EmptyState
                icon={<IconYer size={44} />}
                title="Henüz yer tanımlanmadı"
                hint="Numaralandırılmış yerler girişte araca atanabilir ve rezerve edilebilir."
                action={<Button onClick={yeniYer}>Yer ekle</Button>}
              />
            }
          >
            <div className="grid grid-cols-2 gap-2 sm:grid-cols-3">
              {gorunen.map((y) => {
                const plaka = dolu[y.id]
                return (
                  <button
                    key={y.id}
                    type="button"
                    onClick={() => yerDuzenle(y)}
                    className={[
                      'rounded-card p-3.5 text-left transition-[filter] active:brightness-[0.97]',
                      y.is_active ? 'bg-surface' : 'bg-field opacity-70',
                    ].join(' ')}
                  >
                    <div className="flex items-baseline justify-between gap-2">
                      <span className="truncate text-lead font-semibold text-ink tnum">
                        {y.kod}
                      </span>
                      {!y.is_active && <span className="text-micro text-faint">pasif</span>}
                    </div>
                    <p className="mt-1 truncate text-label text-faint">
                      {plaka ? formatPlaka(plaka) : 'boş'}
                    </p>
                    <div className="mt-2 flex flex-wrap gap-1">
                      {y.tip !== 'NORMAL' && (
                        <span className="rounded-chip bg-field px-2 py-0.5 text-micro font-medium text-soft">
                          {PARK_YERI_TIP_ETIKET[y.tip]}
                        </span>
                      )}
                      {y.rezerve && (
                        <span className="rounded-chip bg-accent-soft px-2 py-0.5 text-micro font-medium text-accent">
                          Rezerve
                        </span>
                      )}
                    </div>
                  </button>
                )
              })}
            </div>
          </ListeDurumu>
        </section>

        {/* ------------------------------------------------ reservations --- */}
        <section>
          <div className="mb-2 flex items-baseline justify-between gap-3">
            <h2 className="text-label font-medium tracking-wide text-faint uppercase">
              Rezervasyonlar
            </h2>
            <button
              type="button"
              onClick={yeniRezervasyon}
              disabled={aktifYerler.length === 0}
              className="min-h-[36px] text-label font-medium text-accent disabled:opacity-45"
            >
              Rezervasyon ekle
            </button>
          </div>

          <ListeDurumu
            pending={rezPending}
            error={rezError}
            onRetry={() => void rezRefetch()}
            empty={rezervasyonlar.length === 0}
            bos={
              <Card>
                <p className="text-body text-faint">
                  Ayrılmış yer yok. Bir yeri belirli bir plakaya ve döneme bağlayabilirsiniz.
                </p>
              </Card>
            }
          >
            <div className="space-y-2">
              {rezervasyonlar.map((r) => {
                const { bas, bit } = araligiGunler(r.gecerlilik)
                const suan = araliktaMi(r.gecerlilik)
                return (
                  <Card key={r.id} className="flex items-center gap-3">
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-2">
                        <span className="truncate text-body font-semibold text-ink tnum">
                          {r.park_yeri?.kod ?? 'Silinmiş yer'}
                        </span>
                        <span className="truncate text-body text-soft tnum">
                          {r.plaka ? formatPlaka(r.plaka) : 'Abonman'}
                        </span>
                        {suan && <Chip tone="success">Şu an</Chip>}
                      </div>
                      <p className="mt-0.5 text-label text-faint tnum">
                        {bas ? formatTarih(bas) : '—'} — {bit ? formatTarih(bit) : 'süresiz'}
                        {r.notlar ? ` · ${r.notlar}` : ''}
                      </p>
                    </div>
                    <button
                      type="button"
                      onClick={() => setSilinecek(r.id)}
                      aria-label="Rezervasyonu sil"
                      className="flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field"
                    >
                      <IconCop size={18} />
                    </button>
                  </Card>
                )
              })}
            </div>
          </ListeDurumu>
        </section>
      </div>

      {/* ----------------------------------------------------- spot form --- */}
      <FormModal
        open={yerAcik}
        onOpenChange={setYerAcik}
        title={duzenlenen ? 'Yeri düzenle' : 'Yeni yer'}
        submitLabel={duzenlenen ? 'Kaydet' : 'Ekle'}
        loading={ekle.isPending || guncelle.isPending}
        error={hata}
        onSubmit={() => {
          const k = kod.trim().toUpperCase()
          if (!k) {
            setHata('Yer kodu zorunludur.')
            return
          }
          const istek = duzenlenen
            ? guncelle.mutateAsync({
                id: duzenlenen.id,
                kod: k,
                tip,
                rezerve,
                is_active: aktif,
              })
            : ekle.mutateAsync({ kod: k, tip, rezerve })

          void istek
            .then(() => setYerAcik(false))
            .catch((e) =>
              setHata(rpcErrorText(e, 'Kaydedilemedi. Bu kod başka bir yerde kullanılıyor olabilir.')),
            )
        }}
      >
        <Input
          label="Yer kodu"
          value={kod}
          onChange={(e) => setKod(e.target.value.toUpperCase())}
          placeholder="A-12"
          maxLength={12}
          autoCapitalize="characters"
          className="tnum"
        />
        <SegmentedControl value={tip} onChange={setTip} options={TIPLER} label="Yer tipi" />
        <Toggle
          checked={rezerve}
          onChange={setRezerve}
          label="Rezerve yer"
          hint="Abonmana ya da belirli bir plakaya ayrılabilir."
        />
        {duzenlenen && (
          <Toggle
            checked={aktif}
            onChange={setAktif}
            label="Kullanımda"
            hint="Kapatılan yer girişte seçilemez; geçmiş kayıtlar korunur."
          />
        )}
      </FormModal>

      {/* ---------------------------------------------- reservation form --- */}
      <FormModal
        open={rezAcik}
        onOpenChange={setRezAcik}
        title="Rezervasyon"
        submitLabel="Ekle"
        loading={rezEkle.isPending}
        error={rezHata}
        onSubmit={() => {
          const p = normalizePlaka(rezPlaka)
          if (!rezYer) {
            setRezHata('Bir yer seçin.')
            return
          }
          if (!plakaGecerli(p)) {
            setRezHata('Geçerli bir plaka girin.')
            return
          }
          if (rezBit < rezBas) {
            setRezHata('Bitiş tarihi başlangıçtan önce olamaz.')
            return
          }
          void rezEkle
            .mutateAsync({
              park_yeri_id: rezYer,
              plaka: p,
              bas_gun: rezBas,
              bit_gun: rezBit,
              notlar: rezNot.trim() || null,
            })
            .then(() => setRezAcik(false))
            .catch((e) =>
              setRezHata(
                rpcErrorText(e, 'Eklenemedi. Bu yer seçilen tarihlerde zaten ayrılmış olabilir.'),
              ),
            )
        }}
      >
        <div>
          <label
            htmlFor="rez-yer"
            className="mb-1.5 block text-label font-medium tracking-wide text-faint uppercase"
          >
            Yer
          </label>
          <select
            id="rez-yer"
            value={rezYer}
            onChange={(e) => setRezYer(e.target.value)}
            className="min-h-[52px] w-full rounded-field bg-field px-4 text-body text-ink outline-none"
          >
            {aktifYerler.map((y) => (
              <option key={y.id} value={y.id}>
                {y.kod}
                {y.rezerve ? ' · rezerve' : ''}
              </option>
            ))}
          </select>
        </div>
        <PlakaInput value={rezPlaka} onChange={setRezPlaka} />
        <div className="grid grid-cols-2 gap-3">
          <Input
            label="Başlangıç"
            type="date"
            value={rezBas}
            onChange={(e) => setRezBas(e.target.value)}
          />
          <Input
            label="Bitiş"
            type="date"
            value={rezBit}
            onChange={(e) => setRezBit(e.target.value)}
          />
        </div>
        <Input
          label="Not (isteğe bağlı)"
          value={rezNot}
          onChange={(e) => setRezNot(e.target.value)}
          maxLength={120}
        />
      </FormModal>

      <ConfirmDialog
        open={silinecek !== null}
        onOpenChange={() => setSilinecek(null)}
        tone="danger"
        title="Rezervasyonu sil"
        description="Yer yeniden serbest kalacak."
        confirmLabel="Sil"
        loading={rezSil.isPending}
        onConfirm={() => {
          if (!silinecek) return
          void rezSil.mutateAsync(silinecek).then(() => setSilinecek(null))
        }}
      />
    </div>
  )
}
