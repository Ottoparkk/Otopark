import * as Dialog from '@radix-ui/react-dialog'
import { useEffect, useRef, useState, type PointerEvent, type WheelEvent } from 'react'
import { IconCarpi } from './icons'
import {
  BASLANGIC,
  ciftDokunus,
  kaydir,
  kistir,
  sigdir,
  sinirla,
  type Boyut,
  type Durum,
  type Nokta,
} from '../../lib/yakinlastir'

/**
 * A photo, full screen, zoomable: pinch and drag on a phone, double tap to
 * zoom in on a point (and again to come back), the wheel and a double click
 * on a computer. Opened by tapping a ticket's camera photo, where the plate
 * in the picture is what gets checked — and at thumbnail size a 6 and an 8
 * look alike.
 *
 * The maths lives in lib/yakinlastir.ts (Node-checked); this file only turns
 * pointers into calls to it.
 *
 * Deliberately no save / share button: the photo shows a plate (KVKK) and
 * stays inside the app.
 */
export function FotoGoruntuleyici({
  url,
  etiket,
  onKapat,
}: {
  /** The photo to show; null = closed. */
  url: string | null
  /** Short caption ("Giriş" / "Çıkış"), shown top left. */
  etiket?: string
  onKapat: () => void
}) {
  return (
    <Dialog.Root open={!!url} onOpenChange={(a) => !a && onKapat()}>
      <Dialog.Portal>
        <Dialog.Overlay className="fixed inset-0 z-50 bg-black/90" />
        <Dialog.Content
          aria-describedby={undefined}
          className="fixed inset-0 z-50 flex flex-col outline-none"
        >
          <Dialog.Title className="sr-only">{etiket ? `${etiket} fotoğrafı` : 'Fotoğraf'}</Dialog.Title>
          {/* Keyed by the photo: a new photo starts at 1×, never at the last
              one's zoom. Content unmounts when closed, so reopening resets too. */}
          {url && <Sahne key={url} url={url} onKapat={onKapat} />}
          <div className="pointer-events-none absolute inset-x-0 top-0 flex items-center justify-between gap-3 px-3 pt-[calc(12px+env(safe-area-inset-top))]">
            {etiket ? (
              <span className="rounded-chip bg-surface/90 px-3 py-1.5 text-label font-medium text-ink">
                {etiket}
              </span>
            ) : (
              <span />
            )}
            <Dialog.Close
              aria-label="Kapat"
              className="pointer-events-auto flex size-11 items-center justify-center rounded-full bg-surface/90 text-ink active:bg-field"
            >
              <IconCarpi size={20} />
            </Dialog.Close>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  )
}

/** A tap: lifted within this long, having moved less than this far. */
const DOKUNUS_MS = 300
const DOKUNUS_PX = 10
/** Two taps this close in time and place are a double tap. */
const CIFT_MS = 300
const CIFT_PX = 30

