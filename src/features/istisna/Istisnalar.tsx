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
import { useKayitSil } from '../cop/api'
import { useFotoUrl } from '../gise/api'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'
import { formatPlaka } from '../../lib/plaka'
import { formatTam } from '../../lib/dates'
import { formatSure, dakikaFarki } from '../../lib/sure'
import { rpcErrorText } from '../../lib/errors'
import { IconCop, IconKamera, IconTik } from '../../components/ui/icons'
import {
  ISTISNA_ETIKET,
  KAMERA_YON_ETIKET,
  type Istisna,
  type IstisnaTur,
} from '../../lib/types'

/** Tone by severity: a rejected event reads red, a flagged one amber. */
const TUR_TONE: Record<IstisnaTur, 'danger' | 'warn' | 'accent'> = {
  GELECEK: 'danger',
  BAYAT: 'danger',
  ACIK_BILET_YOK: 'warn',
  COKLU_ESLESME: 'accent',
  YON_BELIRSIZ: 'warn',
  OKUNAMADI: 'warn',
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
  YON_BELIRSIZ:
    'Bu plaka, içerideki bir aracın plakasına bir karakter uzak. O araç çıkıyorsa Çıkış ekranından tahsil edin; yeni gelen başka bir araçsa girişini elle açın.',
  // Entrance lane. The single gate gets its own text below: there the car may
  // have been LEAVING, and opening an entry for it would leave a phantom
  // ticket that blocks that plate's next real entry.
  OKUNAMADI:
    'Kamera bir araç gördü ama plakasını okuyamadı; bilet açılmadı. Araç içerideyse ve bileti yoksa girişini elle açın. Zaten bileti varsa kaydı çözüldü olarak işaretleyin.',
}

// The last sentence matches the entrance text's "Zaten bileti varsa…": a later
// photo of the same car is a new event, opens its ticket and leaves this row
// open (see KENDILIGINDEN_COZULMEZ below).
const OKUNAMADI_TEK_KAPI =
  'Tek kapıda bir araç görüldü ama plakası okunamadı; girdiği mi çıktığı mı bilinmiyor. İçeride bileti olmayan bir araç varsa girişini elle açın; çıkan bir araçsa kaydı çözüldü olarak işaretleyin. Kamera plakayı başka bir karede okumuş olabilir: aracın zaten bileti varsa kaydı çözüldü olarak işaretleyin.'

function aciklama(i: Istisna): string {
  return i.tur === 'OKUNAMADI' && i.yon === 'ORTAK' ? OKUNAMADI_TEK_KAPI : TUR_ACIKLAMA[i.tur]
}

/**
 * What an OKUNAMADI row carries in `ham_yanit` (039): the model's guess and
 * confidence, or that plate reading itself failed. The raw error goes to the
 * Yönetici's alert only — it is not for the gate.
 */
function okumaBilgisi(i: Istisna): { tahmin: string | null; guven: number | null; servisHatasi: boolean } {
  const ham: Record<string, unknown> = i.tur === 'OKUNAMADI' && i.ham_yanit ? i.ham_yanit : {}
  return {
    tahmin: typeof ham.tahmin === 'string' && ham.tahmin ? ham.tahmin : null,
    guven: typeof ham.guven === 'number' ? ham.guven : null,
    servisHatasi: typeof ham.hata === 'string',
  }
}

/**
 * Exceptions a person has to act on. The camera deliberately declined to act,
 * so the "do not enter it by hand" note below would be exactly the wrong
 * advice for these. An unreadable plate is one: the bridge does not retry a
 * 422 it receives, and a failed read is only recorded on its last attempt.
 * The car CAN be read later, but rarely and not in a way worth waiting for:
 *   - if the 422 reply is lost, the bridge retries the same event within
 *     about two minutes; on the single gate 041 then closes this row (or adds
 *     the plate), on the entrance lane the retry opens the ticket and this
 *     row stays open;
 *   - a later photo of the same car is a new event: it opens the ticket and
 *     leaves this row open.
 * That is why both OKUNAMADI texts above end by telling staff to mark the row
 * resolved when the car already has a ticket.
 */
const KENDILIGINDEN_COZULMEZ: ReadonlySet<IstisnaTur> = new Set(['YON_BELIRSIZ', 'OKUNAMADI'])

