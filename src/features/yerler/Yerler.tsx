import { type ReactNode, useEffect, useMemo, useRef, useState } from 'react'
import {
  Button,
  Chip,
  EmptyState,
  Input,
  ListeDurumu,
  SegmentedControl,
  Select,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { Toggle } from '../../components/ui/Toggle'
import { PlakaInput } from '../../components/ui/PlakaInput'
import {
  useBiletYerDegistir,
  useDoluYerler,
  useRezervasyonEkle,
  useRezervasyonSil,
  useRezervasyonlar,
  useTumParkYerleri,
  useYerEkle,
  useYerGuncelle,
  type DoluYer,
} from './api'
import { useKayitSil } from '../cop/api'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'
import { araliktaMi, araligiGunler } from '../../lib/aralik'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../lib/plaka'
import { formatTarih, gunEkle, istanbulGun } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconAraba, IconArti, IconCop, IconYer } from '../../components/ui/icons'
import { yerleriBloklara } from '../../lib/yerkodu'
import {
  type BlokOrtak,
  blokOrtak,
  cevreyeBol,
} from './duzen'
import { PARK_YERI_TIP_ETIKET, type ParkYeri, type ParkYeriTip } from '../../lib/types'

/**
 * The inside of a bay — identical whether or not it is tappable.
 *
 * Four bands in a fixed order: the code painted at the head of the bay, the
 * car standing in it, what is parked there, and whatever is true of the bay
 * itself. The car glyph is what carries occupancy — across a hundred bays a
 * shape reads at a glance where a line of text has to be read one at a time.
 *
 * The plate band is rendered even when the bay is empty, holding "boş": a bay
 * that grew a line taller the moment a car arrived would reflow its whole row,
 * and the point of drawing the lot as a plan is that the shapes stay where the
 * operator last saw them. Only the chips below it come and go, and they are
 * rare by design — see `ortak`.
 */
function YerGovde({
  yer,
  plaka,
  ortak,
  tasiniyor = false,
}: {
  yer: ParkYeri
  plaka: string | undefined
  /** What the block heading already says, so this bay does not repeat it. */
  ortak: BlokOrtak
  /** This is the car currently being moved. */
  tasiniyor?: boolean
}) {
  // Only what makes this bay different from its block. In a lot numbered by
  // the generated scheme that is almost never anything — engelli and rezerve
  // bays get blocks of their own — which is what keeps a chip off a tile with
  // barely sixty pixels to spend.
  const tipChip = yer.tip !== 'NORMAL' && ortak.tip !== yer.tip
  const rezerveChip = yer.rezerve && !ortak.rezerve
  return (
    <>
      <div className="flex items-baseline justify-between gap-1">
        <span
          className={`truncate text-label font-semibold tnum ${plaka ? 'text-ink' : 'text-soft'}`}
        >
          {yer.kod}
        </span>
        {!yer.is_active && <span className="shrink-0 text-micro text-faint">pasif</span>}
      </div>

      {/* Empty asphalt when there is no car — the band still takes its height
          so the stall does not change shape when one arrives. */}
      <div className="flex flex-1 items-center justify-center py-1">
        {plaka && <IconAraba size={22} className={tasiniyor ? 'text-accent' : 'text-soft'} />}
      </div>

      {/* The plate WITHOUT formatPlaka's spaces — the one place in the app
          that is true, and it is measured: a bay has 54px inside its padding
          at the narrowest, where "35 BCD 567" renders 57.8px and truncates
          while "35BCD567" renders 51.7px and does not. A truncated plate is
          worse than an unspaced one, because it can match several cars. The
          spaced form is still what the accessible name and the move banner
          say, and `truncate` stays as the backstop for an odd plate. */}
      <p
        className={`truncate text-center text-micro tnum ${
          plaka ? 'font-medium text-ink' : 'text-faint'
        }`}
      >
        {plaka ?? 'boş'}
      </p>

      {(tipChip || rezerveChip) && (
        <div className="mt-1 flex flex-wrap justify-center gap-1">
          {/* bg-surface on both, because both bay floors are darker than it:
              plain asphalt, and the accent-soft of a bay being placed into. */}
          {tipChip && (
            <span className="truncate rounded-chip bg-surface px-1.5 py-0.5 text-micro font-medium text-soft">
              {PARK_YERI_TIP_ETIKET[yer.tip]}
            </span>
          )}
          {rezerveChip && (
            <span className="truncate rounded-chip bg-surface px-1.5 py-0.5 text-micro font-medium text-accent">
              Rezerve
            </span>
          )}
        </div>
      )}
    </>
  )
}

