/**
 * Screen memory (owner, 27.11): tabs, filters and searches survive going back,
 * switching tabs in the bottom bar and a reload. Kept in sessionStorage under
 * `op.ekran.<key>`, so a fully closed app starts clean, and cleared on
 * sign-out so the next person on the same phone does too.
 *
 * Pure and storage-agnostic (the storage is an argument), so
 * tests/ekranHafizasi.check.mjs runs it in Node. No runtime imports.
 */

export interface HafizaDeposu {
  getItem(k: string): string | null
  setItem(k: string, v: string): void
  removeItem?(k: string): void
  key?(i: number): string | null
  readonly length?: number
}

const ON_EK = 'op.ekran.'

/**
 * The stored value, or `varsayilan` when there is none, it does not parse, it
 * is not in `gecerli`, or (without a list) its type differs from the default's
 * — a value an older build left behind must not break the screen.
 */
export function hafizaOku<T>(
  depo: HafizaDeposu | null,
  anahtar: string,
  varsayilan: T,
  gecerli?: readonly T[],
): T {
  if (!depo) return varsayilan
  let ham: string | null
  try {
    ham = depo.getItem(ON_EK + anahtar)
  } catch {
    return varsayilan
  }
  if (ham == null) return varsayilan
  let deger: unknown
  try {
    deger = JSON.parse(ham)
  } catch {
    return varsayilan
  }
  if (gecerli) return gecerli.includes(deger as T) ? (deger as T) : varsayilan
  // null default (e.g. a custom date range not chosen yet): any object or null.
  if (varsayilan === null) return deger === null || typeof deger === 'object' ? (deger as T) : varsayilan
  return typeof deger === typeof varsayilan ? (deger as T) : varsayilan
}

export function hafizaYaz<T>(depo: HafizaDeposu | null, anahtar: string, deger: T): void {
  if (!depo) return
  try {
    depo.setItem(ON_EK + anahtar, JSON.stringify(deger))
  } catch {
    // Quota or a locked-down browser: the screen still works, it just forgets.
  }
}

/** Removes every screen key and nothing else (the session lives elsewhere). */
export function hafizaTemizle(depo: HafizaDeposu | null): void {
  if (!depo?.key || !depo.removeItem || depo.length == null) return
  try {
    const silinecek: string[] = []
    for (let i = 0; i < depo.length; i++) {
      const k = depo.key(i)
      if (k?.startsWith(ON_EK)) silinecek.push(k)
    }
    for (const k of silinecek) depo.removeItem(k)
  } catch {
    /* ignore */
  }
}
