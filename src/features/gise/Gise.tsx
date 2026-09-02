import { Suspense, lazy, useEffect, useState } from 'react'
import { useLocation, useNavigate } from 'react-router'
import { BrandPanel, OranCubugu, ScreenHeader } from '../../components/ui/primitives'
import { DolulukRozeti, dolulukYuzde } from './components'
import { GirisBolumu } from './Giris'
import { AracListesi, Tahsilat } from './Cikis'
import { useAcikBiletler, useGunlukOzet } from './api'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'
import { DonemSecici, MenuKart, useDonem } from '../yonetim/components'
import { useDonemAralik, useRaporOzet } from '../finans/api'
import { useAcikIstisnaSayisi } from '../istisna/api'
import { formatTL } from '../../lib/money'
import {
  IconAraba,
  IconArti,
  IconIleri,
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

  const [sorgu, setSorgu] = useState('')
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
  const { data: aralikOzet } = useRaporOzet(bas, bit, gecmis && hazir)
  const { data: acikIstisna = 0 } = useAcikIstisnaSayisi()

  const kapidakiler = biletler.filter((b) => b.cikis_bekliyor_at).length

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

            <div className="mt-4 flex gap-6 border-t border-white/15 pt-3.5">
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
            </div>
          </BrandPanel>
        )}

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

        <ParkYerleriBolumu />

        {yonetici && <DonemSecici value={donem} ozel={ozel} onChange={secim} />}

        {girisBasari && (
          <p className="flex items-center gap-2 rounded-card bg-success-soft px-4 py-3 text-body font-medium text-success">
            <IconTik size={18} />
            {girisBasari.plaka} girişi kaydedildi
            {girisBasari.yerKod && (
              <strong className="font-semibold"> · {girisBasari.yerKod}</strong>
            )}
          </p>
        )}

        {kapidakiler > 0 && (
          <p className="rounded-card bg-accent-soft px-4 py-3 text-body text-accent">
            {kapidakiler} araç çıkış kapısında bekliyor.
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
          onSec={setSecili}
        />
      </div>

      <GirisFab onClick={() => navigate('/gise/giris')} />
    </div>
  )
}

/**
 * Park yerleri, inline and collapsed by default.
 *
 * It sits with the other summary rows, under the occupancy panel — the same
 * place the link to it occupied — and expands in place rather than
 * navigating. Collapsed it costs one row, which is why the vehicle list
 * keeps its position on the screen an operator sees all day.
 *
 * Collapsed means NOT MOUNTED, not hidden: an unopened section should cost
 * neither the lazy chunk nor its three queries.
 */
function ParkYerleriBolumu() {
  const [acik, setAcik] = useState(false)

  return (
    // ONE surface, header and body together. The card styling lives out here
    // rather than on the button, so opening the section grows the same white
    // panel instead of dropping a second, unattached block onto the page
    // background — which read as a separate screen rather than as more of
    // this one.
    <section className="overflow-hidden rounded-card border border-border bg-surface shadow-card">
      <button
        type="button"
        onClick={() => setAcik((v) => !v)}
        aria-expanded={acik}
        className="flex w-full items-center gap-3 px-4 py-3 text-left transition-[filter] active:brightness-[0.97]"
      >
        <span className="flex size-10 shrink-0 items-center justify-center rounded-field bg-accent-soft text-accent">
          <IconYer size={20} />
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-body font-medium text-ink">Park yerleri</span>
          <span className="block text-label text-faint">Yerler ve rezervasyonlar</span>
        </span>
        {/* Closed points DOWN, at the content it will reveal; open points UP,
            at the action it now offers. IconIleri is a right-pointing chevron,
            so both states are rotations of it — and neither state is the
            unrotated one, which is why it is easy to get wrong. */}
        <IconIleri
          size={18}
          className={`shrink-0 text-faint transition-transform duration-150 ${
            acik ? '-rotate-90' : 'rotate-90'
          }`}
        />
      </button>

      {acik && (
        // A hairline, not a gap: the divider says "same panel, next part",
        // where whitespace alone would let the two halves drift apart again.
        <div className="border-t border-divider px-4 pt-4 pb-5">
          <Suspense
            fallback={<p className="py-6 text-center text-body text-faint">Yükleniyor…</p>}
          >
            <YerlerBolumu />
          </Suspense>
        </div>
      )}
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
