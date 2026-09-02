import { useCallback, useState, type ReactNode } from 'react'
import { Link } from 'react-router'
import { IconTile, Input } from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { IconTakvim } from '../../components/ui/icons'
import { formatTarihKisa, gunEkle, istanbulGun } from '../../lib/dates'

/* ------------------------------------------------------------- MenuKart */

/**
 * One tile in a menu.
 *
 * Two shapes, because the same card is used at two widths. Stacked (the
 * default) suits a narrow tile in a multi-column grid, where an icon beside
 * two lines of text would wrap the description. `satir` puts the icon beside
 * the text for a full-width row, where stacking makes a 136px-tall card out of
 * 860px of width and five of them turn a five-item menu into a scroll.
 *
 * Either way the tile colour groups the destinations — money, operations,
 * administration — so the eye can skip a whole category instead of reading
 * every label.
 */
export function MenuKart({
  to,
  icon,
  baslik,
  aciklama,
  tone = 'neutral',
  satir = false,
  kucuk = false,
}: {
  to: string
  icon: ReactNode
  baslik: string
  aciklama: string
  tone?: 'accent' | 'success' | 'warn' | 'danger' | 'neutral' | 'mor'
  /** Icon beside the text instead of above it, at every width. */
  satir?: boolean
  /** A tighter row, for a card that sits among content rather than in a menu. */
  kucuk?: boolean
}) {
  return (
    <Link
      to={to}
      className={[
        'flex rounded-card border border-border bg-surface shadow-card',
        'transition-[filter,transform] duration-100 active:scale-[0.99] active:brightness-[0.97]',
        kucuk ? 'p-3' : 'p-4',
        satir ? 'items-center' : 'flex-col gap-3',
        satir ? (kucuk ? 'gap-3' : 'gap-4') : '',
      ].join(' ')}
    >
      <IconTile tone={tone} size={kucuk ? 'sm' : 'lg'}>
        {icon}
      </IconTile>
      <span className="min-w-0">
        <span className="block text-body font-semibold text-ink">{baslik}</span>
        <span className="mt-0.5 block text-label text-faint">{aciklama}</span>
      </span>
    </Link>
  )
}

/* ---------------------------------------------------------- DonemSecici */

export type Donem = 'TUMU' | 'BUGUN' | 'HAFTA' | 'AY' | 'OZEL'

/** An inclusive Istanbul date range, both ends 'YYYY-MM-DD'. */
export interface DonemAralik {
  bas: string
  bit: string
}

// TUMU first: it is the default a finance screen opens on, and the chip row
// reads left-to-right from "everything" down to "today". OZEL is not in this
// table — its chip is labelled with the dates the user picked.
export const DONEM_ETIKET: Record<Exclude<Donem, 'OZEL'>, string> = {
  TUMU: 'Tümü',
  BUGUN: 'Bugün',
  HAFTA: '7 gün',
  AY: '30 gün',
}

/**
 * Inclusive Istanbul date range for a period, as 'YYYY-MM-DD'.
 *
 * `ilkGun` is only consulted for TUMU and comes from `useIlkGun()` — the date
 * of the earliest ticket or kasa row. Callers that have not loaded it yet get
 * today, so this stays a pure function; `useDonemAralik` carries the `hazir`
 * flag that stops a screen rendering that placeholder range as if it were the
 * answer.
 *
 * OZEL falls back to today when no range has been chosen. That state is not
 * reachable through the UI — the chip only becomes OZEL once a range is
 * confirmed — but a pure function must answer for every input it accepts.
 */
export function donemAralik(d: Donem, ilkGun?: string, ozel?: DonemAralik | null): DonemAralik {
  const bugun = istanbulGun()
  if (d === 'OZEL') return ozel ?? { bas: bugun, bit: bugun }
  if (d === 'TUMU') return { bas: ilkGun ?? bugun, bit: bugun }
  if (d === 'BUGUN') return { bas: bugun, bit: bugun }
  return { bas: gunEkle(d === 'HAFTA' ? -6 : -29), bit: bugun }
}

/**
 * The period a screen is looking at, including a custom range.
 *
 * Lives here rather than in each screen because three screens carry the same
 * pair of states and the same rule about how they move together: picking a
 * preset must NOT clear the custom range, so switching to Bugün and back to
 * the chip returns to the dates already chosen instead of an empty modal.
 */
export function useDonem(baslangic: Donem = 'TUMU') {
  const [donem, setDonem] = useState<Donem>(baslangic)
  const [ozel, setOzel] = useState<DonemAralik | null>(null)

  const secim = useCallback((d: Donem, aralik?: DonemAralik) => {
    if (aralik) setOzel(aralik)
    setDonem(d)
  }, [])

  return { donem, ozel, secim }
}

/**
 * Period chips, plus a calendar chip for an arbitrary range.
 *
 * The calendar sits apart from the four presets on purpose: those are one tap
 * each, this one opens a dialog, and a control that behaves differently should
 * not be dressed as its neighbours. It keeps its own width instead of taking a
 * fifth of the row — five equal chips at 375px leave 60px each, which "30 gün"
 * alone does not fit.
 */
