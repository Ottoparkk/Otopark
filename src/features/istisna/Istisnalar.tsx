import { useEffect, useState } from 'react'
import { useEkranDurumu } from '../../lib/useEkranDurumu'
import { useNavigate } from 'react-router'
import {
  Button,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { FiltreChip } from '../../components/ui/FiltreChip'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { KimSatirlari } from '../../components/ui/KimSatirlari'
import { PlakaInput } from '../../components/ui/PlakaInput'
import { PlakaKontrol } from '../../components/ui/PlakaKontrol'
import {
  useIstisnaBiletAc,
  useIstisnaBiletAcSaatli,
  useIstisnaCoz,
  useIstisnalar,
  type IstisnaBiletSonuc,
} from './api'
import { useKayitSil } from '../cop/api'
import { useFotoUrl } from '../gise/api'
import { useAdlar } from '../yonetim/api'
import { cikisLinki } from '../gise/cikisLink'
import { kartGirisSaati } from '../gise/degistir'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'
import { adCoz } from '../../lib/kimYapti'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../lib/plaka'
import { formatGoreceli, formatTam } from '../../lib/dates'
import { formatSure, dakikaFarki } from '../../lib/sure'
import { rpcErrorText } from '../../lib/errors'
import { IconCop, IconTik } from '../../components/ui/icons'
import { KAMERA_YON_ETIKET, type Istisna } from '../../lib/types'
import {
  aciklama,
  baslangicPlakasi,
  eylemler,
  kimSatirlari,
  kisaDurum,
  sekme as sekmesi,
  tahminNotu,
  type Sekme,
} from './kart'

const SEKMELER: { deger: Sekme; etiket: string }[] = [
  { deger: 'BEKLEYEN', etiket: 'Bekleyen' },
  { deger: 'COZULMUS', etiket: 'Çözülmüş' },
  { deger: 'KAPATILAN', etiket: 'Kapatılan' },
]

const BOS: Record<Sekme, { title: string; hint: string }> = {
  BEKLEYEN: {
    title: 'Bekleyen kayıt yok',
    hint: 'Kamera bir aracı bilete dönüştüremezse burada görünür.',
  },
  COZULMUS: {
    title: 'Çözülmüş kayıt yok',
    hint: 'Giriş açılarak ya da kameranın kendisiyle çözülen kayıtlar burada görünür.',
  },
  KAPATILAN: {
    title: 'Kapatılan kayıt yok',
    hint: '"Kapat" ile kapatılan kayıtlar burada görünür.',
  },
}

export default function Istisnalar() {
  const navigate = useNavigate()
  // Unlike the rest of /yonetim, this screen is open to Personel — but only
  // its waiting list (owner 2026-11-23). RLS (075) gives Personel no resolved
  // rows at all; the tabs are simply not drawn for them. Deleting is the
  // Yönetici's too: the RPC refuses Personel either way.
  const yonetici = isYonetici(useAuth().profile)
  // Remembered (owner, 27.11).
  const [secilen, setSecilen] = useEkranDurumu<Sekme>('istisna.sekme', 'BEKLEYEN', ['BEKLEYEN', 'COZULMUS', 'KAPATILAN'])
  const sekme: Sekme = yonetici ? secilen : 'BEKLEYEN'
  const { data: liste = [], isPending, error, refetch } = useIstisnalar(sekme)
  const adlar = useAdlar()
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
        {yonetici && (
          // Three separate buttons, like Gişe's İçeride / Çıkanlar (owner,
          // 27.11: not the glued bar). Wraps rather than scrolls at 360 px.
          <div className="flex flex-wrap gap-2">
            {SEKMELER.map((s) => (
              <FiltreChip
                key={s.deger}
                aktif={secilen === s.deger}
                onClick={() => setSecilen(s.deger)}
                etiket={s.etiket}
              />
            ))}
          </div>
        )}

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
          bos={<EmptyState icon={<IconTik size={44} />} title={BOS[sekme].title} hint={BOS[sekme].hint} />}
        >
          <div className="space-y-3">
            {liste.map((i) => (
              <IstisnaKart
                key={i.id}
                istisna={i}
                kimAdi={yonetici ? adCoz(i.cozuldu_by, adlar) : null}
                yonetici={yonetici}
                onAcildi={setBasari}
                onKapat={() => {
                  setKapatHata(null)
                  setKapatilacak(i)
                }}
                onCikis={(plaka) => {
                  // Gişe opens with this plate in its search (cikisLink.ts).
                  const l = cikisLinki(plaka)
                  navigate(l.to, { state: l.state })
                }}
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
        description="İşlendi olarak kapanır; kayıt silinmez, Yönetici Kapatılan'da görür."
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
          "Kayıt tamamen kalkar (Çöp Kutusu'ndan geri alınabilir). Yalnızca işlendi demek için Kapat'a basın — kayıt saklanır."
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
  kimAdi,
  yonetici,
  onAcildi,
  onKapat,
  onCikis,
  onSil,
}: {
  istisna: Istisna
  /** The resolver's name (Yönetici only; adCoz). */
  kimAdi: string | null
  yonetici: boolean
  onAcildi: (s: IstisnaBiletSonuc) => void
  onKapat: () => void
  onCikis: (plaka: string) => void
  onSil?: () => void
}) {
  const navigate = useNavigate()
  const { data: fotoUrl } = useFotoUrl(i.foto_path)
  const ac = useIstisnaBiletAc()
  const acSaatli = useIstisnaBiletAcSaatli()
  const mesgul = ac.isPending || acSaatli.isPending
  const sekme = sekmesi(i)
  const bekliyor = sekme === 'BEKLEYEN'
  const e = eylemler(i)
  const tahmin = tahminNotu(i)

  const [plaka, setPlaka] = useState(() => normalizePlaka(baslangicPlakasi(i)))
  const [hata, setHata] = useState<string | null>(null)
  const [onay, setOnay] = useState(false)
  // 072: tek kapı "no open ticket at exit" — the entry time starts EMPTY and
  // must be typed (owner 2026-11-18), with a reason.
  const [saatYerel, setSaatYerel] = useState('')
  const [sebep, setSebep] = useState('')
  const [saatHata, setSaatHata] = useState<{ alan: 'giris' | 'sebep'; metin: string } | null>(null)
  const [saatOnay, setSaatOnay] = useState<{ iso: string; sebep: string } | null>(null)

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

  function saatliSor() {
    if (!plakaGecerli(plaka) || mesgul) return
    setHata(null)
    const s = kartGirisSaati(saatYerel, sebep, new Date())
    if (s.hata !== null) {
      setSaatHata({ alan: s.alan, metin: s.hata })
      return
    }
    setSaatOnay({ iso: s.girisISO, sebep: s.sebep })
  }

  function saatliAc() {
    if (!saatOnay) return
    void acSaatli
      .mutateAsync({ id: i.id, plaka, girisISO: saatOnay.iso, sebep: saatOnay.sebep })
      .then((s) => {
        setSaatOnay(null)
        onAcildi(s)
      })
      .catch((err) => {
        setSaatOnay(null)
        setHata(rpcErrorText(err, 'Giriş açılamadı.'))
      })
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
      durum={kisaDurum(i)}
      ton={bekliyor ? 'warn' : sekme === 'COZULMUS' ? 'success' : 'neutral'}
      ust={
        // Wraps rather than truncates: a long delay ("· 14 sa 50 dk
        // gecikmeli") is the billing signal and must not be cut off.
        <p className="text-label leading-snug text-faint">
          {KAMERA_YON_ETIKET[i.yon]} · {formatGoreceli(i.kaynak_zaman ?? i.alindi_zaman)}
          {gecikmeDk >= 2 ? ` · ${formatSure(gecikmeDk)} gecikmeli` : ''}
        </p>
      }
    >
      {/* Owner 2026-11-23: short, the context first, always visible. */}
      {bekliyor && (
        <p className="text-label text-soft">
          {tahmin ? `${tahmin} ` : ''}
          {aciklama(i)}
        </p>
      )}

      {!bekliyor && yonetici && <KimSatirlari satirlar={kimSatirlari(i, kimAdi)} />}

      {e.girisAc || e.girisAcSaatli ? (
        <PlakaInput
          value={plaka}
          onChange={(v) => {
            setPlaka(v)
            setHata(null)
          }}
          hideLabel
          placeholder="Plakayı yazın"
          error={hata}
          onEnter={e.girisAc ? girisSor : saatliSor}
        />
      ) : bekliyor || i.plaka ? (
        <p className="text-center text-title font-semibold tracking-[0.08em] text-ink tnum">
          {i.plaka ? formatPlaka(i.plaka) : '—'}
        </p>
      ) : null}

      {e.girisAcSaatli && (
        <section className="space-y-3">
          {/* Araç Girişi's field, as is (Giris.tsx): no min/max, dark picker. */}
          <Input
            label="Giriş tarihi ve saati"
            type="datetime-local"
            className="tnum dark:[color-scheme:dark]"
            value={saatYerel}
            onChange={(ev) => {
              setSaatYerel(ev.target.value)
              setSaatHata(null)
            }}
            error={saatHata?.alan === 'giris' ? saatHata.metin : null}
          />
          <Input
            label="Sebep"
            value={sebep}
            onChange={(ev) => {
              setSebep(ev.target.value)
              setSaatHata(null)
            }}
            maxLength={200}
            placeholder="Araç girmiş, kamera çıkış sandı"
            error={saatHata?.alan === 'sebep' ? saatHata.metin : null}
          />
        </section>
      )}

      {(e.girisAc || e.girisAcSaatli || e.cikis || e.bileteGit) && (
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
          {e.girisAcSaatli && (
            <Button
              className="flex-1"
              loading={acSaatli.isPending}
              disabled={!plakaGecerli(plaka)}
              onClick={saatliSor}
            >
              Giriş aç
            </Button>
          )}
          {e.bileteGit && (
            <Button className="flex-1" onClick={() => navigate(`/gise/bilet/${e.bileteGit}`)}>
              Bilete git
            </Button>
          )}
          {e.cikis && (
            <Button variant="secondary" className="flex-1" disabled={mesgul} onClick={() => onCikis(plaka)}>
              Çıkış
            </Button>
          )}
        </div>
      )}

      {/* Owner 2026-11-23: "Kapat" as a text button on the left, the bin on
          the right. Two different things, each behind its own confirmation:
          Kapat CLOSES (kept, Yönetici sees it under Kapatılan); the bin
          DELETES (Yönetici, to Çöp Kutusu). */}
      {(e.kapat || onSil) && (
        <div className="flex items-center justify-between gap-2">
          {e.kapat ? (
            <Button variant="secondary" disabled={mesgul} onClick={onKapat}>
              Kapat
            </Button>
          ) : (
            <span />
          )}
          {onSil && (
            <button
              type="button"
              onClick={onSil}
              aria-label="Kaydı sil"
              className="-mr-2 flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field"
            >
              <IconCop size={18} />
            </button>
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

      <ConfirmDialog
        open={saatOnay !== null}
        onOpenChange={(o) => {
          if (!o) setSaatOnay(null)
        }}
        title="Giriş açılsın mı?"
        description={
          saatOnay
            ? `${formatPlaka(plaka)} için giriş bileti açılacak. Giriş saati: ${formatTam(saatOnay.iso)}.`
            : ''
        }
        confirmLabel="Giriş aç"
        loading={acSaatli.isPending}
        onConfirm={saatliAc}
      />
    </PlakaKontrol>
  )
}
