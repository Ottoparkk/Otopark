import { useState } from 'preact/hooks'
import { formatPlaka } from '../../../src/lib/plaka'
import { formatTL, kurusToInput, parseTLToKurus } from '../../../src/lib/money'
import { formatTam, istanbulGun } from '../../../src/lib/dates'
import { abonmanAra, abonmanGruplari, kalanRozeti, kisaTarih } from '../../../src/features/abonman/liste'
import { ODEME_ETIKET, type AbonmanDurum, type OdemeYontemi } from '../../../src/lib/types'
import { Alan, Bilgi, Cip, Dugme, Ekran, Geri, Hata, Kart, OdemeCip, Rozet, Satir, YontemSecici, useTekSefer, useYukle } from '../parcalar'
import { abonmanAl, abonmanTahsil, abonmanTahsilatlari, abonmanlar } from '../abonmanIslem'
import type { EkranOzellik } from '../main'

/** Abonman list like the main app's: Aktif / Doldu, search, grouped by payment day. */
export function Abonman({ s, git }: EkranOzellik) {
  const y = useYukle(() => abonmanlar(s), [], 60000)
  const [filtre, setFiltre] = useState<AbonmanDurum>('AKTIF')
  const [q, setQ] = useState('')
  const bugun = istanbulGun()
  const liste = abonmanAra(
    (y.veri || []).filter((a) => a.durum === filtre),
    q,
  )
  const gruplar = abonmanGruplari(liste, filtre, 'VARSAYILAN')
  return (
    <Ekran baslik="Abonman">
      <div class="cipler">
        {(['AKTIF', 'DOLDU'] as const).map((f) => (
          <button key={f} type="button" class={filtre === f ? 'cip secili' : 'cip'} onClick={() => setFiltre(f)}>
            {f === 'AKTIF' ? 'Aktif' : 'Doldu'}
          </button>
        ))}
      </div>
      <Alan etiket="Plaka ya da isim ara" value={q} autoComplete="off" onInput={(e) => setQ(e.currentTarget.value)} />
      <Hata metin={y.hata} />
      {!y.veri && !y.hata && <Bilgi metin="Yükleniyor…" />}
      {y.veri && liste.length === 0 && <Bilgi metin={filtre === 'AKTIF' ? 'Abonman yok.' : 'Dolan abonman yok.'} />}
      {gruplar.map((g) => (
        <div key={String(g.gun)}>
          {g.gun !== null && (
            <p class="bolum">
              Ayın {g.gun}. günü · {g.adet} abonman
            </p>
          )}
          {g.ogeler.map((a) => {
            const rozet = kalanRozeti(a, bugun)
            return (
              <button key={a.id} type="button" class="arac" onClick={() => git({ ekran: 'abonmanDetay', id: a.id })}>
                <span class="esnek">
                  <span class="arac-plaka">{formatPlaka(a.plaka)}</span>
                  <span class="arac-alt" style={{ display: 'block' }}>
                    {a.musteri_ad} · bitiş {kisaTarih(a.bitis)}
                  </span>
                  {rozet && <Rozet metin={rozet} ton="uyari" />}
                </span>
                <span class="arac-sag">{formatTL(a.ucret_kurus, { decimals: 0 })}</span>
              </button>
            )
          })}
        </div>
      ))}
    </Ekran>
  )
}

