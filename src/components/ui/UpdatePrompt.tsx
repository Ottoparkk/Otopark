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

  return (
    <div className="fixed inset-x-3 bottom-[calc(76px+env(safe-area-inset-bottom))] z-30 flex items-center gap-3 rounded-card bg-surface p-4 shadow-modal md:inset-x-auto md:right-6 md:bottom-6 md:w-[360px]">
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
