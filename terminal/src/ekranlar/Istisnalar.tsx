import { useState } from 'preact/hooks'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../../src/lib/plaka'
import { formatGoreceli, istanbulGun } from '../../../src/lib/dates'
import { aciklama, baslangicPlakasi, eylemler, kisaDurum, tahminNotu } from '../../../src/features/istisna/kart'
import { KAMERA_YON_ETIKET, type Istisna } from '../../../src/lib/types'
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
  const [basari, setBasari] = useState<{
    plaka: string
    biletId: string
  } | null>(null)
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

type Mod = null | 'kapat'

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
  function girisAc() {
    setHata(null)
    let girisIso = ''
    if (e.girisAcSaatli) {
      if (!/^d{2}:d{2}$/.test(saat)) return setHata('Giriş saatini yazın (ör. 08:30).')
      girisIso = new Date(`${istanbulGun()}T${saat}:00+03:00`).toISOString()
    }
    let sonuc: { bilet_id: string; plaka: string } | null = null
    calistir(
      () =>
        (e.girisAcSaatli ? istisnaBiletAcSaatli(s, i.id, plaka, girisIso, metin, PLAKA) : istisnaBiletAc(s, i.id, plaka, PLAKA)).then(
          (r) => {
            sonuc = r
          },
        ),
      () => bitti(sonuc ? { plaka: sonuc.plaka, biletId: sonuc.bilet_id } : null),
      setHata,
    )
  }

  // The main app's card (PlakaKontrol): lane · time, photo, one status line,
  // the short "what to do", the plate, then the actions.
  return (
    <Kart>
      <p class="meta">
        {KAMERA_YON_ETIKET[i.yon]} · {formatGoreceli(i.kaynak_zaman || i.created_at)}
      </p>
      <Foto s={s} yol={i.foto_path} etiket={KAMERA_YON_ETIKET[i.yon]} />
      <p class="durum-satiri">
        <span class="durum-nokta" />
        <span class="esnek">{kisaDurum(i)}</span>
      </p>
      <p class="kucuk">
        {not ? `${not} ` : ''}
        {aciklama(i)}
      </p>

      {mod === 'kapat' ? (
        <div class="panel">
          <p class="panel-baslik">Kaydı kapat</p>
          <Alan etiket="Not (isteğe bağlı)" value={metin} maxLength={200} onInput={(ev) => setMetin(ev.currentTarget.value)} />
          <Hata metin={hata} />
          <Dugme
            metin="Kapat"
            mesgul={mesgul}
            buyuk
            onBas={() =>
              calistir(
                () => istisnaKapat(s, i.id, metin),
                () => bitti(null),
                setHata,
              )
            }
          />
          <Dugme metin="Vazgeç" ikincil onBas={() => ac(null)} />
        </div>
      ) : (
        <>
          {e.girisAc || e.girisAcSaatli ? (
            <input
              class="alan-girdi plaka-girdi"
              placeholder="Plakayı yazın"
              value={plaka}
              maxLength={15}
              autoComplete="off"
              spellcheck={false}
              onInput={(ev) => {
                setPlaka(normalizePlaka(ev.currentTarget.value))
                setHata(null)
              }}
              style={{ marginBottom: '12px' }}
            />
          ) : (
            <p class="buyuk-plaka" style={{ textAlign: 'center' }}>
              {i.plaka ? formatPlaka(i.plaka) : '—'}
            </p>
          )}
          {e.girisAcSaatli && (
            <>
              <Alan
                etiket="Giriş saati (bugün, ör. 08:30)"
                inputMode="numeric"
                value={saat}
                maxLength={5}
                onInput={(ev) => setSaat(ev.currentTarget.value)}
              />
              <Alan etiket="Sebep" value={metin} maxLength={200} onInput={(ev) => setMetin(ev.currentTarget.value)} />
            </>
          )}
          <Hata metin={hata} />
          {(e.girisAc || e.girisAcSaatli || e.bileteGit || e.cikis) && (
            <div class="dugme-cifti">
              {(e.girisAc || e.girisAcSaatli) && (
                <Dugme metin="Giriş aç" mesgul={mesgul} devreDisi={!plakaGecerli(plaka)} onBas={girisAc} />
              )}
              {e.bileteGit && <Dugme metin="Bilete git" onBas={() => git({ ekran: 'bilet', biletId: e.bileteGit as string })} />}
              {e.cikis && (
                <Dugme
                  metin="Çıkış"
                  ikincil
                  onBas={() => {
                    aramaKoy(i.plaka || plaka)
                    git({ ekran: 'gise' })
                  }}
                />
              )}
            </div>
          )}
          {e.kapat && (
            <div class="yan-yana">
              <span style={{ display: 'inline-block' }}>
                <button type="button" class="dugme dugme-ikincil" style={{ width: 'auto', padding: '0 20px' }} onClick={() => ac('kapat')}>
                  Kapat
                </button>
              </span>
            </div>
          )}
        </>
      )}
    </Kart>
  )
}
