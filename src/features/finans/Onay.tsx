import { useMemo, useState } from 'react'
import {
  Button,
  Card,
  EmptyState,
  FloatingBar,
  Input,
  ListeDurumu,
  ScreenHeader,
  SegmentedControl,
} from '../../components/ui/primitives'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import {
  useOnayListesi,
  useOnayOzet,
  useTahsilatOnayla,
  useTahsilatReddet,
} from './api'
import { formatTL } from '../../lib/money'
import { formatTam } from '../../lib/dates'
import { formatPlaka } from '../../lib/plaka'
import { rpcErrorText } from '../../lib/errors'
import { ODEME_ETIKET, type OnayDurum } from '../../lib/types'
import { IconOnay, IconTik } from '../../components/ui/icons'

/**
 * The gate between money collected at the barrier and money in the books.
 *
 * Bilet and abonman collections are born BEKLIYOR; Finans counts only what
 * has been approved here. Yönetici only — the route guard says so and every
 * RPC behind it re-checks, which is where the boundary actually is.
 *
 * What this screen deliberately does NOT do is move cash. Approving does not
 * collect anything and rejecting does not refund anything: the money changed
 * hands at the barrier either way, and the shift's own cash count still
 * expects it. A decision here answers one question — does this belong in the
 * revenue figures — and the rejected list is what keeps the answer "no" from
 * quietly meaning "gone".
 *
 * SELECT, THEN ACT. A pair of buttons on every card put two hundred controls
 * on a screen for a hundred cars and forced a decision one row at a time,
 * which is not how this list is actually worked: nearly everything is
 * approved, and the exception is picked out by eye. So a tap selects, and the
 * verbs live in one bar in the thumb zone. With nothing selected that bar
 * approves the whole visible list, which is the ordinary case in one tap.
 */
