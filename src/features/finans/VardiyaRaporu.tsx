import { useState } from 'react'
import { useLocation, useNavigate, useParams } from 'react-router'
import { Button, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { AltSayfa } from '../../components/ui/AltSayfa'
import { IconAraba, IconCikis, IconKasa, IconOnay, IconUyari } from '../../components/ui/icons'
import { HalkaGrafik } from './charts'
import { useTumVardiyalar, useVardiyaRaporu, useVardiyaToplamlari } from './api'
import { useProfiller } from '../yonetim/api'
import { oncekiKarsilastirma, vardiyaEtiketi, vardiyaTuru } from './vardiyaEtiket'
import {
  AraclarListesi,
  Chip,
  Deger,
  IslemlerListesi,
  Kalem,
  KarsilastirmaChip,
  SATIR_RENK,
  Satir,
  kisaTL,
} from './raporParcalari'
import { formatTL } from '../../lib/money'
import { istanbulGun } from '../../lib/dates'
import { sureMetni } from '../../lib/sure'

const KAPANIS: Record<string, string> = {
  ELLE: 'Sayılarak kapandı',
  YONETICI: 'Yönetici kapattı',
  OTOMATIK: 'Otomatik kapandı (sayımsız)',
  DEVIR: 'Devredildi (sayımsız)',
}

type Sayfa = 'kasa' | 'araclar' | 'dikkat' | null

/**
 * One shift, as a summary (086; owner 28.11: "like Rocket Money"). One big
 * number with a comparison, one chart, five rows; every list sits one tap
 * deeper in a sheet. Read-only — the count is on the Kasa screen.
 */
export default function VardiyaRaporu() {
  const { id } = useParams()
  const navigate = useNavigate()
  // Opened from a day (a Gece shift can be opened from either of its two
  // days): back returns there. Opened directly, back goes to its own day.
  const ilkSayfa = useLocation().key === 'default'
  const { data: r, isPending, error, refetch } = useVardiyaRaporu(id)
  const { data: profiller = [] } = useProfiller()
  // Cached from the list screen; only used for the comparison chip.
  const { data: liste = [] } = useTumVardiyalar()
  const { data: toplamlar } = useVardiyaToplamlari(liste.map((v) => v.id))
  const [sayfa, setSayfa] = useState<Sayfa>(null)

  const ad = (pid: string | null) =>
    pid === null ? 'Sistem' : profiller.find((p) => p.id === pid)?.ad_soyad || 'Bilinmiyor'

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
        <ScreenHeader title="Vardiya raporu" back="/vardiya" />
        <LoadError error={error} onRetry={() => void refetch()} />
      </div>
    )
  }

  const v = r.vardiya
  const acik = v.kapanis_at === null
  const beklenen = v.beklenen_nakit_kurus ?? v.acilis_nakit_kurus + r.toplam.nakit
  const sayildi = !acik && v.sayilan_nakit_kurus !== null && v.fark_kurus !== null
  const kars = oncekiKarsilastirma(liste, v.id, toplamlar)

  return (
    <div className="pb-8">
      <ScreenHeader
        title={vardiyaEtiketi(v.acilis_at, v.kapanis_at, { kisa: true })}
        back={ilkSayfa ? `/vardiya/gun/${istanbulGun(new Date(v.acilis_at))}` : true}
      />

      <div className="space-y-4 px-5">
        {/* ---- hero: the one number, who and how long, the comparison */}
        <div className="pt-1 pb-2">
          <p className="text-hero font-semibold text-ink tnum">{kisaTL(r.toplam.toplam)}</p>
          <p className="mt-1.5 text-body text-soft">
            {v.personel_ad || (v.personel_id ? 'Bilinmiyor' : 'Otomatik')} ·{' '}
            {sureMetni(v.acilis_at, v.kapanis_at)}
            {acik ? ' · devam ediyor' : ''}
          </p>
          {kars && (
            <KarsilastirmaChip
              className="mt-2.5"
              kars={kars}
              metin={vardiyaTuru(v.acilis_at) === 'Gündüz' ? 'önceki gündüzden' : 'önceki geceden'}
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
            ikon={<IconKasa size={20} />}
            renk={SATIR_RENK.kasa}
            etiket="Kasa"
            onClick={() => setSayfa('kasa')}
            deger={
              acik ? (
                <Chip sinif="bg-accent-soft text-accent">Açık</Chip>
              ) : !sayildi ? (
                <Chip sinif="bg-field text-soft">Sayılmadı</Chip>
              ) : v.fark_kurus === 0 ? (
                <Chip sinif="bg-success-soft text-success">Tutuyor</Chip>
              ) : (
                <Chip sinif={v.fark_kurus! < 0 ? 'bg-danger-soft text-danger' : 'bg-warn-soft text-warn'}>
                  {v.fark_kurus! > 0 ? '+' : ''}
                  {kisaTL(v.fark_kurus!)}
                </Chip>
              )
            }
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
            etiket={acik ? 'İçeride' : 'Kapanışta içeride'}
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

        {acik && (
          <Button size="lg" block onClick={() => navigate('/vardiya/kasa')}>
            Kasayı say ve kapat
          </Button>
        )}
      </div>

      {/* ---- sheets ------------------------------------------------- */}
      <AltSayfa open={sayfa === 'kasa'} onOpenChange={(o) => !o && setSayfa(null)} baslik="Kasa">
        <Kalem k="Açılış nakdi" v={formatTL(v.acilis_nakit_kurus)} />
        <Kalem k={acik ? 'Şu an olması gereken' : 'Olması gereken'} v={formatTL(beklenen)} />
        {!acik && (
          <Kalem
            k="Sayılan"
            v={v.sayilan_nakit_kurus === null ? 'Sayılmadı' : formatTL(v.sayilan_nakit_kurus)}
          />
        )}
        {sayildi && (
          <Kalem
            k="Fark"
            v={`${v.fark_kurus! > 0 ? '+' : ''}${formatTL(v.fark_kurus!)}`}
            ton={v.fark_kurus === 0 ? 'text-success' : v.fark_kurus! < 0 ? 'text-danger' : 'text-warn'}
          />
        )}
        {(v.kapanis_kaynak || v.notlar) && (
          <p className="mt-3 text-label text-faint">
            {[v.kapanis_kaynak ? (KAPANIS[v.kapanis_kaynak] ?? v.kapanis_kaynak) : null, v.notlar]
              .filter(Boolean)
              .join(' · ')}
          </p>
        )}
      </AltSayfa>

      <AltSayfa
        open={sayfa === 'araclar'}
        onOpenChange={(o) => !o && setSayfa(null)}
        baslik={`Çıkan araçlar (${r.biletler.length})`}
      >
        <AraclarListesi biletler={r.biletler} onAc={(bid) => navigate(`/gise/bilet/${bid}`)} />
      </AltSayfa>

      <AltSayfa
        open={sayfa === 'dikkat'}
        onOpenChange={(o) => !o && setSayfa(null)}
        baslik="Dikkat"
        aciklama="Bu vardiyadaki olağan dışı işlemler ve kimin yaptığı."
      >
        <IslemlerListesi islemler={r.islemler} ad={ad} />
      </AltSayfa>
    </div>
  )
}
