import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router'
import {
  Button,
  Chip,
  EmptyState,
  ListeDurumu,
  ScreenHeader,
  SegmentedControl,
} from '../../components/ui/primitives'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { PlakaInput } from '../../components/ui/PlakaInput'
import { PlakaKontrol } from '../../components/ui/PlakaKontrol'
import { useIstisnaBiletAc, useIstisnaCoz, useIstisnalar, type IstisnaBiletSonuc } from './api'
import { useKayitSil } from '../cop/api'
import { useFotoUrl } from '../gise/api'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../lib/plaka'
import { formatGoreceli } from '../../lib/dates'
import { formatSure, dakikaFarki } from '../../lib/sure'
import { rpcErrorText } from '../../lib/errors'
import { IconCarpi, IconCop, IconTik } from '../../components/ui/icons'
import { KAMERA_YON_ETIKET, type Istisna } from '../../lib/types'
import {
  aciklama,
  baslangicPlakasi,
  eylemler,
  elleGirmeUyarisi,
  kisaDurum,
} from './kart'

export default function Istisnalar() {
  const navigate = useNavigate()
  // Unlike the rest of /yonetim, this screen is open to Personel — deleting is
  // not. The RPC refuses them either way; this stops them tapping a control
  // that could only fail.
  const yonetici = isYonetici(useAuth().profile)
  const [sadeceAcik, setSadeceAcik] = useState(true)
  const { data: liste = [], isPending, error, refetch } = useIstisnalar(sadeceAcik)
  const coz = useIstisnaCoz()
  const sil = useKayitSil()

  const [kapatilacak, setKapatilacak] = useState<Istisna | null>(null)
  const [kapatHata, setKapatHata] = useState<string | null>(null)
  const [silinecek, setSilinecek] = useState<Istisna | null>(null)
  const [silHata, setSilHata] = useState<string | null>(null)
  const [basari, setBasari] = useState<IstisnaBiletSonuc | null>(null)

  // The card that was acted on leaves the list, so the outcome is said once at
  // the top and then gets out of the way.
  useEffect(() => {
    if (!basari) return
    const t = window.setTimeout(() => setBasari(null), 6000)
    return () => window.clearTimeout(t)
  }, [basari])

  return (
    <div>
      <ScreenHeader title="Çözülmemiş kayıtlar" back subtitle="Bilete dönüşemeyen kamera olayları" />

      <div className="space-y-4 px-5">
        <SegmentedControl
          value={sadeceAcik ? 'ACIK' : 'TUMU'}
          onChange={(v) => setSadeceAcik(v === 'ACIK')}
          options={[
            { value: 'ACIK', label: 'Bekleyen' },
            { value: 'TUMU', label: 'Tümü' },
          ]}
        />

        {basari && (
          <button
            type="button"
            onClick={() => navigate(`/gise/bilet/${basari.bilet_id}`)}
            className="flex min-h-[44px] w-full items-center justify-between gap-3 rounded-field bg-success-soft px-3 py-2 text-left text-label font-medium text-success"
          >
            <span className="min-w-0">
              {basari.zaten_vardi
                ? `Kamera bu aracın biletini zaten açmış: ${formatPlaka(basari.plaka)}`
                : `${formatPlaka(basari.plaka)} girişi açıldı${basari.yer_kod ? ` · ${basari.yer_kod}` : ''}`}
            </span>
            <span className="shrink-0 underline">Bilete git</span>
          </button>
        )}

        <ListeDurumu
          pending={isPending}
          error={error}
          onRetry={() => void refetch()}
          empty={liste.length === 0}
          bos={
            <EmptyState
              icon={<IconTik size={44} />}
              title={sadeceAcik ? 'Bekleyen kayıt yok' : 'Kayıt yok'}
              hint="Kamera bir aracı bilete dönüştüremezse burada görünür."
            />
          }
        >
          <div className="space-y-3">
            {liste.map((i) => (
              <IstisnaKart
                key={i.id}
                istisna={i}
                onAcildi={setBasari}
                onKapat={() => {
                  setKapatHata(null)
                  setKapatilacak(i)
                }}
                onCikis={() => navigate('/gise/cikis')}
                onSil={
                  yonetici
                    ? () => {
                        setSilHata(null)
                        setSilinecek(i)
                      }
                    : undefined
                }
              />
            ))}
          </div>
        </ListeDurumu>
      </div>

      {/* Kept as a confirmation (one extra tap): closing hides the car from
          the waiting list, and a mis-tap there is a car nobody handles. */}
      <ConfirmDialog
        open={kapatilacak !== null}
        onOpenChange={() => setKapatilacak(null)}
        title="Kaydı kapat"
        description="İşlendi olarak kapanır; kayıt silinmez, Tümü'nde kalır."
        confirmLabel="Kapat"
        loading={coz.isPending}
        error={kapatHata}
        onConfirm={() => {
          if (!kapatilacak) return
          setKapatHata(null)
          void coz
            .mutateAsync({ id: kapatilacak.id, not: null })
            .then(() => setKapatilacak(null))
            .catch((e) => setKapatHata(rpcErrorText(e, 'Kapatılamadı.')))
        }}
      />

      <ConfirmDialog
        open={silinecek !== null}
        onOpenChange={() => setSilinecek(null)}
        tone="danger"
        title="Kaydı sil"
        description={
          "Kayıt tamamen kalkar (Çöp Kutusu'ndan geri alınabilir). Yalnızca işlendi demek için ✕ ile kapatın — kayıt saklanır."
        }
        confirmLabel="Sil"
        loading={sil.isPending}
        error={silHata}
        onConfirm={() => {
          if (!silinecek) return
          void sil
            .mutateAsync({ tablo: 'istisnalar', id: silinecek.id })
            .then(() => setSilinecek(null))
            .catch((e) => setSilHata(rpcErrorText(e, 'Silinemedi.')))
        }}
      />
    </div>
  )
}

