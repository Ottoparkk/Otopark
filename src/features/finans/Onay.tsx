import { useMemo, useState, type ReactNode } from 'react'
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
import { Spinner } from '../../components/ui/Spinner'
import {
  useBiletIptalOnayla,
  useBiletIptalReddet,
  useIptalTalepleri,
  useKararlar,
  useOnayListesi,
  useOnayOzet,
  useTahsilatOnayla,
  useTahsilatReddet,
  useVardiyaKapatmaOnayla,
  useVardiyaKapatmaReddet,
  useVardiyaTalepleri,
} from './api'
import { varsayilanKategori, type Karar, type KararTur, type OnayKategori } from './kararlar'
import { useVardiyaOzetim } from '../vardiya/api'
import { useAdlar } from '../yonetim/api'
import { formatTL } from '../../lib/money'
import { formatTam } from '../../lib/dates'
import { formatPlaka } from '../../lib/plaka'
import { rpcErrorText } from '../../lib/errors'
import { ODEME_ETIKET, type Bilet, type OnayDurum, type VardiyaTalebi } from '../../lib/types'
import { IconCarpi, IconEtiket, IconOnay, IconTik, IconVardiya } from '../../components/ui/icons'

/**
 * The gate between what happened at the barrier and what the books accept.
 *
 * Three queues, each a card at the top (owner, 2026-11-07):
 *  - Vardiya — shift-close requests (035);
 *  - Bilet ve abonman — collections born BEKLIYOR; Finans counts only what is
 *    approved here;
 *  - Bilet iptali — Personel's cancel requests on open tickets (050).
 * Under the cards one Bekleyen / Onaylanan / Reddedilen control applies to
 * the selected card. Yönetici only — the route guard says so and every RPC
 * behind it re-checks, which is where the boundary actually is.
 *
 * What this screen deliberately does NOT do is move cash. Approving a
 * collection does not collect anything and rejecting it does not refund
 * anything: the money changed hands at the barrier, and the shift's own cash
 * count still expects it. The rejected list is what keeps "no" from quietly
 * meaning "gone".
 *
 * SELECT, THEN ACT (collections). Nearly everything is approved and the
 * exception is picked out by eye, so a tap selects and the verbs live in one
 * bar in the thumb zone; with nothing selected the bar approves the whole
 * visible list. The bar exists only on the Bilet ve abonman card: "Tümünü
 * onayla" must never sweep up a till close or a ticket cancel, which are one
 * decision at a time and carry their own buttons.
 *
 * Decided shift and cancel requests leave no row of their own, so their
 * Onaylanan / Reddedilen lists are read from audit_log (see kararlar.ts).
 */
