import { NavLink, Outlet } from 'react-router'
import { useAuth } from './providers/AuthProvider'
import { isYonetici } from '../lib/rbac'
import {
  IconAraba,
  IconKisi,
  IconPanel,
  IconRapor,
  IconVardiya,
  IconZil,
} from '../components/ui/icons'
import { useOkunmamisSayisi } from '../features/settings/api'

interface NavItem {
  to: string
  label: string
  Icon: typeof IconAraba
  end?: boolean
}

/**
 * Bottom navigation on a phone, a top bar from `md` up.
 *
 * Gişe is the first slot deliberately: entry, exit and the list of cars
 * inside are almost everything an operator does all day, and none of them
 * should ever be more than one thumb-tap away.
 */
export function AppShell() {
  const { profile } = useAuth()
  const yonetici = isYonetici(profile)
  const { data: okunmamis = 0 } = useOkunmamisSayisi(yonetici)

  const items: NavItem[] = [
    // One slot, not three: Giriş, Çıkış and the vehicle list are modes of
    // the same page now. No `end`, so /gise/giris and /gise/cikis keep the
    // tab lit instead of dropping the highlight the moment a mode is picked.
    { to: '/gise', label: 'Gişe', Icon: IconAraba },
    { to: '/vardiya', label: 'Vardiya', Icon: IconVardiya },
    // Personel only, and not out of thrift: a Yönetici reaches Profil from
    // the Yönetim menu, while a Personel has no menu at all — without this
    // tab there is no way for them to sign out. Adding it for everyone would
    // make five tabs on a 375px phone to save a Yönetici one tap.
    ...(yonetici ? [] : [{ to: '/ayarlar', label: 'Profil', Icon: IconKisi }]),
    // Finans and Yönetim are both Yönetici-only. Hiding them is UX; RLS
    // is what actually refuses a Personel who types the URL.
    ...(yonetici
      ? [
          { to: '/finans', label: 'Finans', Icon: IconRapor },
          { to: '/yonetim', label: 'Yönetim', Icon: IconPanel, end: true },
        ]
      : []),
  ]

  return (
    <div className="min-h-dvh bg-bg">
      {/* ------------------------------------------------ desktop top bar */}
      <header className="sticky top-0 z-20 hidden border-b border-divider bg-surface md:block">
        <div className="mx-auto flex h-16 max-w-[1100px] items-center gap-2 px-6">
          <span className="mr-4 flex items-center gap-2.5">
            <span className="flex size-8 items-center justify-center rounded-field bg-brand text-[17px] font-bold text-on-brand">
              P
            </span>
            <span className="text-lead font-semibold text-ink">Otopark</span>
          </span>
          <nav className="flex flex-1 items-center gap-1">
            {items.map(({ to, label, Icon, end }) => (
              <NavLink
                key={to}
                to={to}
                end={end}
                className={({ isActive }) =>
                  [
                    'flex min-h-[44px] items-center gap-2 rounded-chip px-4 text-body font-medium transition-colors',
                    isActive ? 'bg-accent-soft text-accent' : 'text-soft hover:bg-field',
                  ].join(' ')
                }
              >
                <Icon size={19} />
                {label}
              </NavLink>
            ))}
          </nav>
          {yonetici && (
            <NavLink
              to="/bildirimler"
              aria-label="Bildirimler"
              className={({ isActive }) =>
                [
                  'relative flex size-11 items-center justify-center rounded-chip transition-colors',
                  isActive ? 'bg-accent-soft text-accent' : 'text-soft hover:bg-field',
                ].join(' ')
              }
            >
              <IconZil size={20} />
              {okunmamis > 0 && <Rozet sayi={okunmamis} />}
            </NavLink>
          )}
        </div>
      </header>

      {/* ---------------------------------------------------------- body */}
      <main className="mx-auto w-full max-w-[1100px] pb-[calc(72px+env(safe-area-inset-bottom))] md:px-6 md:pb-10">
        <Outlet />
      </main>

      {/* ---------------------------------------------- mobile bottom nav */}
      <nav className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-surface/90 pb-[env(safe-area-inset-bottom)] shadow-nav backdrop-blur-lg md:hidden">
        <div className="flex px-1 pt-1.5 pb-0.5">
          {items.map(({ to, label, Icon, end }) => (
            <NavLink
              key={to}
              to={to}
              end={end}
              className={({ isActive }) =>
                [
                  'flex min-h-[56px] flex-1 flex-col items-center justify-center gap-1',
                  isActive ? 'text-accent' : 'text-faint',
                ].join(' ')
              }
            >
              {({ isActive }) => (
                <>
                  {/* The tinted tile behind the icon — not just a colour
                      change. Which tab you are on has to survive a glance in
                      sunlight, and a tinted shape reads far faster than a hue
                      shift on a 22px stroke icon. */}
                  <span
                    className={[
                      'flex h-7 w-12 items-center justify-center rounded-chip transition-colors',
                      isActive ? 'bg-accent-soft' : 'bg-transparent',
                    ].join(' ')}
                  >
                    <Icon size={21} />
                  </span>
                  <span className="text-micro font-medium">{label}</span>
                </>
              )}
            </NavLink>
          ))}
        </div>
      </nav>
    </div>
  )
}

function Rozet({ sayi }: { sayi: number }) {
  return (
    <span className="absolute top-1.5 right-1.5 min-w-[18px] rounded-chip bg-danger px-1 text-center text-[10px] leading-[18px] font-semibold text-surface">
      {sayi > 99 ? '99+' : sayi}
    </span>
  )
}
