import { useEffect, useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Spinner } from './Spinner'
import { cekmeMesafesi, ilerleme, yenilensinMi, ESIK } from '../../lib/cekYenile'

/**
 * Pull down at the top of a screen to refresh it — on a phone.
 *
 * The installed app (standalone PWA) gets no pull-to-refresh from the
 * browser, and in a browser tab the native one is off on purpose
 * (`overscroll-behavior-y: none` on body: a full reload at the barrier would
 * throw away a half-typed plate). This one does NOT reload the page: it
 * refetches the queries the screen is showing, so typed text, the open mode
 * and the scroll position all stay. Mutations are never touched.
 *
 * Touch only (a mouse never pulls), and only when the pull clearly means it:
 * one finger, the page at its top, no dialog open (a pinch on the photo
 * viewer must not refresh the screen behind it), nothing under the finger
 * scrolled, and the gesture heading down rather than sideways.
 *
 * Mounted once in AppShell. The maths is in lib/cekYenile.ts (Node-checked).
 */
export function CekYenile() {
  const qc = useQueryClient()
  const [mesafe, setMesafe] = useState(0)
  const [yenileniyor, setYenileniyor] = useState(false)

  // Gesture bookkeeping in a ref: the window listeners are attached once and
  // must see the latest values, and a touchmove must not wait for a render.
  const durum = useRef({
    bas: null as { x: number; y: number } | null,
    karar: null as 'dikey' | null,
    mesafe: 0,
    yenileniyor: false,
  })

  useEffect(() => {
    const st = durum.current

    function bitir() {
      st.bas = null
      st.karar = null
      st.mesafe = 0
      setMesafe(0)
    }

    function basla(e: TouchEvent) {
      // A second finger mid-pull cancels the pull (it is a pinch).
      if (st.bas) bitir()
      if (st.yenileniyor || e.touches.length !== 1) return
      if (window.scrollY > 0) return
      // Radix marks the body while a dialog (photo viewer, form, confirm) is open.
      if (document.body.hasAttribute('data-scroll-locked')) return
      if (kaydirilmisAta(e.target)) return
      const t = e.touches[0]!
      st.bas = { x: t.clientX, y: t.clientY }
    }

    function hareket(e: TouchEvent) {
      if (!st.bas) return
      if (e.touches.length !== 1) {
        bitir()
        return
      }
      const t = e.touches[0]!
      const dx = t.clientX - st.bas.x
      const dy = t.clientY - st.bas.y
      if (!st.karar) {
        if (Math.hypot(dx, dy) < 10) return
        // Sideways, or up (scrolling the page down): not a pull.
        if (!(dy > Math.abs(dx))) {
          bitir()
          return
        }
        st.karar = 'dikey'
      }
      st.mesafe = cekmeMesafesi(dy)
      setMesafe(st.mesafe)
    }

    async function birak() {
      if (!st.bas) return
      const yenile = st.karar === 'dikey' && yenilensinMi(st.mesafe)
      bitir()
      if (!yenile) return
      st.yenileniyor = true
      setYenileniyor(true)
      try {
        // At least half a second: a refresh that finishes in 80 ms would
        // flash the spinner too briefly to tell the operator it happened.
        await Promise.all([
          qc.refetchQueries({ type: 'active' }),
          new Promise((r) => setTimeout(r, 500)),
        ])
      } finally {
        st.yenileniyor = false
        setYenileniyor(false)
      }
    }

    function vazgec() {
      if (st.bas) bitir()
    }

    const pasif = { passive: true } as const
    window.addEventListener('touchstart', basla, pasif)
    window.addEventListener('touchmove', hareket, pasif)
    window.addEventListener('touchend', birak, pasif)
    window.addEventListener('touchcancel', vazgec, pasif)
    return () => {
      window.removeEventListener('touchstart', basla)
      window.removeEventListener('touchmove', hareket)
      window.removeEventListener('touchend', birak)
      window.removeEventListener('touchcancel', vazgec)
    }
  }, [qc])

  const g = yenileniyor ? ESIK : mesafe
  const p = yenileniyor ? 1 : ilerleme(mesafe)
  const gorunur = yenileniyor || mesafe > 0
  // Circumference of the r=9 circle (Spinner's own shape).
  const CEVRE = 2 * Math.PI * 9

  return (
    <div
      aria-hidden={!yenileniyor}
      className={[
        'pointer-events-none fixed inset-x-0 top-0 z-30 flex justify-center pt-[env(safe-area-inset-top)]',
        // Follows the finger with no lag while pulling; eases back on release.
        mesafe > 0 ? '' : 'transition-[transform,opacity] duration-200',
      ].join(' ')}
      style={{
        transform: `translateY(${g - 48}px)`,
        opacity: gorunur ? 0.4 + 0.6 * p : 0,
      }}
    >
      <div className="flex size-10 items-center justify-center rounded-full bg-surface shadow-modal">
        {yenileniyor ? (
          <Spinner size={22} label="Yenileniyor" />
        ) : (
          <svg
            width={22}
            height={22}
            viewBox="0 0 24 24"
            fill="none"
            className="text-accent"
            style={{ transform: `rotate(${p * 270}deg)` }}
          >
            <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="2.5" opacity="0.2" />
            <circle
              cx="12"
              cy="12"
              r="9"
              stroke="currentColor"
              strokeWidth="2.5"
              strokeLinecap="round"
              strokeDasharray={`${p * 0.8 * CEVRE} ${CEVRE}`}
              transform="rotate(-90 12 12)"
            />
          </svg>
        )}
      </div>
    </div>
  )
}

/** Is the touched element, or anything around it, scrolled away from its top? */
function kaydirilmisAta(hedef: EventTarget | null): boolean {
  let el = hedef instanceof Element ? hedef : null
  while (el && el !== document.body && el !== document.documentElement) {
    if (el.scrollTop > 0) return true
    el = el.parentElement
  }
  return false
}
