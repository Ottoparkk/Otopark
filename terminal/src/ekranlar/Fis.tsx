import { useEffect, useState } from 'preact/hooks'
import { girisFisi, sureMetni, type FisSatiri } from '../../../src/features/fis/fisIcerik'
import { fisTahminSecenekleri, parcala } from '../../../src/features/fis/fisSecenek'
import { kademeAraliklari } from '../../../src/features/finans/kademe'
import { formatTL } from '../../../src/lib/money'
import { formatSaat, formatTam } from '../../../src/lib/dates'
import { ucretsizEtiket } from '../../../src/lib/ucretsiz'
import { formatPlaka } from '../../../src/lib/plaka'
import { Bilgi, Dugme, Ekran, Hata } from '../parcalar'
import { fisVerisi, girisFisiBas, type FisVerisi, type FisYardimcilari } from '../fisIslem'
import { uyariAl } from './Giris'
import type { EkranOzellik } from '../main'

const Y: FisYardimcilari = {
  fis: { tl: formatTL, saat: formatSaat, tam: formatTam, ucretsizEtiket, plaka: formatPlaka },
  girisFisi,
  sureMetni,
  fisTahminSecenekleri,
  parcala,
  kademeAraliklari,
}

/** The fiş's lines; the same markup is the preview and the paper. */
function FisKagidi({ satirlar }: { satirlar: FisSatiri[] }) {
  return (
    <div class="fis-kagit">
      {satirlar.map((s, i) => {
        switch (s.t) {
          case 'baslik':
            return <p key={i} class="fis-baslik">{s.metin}</p>
          case 'alt':
            return <p key={i} class="fis-alt">{s.metin}</p>
          case 'buyuk':
            return <p key={i} class="fis-buyuk">{s.metin}</p>
          case 'satir':
            return (
              <p key={i} class={s.kalin ? 'fis-satir fis-kalin' : 'fis-satir'}>
                <span>{s.sol}</span>
                <span class="fis-sag">{s.sag}</span>
              </p>
            )
          case 'cizgi':
            return <hr key={i} class="fis-cizgi" />
          case 'not':
            return <p key={i} class="fis-not">{s.metin}</p>
        }
      })}
    </div>
  )
}

/**
 * The entry fiş (spec 2026-11-28): "Müşteri ne kadar kalacak?", then Yazdır —
 * the number is taken from the server first, the paper is drawn with it,
 * then Chrome's print screen opens (one tap on Yazdır there, as tested 25.11).
 */
export function Fis({ s, git, biletId }: EkranOzellik & { biletId: string }) {
  const [uyari] = useState(uyariAl)
  const [veri, setVeri] = useState<FisVerisi | null>(null)
  const [yukHata, setYukHata] = useState<string | null>(null)
  const [tahminDk, setTahminDk] = useState<number | null>(null)
  const [kagit, setKagit] = useState<FisSatiri[] | null>(null)
  const [yazdir, setYazdir] = useState(false)
  const [basildi, setBasildi] = useState(false)
  const [mesgul, setMesgul] = useState(false)
  const [hata, setHata] = useState<string | null>(null)

  function yukle() {
    setYukHata(null)
    fisVerisi(s, biletId, Y).then(setVeri, (e: Error) => setYukHata(e.message))
  }
  useEffect(yukle, [biletId])

  // Print only after the paper with the server's number is on the page.
  useEffect(() => {
    if (!yazdir) return
    setYazdir(false)
    window.print()
    setBasildi(true)
  }, [yazdir])

  const kurus = tahminDk === null || !veri ? undefined : veri.fiyatlar.get(tahminDk)
  const tahmin = tahminDk !== null && kurus !== undefined ? { dakika: tahminDk, kurus } : null

  function bas() {
    if (!veri) return
    setMesgul(true)
    setHata(null)
    girisFisiBas(s, { bilet: veri.bilet, otopark: veri.otopark, tahmin }, () => new Date().toISOString(), Y).then(
      (satirlar) => {
        setMesgul(false)
        setKagit(satirlar)
        setYazdir(true)
      },
      (e: Error) => {
        setMesgul(false)
        setHata(e.message)
      },
    )
  }

  const onizleme = veri
    ? Y.girisFisi({ otopark: veri.otopark, bilet: veri.bilet, basim: 1, basimAt: new Date().toISOString(), tahmin }, Y.fis)
    : null
  const ust = (
    <button type="button" class="ust-dugme" onClick={() => git({ ekran: 'gise' })}>
      Gişe
    </button>
  )

  return (
    <>
      <Ekran baslik="Giriş fişi" ust={ust}>
        <Bilgi metin={uyari} />
        <Hata metin={yukHata} />
        {yukHata && <Dugme metin="Tekrar dene" onBas={yukle} ikincil />}
        {!veri && !yukHata && <Bilgi metin="Yükleniyor…" />}
        {veri && veri.secenekler.length > 0 && (
          <div class="secenekler">
            <p class="alan-etiket">Müşteri ne kadar kalacak?</p>
            <button
              type="button"
              class={tahminDk === null ? 'secenek secili' : 'secenek'}
              onClick={() => setTahminDk(null)}
            >
              <span>Söylemedi</span>
            </button>
            {veri.secenekler.map((x) => {
              const f = veri.fiyatlar.get(x.dakika)
              return (
                <button
                  key={x.dakika}
                  type="button"
                  class={tahminDk === x.dakika ? 'secenek secili' : 'secenek'}
                  disabled={f === undefined}
                  onClick={() => setTahminDk(x.dakika)}
                >
                  <span>{x.etiket}</span>
                  <span class="secenek-fiyat">{f === undefined ? '—' : formatTL(f)}</span>
                </button>
              )
            })}
          </div>
        )}
        {onizleme && (
          <div class="onizleme">
            <FisKagidi satirlar={kagit ?? onizleme} />
          </div>
        )}
        <Hata metin={hata} />
        {basildi && <Bilgi metin="Fiş yazdırıldı. Kâğıt çıkmadıysa tekrar yazdırın." />}
        {veri && <Dugme metin={basildi ? 'Tekrar yazdır' : 'Yazdır'} onBas={bas} mesgul={mesgul} buyuk />}
        {basildi && <Dugme metin="Gişe'ye dön" onBas={() => git({ ekran: 'gise' })} ikincil />}
      </Ekran>
      {kagit && (
        <div class="fis-baski" aria-hidden="true">
          <FisKagidi satirlar={kagit} />
        </div>
      )}
    </>
  )
}
