import { useState } from 'preact/hooks'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../../src/lib/plaka'
import { formatTam, istanbulGun } from '../../../src/lib/dates'
import { aciklama, baslangicPlakasi, eylemler, kisaDurum, tahminNotu } from '../../../src/features/istisna/kart'
import type { Istisna } from '../../../src/lib/types'
import { Alan, Bilgi, Dugme, Ekran, Foto, Geri, Hata, Kart, useTekSefer, useYukle } from '../parcalar'
import { bekleyenIstisnalar, istisnaBiletAc, istisnaBiletAcSaatli, istisnaKapat } from '../istisnaIslem'
import { aramaKoy } from './Gise'
import type { EkranOzellik } from '../main'

const PLAKA = { normalizePlaka, plakaGecerli }

/**
 * Çözülmemiş kayıtlar, waiting ones (owner: "very important"): the camera
 * events it could not match, with their photo and the same actions as the
 * main app — Giriş aç, Giriş aç with a typed time, Çıkış (Gişe search),
 * the ticket, Kapat. Delete stays the Yönetici's.
 */
export function Istisnalar({ s, git }: EkranOzellik) {
  const y = useYukle(() => bekleyenIstisnalar(s), [])
  const [basari, setBasari] = useState<{ plaka: string; biletId: string } | null>(null)
  return (
    <Ekran baslik="Çözülmemiş kayıtlar" ust={<Geri metin="Gişe" onBas={() => git({ ekran: 'gise' })} />}>
      <p class="bilgi">Kameranın bilet açamadığı araçlar</p>
      {basari && (
        <Kart ton="basari">
          <p>{formatPlaka(basari.plaka)} girişi açıldı.</p>
          <Dugme metin="Bileti aç" ikincil onBas={() => git({ ekran: 'bilet', biletId: basari.biletId })} />
        </Kart>
      )}
      <Hata metin={y.hata} />
      {!y.veri && !y.hata && <Bilgi metin="Yükleniyor…" />}
      {y.veri && y.veri.length === 0 && <Bilgi metin="Bekleyen kayıt yok." />}
      {y.veri &&
        y.veri.map((i) => (
          <IstisnaKarti
            key={i.id}
            i={i}
            s={s}
            git={git}
            bitti={(r) => {
              if (r) setBasari(r)
              y.yenile()
            }}
          />
        ))}
    </Ekran>
  )
}

type Mod = null | 'giris' | 'saatli' | 'kapat'

function IstisnaKarti({
  i,
  s,
  git,
  bitti,
}: {
  i: Istisna
  s: EkranOzellik['s']
  git: EkranOzellik['git']
  bitti: (r: { plaka: string; biletId: string } | null) => void
}) {
  const e = eylemler(i)
  const [mod, setMod] = useState<Mod>(null)
  const [plaka, setPlaka] = useState(baslangicPlakasi(i))
  const [saat, setSaat] = useState('')
  const [metin, setMetin] = useState('')
  const [hata, setHata] = useState<string | null>(null)
  const [mesgul, calistir] = useTekSefer()
  const not = tahminNotu(i)

  function ac(m: Mod) {
    setMod(m)
    setHata(null)
    setMetin('')
  }
  return (
    <Kart>
      <Foto s={s} yol={i.foto_path} etiket={i.yon === 'CIKIS' ? 'Çıkış' : i.yon === 'GIRIS' ? 'Giriş' : 'Kapı'} />
      <p class="kart-baslik">{kisaDurum(i)}</p>
      <p class="arac-plaka">{i.plaka ? formatPlaka(i.plaka) : 'Plaka yok'}</p>
      <p class="arac-alt">{formatTam(i.kaynak_zaman || i.created_at)}</p>
      <p>{aciklama(i)}</p>
      {not && <p class="bilgi">{not}</p>}

      {(mod === 'giris' || mod === 'saatli') && (
        <div class="panel">
          <p class="panel-baslik">{mod === 'saatli' ? 'Giriş aç (saatli)' : 'Giriş aç'}</p>
          <Alan
            etiket="Plaka"
            class="alan-girdi plaka-girdi"
            value={plaka}
            maxLength={15}
            onInput={(ev) => setPlaka(normalizePlaka(ev.currentTarget.value))}
          />
          {mod === 'saatli' && (
            <>
              <Alan etiket="Giriş saati (bugün, ör. 08:30)" inputMode="numeric" value={saat} maxLength={5} onInput={(ev) => setSaat(ev.currentTarget.value)} />
              <Alan etiket="Sebep" value={metin} maxLength={200} onInput={(ev) => setMetin(ev.currentTarget.value)} />
            </>
          )}
          <Hata metin={hata} />
          <Dugme
            metin="Giriş aç"
            mesgul={mesgul}
            buyuk
            onBas={() => {
              setHata(null)
              let girisIso = ''
              if (mod === 'saatli') {
                if (!/^\d{2}:\d{2}$/.test(saat)) return setHata('Giriş saatini yazın (ör. 08:30).')
                girisIso = new Date(`${istanbulGun()}T${saat}:00+03:00`).toISOString()
              }
              let sonuc: { bilet_id: string; plaka: string } | null = null
              calistir(
                () =>
                  (mod === 'saatli'
                    ? istisnaBiletAcSaatli(s, i.id, plaka, girisIso, metin, PLAKA)
                    : istisnaBiletAc(s, i.id, plaka, PLAKA)
                  ).then((r) => {
                    sonuc = r
                  }),
                () => {
                  setMod(null)
                  bitti(sonuc ? { plaka: sonuc.plaka, biletId: sonuc.bilet_id } : null)
                },
                setHata,
              )
            }}
          />
          <Dugme metin="Vazgeç" ikincil onBas={() => ac(null)} />
        </div>
      )}
      {mod === 'kapat' && (
        <div class="panel">
          <p class="panel-baslik">Kaydı kapat</p>
          <Alan etiket="Not (isteğe bağlı)" value={metin} maxLength={200} onInput={(ev) => setMetin(ev.currentTarget.value)} />
          <p class="bilgi">Kayıt silinmez. Yönetici onu Kapatılan sekmesinde görür.</p>
          <Hata metin={hata} />
          <Dugme
            metin="Kapat"
            mesgul={mesgul}
            buyuk
            onBas={() => calistir(() => istisnaKapat(s, i.id, metin), () => bitti(null), setHata)}
          />
          <Dugme metin="Vazgeç" ikincil onBas={() => ac(null)} />
        </div>
      )}
      {mod === null && (
        <>
          {e.girisAc && <Dugme metin="Giriş aç" onBas={() => ac('giris')} />}
          {e.girisAcSaatli && <Dugme metin="Giriş aç" onBas={() => ac('saatli')} />}
          {e.bileteGit && <Dugme metin="Bileti aç" onBas={() => git({ ekran: 'bilet', biletId: e.bileteGit as string })} />}
          {e.cikis && (
            <Dugme
              metin="Çıkış"
              ikincil
              onBas={() => {
                aramaKoy(i.plaka || baslangicPlakasi(i))
                git({ ekran: 'gise' })
              }}
            />
          )}
          {e.kapat && <Dugme metin="Kapat" ikincil onBas={() => ac('kapat')} />}
        </>
      )}
      {mod === null && <Hata metin={hata} />}
    </Kart>
  )
}