export default function Onay() {
  const ozet = useOnayOzet()
  const talepler = useVardiyaTalepleri()
  const iptaller = useIptalTalepleri()
  const adlar = useAdlar()
  const ad = (id: string | null) => (id ? (adlar.get(id) ?? 'Bilinmiyor') : 'Bilinmiyor')

  // ---- which card ---------------------------------------------------------
  // Chosen ONCE, when all three counts have answered: the first card with
  // something waiting. Kept in state rather than derived, so approving the
  // last item of a card does not yank the screen to another card under the
  // operator's thumb (and take the "done" message with it). A count that
  // failed to load counts as 0 here; its card says so itself.
  const sayilar = {
    vardiya: talepler.data?.length ?? 0,
    bilet: ozet.data?.adet ?? 0,
    iptal: iptaller.data?.length ?? 0,
  }
  const sayimHazir = !talepler.isPending && !ozet.isPending && !iptaller.isPending
  const [kategori, setKategori] = useState<OnayKategori | null>(null)
  // Adjusting state during render (React's documented pattern), not an
  // effect: no frame is painted with the wrong card first.
  if (kategori === null && sayimHazir) setKategori(varsayilanKategori(sayilar))

  const [sekme, setSekme] = useState<OnayDurum>('BEKLIYOR')
  const bekleyen = sekme === 'BEKLIYOR'

  // ---- Bilet ve abonman ---------------------------------------------------
  const liste = useOnayListesi(sekme, kategori === 'BILET')
  const onayla = useTahsilatOnayla()
  const reddet = useTahsilatReddet()

  const [secili, setSecili] = useState<Set<string>>(new Set())
  const [sebep, setSebep] = useState('')
  /** Which dialog is open, if any. */
  const [soru, setSoru] = useState<'ONAY' | 'RET' | null>(null)
  const [hata, setHata] = useState<string | null>(null)
  /** One "done" line for whichever card was just acted on. */
  const [sonuc, setSonuc] = useState<string | null>(null)

  const kayitlar = liste.data ?? []

  // Ids by value, not the Set itself: a row can disappear between the tap and
  // the decision (someone else decided it, a ticket was cancelled). The
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

  // ---- Vardiya ------------------------------------------------------------
  // The CURRENT expected cash, to set against what the operator counted. The
  // request sits on the open shift and this RPC describes exactly that shift,
  // so the two always refer to the same drawer.
  const { data: vardiyaOzet } = useVardiyaOzetim()
  const vardiyaOnayla = useVardiyaKapatmaOnayla()
  const vardiyaReddet = useVardiyaKapatmaReddet()
  const [vardiyaSoru, setVardiyaSoru] = useState<{ t: VardiyaTalebi; tur: 'ONAY' | 'RET' } | null>(
    null,
  )
  const [vardiyaSebep, setVardiyaSebep] = useState('')
  const [vardiyaHata, setVardiyaHata] = useState<string | null>(null)

  const simdikiBeklenen = vardiyaOzet
    ? vardiyaOzet.acilis_nakit_kurus + vardiyaOzet.nakit_kurus
    : null

  function vardiyaKapat() {
    setVardiyaSoru(null)
    setVardiyaSebep('')
    setVardiyaHata(null)
  }

  // ---- Bilet iptali -------------------------------------------------------
  const iptalOnayla = useBiletIptalOnayla()
  const iptalReddet = useBiletIptalReddet()
  const [iptalSoru, setIptalSoru] = useState<{ b: Bilet; tur: 'ONAY' | 'RET' } | null>(null)
  const [iptalSebep, setIptalSebep] = useState('')
  const [iptalHata, setIptalHata] = useState<string | null>(null)

  function iptalKapat() {
    setIptalSoru(null)
    setIptalSebep('')
    setIptalHata(null)
  }

  /** Switching card or tab starts clean: nothing selected, no stale message. */
  function temizle() {
    setSecili(new Set())
    setHata(null)
    setSonuc(null)
  }

  const kararTuru: KararTur | null =
    kategori === 'VARDIYA' ? 'VARDIYA' : kategori === 'BILET_IPTAL' ? 'BILET_IPTAL' : null

  return (
    <div className="md:mx-auto md:max-w-[760px]">
      <ScreenHeader title="Onay" back="/finans" />

      <div className="space-y-4 px-5">
        {/* Three columns at every width: at 360 px each card is ~100 px, which
            fits a two-line label and the count. Wrapping to two rows would put
            one queue below the fold of its own row and read as less important. */}
        <div className="grid grid-cols-3 gap-2" role="group" aria-label="Onay türü">
          <KategoriKarti
            etiket="Vardiya"
            icon={<IconVardiya size={18} />}
            sayi={talepler.error ? null : talepler.isPending ? undefined : sayilar.vardiya}
            secili={kategori === 'VARDIYA'}
            onClick={() => {
              setKategori('VARDIYA')
              temizle()
            }}
          />
          <KategoriKarti
            etiket="Bilet ve abonman"
            icon={<IconEtiket size={18} />}
            sayi={ozet.error ? null : ozet.isPending ? undefined : sayilar.bilet}
            secili={kategori === 'BILET'}
            onClick={() => {
              setKategori('BILET')
              temizle()
            }}
          />
          <KategoriKarti
            etiket="Bilet iptali"
            icon={<IconCarpi size={18} />}
            sayi={iptaller.error ? null : iptaller.isPending ? undefined : sayilar.iptal}
            secili={kategori === 'BILET_IPTAL'}
            onClick={() => {
              setKategori('BILET_IPTAL')
              temizle()
            }}
          />
        </div>

        <SegmentedControl<OnayDurum>
          value={sekme}
          onChange={(v) => {
            setSekme(v)
            temizle()
          }}
          options={[
            { value: 'BEKLIYOR', label: 'Bekleyen' },
            { value: 'ONAYLANDI', label: 'Onaylanan' },
            { value: 'REDDEDILDI', label: 'Reddedilen' },
          ]}
        />

        {sonuc && <p className="text-body text-success">{sonuc}</p>}

        {kategori === null ? (
          <div className="py-14">
            <Spinner label="Yükleniyor" />
          </div>
        ) : kategori === 'BILET' ? (
          <>
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
                        {k.onay_notu && (
                          <p className="mt-0.5 text-label text-danger">{k.onay_notu}</p>
                        )}
                      </div>
                      {/* Negative rows are cancellation counter-entries: the
                          minus sign is the whole difference between a
                          collection and its undoing, so it is never stripped. */}
                      <p className="shrink-0 text-lead font-semibold text-ink tnum">
                        {formatTL(k.tutar_kurus)}
                      </p>
                    </>
                  )

                  // Only the pending tab is interactive. A decided row is a
                  // record — decided rows are immutable by design.
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
                            isaretli
                              ? 'border-accent inset-ring-1 inset-ring-accent'
                              : 'border-border',
                          ].join(' ')}
                        >
                          {/* The tick box carries the state on its own, so the
                              selection survives being read in sunlight. */}
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
          </>
        ) : !bekleyen && kararTuru ? (
          <KararListesi tur={kararTuru} sonuc={sekme === 'ONAYLANDI' ? 'ONAY' : 'RET'} ad={ad} />
        ) : kategori === 'VARDIYA' ? (
          <ListeDurumu
            pending={talepler.isPending}
            error={talepler.error}
            onRetry={() => void talepler.refetch()}
            empty={(talepler.data ?? []).length === 0}
            bos={<EmptyState icon={<IconVardiya size={22} />} title="Kapatma isteği yok" />}
          >
            <ul className="space-y-3">
              {(talepler.data ?? []).map((t) => (
                <li key={t.id}>
                  <TalepKarti
                    t={t}
                    ad={ad(t.kapatma_talebi_by)}
                    simdikiBeklenen={simdikiBeklenen}
                    onOnay={() => {
                      setVardiyaHata(null)
                      setSonuc(null)
                      setVardiyaSoru({ t, tur: 'ONAY' })
                    }}
                    onRet={() => {
                      setVardiyaSebep('')
                      setVardiyaHata(null)
                      setSonuc(null)
                      setVardiyaSoru({ t, tur: 'RET' })
                    }}
                  />
                </li>
              ))}
            </ul>
          </ListeDurumu>
        ) : (
          <ListeDurumu
            pending={iptaller.isPending}
            error={iptaller.error}
            onRetry={() => void iptaller.refetch()}
            empty={(iptaller.data ?? []).length === 0}
            bos={
              <EmptyState
                icon={<IconCarpi size={22} />}
                title="İptal isteği yok"
                hint="Personelin iptal etmek istediği açık biletler burada onay bekler."
              />
            }
          >
            <ul className="space-y-3">
              {(iptaller.data ?? []).map((b) => (
                <li key={b.id}>
                  <IptalKarti
                    b={b}
                    ad={ad(b.iptal_talebi_by ?? null)}
                    onOnay={() => {
                      setIptalHata(null)
                      setSonuc(null)
                      setIptalSoru({ b, tur: 'ONAY' })
                    }}
                    onRet={() => {
                      setIptalSebep('')
                      setIptalHata(null)
                      setSonuc(null)
                      setIptalSoru({ b, tur: 'RET' })
                    }}
                  />
                </li>
              ))}
            </ul>
          </ListeDurumu>
        )}
      </div>

      {kategori === 'BILET' && bekleyen && hedef.length > 0 && (
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

      {/* ---- collections ------------------------------------------------ */}
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

      {/* ---- shift close ------------------------------------------------ */}
      <ConfirmDialog
        open={vardiyaSoru?.tur === 'ONAY'}
        onOpenChange={vardiyaKapat}
        title="Vardiyayı kapat"
        description={
          'Sayılan ' +
          formatTL(vardiyaSoru?.t.talep_sayilan_kurus ?? 0) +
          ' ile vardiya kapanacak. Kapanmış vardiya geri açılmaz.'
        }
        confirmLabel="Onayla ve kapat"
        loading={vardiyaOnayla.isPending}
        error={vardiyaHata}
        onConfirm={() => {
          if (!vardiyaSoru) return
          setVardiyaHata(null)
          void vardiyaOnayla
            .mutateAsync(vardiyaSoru.t.id)
            .then((r) => {
              vardiyaKapat()
              setSonuc(
                r.fark_kurus === 0
                  ? 'Vardiya kapatıldı, kasa tutuyor.'
                  : 'Vardiya kapatıldı. Fark ' +
                      (r.fark_kurus > 0 ? '+' : '') +
                      formatTL(r.fark_kurus) +
                      '.',
              )
            })
            .catch((e) => setVardiyaHata(rpcErrorText(e, 'Vardiya kapatılamadı.')))
        }}
      />

      <ConfirmDialog
        open={vardiyaSoru?.tur === 'RET'}
        onOpenChange={vardiyaKapat}
        title="Kapatma isteğini reddet"
        description="Vardiya açık kalacak ve personel yeniden sayıp gönderebilecek."
        confirmLabel="Reddet"
        tone="danger"
        loading={vardiyaReddet.isPending}
        error={vardiyaHata}
        onConfirm={() => {
          if (!vardiyaSoru) return
          setVardiyaHata(null)
          void vardiyaReddet
            .mutateAsync({ id: vardiyaSoru.t.id, sebep: vardiyaSebep })
            .then(() => {
              vardiyaKapat()
              setSonuc('Kapatma isteği reddedildi, vardiya açık kaldı.')
            })
            .catch((e) => setVardiyaHata(rpcErrorText(e, 'Reddedilemedi.')))
        }}
      >
        {/* Reaches the operator as a notification, so it is the only place they
            learn WHY they are counting again. */}
        <Input
          label="Sebep (isteğe bağlı)"
          value={vardiyaSebep}
          onChange={(e) => setVardiyaSebep(e.target.value)}
          placeholder="Personele bildirilir"
          maxLength={200}
        />
      </ConfirmDialog>

      {/* ---- ticket cancel --------------------------------------------- */}
      <ConfirmDialog
        open={iptalSoru?.tur === 'ONAY'}
        onOpenChange={iptalKapat}
        title="Bileti iptal et"
        description={
          (iptalSoru ? formatPlaka(iptalSoru.b.plaka) : '') +
          ' bileti, personelin yazdığı sebeple iptal edilecek. Personele bildirilir.'
        }
        confirmLabel="Onayla ve iptal et"
        tone="danger"
        loading={iptalOnayla.isPending}
        error={iptalHata}
        onConfirm={() => {
          if (!iptalSoru) return
          setIptalHata(null)
          void iptalOnayla
            .mutateAsync(iptalSoru.b.id)
            .then(() => {
              iptalKapat()
              setSonuc('Bilet iptal edildi.')
            })
            .catch((e) => setIptalHata(rpcErrorText(e, 'İptal edilemedi.')))
        }}
      />

      <ConfirmDialog
        open={iptalSoru?.tur === 'RET'}
        onOpenChange={iptalKapat}
        title="İptal isteğini reddet"
        description="Bilet açık kalacak; personele bildirilir."
        confirmLabel="Reddet"
        tone="danger"
        loading={iptalReddet.isPending}
        error={iptalHata}
        onConfirm={() => {
          if (!iptalSoru) return
          setIptalHata(null)
          void iptalReddet
            .mutateAsync({ id: iptalSoru.b.id, sebep: iptalSebep })
            .then(() => {
              iptalKapat()
              setSonuc('İptal isteği reddedildi, bilet açık kaldı.')
            })
            .catch((e) => setIptalHata(rpcErrorText(e, 'Reddedilemedi.')))
        }}
      >
        <Input
          label="Sebep (isteğe bağlı)"
          value={iptalSebep}
          onChange={(e) => setIptalSebep(e.target.value)}
          placeholder="Personele bildirilir"
          maxLength={200}
        />
      </ConfirmDialog>
    </div>
  )
}

