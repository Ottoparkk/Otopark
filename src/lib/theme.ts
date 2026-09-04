import { safeStorage } from './storage'

/** Must match the inline pre-paint script in index.html. */
const KEY = 'op-dark'

/**
 * Dark is the DEFAULT, so the stored value is read as an opt-OUT: only an
 * explicit '0' turns it off. A missing key — first launch, or storage the
 * browser refuses — has to land on dark, which is what the inline script's
 * try/catch does too. Reading it as an opt-in instead would make a
 * storage-restricted browser silently light while every other one is dark.
 */
function tercihDark(): boolean {
  return safeStorage.getItem(KEY) !== '0'
}

/** The browser chrome should match the surface underneath it. */
function temaRengiYaz(dark: boolean): void {
  const meta = document.querySelector('meta[name="theme-color"]')
  // Both values are --color-bg from index.css. The light one used to be
  // #14161A — that is the INK colour, so choosing light painted a near-black
  // status bar over a near-white app.
  if (meta) meta.setAttribute('content', dark ? '#0f1013' : '#eef1f6')
}

/**
 * index.html already applied the class before first paint (so the launch never
 * flashes the wrong colour). This runs afterwards to keep the in-memory state
 * honest if storage was unavailable to that inline script, and to bring the
 * theme colour in step with the surface — `toggle`, not `add`, because the
 * default is now dark and this may need to take the class OFF.
 */
export function initTheme(): void {
  const dark = tercihDark()
  document.documentElement.classList.toggle('dark', dark)
  temaRengiYaz(dark)
}

export function isDarkMode(): boolean {
  return document.documentElement.classList.contains('dark')
}

export function setDarkMode(on: boolean): void {
  document.documentElement.classList.toggle('dark', on)
  safeStorage.setItem(KEY, on ? '1' : '0')
  temaRengiYaz(on)
}
