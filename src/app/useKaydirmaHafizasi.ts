import { useEffect, useLayoutEffect, useRef } from 'react'
import { useLocation, useNavigationType } from 'react-router'
import { hafizaOku, hafizaYaz, type HafizaDeposu } from '../lib/ekranHafizasi'

const ANAHTAR = 'kaydirma'
const EN_FAZLA = 60

function depo(): HafizaDeposu | null {
  try {
    return window.sessionStorage
  } catch {
    return null
  }
}

/**
 * Scroll memory per history entry (owner, 27.11: back from a ticket must land
 * where the list was). The position is saved while scrolling, keyed by
 * `location.key`; a back/forward (POP) puts it back, retrying for 1.5 s
 * because the list may still be drawing; a new page starts at the
 * top. A replace (clearing router state) leaves the scroll alone.
 */
export function useKaydirmaHafizasi() {
  const { key } = useLocation()
  const tur = useNavigationType()
  const aktif = useRef(key)
  const oncekiKey = useRef<string | null>(null)
  const konumlar = useRef<Record<string, number>>(hafizaOku(depo(), ANAHTAR, {}) ?? {})

  useLayoutEffect(() => {
    try {
      window.history.scrollRestoration = 'manual'
    } catch {
      /* ignore */
    }
  }, [])

  useEffect(() => {
    let zamanlayici: number | undefined
    const kaydet = () => {
      konumlar.current[aktif.current] = Math.round(window.scrollY)
      window.clearTimeout(zamanlayici)
      zamanlayici = window.setTimeout(() => {
        // Keep the newest entries only: sessionStorage is small.
        const girdiler = Object.entries(konumlar.current).slice(-EN_FAZLA)
        konumlar.current = Object.fromEntries(girdiler)
        hafizaYaz(depo(), ANAHTAR, konumlar.current)
      }, 200)
    }
    window.addEventListener('scroll', kaydet, { passive: true })
    // Also at the tap, before React sees it: a scroll event is only sent at
    // the next frame, so a tap right after scrolling (or in a background tab)
    // can navigate first and the late event lands under the new page.
    window.addEventListener('click', kaydet, { capture: true })
    return () => {
      window.removeEventListener('scroll', kaydet)
      window.removeEventListener('click', kaydet, { capture: true })
      window.clearTimeout(zamanlayici)
    }
  }, [])

  useLayoutEffect(() => {
    aktif.current = key
    // Opening the app is a POP too, but its entry has no key of its own
    // ("default" after every cold start) — restoring there would replay a
    // position from an earlier visit. Only a real back/forward restores.
    // (Compared with the previous key rather than a first-run flag, so
    // StrictMode's second run of this effect is not taken for a back.)
    const onceki = oncekiKey.current
    oncekiKey.current = key
    if (onceki === key) return
    if (onceki === null) {
      // A cold start reuses "default": forget what an earlier visit left there.
      konumlar.current[key] = Math.round(window.scrollY)
      return
    }
    if (tur === 'REPLACE') return
    const hedef = tur === 'POP' ? (konumlar.current[key] ?? 0) : 0
    if (hedef <= 0) {
      window.scrollTo(0, 0)
      return
    }
    // The list may still be loading or drawing: try each frame for 1.5 s, and
    // stop the moment the user touches the screen (never fight a thumb).
    const son = performance.now() + 1500
    let iptal = false
    const dur = () => {
      iptal = true
    }
    window.addEventListener('touchstart', dur, { once: true, passive: true })
    window.addEventListener('wheel', dur, { once: true, passive: true })
    const dene = () => {
      if (iptal) return
      window.scrollTo(0, hedef)
      if (Math.abs(window.scrollY - hedef) > 2 && performance.now() < son) window.setTimeout(dene, 16)
    }
    dene()
    return () => {
      iptal = true
      window.removeEventListener('touchstart', dur)
      window.removeEventListener('wheel', dur)
    }
  }, [key, tur])
}
