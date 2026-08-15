import { IconTile, Label } from '../../components/ui/primitives'
import { formatPlaka } from '../../lib/plaka'
import { formatGoreceli } from '../../lib/dates'
import { sureMetni } from '../../lib/sure'
import { ARAC_TIPI_ETIKET, type AcikBilet, type AracTipi } from '../../lib/types'
import { IconAraba, IconIleri, IconKamera, IconUyari } from '../../components/ui/icons'

const TIPLER: AracTipi[] = ['OTOMOBIL', 'MOTOSIKLET', 'MINIBUS', 'KAMYONET']

/**
 * Vehicle type picker. A 2x2 grid rather than a segmented row: four Turkish
 * labels squeezed into one row on a 375px screen truncate to nonsense, and a
 * 56px-tall target is what a thumb actually hits.
 */
export function AracTipiSecici({
  value,
  onChange,
  label = 'Araç tipi',
}: {
  value: AracTipi
  onChange: (v: AracTipi) => void
  label?: string | null
}) {
  return (
    <div>
      {label && <Label>{label}</Label>}
      <div className="grid grid-cols-2 gap-2" role="radiogroup" aria-label="Araç tipi">
        {TIPLER.map((t) => {
          const active = t === value
          return (
            <button
              key={t}
              type="button"
              role="radio"
              aria-checked={active}
              onClick={() => onChange(t)}
              className={[
                'min-h-[56px] rounded-field border px-3 text-body font-medium',
                'transition-[background-color,color,transform] duration-100 active:scale-[0.98]',
                active
                  ? 'border-accent bg-accent text-accent-ink shadow-raised'
                  : 'border-border bg-field text-soft',
              ].join(' ')}
            >
              {ARAC_TIPI_ETIKET[t]}
            </button>
          )
        })}
      </div>
    </div>
  )
}

/**
 * One row in the open-vehicles list.
 *
 * Hierarchy by de-emphasis: the plate is the only thing at full contrast
 * because it is the only thing an operator scans for. Entry time and duration
 * step down to `text-faint`, and there are no labels on either — a duration
 * looks like a duration.
 */
export function BiletKart({ bilet, onClick }: { bilet: AcikBilet; onClick: () => void }) {
  // The tile colour carries the row's state, so a scanning eye sorts the list
  // before reading a single word. "Kapıda" wins over "Abonman": a car waiting
  // at the barrier is the one that needs attention right now.
  const tone = bilet.cikis_bekliyor_at ? 'accent' : bilet.abonman_id ? 'success' : 'neutral'

  return (
    <button
      type="button"
      onClick={onClick}
      className="flex w-full items-center gap-3.5 rounded-card border border-border bg-surface p-3.5 text-left shadow-card transition-[filter,transform] duration-100 active:scale-[0.99] active:brightness-[0.97]"
    >
      <IconTile tone={tone}>
        <IconAraba size={21} />
      </IconTile>

      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2">
          <span className="truncate text-lead font-semibold tracking-wide text-ink tnum">
            {formatPlaka(bilet.plaka)}
          </span>
          {bilet.abonman_id && (
            <span className="shrink-0 rounded-chip bg-success-soft px-2 py-0.5 text-micro font-medium text-success">
              Abonman
            </span>
          )}
          {bilet.cikis_bekliyor_at && (
            <span className="shrink-0 rounded-chip bg-accent-soft px-2 py-0.5 text-micro font-medium text-accent">
              Kapıda
            </span>
          )}
        </div>
        <p className="mt-0.5 truncate text-label text-faint">
          {formatGoreceli(bilet.giris_at)} · {ARAC_TIPI_ETIKET[bilet.arac_tipi]}
          {bilet.gecikmeli_kayit && ' · kameradan'}
        </p>
      </div>

      {/* The one number worth reading at arm's length in this row. */}
      <span className="shrink-0 text-body font-semibold text-ink tnum">
        {sureMetni(bilet.giris_at)}
      </span>
      <IconIleri size={17} className="-mr-0.5 shrink-0 text-faint" />
    </button>
  )
}

/**
 * Occupancy as a whole percent.
 *
 * One definition, because this number is rendered three ways on two screens —
 * the header badge, the headline figure, and the width of the capacity bar. If
 * the bar were fed the unrounded value and the label the rounded one they
 * could disagree, which is the sort of tiny inconsistency that makes an
 * interface feel untrustworthy on the screen where trust matters most.
 *
 * A zero or missing capacity yields 0 rather than NaN or Infinity.
 */
export function dolulukYuzde(dolu: number, kapasite: number): number {
  if (!kapasite || kapasite <= 0) return 0
  return Math.round((dolu / kapasite) * 100)
}

/** Occupancy, sized to sit quietly in a header. Amber past 90%. */
export function DolulukRozeti({ dolu, kapasite }: { dolu: number; kapasite: number }) {
  const yuzde = dolulukYuzde(dolu, kapasite)
  const dolmak = yuzde >= 90
  return (
    <span
      className={[
        'inline-flex items-center gap-1.5 rounded-chip px-2.5 py-1 text-label font-medium tnum',
        dolmak ? 'bg-warn-soft text-warn' : 'bg-field text-soft',
      ].join(' ')}
      title={`${dolu} / ${kapasite} dolu`}
    >
      {dolmak ? <IconUyari size={14} /> : <IconAraba size={14} />}
      {dolu}/{kapasite}
    </span>
  )
}

/** Small thumbnail strip for a captured-but-not-yet-uploaded photo. */
export function FotoOnizleme({ url, onKaldir }: { url: string; onKaldir: () => void }) {
  return (
    <div className="flex items-center gap-3 rounded-field bg-field p-2.5">
      <img
        src={url}
        alt="Çekilen fotoğraf"
        className="size-14 shrink-0 rounded-[10px] object-cover"
      />
      <span className="flex-1 text-label text-soft">
        <IconKamera size={14} className="mr-1 inline" />
        Fotoğraf eklendi
      </span>
      <button
        type="button"
        onClick={onKaldir}
        className="min-h-[44px] px-3 text-label font-medium text-danger"
      >
        Kaldır
      </button>
    </div>
  )
}
