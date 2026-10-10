/**
 * Getting a short piece of text out of the app: to the clipboard, or to a file.
 *
 * Both are used by the camera pairing screen, where the thing being moved is a
 * setup code that is readable exactly once.
 */

/**
 * Copy, reporting whether it actually happened.
 *
 * `navigator.clipboard` needs a secure context and is refused outright in some
 * embedded webviews, so this returns a boolean rather than assuming success —
 * a "Kopyalandı" message for a copy that silently failed is worse than no
 * button at all. Every caller must also render the text itself, so selecting
 * it by hand stays possible.
 */
export async function panoyaKopyala(metin: string): Promise<boolean> {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(metin)
      return true
    }
  } catch {
    /* blocked, or no permission — fall through and report failure */
  }
  return false
}

/** Hands the browser a small text file to save. */
export function metniIndir(dosyaAdi: string, icerik: string): void {
  const url = URL.createObjectURL(new Blob([icerik], { type: 'text/plain;charset=utf-8' }))
  const a = document.createElement('a')
  a.href = url
  a.download = dosyaAdi
  document.body.appendChild(a)
  a.click()
  a.remove()
  // Not revoked immediately: Safari cancels a download whose object URL is
  // freed in the same tick.
  setTimeout(() => URL.revokeObjectURL(url), 60_000)
}
