/**
 * Icon set. Every icon uses `currentColor` for stroke and fill — never a
 * hardcoded hex. That is the whole reason dark mode here is a token
 * re-declaration instead of a pile of `svg[stroke='#111']` override
 * selectors: an icon simply inherits whatever text colour it sits in.
 */
import type { SVGProps } from 'react'

type IconProps = SVGProps<SVGSVGElement> & { size?: number }

function Icon({ size = 24, children, ...rest }: IconProps) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={1.8}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      {...rest}
    >
      {children}
    </svg>
  )
}

export const IconGiris = (p: IconProps) => (
  <Icon {...p}>
    <path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4" />
    <path d="M10 17l5-5-5-5" />
    <path d="M15 12H3" />
  </Icon>
)

export const IconCikis = (p: IconProps) => (
  <Icon {...p}>
    <path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4" />
    <path d="M16 17l5-5-5-5" />
    <path d="M21 12H9" />
  </Icon>
)

export const IconAra = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="11" cy="11" r="7" />
    <path d="m20 20-3.2-3.2" />
  </Icon>
)

export const IconAraba = (p: IconProps) => (
  <Icon {...p}>
    <path d="M5 17h14M6.5 17v1.5a1 1 0 0 1-1 1h-1a1 1 0 0 1-1-1V17M20.5 17v1.5a1 1 0 0 1-1 1h-1a1 1 0 0 1-1-1V17" />
    <path d="M3 17v-3.6a2 2 0 0 1 .3-1L5.6 8A2 2 0 0 1 7.3 7h9.4a2 2 0 0 1 1.7 1l2.3 4.4a2 2 0 0 1 .3 1V17" />
    <circle cx="7.5" cy="14" r="1" />
    <circle cx="16.5" cy="14" r="1" />
  </Icon>
)

export const IconKamera = (p: IconProps) => (
  <Icon {...p}>
    <path d="M3 8.5A2 2 0 0 1 5 6.5h1.6a1 1 0 0 0 .8-.4l1-1.3a1 1 0 0 1 .8-.4h4.6a1 1 0 0 1 .8.4l1 1.3a1 1 0 0 0 .8.4H19a2 2 0 0 1 2 2V17a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z" />
    <circle cx="12" cy="12.5" r="3.2" />
  </Icon>
)

export const IconPanel = (p: IconProps) => (
  <Icon {...p}>
    <rect x="3" y="3" width="7.5" height="8.5" rx="1.6" />
    <rect x="13.5" y="3" width="7.5" height="5" rx="1.6" />
    <rect x="3" y="14.5" width="7.5" height="6.5" rx="1.6" />
    <rect x="13.5" y="11" width="7.5" height="10" rx="1.6" />
  </Icon>
)

export const IconVardiya = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="8.5" />
    <path d="M12 7v5.2l3.2 1.9" />
  </Icon>
)

export const IconAbonman = (p: IconProps) => (
  <Icon {...p}>
    <rect x="2.5" y="5" width="19" height="14" rx="2.4" />
    <path d="M2.5 10h19" />
    <path d="M6.5 14.5h4" />
  </Icon>
)

export const IconPuan = (p: IconProps) => (
  <Icon {...p}>
    <path d="m12 3.5 2.6 5.3 5.9.9-4.2 4.1 1 5.8-5.3-2.8-5.3 2.8 1-5.8L3.5 9.7l5.9-.9Z" />
  </Icon>
)

/**
 * The cash box — the kasa ledger, NOT the loyalty points above it.
 *
 * A strongbox rather than a banknote: notes would collide with the payment
 * method chips, which already speak in cash/card/transfer. Kept to five
 * strokes because this renders at 20px on the Finans card as well as at 44px
 * in an empty state, and a dial with tick marks turns to mush at the small
 * size.
 */
/** A note written on the ticket — a sheet with two lines, not a bubble. */
export const IconNot = (p: IconProps) => (
  <Icon {...p}>
    <path d="M5.5 3.5h9.5l4 4v13a1 1 0 0 1-1 1H5.5a1 1 0 0 1-1-1v-16a1 1 0 0 1 1-1Z" />
    <path d="M14.5 3.6V7.5h4" />
    <path d="M8 13h8M8 16.5h5" />
  </Icon>
)