export default function Onay() {
  const [sekme, setSekme] = useState<OnayDurum>('BEKLIYOR')
  const liste = useOnayListesi(sekme)
  const ozet = useOnayOzet()

  const onayla = useTahsilatOnayla()
  const reddet = useTahsilatReddet()

  const [secili, setSecili] = useState<Set<string>>(new Set())
  const [sebep, setSebep] = useState('')
  /** Which dialog is open, if any. */
  const [soru, setSoru] = useState<'ONAY' | 'RET' | null>(null)
  const [hata, setHata] = useState<string | null>(null)
  const [sonuc, setSonuc] = useState<string | null>(null)

  const kayitlar = liste.data ?? []
  const bekleyen = sekme === 'BEKLIYOR'

  // Ids by value, not the Set itself: a row can disappear between the tap and
  // the decision (someone else decided it, a ticket was cancelled), and acting
  // on a stale id would be asking the server about money that moved. The
  // server skips whatever is no longer BEKLIYOR, and the count it returns is
  // what the screen reports.
  const hedef = useMemo(() => {
    const gorunen = kayitlar.map((k) => k.id)
    return secili.size > 0 ? gorunen.filter((id) => secili.has(id)) : gorunen
  }, [kayitlar, secili])

  const hedefToplam = useMemo(
    () => kayitlar.filter((k) => hedef.includes(k.id)).reduce((a, k) => a + k.tutar_kurus, 0),
    [kayitlar, hedef],
  )

  function sec(id: string) {
    setHata(null)
    setSonuc(null)
    setSecili((onceki) => {
      const yeni = new Set(onceki)
      if (yeni.has(id)) yeni.delete(id)
      else yeni.add(id)
      return yeni
    })
  }

  function kapat() {
    setSoru(null)
    setSebep('')
    setHata(null)
  }

  /** Both verbs report the same way: what the server actually moved. */
  function bitir(n: number, fiil: string) {
    setSecili(new Set())
    kapat()
    setSonuc(
      n === 0
        ? 'Hiçbir tahsilat ' + fiil + ' — hepsi zaten karara bağlanmış.'
        : n < hedef.length
          ? n + ' tahsilat ' + fiil + '; ' + (hedef.length - n) + ' tanesi zaten karara bağlanmıştı.'
          : n + ' tahsilat ' + fiil + '.',
    )
  }

  return (
    <div className="md:mx-auto md:max-w-[760px]">
      <ScreenHeader title="Onay" back="/finans" />

      <div className="space-y-4 px-5">
        <SegmentedControl<OnayDurum>
          value={sekme}
          onChange={(v) => {
            setSekme(v)
            setSecili(new Set())
            setHata(null)
            setSonuc(null)
          }}
          options={[
            { value: 'BEKLIYOR', label: 'Bekleyen' },
            { value: 'ONAYLANDI', label: 'Onaylanan' },
            { value: 'REDDEDILDI', label: 'Reddedilen' },
          ]}
        />

        {bekleyen && (ozet.data?.adet ?? 0) > 0 && (
          <Card>
            <p className="text-title font-semibold text-ink tnum">
              {formatTL(ozet.data?.toplam_kurus ?? 0)}
            </p>
            <p className="mt-0.5 text-label text-faint tnum">
              {ozet.data?.adet ?? 0} tahsilat onay bekliyor
            </p>
          </Card>
        )}

        {sonuc && <p className="text-body text-success">{sonuc}</p>}

        <ListeDurumu
          pending={liste.isPending}
          error={liste.error}
          onRetry={() => void liste.refetch()}
          empty={kayitlar.length === 0}
          bos={
            <EmptyState
              icon={<IconOnay size={22} />}
              title={bekleyen ? 'Onay bekleyen tahsilat yok' : 'Kayıt yok'}
              hint={
                bekleyen
                  ? 'Bilet ve abonman tahsilatları burada birikir; onaylananlar Finans’a geçer.'
                  : undefined
              }
            />
          }
        >
          <ul className="space-y-3">
            {kayitlar.map((k) => {
              const isaretli = secili.has(k.id)
              const govde = (
                <>
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-body font-semibold text-ink">
                      {k.etiket ? formatPlaka(k.etiket) : 'Kaydı silinmiş'}
                      <span className="ml-2 text-label font-medium text-faint">
                        {k.tur === 'BILET' ? 'Bilet' : 'Abonman'}
                      </span>
                    </p>
                    <p className="mt-0.5 text-label text-faint">
                      {formatTam(k.created_at)} · {k.personel} · {ODEME_ETIKET[k.yontem]}
                    </p>
                    {k.aciklama && <p className="mt-0.5 text-label text-faint">{k.aciklama}</p>}
                    {k.onay_notu && <p className="mt-0.5 text-label text-danger">{k.onay_notu}</p>}
                  </div>
                  {/* Negative rows are cancellation counter-entries: the minus
                      sign is the whole difference between a collection and its
                      undoing, so it is never stripped. */}
                  <p className="shrink-0 text-lead font-semibold text-ink tnum">
                    {formatTL(k.tutar_kurus)}
                  </p>
                </>
              )

              // Only the pending tab is interactive. A decided row is a record,
              // and making it look tappable would promise an action that does
              // not exist — decided rows are immutable by design.
              return (
                <li key={k.id}>
                  {bekleyen ? (
                    <button
                      type="button"
                      onClick={() => sec(k.id)}
                      aria-pressed={isaretli}
                      className={[
                        'flex w-full items-start gap-3 rounded-card border bg-surface p-4 text-left shadow-card',
                        'transition-transform duration-100 active:scale-[0.99]',
                        isaretli ? 'border-accent inset-ring-1 inset-ring-accent' : 'border-border',
                      ].join(' ')}
                    >
                      {/* The tick box carries the state on its own, so the
                          selection survives being read in sunlight where a
                          border tint alone would not. */}
                      <span
                        className={[
                          'mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-[6px] border',
                          isaretli
                            ? 'border-accent bg-accent text-accent-ink'
                            : 'border-border bg-field text-transparent',
                        ].join(' ')}
                      >
                        <IconTik size={14} />
                      </span>
                      {govde}
                    </button>
                  ) : (
                    <Card className="flex items-start gap-3">{govde}</Card>
                  )}
                </li>
              )
            })}
          </ul>
        </ListeDurumu>

        {hata && <p className="text-body text-danger">{hata}</p>}
      </div>

      {bekleyen && hedef.length > 0 && (
        <FloatingBar>
          <div className="flex items-center gap-2">
            <Button
              className="flex-1"
              onClick={() => {
                setHata(null)
                setSoru('ONAY')
              }}
            >
              {secili.size > 0 ? 'Onayla (' + hedef.length + ')' : 'Tümünü onayla'}
            </Button>
            <Button
              variant="secondary"
              onClick={() => {
                setSebep('')
                setHata(null)
                setSoru('RET')
              }}
            >
              Reddet
            </Button>
          </div>
          {/* Says what the bar would act on when nothing is ticked, because
              "Tümünü onayla" is otherwise a promise with no stated size. */}
          <p className="mt-2 text-center text-label text-faint tnum">
            {secili.size > 0 ? 'Seçili: ' : 'Listedeki '}
            {hedef.length} tahsilat · {formatTL(hedefToplam)}
          </p>
        </FloatingBar>
      )}

      <ConfirmDialog
        open={soru === 'ONAY'}
        onOpenChange={kapat}
        title={secili.size > 0 ? 'Seçilenleri onayla' : 'Listedekileri onayla'}
        description={
          hedef.length + ' tahsilat, toplam ' + formatTL(hedefToplam) + ', ciroya eklenecek.'
        }
        confirmLabel="Onayla"
        loading={onayla.isPending}
        error={hata}
        onConfirm={() => {
          setHata(null)
          void onayla
            .mutateAsync(hedef)
            .then((n) => bitir(n, 'onaylandı'))
            .catch((e) => setHata(rpcErrorText(e, 'Onaylanamadı.')))
        }}
      />

      <ConfirmDialog
        open={soru === 'RET'}
        onOpenChange={kapat}
        title={secili.size > 0 ? 'Seçilenleri reddet' : 'Listedekileri reddet'}
        description={
          hedef.length +
          ' tahsilat, toplam ' +
          formatTL(hedefToplam) +
          ', ciroya girmeyecek. Para vardiya sayımında durmaya devam eder.'
        }
        confirmLabel="Reddet"
        tone="danger"
        loading={reddet.isPending}
        error={hata}
        onConfirm={() => {
          setHata(null)
          void reddet
            .mutateAsync({ ids: hedef, sebep })
            .then((n) => bitir(n, 'reddedildi'))
            .catch((e) => setHata(rpcErrorText(e, 'Reddedilemedi.')))
        }}
      >
        <Input
          label="Sebep (isteğe bağlı)"
          value={sebep}
          onChange={(e) => setSebep(e.target.value)}
          maxLength={200}
        />
      </ConfirmDialog>
    </div>
  )
}