export default function Istisnalar() {
  const navigate = useNavigate()
  // Unlike the rest of /yonetim, this screen is open to Personel — deleting is
  // not. The RPC refuses them either way; this stops them tapping a control
  // that could only fail.
  const yonetici = isYonetici(useAuth().profile)
  const [sadeceAcik, setSadeceAcik] = useState(true)
  const { data: liste = [], isPending, error, refetch } = useIstisnalar(sadeceAcik)
  const coz = useIstisnaCoz()
  const sil = useKayitSil()

  const [secili, setSecili] = useState<Istisna | null>(null)
  const [not, setNot] = useState('')
  const [hata, setHata] = useState<string | null>(null)
  const [silinecek, setSilinecek] = useState<Istisna | null>(null)
  const [silHata, setSilHata] = useState<string | null>(null)

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
                onSil={
                  yonetici
                    ? () => {
                        setSilHata(null)
                        setSilinecek(i)
                      }
                    : undefined
                }
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

      <ConfirmDialog
        open={silinecek !== null}
        onOpenChange={() => setSilinecek(null)}
        tone="danger"
        title="Kaydı sil"
        description={
          "Bu olay kaydı listeden tamamen kalkar. Sadece işini bitirmek istiyorsanız “Çözüldü” yeterlidir — kayıt saklanır. Çöp Kutusu'ndan geri alınabilir."
        }
        confirmLabel="Sil"
        loading={sil.isPending}
        error={silHata}
        onConfirm={() => {
          if (!silinecek) return
          void sil
            .mutateAsync({ tablo: 'istisnalar', id: silinecek.id })
            .then(() => setSilinecek(null))
            .catch((e) => setSilHata(rpcErrorText(e, 'Silinemedi.')))
        }}
      />
    </div>
  )
}

function IstisnaKart({
  istisna: i,
  onCoz,
  onCikis,
  onSil,
}: {
  istisna: Istisna
  onCoz: () => void
  onCikis: () => void
  onSil?: () => void
}) {
  const { data: fotoUrl } = useFotoUrl(i.foto_path)
  const cozuldu = i.cozuldu_at !== null
  const okuma = okumaBilgisi(i)

  // Both timestamps are kept precisely so this lag is visible. A camera that
  // buffered through an outage shows up here as hours, and a camera whose
  // clock has drifted shows up as a constant offset — the difference between
  // those two is the difference between a network problem and mis-billing.
  const gecikmeDk = i.kaynak_zaman ? dakikaFarki(i.kaynak_zaman, i.alindi_zaman) : 0

  return (
    <Card className={cozuldu ? 'opacity-70' : ''}>
      <div className="flex items-start gap-2">
        <div className="flex min-w-0 flex-1 flex-wrap items-center gap-2">
          <Chip tone={TUR_TONE[i.tur]}>{ISTISNA_ETIKET[i.tur]}</Chip>
          <Chip tone="neutral">{KAMERA_YON_ETIKET[i.yon]}</Chip>
          {i.kaynak === 'KAMERA' && (
            <Chip tone="neutral">
              <IconKamera size={13} />
              Kamera
            </Chip>
          )}
          {cozuldu && <Chip tone="success">Çözüldü</Chip>}
        </div>
        {onSil && (
          <button
            type="button"
            onClick={onSil}
            aria-label="Kaydı sil"
            className="-mt-1.5 -mr-1.5 flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field"
          >
            <IconCop size={18} />
          </button>
        )}
      </div>

      <p className="mt-2.5 text-lead font-semibold tracking-wide text-ink tnum">
        {i.plaka ? formatPlaka(i.plaka) : 'Plaka okunamadı'}
      </p>

      <p className="mt-1 text-label text-faint">
        {i.kaynak_zaman ? `Olay ${formatTam(i.kaynak_zaman)} · ` : ''}
        Alındı {formatTam(i.alindi_zaman)}
        {gecikmeDk >= 2 ? ` · ${formatSure(gecikmeDk)} gecikmeli` : ''}
      </p>

      {okuma.tahmin && (
        <p className="mt-1 text-label text-faint">
          Modelin tahmini: <span className="tnum">{formatPlaka(okuma.tahmin)}</span>
          {okuma.guven !== null ? ` · güven %${Math.round(okuma.guven * 100)}` : ''} — kesin değil
        </p>
      )}
      {okuma.servisHatasi && (
        <p className="mt-1 text-label text-faint">Plaka okuma servisi o sırada çalışmıyordu.</p>
      )}

      <p className="mt-2 text-body text-soft">{aciklama(i)}</p>

      {i.kaynak === 'KAMERA' && !cozuldu && !KENDILIGINDEN_COZULMEZ.has(i.tur) && (
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
          {/* A doubtful single-gate read may well be a departure, so it gets
              the same shortcut an exit-lane exception does — and so does an
              unreadable plate on the single gate. */}
          {((i.tur !== 'GELECEK' && i.yon === 'CIKIS') ||
            i.tur === 'YON_BELIRSIZ' ||
            (i.tur === 'OKUNAMADI' && i.yon === 'ORTAK')) && (
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