function Sahne({ url, onKapat }: { url: string; onKapat: () => void }) {
  const kapRef = useRef<HTMLDivElement>(null)
  const [kap, setKap] = useState<Boyut>({ w: 0, h: 0 })
  const [dogal, setDogal] = useState<Boyut>({ w: 0, h: 0 })
  const [d, setD] = useState<Durum>(BASLANGIC)

  // Pointer bookkeeping lives in refs: it changes on every move and must not
  // re-render, and the handlers need the latest values, not a stale closure.
  const dRef = useRef<Durum>(BASLANGIC)
  const parmaklar = useRef(new Map<number, Nokta>())
  const kistirma = useRef<{ bas: Durum; d0: number; odak0: Nokta } | null>(null)
  const sonNokta = useRef<Nokta | null>(null)
  const basma = useRef<{ t: number; p: Nokta; coklu: boolean } | null>(null)
  const sonDokunus = useRef<{ t: number; p: Nokta } | null>(null)
  const kapatilacak = useRef(false)

  const resim = sigdir(kap, dogal)

  function ayarla(yeni: Durum) {
    dRef.current = yeni
    setD(yeni)
  }

  // The frame's size: the screen, minus nothing — but it changes when the
  // phone turns, and the clamps must follow.
  useEffect(() => {
    const el = kapRef.current
    if (!el) return
    const olc = () => setKap({ w: el.clientWidth, h: el.clientHeight })
    olc()
    const ro = new ResizeObserver(olc)
    ro.observe(el)
    return () => ro.disconnect()
  }, [])

  // After a resize the old pan may be out of bounds: clamp again.
  useEffect(() => {
    if (kap.w > 0) ayarla(sinirla(dRef.current, kap, sigdir(kap, dogal)))
  }, [kap, dogal])

  /** Pointer position relative to the frame's centre. */
  function konum(e: PointerEvent | WheelEvent): Nokta {
    const r = kapRef.current!.getBoundingClientRect()
    return { x: e.clientX - r.left - r.width / 2, y: e.clientY - r.top - r.height / 2 }
  }

  /** Only called with two or more pointers down. */
  function ikiParmak(): { mesafe: number; orta: Nokta } {
    const [a = { x: 0, y: 0 }, b = { x: 0, y: 0 }] = [...parmaklar.current.values()]
    return {
      mesafe: Math.hypot(a.x - b.x, a.y - b.y),
      orta: { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 },
    }
  }

  function kistirmaBaslat() {
    const { mesafe, orta } = ikiParmak()
    kistirma.current = { bas: dRef.current, d0: mesafe, odak0: orta }
    sonNokta.current = null
  }

  function asagi(e: PointerEvent<HTMLDivElement>) {
    e.currentTarget.setPointerCapture(e.pointerId)
    kapatilacak.current = false
    const p = konum(e)
    parmaklar.current.set(e.pointerId, p)
    if (parmaklar.current.size === 1) {
      sonNokta.current = p
      basma.current = { t: e.timeStamp, p, coklu: false }
    } else if (parmaklar.current.size === 2) {
      if (basma.current) basma.current.coklu = true
      kistirmaBaslat()
    }
  }

  function hareket(e: PointerEvent<HTMLDivElement>) {
    if (!parmaklar.current.has(e.pointerId)) return
    const p = konum(e)
    parmaklar.current.set(e.pointerId, p)
    if (parmaklar.current.size >= 2 && kistirma.current) {
      const { mesafe, orta } = ikiParmak()
      const k = kistirma.current
      ayarla(kistir(k.bas, k.d0, mesafe, k.odak0, orta, kap, resim))
    } else if (parmaklar.current.size === 1 && sonNokta.current) {
      const dx = p.x - sonNokta.current.x
      const dy = p.y - sonNokta.current.y
      sonNokta.current = p
      if (dx || dy) ayarla(kaydir(dRef.current, dx, dy, kap, resim))
    }
  }

  function yukari(e: PointerEvent<HTMLDivElement>) {
    if (!parmaklar.current.has(e.pointerId)) return
    const p = konum(e)
    parmaklar.current.delete(e.pointerId)
    kistirma.current = null

    if (parmaklar.current.size === 1) {
      // One finger of a pinch lifted: carry on as a pan from where the other
      // finger IS, so the photo does not jump to catch up.
      sonNokta.current = [...parmaklar.current.values()][0] ?? null
      return
    }
    if (parmaklar.current.size > 1) {
      kistirmaBaslat()
      return
    }
    sonNokta.current = null

    // Last finger up: was it a tap?
    const b = basma.current
    basma.current = null
    if (e.type === 'pointercancel' || !b || b.coklu) return
    const tap =
      e.timeStamp - b.t < DOKUNUS_MS && Math.hypot(p.x - b.p.x, p.y - b.p.y) < DOKUNUS_PX
    if (!tap) return

    const onceki = sonDokunus.current
    if (
      onceki &&
      e.timeStamp - onceki.t < CIFT_MS &&
      Math.hypot(p.x - onceki.p.x, p.y - onceki.p.y) < CIFT_PX
    ) {
      sonDokunus.current = null
      ayarla(ciftDokunus(dRef.current, p, kap, resim))
      return
    }
    sonDokunus.current = { t: e.timeStamp, p }

    // A single tap on the dark area beside an unzoomed photo closes it —
    // the way out a phone user expects. On the photo, or while zoomed, a tap
    // does nothing (it may be the first half of a double tap).
    const disarida = Math.abs(p.x) > resim.w / 2 || Math.abs(p.y) > resim.h / 2
    if (dRef.current.s <= 1.01 && disarida) kapatilacak.current = true
  }

  // The close itself waits for the `click` that follows the tap. Closing on
  // pointerup would remove the viewer before that click, and on a phone the
  // click would then land on whatever is under the finger on the screen
  // behind — "Tahsil et", say.
  function tikla() {
    if (!kapatilacak.current) return
    kapatilacak.current = false
    onKapat()
  }

  function teker(e: WheelEvent<HTMLDivElement>) {
    if (!e.deltaY) return
    const p = konum(e)
    const kat = Math.exp(-e.deltaY * 0.002)
    ayarla(kistir(dRef.current, 1, kat, p, p, kap, resim))
  }

  return (
    <div
      ref={kapRef}
      onPointerDown={asagi}
      onPointerMove={hareket}
      onPointerUp={yukari}
      onPointerCancel={yukari}
      onWheel={teker}
      onClick={tikla}
      className="relative min-h-0 flex-1 touch-none overflow-hidden select-none"
    >
      {kap.w > 0 && (
        <img
          src={url}
          alt=""
          draggable={false}
          onLoad={(e) =>
            setDogal({ w: e.currentTarget.naturalWidth, h: e.currentTarget.naturalHeight })
          }
          className="absolute top-1/2 left-1/2 max-w-none object-contain"
          style={{
            width: resim.w,
            height: resim.h,
            transform: `translate(-50%, -50%) translate(${d.x}px, ${d.y}px) scale(${d.s})`,
          }}
        />
      )}
    </div>
  )
}
