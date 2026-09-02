import { Suspense, lazy } from 'react'
import { Navigate, Outlet, Route, Routes } from 'react-router'
import { AppShell } from './app/AppShell'
import {
  HomeRedirect,
  RedirectIfAuthed,
  RequireActive,
  RequireAuth,
  RequireRole,
} from './app/guards'
import { Spinner } from './components/ui/Spinner'
import { UpdatePrompt } from './components/ui/UpdatePrompt'

/**
 * Auth screens load eagerly — they are the first paint for a signed-out user
 * and a chunk fetch there is a blank screen at the worst moment. Everything
 * else is route-split.
 */
import SignIn from './features/auth/SignIn'
import SignUp from './features/auth/SignUp'
import ResetPassword from './features/auth/ResetPassword'
import PendingApproval from './features/auth/PendingApproval'
import AccountDisabled from './features/auth/AccountDisabled'

const Gise = lazy(() => import('./features/gise/Gise'))
const BiletDetay = lazy(() => import('./features/gise/BiletDetay'))
const Vardiya = lazy(() => import('./features/vardiya/Vardiya'))
const Bildirimler = lazy(() => import('./features/settings/Bildirimler'))
const Ayarlar = lazy(() => import('./features/settings/Ayarlar'))

const Panel = lazy(() => import('./features/yonetim/Panel'))
const Tarifeler = lazy(() => import('./features/finans/Tarifeler'))
const Personel = lazy(() => import('./features/yonetim/Personel'))
const PersonelDetay = lazy(() => import('./features/yonetim/PersonelDetay'))
const OtoparkAyarlari = lazy(() => import('./features/yonetim/OtoparkAyarlari'))

const Finans = lazy(() => import('./features/finans/Finans'))
const Raporlar = lazy(() => import('./features/finans/Raporlar'))
const Kasa = lazy(() => import('./features/finans/Kasa'))
const Onay = lazy(() => import('./features/finans/Onay'))
const Biletler = lazy(() => import('./features/finans/Biletler'))
const Vardiyalar = lazy(() => import('./features/finans/Vardiyalar'))
const AbonmanListe = lazy(() => import('./features/abonman/AbonmanListe'))
const AbonmanDetay = lazy(() => import('./features/abonman/AbonmanDetay'))
const Hesaplar = lazy(() => import('./features/hesap/Hesaplar'))
const HesapDetay = lazy(() => import('./features/hesap/HesapDetay'))
const Istisnalar = lazy(() => import('./features/istisna/Istisnalar'))
const Cop = lazy(() => import('./features/cop/Cop'))

function Yukleniyor() {
  return (
    <div className="flex min-h-[60dvh] items-center justify-center">
      <Spinner label="Yükleniyor" />
    </div>
  )
}

/** Signed in and active. Everything inside gets the shell. */
function Korumali({ children }: { children: React.ReactNode }) {
  return (
    <RequireAuth>
      <RequireActive>{children}</RequireActive>
    </RequireAuth>
  )
}

/**
 * A PATHLESS layout route that only guards — it must render <Outlet/>, not
 * another <AppShell/>. Nesting the shell inside itself would draw two navs
 * and two safe-area paddings on every Yönetim screen.
 */
function YoneticiRotalari() {
  return (
    <RequireRole roles={['YONETICI']}>
      <Outlet />
    </RequireRole>
  )
}

