import { useRef, useState } from 'react'
import { Button } from '../../components/ui/primitives'
import { IconKamera } from '../../components/ui/icons'
import { usePlakaOku, type OkumaAsamasi } from './api'
import { rpcErrorText } from '../../lib/errors'

/**
 * Camera capture with optional OCR assist.
 *
 * Two separate jobs, and the difference matters:
 *   • `onFoto`  — always fires; this is the evidence photo, stored with the
 *                 ticket regardless of whether anything could be read.
 *   • `onPlaka` — fires only on a CONFIDENT read; it prefills the input the
 *                 operator then confirms.
 *
 * A weak read deliberately leaves the field empty rather than filling it with
 * a guess. A bad read should cost a manual entry, never a wrong plate that
 * gets waved through because it looked filled in.
 */
export function PlakaKamera({
  aktif,
  onFoto,
  onPlaka,
}: {
  /** False when plaka_saglayici = 'KAPALI' — capture still works, OCR does not. */
  aktif: boolean
  onFoto: (file: File) => void
  onPlaka: (plaka: string, logId: string | null) => void
}) {
  const inputRef = useRef<HTMLInputElement>(null)
  const [not, setNot] = useState<string | null>(null)
  const [asama, setAsama] = useState<OkumaAsamasi | null>(null)
  const oku = usePlakaOku()

  async function secildi(file: File | undefined) {
    if (!file) return
    setNot(null)
    // Cleared BEFORE the mutation starts, never after it ends: `isPending`
    // flips inside `mutateAsync`, so a stale 'OKUMA' left over from the last
    // capture would flash the second step before the first one had begun.
    setAsama(null)
    onFoto(file)

    if (!aktif) return

    try {
      const sonuc = await oku.mutateAsync({ file, onAsama: setAsama })
      // The log id travels even when the gate suppressed the read, so what the
      // operator types next is still recorded against what the model guessed.
      // Without this the log only ever holds reads we ALREADY trusted, and the
      // threshold could be argued upwards but never downwards — the one number
      // the log exists to settle would be the one it could not measure.
      onPlaka(sonuc.plaka ?? '', sonuc.log_id)
      // Offer the cheap retry before the manual fallback: a suppressed read is
      // usually a distant photo, and this is the one moment the operator has
      // evidence of that. Measured — the same plate read wrong from far away
      // and cleanly from close up.
      if (!sonuc.plaka) setNot('Plaka net okunamadı — yaklaşıp tekrar çekin ya da elle girin.')
    } catch (err) {
      setNot(rpcErrorText(err, 'Plaka okunamadı — elle girin.'))
    }
  }

  // Two named steps read as progress; one long "Okunuyor…" reads as a stall.
  // `HAZIRLIK` is the label whenever pending but unphased, because it is
  // always the first half — the tick between the mutation starting and the
  // first `onAsama` must not flash the wrong step.
  const etiket = oku.isPending
    ? asama === 'OKUMA'
      ? 'Okunuyor…'
      : 'Fotoğraf hazırlanıyor…'
    : aktif
      ? 'Fotoğraf çek ve oku'
      : 'Fotoğraf çek'

  return (
    <div>
      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        // `environment` opens the rear camera directly instead of a gallery
        // picker — one tap fewer with a car waiting.
        capture="environment"
        className="hidden"
        onChange={(e) => {
          void secildi(e.target.files?.[0])
          // Reset so re-selecting the SAME file still fires onChange.
          e.target.value = ''
        }}
      />
      <Button
        type="button"
        // `soft`, not `secondary`: bg-field made this button the same colour
        // as the inputs it sits between, so the one optional action on the
        // entry screen was the hardest thing on it to find.
        variant="soft"
        size="lg"
        block
        loading={oku.isPending}
        onClick={() => inputRef.current?.click()}
      >
        <IconKamera size={20} />
        {etiket}
      </Button>

      {/* The single highest-value thing an operator can do for the read, and
          it costs nothing to say. Only shown when OCR is on — with reading
          off the photo is evidence, and framing it tightly is wrong. */}
      {aktif && !not && (
        <p className="mt-2 text-label text-faint">Plaka kareyi doldursun — yaklaşarak çekin.</p>
      )}
      {not && <p className="mt-2 text-label text-warn">{not}</p>}
    </div>
  )
}
