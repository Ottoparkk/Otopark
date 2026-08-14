import { NavLink, Outlet } from 'react-router'
import { useAuth } from './providers/AuthProvider'
import { isYonetici } from '../lib/rbac'
import {
  IconAraba,
  IconCikis,
  IconGiris,
  IconPanel,
  IconVardiya,
  IconZil,
} from '../components/ui/icons'
import { useOkunmamisSayisi } from '../features/settings/api'

interface NavItem {
  to: string
  label: string
  Icon: typeof IconGiris
  end?: boolean
}

/**
 * Bottom navigation on a phone, a top bar from `md` up.
 *
 * Giriş and Çıkış are the first two slots deliberately — between them they
 * are almost everything an operator does all day, and they should never be
 * more than one thumb-tap away.
 */
export function AppShell() {
  const { profile } = useAuth()
  const yonetici = isYonetici(profile)
  const { data: okunmamis = 0 } = useOkunmamisSayisi(yonetici)

  const items: NavItem[] = [
    { to: '/gise/giris', label: 'Giriş', Icon: IconGiris },
    { to: '/gise/cikis', label: 'Çıkış', Icon: IconCikis },
    { to: '/gise', label: 'Araçlar', Icon: IconAraba, end: true },
    { to: '/vardiya', label: 'Vardiya', Icon: IconVardiya },
    ...(yonetici ? [{ to: '/yonetim', label: 'Yönetim', Icon: IconPanel, end: true }] : []),
  ]

  return (
    <div className="min-h-dvh bg-bg">
      {/* ------------------------------------------------ desktop top bar */}
      <header className="sticky top-0 z-20 hidden border-b border-divider bg-surface md:block">
        <div className="mx-auto flex h-16 max-w-[1100px] items-center gap-2 px-6">
          <span className="mr-4 text-lead font-semibold text-ink">Otopark</span>
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
      <nav className="fixed inset-x-0 bottom-0 z-20 border-t border-divider bg-surface pb-[env(safe-area-inset-bottom)] md:hidden">
        <div className="flex">
          {items.map(({ to, label, Icon, end }) => (
            <NavLink
              key={to}
              to={to}
              end={end}
              className={({ isActive }) =>
                [
                  'flex min-h-[60px] flex-1 flex-col items-center justify-center gap-1 transition-colors',
                  isActive ? 'text-accent' : 'text-faint',
                ].join(' ')
              }
            >
              <Icon size={22} />
              <span className="text-micro font-medium">{label}</span>
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
