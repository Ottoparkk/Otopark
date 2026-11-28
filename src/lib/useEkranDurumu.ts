import { useCallback, useState, type SetStateAction } from 'react'
import { hafizaOku, hafizaTemizle, hafizaYaz, type HafizaDeposu } from './ekranHafizasi'

/** sessionStorage, or nothing where the browser refuses it (private mode). */
function depo(): HafizaDeposu | null {
  try {
    return window.sessionStorage
  } catch {
    return null
  }
}

/**
 * useState that survives leaving the screen (owner, 27.11: back from a ticket
 * must land on the same tab, filter and search). Screen state only — never a
 * form field. Keys are `<screen>.<what>`, e.g. `gise.filtre`.
 */
export function useEkranDurumu<T>(anahtar: string, varsayilan: T, gecerli?: readonly T[]) {
  const [deger, setDeger] = useState<T>(() => hafizaOku(depo(), anahtar, varsayilan, gecerli))
  const ayarla = useCallback(
    (yeni: SetStateAction<T>) => {
      setDeger((onceki) => {
        const d = typeof yeni === 'function' ? (yeni as (p: T) => T)(onceki) : yeni
        hafizaYaz(depo(), anahtar, d)
        return d
      })
    },
    [anahtar],
  )
  return [deger, ayarla] as const
}

/** Sign-out: the next person on this phone starts from clean screens. */
export function ekranHafizasiniTemizle(): void {
  hafizaTemizle(depo())
}
