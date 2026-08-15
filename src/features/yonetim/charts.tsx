import type { ReactNode } from 'react'

/**
 * The chart vocabulary. Hand-rolled SVG and divs, deliberately: a charting
 * library would be a whole dependency tree in the supply chain (A03) for
 * shapes that are a few dozen lines, and it would arrive with its own colour
 * system to fight with the tokens.
 *
 * Two rules every chart here follows:
 *
 * 1. **Colour comes from `currentColor`, never a `var(--color-…)` written into
 *    an SVG attribute.** Tailwind v4 only emits a theme variable to `:root`
 *    when some utility references it, so `stroke="var(--color-nakit)"` can
 *    resolve to nothing the day the last `text-nakit` usage is deleted — and
 *    it would fail silently, as an invisible slice. Setting `text-nakit` on
 *    the element and stroking `currentColor` keeps the utility as the single
 *    source and flips correctly in dark mode.
 *
 * 2. **A chart with no data says so.** Rendering empty axes reads as a broken
 *    screen; "Bu dönemde veri yok" reads as an answer.
 */

/* ------------------------------------------------------------- GrafikBos */

function GrafikBos({ mesaj = 'Bu dönemde veri yok' }: { mesaj?: string }) {
  return (
    <div className="flex h-32 items-center justify-center rounded-field bg-field">
      <p className="text-label text-faint">{mesaj}</p>
    </div>
  )
}

/* ----------------------------------------------------------- SutunGrafik */

/**
 * Daily revenue bars with an average line.
 *
 * The average is the point of the chart: a bare row of bars tells you the
 * shape of the week, but the dashed line is what turns "Thursday was tall"
 * into "Thursday beat the average", which is the reading someone actually
 * acts on. The tallest bar is emphasised for the same reason.
 */
export function SutunGrafik({
  veri,
  format,
}: {
  veri: { gun: string; kurus: number }[]
  format: (kurus: number) => string
}) {
  if (veri.length === 0) return <GrafikBos />

  const degerler = veri.map((v) => v.kurus)
  const max = Math.max(...degerler)
  const toplam = degerler.reduce((a, b) => a + b, 0)
  const ortalama = toplam / veri.length
  const enYuksek = degerler.indexOf(max)

  // Every bar would be full height against a zero maximum, which reads as a
  // record day rather than an empty one.
  if (max <= 0) return <GrafikBos mesaj="Bu dönemde tahsilat yok" />

  return (
    <div>
      <div className="mb-1 flex items-baseline justify-between">
        <span className="text-micro text-faint tnum">{format(max)}</span>
        <span className="text-micro text-faint">
          ort. <span className="tnum">{format(Math.round(ortalama))}</span>
        </span>
      </div>

      <div className="relative flex h-32 items-end gap-[3px]">
        {/* Average line, drawn behind the bars and kept quiet. */}
        <div
          className="pointer-events-none absolute inset-x-0 border-t border-dashed border-faint/50"
          style={{ bottom: `${(ortalama / max) * 100}%` }}
          aria-hidden="true"
        />
        {veri.map((v, i) => (
          <div
            key={v.gun}
            className="flex flex-1 flex-col justify-end"
            title={`${v.gun}: ${format(v.kurus)}`}
          >
            <div
              className={[
                'w-full rounded-t-[3px]',
                v.kurus <= 0 ? 'bg-border' : i === enYuksek ? 'bg-accent' : 'bg-accent/45',
              ].join(' ')}
              // 2% floor so a small non-zero day is still a visible mark
              // rather than nothing — "we took ₺40" and "we took nothing" are
              // different facts and must not render identically.
              style={{ height: `${Math.max((v.kurus / max) * 100, v.kurus > 0 ? 2 : 1)}%` }}
            />
          </div>
        ))}
      </div>

      <div className="mt-1.5 flex justify-between text-micro text-faint tnum">
        <span>{gunEtiketi(veri[0]!.gun)}</span>
        {veri.length > 2 && <span>{gunEtiketi(veri[veri.length - 1]!.gun)}</span>}
      </div>
    </div>
  )
}

/** 'YYYY-MM-DD' -> 'DD.MM', which is all the axis has room for. */
function gunEtiketi(gun: string): string {
  const [, ay, g] = gun.split('-')
  return g && ay ? `${g}.${ay}` : gun
}

/* ----------------------------------------------------------- HalkaGrafik */

export interface HalkaDilim {
  etiket: string
  deger: number
  /** Tailwind text colour class — the slice strokes `currentColor`. */
  renk: string
  gosterim: string
}

/**
 * Donut with a total in the middle and a legend beneath.
 *
 * A donut is the wrong chart for comparing many similar values, but it is the
 * right one here: three payment methods that are parts of one whole, where the
 * question is "how much of today was cash?" and the exact ranking barely
 * matters. The legend carries the real numbers, so the ring only has to convey
 * proportion.
 */
