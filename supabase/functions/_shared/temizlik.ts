/**
 * Photo cleanup loop — the PURE half of foto-temizle (043).
 *
 * No imports and no I/O: listing and deleting are passed in, so
 * tests/temizlik.check.mjs runs this exact file with plain Node. The Edge
 * Function supplies the real calls: `foto_temizlik_listesi` (RPC) to list and
 * the Storage API's `remove()` to delete.
 *
 * Why it exists: 025's nightly job deleted expired photos with SQL, which
 * removes only the metadata row — the file stayed in the bucket, orphaned,
 * still counted against the free 1 GB and kept past the retention (KVKK).
 *
 * The loop never runs forever and never swallows an error: a failed list or
 * delete stops it with `hata` (the function then alerts the Yönetici), and a
 * delete that reports success but leaves the same files listed is treated as
 * a failure too. The round cap and the time budget stop it cleanly — what is
 * left is simply picked up the next night.
 */

/** Most names per Storage `remove()` call (Supabase's own limit). */
export const TEMIZLIK_PARCA = 1000

/** Rounds per night: up to 20,000 files, far above a day's photos. */
export const TEMIZLIK_EN_COK_TUR = 20

/** Stop starting new rounds after this (the function's wall limit is 150 s). */
export const TEMIZLIK_BUTCE_MS = 100_000

export type TemizlikSonucu = {
  /** Files Storage reported as deleted. */
  silinen: number
  /** Delete calls made. */
  tur: number
  /** Why it stopped early, or null. Never contains file names. */
  hata: string | null
  /** True when nothing expired is left. */
  bitti: boolean
}

function mesaj(e: unknown): string {
  return (e instanceof Error ? e.message : String(e)).slice(0, 200)
}

export async function fotoTemizle(o: {
  listele: (limit: number) => Promise<string[]>
  /** Deletes the given names; resolves to how many were deleted, throws on error. */
  sil: (adlar: string[]) => Promise<number>
  enCokTur?: number
  butceMs?: number
  simdi?: () => number
}): Promise<TemizlikSonucu> {
  const enCokTur = o.enCokTur ?? TEMIZLIK_EN_COK_TUR
  const butceMs = o.butceMs ?? TEMIZLIK_BUTCE_MS
  const simdi = o.simdi ?? Date.now
  const bas = simdi()
  let silinen = 0
  let tur = 0
  let onceki = new Set<string>()

  while (tur < enCokTur) {
    if (simdi() - bas >= butceMs) return { silinen, tur, hata: null, bitti: false }

    let adlar: string[]
    try {
      adlar = await o.listele(TEMIZLIK_PARCA)
    } catch (e) {
      return { silinen, tur, hata: `Liste alınamadı: ${mesaj(e)}`, bitti: false }
    }
    if (adlar.length === 0) return { silinen, tur, hata: null, bitti: true }

    // The last round's files are listed again: the "successful" delete did
    // not delete them. Going on would loop on the same files all night.
    if (adlar.some((a) => onceki.has(a))) {
      return {
        silinen,
        tur,
        hata: 'Silinen dosyalar yeniden listelendi — Storage silmedi.',
        bitti: false,
      }
    }

    const parca = adlar.slice(0, TEMIZLIK_PARCA)
    try {
      silinen += await o.sil(parca)
    } catch (e) {
      return { silinen, tur, hata: `Silinemedi: ${mesaj(e)}`, bitti: false }
    }
    tur += 1
    onceki = new Set(parca)
  }
  return { silinen, tur, hata: null, bitti: false }
}