/**
 * One queue at the top of the screen.
 * `sayi`: a number, `undefined` while loading, `null` if the count failed.
 */
function KategoriKarti({
  etiket,
  icon,
  sayi,
  secili,
  onClick,
}: {
  etiket: string
  icon: ReactNode
  sayi: number | null | undefined
  secili: boolean
  onClick: () => void
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-pressed={secili}
      className={[
        'flex min-h-[96px] flex-col items-start rounded-card border bg-surface p-3 text-left shadow-card',
        'transition-transform duration-100 active:scale-[0.98]',
        secili ? 'border-accent inset-ring-1 inset-ring-accent' : 'border-border',
      ].join(' ')}
    >
      <span className={secili ? 'text-accent' : 'text-faint'}>{icon}</span>
      <span className="mt-1.5 text-label leading-snug font-semibold text-ink">{etiket}</span>
      <span
        className={[
          'mt-auto pt-1 text-label tnum',
          sayi !== undefined && sayi !== null && sayi > 0 ? 'font-semibold text-warn' : 'text-faint',
        ].join(' ')}
      >
        {sayi === undefined ? '…' : sayi === null ? 'Yüklenemedi' : sayi + ' bekliyor'}
      </span>
    </button>
  )
}

function KararListesi({
  tur,
  sonuc,
  ad,
}: {
  tur: KararTur
  sonuc: 'ONAY' | 'RET'
  ad: (id: string | null) => string
}) {
  const q = useKararlar(tur, sonuc)
  const kararlar = q.data ?? []
  return (
    <ListeDurumu
      pending={q.isPending}
      error={q.error}
      onRetry={() => void q.refetch()}
      empty={kararlar.length === 0}
      bos={
        <EmptyState
          icon={tur === 'VARDIYA' ? <IconVardiya size={22} /> : <IconCarpi size={22} />}
          title={sonuc === 'ONAY' ? 'Onaylanan istek yok' : 'Reddedilen istek yok'}
        />
      }
    >
      <ul className="space-y-3">
        {kararlar.map((k) => (
          <li key={k.id}>
            <KararKarti k={k} ad={ad} />
          </li>
        ))}
      </ul>
      {kararlar.length >= 50 && (
        <p className="pt-3 text-center text-label text-faint">Son 50 karar gösteriliyor.</p>
      )}
    </ListeDurumu>
  )
}

