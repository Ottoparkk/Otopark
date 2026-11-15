import { Suspense, lazy, useEffect, useState } from 'react'
import { useLocation, useNavigate } from 'react-router'
import { BrandPanel, OranCubugu, ScreenHeader } from '../../components/ui/primitives'
import { DolulukRozeti, VardiyaUyarisi, dolulukYuzde } from './components'
import { GirisBolumu } from './Giris'
import { AracListesi, Tahsilat } from './Cikis'
import { useAcikBiletler, useGunlukOzet } from './api'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'
import { DonemSecici, MenuKart, useDonem } from '../yonetim/components'
import { useDonemAralik, useRaporOzet } from '../finans/api'
import { useAcikIstisnaSayisi } from '../istisna/api'
import { cikisAramasi } from './cikisLink'
import { formatTL } from '../../lib/money'
import {
  IconAraba,
  IconArti,
  IconKamera,
  IconTik,
  IconYer,
} from '../../components/ui/icons'
import type { AcikBilet } from '../../lib/types'

// Lazily loaded so the spot grid, its two form modals and the confirm dialog
// stay out of the gate's chunk — this is the screen an operator opens all
// day, and most openings never expand this section.
const YerlerBolumu = lazy(() =>
  import('../yerler/Yerler').then((m) => ({ default: m.YerlerBolumu })),
)

/**
 * The gate. Everything an operator does all day lives on this one page.
 *
 * There are no mode tabs. The page IS the list of vehicles — the ones inside,
 * then the ones that recently left — and the two things you can do to it are
 * reached without ever choosing a mode first:
 *
 *   çıkış  — tap a car in the list
 *   giriş  — the floating button
 *
 * An earlier version had a `Giriş | Çıkış` toggle at the top, which forced a
 * navigation decision before every single action and made the list a
 * second-class citizen of a mode it did not belong to. Entry is one action
 * among a screenful of cars, so it gets one button, not half the screen.
 */
