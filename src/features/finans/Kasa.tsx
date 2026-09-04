import { useMemo, useState } from 'react'
import {
  Card,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
  SegmentedControl,
  Select,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { YontemSecici } from '../../components/ui/YontemSecici'
import { DonemSecici, IstatKutu, useDonem } from '../yonetim/components'
import { GrafikKart, SiraliCubuklar } from './charts'
import {
  useDonemAralik,
  useKasaEkle,
  useKasaHareketleri,
  useKasaSil,
  useKasaTekrarDurdur,
  useKasaTekrarEkle,
  useKasaTekrarKurallari,
  useOnayliTahsilatlar,
} from './api'
import { formatTL, parseTLToKurus } from '../../lib/money'
import { ayAraligi, ayEkle, formatAy, formatTarih, istanbulAy, istanbulGun } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconArti, IconCop, IconKasa } from '../../components/ui/icons'
import {
  ODEME_ETIKET,
  type KasaHareketi,
  type KasaTur,
  type OdemeYontemi,
} from '../../lib/types'

/**
 * The picker's floor. Nothing was recorded before the system went live, so an
 * empty month before it is a question nobody has.
 */
const AY_TABAN = '2026-09'

/**
 * How far ahead to plan. Twelve answers "what is coming" without turning the
 * picker into a scroll, and a recurring rule repeats monthly anyway — the
 * thirteenth month tells you nothing the first did not.
 */
const AY_ILERI = 12

/** One list row, whatever produced it. */
type KasaSatiri = {
  id: string
  /** Only a hand-made row can be deleted; null on a collection or a plan. */
  kasaId: string | null
  gun: string
  tutar: number
  baslik: string
  alt: string | null
  etiket: string | null
  ton: 'accent' | 'warn' | 'neutral'
  duzenli: boolean
  /** Not written yet — projected from a rule, so it is not money that moved. */
  planlanan: boolean
}

const CHIP_TON: Record<KasaSatiri['ton'], string> = {
  accent: 'bg-accent-soft text-accent',
  warn: 'bg-warn-soft text-warn',
  neutral: 'bg-field text-soft',
}

/** Newest first, by calendar day. 'YYYY-MM-DD' sorts lexicographically. */
const gunAzalan = (a: KasaSatiri, b: KasaSatiri) =>
  a.gun < b.gun ? 1 : a.gun > b.gun ? -1 : 0

/**
 * A kasa row in list shape. Shared by the period list and the month list so
 * the two cannot drift in how they render the same record.
 */
function kasaSatiri(k: KasaHareketi): KasaSatiri {
  // ONE expression behind both the badge and the filter, so a row can never be
  // badged "Düzenli" and then be missing from the Düzenli list.
  const duzenliMi = k.tekrar_kural_id != null
  return {
    id: k.id,
    kasaId: k.id,
    gun: k.tarih,
    tutar: k.tur === 'GELIR' ? k.tutar_kurus : -k.tutar_kurus,
    baslik: k.aciklama || k.kategori || '—',
    alt: k.kategori && k.aciklama ? k.kategori : null,
    etiket: duzenliMi ? 'Düzenli' : null,
    ton: duzenliMi ? 'accent' : 'neutral',
    duzenli: duzenliMi,
    planlanan: false,
  }
}

