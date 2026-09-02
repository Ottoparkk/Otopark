import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router'
import {
  Card,
  Chip,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { PlakaInput } from '../../components/ui/PlakaInput'
import { useHesapEkle, useHesapOzetleri } from './api'
import { usePuanKurali } from '../yonetim/api'
import { useAyarlar } from '../gise/api'
import { formatTL } from '../../lib/money'
import { rpcErrorText } from '../../lib/errors'
import { normalizePlaka } from '../../lib/plaka'
import { IconAra, IconArti, IconPuan } from '../../components/ui/icons'

export default function Hesaplar() {
  const navigate = useNavigate()
  const { data: hesaplar = [], isPending, error, refetch } = useHesapOzetleri()
  const { data: kural } = usePuanKurali()
  const { data: ayar } = useAyarlar()
  const ekle = useHesapEkle()

  const [q, setQ] = useState('')
  const [acik, setAcik] = useState(false)
  const [ad, setAd] = useState('')
  const [tel, setTel] = useState('')
  const [plaka, setPlaka] = useState('')
  const [notlar, setNotlar] = useState('')
  const [hata, setHata] = useState<string | null>(null)

  const kurusPerPuan = kural?.kurus_per_puan ?? 0

  const gorunen = useMemo(() => {
    const s = q.trim().toLocaleLowerCase('tr-TR')
    if (!s) return hesaplar
    return hesaplar.filter((h) => h.ad.toLocaleLowerCase('tr-TR').includes(s))
  }, [hesaplar, q])

  return (
    <div>
      <ScreenHeader
        title="Puan hesapları"
        back="/yonetim"
        right={
          <button
            type="button"
            onClick={() => {
              setAd('')
              setTel('')
              setPlaka('')
              setNotlar('')
              setHata(null)
              setAcik(true)
            }}
            aria-label="Hesap ekle"
            className="flex size-11 items-center justify-center rounded-chip bg-accent text-accent-ink"
          >
            <IconArti size={20} />
          </button>
        }
      />

      <div className="space-y-4 px-5">
        {ayar && !ayar.puan_aktif && (
          <p className="rounded-card bg-warn-soft px-4 py-3 text-label text-warn">
            Puan sistemi kapalı. Hesaplar tanımlanabilir ancak girişlerde puan
            kazanılmaz — açmak için Otopark Ayarları.
          </p>
        )}

        {/* Only the count. The two figures that used to sit beside it — total
            points and what they are worth — were sums across every customer,
            and nobody acts on those: a balance is only meaningful against the
            person who can spend it, and every row below already carries its
            own. The outstanding liability across the lot is a Finans
            question, not a list header. */}
        <p className="text-label text-faint tnum">{hesaplar.length} hesap</p>

        <div className="relative">
          <IconAra
            size={20}
            className="pointer-events-none absolute top-1/2 left-4 -translate-y-1/2 text-faint"
          />
          <Input
            label="Hesap ara"
            hideLabel
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Hesap ara"
            className="pl-11"
          />
        </div>

        <div className="space-y-2">
          <ListeDurumu
            pending={isPending}
            error={error}
            onRetry={() => void refetch()}
            empty={gorunen.length === 0}
            bos={
              <EmptyState
                icon={<IconPuan size={44} />}
                title={q ? 'Eşleşen hesap yok' : 'Henüz hesap yok'}
                hint={
                  q
                    ? undefined
                    : 'Düzenli müşterileri bir hesaba bağlayın; araçları girişte tanınır ve puan kazanır.'
                }
              />
            }
          >
            {gorunen.map((h) => (
              <Card key={h.hesap_id} as="div">
                <button
                  type="button"
                  onClick={() => navigate(`/yonetim/hesaplar/${h.hesap_id}`)}
                  className="flex w-full items-center gap-3 text-left"
                >
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2">
                      <span className="truncate text-body font-medium text-ink">{h.ad}</span>
                      {h.durum === 'PASIF' && <Chip tone="neutral">Pasif</Chip>}
                    </div>
                    {kurusPerPuan > 0 && (
                      <p className="mt-0.5 text-label text-faint tnum">
                        {formatTL(h.bakiye * kurusPerPuan)} karşılığı
                      </p>
                    )}
                  </div>
                  <span className="shrink-0 text-lead font-semibold text-ink tnum">{h.bakiye}</span>
                </button>
              </Card>
            ))}
          </ListeDurumu>
        </div>
      </div>

      <FormModal
        open={acik}
        onOpenChange={setAcik}
        title="Yeni hesap"
        submitLabel="Ekle"
        loading={ekle.isPending}
        error={hata}
        onSubmit={() => {
          if (!ad.trim()) {
            setHata('Hesap adı zorunludur.')
            return
          }
          const t = tel.replace(/\D/g, '')
          if (t && !/^[1-9][0-9]{9}$/.test(t)) {
            setHata('Telefonu 10 hane olarak girin (örn. 5321234567).')
            return
          }
          // The plate is what the system recognises at the barrier; an account
          // without one cannot earn anything.
          const p = normalizePlaka(plaka)
          if (p.length < 4) {
            setHata('Plaka girin.')
            return
          }
          void ekle
            .mutateAsync({
              ad: ad.trim(),
              telefon: t || null,
              notlar: notlar.trim() || null,
              plaka: p,
            })
            // Straight into the new account: more vehicles, if there are any,
            // are added on the detail screen.
            .then((id) => {
              setAcik(false)
              setAd('')
              setTel('')
              setNotlar('')
              setPlaka('')
              navigate(`/yonetim/hesaplar/${id}`)
            })
            .catch((e) => setHata(rpcErrorText(e, 'Hesap eklenemedi.')))
        }}
      >
        <Input label="Ad" value={ad} onChange={(e) => setAd(e.target.value)} maxLength={80} />
        {/* Required, and first after the name: this is the only field that
            makes the account do anything. */}
        <PlakaInput value={plaka} onChange={setPlaka} />
        <Input
          label="Telefon (isteğe bağlı)"
          value={tel}
          onChange={(e) => setTel(e.target.value)}
          inputMode="tel"
          placeholder="5321234567"
          maxLength={10}
        />
        <Input
          label="Not (isteğe bağlı)"
          value={notlar}
          onChange={(e) => setNotlar(e.target.value)}
          maxLength={200}
        />
      </FormModal>
    </div>
  )
}