export const IconKasa = (p: IconProps) => (
  <Icon {...p}>
    <rect x="3" y="4.5" width="18" height="15" rx="2.5" />
    <circle cx="10" cy="12" r="2.6" />
    <path d="M16 10v4" />
    <path d="M6.5 19.5V21" />
    <path d="M17.5 19.5V21" />
  </Icon>
)

export const IconAyar = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="3" />
    <path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1A1.6 1.6 0 0 0 9 19.4a1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1A1.6 1.6 0 0 0 4.6 9a1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1Z" />
  </Icon>
)

export const IconZil = (p: IconProps) => (
  <Icon {...p}>
    <path d="M18 8.5a6 6 0 1 0-12 0c0 6-2.5 7.5-2.5 7.5h17S18 14.5 18 8.5" />
    <path d="M13.7 19.5a2 2 0 0 1-3.4 0" />
  </Icon>
)

export const IconGeri = (p: IconProps) => (
  <Icon {...p}>
    <path d="m14.5 5-7 7 7 7" />
  </Icon>
)

/** Price tag — tariffs. */
export const IconEtiket = (p: IconProps) => (
  <Icon {...p}>
    <path d="M20.5 12.7 12.8 20.4a2 2 0 0 1-2.8 0l-6.4-6.4a2 2 0 0 1-.6-1.4V4.9a2 2 0 0 1 2-2h7.7a2 2 0 0 1 1.4.6l6.4 6.4a2 2 0 0 1 0 2.8Z" />
    <circle cx="8.2" cy="8.2" r="1.4" />
  </Icon>
)

/** Trailing chevron on a tappable row — the affordance that says "this opens". */
export const IconIleri = (p: IconProps) => (
  <Icon {...p}>
    <path d="m9.5 5 7 7-7 7" />
  </Icon>
)

export const IconArti = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 5v14M5 12h14" />
  </Icon>
)

export const IconCarpi = (p: IconProps) => (
  <Icon {...p}>
    <path d="M6 6l12 12M18 6 6 18" />
  </Icon>
)

export const IconTik = (p: IconProps) => (
  <Icon {...p}>
    <path d="m4.5 12.5 5 5 10-11" />
  </Icon>
)

/** A tick INSIDE a circle — approval, as distinct from IconTik's bare
 *  "done". The two appear on the same screen, so they must not be the same
 *  mark. */
export const IconOnay = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="9" />
    <path d="m8.25 12.25 2.5 2.5 5-5.5" />
  </Icon>
)

export const IconTakvim = (p: IconProps) => (
  <Icon {...p}>
    <rect x="3.5" y="5" width="17" height="15" rx="2.5" />
    <path d="M3.5 9.5h17M8 3.5v3M16 3.5v3" />
  </Icon>
)

export const IconUyari = (p: IconProps) => (
  <Icon {...p}>
    <path d="M10.3 3.9 2.4 17.2A2 2 0 0 0 4.1 20h15.8a2 2 0 0 0 1.7-2.8L13.7 3.9a2 2 0 0 0-3.4 0Z" />
    <path d="M12 9v4.5" />
    <circle cx="12" cy="16.8" r="0.9" fill="currentColor" stroke="none" />
  </Icon>
)

export const IconCop = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4 7h16M9.5 7V5.2a1.2 1.2 0 0 1 1.2-1.2h2.6a1.2 1.2 0 0 1 1.2 1.2V7" />
    <path d="M6.5 7v11.8A1.2 1.2 0 0 0 7.7 20h8.6a1.2 1.2 0 0 0 1.2-1.2V7" />
    <path d="M10 11v5M14 11v5" />
  </Icon>
)

export const IconKisi = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="8" r="4" />
    <path d="M4.5 20a7.5 7.5 0 0 1 15 0" />
  </Icon>
)

export const IconYer = (p: IconProps) => (
  <Icon {...p}>
    <path d="M12 21s7-5.7 7-11a7 7 0 1 0-14 0c0 5.3 7 11 7 11Z" />
    <circle cx="12" cy="10" r="2.6" />
  </Icon>
)

export const IconRapor = (p: IconProps) => (
  <Icon {...p}>
    <path d="M4 20V9M10 20V4M16 20v-7M22 20H2" />
  </Icon>
)

export const IconAy = (p: IconProps) => (
  <Icon {...p}>
    <path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5Z" />
  </Icon>
)

export const IconGunes = (p: IconProps) => (
  <Icon {...p}>
    <circle cx="12" cy="12" r="4" />
    <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
  </Icon>
)