export default function Gise() {
  const navigate = useNavigate()
  const { pathname, state } = useLocation()

  // Entry stays a real URL so deep links keep working — the exceptions screen
  // and notifications both link into this page, and the browser back button
  // should close the form rather than leave the app.
  const girisAcik = pathname.endsWith('/giris')

  // Opened as "Çıkış" from Çözülmemiş kayıtlar: start with that card's plate
  // in the search and the cursor in it (cikisLink.ts). Read once, on arrival;
  // cleared once a car is picked, so the hint does not return after collecting.
  const [cikisAra, setCikisAra] = useState(() => cikisAramasi(pathname, state))
  const [sorgu, setSorgu] = useState(cikisAra ?? '')
  /**
   * The confirmation handed over by Araç Girişi as it closed itself.
   *
   * Read out of the router state and then CLEARED from it: left in place, a
   * reload or a back-tap would replay a stale "kaydedildi" for a car that was
   * entered an hour ago, which is worse than showing nothing.
   */
  const [girisBasari, setGirisBasari] = useState<{
    plaka: string
    yerKod: string | null
  } | null>(null)
  const [secili, setSecili] = useState<AcikBilet | null>(null)
  // Park yerleri: opened from the icon in the occupancy card (owner,
  // 2026-11-15 — the row of its own is gone).
  const [yerlerAcik, setYerlerAcik] = useState(false)

  const { data: biletler = [], isPending, error, refetch } = useAcikBiletler(sorgu)
  const { data: ozet } = useGunlukOzet()

  /**
   * A date range on THIS screen is Yönetici-only, and not because of the
   * button — because of what it would show. Personel are allowed today's lot
   * total and their own shift, nothing else; a range here would hand them the
   * revenue history the whole role boundary exists to withhold. The chips are
   * hidden and the query is disabled for them, and `rapor_ozet` refuses them
   * anyway, which is where the boundary actually is.
   *
   * Occupancy is deliberately NOT re-scoped: it is a fact about right now, and
   * a "how full was the lot last Tuesday" figure is a different question this
   * panel does not answer.
   */
  const { profile } = useAuth()
  const yonetici = isYonetici(profile)
  const { donem, ozel, secim } = useDonem('BUGUN')
  const gecmis = yonetici && donem !== 'BUGUN'
  const { bas, bit, hazir } = useDonemAralik(donem, ozel)
  // 067 (owner, 2026-11-15): the chips also scope Çıkanlar. Tümü is no
  // bound at all (not "since the first ticket", which needs a round trip
  // first). Personel only ever pick Bugün / 3 gün, and RLS holds them to it.
  const cikisAralik = donem === 'TUMU' ? null : { bas, bit }
  const { data: aralikOzet } = useRaporOzet(bas, bit, gecmis && hazir)
  const { data: acikIstisna = 0 } = useAcikIstisnaSayisi()

  useEffect(() => {
    const s = state as { girisBasari?: { plaka: string; yerKod: string | null } } | null
    if (!s?.girisBasari) return
    setGirisBasari(s.girisBasari)
    navigate(pathname, { replace: true, state: null })
  }, [state, navigate, pathname])

  useEffect(() => {
    if (!girisBasari) return
    const t = setTimeout(() => setGirisBasari(null), 5000)
    return () => clearTimeout(t)
  }, [girisBasari])

  // Keep the selected ticket in step with refetches (points may have been
  // applied, the camera may have flagged it at the gate).
  useEffect(() => {
    if (!secili) return
    const guncel = biletler.find((b) => b.id === secili.id)
    if (guncel && guncel !== secili) setSecili(guncel)
  }, [biletler, secili])

  // Collecting takes over the whole page: it is a money flow and nothing else
  // on screen should compete with the amount.
  if (secili) {
    return <Tahsilat bilet={secili} onKapat={() => setSecili(null)} />
  }

  // So does entry — a plate being typed at a barrier deserves the whole
  // screen, and the keyboard will cover half of it anyway.
  if (girisAcik) {
    return (
      <div className="flex min-h-dvh flex-col md:min-h-0">
        <ScreenHeader
          title="Araç Girişi"
          back="/gise"
          right={ozet ? <DolulukRozeti dolu={ozet.doluluk} kapasite={ozet.kapasite} /> : null}
        />
        <div className="mb-4 px-5">
          <VardiyaUyarisi />
        </div>
        <GirisBolumu autoFocus />
      </div>
    )
  }

  return (
    <div className="flex min-h-dvh flex-col md:min-h-0">
      <ScreenHeader
        title="Gişe"
        right={ozet ? <DolulukRozeti dolu={ozet.doluluk} kapasite={ozet.kapasite} /> : null}
      />

      <div className="space-y-4 px-5">
        <VardiyaUyarisi />
        {ozet && (
          <BrandPanel>
            <div className="flex items-end justify-between gap-3">
              <div>
                <p className="text-label font-medium tracking-wide text-on-brand-soft uppercase">
                  Doluluk
                </p>
                {/* The car sits at the tinted rung, not full white: it labels
                    the number rather than competing with it, which is the one
                    thing on this screen allowed to be the loudest. The count
                    and its capacity stay in their own span so the flex gap
                    spaces the ICON only and "1 / 100" keeps its tight kerning. */}
                <p className="mt-1 flex items-center gap-2.5 text-hero font-semibold tnum">
                  <IconAraba size={30} className="shrink-0 text-on-brand-soft" />
                  <span>
                    {ozet.doluluk}
                    <span className="ml-1 text-title font-medium text-on-brand-soft">
                      / {ozet.kapasite}
                    </span>
                  </span>
                </p>
              </div>
              <p className="pb-1.5 text-title font-semibold tnum">
                %{dolulukYuzde(ozet.doluluk, ozet.kapasite)}
              </p>
            </div>

            <div className="mt-3">
              <OranCubugu yuzde={dolulukYuzde(ozet.doluluk, ozet.kapasite)} />
            </div>

            <div className="mt-4 flex items-center gap-6 border-t border-white/15 pt-3.5">
              <div>
                <p className="text-lead font-semibold tnum">
                  {gecmis
                    ? (aralikOzet?.abonman_giris ?? 0) + (aralikOzet?.saatlik_giris ?? 0)
                    : ozet.arac_sayisi}
                </p>
                <p className="text-label text-on-brand-soft">{gecmis ? 'giren' : 'bugün giren'}</p>
              </div>
              <div>
                <p className="text-lead font-semibold tnum">
                  {formatTL(gecmis ? (aralikOzet?.ciro_kurus ?? 0) : ozet.toplam_kurus, {
                    decimals: 0,
                  })}
                </p>
                {/* "onaylı" is not decoration. Today's figure comes from
                    gunluk_ozet, which counts every collection taken at the
                    barrier; a range comes from rapor_ozet, which counts only
                    what the Yönetici has approved. Same slot, two different
                    questions — so the label has to say which one is being
                    answered, or a range would look like money had gone
                    missing. */}
                <p className="text-label text-on-brand-soft">
                  {gecmis ? 'onaylı tahsilat' : 'bugün tahsilat'}
                </p>
              </div>
              <div className="ml-auto">
                <ParkYerleriDugmesi
                  acik={yerlerAcik}
                  onClick={() => setYerlerAcik((v) => !v)}
                  zemin="brand"
                />
              </div>
            </div>
          </BrandPanel>
        )}
        {/* The card waits for gunluk_ozet. Without it the bays would have no
            way in at all, so the same icon stands on its own. */}
        {!ozet && (
          <div className="flex justify-end">
            <ParkYerleriDugmesi
              acik={yerlerAcik}
              onClick={() => setYerlerAcik((v) => !v)}
              zemin="yuzey"
            />
          </div>
        )}

        {yerlerAcik && <ParkYerleriBolumu />}

        {/* The same card it was in the Yönetim menu, moved rather than
            redrawn — literally the same component, so the two cannot drift
            apart. Always present: if it only appeared when the count was
            non-zero, the resolved history would have no way in at all. Warn
            when something needs fixing, neutral when nothing does. */}
        <MenuKart
          satir
          kucuk
          to="/istisnalar"
          tone={acikIstisna > 0 ? 'warn' : 'neutral'}
          icon={<IconKamera size={18} />}
          baslik="Çözülmemiş kayıtlar"
          aciklama={
            acikIstisna > 0
              ? acikIstisna + ' eşleşmeyen giriş/çıkış olayı'
              : 'Eşleşmeyen giriş/çıkış olayı yok'
          }
        />

        {yonetici ? (
          <DonemSecici value={donem} ozel={ozel} onChange={secim} />
        ) : (
          // 067: Personel see exits from today or the last 3 days, no further
          // (RLS) — so two chips and no calendar. The card above stays
          // "bugün", and its labels say so.
          <DonemSecici
            value={donem}
            onChange={secim}
            secenekler={['BUGUN', 'UC_GUN']}
            takvim={false}
          />
        )}

        {girisBasari && (
          <p className="flex items-center gap-2 rounded-card bg-success-soft px-4 py-3 text-body font-medium text-success">
            <IconTik size={18} />
            {girisBasari.plaka} girişi kaydedildi
            {girisBasari.yerKod && (
              <strong className="font-semibold"> · {girisBasari.yerKod}</strong>
            )}
          </p>
        )}

      </div>

      {/* pb clears the floating button, which is 56px tall sitting 84px up.
          Without it the last row — and the lost-ticket link under it — hide
          behind the button on a full lot. */}
      <div className="mt-4 flex flex-1 flex-col pb-24">
        <AracListesi
          sorgu={sorgu}
          setSorgu={setSorgu}
          biletler={biletler}
          isPending={isPending}
          error={error}
          refetch={() => void refetch()}
          onSec={(b) => {
            setCikisAra(null)
            setSecili(b)
          }}
          aramaOdak={cikisAra !== null}
          cikisAralik={cikisAralik}
        />
      </div>

      <GirisFab onClick={() => navigate('/gise/giris')} />
    </div>
  )
}