function IstisnaKart({
  istisna: i,
  onAcildi,
  onKapat,
  onCikis,
  onSil,
}: {
  istisna: Istisna
  onAcildi: (s: IstisnaBiletSonuc) => void
  onKapat: () => void
  onCikis: () => void
  onSil?: () => void
}) {
  const { data: fotoUrl } = useFotoUrl(i.foto_path)
  const ac = useIstisnaBiletAc()
  const cozuldu = i.cozuldu_at !== null
  const e = eylemler(i)

  const [plaka, setPlaka] = useState(() => normalizePlaka(baslangicPlakasi(i)))
  const [hata, setHata] = useState<string | null>(null)
  const [ayrinti, setAyrinti] = useState(false)
  const [onay, setOnay] = useState(false)

  // Both timestamps are kept precisely so this lag is visible. A camera that
  // buffered through an outage shows up here as hours, and a camera whose
  // clock has drifted shows up as a constant offset — the difference between
  // those two is the difference between a network problem and mis-billing.
  const gecikmeDk = i.kaynak_zaman ? dakikaFarki(i.kaynak_zaman, i.alindi_zaman) : 0

  // The button (or Enter) only ASKS; the ticket opens from the dialog (owner,
  // 2026-10-31: a confirmation before a ticket is created).
  function girisSor() {
    if (!plakaGecerli(plaka) || ac.isPending) return
    setHata(null)
    setOnay(true)
  }

  function girisAc() {
    // mutateAsync, not mutate(…, callbacks): the card leaves the list as soon
    // as the refetch lands, and per-call callbacks of an unmounted component
    // are dropped — the success line must still be shown.
    void ac
      .mutateAsync({ id: i.id, plaka })
      .then((s) => {
        setOnay(false)
        onAcildi(s)
      })
      .catch((err) => {
        // Closed, and the reason goes under the plate: the likeliest refusal
        // ("plate already inside") is fixed in the field, not in the dialog.
        setOnay(false)
        setHata(rpcErrorText(err, 'Giriş açılamadı.'))
      })
  }

  return (
    <PlakaKontrol
      fotoUrl={fotoUrl}
      durum={cozuldu ? (i.cozum_notu ?? 'Kapatıldı') : kisaDurum(i)}
      ton={cozuldu ? 'success' : 'warn'}
      className={cozuldu ? 'opacity-80' : ''}
      ust={
        <div className="flex min-h-[28px] items-center gap-2">
          {/* Wraps rather than truncates: with the icons beside it a long delay
              ("· 14 sa 50 dk gecikmeli" — the billing signal) was cut off. */}
          <p className="min-w-0 flex-1 text-label leading-snug text-faint">
            {KAMERA_YON_ETIKET[i.yon]} · {formatGoreceli(i.kaynak_zaman ?? i.alindi_zaman)}
            {gecikmeDk >= 2 ? ` · ${formatSure(gecikmeDk)} gecikmeli` : ''}
          </p>
          {cozuldu && <Chip tone="success" size="sm">Kapatıldı</Chip>}
          <button
            type="button"
            onClick={() => setAyrinti((a) => !a)}
            aria-expanded={ayrinti}
            className="-my-2 flex min-h-[44px] shrink-0 items-center px-1 text-label font-medium text-accent"
          >
            {ayrinti ? 'Gizle' : 'Ayrıntı'}
          </button>
          {/* Two different things, each behind its own confirmation: the bin
              DELETES the record (Yönetici, to Çöp Kutusu), the ✕ CLOSES it —
              handled, kept, still under "Tümü". The ✕ sits at the far edge,
              where a card's close mark is expected (owner, 2026-10-31). */}
          {onSil && (
            <button
              type="button"
              onClick={onSil}
              aria-label="Kaydı sil"
              className={`-my-2 flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field ${e.kapat ? '' : '-mr-2'}`}
            >
              <IconCop size={18} />
            </button>
          )}
          {e.kapat && (
            <button
              type="button"
              onClick={onKapat}
              disabled={ac.isPending}
              aria-label="Kaydı kapat"
              className="-my-2 -mr-2 flex size-11 shrink-0 items-center justify-center rounded-chip text-ink active:bg-field disabled:opacity-40"
            >
              <IconCarpi size={22} />
            </button>
          )}
        </div>
      }
    >
      {ayrinti && <p className="text-label text-soft">{aciklama(i)}</p>}

      {e.girisAc ? (
        <PlakaInput
          value={plaka}
          onChange={(v) => {
            setPlaka(v)
            setHata(null)
          }}
          hideLabel
          placeholder="Plakayı yazın"
          error={hata}
          onEnter={girisSor}
        />
      ) : (
        <p className="text-center text-title font-semibold tracking-[0.08em] text-ink tnum">
          {i.plaka ? formatPlaka(i.plaka) : '—'}
        </p>
      )}

      {elleGirmeUyarisi(i) && (
        <p className="rounded-field bg-warn-soft px-3 py-2 text-label font-medium text-warn">
          Kameradan geldi — elle girmeyin, kendiliğinden düzelebilir.
        </p>
      )}

      {(e.girisAc || e.cikis) && (
        <div className="flex items-center gap-2">
          {e.girisAc && (
            <Button
              className="flex-1"
              loading={ac.isPending}
              disabled={!plakaGecerli(plaka)}
              onClick={girisSor}
            >
              Giriş aç
            </Button>
          )}
          {e.cikis && (
            <Button variant="secondary" className="flex-1" disabled={ac.isPending} onClick={onCikis}>
              Çıkış
            </Button>
          )}
        </div>
      )}

      <ConfirmDialog
        open={onay}
        onOpenChange={setOnay}
        title="Giriş açılsın mı?"
        description={`${formatPlaka(plaka)} için giriş bileti açılacak.`}
        confirmLabel="Giriş aç"
        loading={ac.isPending}
        onConfirm={girisAc}
      />
    </PlakaKontrol>
  )
}
