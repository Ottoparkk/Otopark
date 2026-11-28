import { useEffect, useRef, useState } from 'preact/hooks'
import { formatPlaka } from '../../../src/lib/plaka'
import { formatTL } from '../../../src/lib/money'
import { formatSaat, istanbulGun } from '../../../src/lib/dates'
import { sureMetni } from '../../../src/lib/sure'
import { ucretsizEtiket } from '../../../src/lib/ucretsiz'
import type { AcikBilet } from '../../../src/lib/types'
import { Bilgi, Ekran, Geri, Hata, Kart, Rozet, useYukle } from '../parcalar'
import { benKimim, type Ben } from '../oturumIslem'
import { acikBiletler, acikIstisnaSayisi, cikanlar, gunlukOzet, type CikanBilet } from '../giseIslem'
import type { EkranOzellik } from '../main'

// Çözülmemiş kayıtlar → "Çıkış" opens Gişe with the plate already searched.
let bekleyenArama = ''
export function aramaKoy(q: string) {
  bekleyenArama = q
}

/** Today's Istanbul midnight as an instant (fixed UTC+3). */
function bugunBasi(): string {
  return new Date(`${istanbulGun()}T00:00:00+03:00`).toISOString()
}

/**
 * Gişe, laid out like the main app's for a Personel (owner 28.11): who holds
 * the shift + Devral, occupancy, Çözülmemiş kayıtlar, search, İçeride and
 * today's exits, and Giriş bottom right. Lists poll every 15 s (spec).
 */
export function Gise({ s, git }: EkranOzellik) {
  const [ben, setBen] = useState<Ben | null>(null)
  const [benHata, setBenHata] = useState<string | null>(null)
  const [sorgu, setSorgu] = useState(() => {
    const q = bekleyenArama
    bekleyenArama = ''
    return q
  })
  const [aranan, setAranan] = useState(sorgu)
  const zaman = useRef(0)

  useEffect(() => {
    benKimim(s).then(setBen, (e: Error) => {
      setBenHata(e.message)
      if (!s.oturum()) git({ ekran: 'pin' })
    })
  }, [])

  // Typing waits 300 ms before asking the server.
  function aramaYaz(q: string) {
    setSorgu(q)
    window.clearTimeout(zaman.current)
    zaman.current = window.setTimeout(() => setAranan(q.trim()), 300)
  }

  const ozet = useYukle(() => gunlukOzet(s), [], 30000)
  const istisna = useYukle(() => acikIstisnaSayisi(s), [], 60000)
  const iceride = useYukle(() => acikBiletler(s, aranan), [aranan])
  const cikan = useYukle(() => cikanlar(s, bugunBasi()), [], 30000)

  const q = aranan.replace(/\s+/g, '').toUpperCase()
  const cikanlarGorunen = (cikan.veri || []).filter((b) => !q || b.plaka.indexOf(q) >= 0)
  const o = ozet.veri
  const yuzde = o && o.kapasite > 0 ? Math.min(100, Math.round((o.doluluk / o.kapasite) * 100)) : 0
  const acikSayi = istisna.veri || 0

  return (
    <Ekran baslik="Gişe" ust={<Geri metin="Devral" onBas={() => git({ ekran: 'pin' })} />}>
      <p class="serit">{ben ? `Vardiyada: ${ben.ad_soyad}` : 'Vardiya'}</p>
      <Hata metin={benHata} />
      {o && (
        <Kart ton="marka">
          <p class="kart-baslik">Doluluk</p>
          <div class="yan-yana">
            <p class="dev esnek">
              {o.doluluk}
              <span class="dev-alt"> / {o.kapasite}</span>
            </p>
            <p class="dev-alt">%{yuzde}</p>
          </div>
          <div class="cubuk">
            <div class="cubuk-dolu" style={{ width: `${yuzde}%` }} />
          </div>
          <div class="yan-yana">
            <p>
              <strong>{o.arac_sayisi}</strong> <span class="dev-alt">bugün giren</span>
            </p>
            <p>
              <strong>{formatTL(o.toplam_kurus, { decimals: 0 })}</strong> <span class="dev-alt">bugün tahsilat</span>
            </p>
          </div>
        </Kart>
      )}

      <button type="button" class={acikSayi > 0 ? 'arac arac-uyari' : 'arac'} onClick={() => git({ ekran: 'istisnalar' })}>
        <span class="esnek">
          <span class="arac-plaka" style={{ fontSize: '16px' }}>
            Çözülmemiş kayıtlar
          </span>
          <span class="arac-alt" style={{ display: 'block' }}>
            {acikSayi > 0 ? `${acikSayi} eşleşmeyen giriş/çıkış olayı` : 'Eşleşmeyen giriş/çıkış olayı yok'}
          </span>
        </span>
        {acikSayi > 0 && <Rozet metin={String(acikSayi)} ton="uyari" />}
      </button>

      <label class="alan">
        <span class="alan-etiket">Plaka ara</span>
        <input
          class="alan-girdi plaka-girdi"
          value={sorgu}
          autoComplete="off"
          autoCapitalize="characters"
          spellcheck={false}
          maxLength={15}
          onInput={(e) => aramaYaz(e.currentTarget.value)}
        />
      </label>

      <p class="bolum">İçeride{iceride.veri ? ` (${iceride.veri.length})` : ''}</p>
      <Hata metin={iceride.hata} />
      {!iceride.veri && !iceride.hata && <Bilgi metin="Yükleniyor…" />}
      {iceride.veri && iceride.veri.length === 0 && <Bilgi metin={aranan ? 'Bu plakada içeride araç yok.' : 'İçeride araç yok.'} />}
      {iceride.veri && iceride.veri.map((b) => <IcerideSatir key={b.id} b={b} git={git} />)}

      <p class="bolum">Bugün çıkanlar{cikan.veri ? ` (${cikanlarGorunen.length})` : ''}</p>
      <Hata metin={cikan.hata} />
      {cikan.veri && cikanlarGorunen.length === 0 && <Bilgi metin="Bugün çıkan araç yok." />}
      {cikanlarGorunen.map((b) => (
        <CikanSatir key={b.id} b={b} git={git} />
      ))}

      <button type="button" class="bag" onClick={() => git({ ekran: 'kayip' })}>
        Kaydı olmayan araç — kayıp bilet ücreti al
      </button>
      <button type="button" class="fab" onClick={() => git({ ekran: 'giris' })}>
        + Giriş
      </button>
    </Ekran>
  )
}

