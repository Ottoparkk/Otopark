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
import { formatTarih, istanbulGun } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconArti, IconCop, IconKasa } from '../../components/ui/icons'
import { ODEME_ETIKET, type KasaTur, type OdemeYontemi } from '../../lib/types'

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
  const satirlar = useMemo(() => {
    const kasa = liste.map((k) => ({
      id: k.id,
      kasaId: k.id as string | null,
      gun: k.tarih,
      tutar: k.tur === 'GELIR' ? k.tutar_kurus : -k.tutar_kurus,
      baslik: k.aciklama || k.kategori || '—',
      alt: k.kategori && k.aciklama ? k.kategori : null,
      etiket: null as string | null,
    }))
    const tahsil = tahsilatlar.map((t) => ({
      id: t.id,
      kasaId: null as string | null,
      gun: istanbulGun(new Date(t.created_at)),
      tutar: t.tutar_kurus,
      baslik: t.aciklama || (t.tur === 'BILET' ? 'Bilet tahsilatı' : 'Abonman tahsilatı'),
      alt: null as string | null,
      etiket: t.tur === 'BILET' ? 'Bilet' : 'Abonman',
    }))
    return [...kasa, ...tahsil].sort((a, b) => (a.gun < b.gun ? 1 : a.gun > b.gun ? -1 : 0))
  }, [liste, tahsilatlar])

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

        <div className="space-y-2">
          <ListeDurumu
            pending={!hazir || isPending}
            error={ilkGunHatasi ?? error}
            onRetry={() => void refetch()}
            empty={satirlar.length === 0}
            bos={
              <EmptyState
                icon={<IconKasa size={44} />}
                title={donem === 'TUMU' ? 'Henüz kayıt yok' : 'Bu dönemde kayıt yok'}
                hint="Elektrik, temizlik, bakım gibi giderleri buraya girin."
              />
            }
          >
            {satirlar.map((r) => (
              <Card key={r.id} className="flex items-center gap-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-body text-ink">{r.baslik}</p>
                  <p className="mt-0.5 flex flex-wrap items-center gap-2 text-label text-faint">
                    <span>
                      {formatTarih(r.gun)}
                      {r.alt ? ` · ${r.alt}` : ''}
                    </span>
                    {r.etiket && (
                      <span className="rounded-chip bg-field px-2 py-0.5 text-micro font-medium text-soft">
                        {r.etiket}
                      </span>
                    )}
                  </p>
                </div>
                <span
                  className={`shrink-0 text-body font-semibold tnum ${
                    r.tutar >= 0 ? 'text-success' : 'text-danger'
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
