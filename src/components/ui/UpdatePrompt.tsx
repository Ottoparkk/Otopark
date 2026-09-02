import { useRegisterSW } from 'virtual:pwa-register/react'
import { Button } from './primitives'

/**
 * Service-worker update banner.
 *
 * `registerType: 'prompt'` and this banner exist for one reason: an
 * auto-reload must never fire while a plate is half-typed at the barrier.
 * The operator decides when to take the new version.
 */
export function UpdatePrompt() {
  const {
    needRefresh: [needRefresh, setNeedRefresh],
    updateServiceWorker,
  } = useRegisterSW()

  if (!needRefresh) return null

  // Positioned AROUND the Giriş FAB on Gişe, which shares this corner and the
  // same z-index. It was landing exactly on top of "Güncelle", so the update
  // was unreachable and the tap opened Yeni Kayıt instead.
  //
  // Mobile: the banner is full width and cannot dodge sideways, so it sits
  // above the FAB, which ends 140px up. Desktop: it moves to the left corner,
  // which is empty and is where a toast belongs anyway.
  return (
    <div className="fixed inset-x-3 bottom-[calc(152px+env(safe-area-inset-bottom))] z-30 flex items-center gap-3 rounded-card bg-surface p-4 shadow-modal md:right-auto md:bottom-6 md:left-6 md:w-[360px]">
      <div className="min-w-0 flex-1">
        <p className="text-body font-medium text-ink">Yeni sürüm hazır</p>
        <p className="mt-0.5 text-label text-faint">
          Güncellemek için sayfa yeniden yüklenecek.
        </p>
      </div>
      <Button variant="secondary" onClick={() => setNeedRefresh(false)}>
        Sonra
      </Button>
      <Button onClick={() => void updateServiceWorker(true)}>Güncelle</Button>
    </div>
  )
}
