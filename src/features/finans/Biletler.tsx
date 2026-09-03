import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router'
import {
  Card,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { useBiletGecmisi } from './api'
import { IstatKutu } from '../yonetim/components'
import { formatPlaka } from '../../lib/plaka'
import { formatTL } from '../../lib/money'
import { formatGoreceli } from '../../lib/dates'
import { sureMetni } from '../../lib/sure'
import { olusturanAdi } from '../../lib/olusturan'
import { useAdlar } from '../yonetim/api'
import { IconAra, IconAraba } from '../../components/ui/icons'
import {
  ODEME_CHIP,
  ODEME_DURUM_ETIKET,
  ODEME_ETIKET,
  ONAY_CHIP,
  ONAY_ETIKET,
  type BiletDurum,
  type OdemeYontemi,
} from '../../lib/types'
import { biletBorcu, odemeAlindi, onayDurumu } from '../../lib/bilet'

const FILTRELER: { value: BiletDurum | 'TUMU'; label: string }[] = [
  { value: 'TUMU', label: 'Tümü' },
  { value: 'ACIK', label: 'İçeride' },
  { value: 'KAPALI', label: 'Çıktı' },
  { value: 'IPTAL', label: 'İptal' },
]

export default function Biletler() {
  // Once for the list, handed to each row — the rows are markup here rather
  // than a component, but the rule is the same one BiletKart documents.
  const adlar = useAdlar()
  const navigate = useNavigate()
  const [durum, setDurum] = useState<BiletDurum | 'TUMU'>('TUMU')
  const [q, setQ] = useState('')
  const { data: liste = [], isPending, error, refetch } = useBiletGecmisi({ durum, q })

  /**
   * Totals for what is ON SCREEN — the current filter, capped at the same 200
   * rows the header names. Deliberately not an all-time figure: this query has
   * no date range and takes the newest 200, so a bare "toplam" here would be a
   * number nobody could reproduce. Finans is where the real totals live.
   */
  const ozet = useMemo(() => {
    const tahsilat = liste.reduce((a, b) => a + b.tahsil_kurus, 0)
    const cikan = liste.filter((b) => b.durum === 'KAPALI').length
    const iptal = liste.filter((b) => b.durum === 'IPTAL').length

    const yontemler: { etiket: string; net: number }[] = (
      ['NAKIT', 'KREDI_KARTI', 'HAVALE'] as OdemeYontemi[]
    ).map((y) => ({
      etiket: ODEME_ETIKET[y],
      net: liste.filter((b) => b.odeme_yontemi === y).reduce((a, b) => a + b.tahsil_kurus, 0),
    }))
    // Kept for the same reason as on Kasa, though the database makes it
    // unlikely here: a non-zero collection requires a method. If one ever
    // appears without one, the three channels must not quietly fail to add up.
    const yontemsiz = liste
      .filter((b) => !b.odeme_yontemi)
      .reduce((a, b) => a + b.tahsil_kurus, 0)
    if (yontemsiz !== 0) yontemler.push({ etiket: 'yöntemsiz', net: yontemsiz })

    return { tahsilat, cikan, iptal, yontemler }
  }, [liste])

  return (
    <div>
      <ScreenHeader title="Bilet geçmişi" back="/finans" subtitle="Son 200 kayıt" />

      <div className="space-y-3 px-5">
        <Card>
          <div className="grid grid-cols-3 gap-3">
            <IstatKutu deger={formatTL(ozet.tahsilat, { decimals: 0 })} etiket="tahsilat" />
            <IstatKutu deger={String(ozet.cikan)} etiket="çıkan" tone="success" />
            <IstatKutu
              deger={String(ozet.iptal)}
              etiket="iptal"
              tone={ozet.iptal > 0 ? 'danger' : 'default'}
            />
          </div>

          <div className="mt-3 flex flex-wrap gap-x-6 gap-y-2 border-t border-border pt-3">
            {ozet.yontemler.map((y) => (
              <div key={y.etiket}>
                <p className="text-lead font-semibold text-ink tnum">
                  {formatTL(y.net, { decimals: 0 })}
                </p>
                <p className="text-label text-faint">{y.etiket}</p>
              </div>
            ))}
          </div>

          {/* Two caveats, and both earn their place: the figures describe the
              rows below rather than all time, and barrier money is not revenue
              until it clears Onay. */}
          <p className="mt-3 text-label text-faint">
            Listedeki biletlerin toplamı — onaylananlar Finans'taki ciroya girer.
          </p>
        </Card>

        <div className="relative">
          <IconAra
            size={20}
            className="pointer-events-none absolute top-1/2 left-4 -translate-y-1/2 text-faint"
          />
          <Input
            label="Plaka ara"
            hideLabel
            value={q}
            onChange={(e) => setQ(e.target.value.toUpperCase())}
            placeholder="Plaka ara"
            autoCapitalize="characters"
            autoCorrect="off"
            spellCheck={false}
            className="pl-11 tnum"
          />
        </div>

        <div className="flex gap-2 overflow-x-auto pb-1">
          {FILTRELER.map((f) => (
            <button
              key={f.value}
              type="button"
              onClick={() => setDurum(f.value)}
              className={[
                'min-h-[40px] shrink-0 rounded-chip px-4 text-body font-medium transition-colors',
                durum === f.value ? 'bg-ink text-bg' : 'bg-field text-soft',
              ].join(' ')}
            >
              {f.label}
            </button>
          ))}
        </div>

        <div className="space-y-2">
          <ListeDurumu
            pending={isPending}
            error={error}
            onRetry={() => void refetch()}
            empty={liste.length === 0}
            bos={<EmptyState icon={<IconAraba size={44} />} title="Kayıt yok" />}
          >
            {liste.map((b) => (
              <Card key={b.id} as="div">
                <button
                  type="button"
                  onClick={() => navigate(`/gise/bilet/${b.id}`)}
                  className="w-full text-left"
                >
                  <div className="flex items-baseline justify-between gap-3">
                    <span className="truncate text-lead font-semibold tracking-wide text-ink tnum">
                      {formatPlaka(b.plaka)}
                    </span>
                    <span
                      className={`shrink-0 text-body font-semibold tnum ${
                        b.durum === 'IPTAL' ? 'text-faint line-through' : 'text-ink'
                      }`}
                    >
                      {/* The FEE, not what was collected: since 027 a closed
                          ticket can owe money, and printing tahsil_kurus made
                          a debt look identical to a free abonman exit. */}
                      {b.durum === 'ACIK' ? '—' : formatTL(biletBorcu(b))}
                    </span>
                  </div>

                  <div className="mt-1 flex flex-wrap items-center gap-2">
                    <span className="text-label text-faint">
                      {formatGoreceli(b.giris_at)} · {sureMetni(b.giris_at, b.cikis_at)}
                      {/* Exit side once the car has gone (who took the money),
                          entry side while it is still inside (who let it in) —
                          each row shows the half that can be asked about. */}
                      {' · '}
                      {b.cikis_at
                        ? olusturanAdi(b.cikis_by, b.cikis_kaynak, adlar)
                        : olusturanAdi(b.giris_by, b.giris_kaynak, adlar)}
                    </span>
                    {/* Whether the money was taken at all comes before
                        whether it counts: an unpaid exit has nothing to
                        approve, so the approval chip below is absent and
                        this is the only thing that explains the row. */}
                    {b.durum === 'KAPALI' && (
                      <span
                        className={`rounded-chip px-2 py-0.5 text-micro font-medium ${
                          odemeAlindi(b)
                            ? 'bg-success-soft text-success'
                            : biletBorcu(b) > 0
                              ? 'bg-warn-soft text-warn'
                              : 'bg-field text-soft'
                        }`}
                      >
                        {ODEME_DURUM_ETIKET[odemeAlindi(b) ? 'ALINDI' : 'ALINMADI']}
                      </span>
                    )}
                    {/* Then: whether this money counts is a bigger fact about
                        the ticket than how it was paid. */}
                    {(() => {
                      const onay = onayDurumu(b)
                      return onay ? (
                        <span
                          className={`rounded-chip px-2 py-0.5 text-micro font-medium ${ONAY_CHIP[onay]}`}
                        >
                          {ONAY_ETIKET[onay]}
                        </span>
                      ) : null
                    })()}
                    {b.odeme_yontemi && (
                      <span
                        className={`rounded-chip px-2 py-0.5 text-micro font-medium ${ODEME_CHIP[b.odeme_yontemi]}`}
                      >
                        {ODEME_ETIKET[b.odeme_yontemi]}
                      </span>
                    )}
                    {b.abonman_id && (
                      <span className="rounded-chip bg-success-soft px-2 py-0.5 text-micro font-medium text-success">
                        Abonman
                      </span>
                    )}
                    {b.ucret_degistirildi && (
                      <span className="rounded-chip bg-danger-soft px-2 py-0.5 text-micro font-medium text-danger">
                        Ücret değişti
                      </span>
                    )}
                    {b.kayip_bilet && (
                      <span className="rounded-chip bg-warn-soft px-2 py-0.5 text-micro font-medium text-warn">
                        Kayıp bilet
                      </span>
                    )}
                    {b.giris_kaynak === 'KAMERA' && (
                      <span className="rounded-chip bg-field px-2 py-0.5 text-micro font-medium text-soft">
                        Kamera
                      </span>
                    )}
                  </div>
                </button>
              </Card>
            ))}
          </ListeDurumu>
        </div>
      </div>
    </div>
  )
}