/**
 * The accessible name for a tile, which is the only place the gesture is
 * spoken. Kept out of the JSX because it is four cases, and four nested
 * ternaries inside an attribute is where mistakes hide.
 */
function yerEtiketi(
  yer: ParkYeri,
  d: DoluYer | undefined,
  kaynakMi: boolean,
  hedefMi: boolean,
  tasimaVar: boolean,
): string {
  if (d) {
    const plaka = formatPlaka(d.plaka)
    if (kaynakMi) return `${yer.kod}, ${plaka} — taşınıyor, bırakmak için tekrar dokunun`
    if (tasimaVar) return `${yer.kod}, ${plaka}`
    return `${yer.kod}, ${plaka} — taşımak için basılı tutun`
  }
  return hedefMi ? `${yer.kod}, boş — aracı buraya taşı` : `${yer.kod}, boş`
}

/**
 * Bays along the top and both sides, an island in the middle.
 *
 * The one arrangement the plan has. It places bays in CODE ORDER — see
 * `cevreyeBol`, which walks the shape (top, left, island, right) so the last
 * tile drawn holds the highest code.
 *
 * The sides take a fixed 22% rather than a share of a flex row: their content
 * is two bays wide and the island's is four, so letting all three grow left
 * the sides stretched to 370px on a desktop while the island stayed narrow.
 */
function CevrePlani({
  yerler,
  kutu,
}: {
  yerler: ParkYeri[]
  kutu: (y: ParkYeri) => ReactNode
}) {
  const { ust, sol, orta, sag } = cevreyeBol(yerler)
  const halka = sol.length > 0 || orta.length > 0 || sag.length > 0
  return (
    <div className="space-y-4">
      {ust.length > 0 && (
        <div className="grid grid-cols-4 gap-1 md:grid-cols-8">{ust.map((y) => kutu(y))}</div>
      )}
      {halka && (
        <div className="flex items-start gap-4">
          {sol.length > 0 && (
            <div className="grid w-[22%] gap-1 md:grid-cols-2">{sol.map((y) => kutu(y))}</div>
          )}
          {orta.length > 0 && (
            <div className="grid flex-1 grid-cols-2 gap-1 md:grid-cols-4">
              {orta.map((y) => kutu(y))}
            </div>
          )}
          {sag.length > 0 && (
            <div className="grid w-[22%] gap-1 md:grid-cols-2">{sag.map((y) => kutu(y))}</div>
          )}
        </div>
      )}
    </div>
  )
}

const TIPLER: { value: ParkYeriTip; label: string }[] = [
  { value: 'NORMAL', label: 'Normal' },
  { value: 'ENGELLI', label: 'Engelli' },
  { value: 'SARJ', label: 'Şarj' },
]

/**
 * Spots and reservations, rendered INLINE on Gişe.
 *
 * Not a screen: there is no header and no back link, because "which bay is
 * free" is a question asked while looking at the gate, and sending an
 * operator to another page to answer it — then back again — is a round trip
 * for one glance. Gişe mounts this lazily and only once expanded, so the
 * gate's own chunk stays small for the screen that loads hundreds of times
 * a day.
 *
 * THE LAYOUT IS YÖNETİCİ-ONLY; WHERE A CAR IS PARKED IS NOT. RLS lets any
 * active staff SELECT park_yerleri and rezervasyonlar — an operator at the
 * barrier has to know which bay is free and who a reserved one belongs to —
 * but every INSERT/UPDATE/DELETE policy on those tables requires
 * is_yonetici(). So adding, editing, retiring, deleting a bay and every
 * reservation control are refused by the database whatever this file does;
 * hiding them here only stops a Personel tapping a control that would fail,
 * which is a UX obligation rather than the security one.
 *
 * Moving a car to another bay is the one write Personel DO have, and it is a
 * different thing: it changes a ticket, not the lot. `bilet_yer_degistir`
 * (011) is is_staff() on purpose — Personel choose the bay at Giriş, and an
 * operator who may set a field but not correct it two minutes later will stop
 * setting it. It touches nothing but park_yeri_id on an open ticket.
 */
