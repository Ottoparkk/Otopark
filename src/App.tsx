import { Suspense, lazy } from 'react'
import { Outlet, Route, Routes } from 'react-router'
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

const Giris = lazy(() => import('./features/gise/Giris'))
const Cikis = lazy(() => import('./features/gise/Cikis'))
const AcikBiletler = lazy(() => import('./features/gise/AcikBiletler'))
const BiletDetay = lazy(() => import('./features/gise/BiletDetay'))
const Vardiya = lazy(() => import('./features/vardiya/Vardiya'))
const Bildirimler = lazy(() => import('./features/settings/Bildirimler'))
const Ayarlar = lazy(() => import('./features/settings/Ayarlar'))

const Panel = lazy(() => import('./features/yonetim/Panel'))
const Raporlar = lazy(() => import('./features/yonetim/Raporlar'))
const Tarifeler = lazy(() => import('./features/yonetim/Tarifeler'))
const Personel = lazy(() => import('./features/yonetim/Personel'))
const OtoparkAyarlari = lazy(() => import('./features/yonetim/OtoparkAyarlari'))
const Kasa = lazy(() => import('./features/yonetim/Kasa'))
const Biletler = lazy(() => import('./features/yonetim/Biletler'))
const Vardiyalar = lazy(() => import('./features/yonetim/Vardiyalar'))
const AbonmanListe = lazy(() => import('./features/abonman/AbonmanListe'))
const AbonmanDetay = lazy(() => import('./features/abonman/AbonmanDetay'))
const Yerler = lazy(() => import('./features/yerler/Yerler'))
const Hesaplar = lazy(() => import('./features/hesap/Hesaplar'))
const HesapDetay = lazy(() => import('./features/hesap/HesapDetay'))
const Istisnalar = lazy(() => import('./features/istisna/Istisnalar'))

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
            <Route path="/gise" element={<AcikBiletler />} />
            <Route path="/gise/giris" element={<Giris />} />
            <Route path="/gise/cikis" element={<Cikis />} />
            <Route path="/gise/bilet/:id" element={<BiletDetay />} />
            <Route path="/vardiya" element={<Vardiya />} />
            <Route path="/bildirimler" element={<Bildirimler />} />
            <Route path="/ayarlar" element={<Ayarlar />} />
            <Route path="/istisnalar" element={<Istisnalar />} />

            {/* Yönetici only. The guard mirrors RLS for UX; RLS and the RPCs
                are what actually refuse a Personel who types the URL. */}
            <Route element={<YoneticiRotalari />}>
              <Route path="/yonetim" element={<Panel />} />
              <Route path="/yonetim/raporlar" element={<Raporlar />} />
              <Route path="/yonetim/tarifeler" element={<Tarifeler />} />
              <Route path="/yonetim/personel" element={<Personel />} />
              <Route path="/yonetim/ayarlar" element={<OtoparkAyarlari />} />
              <Route path="/yonetim/kasa" element={<Kasa />} />
              <Route path="/yonetim/biletler" element={<Biletler />} />
              <Route path="/yonetim/vardiyalar" element={<Vardiyalar />} />
              <Route path="/yonetim/abonman" element={<AbonmanListe />} />
              <Route path="/yonetim/abonman/:id" element={<AbonmanDetay />} />
              <Route path="/yonetim/yerler" element={<Yerler />} />
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
