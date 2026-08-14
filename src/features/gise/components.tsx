import { Label } from '../../components/ui/primitives'
import { formatPlaka } from '../../lib/plaka'
import { formatGoreceli } from '../../lib/dates'
import { sureMetni } from '../../lib/sure'
import { ARAC_TIPI_ETIKET, type AcikBilet, type AracTipi } from '../../lib/types'
import { IconAraba, IconKamera, IconUyari } from '../../components/ui/icons'

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
                'min-h-[56px] rounded-field px-3 text-body font-medium transition-colors',
                active ? 'bg-accent text-accent-ink' : 'bg-field text-soft',
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
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex w-full items-center gap-3 rounded-card bg-surface p-4 text-left active:brightness-[0.97]"
    >
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
        <p className="mt-1 truncate text-label text-faint">
          {formatGoreceli(bilet.giris_at)} · {ARAC_TIPI_ETIKET[bilet.arac_tipi]}
          {bilet.gecikmeli_kayit && ' · kameradan'}
        </p>
      </div>

      {/* The one number worth reading at arm's length in this row. */}
      <span className="shrink-0 text-body font-medium text-soft tnum">
        {sureMetni(bilet.giris_at)}
      </span>
    </button>
  )
}

/** Occupancy, sized to sit quietly in a header. Amber past 90%. */
export function DolulukRozeti({ dolu, kapasite }: { dolu: number; kapasite: number }) {
  const yuzde = kapasite > 0 ? Math.round((dolu / kapasite) * 100) : 0
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
