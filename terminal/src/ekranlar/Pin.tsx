import { useEffect, useRef, useState } from 'preact/hooks'
import { pinGecerli, terminalOku, terminalYaz } from '../../../src/features/terminal/terminal'
import { Bilgi, Dugme, Ekran, Hata } from '../parcalar'
import { personelListesi, pinIleGir, type TerminalPersonel } from '../oturumIslem'
import type { EkranOzellik } from '../main'

const TUSLAR = [
  ['1', '2', '3'],
  ['4', '5', '6'],
  ['7', '8', '9'],
  ['sil', '0', 'tamam'],
] as const

/**
 * PIN (084): pick your name, type 4 digits. With someone already signed in
 * this is Devral — the server hands the open shift over.
 */
export function Pin({ s, depo, git }: EkranOzellik) {
  const terminal = terminalOku(depo)
  const devral = s.oturum() !== null
  const [liste, setListe] = useState<TerminalPersonel[] | null>(null)
  const [listeHata, setListeHata] = useState<string | null>(null)
  const [secilen, setSecilen] = useState<TerminalPersonel | null>(null)
  const [pin, setPin] = useState('')
  const [mesgul, setMesgul] = useState(false)
  const [hata, setHata] = useState<string | null>(null)
  // Taps can land before the screen redraws (slow P2): read the latest PIN and
  // the in-flight flag from refs, not from the last render (bench 28.11).
  const pinSimdi = useRef('')
  const gonderiliyor = useRef(false)
  function pinYaz(p: string) {
    pinSimdi.current = p
    setPin(p)
  }

  function listeAl() {
    if (!terminal) return
    setListeHata(null)
    personelListesi(s, terminal).then(setListe, (e: Error) => setListeHata(e.message))
  }
  useEffect(listeAl, [])

  function gir(p: string) {
    if (!terminal || !secilen || gonderiliyor.current) return
    gonderiliyor.current = true
    setMesgul(true)
    setHata(null)
    pinIleGir(s, terminal, secilen.id, p, { terminalYaz, pinGecerli }).then(
      () => git({ ekran: 'gise' }),
      (e: Error) => {
        gonderiliyor.current = false
        setMesgul(false)
        pinYaz('')
        setHata(e.message)
      },
    )
  }

  function bas(t: string) {
    if (gonderiliyor.current) return
    setHata(null)
    const pin = pinSimdi.current
    if (t === 'sil') pinYaz(pin.slice(0, -1))
    else if (t === 'tamam') gir(pin)
    else if (pin.length < 4) {
      const yeni = pin + t
      pinYaz(yeni)
      if (yeni.length === 4) gir(yeni)
    }
  }

  const ust = devral ? (
    <button type="button" class="ust-dugme" onClick={() => git({ ekran: 'gise' })}>
      Vazgeç
    </button>
  ) : null

  if (!secilen) {
    return (
      <Ekran baslik={devral ? 'Devral' : 'Kim çalışıyor?'} ust={ust}>
        {devral && <Bilgi metin="Vardiyayı devralacak kişiyi seçin." />}
        <Hata metin={listeHata} />
        {listeHata && <Dugme metin="Tekrar dene" onBas={listeAl} ikincil />}
        {!liste && !listeHata && <Bilgi metin="Yükleniyor…" />}
        {liste && liste.length === 0 && <Bilgi metin="Personel yok. Yönetici, Personel ekranından PIN versin." />}
        {liste &&
          liste.map((p) => (
            <button key={p.id} type="button" class="liste-dugme" onClick={() => setSecilen(p)}>
              {p.ad_soyad}
            </button>
          ))}
      </Ekran>
    )
  }

  return (
    <Ekran baslik={secilen.ad_soyad} ust={ust}>
      <p class="pin-noktalar" aria-label={`${pin.length} rakam girildi`}>
        {[0, 1, 2, 3].map((i) => (
          <span key={i} class={i < pin.length ? 'pin-nokta dolu' : 'pin-nokta'} />
        ))}
      </p>
      <Hata metin={hata} />
      {mesgul && <Bilgi metin="Giriş yapılıyor…" />}
      <div class="tus-takimi">
        {TUSLAR.map((satir, i) => (
          <div key={i} class="tus-satir">
            {satir.map((t) => (
              <button
                key={t}
                type="button"
                class={t === 'sil' || t === 'tamam' ? 'tus tus-ikincil' : 'tus'}
                disabled={mesgul || (t === 'tamam' && pin.length !== 4)}
                onClick={() => bas(t)}
              >
                {t === 'sil' ? 'Sil' : t === 'tamam' ? 'Giriş' : t}
              </button>
            ))}
          </div>
        ))}
      </div>
      <Dugme
        metin="Başka kişi"
        onBas={() => {
          setSecilen(null)
          pinYaz('')
          setHata(null)
        }}
        ikincil
      />
    </Ekran>
  )
}