function KararKarti({ k, ad }: { k: Karar; ad: (id: string | null) => string }) {
  const vardiya = k.tur === 'VARDIYA'
  return (
    <Card>
      <p className="truncate text-body font-semibold text-ink">
        {vardiya ? ad(k.talep_eden) : k.plaka ? formatPlaka(k.plaka) : 'Plaka yok'}
        <span className="ml-2 text-label font-medium text-faint">
          {vardiya ? 'Vardiya kapatma' : 'Bilet iptali'}
        </span>
      </p>
      <p className="mt-0.5 text-label text-faint">
        {formatTam(k.karar_at)} · Karar: {ad(k.karar_veren)}
      </p>

      {vardiya ? (
        (k.sayilan_kurus !== null || k.fark_kurus !== null) && (
          <div className="mt-3 space-y-1.5 border-t border-divider pt-3">
            {k.sayilan_kurus !== null && <Satir k="Sayılan" v={formatTL(k.sayilan_kurus)} />}
            {k.fark_kurus !== null && (
              <Satir
                k="Fark"
                v={(k.fark_kurus > 0 ? '+' : '') + formatTL(k.fark_kurus)}
                ton={k.fark_kurus === 0 ? 'text-success' : k.fark_kurus < 0 ? 'text-danger' : 'text-warn'}
              />
            )}
          </div>
        )
      ) : (
        <p className="mt-2 text-label text-faint">
          İsteyen: {ad(k.talep_eden)}
          {k.sebep && <> — {k.sebep}</>}
        </p>
      )}

      {k.ret_sebep && <p className="mt-2 text-label text-danger">Ret sebebi: {k.ret_sebep}</p>}
    </Card>
  )
}

