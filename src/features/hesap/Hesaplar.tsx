import { useEffect, useMemo, useState } from 'react'
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
import { Toggle } from '../../components/ui/Toggle'
import { PlakaInput } from '../../components/ui/PlakaInput'
import { useHesapEkle, useHesapOzetleri } from './api'
import { useAyarGuncelle, usePuanKurali, usePuanKuralGuncelle } from '../yonetim/api'
import { useAyarlar } from '../gise/api'
import { digitsOnly, formatTL, kurusToInput, parseTLToKurus } from '../../lib/money'
import { rpcErrorText } from '../../lib/errors'
import { normalizePlaka } from '../../lib/plaka'
import { normalizeTel, telGonderilebilir } from '../../lib/telefon'
import { IconAra, IconArti, IconAyar, IconPuan } from '../../components/ui/icons'

export default function Hesaplar() {
  const navigate = useNavigate()
  const { data: hesaplar = [], isPending, error, refetch } = useHesapOzetleri()
  const { data: kural } = usePuanKurali()
  const { data: ayar } = useAyarlar()
  const ekle = useHesapEkle()
  const ayarGuncelle = useAyarGuncelle()
  const kuralGuncelle = usePuanKuralGuncelle()

  const [q, setQ] = useState('')
  const [acik, setAcik] = useState(false)
  const [ad, setAd] = useState('')
  const [tel, setTel] = useState('')
  const [plaka, setPlaka] = useState('')
  const [notlar, setNotlar] = useState('')
  const [hata, setHata] = useState<string | null>(null)

  // The rule lives on THIS screen now: the settings for a feature belong with
  // the feature, and the Yönetim tile is the only door to either.
  const [ayarAcik, setAyarAcik] = useState(false)
  const [puanAktif, setPuanAktif] = useState(false)
  const [kazanim, setKazanim] = useState('')
  const [puanDeger, setPuanDeger] = useState('')
  const [bekleme, setBekleme] = useState('')
  const [ayarHata, setAyarHata] = useState<string | null>(null)

  const kurusPerPuan = kural?.kurus_per_puan ?? 0

  useEffect(() => {
    if (kural) {
      setKazanim(String(kural.kazanim_puan))
      setPuanDeger(kurusToInput(kural.kurus_per_puan))
      setBekleme(String(kural.bekleme_saat))
    }
  }, [kural])
  useEffect(() => {
    if (ayar) setPuanAktif(ayar.puan_aktif)
  }, [ayar])

  async function ayarKaydet() {
    const deger = parseTLToKurus(puanDeger || '0')
    if (deger === null) {
      setAyarHata('Puan değerini geçerli girin.')
      return
    }
    const yeniKazanim = Number(kazanim) || 0
    const yeniBekleme = Number(bekleme) || 0
    try {
      if (ayar && ayar.puan_aktif !== puanAktif) {
        await ayarGuncelle.mutateAsync({ puan_aktif: puanAktif })
      }
      // Only when something actually moved: every call closes the current
      // version and opens a new one, so saving an unchanged rule would fill
      // the history with versions that changed nothing.
      if (
        !kural ||
        kural.kazanim_puan !== yeniKazanim ||
        kural.kurus_per_puan !== deger ||
        kural.bekleme_saat !== yeniBekleme
      ) {
        await kuralGuncelle.mutateAsync({
          kazanim_puan: yeniKazanim,
          kurus_per_puan: deger,
          bekleme_saat: yeniBekleme,
          puan_gecerlilik_gun: kural?.puan_gecerlilik_gun ?? 0,
        })
      }
      setAyarAcik(false)
    } catch (e) {
      setAyarHata(rpcErrorText(e, 'Puan ayarları kaydedilemedi.'))
    }
  }

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
            kazanılmaz — açmak için Puan ayarları.
          </p>
        )}

        {/* Only the count. The two figures that used to sit beside it — total
            points and what they are worth — were sums across every customer,
            and nobody acts on those: a balance is only meaningful against the
            person who can spend it, and every row below already carries its
            own. The outstanding liability across the lot is a Finans
            question, not a list header. */}
        {/* The settings button carries its label rather than a bare gear, and
            sits here rather than in the header: "Puan ayarları" beside a title
            reading "Puan hesapları" needs room the header does not have — the
            title would truncate to make space for it. */}
        <div className="flex items-center justify-between gap-3">
          <p className="text-label text-faint tnum">{hesaplar.length} hesap</p>
          <button
            type="button"
            onClick={() => {
              setAyarHata(null)
              setAyarAcik(true)
            }}
            className="flex shrink-0 items-center gap-1.5 rounded-chip bg-field px-3 py-2 text-label font-medium text-soft active:bg-border"
          >
            <IconAyar size={16} />
            Puan ayarları
          </button>
        </div>

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
          // Shared with the gişe screens on purpose: two hand-written copies
          // of this rule are what let one of them forget the empty case.
          // normalizeTel also means a number dictated as "0532…" is accepted
          // here the way it already was at the barrier.
          const t = normalizeTel(tel)
          if (!telGonderilebilir(t)) {
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

      <FormModal
        open={ayarAcik}
        onOpenChange={setAyarAcik}
        title="Puan ayarları"
        loading={ayarGuncelle.isPending || kuralGuncelle.isPending}
        error={ayarHata}
        onSubmit={() => void ayarKaydet()}
      >
        <Toggle
          checked={puanAktif}
          onChange={setPuanAktif}
          label="Puan sistemi açık"
          hint="Kapalıyken hiçbir puan kazanılmaz ve kullanılamaz."
        />
        {/* The rule stays editable while the system is off — the rate is what
            you want to settle BEFORE opening the tap, not after. */}
        <Input
          label="Giriş başına kazanım (puan)"
          value={kazanim}
          onChange={(e) => setKazanim(digitsOnly(e.target.value, 5))}
          inputMode="numeric"
        />
        <Input
          label="1 puanın değeri (₺)"
          value={puanDeger}
          onChange={(e) => setPuanDeger(e.target.value)}
          inputMode="decimal"
        />
        <Input
          label="Aynı plaka için bekleme (saat)"
          value={bekleme}
          onChange={(e) => setBekleme(digitsOnly(e.target.value, 3))}
          inputMode="numeric"
          hint="Girip çıkarak puan biriktirmeyi engeller."
        />
        {kazanim && puanDeger && (
          <p className="text-label text-faint">
            Her giriş yaklaşık{' '}
            <strong className="text-soft">
              {formatTL((Number(kazanim) || 0) * (parseTLToKurus(puanDeger) ?? 0))}
            </strong>{' '}
            değerinde borç yaratır.
          </p>
        )}
      </FormModal>
    </div>
  )
}