export default function App() {
  return (
    <>
      <UpdatePrompt />
      <Suspense fallback={<Yukleniyor />}>
        <Routes>
          {/* ------------------------------------------------------ auth */}
          <Route
            path="/giris"
            element={
              <RedirectIfAuthed>
                <SignIn />
              </RedirectIfAuthed>
            }
          />
          <Route
            path="/kayit"
            element={
              <RedirectIfAuthed>
                <SignUp />
              </RedirectIfAuthed>
            }
          />
          <Route path="/sifre-sifirla" element={<ResetPassword />} />

          {/* Gates for accounts that exist but cannot use the app yet. */}
          <Route
            path="/onay-bekliyor"
            element={
              <RequireAuth>
                <PendingApproval />
              </RequireAuth>
            }
          />
          <Route
            path="/hesap-kapali"
            element={
              <RequireAuth>
                <AccountDisabled />
              </RequireAuth>
            }
          />

          <Route path="/" element={<HomeRedirect />} />

          {/* --------------------------------------------------- the app */}
          <Route
            element={
              <Korumali>
                <AppShell />
              </Korumali>
            }
          >
            <Route path="/gise" element={<Gise />} />
            <Route path="/gise/giris" element={<Gise />} />
            <Route path="/gise/cikis" element={<Gise />} />
            <Route path="/gise/bilet/:id" element={<BiletDetay />} />
            {/* Park yerleri is no longer a screen — it is a section at the
                bottom of Gişe. This keeps old bookmarks working, and sits
                OUTSIDE the Yönetici block on purpose: inside it, a Personel
                following an old link would hit the guard and bounce home
                instead of landing on the page that now holds the section. */}
            <Route path="/yonetim/yerler" element={<Navigate to="/gise" replace />} />
            <Route path="/vardiya" element={<Vardiya />} />
            <Route path="/bildirimler" element={<Bildirimler />} />
            <Route path="/ayarlar" element={<Ayarlar />} />
            <Route path="/istisnalar" element={<Istisnalar />} />

            {/* Yönetici only. The guard mirrors RLS for UX; RLS and the RPCs
                are what actually refuse a Personel who types the URL. */}
            <Route element={<YoneticiRotalari />}>
              <Route path="/yonetim" element={<Panel />} />
              <Route path="/yonetim/personel" element={<Personel />} />
              {/* Pay is the most private thing stored about a person; the
                  guard here mirrors what every RPC behind it re-checks. */}
              <Route path="/yonetim/personel/:id" element={<PersonelDetay />} />
              {/* Yönetici-only: the bin exposes every deleted record,
                  money ones included. RLS on `cop` says the same. */}
              <Route path="/yonetim/cop" element={<Cop />} />
              <Route path="/yonetim/ayarlar" element={<OtoparkAyarlari />} />

              {/* Finans is its own section, but the same guard: every
                  table behind it is Yönetici-only in RLS. */}
              <Route path="/finans" element={<Finans />} />
              <Route path="/finans/raporlar" element={<Raporlar />} />
              <Route path="/finans/kasa" element={<Kasa />} />
              {/* Deciding what counts as revenue is the owner's call, not a
                  shared finance duty — and the RPCs behind it say the same. */}
              <Route path="/finans/onay" element={<Onay />} />
              <Route path="/finans/biletler" element={<Biletler />} />
              <Route path="/finans/vardiyalar" element={<Vardiyalar />} />
              <Route path="/finans/tarifeler" element={<Tarifeler />} />
              {/* Money moved out of /yonetim. Notification rows written before
                  the move still carry the old links and cannot be rewritten, so
                  these keep those taps landing on the right screen instead of
                  falling through to the catch-all and bouncing home. */}
              <Route path="/yonetim/raporlar" element={<Navigate to="/finans/raporlar" replace />} />
              <Route path="/yonetim/kasa" element={<Navigate to="/finans/kasa" replace />} />
              <Route path="/yonetim/biletler" element={<Navigate to="/finans/biletler" replace />} />
              <Route path="/yonetim/vardiyalar" element={<Navigate to="/finans/vardiyalar" replace />} />

              <Route path="/yonetim/abonman" element={<AbonmanListe />} />
              <Route path="/yonetim/abonman/:id" element={<AbonmanDetay />} />
              <Route path="/yonetim/hesaplar" element={<Hesaplar />} />
              <Route path="/yonetim/hesaplar/:id" element={<HesapDetay />} />
            </Route>
          </Route>

          <Route path="*" element={<HomeRedirect />} />
        </Routes>
      </Suspense>
    </>
  )
}
