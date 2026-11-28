/**
 * Shrink a camera photo on the P2 (browser only). The same two sizes the app
 * uses and that "Deneme 4" timed on the P2 (1.2 s): 1568 px JPEG 0.92 for the
 * plate read, 1280 px JPEG 0.8 for the stored photo. Canvas only — no
 * File.arrayBuffer (Chrome 76), no image library.
 */
import { hedefBoyut, KANIT_KENAR, OKUMA_KENAR } from '../../src/lib/fotoBoyut'

function resimAc(dosya: File): Promise<HTMLImageElement> {
  return new Promise((coz, reddet) => {
    const url = URL.createObjectURL(dosya)
    const img = new Image()
    img.onload = () => {
      URL.revokeObjectURL(url)
      coz(img)
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      reddet(new Error('Fotoğraf açılamadı. Tekrar çekin.'))
    }
    img.src = url
  })
}

function ciz(img: HTMLImageElement, sinir: number): HTMLCanvasElement {
  const b = hedefBoyut(img.naturalWidth, img.naturalHeight, sinir)
  const c = document.createElement('canvas')
  c.width = b.en
  c.height = b.boy
  const ctx = c.getContext('2d')
  if (!ctx) throw new Error('Fotoğraf hazırlanamadı.')
  ctx.drawImage(img, 0, 0, b.en, b.boy)
  return c
}

function blobAl(c: HTMLCanvasElement, kalite: number): Promise<Blob> {
  return new Promise((coz, reddet) => {
    c.toBlob((b) => (b ? coz(b) : reddet(new Error('Fotoğraf hazırlanamadı.'))), 'image/jpeg', kalite)
  })
}

export async function fotoHazirla(dosya: File): Promise<{ okumaBase64: string; kanit: Blob }> {
  const img = await resimAc(dosya)
  const okuma = ciz(img, OKUMA_KENAR).toDataURL('image/jpeg', 0.92)
  const kanit = await blobAl(ciz(img, KANIT_KENAR), 0.8)
  return { okumaBase64: okuma.slice(okuma.indexOf(',') + 1), kanit }
}
