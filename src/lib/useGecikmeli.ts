import { useEffect, useState } from 'react'

/**
 * The value, but only once it has stopped changing for `ms`.
 *
 * For search boxes and plate fields whose value goes into a server query: the
 * field itself stays instant, while the query waits until the operator pauses.
 * Without it, typing "34ABC123" sent a request per letter and re-drew the
 * whole list each time — on the P2 test bench (Chrome 119, 4x slower CPU)
 * that added about a second of lag to an eight-letter plate.
 *
 * Clearing is immediate: an emptied search box should show the full list at
 * once, not a quarter-second later.
 */
export function useGecikmeli<T>(deger: T, ms = 250): T {
  const [gecikmeli, setGecikmeli] = useState(deger)
  const bos = deger === '' || deger == null
  useEffect(() => {
    if (bos) return
    const t = setTimeout(() => setGecikmeli(deger), ms)
    return () => clearTimeout(t)
  }, [deger, ms, bos])
  return bos ? deger : gecikmeli
}
