import { useState } from 'react'
import { useNavigate, useParams } from 'react-router'
import { LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { AltSayfa } from '../../components/ui/AltSayfa'
import {
  IconAraba,
  IconAy,
  IconCikis,
  IconGiris,
  IconGunes,
  IconIleri,
  IconOnay,
  IconUyari,
} from '../../components/ui/icons'
import { HalkaGrafik } from './charts'
import { useGunRaporu, useGunToplamlari, type GunRaporuVardiya } from './api'
import { useProfiller } from '../yonetim/api'
import { gecenGunMetni, gunEtiketi, vardiyaEtiketi, vardiyaTuru, yuzdeFark } from './vardiyaEtiket'
import {
  AraclarListesi,
  Chip,
  Deger,
  IslemlerListesi,
  KarsilastirmaChip,
  SATIR_RENK,
  Satir,
  kisaTL,
} from './raporParcalari'
import { istanbulGun } from '../../lib/dates'

const GUN_RE = /^\d{4}-\d{2}-\d{2}$/

type Sayfa = 'araclar' | 'dikkat' | null

/**
 * One calendar day, 00:00–24:00 Istanbul (087; owner 28.11: "how the whole
 * day went"). The same Rocket Money shape as the shift report: one number
 * with a comparison, one chart, short rows, and the day's shifts — each
 * opening its own report, where the cash count lives.
 */
export default function GunRaporu() {
  const { gun: param } = useParams()
  const gun = param && GUN_RE.test(param) ? param : undefined
  const navigate = useNavigate()
  const { data: r, isPending, error, refetch } = useGunRaporu(gun)
  const { data: toplamlar } = useGunToplamlari(gun ?? '', gun ?? '')
  const { data: profiller = [] } = useProfiller()
  const [sayfa, setSayfa] = useState<Sayfa>(null)

  const bugun = istanbulGun()
  const ad = (pid: string | null) =>
    pid === null ? 'Sistem' : profiller.find((p) => p.id === pid)?.ad_soyad || 'Bilinmiyor'

  if (!gun) {
    return (
      <div className="px-5">
        <ScreenHeader title="Günlük rapor" back="/vardiya" />
        <LoadError error={new Error('Geçersiz tarih.')} onRetry={() => navigate('/vardiya')} />
      </div>
    )
  }
  if (isPending) {
    return (
      <div className="py-20">
        <Spinner label="Rapor yükleniyor" />
      </div>
    )
  }
  if (error || !r) {
    return (
      <div className="px-5">
        <ScreenHeader title="Günlük rapor" back="/vardiya" />
        <LoadError error={error} onRetry={() => void refetch()} />
      </div>
    )
  }

  const buGun = gun === bugun
  const satir = toplamlar?.get(gun)
  const kars = satir ? yuzdeFark(r.toplam.toplam, satir.onceki) : null

  return (
    <div className="pb-8">
      <ScreenHeader title={gunEtiketi(gun, bugun)} back="/vardiya" />

      <div className="space-y-4 px-5">
        {/* ---- hero: the day's number and the week-ago comparison */}
        <div className="pt-1 pb-2">
          <p className="text-hero font-semibold text-ink tnum">{kisaTL(r.toplam.toplam)}</p>
          <p className="mt-1.5 text-body text-soft">
            {r.vardiyalar.length} vardiya{buGun ? ' · devam ediyor' : ''}
          </p>
          {kars && (
            <KarsilastirmaChip
              className="mt-2.5"
              kars={kars}
              metin={buGun ? `${gecenGunMetni(gun)}, bu saate kadar` : gecenGunMetni(gun)}
            />
          )}
        </div>

        {/* ---- the chart: how it was paid */}
        <div className="rounded-card border border-border bg-surface p-4 shadow-card">
          <HalkaGrafik
            merkez={String(r.toplam.arac)}
            merkezAlt="araç"
            dilimler={[
              { etiket: 'Nakit', deger: r.toplam.nakit, renk: 'text-nakit', gosterim: kisaTL(r.toplam.nakit) },
              { etiket: 'Kart', deger: r.toplam.kart, renk: 'text-kart', gosterim: kisaTL(r.toplam.kart) },
              { etiket: 'Havale', deger: r.toplam.havale, renk: 'text-havale', gosterim: kisaTL(r.toplam.havale) },
            ]}
          />
        </div>

        {/* ---- the rows; details one tap deeper */}
        <div className="divide-y divide-divider overflow-hidden rounded-card border border-border bg-surface shadow-card">
          <Satir
            ikon={<IconGiris size={20} />}
            renk={SATIR_RENK.giren}
            etiket={
              <>
                Giren araçlar
                {r.giris.kamera > 0 && (
                  <span className="text-label text-faint"> · {r.giris.kamera} kamera</span>
                )}
              </>
            }
            deger={<Deger>{r.giris.toplam}</Deger>}
          />
          <Satir
            ikon={<IconCikis size={20} />}
            renk={SATIR_RENK.cikan}
            etiket="Çıkan araçlar"
            deger={<Deger>{r.biletler.length}</Deger>}
            onClick={r.biletler.length > 0 ? () => setSayfa('araclar') : undefined}
          />
          {r.islemler.length > 0 && (
            <Satir
              ikon={<IconUyari size={20} />}
              renk={SATIR_RENK.dikkat}
              etiket="Dikkat"
              deger={<Chip sinif="bg-warn-soft text-warn">{r.islemler.length}</Chip>}
              onClick={() => setSayfa('dikkat')}
            />
          )}
          <Satir
            ikon={<IconAraba size={20} />}
            renk={SATIR_RENK.iceride}
            etiket={buGun ? 'İçeride' : 'Gün sonunda içeride'}
            deger={<Deger>{r.iceride} araç</Deger>}
          />
          <Satir
            ikon={<IconOnay size={20} />}
            renk={SATIR_RENK.onay}
            etiket="Onay bekleyen"
            deger={<Deger>{r.onay.adet > 0 ? `${r.onay.adet} · ${kisaTL(r.onay.tutar)}` : 'Yok'}</Deger>}
            onClick={() => navigate('/finans/onay')}
          />
        </div>

        {/* ---- the day's shifts; each opens its own report */}
        {r.vardiyalar.length > 0 && (
          <section>
            <h2 className="mb-2 px-1 text-label font-medium text-soft">Vardiyalar</h2>
            <div className="divide-y divide-divider overflow-hidden rounded-card border border-border bg-surface shadow-card">
              {r.vardiyalar.map((v) => (
                <VardiyaSatiri key={v.id} v={v} onClick={() => navigate(`/vardiya/${v.id}`)} />
              ))}
            </div>
          </section>
        )}
      </div>

      <AltSayfa
        open={sayfa === 'araclar'}
        onOpenChange={(o) => !o && setSayfa(null)}
        baslik={`Çıkan araçlar (${r.biletler.length})`}
      >
        <AraclarListesi biletler={r.biletler} onAc={(id) => navigate(`/gise/bilet/${id}`)} />
      </AltSayfa>

      <AltSayfa
        open={sayfa === 'dikkat'}
        onOpenChange={(o) => !o && setSayfa(null)}
        baslik="Dikkat"
        aciklama="Bu gündeki olağan dışı işlemler ve kimin yaptığı."
      >
        <IslemlerListesi islemler={r.islemler} ad={ad} />
      </AltSayfa>
    </div>
  )
}

/** A shift of the day: when, who, its own total, and the cash difference if counted. */
function VardiyaSatiri({ v, onClick }: { v: GunRaporuVardiya; onClick: () => void }) {
  const gunduz = vardiyaTuru(v.acilis_at) === 'Gündüz'
  const fark = v.sayilan_nakit_kurus === null ? null : v.fark_kurus
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex min-h-[64px] w-full items-center gap-3 px-4 py-3 text-left active:bg-field"
    >
      <span
        className={`flex size-9 shrink-0 items-center justify-center rounded-field ${
          gunduz ? 'bg-warn-soft text-warn' : 'bg-kart-soft text-kart'
        }`}
      >
        {gunduz ? <IconGunes size={19} /> : <IconAy size={19} />}
      </span>
      <div className="min-w-0 flex-1">
        <p className="truncate text-body font-semibold text-ink">
          {vardiyaEtiketi(v.acilis_at, v.kapanis_at, { kisa: true })}
        </p>
        <p className="truncate text-label text-faint">
          {v.personel_ad || (v.personel_id ? 'Bilinmiyor' : 'Otomatik')}
          {v.kapanis_at === null ? ' · devam ediyor' : ''}
        </p>
      </div>
      <div className="shrink-0 text-right">
        <p className="text-body font-semibold text-ink tnum">{kisaTL(v.toplam)}</p>
        {fark !== null && (
          <p
            className={`text-label font-medium tnum ${
              fark === 0 ? 'text-success' : fark < 0 ? 'text-danger' : 'text-warn'
            }`}
          >
            {fark === 0 ? 'Tutuyor' : `${fark > 0 ? '+' : ''}${kisaTL(fark)}`}
          </p>
        )}
      </div>
      <IconIleri size={17} className="shrink-0 text-faint" />
    </button>
  )
}
