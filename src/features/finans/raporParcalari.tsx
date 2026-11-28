import type { ReactNode } from 'react'
import { IconIleri } from '../../components/ui/icons'
import { formatTL } from '../../lib/money'
import { formatSaat } from '../../lib/dates'
import { formatPlaka } from '../../lib/plaka'
import { ODEME_CHIP, ODEME_ETIKET } from '../../lib/types'
import { islemEtiketi, type Karsilastirma } from './vardiyaEtiket'
import type { VardiyaRaporuBilet, VardiyaRaporuIslem } from './api'

/**
 * The pieces the shift report (086) and the day report (087) share: summary
 * rows, chips, the comparison chip and the two sheet lists. One look for
 * both, owner 28.11 ("like Rocket Money").
 */

export const kisaTL = (kurus: number) => formatTL(kurus, { decimals: 0 })

/**
 * Icon-tile colours of the report rows (owner 28.11: "give icons colour to
 * better differentiate them"). One map, so a row has the same colour in the
 * shift report and the day report.
 */
export const SATIR_RENK = {
  kasa: 'bg-nakit-soft text-nakit',
  giren: 'bg-accent-soft text-accent',
  cikan: 'bg-kart-soft text-kart',
  dikkat: 'bg-warn-soft text-warn',
  iceride: 'bg-havale-soft text-havale',
  onay: 'bg-mor-soft text-mor',
} as const

/** One summary row: icon, label, value, and an arrow when it opens something. */
export function Satir({
  ikon,
  etiket,
  deger,
  onClick,
  renk = 'bg-field text-soft',
}: {
  ikon: ReactNode
  etiket: ReactNode
  deger: ReactNode
  onClick?: () => void
  /** The icon tile's colours — one of SATIR_RENK. */
  renk?: string
}) {
  const ic = (
    <>
      <span className={`flex size-9 shrink-0 items-center justify-center rounded-field ${renk}`}>
        {ikon}
      </span>
      <span className="min-w-0 flex-1 truncate text-body text-ink">{etiket}</span>
      {deger}
      {onClick ? (
        <IconIleri size={17} className="shrink-0 text-faint" />
      ) : (
        <span className="w-[17px] shrink-0" aria-hidden="true" />
      )}
    </>
  )
  return onClick ? (
    <button
      type="button"
      onClick={onClick}
      className="flex min-h-[56px] w-full items-center gap-3 px-4 text-left active:bg-field"
    >
      {ic}
    </button>
  ) : (
    <div className="flex min-h-[56px] items-center gap-3 px-4">{ic}</div>
  )
}

export function Deger({ children }: { children: ReactNode }) {
  return <span className="shrink-0 text-body font-semibold text-ink tnum">{children}</span>
}

export function Chip({ sinif, children }: { sinif: string; children: ReactNode }) {
  return (
    <span className={`shrink-0 rounded-chip px-2.5 py-1 text-label font-medium tnum ${sinif}`}>
      {children}
    </span>
  )
}

export function Kalem({ k, v, ton = 'text-ink' }: { k: string; v: string; ton?: string }) {
  return (
    <div className="flex min-h-[44px] items-center justify-between gap-3">
      <span className="text-body text-soft">{k}</span>
      <span className={`text-body font-semibold tnum ${ton}`}>{v}</span>
    </div>
  )
}

/** "▲ %13 önceki gündüzden" — green up, red down, grey flat. */
export function KarsilastirmaChip({
  kars,
  metin,
  className = '',
}: {
  kars: Karsilastirma
  metin: string
  className?: string
}) {
  return (
    <span
      className={[
        'inline-block rounded-chip px-2.5 py-1 text-label font-medium tnum',
        kars.yon === 'yukari'
          ? 'bg-success-soft text-success'
          : kars.yon === 'asagi'
            ? 'bg-danger-soft text-danger'
            : 'bg-field text-soft',
        className,
      ].join(' ')}
    >
      {kars.yon === 'yukari' ? '▲ ' : kars.yon === 'asagi' ? '▼ ' : ''}%{kars.yuzde} {metin}
    </span>
  )
}

/** The "Çıkan araçlar" sheet body: plate, times, amount and how it was paid. */
export function AraclarListesi({
  biletler,
  onAc,
}: {
  biletler: VardiyaRaporuBilet[]
  onAc: (id: string) => void
}) {
  return (
    <div className="divide-y divide-divider">
      {biletler.map((b) => (
        <button
          key={b.id}
          type="button"
          onClick={() => onAc(b.id)}
          className="flex min-h-[56px] w-full items-center gap-3 py-2.5 text-left"
        >
          <div className="min-w-0 flex-1">
            <p className="truncate text-body font-semibold text-ink tnum">{formatPlaka(b.plaka)}</p>
            <p className="mt-0.5 text-label text-faint tnum">
              {formatSaat(b.giris_at)} → {b.cikis_at ? formatSaat(b.cikis_at) : '—'}
            </p>
          </div>
          <div className="shrink-0 text-right">
            <p className="text-body font-medium text-ink tnum">{kisaTL(b.tahsil_kurus)}</p>
            {b.odeme_yontemi ? (
              <span
                className={`mt-0.5 inline-block rounded-chip px-2 py-0.5 text-micro font-medium ${ODEME_CHIP[b.odeme_yontemi]}`}
              >
                {ODEME_ETIKET[b.odeme_yontemi]}
              </span>
            ) : (
              <p className="mt-0.5 text-micro text-faint">{b.ucretsiz_sebep ? 'Ücretsiz' : 'Ödenmedi'}</p>
            )}
          </div>
        </button>
      ))}
    </div>
  )
}

/** The "Dikkat" sheet body: what happened, on which plate, when and by whom. */
export function IslemlerListesi({
  islemler,
  ad,
}: {
  islemler: VardiyaRaporuIslem[]
  ad: (id: string | null) => string
}) {
  return (
    <div className="divide-y divide-divider">
      {islemler.map((i, n) => (
        <div key={n} className="py-3">
          <p className="text-body text-ink">
            {islemEtiketi(i.action)}
            {i.plaka && <span className="ml-2 font-semibold tnum">{formatPlaka(i.plaka)}</span>}
          </p>
          <p className="mt-0.5 text-label text-faint">
            <span className="tnum">{formatSaat(i.created_at)}</span> · {ad(i.actor)}
          </p>
        </div>
      ))}
    </div>
  )
}
