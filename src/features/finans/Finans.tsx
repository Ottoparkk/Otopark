import { useMemo, type ReactNode } from 'react'
import { useNavigate } from 'react-router'
import { BrandPanel, IconTile, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { MenuKart, DonemSecici, useDonem } from '../yonetim/components'
import { Sparkline } from './charts'
import {
  useDonemAralik,
  useKasaHareketleri,
  useRaporGunluk,
  useOnayOzet,
  useVardiyaTalepleri,
  useRaporOzet,
  useTumVardiyalar,
  useYontemOzet,
} from './api'
import { formatTL } from '../../lib/money'
import { ODEME_ETIKET, type OdemeYontemi } from '../../lib/types'
import { gunEkle, gunFarki } from '../../lib/dates'
import {
  IconAraba,
  IconEtiket,
  IconIleri,
  IconKasa,
  IconOnay,
  IconRapor,
  IconUyari,
  IconVardiya,
} from '../../components/ui/icons'

const kisaTL = (kurus: number) => formatTL(kurus, { decimals: 0 })

/**
 * The Finans home.
 *
 * Money lives in TWO separate ledgers and this is the only screen that adds
 * them together, so the arithmetic is stated once, here:
 *
 *   ciro     = SUM(tahsilatlar)            collected at the barrier, via
 *                                          rapor_ozet. Already net of
 *                                          cancellations, which are stored as
 *                                          negative counter-entries.
 *   ek gelir = SUM(kasa_hareketleri GELIR) anything not taken at the barrier
 *   gider    = SUM(kasa_hareketleri GIDER)
 *   net      = ciro + ek gelir - gider
 *
 * Adding the two is only safe because nothing writes to both: `tahsilatlar` is
 * written solely by the ticket and subscription RPCs, `kasa_hareketleri`
 * solely by hand. Both are filtered on Istanbul calendar dates, so the two
 * windows line up exactly.
 *
 * The Kasa SCREEN shows both tables as one ledger, so its net for a period is
 * this same `net` by construction — approval does not copy a collection into
 * `kasa_hareketleri`, it just lets it count.
 *
 * KASA IS A BALANCE, BILET IS A REPORT. The Kasa card shows the money on hand
 * across all time and is moved by approvals and by kasa entries; the Bilet
 * card is an informational figure for what bilet and abonman brought in during
 * the selected period. The second is a COMPONENT of the first, never an
 * addition to it — adding the two would count every ticket twice.
 */
export default function Finans() {
  const navigate = useNavigate()
  // Opens on TÜMÜ: the first question anyone brings to this screen is "how
  // much has this car park made", not "how much this week". Narrowing is one
  // tap away; a default window silently hides the rest of the money.
  const { donem, ozel, secim } = useDonem()
  const { bas, bit, hazir, ilkGunHatasi } = useDonemAralik(donem, ozel)

  // The immediately preceding window of the SAME LENGTH, so the change chip
  // compares like with like instead of this week against a whole month.
  // Meaningless for TÜMÜ — there is nothing before "everything" — so it is
  // not even requested there.
  const onceki = useMemo(() => {
    // gunFarki() is relative to TODAY, so the length of [bas, bit] is the
    // difference of the two offsets, inclusive: Bugün = 1, 7 gün = 7, 30 = 30.
    const uzunluk = gunFarki(bit) - gunFarki(bas) + 1
    return { bas: gunEkle(-uzunluk, bas), bit: gunEkle(-1, bas) }
  }, [bas, bit])

  const ozet = useRaporOzet(bas, bit, hazir)
  const yontemler = useYontemOzet(bas, bit, hazir)
  /**
   * All three channels, always, in a fixed order.
   *
   * An earlier version hid a channel whose net was zero, on the theory that
   * three zeroes are furniture. That was wrong for this screen: it made the
   * whole row invisible on a lot that has not taken money yet, so there was
   * no way to tell "nothing came in through Havale" from "this feature is not
   * working". A zero here is an answer, and an operator who has just switched
   * period needs the channels to stay in the same places.
   */
  const yontemNet = useMemo(() => {
    const sira: OdemeYontemi[] = ['NAKIT', 'KREDI_KARTI', 'HAVALE']
    return sira.map((yontem) => {
      const r = (yontemler.data ?? []).find((x) => x.yontem === yontem)
      return { yontem, net: (r?.gelir_kurus ?? 0) - (r?.gider_kurus ?? 0) }
    })
  }, [yontemler.data])
  const oncekiOzet = useRaporOzet(onceki.bas, onceki.bit, hazir && donem !== 'TUMU')
  const gunluk = useRaporGunluk(bas, bit, hazir)
  const kasa = useKasaHareketleri(bas, bit, hazir)
  // Not period-scoped, unlike everything else on this screen: a collection
  // still waiting for a decision is outstanding today whichever window is
  // selected, and hiding it behind "Bugün" is how it would be forgotten.
  const onay = useOnayOzet()
  // A waiting till close has no other signal anywhere in the app: without it
  // here the operator is standing at a shift that will not close, and the
  // Yönetici has no reason to open the screen that would close it.
  const { data: vardiyaTalep = [] } = useVardiyaTalepleri()

  /**
   * What is actually in the till — the money we have, not the money that
   * moved inside the selected window.
   *
   * Deliberately ignores the period chips, which is why it is fetched over the
   * whole history instead of `bas`/`bit`: a balance is a position, not a
   * window, and "Bugün" would otherwise turn the till into today's takings.
   * Approving a collection moves it, a kasa entry moves it — the same two
   * things the Kasa screen lists.
   */
  const tum = useDonemAralik('TUMU')
  const tumOzet = useRaporOzet(tum.bas, tum.bit, tum.hazir)
  const tumKasa = useKasaHareketleri(tum.bas, tum.bit, tum.hazir)
  const kasadaki = useMemo(() => {
    const h = tumKasa.data ?? []
    const gelir = h.filter((x) => x.tur === 'GELIR').reduce((a, x) => a + x.tutar_kurus, 0)
    const gider = h.filter((x) => x.tur === 'GIDER').reduce((a, x) => a + x.tutar_kurus, 0)
    return (tumOzet.data?.ciro_kurus ?? 0) + gelir - gider
  }, [tumKasa.data, tumOzet.data])
  const { data: vardiyalar = [] } = useTumVardiyalar()

  const ciro = ozet.data?.ciro_kurus ?? 0

  // Two different queues behind one card. The figure stays the collections
  // total — a shift close has no single amount of its own — so the caption is
  // what has to carry the second queue.
  const tahsilatAdet = onay.data?.adet ?? 0
  const onayBekleyen = tahsilatAdet > 0 || vardiyaTalep.length > 0
  const onayAlt =
    tahsilatAdet > 0 && vardiyaTalep.length > 0
      ? tahsilatAdet + ' tahsilat + vardiya kapatma'
      : tahsilatAdet > 0
        ? tahsilatAdet + ' tahsilat bekliyor'
        : vardiyaTalep.length > 0
          ? 'vardiya kapatma bekliyor'
          : 'bekleyen yok'

  const kasaToplam = useMemo(() => {
    const h = kasa.data ?? []
    return {
      gelir: h.filter((x) => x.tur === 'GELIR').reduce((a, x) => a + x.tutar_kurus, 0),
      gider: h.filter((x) => x.tur === 'GIDER').reduce((a, x) => a + x.tutar_kurus, 0),
    }
  }, [kasa.data])

  const toplamGelir = ciro + kasaToplam.gelir
  const net = toplamGelir - kasaToplam.gider

  // Cash that did not reconcile is the number that matters most in a cash
  // business, and it stays invisible unless a screen goes looking for it.
  const farkli = useMemo(
    () => vardiyalar.filter((v) => v.fark_kurus !== null && v.fark_kurus !== 0),
    [vardiyalar],
  )

  const yukleniyor = !hazir || ozet.isPending || gunluk.isPending || kasa.isPending
  const hata = ilkGunHatasi ?? ozet.error ?? gunluk.error ?? kasa.error

  return (
    // The HEADER is inside the centred wrapper, not above it. ScreenHeader
    // carries its own horizontal padding and is shared by every screen, so
    // centring only the body left "Finans" hanging ~120px to the left of the
    // cards it belongs to — this screen is the only one that centres its body,
    // which is why it was the only one with an orphaned title.
    <div className="md:mx-auto md:max-w-[900px]">
      <ScreenHeader title="Finans" />

      {/* ONE column at every width, in the order the screen is read: the
          money, then how it was made, then the audit numbers and the way out.
          A side column put Denetim level with the headline figure, which gave
          two unrelated things equal billing and left the eye choosing between
          them. Capped rather than run out to the shell's full 1052 — a row of
          plain text a metre wide is not a dashboard, it is a stretched phone. */}
      <div className="px-5">
        {/* ---------------------------------------- money and its sources --- */}
        <div className="space-y-4">
          {hata ? (
            <LoadError
              error={hata}
              onRetry={() => {
                void ozet.refetch()
                void gunluk.refetch()
                void kasa.refetch()
              }}
            />
          ) : yukleniyor ? (
            <div className="py-14">
              <Spinner label="Finans hazırlanıyor" />
            </div>
          ) : (
            /* ---- net: the number this whole section exists for ---------- */
            <BrandPanel>
              {/* One instance of each part, placed differently by width. A
                  phone stacks: net, then a rule, then its two components. A
                  desktop panel is ~600px wide, and stacking there left the
                  right two thirds empty while the content huddled in the top
                  left — so from md up the components move BESIDE the headline
                  and the rule turns vertical. */}
              <div className="md:flex md:items-end md:justify-between md:gap-8">
                <div className="min-w-0 md:flex-1">
                  <p className="text-label font-medium tracking-wide text-on-brand-soft uppercase">
                    Net
                  </p>
                  <div className="mt-1.5 flex items-end justify-between gap-3 md:justify-start">
                    <p className="text-hero font-semibold tnum">{kisaTL(net)}</p>
                    <DegisimRozeti simdi={ciro} once={oncekiOzet.data?.ciro_kurus ?? 0} />
                  </div>

                  {(gunluk.data ?? []).length > 1 && (
                    <div className="mt-3 text-on-brand">
                      <Sparkline veri={(gunluk.data ?? []).map((g) => g.ciro_kurus)} />
                    </div>
                  )}
                </div>

                <div className="mt-4 flex gap-6 border-t border-white/15 pt-3.5 md:mt-0 md:shrink-0 md:border-t-0 md:border-l md:pt-0 md:pb-1 md:pl-8">
                  <div>
                    {/* Paler than the green and red used on white: on this
                        teal panel the ordinary tokens fall under AA (3.98 and
                        3.00). See --on-brand-success / --on-brand-danger. */}
                    <p className="text-lead font-semibold text-on-brand-success tnum">
                      {kisaTL(toplamGelir)}
                    </p>
                    <p className="text-label text-on-brand-soft">gelir</p>
                  </div>
                  <div>
                    <p className="text-lead font-semibold text-on-brand-danger tnum">
                      {kisaTL(kasaToplam.gider)}
                    </p>
                    <p className="text-label text-on-brand-soft">gider</p>
                  </div>
                </div>
              </div>

              {/* Where the money actually came in and went out. Rendered only
                  when at least one entry carries a method — three zeroes on a
                  fresh lot is furniture, not information.

                  The three CAN total less than Net: `yontem` is optional, and
                  an entry without one is counted by no bucket. Shown as a net
                  per channel (gelir − gider), which is what "how much cash is
                  in the drawer" actually means. */}
              {/* Gated on the query having ANSWERED, not on the figures
                  being non-zero: until migration 015 is run the RPC does not
                  exist and the call fails, and three zeroes would then be a
                  lie — it would read as "no cash taken" when the truth is
                  "nobody asked the server yet". */}
              {yontemler.data !== undefined && (
                <div className="mt-4 flex flex-wrap gap-x-6 gap-y-2 border-t border-white/15 pt-3.5">
                  {yontemNet.map((y) => (
                    <div key={y.yontem}>
                      <p className="text-lead font-semibold tnum">{kisaTL(y.net)}</p>
                      <p className="text-label text-on-brand-soft">{ODEME_ETIKET[y.yontem]}</p>
                    </div>
                  ))}
                </div>
              )}
            </BrandPanel>
          )}

          {/* Under the headline figure, not above it. The first thing anyone
              wants off this screen is the number; the period is the follow-up
              question, and putting the control first made the screen open on a
              filter rather than on an answer. Outside the loading branch on
              purpose — the period must stay switchable while figures load and
              after one fails, which is exactly when it gets narrowed. */}
          <DonemSecici value={donem} ozel={ozel} onChange={secim} />

          {/* ---- where the money is, each card a way in --------------- */}
          {/* Kasa across the top, Bilet and Onay as equal halves under it.
              Kasa leads because it is the ledger somebody actually keeps —
              its entries are made by hand and it is the only one of the three
              that can be wrong — while Bilet ciro is a read-only consequence
              of the barrier and Onay is a queue.

              ONE COLUMN on a phone, so no card is ever narrow. Two across a
              375px screen leaves the smaller one 94.8px for its figure, and a
              seven-digit sum is 107.9px at 22px — it clipped exactly the
              totals worth reading. From md a half is ~420px, where it fits
              several times over. */}
          {!hata && !yukleniyor && (
            <div className="grid gap-3 md:grid-cols-2">
              <ToplamKart
                className="md:col-span-2"
                baslik="Kasa"
                deger={kisaTL(kasadaki)}
                alt="şu an kasada · tüm zamanlar"
                tone={kasadaki < 0 ? 'danger' : 'accent'}
                icon={<IconKasa size={20} />}
                onClick={() => navigate('/finans/kasa')}
              />
              {/* The heading is "Bilet", but the figure is not: rapor_ozet
                  sums tahsilatlar with no filter on tur, so it carries abonman
                  collections too. That half is not dropped, only demoted to
                  the pale line, which is where the scope of a number belongs
                  once its heading has been shortened.

                  That line carried the çıkış count as well until a seven-digit
                  total left it 123px and wrapped it onto two lines, making
                  this card visibly taller than the one beside it. The count is
                  one tap away on the screen this card opens; equal-height
                  cards are not. */}
              <ToplamKart
                baslik="Bilet"
                deger={kisaTL(ciro)}
                alt="ve abonman"
                tone="success"
                icon={<IconAraba size={20} />}
                onClick={() => navigate('/finans/biletler')}
              />
              {/* Same block as Bilet, under Kasa: this is money too — taken,
                  but not yet accepted into the figures above it. That makes it
                  the answer to "why is Ciro lower than what we took today",
                  and an answer belongs beside the question rather than filed
                  under Detaylar. Shown even at zero, because it is also the
                  only way in to the approved and rejected history. */}
              <ToplamKart
                baslik="Onay"
                deger={kisaTL(onay.data?.toplam_kurus ?? 0)}
                alt={onayAlt}
                tone={onayBekleyen ? 'mor' : 'neutral'}
                icon={<IconOnay size={20} />}
                onClick={() => navigate('/finans/onay')}
              />
            </div>
          )}
        </div>

        {/* ------------------------------------- audit, then the exits --- */}
        <div className="mt-4 space-y-4">
          {!hata && !yukleniyor && (
            <>
              {/* ---- cash that did not add up -------------------------- */}
              {farkli.length > 0 && (
                <button
                  type="button"
                  onClick={() => navigate('/finans/vardiyalar')}
                  className="flex w-full items-center gap-3 rounded-card bg-warn-soft px-4 py-3 text-left"
                >
                  <IconUyari size={20} className="shrink-0 text-warn" />
                  <span className="flex-1 text-body font-medium text-warn">
                    {farkli.length} vardiyada kasa farkı var
                  </span>
                  <IconIleri size={17} className="shrink-0 text-warn" />
                </button>
              )}

            </>
          )}

          {/* Outside the loading branch on purpose: the way out of this
              screen should not disappear while the figures are arriving. */}
          <section>
          {/* Only the destinations NOT already reachable from a card above.
              Kasa and Bilet geçmişi each had a tile here as well as their own
              summary card, so this screen linked to five places eight times. */}
          <h2 className="mb-2 text-label font-medium tracking-wide text-faint uppercase">
            Detaylar
          </h2>
          {/* Two across on a phone (three in a 2-wide grid leaves a ragged
              2+1), all three across on desktop now that the row is full
              width. They stay stacked tiles: at ~275px each, an icon beside
              two lines of text wraps the description. */}
          <div className="grid grid-cols-2 gap-3 md:grid-cols-3">
            <MenuKart
              to="/finans/raporlar"
              tone="accent"
              icon={<IconRapor size={22} />}
              baslik="Raporlar"
              aciklama="Ciro, yoğunluk, kalış süresi"
            />
            <MenuKart
              to="/finans/vardiyalar"
              tone={farkli.length > 0 ? 'warn' : 'accent'}
              icon={<IconVardiya size={22} />}
              baslik="Vardiyalar"
              aciklama="Kasa sayımları ve farklar"
            />
            {/* Prices belong with the money they generate, not with the
                capacity and camera settings they used to sit beside. */}
            <MenuKart
              to="/finans/tarifeler"
              tone="accent"
              icon={<IconEtiket size={22} />}
              baslik="Tarifeler"
              aciklama="Ücretler — değişiklik sürümlenir"
            />
            </div>
          </section>
        </div>
      </div>
    </div>
  )
}

/* ------------------------------------------------------------ components */

/**
 * Period-over-period change.
 *
 * Compares CIRO, not net, on purpose: kasa entries are lumpy and manual, so a
 * single rent payment landing inside one window would swamp the trading figure
 * this chip is meant to describe. Silent when there is no previous period to
 * divide by — a percentage against zero is noise, not information.
 */
function DegisimRozeti({ simdi, once }: { simdi: number; once: number }) {
  if (once <= 0) return null
  const yuzde = Math.round(((simdi - once) / once) * 100)
  if (yuzde === 0) return null
  const artis = yuzde > 0
  return (
    <span
      className={
        'mb-1.5 shrink-0 rounded-chip px-2 py-1 text-label font-medium tnum ' +
        (artis ? 'bg-success-soft text-success' : 'bg-danger-soft text-danger')
      }
      title="Önceki eşit uzunluktaki döneme göre ciro değişimi"
    >
      {artis ? '▲' : '▼'} %{Math.abs(yuzde)}
    </span>
  )
}

function ToplamKart({
  baslik,
  deger,
  alt,
  tone,
  icon,
  onClick,
  className = '',
}: {
  baslik: string
  deger: string
  alt: string
  tone: 'success' | 'accent' | 'warn' | 'danger' | 'neutral' | 'mor'
  icon: ReactNode
  onClick: () => void
  /** Grid span. The caller owns the width; the card owns everything else. */
  className?: string
}) {
  return (
    // One row: what it is on the left, what it comes to on the right. The
    // figure is pushed to the edge rather than following the label, so the two
    // cards' numbers land on the same right margin and can be read against
    // each other — the whole reason they sit one above the other.
    <button
      type="button"
      onClick={onClick}
      className={[
        'flex items-center gap-3 rounded-card border border-border bg-surface p-4 text-left shadow-card',
        'transition-transform duration-100 active:scale-[0.99]',
        className,
      ].join(' ')}
    >
      <IconTile tone={tone}>{icon}</IconTile>
      <div className="min-w-0">
        <p className="text-body font-semibold text-ink">{baslik}</p>
        <p className="text-label text-faint tnum">{alt}</p>
      </div>
      {/* pl-3 is a floor on the gap, not decoration: ml-auto collapses to
          nothing once the label and the figure fill the row, and a long total
          would otherwise touch the word beside it. */}
      <p className="ml-auto shrink-0 pl-3 text-title font-semibold text-ink tnum">{deger}</p>
    </button>
  )
}
