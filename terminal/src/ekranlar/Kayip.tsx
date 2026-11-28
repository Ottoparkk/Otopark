import { useRef, useState } from 'preact/hooks'
import { normalizePlaka, plakaGecerli } from '../../../src/lib/plaka'
import { yeniKimlik } from '../../../src/lib/fotoYolu'
import type { OdemeYontemi } from '../../../src/lib/types'
import { Alan, Dugme, Ekran, Geri, Hata, YontemSecici, useTekSefer } from '../parcalar'
import { kayipBilet } from '../giseIslem'
import type { EkranOzellik } from '../main'

/**
 * Kayıp bilet (owner, stage 2): a car with no record pays the tariff's lost
 * ticket fee; the server opens and closes the ticket in one go
 * (kayip_bilet_tahsil). One operation id per form, so a retry never charges
 * twice.
 */
export function Kayip({ s, git }: EkranOzellik) {
  const [plaka, setPlaka] = useState('')
  const [yontem, setYontem] = useState<OdemeYontemi | null>(null)
  const [hata, setHata] = useState<string | null>(null)
  const [mesgul, calistir] = useTekSefer()
  const islemId = useRef(yeniKimlik())
  return (
    <Ekran baslik="Kayıp bilet" ust={<Geri metin="Gişe" onBas={() => git({ ekran: 'gise' })} />}>
      <p class="bilgi">Girişi kaydedilmemiş bir araç için tarifedeki kayıp bilet ücreti tahsil edilir.</p>
      <Alan
        etiket="Plaka"
        class="alan-girdi plaka-girdi"
        value={plaka}
        maxLength={15}
        autoComplete="off"
        onInput={(e) => setPlaka(normalizePlaka(e.currentTarget.value))}
      />
      <p class="alan-etiket">Ödeme yöntemi</p>
      <YontemSecici deger={yontem} sec={setYontem} />
      <Hata metin={hata} />
      <Dugme
        metin="Tahsil et"
        mesgul={mesgul}
        devreDisi={!plakaGecerli(plaka) || !yontem}
        buyuk
        onBas={() => {
          let id = ''
          calistir(
            () =>
              kayipBilet(s, plaka, yontem as OdemeYontemi, islemId.current, { normalizePlaka, plakaGecerli }).then((b) => {
                id = b
              }),
            () => {
              islemId.current = yeniKimlik()
              git({ ekran: 'cfis', biletId: id })
            },
            setHata,
          )
        }}
      />
    </Ekran>
  )
}