export function DonemSecici({
  value,
  ozel,
  onChange,
}: {
  value: Donem
  ozel?: DonemAralik | null
  onChange: (d: Donem, aralik?: DonemAralik) => void
}) {
  const [acik, setAcik] = useState(false)
  const [bas, setBas] = useState('')
  const [bit, setBit] = useState('')
  const [hata, setHata] = useState<string | null>(null)

  const ozelAktif = value === 'OZEL' && ozel != null

  function ac() {
    // Re-opens on the range already chosen, or on today when there is none —
    // never on two empty fields the user has to fill from scratch.
    const bugun = istanbulGun()
    setBas(ozel?.bas ?? bugun)
    setBit(ozel?.bit ?? bugun)
    setHata(null)
    setAcik(true)
  }

  function uygula() {
    if (!bas || !bit) {
      setHata('İki tarihi de seçin.')
      return
    }
    if (bas > bit) {
      // Refused rather than silently swapped: a reversed range is as likely to
      // be a mis-tap in one field as an intent to invert, and quietly showing
      // a different period than the one on screen is worse than a message.
      setHata('Başlangıç, bitişten sonra olamaz.')
      return
    }
    onChange('OZEL', { bas, bit })
    setAcik(false)
  }

  return (
    <>
      {/* Two rows on a phone, one from md. Five controls do not fit across
          375px: the four presets alone need ~338px of content, so adding the
          calendar to the same line either wraps it raggedly (three chips, then
          two) or shrinks "30 gün" until it clips. Giving the calendar its own
          line keeps the presets exactly as they were and puts the odd control
          out where it reads as one. */}
      <div
        className="flex flex-col gap-2 md:flex-row md:items-center"
        role="tablist"
        aria-label="Dönem"
      >
        <div className="flex gap-2">
          {(Object.keys(DONEM_ETIKET) as Exclude<Donem, 'OZEL'>[]).map((d) => {
            const active = d === value
            return (
              <button
                key={d}
                type="button"
                role="tab"
                aria-selected={active}
                onClick={() => onChange(d)}
                className={[
                  // flex-1 on a phone so the chips fill the width and stay
                  // thumb-sized; content-width from md up, where stretching them
                  // across a 700px column turns a filter into big buttons.
                  'min-h-[44px] flex-1 rounded-chip px-3 text-body font-medium transition-colors',
                  'md:flex-none md:px-5',
                  active ? 'bg-ink text-bg' : 'bg-field text-soft',
                ].join(' ')}
              >
                {DONEM_ETIKET[d]}
              </button>
            )
          })}
        </div>

        <button
          type="button"
          role="tab"
          aria-selected={ozelAktif}
          aria-label="Tarih aralığı seç"
          onClick={ac}
          className={[
            'flex min-h-[44px] shrink-0 items-center gap-2 self-start rounded-chip px-3',
            'text-body font-medium transition-colors md:self-auto md:px-4',
            ozelAktif ? 'bg-ink text-bg' : 'bg-field text-soft',
          ].join(' ')}
        >
          <IconTakvim size={18} />
          {ozelAktif && (
            <span className="tnum">
              {formatTarihKisa(ozel.bas)} – {formatTarihKisa(ozel.bit)}
            </span>
          )}
        </button>
      </div>

      <FormModal
        open={acik}
        onOpenChange={setAcik}
        title="Tarih aralığı"
        submitLabel="Uygula"
        error={hata}
        onSubmit={uygula}
      >
        {/* Native date inputs: the platform's own picker is the one the
            operator already knows, it is localised for free, and it cannot
            produce a malformed date the way a typed field can. */}
        <Input
          label="Başlangıç"
          type="date"
          value={bas}
          max={bit || undefined}
          onChange={(e) => {
            setBas(e.target.value)
            setHata(null)
          }}
        />
        <Input
          label="Bitiş"
          type="date"
          value={bit}
          min={bas || undefined}
          onChange={(e) => {
            setBit(e.target.value)
            setHata(null)
          }}
        />
      </FormModal>
    </>
  )
}

/* ----------------------------------------------------------- IstatKutu */

/**
 * A number with its caption underneath. The figure is at full contrast, the
 * caption is not — the eye lands on the value, the word only explains it.
 */
export function IstatKutu({
  deger,
  etiket,
  tone = 'default',
}: {
  deger: string
  etiket: string
  tone?: 'default' | 'success' | 'danger'
}) {
  const tones = {
    default: 'text-ink',
    success: 'text-success',
    danger: 'text-danger',
  }
  return (
    <div>
      <p className={`text-title font-semibold tnum ${tones[tone]}`}>{deger}</p>
      <p className="mt-0.5 text-label text-faint">{etiket}</p>
    </div>
  )
}

/* Charts live in ./charts.tsx — this file is layout components only. */