/** Expenses and non-ticket income. Yönetici only — Personel never see this. */
export default function Kasa() {
  // Tümü, like Finans: this IS the list of işlemler, and opening it on a
  // 30-day window hides older rows behind a filter nobody was told about.
  const { donem, ozel, secim } = useDonem()
  /** '' = one-off. Otherwise the day of the month, 1-28. */
  const [tekrarGun, setTekrarGun] = useState('')
  const { bas, bit, hazir, ilkGunHatasi } = useDonemAralik(donem, ozel)
  const {
    data: liste = [],
    isPending,
    error,
    refetch,
  } = useKasaHareketleri(bas, bit, hazir)

  // Approved barrier money, shown in the same ledger. NOT written into
  // kasa_hareketleri on approval: that would be a second copy of money that
  // already exists in `tahsilatlar`, and two ledgers for one lira is how they
  // drift apart. The till is a VIEW over both tables.
  const { data: tahsilatlar = [] } = useOnayliTahsilatlar(bas, bit, hazir)

  const ekle = useKasaEkle()
  const sil = useKasaSil()
  const tekrarEkle = useKasaTekrarEkle()
  const tekrarDurdur = useKasaTekrarDurdur()
  const { data: kurallar = [] } = useKasaTekrarKurallari()

  const [acik, setAcik] = useState(false)
  const [duzenliSuzgec, setDuzenliSuzgec] = useState(false)
  const [tur, setTur] = useState<KasaTur>('GIDER')
  const [tutar, setTutar] = useState('')
  const [aciklama, setAciklama] = useState('')
  const [kategori, setKategori] = useState('')
  const [yontem, setYontem] = useState<OdemeYontemi | null>('NAKIT')
  const [hata, setHata] = useState<string | null>(null)
  const [silinecek, setSilinecek] = useState<string | null>(null)

  // Moved here from the Finans home: this screen IS the expense ledger, so
  // the category split belongs beside the rows it summarises rather than on a
  // dashboard that then needed a second link back here to see them.
  const giderKategori = useMemo(() => {
    const m = new Map<string, number>()
    for (const h of liste) {
      if (h.tur !== 'GIDER') continue
      const k = h.kategori?.trim() || 'Diğer'
      m.set(k, (m.get(k) ?? 0) + h.tutar_kurus)
    }
    return [...m.entries()].map(([etiket, deger]) => ({
      etiket,
      deger,
      gosterim: formatTL(deger, { decimals: 0 }),
    }))
  }, [liste])

  /**
   * The two sources as one list, newest first.
   *
   * `kasaId` is what separates them: only a hand-made entry can be deleted,
   * because a collection is undone by cancelling its ticket, not by removing a
   * line from the till.
   */
  const satirlar = useMemo<KasaSatiri[]>(() => {
    const kasa = liste.map(kasaSatiri)
    const tahsil: KasaSatiri[] = tahsilatlar.map((t) => ({
      id: t.id,
      kasaId: null,
      gun: istanbulGun(new Date(t.created_at)),
      tutar: t.tutar_kurus,
      baslik: t.aciklama || (t.tur === 'BILET' ? 'Bilet tahsilatı' : 'Abonman tahsilatı'),
      alt: null,
      etiket: t.tur === 'BILET' ? 'Bilet' : 'Abonman',
      ton: 'neutral',
      // A collection is never rule-written: it comes from a car leaving, so it
      // is one-off by definition and drops out under the filter.
      duzenli: false,
      planlanan: false,
    }))
    return [...kasa, ...tahsil].sort(gunAzalan)
  }, [liste, tahsilatlar])

  /**
   * The filter offers itself only where the concept exists at all — an
   * always-empty chip teaches the operator to stop reading the row, the same
   * reason the rules card and the chart below are conditional.
   *
   * Both halves are needed: `kurallar` holds only ACTIVE rules, so a business
   * that stopped all of them would lose the filter while its history still
   * carries rule-written rows; and a brand-new rule can exist before its first
   * row falls inside the selected period.
   */
  const duzenliVar = kurallar.length > 0 || satirlar.some((r) => r.duzenli)

  /**
   * `&& duzenliVar` is not belt-and-braces: without it, turning the filter on
   * and then switching to a period with no recurring rows would hide the chip
   * while it was still filtering — an empty list with nothing on screen to
   * switch off. Deriving it here rather than resetting in an effect means that
   * state simply cannot exist.
   */
  /**
   * The Düzenli view is scoped by MONTH, not by the period chips above.
   *
   * It has to be: a future month has no rows at all, so no period range could
   * ever reach it. The subtotal line names the month for exactly that reason —
   * the summary card keeps reporting the period, and two scopes on one screen
   * must each say which one they are.
   */
  const ayModu = duzenliSuzgec && duzenliVar
  const [ay, setAy] = useState(istanbulAy)

  const aylar = useMemo(() => {
    const son = ayEkle(AY_ILERI)
    const out: string[] = []
    let a = AY_TABAN
    // Bounded loop, not `while (a <= son)`: a mistyped constant must not hang
    // the screen it is supposed to draw.
    for (let i = 0; i < 240 && a <= son; i += 1) {
      out.push(a)
      a = ayEkle(1, a)
    }
    return out
  }, [])

  const ayAralik = useMemo(() => ayAraligi(ay), [ay])
  const ayKasa = useKasaHareketleri(ayAralik.bas, ayAralik.bit, ayModu)

  /**
   * What a rule WILL write, for days that have not arrived yet.
   *
   * Two rules keep this from becoming fiction:
   *   • `gun > bugün` — a date that has passed either has a row or genuinely
   *     did not happen. Projecting one would put money on screen that nobody
   *     spent, in the ledger whose whole job is to be trustworthy.
   *   • `gun >= next_run` — the rule's own schedule decides. A rule created
   *     after this month's day has `next_run` in a later month and must not
   *     appear here at all.
   * Plus the same dedupe the cron uses, so a day already written is never
   * shown twice.
   */
  const planlanan = useMemo<KasaSatiri[]>(() => {
    if (!ayModu) return []
    const bugun = istanbulGun()
    const yazilmis = new Set(
      (ayKasa.data ?? [])
        .filter((k) => k.tekrar_kural_id)
        .map((k) => `${k.tekrar_kural_id}|${k.tarih}`),
    )
    return kurallar
      // `odeme_gunu` is CHECK-constrained to 1-28, so this is always a real
      // date: no month-length table, and February needs no special case.
      .map((k) => ({ k, gun: `${ay}-${String(k.odeme_gunu).padStart(2, '0')}` }))
      .filter(
        ({ k, gun }) => gun > bugun && gun >= k.next_run && !yazilmis.has(`${k.id}|${gun}`),
      )
      .map(({ k, gun }) => ({
        id: `plan-${k.id}-${gun}`,
        kasaId: null,
        gun,
        tutar: k.tur === 'GELIR' ? k.tutar_kurus : -k.tutar_kurus,
        baslik: k.aciklama || k.kategori || '—',
        alt: k.kategori && k.aciklama ? k.kategori : null,
        etiket: 'Planlanan',
        ton: 'warn',
        duzenli: true,
        planlanan: true,
      }))
  }, [ayModu, ay, ayKasa.data, kurallar])

  const gosterilen = useMemo<KasaSatiri[]>(() => {
    if (!ayModu) return satirlar
    const gercek = (ayKasa.data ?? []).filter((k) => k.tekrar_kural_id != null).map(kasaSatiri)
    return [...gercek, ...planlanan].sort(gunAzalan)
  }, [ayModu, satirlar, ayKasa.data, planlanan])

  /** Signed, so a month of rent and electricity reads as one negative number
   *  rather than a turnover figure that hides which way the money went. */
  const duzenliNet = useMemo(() => gosterilen.reduce((a, r) => a + r.tutar, 0), [gosterilen])
  const planSayisi = useMemo(
    () => gosterilen.filter((r) => r.planlanan).length,
    [gosterilen],
  )

  const toplam = useMemo(() => {
    // Collections are summed SIGNED: a cancelled ticket writes a negative
    // counter-entry, and it has to reduce income rather than show up as an
    // expense. Same rule `rapor_ozet` uses for ciro, which is what keeps this
    // screen's net equal to the Net on Finans.
    const tahsilat = tahsilatlar.reduce((a, t) => a + t.tutar_kurus, 0)
    const gelir =
      tahsilat + liste.filter((k) => k.tur === 'GELIR').reduce((a, k) => a + k.tutar_kurus, 0)
    const gider = liste.filter((k) => k.tur === 'GIDER').reduce((a, k) => a + k.tutar_kurus, 0)

    // Per channel, from THESE rows only — never from `yontem_ozet`, which
    // also sums tahsilatlar. Borrowing that here would contradict the line
    // printed under these very figures: bilet and abonman money is ciro and
    // does not belong to the kasa.
    const isaretli = (k: { tur: KasaTur; tutar_kurus: number }) =>
      k.tur === 'GELIR' ? k.tutar_kurus : -k.tutar_kurus
    const yontemler: { etiket: string; net: number }[] = (
      ['NAKIT', 'KREDI_KARTI', 'HAVALE'] as OdemeYontemi[]
    ).map((y) => ({
      etiket: ODEME_ETIKET[y],
      net:
        liste.filter((k) => k.yontem === y).reduce((a, k) => a + isaretli(k), 0) +
        tahsilatlar.filter((t) => t.yontem === y).reduce((a, t) => a + t.tutar_kurus, 0),
    }))
    // `yontem` is optional on a kasa entry, so without this the three
    // channels would quietly fail to add up to net. Shown only when there is
    // something in it — an always-present zero is furniture.
    const yontemsiz = liste.filter((k) => !k.yontem).reduce((a, k) => a + isaretli(k), 0)
    if (yontemsiz !== 0) yontemler.push({ etiket: 'yöntemsiz', net: yontemsiz })

    return { gelir, gider, net: gelir - gider, yontemler }
  }, [liste, tahsilatlar])

  return (
    <div>
      <ScreenHeader
        title="Kasa"
        back="/finans"
        right={
          <button
            type="button"
            onClick={() => {
              setTur('GIDER')
              setTutar('')
              setAciklama('')
              setKategori('')
              // Both of these used to survive the close and arrive already
              // filled on the next entry. The method carrying over is a
              // wrong bucket; the recurrence day carrying over is worse —
              // it silently turns the next one-off into a standing rule.
              setYontem('NAKIT')
              setTekrarGun('')
              setHata(null)
              setAcik(true)
            }}
            // Labelled, not a bare plus: this screen carries three different
            // things somebody might want to add, and a lone icon makes the
            // user find out which one it is by pressing it.
            className="flex min-h-[44px] items-center gap-1.5 rounded-chip bg-accent px-3 text-label font-medium text-accent-ink"
          >
            <IconArti size={18} />
            İşlem ekle
          </button>
        }
      />

      <div className="space-y-4 px-5">
        <Card>
          {/* Net leads: it is the figure this screen exists to report, and
              gelir and gider are the two halves it is made of. */}
          <div className="grid grid-cols-3 gap-3">
            <IstatKutu
              deger={formatTL(toplam.net, { decimals: 0 })}
              etiket="net"
              tone={toplam.net < 0 ? 'danger' : 'default'}
            />
            <IstatKutu
              deger={formatTL(toplam.gelir, { decimals: 0 })}
              etiket="gelir"
              tone="success"
            />
            <IstatKutu deger={formatTL(toplam.gider, { decimals: 0 })} etiket="gider" tone="danger" />
          </div>

          {/* How that net splits across the drawer, the card machine and the
              bank. Net per channel, not turnover: a channel that paid out
              more than it took in reads negative, which is the honest answer
              to "how much cash is in there". */}
          <div className="mt-3 flex flex-wrap gap-x-6 gap-y-2 border-t border-border pt-3">
            {toplam.yontemler.map((y) => (
              <div key={y.etiket}>
                <p className="text-lead font-semibold text-ink tnum">
                  {formatTL(y.net, { decimals: 0 })}
                </p>
                <p className="text-label text-faint">{y.etiket}</p>
              </div>
            ))}
          </div>

          <p className="mt-3 text-label text-faint">
            Bilet ve abonman tahsilatları yalnızca onaylandıktan sonra buraya girer.
          </p>
        </Card>

        {/* Under the totals, matching Finans and Raporlar: the number is the
            answer, the period is the follow-up question. */}
        <DonemSecici value={donem} ozel={ozel} onChange={secim} />

        {/* Only when there are any: a permanently empty card teaches the
            operator to stop reading this part of the screen. */}
        {kurallar.length > 0 && (
          <Card>
            <h3 className="mb-3 text-label font-medium tracking-wide text-faint uppercase">
              Düzenli kayıtlar
            </h3>
            <ul className="space-y-2.5">
              {kurallar.map((k) => (
                <li key={k.id} className="flex items-center gap-3">
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-body text-ink">
                      <span className="font-semibold tnum">
                        {k.tur === 'GIDER' ? '−' : '+'}
                        {formatTL(k.tutar_kurus)}
                      </span>{' '}
                      {k.aciklama}
                    </p>
                    <p className="mt-0.5 text-label text-faint tnum">
                      Her ayın {k.odeme_gunu}. günü · sonraki {formatTarih(k.next_run)}
                    </p>
                  </div>
                  {/* Stopping leaves every entry it already wrote in the kasa —
                      this ends the rule, it does not undo the money. */}
                  <button
                    type="button"
                    onClick={() => void tekrarDurdur.mutateAsync(k.id)}
                    className="min-h-[44px] shrink-0 text-label font-medium text-accent"
                  >
                    Durdur
                  </button>
                </li>
              ))}
            </ul>
          </Card>
        )}

        {/* Only once there is something to break down — an empty chart above
            an empty list is two ways of saying the same nothing. */}
        {giderKategori.length > 0 && (
          <GrafikKart baslik="Gider dağılımı" aciklama="Kategoriye göre">
            <SiraliCubuklar satirlar={giderKategori} bos="" />
          </GrafikKart>
        )}

        {/* Deliberately NOT wired to the summary card above. That card's net
            is the same figure Finans reports, and the comment on its
            arithmetic says so — making a list filter silently re-cut it would
            leave two screens disagreeing about the period's net. The filtered
            total goes beside the chip instead, where it is plainly a subtotal
            of what is on screen. */}
        {duzenliVar && (
          <div className="space-y-2">
            <div className="flex flex-wrap items-center gap-2">
              <button
                type="button"
                aria-pressed={duzenliSuzgec}
                onClick={() => setDuzenliSuzgec((v) => !v)}
                className={[
                  'min-h-[44px] shrink-0 rounded-chip px-4 text-body font-medium transition-colors',
                  duzenliSuzgec ? 'bg-ink text-bg' : 'bg-field text-soft',
                ].join(' ')}
              >
                Düzenli
              </button>
              {/* The sub-filter, and only while the filter it belongs to is on:
                  on its own a month picker would look like it scoped the whole
                  screen, which it does not.

                  A compact native select rather than the Select primitive —
                  that one is a labelled, full-width form field, and this has to
                  sit beside a chip and read as one. Native so the phone opens
                  its own wheel picker, which beats anything hand-rolled here. */}
              {duzenliSuzgec && (
                <select
                  aria-label="Ay seç"
                  value={ay}
                  onChange={(e) => setAy(e.target.value)}
                  className="min-h-[44px] shrink-0 rounded-chip border border-border bg-field px-3 text-body font-medium text-ink outline-none focus:border-accent"
                >
                  {aylar.map((a) => (
                    <option key={a} value={a}>
                      {formatAy(a)}
                    </option>
                  ))}
                </select>
              )}
            </div>
            {duzenliSuzgec && (
              <p className="text-label text-faint tnum">
                {formatAy(ay)} · {gosterilen.length} kayıt · {formatTL(duzenliNet)}
                {planSayisi > 0 && ` · ${planSayisi} planlanan`}
              </p>
            )}
          </div>
        )}

        <div className="space-y-2">
          {/* The month view has its own query, so its loading and error states
              are its own too — showing the period query's spinner here would
              report on data this list is not made of. */}
          <ListeDurumu
            pending={ayModu ? ayKasa.isPending : !hazir || isPending}
            error={ayModu ? ayKasa.error : (ilkGunHatasi ?? error)}
            onRetry={() => void (ayModu ? ayKasa.refetch() : refetch())}
            empty={gosterilen.length === 0}
            bos={
              <EmptyState
                icon={<IconKasa size={44} />}
                title={
                  duzenliSuzgec
                    ? 'Düzenli kayıt yok'
                    : donem === 'TUMU'
                      ? 'Henüz kayıt yok'
                      : 'Bu dönemde kayıt yok'
                }
                hint={
                  duzenliSuzgec
                    ? `${formatAy(ay)} için düzenli gelir ya da gider yok.`
                    : 'Elektrik, temizlik, bakım gibi giderleri buraya girin.'
                }
              />
            }
          >
            {gosterilen.map((r) => (
              <Card key={r.id} className="flex items-center gap-3">
                <div className="min-w-0 flex-1">
                  {/* A planned row is money that has NOT moved. It is dimmed
                      rather than coloured so the eye reads the real entries
                      first — the ledger is still the thing being reported. */}
                  <p className={`truncate text-body ${r.planlanan ? 'text-soft' : 'text-ink'}`}>
                    {r.baslik}
                  </p>
                  <p className="mt-0.5 flex flex-wrap items-center gap-2 text-label text-faint">
                    <span>
                      {formatTarih(r.gun)}
                      {r.alt ? ` · ${r.alt}` : ''}
                    </span>
                    {/* Düzenli takes the accent tone because it is the one
                        badge the filter above also selects on — the badge and
                        the chip that finds it should look like the same idea.
                        Planlanan takes warn, Bilet/Abonman stay neutral: those
                        two only say where a row came from. The tone travels on
                        the row itself, so it cannot disagree with the text. */}
                    {r.etiket && (
                      <span
                        className={`rounded-chip px-2 py-0.5 text-micro font-medium ${CHIP_TON[r.ton]}`}
                      >
                        {r.etiket}
                      </span>
                    )}
                  </p>
                </div>
                <span
                  className={`shrink-0 text-body font-semibold tnum ${
                    r.planlanan ? 'text-soft' : r.tutar >= 0 ? 'text-success' : 'text-danger'
                  }`}
                >
                  {r.tutar >= 0 ? '+' : '−'}
                  {formatTL(Math.abs(r.tutar))}
                </span>
                {/* Only hand-made entries carry a bin. A collection is undone
                    by cancelling its ticket, which writes the counter-entry;
                    deleting the line here would leave the two ledgers
                    disagreeing about the same money. */}
                {r.kasaId ? (
                  <button
                    type="button"
                    onClick={() => setSilinecek(r.kasaId)}
                    aria-label="Sil"
                    className="flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field"
                  >
                    <IconCop size={18} />
                  </button>
                ) : (
                  <span className="size-11 shrink-0" aria-hidden="true" />
                )}
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
        loading={ekle.isPending || tekrarEkle.isPending}
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
          // A recurring entry writes this month's row itself, inside the
          // RPC — calling both would book the expense twice.
          const gun = Number(tekrarGun)
          const istek: Promise<void> = tekrarGun
            ? tekrarEkle.mutateAsync({
                tur,
                tutar_kurus: kurus,
                aciklama: aciklama.trim(),
                kategori: kategori.trim() || null,
                yontem,
                gun,
              })
            : ekle.mutateAsync({
                tur,
                tutar_kurus: kurus,
                aciklama: aciklama.trim(),
                kategori: kategori.trim() || null,
                yontem,
              })

          void istek
            .then(() => setAcik(false))
            .catch((e) => setHata(rpcErrorText(e, 'Kayıt eklenemedi.')))
        }}
      >
        <SegmentedControl
          value={tur}
          onChange={setTur}
          options={[
            { value: 'GIDER', label: 'Gider' },
            { value: 'GELIR', label: 'Gelir' },
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
        <YontemSecici value={yontem} onChange={setYontem} />
        {/* Last, because it changes what Ekle MEANS: with a day chosen this
            stops being one entry and becomes a standing one. Capped at 28 —
            a rule set to the 31st would skip February entirely. */}
        <Select
          id="kasa-tekrar"
          label="Tekrar"
          value={tekrarGun}
          onChange={(e) => setTekrarGun(e.target.value)}
          hint={
            tekrarGun
              ? `Bu kayıt bugün yazılır, sonra her ayın ${tekrarGun}. günü otomatik tekrarlar.`
              : undefined
          }
        >
          <option value="">Yok (tek sefer)</option>
          {Array.from({ length: 28 }, (_, i) => i + 1).map((g) => (
            <option key={g} value={g}>
              Her ayın {g}. günü
            </option>
          ))}
        </Select>
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
