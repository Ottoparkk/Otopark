import type { ReactNode } from 'react'
import { Link } from 'react-router'
import { IconTile } from '../../components/ui/primitives'
import { gunEkle, istanbulGun } from '../../lib/dates'
import { formatTL } from '../../lib/money'

/* ------------------------------------------------------------- MenuKart */

/**
 * One tile in the Yönetim menu.
 *
 * A stack rather than a row, because the menu is a 2-column grid: twelve
 * identical full-width rows of grey text was the single dullest surface in the
 * app, and nothing in it helped you find anything. The tile colour groups the
 * destinations — money, operations, administration — so the eye can skip a
 * whole category instead of reading twelve labels.
 */
export function MenuKart({
  to,
  icon,
  baslik,
  aciklama,
  tone = 'neutral',
}: {
  to: string
  icon: ReactNode
  baslik: string
  aciklama: string
  tone?: 'accent' | 'success' | 'warn' | 'danger' | 'neutral'
}) {
  return (
    <Link
      to={to}
      className="flex flex-col gap-3 rounded-card border border-border bg-surface p-4 shadow-card transition-[filter,transform] duration-100 active:scale-[0.99] active:brightness-[0.97]"
    >
      <IconTile tone={tone} size="lg">
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

export type Donem = 'BUGUN' | 'HAFTA' | 'AY'

export const DONEM_ETIKET: Record<Donem, string> = {
  BUGUN: 'Bugün',
  HAFTA: '7 gün',
  AY: '30 gün',
}

/** Inclusive Istanbul date range for a period, as 'YYYY-MM-DD'. */
export function donemAralik(d: Donem): { bas: string; bit: string } {
  const bugun = istanbulGun()
  if (d === 'BUGUN') return { bas: bugun, bit: bugun }
  return { bas: gunEkle(d === 'HAFTA' ? -6 : -29), bit: bugun }
}

export function DonemSecici({ value, onChange }: { value: Donem; onChange: (d: Donem) => void }) {
  return (
    <div className="flex gap-2" role="tablist" aria-label="Dönem">
      {(Object.keys(DONEM_ETIKET) as Donem[]).map((d) => {
        const active = d === value
        return (
          <button
            key={d}
            type="button"
            role="tab"
            aria-selected={active}
            onClick={() => onChange(d)}
            className={[
              'min-h-[44px] flex-1 rounded-chip px-3 text-body font-medium transition-colors',
              active ? 'bg-ink text-bg' : 'bg-field text-soft',
            ].join(' ')}
          >
            {DONEM_ETIKET[d]}
          </button>
        )
      })}
    </div>
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

/* -------------------------------------------------------------- SutunGrafik */

/**
 * Daily revenue bars. Deliberately plain SVG-free markup: a charting library
 * would be a dependency in the supply chain for something that is a handful
 * of divs, and the whole point of this chart is the SHAPE of the week, not
 * precise readings — the exact figures are one tap away in the table.
 */
export function SutunGrafik({ veri }: { veri: { gun: string; kurus: number }[] }) {
  const max = Math.max(1, ...veri.map((v) => v.kurus))
  return (
    <div>
      <div className="flex h-32 items-end gap-1">
        {veri.map((v) => {
          const oran = v.kurus / max
          return (
            <div key={v.gun} className="flex flex-1 flex-col justify-end" title={`${v.gun}: ${formatTL(v.kurus)}`}>
              <div
                className={`w-full rounded-t-[4px] ${v.kurus > 0 ? 'bg-accent' : 'bg-field'}`}
                style={{ height: `${Math.max(oran * 100, 2)}%` }}
              />
            </div>
          )
        })}
      </div>
      {veri.length > 0 && (
        <div className="mt-1.5 flex justify-between text-micro text-faint tnum">
          <span>{veri[0]?.gun.slice(8)}</span>
          <span>{veri[veri.length - 1]?.gun.slice(8)}</span>
        </div>
      )}
    </div>
  )
}