/** One abonman: details, "Tahsilat al" (every staff role, 062), its payments. */
export function AbonmanDetay({ s, git, id }: EkranOzellik & { id: string }) {
  const y = useYukle(() => Promise.all([abonmanAl(s, id), abonmanTahsilatlari(s, id)]), [id], 60000)
  const [acik, setAcik] = useState(false)
  const [tutar, setTutar] = useState('')
  const [yontem, setYontem] = useState<OdemeYontemi | null>(null)
  const [yenile, setYenile] = useState(true)
  const [hata, setHata] = useState<string | null>(null)
  const [basari, setBasari] = useState<string | null>(null)
  const [mesgul, calistir] = useTekSefer()
  const geri = <Geri onBas={() => git({ ekran: 'abonman' })} />
  if (!y.veri) {
    return (
      <Ekran baslik="Abonman" ust={geri}>
        <Hata metin={y.hata} />
        {!y.hata && <Bilgi metin="Yükleniyor…" />}
      </Ekran>
    )
  }
  const [a, tahsilatlar] = y.veri
  const rozet = kalanRozeti(a, istanbulGun())
  const kurus = parseTLToKurus(tutar)
  return (
    <Ekran baslik={formatPlaka(a.plaka)} ust={geri}>
      <Kart>
        <div class="plaka-satiri">
          <div>
            <p class="ikili-v">{formatTL(a.ucret_kurus, { decimals: 0 })}</p>
            <p class="ikili-k">aylık ücret</p>
          </div>
          {a.durum === 'IPTAL' ? (
            <Cip metin="İptal" ton="notr" />
          ) : a.durum === 'DOLDU' ? (
            <Cip metin="Süresi doldu" ton="notr" />
          ) : rozet ? (
            <Cip metin={rozet} ton="uyari" />
          ) : (
            <Cip metin="Aktif" ton="basari" />
          )}
        </div>
        <Satir k="Müşteri" v={a.musteri_ad || 'İsimsiz müşteri'} />
        <Satir k="Geçerli" v={`${kisaTarih(a.bitis)} tarihine kadar`} />
        {a.musteri_tel && <Satir k="Telefon" v={a.musteri_tel} />}
        {a.notlar && <Satir k="Not" v={a.notlar} />}
      </Kart>
      {basari && (
        <Kart ton="basari">
          <p>{basari}</p>
        </Kart>
      )}
      {a.durum !== 'IPTAL' &&
        (acik ? (
          <div class="panel">
            <p class="panel-baslik">Abonman tahsilatı</p>
            <Alan etiket="Tutar (₺)" inputMode="decimal" value={tutar} onInput={(e) => setTutar(e.currentTarget.value)} />
            <p class="alan-etiket">Ödeme yöntemi</p>
            <YontemSecici deger={yontem} sec={setYontem} />
            <button type="button" class={yenile ? 'anahtar acik' : 'anahtar'} onClick={() => setYenile(!yenile)}>
              <span>Süreyi bir ay uzat</span>
              <strong>{yenile ? 'Evet' : 'Hayır'}</strong>
            </button>
            <p class="bilgi">Tahsilat Yönetici onayına gider. Tahsilat otomatik tekrarlanmaz.</p>
            <Hata metin={hata} />
            <Dugme
              metin={kurus ? `${formatTL(kurus)} Tahsil et` : 'Tahsil et'}
              mesgul={mesgul}
              devreDisi={!kurus || !yontem}
              buyuk
              onBas={() =>
                calistir(
                  () =>
                    abonmanTahsil(s, {
                      id: a.id,
                      yontem: yontem as OdemeYontemi,
                      tutar: kurus || 0,
                      yenile,
                    }),
                  () => {
                    setAcik(false)
                    setBasari(`${formatTL(kurus || 0)} tahsil edildi.`)
                    y.yenile()
                  },
                  setHata,
                )
              }
            />
            <Dugme metin="Vazgeç" ikincil onBas={() => setAcik(false)} />
          </div>
        ) : (
          <Dugme
            metin="Tahsilat al"
            buyuk
            onBas={() => {
              setTutar(kurusToInput(a.ucret_kurus))
              setYontem(null)
              setYenile(true)
              setHata(null)
              setBasari(null)
              setAcik(true)
            }}
          />
        ))}
      <p class="bolum">Tahsilatlar</p>
      {tahsilatlar.length === 0 && <Bilgi metin="Tahsilat yok." />}
      {tahsilatlar.map((t) => (
        <Kart key={t.id}>
          <div class="plaka-satiri" style={{ margin: 0 }}>
            <div>
              <p style={{ margin: 0, fontWeight: 700 }}>{formatTL(t.tutar_kurus)}</p>
              <p class="ikili-k">{formatTam(t.created_at)}</p>
            </div>
            <div>
              <OdemeCip yontem={t.yontem} etiket={ODEME_ETIKET[t.yontem]} />{' '}
              {t.iptal_of ? (
                <Cip metin="Ters kayıt" ton="tehlike" />
              ) : t.durum === 'ONAYLANDI' ? (
                <Cip metin="Onaylandı" ton="basari" />
              ) : t.durum === 'REDDEDILDI' ? (
                <Cip metin="Reddedildi" ton="tehlike" />
              ) : (
                <Cip metin="Onay bekliyor" ton="uyari" />
              )}
            </div>
          </div>
        </Kart>
      ))}
    </Ekran>
  )
}
