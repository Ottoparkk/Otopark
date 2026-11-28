import { useEffect, useState } from 'preact/hooks'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../../src/lib/plaka'
import { formatTL, parseTLToKurus } from '../../../src/lib/money'
import { formatSaat, formatTam } from '../../../src/lib/dates'
import { sureMetni } from '../../../src/lib/sure'
import { biletBorcu, cikisGeriAlma, kapaliBiletIslemYapabilir, sureBitisi } from '../../../src/lib/bilet'
import { UCRETSIZ_SEBEPLER, sonradanUcretsizMi, ucretsizEtiket, ucretsizHatasi } from '../../../src/lib/ucretsiz'
import { asimDurumu, type AsimOnizleme } from '../../../src/features/gise/asim'
import { anlasmaSaat, anlasmaSaatGecerli, bitisMetni, type AnlasmaBirim } from '../../../src/features/gise/anlasma'
import { ODEME_ETIKET, type Bilet as BiletTipi, type OdemeYontemi, type UcretsizSebep } from '../../../src/lib/types'
import {
  AltBar,
  Alan,
  Bilgi,
  Cip,
  Dugme,
  Ekran,
  Foto,
  Geri,
  Hata,
  Ikili,
  Kart,
  OdemeCip,
  PlakaBasligi,
  Satir,
  YontemSecici,
  useTekSefer,
  useYukle,
} from '../parcalar'
import * as G from '../giseIslem'
import type { EkranOzellik } from '../main'

const PLAKA = { normalizePlaka, plakaGecerli }

interface Yuk {
  bilet: BiletTipi
  ucret: number | null
  asim: AsimOnizleme | null
  yikamaTarife: number | null
  vardiyam: string | null
}

async function yukle(s: EkranOzellik['s'], id: string): Promise<Yuk> {
  const bilet = await G.biletAl(s, id)
  if (bilet.durum === 'ACIK') {
    const [ucret, asim, yikamaTarife] = await Promise.all([G.ucretOnizle(s, id), G.asimOnizle(s, id), G.yikamaUcreti(s)])
    return { bilet, ucret, asim, yikamaTarife, vardiyam: null }
  }
  return {
    bilet,
    ucret: null,
    asim: null,
    yikamaTarife: null,
    vardiyam: await G.vardiyamId(s),
  }
}

type Acik = null | 'tahsil' | 'ucretsiz' | 'plaka' | 'iptal' | 'anlasma' | 'geriAl' | 'degistir'

/**
 * One ticket. Open: the main app's Tahsilat page (fee, Süre aşımı, services,
 * Tahsil Et ve Çıkış Ver, Ücretsiz, Plaka düzelt, İptal iste, entry fiş).
 * Closed: Ödeme topla, Ücretsiz çıkış, Araç çıkmadı and the exit fiş — own
 * shift only (067); the server re-checks every one.
 */