export function HalkaGrafik({
  dilimler,
  merkez,
  merkezAlt,
}: {
  dilimler: HalkaDilim[]
  merkez: string
  merkezAlt?: string
}) {
  const toplam = dilimler.reduce((a, d) => a + d.deger, 0)
  if (toplam <= 0) return <GrafikBos mesaj="Bu dönemde tahsilat yok" />

  const R = 42
  const C = 2 * Math.PI * R
  let acc = 0

  return (
    <div className="flex items-center gap-5">
      <div className="relative shrink-0">
        <svg width="112" height="112" viewBox="0 0 100 100" aria-hidden="true">
          <circle
            cx="50"
            cy="50"
            r={R}
            fill="none"
            strokeWidth="13"
            className="text-field"
            stroke="currentColor"
          />
          {dilimler.map((d) => {
            if (d.deger <= 0) return null
            const uzunluk = (d.deger / toplam) * C
            const offset = -acc
            acc += uzunluk
            return (
              <circle
                key={d.etiket}
                cx="50"
                cy="50"
                r={R}
                fill="none"
                strokeWidth="13"
                className={d.renk}
                stroke="currentColor"
                strokeDasharray={`${uzunluk} ${C - uzunluk}`}
                strokeDashoffset={offset}
                // Start at twelve o'clock instead of three.
                transform="rotate(-90 50 50)"
              />
            )
          })}
        </svg>
        <div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
          <span className="text-body font-semibold text-ink tnum">{merkez}</span>
          {merkezAlt && <span className="text-micro text-faint">{merkezAlt}</span>}
        </div>
      </div>

      <ul className="min-w-0 flex-1 space-y-2">
        {dilimler.map((d) => (
          <li key={d.etiket} className="flex items-center gap-2.5">
            <span className={`size-2.5 shrink-0 rounded-chip bg-current ${d.renk}`} aria-hidden="true" />
            <span className="min-w-0 flex-1 truncate text-label text-soft">{d.etiket}</span>
            <span className="shrink-0 text-label font-medium text-ink tnum">{d.gosterim}</span>
            <span className="w-9 shrink-0 text-right text-micro text-faint tnum">
              %{Math.round((d.deger / toplam) * 100)}
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}

/* -------------------------------------------------------- SiraliCubuklar */

/**
 * Ranked horizontal bars.
 *
 * Deliberately single-coloured. Four vehicle types in four different colours
 * would invent four new meanings the rest of the app does not have, and the
 * label already says which row is which — colour would be decoration competing
 * with the payment chips, which use colour to mean something.
 */
export function SiraliCubuklar({
  satirlar,
  bos = 'Bu dönemde veri yok',
}: {
  satirlar: { etiket: string; deger: number; gosterim: string }[]
  bos?: string
}) {
  const siralinmis = [...satirlar].sort((a, b) => b.deger - a.deger)
  const max = Math.max(0, ...siralinmis.map((s) => s.deger))
  if (max <= 0) return <GrafikBos mesaj={bos} />

  return (
    <ul className="space-y-2.5">
      {siralinmis.map((s) => (
        <li key={s.etiket}>
          <div className="mb-1 flex items-baseline justify-between gap-2">
            <span className="min-w-0 truncate text-label text-soft">{s.etiket}</span>
            <span className="shrink-0 text-label font-medium text-ink tnum">{s.gosterim}</span>
          </div>
          <div className="h-2 w-full overflow-hidden rounded-chip bg-field">
            <div
              className="h-full rounded-chip bg-accent"
              style={{ width: `${Math.max((s.deger / max) * 100, s.deger > 0 ? 3 : 0)}%` }}
            />
          </div>
        </li>
      ))}
    </ul>
  )
}

/* ------------------------------------------------------------ SaatGrafigi */

/**
 * Entries by hour of day, 00–23.
 *
 * This is the chart that answers a question the numbers alone never do — when
 * to put a second person on the gate. The peak is called out in words above
 * the bars, because reading a peak off 24 thin columns is exactly the work a
 * chart is supposed to save.
 */
export function SaatGrafigi({ saatler }: { saatler: number[] }) {
  const max = Math.max(...saatler)
  if (max <= 0) return <GrafikBos mesaj="Bu dönemde giriş yok" />

  const zirve = saatler.indexOf(max)
  const iki = (n: number) => String(n).padStart(2, '0')

  return (
    <div>
      <p className="mb-2 text-label text-soft">
        En yoğun saat{' '}
        <strong className="font-semibold text-ink tnum">
          {iki(zirve)}.00–{iki((zirve + 1) % 24)}.00
        </strong>{' '}
        <span className="text-faint tnum">({max} giriş)</span>
      </p>

      <div className="flex h-24 items-end gap-[2px]">
        {saatler.map((n, s) => (
          <div
            key={s}
            className="flex flex-1 flex-col justify-end"
            title={`${iki(s)}.00 — ${n} giriş`}
          >
            <div
              className={[
                'w-full rounded-t-[2px]',
                n <= 0 ? 'bg-border' : s === zirve ? 'bg-accent' : 'bg-accent/45',
              ].join(' ')}
              style={{ height: `${Math.max((n / max) * 100, n > 0 ? 4 : 2)}%` }}
            />
          </div>
        ))}
      </div>

      {/* Four anchors only. A label under all 24 columns is unreadable at
          375px and the shape is what is being read, not exact hours. */}
      <div className="mt-1.5 flex justify-between text-micro text-faint tnum">
        <span>00</span>
        <span>06</span>
        <span>12</span>
        <span>18</span>
        <span>23</span>
      </div>
    </div>
  )
}

/* ------------------------------------------------------------- OranSerit */

/**
 * A single stacked strip for a two-or-three-way split, with its legend inline.
 * Cheaper than a donut when the whole point is one ratio (subscriber vs
 * paying), and it survives being 120px wide.
 */
export function OranSerit({
  parcalar,
}: {
  parcalar: { etiket: string; deger: number; renk: string }[]
}) {
  const toplam = parcalar.reduce((a, p) => a + p.deger, 0)
  if (toplam <= 0) return <GrafikBos mesaj="Bu dönemde giriş yok" />

  return (
    <div>
      <div className="flex h-3 w-full overflow-hidden rounded-chip bg-field">
        {parcalar.map((p) =>
          p.deger > 0 ? (
            <div
              key={p.etiket}
              className={`h-full bg-current ${p.renk}`}
              style={{ width: `${(p.deger / toplam) * 100}%` }}
              title={`${p.etiket}: ${p.deger}`}
            />
          ) : null,
        )}
      </div>
      <ul className="mt-3 flex flex-wrap gap-x-5 gap-y-1.5">
        {parcalar.map((p) => (
          <li key={p.etiket} className="flex items-center gap-2">
            <span className={`size-2.5 rounded-chip bg-current ${p.renk}`} aria-hidden="true" />
            <span className="text-label text-soft">{p.etiket}</span>
            <span className="text-label font-medium text-ink tnum">{p.deger}</span>
            <span className="text-micro text-faint tnum">
              %{Math.round((p.deger / toplam) * 100)}
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}

/* -------------------------------------------------------------- Sparkline */

/**
 * A trend with no axes, small enough to sit inside a summary panel. It answers
 * "which way is this going", nothing more — the numbers live next to it.
 *
 * `preserveAspectRatio="none"` lets one path stretch to any width; with only a
 * shape to read and no gradient or round caps, the distortion is invisible.
 */
export function Sparkline({ veri, className = '' }: { veri: number[]; className?: string }) {
  if (veri.length < 2) return null
  const max = Math.max(...veri)
  const min = Math.min(...veri)
  const aralik = max - min || 1
  const W = 100
  const H = 28

  const nokta = (v: number, i: number) => {
    const x = (i / (veri.length - 1)) * W
    const y = H - ((v - min) / aralik) * H
    return `${x.toFixed(2)},${y.toFixed(2)}`
  }
  const cizgi = veri.map(nokta).join(' ')
  const alan = `0,${H} ${cizgi} ${W},${H}`

  return (
    <svg
      viewBox={`0 0 ${W} ${H}`}
      preserveAspectRatio="none"
      className={`h-7 w-full ${className}`}
      aria-hidden="true"
    >
      <polygon points={alan} fill="currentColor" opacity="0.18" />
      <polyline
        points={cizgi}
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinejoin="round"
        strokeLinecap="round"
        vectorEffect="non-scaling-stroke"
      />
    </svg>
  )
}

/* ------------------------------------------------------------ GrafikKart */

/** A titled chart block, so every chart on a screen is framed identically. */
export function GrafikKart({
  baslik,
  aciklama,
  sag,
  children,
}: {
  baslik: string
  aciklama?: string
  sag?: ReactNode
  children: ReactNode
}) {
  return (
    <div className="rounded-card border border-border bg-surface p-4 shadow-card">
      <div className="mb-3 flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h3 className="text-label font-medium tracking-wide text-faint uppercase">{baslik}</h3>
          {aciklama && <p className="mt-0.5 text-label text-faint">{aciklama}</p>}
        </div>
        {sag && <div className="shrink-0">{sag}</div>}
      </div>
      {children}
    </div>
  )
}
