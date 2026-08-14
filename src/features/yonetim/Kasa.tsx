import { useMemo, useState } from 'react'
import {
  Card,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
  SegmentedControl,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { YontemSecici } from '../../components/ui/YontemSecici'
import { DonemSecici, IstatKutu, donemAralik, type Donem } from './components'
import { useKasaEkle, useKasaHareketleri, useKasaSil } from './api'
import { formatTL, parseTLToKurus } from '../../lib/money'
import { formatTarih } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconArti, IconCop, IconPuan } from '../../components/ui/icons'
import type { KasaTur, OdemeYontemi } from '../../lib/types'

/** Expenses and non-ticket income. Yönetici only — Personel never see this. */
export default function Kasa() {
  const [donem, setDonem] = useState<Donem>('AY')
  const { bas, bit } = useMemo(() => donemAralik(donem), [donem])
  const { data: liste = [], isPending, error, refetch } = useKasaHareketleri(bas, bit)

  const ekle = useKasaEkle()
  const sil = useKasaSil()

  const [acik, setAcik] = useState(false)
  const [tur, setTur] = useState<KasaTur>('GIDER')
  const [tutar, setTutar] = useState('')
  const [aciklama, setAciklama] = useState('')
  const [kategori, setKategori] = useState('')
  const [yontem, setYontem] = useState<OdemeYontemi | null>('NAKIT')
  const [hata, setHata] = useState<string | null>(null)
  const [silinecek, setSilinecek] = useState<string | null>(null)

  const toplam = useMemo(() => {
    const gelir = liste.filter((k) => k.tur === 'GELIR').reduce((a, k) => a + k.tutar_kurus, 0)
    const gider = liste.filter((k) => k.tur === 'GIDER').reduce((a, k) => a + k.tutar_kurus, 0)
    return { gelir, gider, net: gelir - gider }
  }, [liste])

  return (
    <div>
      <ScreenHeader
        title="Kasa"
        back="/yonetim"
        right={
          <button
            type="button"
            onClick={() => {
              setTur('GIDER')
              setTutar('')
              setAciklama('')
              setKategori('')
              setHata(null)
              setAcik(true)
            }}
            aria-label="Kayıt ekle"
            className="flex size-11 items-center justify-center rounded-chip bg-accent text-accent-ink"
          >
            <IconArti size={20} />
          </button>
        }
      />

      <div className="space-y-4 px-5">
        <DonemSecici value={donem} onChange={setDonem} />

        <Card>
          <div className="grid grid-cols-3 gap-3">
            <IstatKutu
              deger={formatTL(toplam.gelir, { decimals: 0 })}
              etiket="ek gelir"
              tone="success"
            />
            <IstatKutu deger={formatTL(toplam.gider, { decimals: 0 })} etiket="gider" tone="danger" />
            <IstatKutu
              deger={formatTL(toplam.net, { decimals: 0 })}
              etiket="net"
              tone={toplam.net < 0 ? 'danger' : 'default'}
            />
          </div>
          <p className="mt-3 text-label text-faint">
            Bilet ve abonman tahsilatları burada görünmez — onlar Raporlar'daki cirodadır.
          </p>
        </Card>

        <div className="space-y-2">
          <ListeDurumu
            pending={isPending}
            error={error}
            onRetry={() => void refetch()}
            empty={liste.length === 0}
            bos={
              <EmptyState
                icon={<IconPuan size={44} />}
                title="Bu dönemde kayıt yok"
                hint="Elektrik, temizlik, bakım gibi giderleri buraya girin."
              />
            }
          >
            {liste.map((k) => (
              <Card key={k.id} className="flex items-center gap-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-body text-ink">{k.aciklama || k.kategori || '—'}</p>
                  <p className="mt-0.5 text-label text-faint">
                    {formatTarih(k.tarih)}
                    {k.kategori && k.aciklama ? ` · ${k.kategori}` : ''}
                  </p>
                </div>
                <span
                  className={`shrink-0 text-body font-semibold tnum ${
                    k.tur === 'GELIR' ? 'text-success' : 'text-danger'
                  }`}
                >
                  {k.tur === 'GELIR' ? '+' : '−'}
                  {formatTL(k.tutar_kurus)}
                </span>
                <button
                  type="button"
                  onClick={() => setSilinecek(k.id)}
                  aria-label="Sil"
                  className="flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field"
                >
                  <IconCop size={18} />
                </button>
              </Card>
            ))}
          </ListeDurumu>
        </div>
      </div>

      <FormModal
        open={acik}
        onOpenChange={setAcik}
        title="Kasa kaydı"
        submitLabel="Ekle"
        loading={ekle.isPending}
        error={hata}
        onSubmit={() => {
          const kurus = parseTLToKurus(tutar)
          if (kurus === null || kurus <= 0) {
            setHata('Geçerli bir tutar girin.')
            return
          }
          if (!aciklama.trim()) {
            setHata('Açıklama zorunludur.')
            return
          }
          void ekle
            .mutateAsync({
              tur,
              tutar_kurus: kurus,
              aciklama: aciklama.trim(),
              kategori: kategori.trim() || null,
              yontem,
            })
            .then(() => setAcik(false))
            .catch((e) => setHata(rpcErrorText(e, 'Kayıt eklenemedi.')))
        }}
      >
        <SegmentedControl
          value={tur}
          onChange={setTur}
          options={[
            { value: 'GIDER', label: 'Gider' },
            { value: 'GELIR', label: 'Ek gelir' },
          ]}
        />
        <Input
          label="Tutar (₺)"
          value={tutar}
          onChange={(e) => setTutar(e.target.value)}
          inputMode="decimal"
        />
        <Input
          label="Açıklama"
          value={aciklama}
          onChange={(e) => setAciklama(e.target.value)}
          maxLength={200}
        />
        <Input
          label="Kategori (isteğe bağlı)"
          value={kategori}
          onChange={(e) => setKategori(e.target.value)}
          placeholder="Elektrik, temizlik, bakım…"
          maxLength={60}
        />
        <YontemSecici value={yontem} onChange={setYontem} label="Ödeme yöntemi (isteğe bağlı)" />
      </FormModal>

      <ConfirmDialog
        open={silinecek !== null}
        onOpenChange={() => setSilinecek(null)}
        tone="danger"
        title="Kaydı sil"
        description="Bu kasa kaydı kalıcı olarak silinecek."
        confirmLabel="Sil"
        loading={sil.isPending}
        onConfirm={() => {
          if (!silinecek) return
          void sil.mutateAsync(silinecek).then(() => setSilinecek(null))
        }}
      />
    </div>
  )
}
