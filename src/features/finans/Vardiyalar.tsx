import { useState } from 'react'
import {
  Card,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { useTumVardiyalar, useVardiyaZorlaKapat } from './api'
import { useProfiller } from '../yonetim/api'
import { formatTL, parseTLToKurus } from '../../lib/money'
import { formatTam } from '../../lib/dates'
import { sureMetni } from '../../lib/sure'
import { rpcErrorText } from '../../lib/errors'
import { IconVardiya } from '../../components/ui/icons'
import type { Vardiya } from '../../lib/types'

/**
 * Every shift, with its cash count.
 *
 * The difference column is the point of this screen — a shift that comes up
 * short is the single clearest signal in a cash business, and it should be
 * readable in one scan.
 *
 * A shift with NO count reads as "Sayım yok", never as ₺0 and never as
 * "Tutuyor". Those are three different facts and only one of them is true
 * when nobody opened the drawer.
 */
export default function Vardiyalar() {
  const { data: liste = [], isPending, error, refetch } = useTumVardiyalar()
  const { data: profiller = [] } = useProfiller()
  const zorlaKapat = useVardiyaZorlaKapat()

  const [hedef, setHedef] = useState<Vardiya | null>(null)
  const [sayilan, setSayilan] = useState('')
  const [notlar, setNotlar] = useState('')
  const [hata, setHata] = useState<string | null>(null)

  // `id` is null on a shift the cron opened (030): there is no opener to name,
  // and 'Bilinmiyor' would read as a missing record rather than an automatic
  // one — two very different things when the number underneath is cash.
  const ad = (id: string | null) =>
    id === null
      ? 'Otomatik açıldı'
      : profiller.find((p) => p.id === id)?.ad_soyad || 'Bilinmiyor'

  function kapatmayiAc(v: Vardiya) {
    setHedef(v)
    setSayilan('')
    setNotlar('')
    setHata(null)
  }

  function kapat() {
    if (!hedef) return
    const ham = sayilan.trim()
    let kurus: number | null = null
    // Empty is a real answer here, not a missing one: nobody counted.
    if (ham) {
      const parsed = parseTLToKurus(ham)
      if (parsed === null || parsed < 0) {
        setHata('Sayılan nakdi geçerli girin.')
        return
      }
      kurus = parsed
    }
    void zorlaKapat
      .mutateAsync({ id: hedef.id, sayilan: kurus, notlar: notlar.trim() || null })
      .then(() => setHedef(null))
      .catch((e) => setHata(rpcErrorText(e, 'Vardiya kapatılamadı.')))
  }

  return (
    <div>
      <ScreenHeader title="Vardiyalar" back="/finans" subtitle="Son 100 vardiya" />

      <div className="space-y-2 px-5">
        <ListeDurumu
          pending={isPending}
          error={error}
          onRetry={() => void refetch()}
          empty={liste.length === 0}
          bos={<EmptyState icon={<IconVardiya size={44} />} title="Vardiya kaydı yok" />}
        >
          {liste.map((v) => {
            const acik = v.kapanis_at === null
            const fark = v.fark_kurus
            return (
              <Card key={v.id}>
                <div className="flex items-start justify-between gap-3">
                  <div className="min-w-0">
                    {/* The drawer is shared, so the accountable person is the
                        one who COUNTED it. Falls back to the opener, which is
                        also what every pre-030 row resolves to. */}
                    <p className="truncate text-body font-medium text-ink">
                      {ad(v.kapatan_id ?? v.personel_id)}
                    </p>
                    {v.kapatan_id && v.personel_id && v.kapatan_id !== v.personel_id && (
                      <p className="mt-0.5 text-label text-faint">
                        Açan: {ad(v.personel_id)}
                      </p>
                    )}
                    <p className="mt-0.5 text-label text-faint">
                      {formatTam(v.acilis_at)} ·{' '}
                      {acik ? 'devam ediyor' : sureMetni(v.acilis_at, v.kapanis_at)}
                    </p>
                    {/* Only when it was not the operator: a normal close needs
                        no label, an unusual one does. */}
                    {!acik && v.kapanis_kaynak && v.kapanis_kaynak !== 'ELLE' && (
                      <p className="mt-1 text-label text-warn">
                        {v.kapanis_kaynak === 'OTOMATIK'
                          ? 'Otomatik kapatıldı'
                          : 'Yönetici kapattı'}
                      </p>
                    )}
                  </div>

                  {acik ? (
                    <span className="shrink-0 rounded-chip bg-accent-soft px-2.5 py-1 text-label font-medium text-accent">
                      Açık
                    </span>
                  ) : fark === null ? (
                    <span className="shrink-0 rounded-chip bg-warn-soft px-2.5 py-1 text-label font-medium text-warn">
                      Sayım yok
                    </span>
                  ) : fark === 0 ? (
                    <span className="shrink-0 rounded-chip bg-success-soft px-2.5 py-1 text-label font-medium text-success">
                      Tutuyor
                    </span>
                  ) : (
                    <span
                      className={`shrink-0 rounded-chip px-2.5 py-1 text-label font-medium tnum ${
                        fark < 0 ? 'bg-danger-soft text-danger' : 'bg-warn-soft text-warn'
                      }`}
                    >
                      {fark > 0 ? '+' : ''}
                      {formatTL(fark)}
                    </span>
                  )}
                </div>

                {/* Its own row, not beside the status chip. At 375px a name, a
                    chip and a button in one line squeezed the date column
                    until it wrapped mid-phrase — and this is the wider tap
                    target anyway.

                    The operator's own close is the good path; this is for the
                    shift whose owner cannot close it — they left, or their
                    account was disabled. Without it they can never open
                    another shift. */}
                {acik && (
                  <div className="mt-3 flex justify-end border-t border-divider pt-3">
                    <button
                      type="button"
                      onClick={() => kapatmayiAc(v)}
                      className="min-h-[40px] rounded-chip bg-field px-4 text-label font-medium text-soft active:bg-border"
                    >
                      Vardiyayı kapat
                    </button>
                  </div>
                )}

                {!acik && v.beklenen_nakit_kurus !== null && (
                  <div className="mt-3 flex gap-4 border-t border-divider pt-3 text-label">
                    <span className="text-faint">
                      Beklenen{' '}
                      <span className="text-soft tnum">{formatTL(v.beklenen_nakit_kurus)}</span>
                    </span>
                    <span className="text-faint">
                      Sayılan{' '}
                      {v.sayilan_nakit_kurus === null ? (
                        <span className="text-warn">sayılmadı</span>
                      ) : (
                        <span className="text-soft tnum">{formatTL(v.sayilan_nakit_kurus)}</span>
                      )}
                    </span>
                  </div>
                )}

                {v.notlar && <p className="mt-2 text-label text-faint">{v.notlar}</p>}
              </Card>
            )
          })}
        </ListeDurumu>
      </div>

      <FormModal
        open={hedef !== null}
        onOpenChange={(o) => {
          if (!o) setHedef(null)
        }}
        title="Vardiyayı kapat"
        submitLabel="Kapat"
        loading={zorlaKapat.isPending}
        error={hata}
        onSubmit={kapat}
      >
        <p className="text-body text-soft">
          {hedef ? `${ad(hedef.personel_id)} — ${formatTam(hedef.acilis_at)}` : ''}
        </p>
        <Input
          label="Sayılan nakit (₺) — isteğe bağlı"
          value={sayilan}
          onChange={(e) => setSayilan(e.target.value)}
          inputMode="decimal"
          placeholder="Sayılmadıysa boş bırakın"
          hint="Boş bırakırsanız fark hesaplanmaz. Sayılmayan bir kasaya rakam yazmak, eksiği kalıcı olarak gizler."
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