export function YerlerBolumu() {
  const yonetici = isYonetici(useAuth().profile)
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
  const yerDegistir = useBiletYerDegistir()
  const rezEkle = useRezervasyonEkle()
  const rezSil = useRezervasyonSil()
  const kayitSil = useKayitSil()

  const [pasifGoster, setPasifGoster] = useState(false)
  // Read once from the device, written back on every change: which plan an
  // operator prefers is theirs, and it should survive closing the panel.

  /* ---- moving a car between bays ----
   *
   * Hold an occupied bay for three seconds (or double-click it), then tap the
   * empty one. While `tasima` is set the grid stops being a list of bays and
   * becomes a target picker: only the empty active ones respond, and the bay
   * the car came off puts it back down. */
  const [tasima, setTasima] = useState<{
    biletId: string
    yerId: string
    plaka: string
  } | null>(null)
  const [tasimaHata, setTasimaHata] = useState<string | null>(null)
  const [tasimaBasari, setTasimaBasari] = useState<string | null>(null)
  /** The bay under a live long-press — it is the one drawing the progress bar. */
  const [basilan, setBasilan] = useState<string | null>(null)

  const basmaTimer = useRef<number | null>(null)
  const basmaNokta = useRef<{ x: number; y: number } | null>(null)
  /**
   * When the hold completed, not WHETHER it did.
   *
   * A long press still produces a click on pointerup, which would otherwise
   * open the edit form the instant the car was picked up. A boolean flag would
   * have to be cleared by that click — and if the browser never sent one it
   * would sit there and swallow the operator's next tap, which is the tap that
   * chooses the destination. A timestamp expires on its own.
   */
  const uzunBasmaAn = useRef(0)
  /**
   * The deferred single click on an OCCUPIED tile.
   *
   * A double-click is two clicks first, so opening the edit form immediately
   * would put a modal under the second one and the gesture could never
   * complete. Only occupied tiles pay the 250 ms — the ones the gesture lives
   * on, and the ones nobody edits in a hurry.
   */
  const tikTimer = useRef<number | null>(null)

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
  const [rezSilHata, setRezSilHata] = useState<string | null>(null)

  /* ---- spot deletion ---- */
  const [yerSilinecek, setYerSilinecek] = useState<ParkYeri | null>(null)
  const [yerSilHata, setYerSilHata] = useState<string | null>(null)

  const gorunen = useMemo(
    () => yerler.filter((y) => pasifGoster || y.is_active),
    [yerler, pasifGoster],
  )
  const aktifYerler = useMemo(() => yerler.filter((y) => y.is_active), [yerler])
  // The lot is drawn block by block — A-…, B-…, or the P/E/R scheme from
  // Otopark Ayarları — because that is how it is signposted on the ground.
  // `gorunen` is already in the server's order, so the blocks come out in it.
  const bloklar = useMemo(() => yerleriBloklara(gorunen), [gorunen])

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

  // Timers must not outlive the section: Gişe mounts it lazily and collapses
  // it again, and a pending click would open a form on an unmounted tree.
  useEffect(
    () => () => {
      if (basmaTimer.current !== null) clearTimeout(basmaTimer.current)
      if (tikTimer.current !== null) clearTimeout(tikTimer.current)
    },
    [],
  )

  useEffect(() => {
    if (!tasimaBasari) return
    const t = setTimeout(() => setTasimaBasari(null), 4000)
    return () => clearTimeout(t)
  }, [tasimaBasari])

  function basmayiBirak() {
    if (basmaTimer.current !== null) {
      clearTimeout(basmaTimer.current)
      basmaTimer.current = null
    }
    basmaNokta.current = null
    setBasilan(null)
  }

  function tasimayiBaslat(y: ParkYeri, d: DoluYer) {
    basmayiBirak()
    setTasimaHata(null)
    setTasimaBasari(null)
    setTasima({ biletId: d.bilet_id, yerId: y.id, plaka: d.plaka })
  }

  function tasi(hedef: ParkYeri) {
    if (!tasima) return
    const plaka = tasima.plaka
    setTasimaHata(null)
    void yerDegistir
      .mutateAsync({ bilet_id: tasima.biletId, yeni_yer_id: hedef.id })
      .then(() => {
        setTasima(null)
        setTasimaBasari(`${formatPlaka(plaka)} → ${hedef.kod}`)
      })
      .catch((e) =>
        // The move stays picked up on failure: the two ways it fails — the bay
        // was taken a moment ago, the car has already left — are both answered
        // by choosing again, and dropping the car would mean starting the
        // three-second hold over.
        setTasimaHata(rpcErrorText(e, 'Araç taşınamadı. Başka bir yer seçin.')),
      )
  }

  /** One tap. What it means depends entirely on whether a car is in hand. */
  function yerTikla(y: ParkYeri, d: DoluYer | undefined) {
    // The click that follows the hold — see uzunBasmaAn.
    if (Date.now() - uzunBasmaAn.current < 400) return

    if (tasima) {
      if (y.id === tasima.yerId) {
        setTasima(null) // put it back down
        setTasimaHata(null)
        return
      }
      if (d || !y.is_active) return // not a destination
      tasi(y)
      return
    }

    if (!yonetici) return
    if (tikTimer.current !== null) {
      clearTimeout(tikTimer.current)
      tikTimer.current = null
    }
    if (d) {
      tikTimer.current = window.setTimeout(() => {
        tikTimer.current = null
        yerDuzenle(y)
      }, 250)
    } else {
      yerDuzenle(y)
    }
  }

  /**
   * One bay, with every gesture that can happen on it.
   *
   * A closure rather than a component: both plans render bays, and this needs
   * nine pieces of this component's state — the move in progress, the timers,
   * the role. Passing all of that down would be a prop list nobody could keep
   * correct, and getting it wrong here means a bay that silently stops
   * responding to a three-second hold.
   */
  function yerKutusu(y: ParkYeri, ortak: BlokOrtak) {
    const d = dolu[y.id]
    const kaynakMi = tasima?.yerId === y.id
    const hedefMi = Boolean(tasima) && !kaynakMi && !d && y.is_active
    // Only outside move mode: a car already in hand is not picked up again.
    const tasinabilir = Boolean(d) && y.is_active && !tasima
    // In move mode the plan IS the destination picker, so nothing else
    // responds — including a Yönetici's edit tap, which would otherwise open a
    // form over a half-finished move.
    const etkilesimli = tasima ? kaynakMi || hedefMi : yonetici || tasinabilir
    const isaretli = kaynakMi || hedefMi

    const govde = <YerGovde yer={y} plaka={d?.plaka} ortak={ortak} tasiniyor={kaynakMi} />
    const sinif = [
      'relative flex min-h-[74px] flex-col overflow-hidden rounded-chip p-1.5 text-left no-select',
      // Every bay is asphalt, occupied or not — a lot is one surface, and the
      // car is what marks a bay as taken. Flooring occupied bays in `surface`
      // was tried and is wrong: on a white panel they vanish, and the free
      // ones end up reading as holes punched in the plan.
      //
      // Exactly ONE background and ONE opacity class: Tailwind orders
      // utilities by its own rules, not by the order they appear in this
      // array, so two of either is a coin toss.
      isaretli ? 'bg-accent-soft' : 'bg-field',
      !y.is_active ? 'opacity-55' : tasima && !isaretli ? 'opacity-40' : '',
      // An INSET ring: a normal one is drawn outside the box and would cover
      // the aisle and the bay next door.
      kaynakMi ? 'inset-ring-2 inset-ring-accent' : hedefMi ? 'inset-ring-1 inset-ring-accent' : '',
    ].join(' ')

    // Two explicit branches rather than one element with a computed tag: this
    // is an RBAC fork, and the version a Personel gets must be obvious on
    // sight. A plain div, not a disabled button — a tappable-looking bay that
    // does nothing reads as a broken screen, and `disabled` would dim
    // information they are entitled to read.
    return etkilesimli ? (
      <button
        key={y.id}
        type="button"
        onClick={() => yerTikla(y, d)}
        onDoubleClick={() => {
          if (!tasinabilir || !d) return
          if (tikTimer.current !== null) {
            clearTimeout(tikTimer.current)
            tikTimer.current = null
          }
          tasimayiBaslat(y, d)
        }}
        onPointerDown={(e) => {
          if (!tasinabilir || !d) return
          basmaNokta.current = { x: e.clientX, y: e.clientY }
          setBasilan(y.id)
          basmaTimer.current = window.setTimeout(() => {
            uzunBasmaAn.current = Date.now()
            // Haptic where there is one: the bar says the hold is running,
            // this says it is done, and on a phone at a barrier that is felt
            // before it is seen.
            navigator.vibrate?.(30)
            tasimayiBaslat(y, d)
          }, 3000)
        }}
        onPointerMove={(e) => {
          const n = basmaNokta.current
          if (!n) return
          // A scroll is a press that moved. Ten pixels of slop so a thumb
          // resting on a bay still counts as holding it.
          if (Math.abs(e.clientX - n.x) > 10 || Math.abs(e.clientY - n.y) > 10) {
            basmayiBirak()
          }
        }}
        onPointerUp={basmayiBirak}
        onPointerCancel={basmayiBirak}
        onPointerLeave={basmayiBirak}
        onContextMenu={(e) => {
          // Android raises this mid-hold and would cancel it.
          if (tasinabilir) e.preventDefault()
        }}
        aria-label={yerEtiketi(y, d, kaynakMi, hedefMi, Boolean(tasima))}
        className={`${sinif} transition-[filter,opacity] active:brightness-[0.97]`}
      >
        {govde}
        {basilan === y.id && (
          <span aria-hidden className="basili-cubuk absolute inset-x-0 bottom-0 h-1 bg-accent" />
        )}
      </button>
    ) : (
      <div key={y.id} className={sinif}>
        {govde}
      </div>
    )
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
      <div className="space-y-6">
        {/* ------------------------------------------------------- spots --- */}
        <section>
          <div className="mb-2 flex items-baseline justify-between gap-3">
            <h2 className="text-label font-medium tracking-wide text-faint uppercase">
              Yerler
            </h2>
            {/* A retired bay is not a bay an operator can use, so this
                toggle — and adding one — only mean something to whoever can
                un-retire it. */}
            {yonetici && (
              <div className="flex shrink-0 items-baseline gap-4">
                <button
                  type="button"
                  onClick={() => setPasifGoster((v) => !v)}
                  className="min-h-[36px] text-label font-medium text-accent"
                >
                  {pasifGoster ? 'Pasifleri gizle' : 'Pasifleri göster'}
                </button>
                <button
                  type="button"
                  onClick={yeniYer}
                  className="flex min-h-[36px] items-center gap-1 text-label font-medium text-accent"
                >
                  <IconArti size={16} />
                  Yer ekle
                </button>
              </div>
            )}
          </div>

          {/* An invisible gesture is not a feature: nothing on a tile says it
              can be held, so the line that says so is part of the feature
              rather than documentation. It steps aside while a car is in hand,
              where the banner has something more urgent to say. */}
          {!tasima && Object.keys(dolu).length > 0 && (
            <p className="mb-2 text-label text-faint">
              Bir aracı taşımak için yerini 3 sn basılı tutun, sonra boş yere dokunun.
              <span className="hidden sm:inline"> Masaüstünde çift tıklayın.</span>
            </p>
          )}

          {tasima && (
            <div className="mb-2 flex items-center gap-3 rounded-card bg-accent-soft px-3.5 py-2.5">
              <p className="min-w-0 flex-1 text-body text-accent">
                <strong className="font-semibold tnum">{formatPlaka(tasima.plaka)}</strong> taşınıyor
                — boş bir yere dokunun
              </p>
              <button
                type="button"
                onClick={() => {
                  setTasima(null)
                  setTasimaHata(null)
                }}
                className="min-h-[36px] shrink-0 text-label font-medium text-accent"
              >
                Vazgeç
              </button>
            </div>
          )}

          {tasimaHata && (
            <p
              role="alert"
              className="mb-2 rounded-card bg-danger-soft px-3.5 py-2.5 text-body text-danger"
            >
              {tasimaHata}
            </p>
          )}

          {tasimaBasari && (
            <p className="mb-2 rounded-card bg-success-soft px-3.5 py-2.5 text-body font-medium text-success tnum">
              {tasimaBasari}
            </p>
          )}

          <ListeDurumu
            pending={isPending}
            error={error}
            onRetry={() => void refetch()}
            empty={gorunen.length === 0}
            bos={
              <EmptyState
                icon={<IconYer size={44} />}
                title="Henüz yer tanımlanmadı"
                hint={
                  yonetici
                    ? 'Numaralandırılmış yerler girişte araca atanabilir ve rezerve edilebilir.'
                    : 'Numaralandırılmış yer tanımlanana kadar araçlar yer seçilmeden alınır.'
                }
                action={yonetici ? <Button onClick={yeniYer}>Yer ekle</Button> : undefined}
              />
            }
          >
            {/* One arrangement, placing bays in CODE ORDER into a stylised
                shape — see duzen.ts. It does not know where a bay physically
                is. */}
            <div>
              {bloklar.map((b, bi) => {
                const doluSayi = b.yerler.filter((y) => dolu[y.id]).length
                const ortak = blokOrtak(b.yerler)
                // Said once in the heading so the bays can stop repeating it.
                // A note identical to the block's own name is dropped: an
                // "Engelli · Engelli" heading helps nobody.
                const notlar = [
                  ortak.tip && ortak.tip !== 'NORMAL' ? PARK_YERI_TIP_ETIKET[ortak.tip] : null,
                  ortak.rezerve ? 'Rezerve' : null,
                ].filter((n): n is string => n !== null && n !== b.etiket)
                const kutu = (y: ParkYeri) => yerKutusu(y, ortak)
                return (
                  <div
                    key={b.blok}
                    // The drive aisle between two blocks. Without it they butt
                    // together and the headings are the only thing left saying
                    // they are different parts of the lot.
                    className={bi > 0 ? 'mt-5 border-t border-dashed border-border pt-5' : ''}
                  >
                    <div className="mb-2 flex items-baseline justify-between gap-2">
                      <h3 className="truncate text-label font-semibold text-soft">
                        {b.etiket}
                        {notlar.length > 0 && (
                          <span className="font-normal text-faint"> · {notlar.join(' · ')}</span>
                        )}
                      </h3>
                      <span className="shrink-0 text-micro text-faint tnum">
                        {doluSayi}/{b.yerler.length} dolu
                      </span>
                    </div>

                    <CevrePlani yerler={b.yerler} kutu={kutu} />
                  </div>
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
            {yonetici && (
              <button
                type="button"
                onClick={yeniRezervasyon}
                disabled={aktifYerler.length === 0}
                className="min-h-[36px] text-label font-medium text-accent disabled:opacity-45"
              >
                Rezervasyon ekle
              </button>
            )}
          </div>

          <ListeDurumu
            pending={rezPending}
            error={rezError}
            onRetry={() => void rezRefetch()}
            empty={rezervasyonlar.length === 0}
            bos={
              <p className="py-1 text-body text-faint">
                {yonetici
                  ? 'Ayrılmış yer yok. Bir yeri belirli bir plakaya ve döneme bağlayabilirsiniz.'
                  : 'Ayrılmış yer yok.'}
              </p>
            }
          >
            <div className="space-y-2">
              {rezervasyonlar.map((r) => {
                const { bas, bit } = araligiGunler(r.gecerlilik)
                const suan = araliktaMi(r.gecerlilik)
                return (
                  <div
                    key={r.id}
                    className="flex items-center gap-3 rounded-card bg-field p-3.5"
                  >
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
                    {yonetici && (
                      <button
                        type="button"
                        onClick={() => {
                          setRezSilHata(null)
                          setSilinecek(r.id)
                        }}
                        aria-label="Rezervasyonu sil"
                        className="flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field"
                      >
                        <IconCop size={18} />
                      </button>
                    )}
                  </div>
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
        {/* P-01 / E-01 / R-01 are produced from the capacity in Otopark
            Ayarları and are managed there — this form stays for the bays that
            fall outside the scheme (a şarj point, an odd corner bay), and for
            renaming. Saying so here is what stops someone hand-numbering a
            whole lot one row at a time. */}
        <Input
          label="Yer kodu"
          value={kod}
          onChange={(e) => setKod(e.target.value.toUpperCase())}
          placeholder="S-01"
          maxLength={12}
          autoCapitalize="characters"
          className="tnum"
          hint={
            duzenlenen
              ? undefined
              : 'P / E / R kodları kapasiteden otomatik üretilir — Otopark Ayarları.'
          }
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
        {/* Retiring and deleting are different answers to different problems,
            so they sit together and read as a pair: the Toggle above keeps the
            bay and its history, this removes the row. Deleting is the quiet
            one because it is almost never what someone wants. */}
        {duzenlenen && (
          <button
            type="button"
            onClick={() => {
              // Close the form before opening the confirmation: two stacked
              // Radix dialogs fight over the focus trap.
              const y = duzenlenen
              setYerAcik(false)
              setYerSilHata(null)
              setYerSilinecek(y)
            }}
            className="flex min-h-[44px] w-full items-center justify-center gap-2 rounded-field text-label font-medium text-faint"
          >
            <IconCop size={16} />
            Bu yeri sil
          </button>
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
        <Select
          id="rez-yer"
          label="Yer"
          value={rezYer}
          onChange={(e) => setRezYer(e.target.value)}
        >
          {aktifYerler.map((y) => (
            <option key={y.id} value={y.id}>
              {y.kod}
              {y.rezerve ? ' · rezerve' : ''}
            </option>
          ))}
        </Select>
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
        description="Yer yeniden serbest kalacak. Çöp Kutusu'ndan geri alınabilir."
        confirmLabel="Sil"
        loading={rezSil.isPending}
        error={rezSilHata}
        onConfirm={() => {
          if (!silinecek) return
          void rezSil
            .mutateAsync(silinecek)
            .then(() => setSilinecek(null))
            .catch((e) => setRezSilHata(rpcErrorText(e, 'Silinemedi.')))
        }}
      />

      <ConfirmDialog
        open={yerSilinecek !== null}
        onOpenChange={() => setYerSilinecek(null)}
        tone="danger"
        title="Yeri sil"
        description={
          yerSilinecek
            ? `${yerSilinecek.kod} silinecek. Bu yere bağlı rezervasyonlar da kalkar. Yeri kullanmayı bırakmak istiyorsanız silmek yerine "Kullanımda"yı kapatın — geçmiş kayıtlar öyle korunur. Çöp Kutusu'ndan geri alınabilir.`
            : ''
        }
        confirmLabel="Sil"
        loading={kayitSil.isPending}
        error={yerSilHata}
        onConfirm={() => {
          if (!yerSilinecek) return
          void kayitSil
            .mutateAsync({ tablo: 'park_yerleri', id: yerSilinecek.id })
            .then(() => setYerSilinecek(null))
            .catch((e) => setYerSilHata(rpcErrorText(e, 'Yer silinemedi.')))
        }}
      />
    </div>
  )
}
