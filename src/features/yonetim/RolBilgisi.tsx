import { FormModal } from '../../components/ui/FormModal'
import { IconTik, IconCarpi } from '../../components/ui/icons'

/**
 * What each role can actually reach, named by the sections as they appear in
 * the app — "Finans", "Çöp Kutusu" — rather than described in the abstract.
 * Somebody reading this is about to promote or demote a person, and the
 * question in their head is "will they see the Kasa?", not "do they have
 * read access to financial aggregates".
 *
 * Written from the RLS policies and RPC guards, not from which buttons happen
 * to be visible: hiding a button is the cosmetic half, and a reference that
 * described the UI would be wrong the first time the two drifted apart.
 */

type Madde = { ad: string; detay: string }

const ACIK: Madde[] = [
  { ad: 'Gişe', detay: 'Araç girişi, çıkış ve ücret tahsilatı, açık bilet arama, kayıp bilet' },
  { ad: 'Vardiya', detay: 'Kendi vardiyasını açar ve kapatır, kendi nakdini sayar' },
  { ad: 'Çözülmemiş kayıtlar', detay: 'Görür ve çözer — silemez' },
  { ad: 'Profil', detay: 'Ad soyad, koyu mod, çıkış' },
]

const KAPALI: Madde[] = [
  { ad: 'Finans', detay: 'Kasa, Onay, Raporlar, Bilet, Vardiyalar, Tarifeler' },
  {
    ad: 'Yönetim',
    detay: 'Abonmanlar, Puan hesapları, Personel, Otopark Ayarları, Çöp Kutusu',
  },
  { ad: 'Bildirimler', detay: 'Ekran açılır ama boştur; her bildirim türü Yöneticiye özeldir' },
]

// The part a section list cannot express: what a Personel sees LESS of inside
// a screen they are allowed to open. This is where the real boundary sits.
const GISEDE: Madde[] = [
  { ad: 'Abonman fiyatı', detay: 'Yalnızca "geçerli mi" bilgisi görünür, tutar görünmez' },
  { ad: 'Geçmiş ciro', detay: 'Yalnızca bugünün toplamı ve anlık doluluk' },
  { ad: 'Başkasının vardiyası', detay: 'Kendi açık vardiyasının tahsilatları dışında hiçbiri' },
  { ad: 'Puan', detay: 'Yalnızca kapıdaki aracın bakiyesi — hesap listesi ve geçmiş yok' },
  { ad: 'Bilet iptali', detay: 'Yapabilir, ama sebep zorunludur ve Yöneticiye bildirilir' },
]

const YONETICI: Madde[] = [
  { ad: 'Onay', detay: 'Onaylanmayan tahsilat ciroya girmez' },
  { ad: 'Finans', detay: 'Kasa, geçmiş ciro, raporlar, tüm biletler ve vardiyalar' },
  { ad: 'Tarifeler', detay: 'Fiyat değiştirme — açık biletleri geriye dönük etkilemez' },
  { ad: 'Otopark Ayarları', detay: 'Kapasite, park yerleri, kamera, plaka okuma' },
  { ad: 'Abonmanlar', detay: 'Abonman ve fiyatları, tahsilat' },
  { ad: 'Puan hesapları', detay: 'Hesaplar, bakiyeler ve puan kuralı' },
  { ad: 'Personel', detay: 'Kayıt onayı, rol, maaş, avans ve prim' },
  { ad: 'Vardiyalar', detay: 'Açık kalan bir vardiyayı kapatabilir' },
  { ad: 'Çöp Kutusu', detay: 'Silinenleri görür ve geri alır' },
]

function Satir({ madde, olumlu }: { madde: Madde; olumlu: boolean }) {
  return (
    <li className="flex items-start gap-2.5">
      <span
        className={`mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full ${
          olumlu ? 'bg-success-soft text-success' : 'bg-field text-faint'
        }`}
      >
        {olumlu ? <IconTik size={13} /> : <IconCarpi size={12} />}
      </span>
      <span className="min-w-0">
        <span className="text-body font-medium text-ink">{madde.ad}</span>
        <span className="text-body text-soft"> — {madde.detay}</span>
      </span>
    </li>
  )
}

function Bolum({
  baslik,
  maddeler,
  olumlu,
  ilk = false,
}: {
  baslik: string
  maddeler: Madde[]
  olumlu: boolean
  ilk?: boolean
}) {
  return (
    <div className={ilk ? undefined : 'border-t border-divider pt-4'}>
      <p className="mb-2 text-label font-medium tracking-wide text-faint uppercase">{baslik}</p>
      <ul className="space-y-2">
        {maddeler.map((m) => (
          <Satir key={m.ad} madde={m} olumlu={olumlu} />
        ))}
      </ul>
    </div>
  )
}

export function RolBilgisi({
  open,
  onOpenChange,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  return (
    <FormModal
      open={open}
      onOpenChange={onOpenChange}
      title="Rol bilgisi"
      submitLabel="Kapat"
      onSubmit={() => onOpenChange(false)}
    >
      <Bolum baslik="Personel — açık bölümler" maddeler={ACIK} olumlu ilk />
      <Bolum baslik="Personel — kapalı bölümler" maddeler={KAPALI} olumlu={false} />
      <Bolum baslik="Gişe'de Personel'in görmedikleri" maddeler={GISEDE} olumlu={false} />

      <div className="border-t border-divider pt-4">
        <p className="mb-2 text-label font-medium tracking-wide text-faint uppercase">
          Yönetici
        </p>
        <p className="mb-2 text-body text-soft">
          Personelin gördüğü her şey, ayrıca Finans ve Yönetim bölümlerinin tamamı:
        </p>
        <ul className="space-y-2">
          {YONETICI.map((m) => (
            <Satir key={m.ad} madde={m} olumlu />
          ))}
        </ul>
      </div>

      {/* Not decoration: it is the answer to "but the button is hidden, so it
          is fine, right?" — no, the hidden button is the cosmetic half. */}
      <p className="rounded-field bg-field px-3.5 py-3 text-label text-faint">
        Bu sınırlar veritabanında tanımlıdır. Bir Personel adresi elle yazsa da sunucu
        reddeder; ekranda düğmeyi gizlemek yalnızca görsel kısımdır.
      </p>
    </FormModal>
  )
}