export function Bilet({ s, git, biletId }: EkranOzellik & { biletId: string }) {
  const y = useYukle(() => yukle(s, biletId), [biletId], 30000)
  const [acik, setAcik] = useState<Acik>(null)
  const [mesgul, calistir] = useTekSefer()
  const [hata, setHata] = useState<string | null>(null)
  const [yontem, setYontem] = useState<OdemeYontemi | null>(null)
  const [sebep, setSebep] = useState<UcretsizSebep | null>(null)
  const [metin, setMetin] = useState('')
  const [plaka, setPlaka] = useState('')
  const [anlasmaTutar, setAnlasmaTutar] = useState('')
  const [anlasmaSayi, setAnlasmaSayi] = useState('1')
  const [anlasmaBirim, setAnlasmaBirim] = useState<AnlasmaBirim>('gun')

  // A panel opened from the bottom bar may be off-screen: bring it into view.
  useEffect(() => {
    const p = acik ? document.querySelector('.panel') : null
    if (p) p.scrollIntoView(true)
  }, [acik])

  const geri = <Geri metin="Gişe" onBas={() => git({ ekran: 'gise' })} />
  if (!y.veri) {
    return (
      <Ekran baslik="Bilet" ust={geri}>
        <Hata metin={y.hata} />
        {y.hata ? <Dugme metin="Tekrar dene" onBas={y.yenile} ikincil /> : <Bilgi metin="Yükleniyor…" />}
      </Ekran>
    )
  }
  const { bilet: b, ucret, asim, yikamaTarife, vardiyam } = y.veri
  const acikBilet = b.durum === 'ACIK'
  const asimD = asimDurumu(b, asim)
  const net = acikBilet ? (b.abonman_id ? b.yikama_kurus || 0 : Math.max(0, (ucret || 0) - b.indirim_kurus)) : biletBorcu(b)
  const odemeGerekli = net > 0

  function ac(a: Acik) {
    setAcik(a)
    setHata(null)
    setYontem(null)
    setSebep(null)
    setMetin('')
  }
  function bitir() {
    ac(null)
    y.yenile()
  }
  function is(f: () => Promise<unknown>, sonra: () => void = bitir) {
    setHata(null)
    calistir(f, sonra, setHata)
  }

  // --- the panels a button opens -------------------------------------------------------
  function tahsilPaneli(kapali: boolean) {
    return (
      <div class="panel">
        <p class="panel-baslik">{odemeGerekli ? `${formatTL(net)} tahsil edilsin mi?` : 'Çıkış kaydedilsin mi?'}</p>
        {odemeGerekli && (
          <>
            <p class="alan-etiket">Ödeme yöntemi</p>
            <YontemSecici deger={yontem} sec={setYontem} />
          </>
        )}
        <p class="bilgi">
          {kapali
            ? 'Toplanan ödeme Yönetici onayına gider.'
            : 'Tahsilat kaydedildikten sonra bilet değiştirilemez, yalnız iptal edilebilir.'}
        </p>
        <Hata metin={hata} />
        <Dugme
          metin={odemeGerekli ? `${formatTL(net)} Tahsil et` : 'Çıkışı kaydet'}
          mesgul={mesgul}
          devreDisi={odemeGerekli && !yontem}
          buyuk
          onBas={() =>
            kapali
              ? is(() => G.biletTahsil(s, b.id, yontem as OdemeYontemi))
              : is(
                  () => G.biletKapat(s, b.id, odemeGerekli ? yontem : null),
                  () => git({ ekran: 'cfis', biletId: b.id }),
                )
          }
        />
        <Dugme metin="Vazgeç" ikincil onBas={() => ac(null)} />
      </div>
    )
  }
  function ucretsizPaneli() {
    return (
      <div class="panel">
        <p class="panel-baslik">Ücretsiz çıkış</p>
        <p class="alan-etiket">Sebep</p>
        <div class="cipler">
          {UCRETSIZ_SEBEPLER.map((x) => (
            <button key={x.value} type="button" class={sebep === x.value ? 'cip secili' : 'cip'} onClick={() => setSebep(x.value)}>
              {x.label}
            </button>
          ))}
        </div>
        <Alan etiket="Not" value={metin} maxLength={200} onInput={(e) => setMetin(e.currentTarget.value)} />
        <p class="bilgi">Ücret sıfırlanır; Yönetici bilgilendirilir.</p>
        <Hata metin={hata} />
        <Dugme
          metin="Ücretsiz çıkış ver"
          mesgul={mesgul}
          buyuk
          onBas={() => {
            const h = ucretsizHatasi(sebep, metin)
            if (h) return setHata(h)
            is(
              () => G.ucretsizCikis(s, b.id, sebep as UcretsizSebep, metin),
              acikBilet ? () => git({ ekran: 'cfis', biletId: b.id }) : bitir,
            )
          }}
        />
        <Dugme metin="Vazgeç" ikincil onBas={() => ac(null)} />
      </div>
    )
  }
  function metinPaneli(baslik: string, etiket: string, aciklama: string, dugme: string, f: () => Promise<unknown>) {
    return (
      <div class="panel">
        <p class="panel-baslik">{baslik}</p>
        <Alan etiket={etiket} value={metin} maxLength={200} onInput={(e) => setMetin(e.currentTarget.value)} />
        <p class="bilgi">{aciklama}</p>
        <Hata metin={hata} />
        <Dugme metin={dugme} mesgul={mesgul} buyuk onBas={() => is(f)} />
        <Dugme metin="Vazgeç" ikincil onBas={() => ac(null)} />
      </div>
    )
  }

  // The ticket's facts, as the main app's "Bilet" card.
  function biletKarti() {
    const ucretsiz = ucretsizEtiket(b.ucretsiz_sebep)
    return (
      <Kart>
        <p class="kart-baslik">BİLET</p>
        <Satir k="Giriş" v={formatTam(b.giris_at)} />
        {b.cikis_at && <Satir k="Çıkış" v={`${formatTam(b.cikis_at)}${b.cikis_kaynak === 'KAMERA' ? ' · kamera' : ''}`} />}
        {!acikBilet && b.ucret_kurus > 0 && <Satir k="Ücret" v={formatTL(b.ucret_kurus)} />}
        {!acikBilet && b.yikama_kurus ? <Satir k="Oto yıkama" v={formatTL(b.yikama_kurus)} /> : null}
        {b.odeme_yontemi && <Satir k="Ödeme" v={<OdemeCip yontem={b.odeme_yontemi} etiket={ODEME_ETIKET[b.odeme_yontemi]} />} />}
        {ucretsiz && <Satir k="Ücretsiz çıkış" v={`${ucretsiz}${b.ucretsiz_not ? ' — ' + b.ucretsiz_not : ''}`} />}
        {b.abonman_id && <Satir k="Abonman" v="Ücretsiz giriş" />}
        {b.kayip_bilet && <Satir k="Kayıp bilet" v="Evet" />}
        {(b.arac_bilgi || b.musteri_ad || b.notlar) && <div class="kart-ayrac" />}
        {b.arac_bilgi && <Satir k="Araç" v={b.arac_bilgi} />}
        {b.musteri_ad && <Satir k="Müşteri" v={b.musteri_ad} />}
        {b.notlar && <Satir k="Not" v={b.notlar} />}
      </Kart>
    )
  }

  // --- closed ticket: the main app's Bilet page --------------------------------------------
  if (!acikBilet) {
    const borc = biletBorcu(b)
    const islem = kapaliBiletIslemYapabilir(b, false, vardiyam)
    const borclu = b.durum === 'KAPALI' && borc > 0 && b.tahsil_kurus === 0
    const geriAlma = islem ? cikisGeriAlma(b) : null
    return (
      <Ekran baslik="Bilet" ust={geri}>
        <div class="fotolar">
          <Foto s={s} yol={b.giris_foto} etiket="Giriş" />
          <Foto s={s} yol={b.cikis_foto} etiket="Çıkış" />
        </div>
        <PlakaBasligi
          plaka={formatPlaka(b.plaka)}
          cip={b.durum === 'IPTAL' ? <Cip metin="İptal" ton="tehlike" /> : <Cip metin="Çıktı" ton="basari" />}
        />
        <Ikili
          a={{ k: 'Ücret', v: b.durum === 'IPTAL' ? '—' : formatTL(borc) }}
          b={{ k: 'Süre', v: sureMetni(b.giris_at, sureBitisi(b)) }}
        />
        {b.durum === 'KAPALI' && !islem && (
          <p class="kucuk">
            {borclu ? `${formatTL(borc)} ödeme alınmadı. ` : ''}Bu bilet başka bir vardiyada kapandı; işlem için Yönetici'ye başvurun.
          </p>
        )}
        {acik === 'tahsil' && tahsilPaneli(true)}
        {acik === 'ucretsiz' && ucretsizPaneli()}
        {acik === 'geriAl' &&
          (geriAlma === 'KAMERA'
            ? metinPaneli(
                'Araç çıkmadı mı?',
                'Not (isteğe bağlı)',
                `${formatPlaka(b.plaka)} yeniden içeride görünecek.`,
                'Bileti yeniden aç',
                () => G.kameraGeriAc(s, b.id),
              )
            : metinPaneli('Araç çıkmadı mı?', 'Sebep', 'Alınan ödeme ters kayıtla geri alınır.', 'Bileti yeniden aç', () =>
                G.cikisGeriAl(s, b.id, metin),
              ))}
        {borclu && islem && acik === null && (
          <Kart>
            <p class="kart-baslik" style={{ color: 'var(--warn)' }}>
              ÖDEME TOPLA
            </p>
            <p class="kucuk">
              {b.cikis_kaynak === 'KAMERA' ? 'Kamera aracın çıkışını gördü. ' : 'Araç borçlu çıktı. '}
              <strong>{formatTL(borc)}</strong> ödeme bekliyor.
            </p>
            <Hata metin={hata} />
            <Dugme
              metin={`${formatTL(borc)} Ödeme topla`}
              buyuk
              onBas={() => (asimDurumu(b, null) === 'BEKLIYOR' ? setHata('Önce süre aşımı için karar verin.') : ac('tahsil'))}
            />
            {sonradanUcretsizMi(b, borc) && <Dugme metin="Ücretsiz çıkış" ikincil buyuk onBas={() => ac('ucretsiz')} />}
          </Kart>
        )}
        {acik === null && !(borclu && islem) && <Hata metin={hata} />}
        {acik === null && geriAlma && <Dugme metin="Araç çıkmadı" yumusak onBas={() => ac('geriAl')} />}
        {acik === null && b.durum === 'KAPALI' && !borclu && (
          <Dugme metin="Çıkış fişi yazdır" ikincil onBas={() => git({ ekran: 'cfis', biletId: b.id })} />
        )}
        {biletKarti()}
      </Ekran>
    )
  }

  // --- open ticket: the main app's Tahsilat page -------------------------------------------
  const yikamaVar = !b.abonman_id || yikamaTarife !== null || Boolean(b.yikama_kurus)
  const anlasmaSaati = anlasmaSaat(Number(anlasmaSayi) || 0, anlasmaBirim)
  const otopark = ucret === null ? null : Math.max(0, ucret - (b.yikama_kurus || 0))
  return (
    <Ekran baslik="Tahsilat" ust={geri}>
      <Foto s={s} yol={b.giris_foto} etiket="Giriş" />
      <PlakaBasligi plaka={formatPlaka(b.plaka)} cip={<Cip metin="İçeride" ton="marka" />} />
      {b.iptal_talebi_at && (
        <Kart ton="uyari">
          <p>İptal istendi{b.iptal_talebi_sebep ? `: ${b.iptal_talebi_sebep}` : ''}.</p>
        </Kart>
      )}
      <div class="ucret-panel">
        <p class="tutar">{formatTL(net)}</p>
        <p class="alt">
          {sureMetni(b.giris_at)} · {formatSaat(b.giris_at)}
        </p>
        {b.abonman_id && <p class="not">{b.yikama_kurus ? 'Abonman — otopark ücretsiz, oto yıkama alınır' : 'Abonman — ücretsiz çıkış'}</p>}
      </div>

      {acik === 'tahsil' && tahsilPaneli(false)}
      {acik === 'ucretsiz' && ucretsizPaneli()}
      {acik === 'iptal' &&
        metinPaneli('İptal iste', 'İptal sebebi', 'Yönetici onayına gönderilir.', 'İsteği gönder', () => G.iptalIste(s, b.id, metin))}
      {acik === 'plaka' && (
        <div class="panel">
          <p class="panel-baslik">Plaka düzelt</p>
          <Alan
            etiket="Doğru plaka"
            class="alan-girdi plaka-girdi"
            value={plaka}
            maxLength={15}
            onInput={(e) => setPlaka(normalizePlaka(e.currentTarget.value))}
          />
          <Hata metin={hata} />
          <Dugme metin="Plakayı kaydet" mesgul={mesgul} buyuk onBas={() => is(() => G.plakaDuzelt(s, b.id, plaka, PLAKA))} />
          <Dugme metin="Vazgeç" ikincil onBas={() => ac(null)} />
        </div>
      )}
      {acik === 'degistir' && (
        <div class="panel">
          <p class="panel-baslik">Değiştir</p>
          <Dugme
            metin="Plaka düzelt"
            ikincil
            onBas={() => {
              setPlaka(b.plaka)
              ac('plaka')
            }}
          />
          {!b.iptal_talebi_at && <Dugme metin="İptal iste" ikincil onBas={() => ac('iptal')} />}
          <Dugme metin="Vazgeç" ikincil onBas={() => ac(null)} />
        </div>
      )}
      {acik === 'anlasma' && (
        <div class="panel">
          <p class="panel-baslik">Anlaşmalı fiyat</p>
          <Alan etiket="Tutar (₺)" inputMode="decimal" value={anlasmaTutar} onInput={(e) => setAnlasmaTutar(e.currentTarget.value)} />
          <Alan
            etiket="Süre"
            inputMode="numeric"
            value={anlasmaSayi}
            onInput={(e) => setAnlasmaSayi(e.currentTarget.value.replace(/\D/g, ''))}
          />
          <div class="cipler">
            <button type="button" class={anlasmaBirim === 'saat' ? 'cip secili' : 'cip'} onClick={() => setAnlasmaBirim('saat')}>
              Saat
            </button>
            <button type="button" class={anlasmaBirim === 'gun' ? 'cip secili' : 'cip'} onClick={() => setAnlasmaBirim('gun')}>
              Gün
            </button>
          </div>
          <Hata metin={hata} />
          <Dugme
            metin="Anlaşmayı kaydet"
            mesgul={mesgul}
            buyuk
            onBas={() => {
              const k = parseTLToKurus(anlasmaTutar)
              if (k === null || k <= 0) return setHata('Tutarı yazın.')
              if (!anlasmaSaatGecerli(anlasmaSaati)) return setHata('Süreyi kontrol edin.')
              is(() => G.anlasma(s, b.id, k, anlasmaSaati))
            }}
          />
          <Dugme metin="Vazgeç" ikincil onBas={() => ac(null)} />
        </div>
      )}

      {acik === null && yikamaVar && (
        <Kart>
          <p class="kart-baslik">HİZMETLER</p>
          {b.anlasma_kurus == null && (
            <Satir k="Otopark" v={b.abonman_id ? 'Ücretsiz (abonman)' : otopark === null ? '—' : formatTL(otopark)} />
          )}
          {asimD === 'BEKLIYOR' && asim && (
            <div class="ton-uyari" style={{ margin: '10px 0', padding: '10px 12px', borderRadius: '10px' }}>
              <p style={{ margin: '0 0 8px' }}>
                Süre aşımı: ilk kademe {formatTL(asim.ilk_kurus)}, tam {formatTL(asim.tam_kurus)}.
              </p>
              <div class="dugme-cifti">
                <Dugme metin="Tam ücret" mesgul={mesgul} onBas={() => is(() => G.asimKarar(s, b.id, true))} />
                <Dugme metin="İlk kademe" ikincil mesgul={mesgul} onBas={() => is(() => G.asimKarar(s, b.id, false))} />
              </div>
            </div>
          )}
          {(asimD === 'TAM' || asimD === 'ILK') && (
            <p class="kucuk">{asimD === 'TAM' ? 'Süre aşımı: tam ücret.' : 'Süre aşımı: ilk kademe.'}</p>
          )}
          {!b.abonman_id &&
            (b.anlasma_kurus != null ? (
              <>
                <Satir k="Anlaşmalı fiyat" v={formatTL(b.anlasma_kurus)} />
                {b.anlasma_bitis && <Satir k="Bitiş" v={bitisMetni(b.anlasma_bitis)} />}
              </>
            ) : (
              <button type="button" class="anahtar" onClick={() => ac('anlasma')}>
                <span>Anlaşmalı fiyat</span>
                <strong>Ekle</strong>
              </button>
            ))}
          <button
            type="button"
            class={b.yikama_kurus ? 'anahtar acik' : 'anahtar'}
            disabled={mesgul}
            onClick={() => is(() => G.yikama(s, b.id, !b.yikama_kurus))}
          >
            <span>Oto yıkama{b.yikama_kurus ? ` · ${formatTL(b.yikama_kurus)}` : yikamaTarife ? ` · +${formatTL(yikamaTarife)}` : ''}</span>
            <strong>{b.yikama_kurus ? 'Var — kaldır' : 'Ekle'}</strong>
          </button>
        </Kart>
      )}

      {biletKarti()}
      {acik === null && (
        <>
          <Dugme metin="Giriş fişi yazdır" ikincil onBas={() => git({ ekran: 'fis', biletId: b.id })} />
          <Dugme metin="Değiştir" yumusak onBas={() => ac('degistir')} />
          <Hata metin={hata} />
          <AltBar>
            <Dugme
              metin={odemeGerekli ? `${formatTL(net)} Tahsil Et ve Çıkış Ver` : 'Çıkışı Kaydet'}
              buyuk
              onBas={() => (asimD === 'BEKLIYOR' ? setHata('Önce süre aşımı için karar verin.') : ac('tahsil'))}
            />
            {odemeGerekli && (
              <Dugme
                metin="Ücretsiz"
                ikincil
                onBas={() => (b.indirim_kurus > 0 ? setHata('Önce kullanılan puanı geri alın.') : ac('ucretsiz'))}
              />
            )}
          </AltBar>
        </>
      )}
    </Ekran>
  )
}
