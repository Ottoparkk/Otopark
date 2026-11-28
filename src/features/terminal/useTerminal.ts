import { useMemo, useSyncExternalStore } from 'react'
import { safeStorage } from '../../lib/storage'
import { terminalOku, terminalSil, terminalYaz, type TerminalKaydi } from './terminal'

/** Same-tab change signal; the `storage` event covers other tabs. */
const OLAY = 'op-terminal'

function abone(degisti: () => void): () => void {
  window.addEventListener(OLAY, degisti)
  window.addEventListener('storage', degisti)
  return () => {
    window.removeEventListener(OLAY, degisti)
    window.removeEventListener('storage', degisti)
  }
}

/** This device's terminal record, or null when it is not a terminal. */
export function useTerminal(): TerminalKaydi | null {
  // The raw string is the snapshot: stable between renders, so React does
  // not loop; the parsed record is derived from it.
  const ham = useSyncExternalStore(abone, () => safeStorage.getItem('op.terminal'))
  return useMemo(() => terminalOku({ getItem: () => ham }), [ham])
}

export function buCihaziTerminalYap(kayit: TerminalKaydi): void {
  terminalYaz(safeStorage, kayit)
  window.dispatchEvent(new Event(OLAY))
}

export function terminalKaydiniSil(): void {
  terminalSil(safeStorage)
  window.dispatchEvent(new Event(OLAY))
}