function IptalKarti({
  b,
  ad,
  onOnay,
  onRet,
}: {
  b: Bilet
  ad: string
  onOnay: () => void
  onRet: () => void
}) {
  return (
    <Card>
      <div className="flex items-start gap-3">
        <span className="mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-field bg-warn-soft text-warn">
          <IconCarpi size={18} />
        </span>
        <div className="min-w-0 flex-1">
          <p className="truncate text-body font-semibold text-ink">
            {formatPlaka(b.plaka)}
            <span className="ml-2 text-label font-medium text-faint">Bilet iptali</span>
          </p>
          <p className="mt-0.5 text-label text-faint">
            {b.iptal_talebi_at ? formatTam(b.iptal_talebi_at) : ''} · {ad}
          </p>
        </div>
      </div>

      <div className="mt-3 space-y-1.5 border-t border-divider pt-3">
        <Satir k="Giriş" v={formatTam(b.giris_at)} />
      </div>

      {b.iptal_talebi_sebep && (
        <p className="mt-3 rounded-field bg-field px-3 py-2 text-label text-soft">
          {b.iptal_talebi_sebep}
        </p>
      )}

      {/* Its own verbs, like a till close: one ticket, one decision. */}
      <div className="mt-4 flex items-center gap-2">
        <Button className="flex-1" onClick={onOnay}>
          Onayla ve iptal et
        </Button>
        <Button variant="secondary" onClick={onRet}>
          Reddet
        </Button>
      </div>
    </Card>
  )
}

