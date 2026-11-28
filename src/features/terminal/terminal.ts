/**
 * The shared handheld (084, owner 28.11): is this device a registered
 * terminal, and is a PIN well-formed.
 *
 * The record lives in localStorage under `op.terminal` as {id, ad, gizli}.
 * `gizli` is the terminal's own 64-hex secret, handed out once by
 * terminal_kaydet; the server keeps only its SHA-256. Sign-out does NOT clear
 * it (only `op.ekran.*` goes), so the device stays a terminal across workers.
 *
 * Pure and storage-agnostic (tests/terminal.check.mjs runs it in Node).
 */

export interface TerminalKaydi {
  id: string
  ad: string
  gizli: string
}

export interface TerminalDeposu {
  getItem(k: string): string | null
  setItem?(k: string, v: string): void
  removeItem?(k: string): void
}

const ANAHTAR = 'op.terminal'

/** Exactly four ASCII digits. */
export function pinGecerli(pin: unknown): boolean {
  return typeof pin === 'string' && /^[0-9]{4}$/.test(pin)
}

/** The stored record, or null when there is none or it is unusable. */
export function terminalOku(depo: TerminalDeposu | null): TerminalKaydi | null {
  if (!depo) return null
  let ham: string | null
  try {
    ham = depo.getItem(ANAHTAR)
  } catch {
    return null
  }
  if (!ham) return null
  let k: unknown
  try {
    k = JSON.parse(ham)
  } catch {
    return null
  }
  if (!k || typeof k !== 'object') return null
  const { id, ad, gizli } = k as Record<string, unknown>
  if (typeof id !== 'string' || !id) return null
  if (typeof ad !== 'string') return null
  if (typeof gizli !== 'string' || !/^[0-9a-f]{64}$/.test(gizli)) return null
  return { id, ad, gizli }
}

export function terminalYaz(depo: TerminalDeposu, kayit: TerminalKaydi): void {
  try {
    depo.setItem?.(ANAHTAR, JSON.stringify(kayit))
  } catch {
    // A locked-down browser: the device simply is not a terminal.
  }
}

export function terminalSil(depo: TerminalDeposu): void {
  try {
    depo.removeItem?.(ANAHTAR)
  } catch {
    /* ignore */
  }
}
