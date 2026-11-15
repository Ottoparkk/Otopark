import { useState } from 'react'
import { Label } from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { formatPlaka } from '../../lib/plaka'
import { formatTL } from '../../lib/money'
import { UCRETSIZ_NOT_MAX, UCRETSIZ_SEBEPLER, ucretsizEtiket, ucretsizHatasi } from '../../lib/ucretsiz'
import type { UcretsizSebep } from '../../lib/types'

export interface UcretsizGonderim {
  sebep: UcretsizSebep
  not: string
}

/**
 * Free exit (065 / 066): reason + REQUIRED note, then a box that reads it all
 * back (owner, 2026-11-14: the button only asks, the box sends). One flow for
 * both places — the exit screen (car inside) and the "Ödeme topla" box (the
 * camera or "Çıkış Ver" already let the car out owing).
 *
 * Mount it only while the flow is open: mounting starts it empty, `onKapat`
 * ends it. "Vazgeç" in the box goes back to the form with the values kept.
 * `onGonder` rejects with a displayable message to keep the box open on it;
 * on success the parent unmounts this (or shows its receipt).
 */
export function UcretsizCikisPencereleri({
  plaka,
  tutarKurus,
  yonetici,
  onKapat,
  onGonder,
}: {
  plaka: string
  /** The fee being waived, as the screen shows it. */
  tutarKurus: number
  yonetici: boolean
  onKapat: () => void
  onGonder: (g: UcretsizGonderim) => Promise<void>
}) {
  const [sebep, setSebep] = useState<UcretsizSebep | null>(null)
  const [not, setNot] = useState('')
  const [formHata, setFormHata] = useState<string | null>(null)
  const [onay, setOnay] = useState<UcretsizGonderim | null>(null)
  const [hata, setHata] = useState<string | null>(null)
  const [gonderiliyor, setGonderiliyor] = useState(false)

  function gonder() {
    if (!onay || gonderiliyor) return
    setHata(null)
    setGonderiliyor(true)
    onGonder(onay)
      .catch((err: unknown) => {
        setHata(err instanceof Error ? err.message : 'Ücretsiz çıkış kaydedilemedi. Tekrar deneyin.')
      })
      .finally(() => setGonderiliyor(false))
  }

  return (
    <>
      <FormModal
        open={onay === null}
        onOpenChange={(o) => {
          if (!o) onKapat()
        }}
        title="Ücretsiz çıkış"
        submitLabel="Devam"
        error={formHata}
        onSubmit={() => {
          const h = ucretsizHatasi(sebep, not)
          if (h || !sebep) {
            setFormHata(h ?? 'Sebep seçin.')
            return
          }
          setFormHata(null)
          setHata(null)
          // One box at a time: the form steps aside while the box reads it
          // back, and comes back unchanged on "Vazgeç".
          setOnay({ sebep, not: not.trim() })
        }}
      >
        <div>
          <Label>Sebep</Label>
          <div className="grid grid-cols-2 gap-2" role="radiogroup" aria-label="Sebep">
            {UCRETSIZ_SEBEPLER.map((s) => {
              const secili = sebep === s.value
              return (
                <button
                  key={s.value}
                  type="button"
                  role="radio"
                  aria-checked={secili}
                  onClick={() => setSebep(s.value)}
                  className={[
                    'min-h-[52px] rounded-field px-3 text-body font-medium transition-colors',
                    // "Diğer" spans the row: five chips, no orphan half.
                    s.value === 'DIGER' ? 'col-span-2' : '',
                    secili ? 'bg-accent text-accent-ink' : 'bg-field text-soft',
                  ].join(' ')}
                >
                  {s.label}
                </button>
              )
            })}
          </div>
        </div>
        <div>
          <Label htmlFor="ucretsiz-not">Not (zorunlu)</Label>
          <textarea
            id="ucretsiz-not"
            value={not}
            onChange={(e) => setNot(e.target.value)}
            maxLength={UCRETSIZ_NOT_MAX}
            rows={3}
            placeholder="Örn. ekip aracı, fiyat sorup çıktı"
            className="w-full resize-y rounded-field border border-border bg-field px-4 py-3 text-body text-ink outline-none focus:border-accent"
          />
        </div>
      </FormModal>

      <ConfirmDialog
        open={onay !== null}
        onOpenChange={(o) => {
          if (o || gonderiliyor) return
          setOnay(null)
        }}
        title="Ücretsiz çıkış verilsin mi?"
        description={
          onay && (
            <>
              <span className="block text-title font-semibold tracking-wide text-ink tnum">
                {formatPlaka(plaka)}
              </span>
              <span className="mt-1 block break-words">
                <strong className="font-semibold text-ink">{ucretsizEtiket(onay.sebep)}</strong> —{' '}
                {onay.not}
              </span>
              <span className="mt-1 block font-semibold text-warn tnum">
                Hesaplanan {formatTL(tutarKurus)} alınmayacak.
              </span>
              {!yonetici && <span className="mt-1 block">Yöneticiye bildirilir.</span>}
            </>
          )
        }
        confirmLabel="Ücretsiz çıkış ver"
        loading={gonderiliyor}
        error={hata}
        onConfirm={gonder}
      />
    </>
  )
}