/**
 * The way into Park yerleri: one icon, in the occupancy card's empty corner
 * (owner, 2026-11-15). It toggles the panel under the card; the pressed look
 * says it is open, so the same tap closes it.
 *
 * `zemin` is what it sits on: the brand gradient, or the page when the card
 * is not there (see the fallback in Gise).
 */
function ParkYerleriDugmesi({
  acik,
  onClick,
  zemin,
}: {
  acik: boolean
  onClick: () => void
  zemin: 'brand' | 'yuzey'
}) {
  const renk =
    zemin === 'brand'
      ? acik
        ? 'bg-white/30 text-on-brand'
        : 'bg-white/15 text-on-brand active:bg-white/25'
      : acik
        ? 'bg-accent text-accent-ink'
        : 'bg-accent-soft text-accent active:brightness-[0.97]'
  return (
    <button
      type="button"
      onClick={onClick}
      aria-expanded={acik}
      aria-label="Park yerleri"
      title="Park yerleri"
      className={`flex size-11 shrink-0 items-center justify-center rounded-field transition-colors ${renk}`}
    >
      <IconYer size={22} />
    </button>
  )
}

/**
 * Park yerleri, under the occupancy card while its icon is pressed.
 *
 * Closed means NOT MOUNTED, not hidden: an unopened section should cost
 * neither the lazy chunk nor its three queries.
 */
function ParkYerleriBolumu() {
  return (
    <section className="overflow-hidden rounded-card border border-border bg-surface px-4 pt-4 pb-5 shadow-card">
      <Suspense fallback={<p className="py-6 text-center text-body text-faint">Yükleniyor…</p>}>
        <YerlerBolumu />
      </Suspense>
    </section>
  )
}

/**
 * The floating entry button.
 *
 * Labelled, not a bare "+": an operator at a barrier should not have to
 * remember what the plus does, and there is room for one word.
 *
 * It clears the bottom nav (~72px) plus the home indicator, and drops to a
 * normal margin from `md` up where the nav moves to the top of the screen.
 */
function GirisFab({ onClick }: { onClick: () => void }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={[
        'fixed right-5 bottom-[calc(84px+env(safe-area-inset-bottom))] z-30 md:bottom-8',
        'flex min-h-[56px] items-center gap-2 rounded-chip px-5',
        'bg-accent text-lead font-semibold text-accent-ink shadow-raised',
        'transition-transform duration-100 active:scale-[0.97]',
      ].join(' ')}
    >
      <IconArti size={22} />
      Giriş
    </button>
  )
}
