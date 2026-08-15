import type { ReactNode } from 'react'
import { BrandPanel, ScreenHeader } from '../../components/ui/primitives'
import { DolulukRozeti } from '../gise/components'
import { useGunlukOzet } from '../gise/api'
import { MenuKart } from './components'
import { formatTL } from '../../lib/money'
import {
  IconAbonman,
  IconAyar,
  IconAraba,
  IconKamera,
  IconPuan,
  IconRapor,
  IconKisi,
  IconVardiya,
  IconYer,
  IconZil,
} from '../../components/ui/icons'
import { useOkunmamisSayisi } from '../settings/api'

export default function Panel() {
  const { data: ozet } = useGunlukOzet()
  const { data: okunmamis = 0 } = useOkunmamisSayisi(true)

  return (
    <div>
      <ScreenHeader
        title="Yönetim"
        right={ozet ? <DolulukRozeti dolu={ozet.doluluk} kapasite={ozet.kapasite} /> : null}
      />

      <div className="space-y-5 px-5">
        {/* Today's takings are what a Yönetici opens this screen for, so they
            get the one branded surface and the money leads. */}
        {ozet && (
          <BrandPanel>
            <p className="text-label font-medium tracking-wide text-on-brand-soft uppercase">
              Bugün
            </p>
            <p className="mt-1.5 text-hero font-semibold tnum">
              {formatTL(ozet.toplam_kurus, { decimals: 0 })}
            </p>
            <div className="mt-4 flex gap-6 border-t border-white/15 pt-3.5">
              <div>
                <p className="text-lead font-semibold tnum">{ozet.arac_sayisi}</p>
                <p className="text-label text-on-brand-soft">giren araç</p>
              </div>
              <div>
                <p className="text-lead font-semibold tnum">
                  {ozet.doluluk}/{ozet.kapasite}
                </p>
                <p className="text-label text-on-brand-soft">doluluk</p>
              </div>
            </div>
          </BrandPanel>
        )}

        {/* Three groups, three tile colours: money, operations, administration.
            The grouping already existed; it was just invisible. */}
        <Bolum baslik="Para ve raporlar">
          <MenuKart
            to="/yonetim/raporlar"
            tone="accent"
            icon={<IconRapor size={22} />}
            baslik="Raporlar"
            aciklama="Ciro, doluluk, ortalama süre"
          />
          <MenuKart
            to="/yonetim/biletler"
            tone="accent"
            icon={<IconAraba size={22} />}
            baslik="Bilet geçmişi"
            aciklama="Tüm giriş ve çıkışlar"
          />
          <MenuKart
            to="/yonetim/vardiyalar"
            tone="accent"
            icon={<IconVardiya size={22} />}
            baslik="Vardiyalar"
            aciklama="Kasa sayımları ve farklar"
          />
          <MenuKart
            to="/yonetim/kasa"
            tone="accent"
            icon={<IconPuan size={22} />}
            baslik="Kasa"
            aciklama="Gider ve ek gelir kayıtları"
          />
        </Bolum>

        <Bolum baslik="Müşteriler ve yerler">
          <MenuKart
            to="/yonetim/abonman"
            tone="success"
            icon={<IconAbonman size={22} />}
            baslik="Abonmanlar"
            aciklama="Aylık müşteriler ve tahsilat"
          />
          <MenuKart
            to="/yonetim/yerler"
            tone="success"
            icon={<IconYer size={22} />}
            baslik="Park yerleri"
            aciklama="Yerler ve rezervasyonlar"
          />
          <MenuKart
            to="/yonetim/hesaplar"
            tone="success"
            icon={<IconPuan size={22} />}
            baslik="Puan hesapları"
            aciklama="Sadakat hesapları ve bakiyeler"
          />
        </Bolum>

        <Bolum baslik="Yönetim">
          <MenuKart
            to="/yonetim/tarifeler"
            icon={<IconRapor size={22} />}
            baslik="Tarifeler"
            aciklama="Ücretler — değişiklik sürümlenir"
          />
          <MenuKart
            to="/yonetim/personel"
            icon={<IconKisi size={22} />}
            baslik="Personel"
            aciklama="Kayıt onayı, rol ve durum"
          />
          {/* Warn, always: an unresolved event is a car that will be argued
              about at the barrier, and it should not look like a settings page. */}
          <MenuKart
            to="/istisnalar"
            tone="warn"
            icon={<IconKamera size={22} />}
            baslik="Çözülmemiş kayıtlar"
            aciklama="Eşleşmeyen giriş/çıkış olayları"
          />
          <MenuKart
            to="/yonetim/ayarlar"
            icon={<IconAyar size={22} />}
            baslik="Otopark ayarları"
            aciklama="Kapasite, kamera, plaka okuma, puan"
          />
          <MenuKart
            to="/bildirimler"
            tone={okunmamis > 0 ? 'accent' : 'neutral'}
            icon={<IconZil size={22} />}
            baslik="Bildirimler"
            aciklama={okunmamis > 0 ? `${okunmamis} okunmamış` : 'Tümü okundu'}
          />
        </Bolum>
      </div>
    </div>
  )
}

/**
 * A titled 2-column group of menu tiles.
 *
 * The heading is at the faintest rung on purpose — it labels the group without
 * competing with the destinations, which are the things being chosen.
 */
function Bolum({ baslik, children }: { baslik: string; children: ReactNode }) {
  return (
    <section>
      <h2 className="mb-2 text-label font-medium tracking-wide text-faint uppercase">{baslik}</h2>
      <div className="grid grid-cols-2 gap-3">{children}</div>
    </section>
  )
}
