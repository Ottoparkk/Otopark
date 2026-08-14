import { useRef, useState } from 'react'
import { Button } from '../../components/ui/primitives'
import { IconKamera } from '../../components/ui/icons'
import { usePlakaOku } from './api'
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
  const oku = usePlakaOku()

  async function secildi(file: File | undefined) {
    if (!file) return
    setNot(null)
    onFoto(file)

    if (!aktif) return

    try {
      const sonuc = await oku.mutateAsync(file)
      if (sonuc.plaka) {
        onPlaka(sonuc.plaka, sonuc.log_id)
      } else {
        setNot('Plaka net okunamadı — elle girin.')
      }
    } catch (err) {
      setNot(rpcErrorText(err, 'Plaka okunamadı — elle girin.'))
    }
  }

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
        variant="secondary"
        size="lg"
        block
        loading={oku.isPending}
        onClick={() => inputRef.current?.click()}
      >
        <IconKamera size={20} />
        {oku.isPending ? 'Okunuyor…' : aktif ? 'Fotoğraf çek ve oku' : 'Fotoğraf çek'}
      </Button>

      {not && <p className="mt-2 text-label text-warn">{not}</p>}
    </div>
  )
}
