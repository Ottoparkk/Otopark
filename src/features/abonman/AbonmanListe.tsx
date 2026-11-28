import { useMemo, useState } from 'react'
import { useEkranDurumu } from '../../lib/useEkranDurumu'
import { useNavigate } from 'react-router'
import {
  Card,
  Chip,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
  Select,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { YontemSecici } from '../../components/ui/YontemSecici'
import { FiltreChip } from '../../components/ui/FiltreChip'
import { useAbonmanEkle, useAbonmanlar, type AbonmanGirdi } from './api'
import {
  abonmanAra,
  abonmanGruplari,
  abonmanOzeti,
  kalanRozeti,
  kisaTarih,
  type AbonmanSiralama,
} from './liste'
import { useParkYerleri } from '../gise/api'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../lib/plaka'
import { formatTL, parseTLToKurus } from '../../lib/money'
import { normalizeTel } from '../../lib/telefon'
import { formatTarih, istanbulGun } from '../../lib/dates'
import { ayinGunu, sonrakiYenileme } from '../../lib/abonman'
import { rpcErrorText } from '../../lib/errors'
import { IconAbonman, IconAra, IconArti } from '../../components/ui/icons'
import { ODEME_ETIKET, type AbonmanDurum, type OdemeYontemi } from '../../lib/types'

const GUNLER = Array.from({ length: 31 }, (_, i) => i + 1)

/** Today's day of the month in Istanbul — the default payment day. */
function bugununGunu(): number {
  return Number(istanbulGun().slice(8, 10))
}

// Owner, 27.11: no "Tümü"; İptal gets its own tab.
const SEKMELER: { value: AbonmanDurum; label: string }[] = [
  { value: 'AKTIF', label: 'Aktif' },
  { value: 'DOLDU', label: 'Doldu' },
  { value: 'IPTAL', label: 'İptal' },
]

const SIRALAMALAR: AbonmanSiralama[] = ['VARSAYILAN', 'ARTAN', 'AZALAN']

/**
 * Abonmanlar (062, owner 2026-11-15): every staff role. Personel reach it from
 * their bottom tab, the Yönetici from the Yönetim menu. Anyone may add one —
 * with its first payment, a payment DAY instead of dates — and the Yönetici
 * is told who added it.
 */
export default function AbonmanListe() {
  const navigate = useNavigate()
  const { profile } = useAuth()
  const yonetici = isYonetici(profile)
  // Remembered (owner, 27.11). An old "TUMU" falls back to Aktif.
  const [filtre, setFiltre] = useEkranDurumu<AbonmanDurum>('abonman.filtre', 'AKTIF', ['AKTIF', 'DOLDU', 'IPTAL'])
  const [sorgu, setSorgu] = useEkranDurumu('abonman.q', '')
  const [siralama, setSiralama] = useEkranDurumu<AbonmanSiralama>('abonman.siralama', 'VARSAYILAN', SIRALAMALAR)
  const { data: liste = [], isPending, error, refetch } = useAbonmanlar(filtre)
  const { data: yerler = [] } = useParkYerleri()
  const ekle = useAbonmanEkle()
  const bugun = istanbulGun()
  const gruplar = useMemo(
    () => abonmanGruplari(abonmanAra(liste, sorgu), filtre, siralama),
    [liste, sorgu, filtre, siralama],
  )
  const ozet = abonmanOzeti(liste)

  const [acik, setAcik] = useState(false)
  const [plaka, setPlaka] = useState('')
  const [ad, setAd] = useState('')
  const [tel, setTel] = useState('')
  const [gun, setGun] = useState(bugununGunu)
  const [ucret, setUcret] = useState('')
  const [yer, setYer] = useState('')
  // The first month, taken in the same form. The amount follows the monthly
  // fee until it is typed into (a shorter first period may cost less).
  const [tutar, setTutar] = useState('')
  const [tutarElle, setTutarElle] = useState(false)
  const [yontem, setYontem] = useState<OdemeYontemi | null>('NAKIT')
  const [hata, setHata] = useState<string | null>(null)
  // The form only ASKS (owner, 2026-11-14): what is sent is frozen here and
  // read back in the box; the box sends it.
  const [onay, setOnay] = useState<AbonmanGirdi | null>(null)
  const [onayHata, setOnayHata] = useState<string | null>(null)
  const bitis = sonrakiYenileme(gun, istanbulGun())

  return (
    <div>
      <ScreenHeader
        title="Abonmanlar"
        // A Personel arrives from the bottom tab: there is nothing to go back to.
        back={yonetici ? '/yonetim' : undefined}
        right={
          <button
            type="button"
            onClick={() => {
              setPlaka('')
              setAd('')
              setTel('')
              setGun(bugununGunu())
              setUcret('')
              setYer('')
              setTutar('')
              setTutarElle(false)
              setYontem('NAKIT')
              setHata(null)
              setAcik(true)
            }}
            aria-label="Abonman ekle"
            className="flex size-11 items-center justify-center rounded-chip bg-accent text-accent-ink"
          >
            <IconArti size={20} />
          </button>
        }
      />

      <div className="space-y-3 px-5">
        <div className="flex flex-wrap gap-2">
          {SEKMELER.map((f) => (
            <FiltreChip
              key={f.value}
              aktif={filtre === f.value}
              onClick={() => setFiltre(f.value)}
              etiket={f.label}
            />
          ))}
        </div>

        {/* Owner chose a summary at the top (27.11): the Yönetici's view of the
            month, so only on Aktif and only for them. */}
        {yonetici && filtre === 'AKTIF' && liste.length > 0 && (
          <div className="flex items-center justify-between gap-3 rounded-card bg-field px-4 py-3">
            <div>
              <p className="text-label text-faint">Aktif abonman</p>
              <p className="text-title font-semibold text-ink tnum">{ozet.adet}</p>
            </div>
            <div className="text-right">
              <p className="text-label text-faint">Aylık toplam</p>
              <p className="text-title font-semibold text-ink tnum">{formatTL(ozet.toplamKurus)}</p>
            </div>
          </div>
        )}

        {/* Search and order on one row: the search takes what is left. */}
        <div className="flex gap-2">
          <div className="relative min-w-0 flex-1">
            <IconAra
              size={20}
              className="pointer-events-none absolute top-1/2 left-4 -translate-y-1/2 text-faint"
            />
            <Input
              label="Plaka veya isim ara"
              hideLabel
              value={sorgu}
              onChange={(e) => setSorgu(e.target.value)}
              placeholder="Plaka, isim"
              autoCorrect="off"
              spellCheck={false}
              className="pl-11"
            />
          </div>
          <div className="w-[10.75rem] shrink-0">
            <Select
              aria-label="Sıralama"
              value={siralama}
              onChange={(e) => setSiralama(e.target.value as AbonmanSiralama)}
            >
              <option value="VARSAYILAN">{filtre === 'AKTIF' ? 'Ödeme günü' : 'Bitiş tarihi'}</option>
              <option value="ARTAN">Düşük → yüksek</option>
              <option value="AZALAN">Yüksek → düşük</option>
            </Select>
          </div>
        </div>

        <ListeDurumu
          pending={isPending}
          error={error}
          onRetry={() => void refetch()}
          empty={liste.length === 0}
          bos={
            <EmptyState
              icon={<IconAbonman size={44} />}
              title={filtre === 'AKTIF' ? 'Abonman yok' : filtre === 'DOLDU' ? 'Dolan abonman yok' : 'İptal edilen abonman yok'}
              hint={filtre === 'AKTIF' ? 'Aylık müşterileri buradan ekleyin; girişte tanınırlar.' : undefined}
            />
          }
        >
          {gruplar.length === 0 ? (
            <EmptyState icon={<IconAra size={44} />} title="Sonuç yok" hint="Başka bir plaka ya da isim deneyin." />
          ) : (
            <div className="space-y-5">
              {gruplar.map((g) => (
                <section key={g.gun ?? 'hepsi'}>
                  {/* Owner, 27.11: "Ayın 1'i" as a heading, its abonmans under
                      it, with how many and what they bring in a month. */}
                  {g.gun !== null && (
                    <h3 className="mb-2 flex items-baseline justify-between gap-3 text-label font-semibold tracking-wide text-ink uppercase">
                      <span>{ayinGunu(g.gun)}</span>
                      <span className="font-medium tracking-normal text-soft normal-case tnum">
                        {g.adet} abonman · {formatTL(g.toplamKurus)}
                      </span>
                    </h3>
                  )}
                  <div className="space-y-2">
                    {g.ogeler.map((a) => {
                      const rozet = kalanRozeti(a, bugun)
                      return (
                        <Card key={a.id} as="div">
                          <button
                            type="button"
                            onClick={() => navigate(`/abonman/${a.id}`)}
                            className="w-full text-left"
                          >
                            {/* Owner, 27.11: fewer lines, the price easy to
                                read, the period as "1.12.26 → 1.1.27" instead
                                of the payment-day chip (the heading says it). */}
                            <div className="flex items-baseline justify-between gap-3">
                              <span className="min-w-0 truncate text-lead font-semibold tracking-wide text-ink tnum">
                                {formatPlaka(a.plaka)}
                              </span>
                              <span className="shrink-0 text-lead font-bold text-ink tnum">
                                {formatTL(a.ucret_kurus)}
                              </span>
                            </div>
                            <p className="mt-1 truncate text-label text-faint tnum">
                              {a.musteri_ad || 'İsimsiz'} · {kisaTarih(a.baslangic)} → {kisaTarih(a.bitis)}
                            </p>
                            {rozet && (
                              <Chip size="sm" tone="warn" className="mt-2">
                                {rozet}
                              </Chip>
                            )}
                          </button>
                        </Card>
                      )
                    })}
                  </div>
                </section>
              ))}
            </div>
          )}
        </ListeDurumu>
      </div>

      <FormModal
        open={acik}
        onOpenChange={setAcik}
        title="Yeni abonman"
        submitLabel="Ekle"
        loading={ekle.isPending}
        error={hata}
        onSubmit={() => {
          const p = normalizePlaka(plaka)
          if (!plakaGecerli(p)) {
            setHata('Geçerli bir plaka girin.')
            return
          }
          const kurus = parseTLToKurus(ucret || '0')
          if (kurus === null) {
            setHata('Geçerli bir aylık ücret girin.')
            return
          }
          const ilk = parseTLToKurus((tutarElle ? tutar : ucret) || '0')
          if (ilk === null || ilk < 0) {
            setHata('Geçerli bir ilk ödeme tutarı girin.')
            return
          }
          // The server says the same; a Yönetici may add a free abonman.
          if (ilk === 0 && !yonetici) {
            setHata('İlk ödeme tutarını girin.')
            return
          }
          if (ilk > 0 && !yontem) {
            setHata('Ödeme yöntemi seçin.')
            return
          }
          setHata(null)
          setOnayHata(null)
          setOnay({
            plaka: p,
            musteri_ad: ad.trim(),
            // normalizeTel, not a bare digit strip: an operator types the
            // trunk zero and the server refuses eleven digits outright.
            musteri_tel: normalizeTel(tel) || null,
            ucret_kurus: kurus,
            yenileme_gunu: gun,
            park_yeri_id: yer || null,
            notlar: null,
            tutar_kurus: ilk,
            yontem: ilk > 0 ? yontem : null,
          })
          // One box at a time: the form steps aside while the box reads it
          // back, and comes back unchanged on "Vazgeç".
          setAcik(false)
        }}
      >
        <Input
          label="Plaka"
          value={plaka}
          onChange={(e) => setPlaka(normalizePlaka(e.target.value))}
          placeholder="34ABC123"
          autoCapitalize="characters"
          className="tracking-widest tnum"
        />
        <Input label="Müşteri adı" value={ad} onChange={(e) => setAd(e.target.value)} maxLength={80} />
        <Input
          label="Telefon (isteğe bağlı)"
          value={tel}
          onChange={(e) => setTel(e.target.value)}
          inputMode="tel"
          placeholder="5XXXXXXXXX"
          maxLength={10}
        />
        <Input
          label="Aylık ücret (₺)"
          value={ucret}
          onChange={(e) => setUcret(e.target.value)}
          inputMode="decimal"
        />
        <Select
          label="Ödeme günü"
          value={String(gun)}
          onChange={(e) => setGun(Number(e.target.value))}
          hint={bitis ? `Geçerli: bugün — ${formatTarih(bitis)}` : undefined}
        >
          {GUNLER.map((n) => (
            <option key={n} value={n}>
              {ayinGunu(n)}
            </option>
          ))}
        </Select>
        <Select
          label="Ayrılmış yer (isteğe bağlı)"
          value={yer}
          onChange={(e) => setYer(e.target.value)}
        >
          <option value="">Yer atanmadı</option>
          {yerler
            .filter((y) => y.rezerve)
            .map((y) => (
              <option key={y.id} value={y.id}>
                {y.kod}
              </option>
            ))}
        </Select>

        <div className="space-y-3 border-t border-divider pt-4">
          <p className="text-label font-medium tracking-wide text-faint uppercase">İlk ödeme</p>
          <Input
            label="Tutar (₺)"
            value={tutarElle ? tutar : ucret}
            onChange={(e) => {
              setTutarElle(true)
              setTutar(e.target.value)
            }}
            inputMode="decimal"
          />
          <YontemSecici value={yontem} onChange={setYontem} />
        </div>
      </FormModal>

      {/* The read-back (owner, 2026-11-14). Stays open on a refusal (an
          overlapping abonman, no open shift) so the reason is read here. */}
      <ConfirmDialog
        open={onay !== null}
        onOpenChange={(o) => {
          if (o || ekle.isPending) return
          setOnay(null)
          setAcik(true)
        }}
        title="Abonman eklensin mi?"
        description={
          onay && (
            <>
              <span className="block text-title font-semibold tracking-wide text-ink tnum">
                {formatPlaka(onay.plaka)}
              </span>
              <span className="mt-1 block tnum">
                {formatTL(onay.ucret_kurus)} / ay · {ayinGunu(onay.yenileme_gunu)}
              </span>
              <span className="block tnum">
                {formatTarih(sonrakiYenileme(onay.yenileme_gunu, istanbulGun()) ?? '')} tarihine
                kadar geçerli.
              </span>
              <span className="mt-1 block font-semibold text-warn tnum">
                {onay.tutar_kurus > 0 && onay.yontem
                  ? `İlk ödeme ${formatTL(onay.tutar_kurus)} · ${ODEME_ETIKET[onay.yontem]}`
                  : 'İlk ödeme alınmadı'}
              </span>
            </>
          )
        }
        confirmLabel="Ekle"
        loading={ekle.isPending}
        error={onayHata}
        onConfirm={() => {
          if (!onay || ekle.isPending) return
          setOnayHata(null)
          ekle
            .mutateAsync(onay)
            .then(() => setOnay(null))
            .catch((e) =>
              setOnayHata(
                rpcErrorText(e, 'Abonman eklenemedi. Aynı plakada çakışan bir dönem olabilir.'),
              ),
            )
        }}
      />
    </div>
  )
}
