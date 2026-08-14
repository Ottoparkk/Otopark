import { safeStorage } from './storage'

/** Must match the inline pre-paint script in index.html. */
const KEY = 'op-dark'

/**
 * index.html already applied the class before first paint (so a dark launch
 * never flashes white). This runs afterwards purely to keep the in-memory
 * state honest if storage was unavailable to that inline script.
 */
export function initTheme(): void {
  if (safeStorage.getItem(KEY) === '1') {
    document.documentElement.classList.add('dark')
  }
}

export function isDarkMode(): boolean {
  return document.documentElement.classList.contains('dark')
}

export function setDarkMode(on: boolean): void {
  document.documentElement.classList.toggle('dark', on)
  safeStorage.setItem(KEY, on ? '1' : '0')
  // Keep the browser chrome in step with the app surface.
  const meta = document.querySelector('meta[name="theme-color"]')
  if (meta) meta.setAttribute('content', on ? '#0F1013' : '#14161A')
}
