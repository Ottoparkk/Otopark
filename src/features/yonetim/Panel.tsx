import { Card, ScreenHeader } from '../../components/ui/primitives'
import { DolulukRozeti } from '../gise/components'
import { useGunlukOzet } from '../gise/api'
import { MenuKart, IstatKutu } from './components'
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

      <div className="space-y-4 px-5">
        {ozet && (
          <Card>
            <p className="text-label font-medium tracking-wide text-faint uppercase">Bugün</p>
            <div className="mt-3 grid grid-cols-3 gap-3">
              <IstatKutu deger={formatTL(ozet.toplam_kurus, { decimals: 0 })} etiket="tahsilat" />
              <IstatKutu deger={String(ozet.arac_sayisi)} etiket="giren araç" />
              <IstatKutu deger={`${ozet.doluluk}/${ozet.kapasite}`} etiket="doluluk" />
            </div>
          </Card>
        )}

        <div className="space-y-2">
          <MenuKart
            to="/yonetim/raporlar"
            icon={<IconRapor size={20} />}
            baslik="Raporlar"
            aciklama="Ciro, doluluk, ortalama süre"
          />
          <MenuKart
            to="/yonetim/biletler"
            icon={<IconAraba size={20} />}
            baslik="Bilet geçmişi"
            aciklama="Tüm giriş ve çıkışlar"
          />
          <MenuKart
            to="/yonetim/vardiyalar"
            icon={<IconVardiya size={20} />}
            baslik="Vardiyalar"
            aciklama="Kasa sayımları ve farklar"
          />
          <MenuKart
            to="/yonetim/kasa"
            icon={<IconPuan size={20} />}
            baslik="Kasa"
            aciklama="Gider ve ek gelir kayıtları"
          />
        </div>

        <div className="space-y-2">
          <MenuKart
            to="/yonetim/abonman"
            icon={<IconAbonman size={20} />}
            baslik="Abonmanlar"
            aciklama="Aylık müşteriler ve tahsilat"
          />
          <MenuKart
            to="/yonetim/yerler"
            icon={<IconYer size={20} />}
            baslik="Park yerleri"
            aciklama="Yerler ve rezervasyonlar"
          />
          <MenuKart
            to="/yonetim/hesaplar"
            icon={<IconPuan size={20} />}
            baslik="Puan hesapları"
            aciklama="Sadakat hesapları ve bakiyeler"
          />
        </div>

        <div className="space-y-2">
          <MenuKart
            to="/yonetim/tarifeler"
            icon={<IconRapor size={20} />}
            baslik="Tarifeler"
            aciklama="Ücretler — değişiklik sürümlenir"
          />
          <MenuKart
            to="/yonetim/personel"
            icon={<IconKisi size={20} />}
            baslik="Personel"
            aciklama="Kayıt onayı, rol ve durum"
          />
          <MenuKart
            to="/istisnalar"
            icon={<IconKamera size={20} />}
            baslik="Çözülmemiş kayıtlar"
            aciklama="Eşleşmeyen giriş/çıkış olayları"
          />
          <MenuKart
            to="/yonetim/ayarlar"
            icon={<IconAyar size={20} />}
            baslik="Otopark ayarları"
            aciklama="Kapasite, kamera, plaka okuma, puan"
          />
          <MenuKart
            to="/bildirimler"
            icon={<IconZil size={20} />}
            baslik="Bildirimler"
            aciklama={okunmamis > 0 ? `${okunmamis} okunmamış` : 'Tümü okundu'}
          />
        </div>
      </div>
    </div>
  )
}
