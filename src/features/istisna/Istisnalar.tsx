import { useState } from 'react'
import { useNavigate } from 'react-router'
import {
  Card,
  Chip,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
  SegmentedControl,
} from '../../components/ui/primitives'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { useIstisnaCoz, useIstisnalar } from './api'
import { useFotoUrl } from '../gise/api'
import { formatPlaka } from '../../lib/plaka'
import { formatTam } from '../../lib/dates'
import { formatSure, dakikaFarki } from '../../lib/sure'
import { rpcErrorText } from '../../lib/errors'
import { IconKamera, IconTik } from '../../components/ui/icons'
import { ISTISNA_ETIKET, type Istisna, type IstisnaTur } from '../../lib/types'

/** Tone by severity: a rejected event reads red, a flagged one amber. */
const TUR_TONE: Record<IstisnaTur, 'danger' | 'warn' | 'accent'> = {
  GELECEK: 'danger',
  BAYAT: 'danger',
  ACIK_BILET_YOK: 'warn',
  COKLU_ESLESME: 'accent',
}

/** What the operator should actually DO — the label alone does not say. */
const TUR_ACIKLAMA: Record<IstisnaTur, string> = {
  GELECEK:
    'Olayın saati ileri tarihli olduğu için kabul edilmedi. Kameranın saati yanlış olabilir.',
  BAYAT:
    'Olay çok geç ulaştı; araç çoktan çıkmış olabilir, bu yüzden bilet açılmadı.',
  ACIK_BILET_YOK:
    'Çıkışta bu plakaya ait açık bilet bulunamadı. Plaka yanlış okunmuş ya da giriş kaydedilmemiş olabilir.',
  COKLU_ESLESME:
    'Aramaya birden fazla açık bilet uydu. Doğru aracı Çıkış ekranından seçin.',
}

export default function Istisnalar() {
  const navigate = useNavigate()
  const [sadeceAcik, setSadeceAcik] = useState(true)
  const { data: liste = [], isPending, error, refetch } = useIstisnalar(sadeceAcik)
  const coz = useIstisnaCoz()

  const [secili, setSecili] = useState<Istisna | null>(null)
  const [not, setNot] = useState('')
  const [hata, setHata] = useState<string | null>(null)

  return (
    <div>
      <ScreenHeader
        title="Çözülmemiş kayıtlar"
        back
        subtitle="Bilete dönüşemeyen giriş ve çıkış olayları"
      />

      <div className="space-y-4 px-5">
        <SegmentedControl
          value={sadeceAcik ? 'ACIK' : 'TUMU'}
          onChange={(v) => setSadeceAcik(v === 'ACIK')}
          options={[
            { value: 'ACIK', label: 'Bekleyen' },
            { value: 'TUMU', label: 'Tümü' },
          ]}
        />

        <ListeDurumu
          pending={isPending}
          error={error}
          onRetry={() => void refetch()}
          empty={liste.length === 0}
          bos={
            <EmptyState
              icon={<IconTik size={44} />}
              title={sadeceAcik ? 'Bekleyen kayıt yok' : 'Kayıt yok'}
              hint="Bir giriş ya da çıkış olayı bilete dönüşemezse burada listelenir."
            />
          }
        >
          <div className="space-y-2">
            {liste.map((i) => (
              <IstisnaKart
                key={i.id}
                istisna={i}
                onCoz={() => {
                  setSecili(i)
                  setNot('')
                  setHata(null)
                }}
                onCikis={() => navigate('/gise/cikis')}
              />
            ))}
          </div>
        </ListeDurumu>
      </div>

      <ConfirmDialog
        open={secili !== null}
        onOpenChange={() => setSecili(null)}
        title="Çözüldü olarak işaretle"
        description="Kayıt listeden düşer. Ne yaptığınızı kısaca not edebilirsiniz."
        confirmLabel="İşaretle"
        loading={coz.isPending}
        error={hata}
        onConfirm={() => {
          if (!secili) return
          setHata(null)
          void coz
            .mutateAsync({ id: secili.id, not: not.trim() || null })
            .then(() => setSecili(null))
            .catch((e) => setHata(rpcErrorText(e, 'İşaretlenemedi.')))
        }}
      >
        <Input
          label="Not (isteğe bağlı)"
          value={not}
          onChange={(e) => setNot(e.target.value)}
          placeholder="Elle giriş açıldı"
          maxLength={200}
        />
      </ConfirmDialog>
    </div>
  )
}

function IstisnaKart({
  istisna: i,
  onCoz,
  onCikis,
}: {
  istisna: Istisna
  onCoz: () => void
  onCikis: () => void
}) {
  const { data: fotoUrl } = useFotoUrl(i.foto_path)
  const cozuldu = i.cozuldu_at !== null

  // Both timestamps are kept precisely so this lag is visible. A camera that
  // buffered through an outage shows up here as hours, and a camera whose
  // clock has drifted shows up as a constant offset — the difference between
  // those two is the difference between a network problem and mis-billing.
  const gecikmeDk = i.kaynak_zaman ? dakikaFarki(i.kaynak_zaman, i.alindi_zaman) : 0

  return (
    <Card className={cozuldu ? 'opacity-70' : ''}>
      <div className="flex flex-wrap items-center gap-2">
        <Chip tone={TUR_TONE[i.tur]}>{ISTISNA_ETIKET[i.tur]}</Chip>
        <Chip tone="neutral">{i.yon === 'GIRIS' ? 'Giriş' : 'Çıkış'}</Chip>
        {i.kaynak === 'KAMERA' && (
          <Chip tone="neutral">
            <IconKamera size={13} />
            Kamera
          </Chip>
        )}
        {cozuldu && <Chip tone="success">Çözüldü</Chip>}
      </div>

      <p className="mt-2.5 text-lead font-semibold tracking-wide text-ink tnum">
        {i.plaka ? formatPlaka(i.plaka) : 'Plaka okunamadı'}
      </p>

      <p className="mt-1 text-label text-faint">
        {i.kaynak_zaman ? `Olay ${formatTam(i.kaynak_zaman)} · ` : ''}
        Alındı {formatTam(i.alindi_zaman)}
        {gecikmeDk >= 2 ? ` · ${formatSure(gecikmeDk)} gecikmeli` : ''}
      </p>

      <p className="mt-2 text-body text-soft">{TUR_ACIKLAMA[i.tur]}</p>

      {i.kaynak === 'KAMERA' && !cozuldu && (
        <p className="mt-2 rounded-field bg-warn-soft px-3 py-2 text-label font-medium text-warn">
          Bu araç kameradan geldi — elle girmeyin. Bağlantı düzeldiğinde kayıt
          kendiliğinden oluşabilir.
        </p>
      )}

      {fotoUrl && (
        <img
          src={fotoUrl}
          alt="Olay fotoğrafı"
          className="mt-3 max-h-52 w-full rounded-field object-cover"
        />
      )}

      {cozuldu ? (
        i.cozum_notu && <p className="mt-3 text-label text-faint">Not: {i.cozum_notu}</p>
      ) : (
        <div className="mt-3 flex gap-2">
          {i.tur !== 'GELECEK' && i.yon === 'CIKIS' && (
            <button
              type="button"
              onClick={onCikis}
              className="min-h-[44px] flex-1 rounded-field bg-field px-4 text-body font-medium text-ink"
            >
              Çıkış ekranı
            </button>
          )}
          <button
            type="button"
            onClick={onCoz}
            className="min-h-[44px] flex-1 rounded-field bg-accent px-4 text-body font-medium text-accent-ink"
          >
            Çözüldü
          </button>
        </div>
      )}
    </Card>
  )
}
