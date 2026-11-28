import { useRef, useState } from 'preact/hooks'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../../src/lib/plaka'
import { fotoYolu, yeniKimlik } from '../../../src/lib/fotoYolu'
import { Alan, Bilgi, Dugme, Ekran, Hata } from '../parcalar'
import { girisAc, plakaOku, type OkumaSonucu } from '../girisIslem'
import { fotoHazirla } from '../foto'
import type { EkranOzellik } from '../main'

const GIRIS_ARACLARI = { normalizePlaka, plakaGecerli, fotoYolu: (yon: 'giris', p: string) => fotoYolu(yon, p) }

// The upload warning travels to the fiş screen with the ticket.
let bekleyenUyari: string | null = null
export function uyariAl(): string | null {
  const u = bekleyenUyari
  bekleyenUyari = null
  return u
}

type FotoDurum = 'YOK' | 'HAZIRLIK' | 'OKUMA' | 'HAZIR'

/**
 * Giriş (spec 2026-11-28): plate, optional photo read by the camera, optional
 * vehicle note, Giriş aç. The read plate only fills the field; a person
 * confirms it. A failed read never blocks typing the plate.
 */
export function Giris({ s, git }: EkranOzellik) {
  const [plaka, setPlaka] = useState('')
  const [aracBilgi, setAracBilgi] = useState('')
  const [foto, setFoto] = useState<FotoDurum>('YOK')
  const [kanit, setKanit] = useState<Blob | null>(null)
  const [okuma, setOkuma] = useState<OkumaSonucu | null>(null)
  const [bilgi, setBilgi] = useState<string | null>(null)
  const [mesgul, setMesgul] = useState(false)
  const [hata, setHata] = useState<string | null>(null)
  const islemId = useRef(yeniKimlik())

  function fotoSecildi(e: Event) {
    const girdi = e.currentTarget as HTMLInputElement
    const dosya = girdi.files && girdi.files[0]
    girdi.value = ''
    if (!dosya) return
    setHata(null)
    setBilgi(null)
    setFoto('HAZIRLIK')
    let hazir = false
    fotoHazirla(dosya)
      .then((h) => {
        hazir = true
        setKanit(h.kanit)
        setFoto('OKUMA')
        return plakaOku(s, h.okumaBase64)
      })
      .then(
        (o) => {
          setOkuma(o)
          setFoto('HAZIR')
          if (o.plaka) {
            setPlaka(normalizePlaka(o.plaka))
            setBilgi('Kameranın okuduğu plaka. Kontrol edin.')
          } else {
            setBilgi('Plaka okunamadı. Yazın.')
          }
          const alan = document.getElementById('plaka-alani')
          if (alan) alan.focus()
        },
        (err: Error) => {
          // A failed read keeps the photo for the ticket; a failed shrink has none.
          setFoto(hazir ? 'HAZIR' : 'YOK')
          setBilgi(`${err.message} Plakayı yazın.`)
        },
      )
  }

  function ac() {
    setMesgul(true)
    setHata(null)
    girisAc(s, { plaka, islemId: islemId.current, kanit, okuma, aracBilgi }, GIRIS_ARACLARI).then(
      (r) => {
        islemId.current = yeniKimlik()
        bekleyenUyari = r.uyari
        git({ ekran: 'fis', biletId: r.biletId })
      },
      (err: Error) => {
        setMesgul(false)
        setHata(err.message)
      },
    )
  }

  const fotoMetni =
    foto === 'HAZIRLIK' ? 'Hazırlanıyor…' : foto === 'OKUMA' ? 'Okunuyor…' : foto === 'HAZIR' ? 'Yeniden çek' : 'Fotoğraf çek'
  const ust = (
    <button type="button" class="ust-dugme" onClick={() => git({ ekran: 'gise' })}>
      Geri
    </button>
  )

  return (
    <Ekran baslik="Giriş" ust={ust}>
      <label class={foto === 'HAZIRLIK' || foto === 'OKUMA' ? 'dugme dugme-ikincil dugme-dosya mesgul' : 'dugme dugme-ikincil dugme-dosya'}>
        {fotoMetni}
        <input
          type="file"
          accept="image/*"
          capture="environment"
          class="gizli-dosya"
          disabled={foto === 'HAZIRLIK' || foto === 'OKUMA' || mesgul}
          onChange={fotoSecildi}
        />
      </label>
      <Bilgi metin={bilgi} />
      <Alan
        etiket="Plaka"
        id="plaka-alani"
        value={plaka}
        autoCapitalize="characters"
        autoComplete="off"
        spellcheck={false}
        maxLength={15}
        onInput={(e) => setPlaka(normalizePlaka(e.currentTarget.value))}
      />
      {plaka && plakaGecerli(plaka) && <p class="plaka-onizleme">{formatPlaka(plaka)}</p>}
      <Alan
        etiket="Araç bilgisi (isteğe bağlı)"
        value={aracBilgi}
        maxLength={60}
        onInput={(e) => setAracBilgi(e.currentTarget.value)}
      />
      <Hata metin={hata} />
      <Dugme metin="Giriş aç" onBas={ac} mesgul={mesgul} devreDisi={!plakaGecerli(plaka)} buyuk />
    </Ekran>
  )
}
