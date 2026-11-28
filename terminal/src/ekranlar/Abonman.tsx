import { useState } from 'preact/hooks'
import { formatPlaka } from '../../../src/lib/plaka'
import { formatTL, kurusToInput, parseTLToKurus } from '../../../src/lib/money'
import { formatTam, istanbulGun } from '../../../src/lib/dates'
import { abonmanAra, abonmanGruplari, kalanRozeti, kisaTarih } from '../../../src/features/abonman/liste'
import { ODEME_ETIKET, type AbonmanDurum, type OdemeYontemi } from '../../../src/lib/types'
import { Alan, Bilgi, Dugme, Ekran, Geri, Hata, Kart, Rozet, Satir, YontemSecici, useTekSefer, useYukle } from '../parcalar'
import { abonmanAl, abonmanTahsil, abonmanTahsilatlari, abonmanlar } from '../abonmanIslem'
import type { EkranOzellik } from '../main'

/** Abonman list like the main app's: Aktif / Doldu, search, grouped by payment day. */
export function Abonman({ s, git }: EkranOzellik) {
  const y = useYukle(() => abonmanlar(s), [], 60000)
  const [filtre, setFiltre] = useState<AbonmanDurum>('AKTIF')
  const [q, setQ] = useState('')
  const bugun = istanbulGun()
  const liste = abonmanAra((y.veri || []).filter((a) => a.durum === filtre), q)
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
    <Ekran baslik="Abonman" ust={geri}>
      <p class="buyuk-plaka">
        {formatPlaka(a.plaka)} {rozet && <Rozet metin={rozet} ton="uyari" />}
      </p>
      <Kart>
        <Satir k="Müşteri" v={a.musteri_ad} />
        {a.musteri_tel && <Satir k="Telefon" v={a.musteri_tel} />}
        <Satir k="Aylık ücret" v={formatTL(a.ucret_kurus)} />
        <Satir k="Başlangıç" v={kisaTarih(a.baslangic)} />
        <Satir k="Bitiş" v={kisaTarih(a.bitis)} />
        <Satir k="Durum" v={a.durum === 'AKTIF' ? 'Aktif' : a.durum === 'DOLDU' ? 'Doldu' : 'İptal'} />
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
                  () => abonmanTahsil(s, { id: a.id, yontem: yontem as OdemeYontemi, tutar: kurus || 0, yenile }),
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
          <Satir k={formatTam(t.created_at)} v={`${formatTL(t.tutar_kurus)} · ${ODEME_ETIKET[t.yontem]}`} />
          <p class="arac-alt">
            {t.iptal_of ? 'Ters kayıt' : t.durum === 'ONAYLANDI' ? 'Onaylandı' : t.durum === 'REDDEDILDI' ? 'Reddedildi' : 'Onay bekliyor'}
          </p>
        </Kart>
      ))}
    </Ekran>
  )
}