function TalepKarti({
  t,
  ad,
  simdikiBeklenen,
  onOnay,
  onRet,
}: {
  t: VardiyaTalebi
  ad: string
  /** Expected cash RIGHT NOW; null while the summary is still loading. */
  simdikiBeklenen: number | null
  onOnay: () => void
  onRet: () => void
}) {
  const fark = simdikiBeklenen === null ? null : t.talep_sayilan_kurus - simdikiBeklenen
  // Money collected between the count and this decision. Not a miscount, and
  // the Yönetici cannot tell the two apart without being told.
  const sonradan =
    simdikiBeklenen === null || t.talep_beklenen_kurus === null
      ? 0
      : simdikiBeklenen - t.talep_beklenen_kurus

  return (
    <Card>
      <div className="flex items-start gap-3">
        <span className="mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-field bg-accent-soft text-accent">
          <IconVardiya size={18} />
        </span>
        <div className="min-w-0 flex-1">
          <p className="truncate text-body font-semibold text-ink">
            {ad}
            <span className="ml-2 text-label font-medium text-faint">Vardiya kapatma</span>
          </p>
          <p className="mt-0.5 text-label text-faint">{formatTam(t.kapatma_talebi_at)}</p>
        </div>
      </div>

      <div className="mt-3 space-y-1.5 border-t border-divider pt-3">
        <Satir k="Olması gereken" v={simdikiBeklenen === null ? '—' : formatTL(simdikiBeklenen)} />
        <Satir k="Sayılan" v={formatTL(t.talep_sayilan_kurus)} />
        {fark !== null && (
          <Satir
            k="Fark"
            v={(fark > 0 ? '+' : '') + formatTL(fark)}
            ton={fark === 0 ? 'text-success' : fark < 0 ? 'text-danger' : 'text-warn'}
          />
        )}
      </div>

      {sonradan !== 0 && (
        <p className="mt-3 rounded-field bg-warn-soft px-3 py-2 text-label text-warn">
          Sayımdan sonra {formatTL(Math.abs(sonradan))} nakit
          {sonradan > 0 ? ' tahsil edildi' : ' geri alındı'} — fark bundan doğuyor olabilir.
        </p>
      )}

      {t.talep_notlar && <p className="mt-3 text-label text-faint">{t.talep_notlar}</p>}

      {/* This card carries its own verbs: a till close is one decision at a
          time, and it must not ride along with "Tümünü onayla". */}
      <div className="mt-4 flex items-center gap-2">
        <Button className="flex-1" onClick={onOnay}>
          Onayla ve kapat
        </Button>
        <Button variant="secondary" onClick={onRet}>
          Reddet
        </Button>
      </div>
    </Card>
  )
}

function Satir({ k, v, ton = 'text-ink' }: { k: string; v: string; ton?: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <span className="text-label text-faint">{k}</span>
      <span className={`text-body font-medium tnum ${ton}`}>{v}</span>
    </div>
  )
}