function IcerideSatir({ b, git }: { b: AcikBilet; git: EkranOzellik['git'] }) {
  return (
    <button type="button" class="arac" onClick={() => git({ ekran: 'bilet', biletId: b.id })}>
      <span class="esnek">
        <span class="arac-plaka">{formatPlaka(b.plaka)}</span>
        <span class="arac-alt" style={{ display: 'block' }}>
          {formatSaat(b.giris_at)} · {sureMetni(b.giris_at)}
        </span>
        <span style={{ display: 'block' }}>
          {b.abonman_id && <Rozet metin="Abonman" ton="basari" />}
          {b.iptal_talebi && <Rozet metin="İptal istendi" ton="uyari" />}
          {b.asim_bekliyor && <Rozet metin="Süre aşımı" ton="uyari" />}
          {b.plaka_supheli && <Rozet metin="Plaka şüpheli" ton="uyari" />}
          {b.yikama_kurus ? <Rozet metin="Oto yıkama" ton="marka" /> : null}
        </span>
      </span>
      <span class="arac-sag">›</span>
    </button>
  )
}

function CikanSatir({ b, git }: { b: CikanBilet; git: EkranOzellik['git'] }) {
  const borc = b.ucret_kurus - b.indirim_kurus
  const odenmedi = borc > 0 && b.tahsil_kurus === 0
  const ucretsiz = ucretsizEtiket(b.ucretsiz_sebep)
  return (
    <button type="button" class="arac" onClick={() => git({ ekran: 'bilet', biletId: b.id })}>
      <span class="esnek">
        <span class="arac-plaka">{formatPlaka(b.plaka)}</span>
        <span class="arac-alt" style={{ display: 'block' }}>
          Çıkış {b.cikis_at ? formatSaat(b.cikis_at) : '—'}
          {b.cikis_kaynak === 'KAMERA' ? ' · kamera' : ''}
        </span>
      </span>
      <span class="arac-sag">
        {odenmedi ? (
          <Rozet metin={`${formatTL(borc)} ödenmedi`} ton="tehlike" />
        ) : ucretsiz ? (
          <Rozet metin="Ücretsiz" ton="uyari" />
        ) : b.abonman_id && !borc ? (
          <Rozet metin="Abonman" ton="basari" />
        ) : (
          formatTL(b.tahsil_kurus || borc)
        )}
      </span>
    </button>
  )
}
