import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router'
import {
  BrandPanel,
  Button,
  EmptyState,
  FloatingBar,
  Input,
  ListeDurumu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { YontemSecici } from '../../components/ui/YontemSecici'
import { FormModal } from '../../components/ui/FormModal'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { Spinner } from '../../components/ui/Spinner'
import { LoadError } from '../../components/ui/primitives'
import {
  BOS_EK_BILGI,
  BiletBilgileri,
  BiletEkleri,
  BiletKart,
  CikanKart,
  IptalButonu,
  EkBilgiFormu,
  ekBilgiAlanlari,
  ekBilgiGonder,
  ekBilgiOzet,
  useBiletAksiyonlari,
  type EkBilgiler,
} from './components'
import {
  useAyarlar,
  useBilet,
  useBiletKapat,
  useBiletMusteriGuncelle,
  useCikanBiletler,
  useKayipBilet,
  usePuanDurumu,
  usePuanGeriAl,
  usePuanKullan,
  useUcretOnizleme,
  useYerKodlari,
} from './api'
import { formatPlaka } from '../../lib/plaka'
import { formatTutar, formatTL, digitsOnly, parseTLToKurus, kurusToInput } from '../../lib/money'
import { sureMetni } from '../../lib/sure'
import { formatGoreceli } from '../../lib/dates'
import { telGecerli } from '../../lib/telefon'
import { rpcErrorText } from '../../lib/errors'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'
import {
  IconAra,
  IconAraba,
  IconCop,
  IconEtiket,
  IconIleri,
  IconKisi,
  IconTik,
} from '../../components/ui/icons'
import {
  type AcikBilet,
  type OdemeYontemi,
} from '../../lib/types'

type Filtre = 'TUMU' | 'ICERIDE' | 'CIKAN'

const FILTRELER: { deger: Filtre; etiket: string }[] = [
  { deger: 'TUMU', etiket: 'Tümü' },
  { deger: 'ICERIDE', etiket: 'İçeride' },
  { deger: 'CIKAN', etiket: 'Çıkanlar' },
]

/**
 * A filter chip. Visually identical to DonemSecici, deliberately — same idiom,
 * same tap target — but announced as a TOGGLE BUTTON, not a tab.
 *
 * `role="tab"` would be a promise the screen makes and then breaks: a tab owns
 * a tabpanel and answers arrow keys via roving tabindex, and neither is true
 * here — "Tümü" shows both sections at once, so there is no one panel to own.
 * `aria-pressed` describes exactly what this is (a pressed filter) and works
 * with plain Tab navigation, so nothing has to be simulated.
 *
 * NOT labelled "Giriş" / "Çıkış" even though that is what this filters, because
 * the floating button on this same screen already says "Giriş" and means an
 * ACTION — recording an arrival. Two different meanings for one word on one
 * screen is the sort of thing that reads fine in a spec and confuses somebody
 * at a barrier. "İçeride" is also the more truthful label: the section holds
 * cars that are still here, not every car that entered today.
 */
function FiltreChip({
  aktif,
  onClick,
  etiket,
}: {
  aktif: boolean
  onClick: () => void
  etiket: string
}) {
  return (
    <button
      type="button"
      aria-pressed={aktif}
      onClick={onClick}
      className={[
        'min-h-[44px] rounded-chip px-4 text-body font-medium transition-colors',
        aktif ? 'bg-ink text-bg' : 'bg-field text-soft',
      ].join(' ')}
    >
      {etiket}
    </button>
  )
}

/** A quiet section heading inside the one list. */
function BolumBasligi({ metin, sayi }: { metin: string; sayi?: number }) {
  return (
    <h3 className="mb-2 flex items-baseline gap-2 text-label font-medium tracking-wide text-faint uppercase">
      {metin}
      {sayi !== undefined && <span className="tnum">{sayi}</span>}
    </h3>
  )
}

/**
 * The vehicle list: what is inside, then what recently left.
 *
 * ONE list with two sections, NOT a tab bar. Both halves are visible by
 * default, so the plain arrival at this screen costs zero navigation
 * decisions and one search box filters BOTH at once — typing a plate answers
 * "is it still here, or did it already leave?" in a single glance, which is
 * the actual question at a barrier.
 *
 * The chip row narrows that default; it never hides a half behind a tap the
 * operator has to guess at. Filter chips sit ABOVE flat content here; an
 * earlier version put them under a segmented control and the nesting made
 * "Çıkış → İçeride" a readable path, which is nonsense.
 *
 * The open-ticket query lives in the PARENT. Gişe needs the same rows to count
 * cars waiting at the barrier, and the collect view has to replace the whole
 * page rather than render underneath it.
 */
export function AracListesi({
  sorgu,
  setSorgu,
  biletler,
  isPending,
  error,
  refetch,
  onSec,
}: {
  sorgu: string
  setSorgu: (v: string) => void
  biletler: AcikBilet[]
  isPending: boolean
  error: unknown
  refetch: () => void
  onSec: (b: AcikBilet) => void
}) {
  const navigate = useNavigate()
  const yonetici = isYonetici(useAuth().profile)
  const yerKodlari = useYerKodlari()
  const [filtre, setFiltre] = useState<Filtre>('TUMU')

  const iceridiGoster = filtre !== 'CIKAN'
  const cikanGoster = filtre !== 'ICERIDE'

  // Skipped entirely while the filter hides it — a gate phone on mobile data
  // should not pull closed tickets nobody asked to see.
  const cikanlar = useCikanBiletler(sorgu, cikanGoster)

  return (
    <div className="flex flex-1 flex-col">
      <div className="px-5">
        <div className="relative">
          <IconAra
            size={20}
            className="pointer-events-none absolute top-1/2 left-4 -translate-y-1/2 text-faint"
          />
          <Input
            label="Plaka ara"
            hideLabel
            value={sorgu}
            onChange={(e) => setSorgu(e.target.value.toUpperCase())}
            placeholder="Plaka ara — son rakamlar da yeterli"
            inputMode="text"
            autoCapitalize="characters"
            autoCorrect="off"
            spellCheck={false}
            className="pl-11 tnum"
          />
        </div>
      </div>

      {/* The only control layer on this screen — there is no tab bar above it
          to nest under, so a single chip row reads as what it is: a filter. */}
      <div className="mt-3 flex gap-2 px-5" role="group" aria-label="Araç filtresi">
        {FILTRELER.map((f) => (
          <FiltreChip
            key={f.deger}
            aktif={filtre === f.deger}
            onClick={() => setFiltre(f.deger)}
            etiket={f.etiket}
          />
        ))}
      </div>

      <div className="mt-5 flex-1 space-y-6 px-5">
        {/* ---- still here: the actionable half ------------------------- */}
        {iceridiGoster && (
          <section>
            <BolumBasligi metin="İçeride" sayi={biletler.length} />
            <div className="space-y-2">
              {/* "İçeride araç yok" must never stand in for "the list did not
                  load" — an operator who believes the lot is empty stops
                  charging. */}
              <ListeDurumu
                pending={isPending}
                error={error}
                onRetry={refetch}
                empty={biletler.length === 0}
                bos={
                  <EmptyState
                    icon={<IconAraba size={44} />}
                    title={sorgu ? 'Eşleşen araç yok' : 'İçeride araç yok'}
                    hint={
                      sorgu
                        ? 'Plakanın tamamını değil, son rakamlarını da arayabilirsiniz. Kaydı hiç yoksa kayıp bilet ücreti alın.'
                        : 'Giriş yapılan araçlar burada listelenir.'
                    }
                  />
                }
              >
                {biletler.map((b) => (
                  <BiletKart
                    key={b.id}
                    bilet={b}
                    yerKod={b.park_yeri_id ? (yerKodlari[b.park_yeri_id] ?? null) : null}
                    onClick={() => onSec(b)}
                  />
                ))}
              </ListeDurumu>
            </div>
          </section>
        )}

        {/* ---- already gone: reference, so it sits below --------------- */}
        {cikanGoster && (
          <section>
            <BolumBasligi metin="Son çıkanlar" />
            <div className="space-y-2">
              <ListeDurumu
                pending={cikanlar.isPending}
                error={cikanlar.error}
                onRetry={() => void cikanlar.refetch()}
                empty={(cikanlar.data ?? []).length === 0}
                // A compact line, not another big empty state: two full
                // illustrations stacked on one screen would drown the section
                // that actually needs attention.
                bos={
                  <p className="py-2 text-body text-faint">
                    {sorgu
                      ? 'Bu plakayla eşleşen çıkış yok.'
                      : yonetici
                        ? 'Henüz çıkış yok.'
                        : 'Kendi vardiyanızda çıkışı yapılan araçlar burada görünür.'}
                  </p>
                }
              >
                {(cikanlar.data ?? []).map((b) => (
                  <CikanKart
                    key={b.id}
                    bilet={b}
                    // A closed ticket cannot be collected again — this opens the
                    // record instead of the payment screen.
                    onClick={() => navigate(`/gise/bilet/${b.id}`)}
                  />
                ))}
              </ListeDurumu>
            </div>
          </section>
        )}
      </div>

      <KayipBiletBolumu />
    </div>
  )
}

/* ==================================================== the collect screen === */

export function Tahsilat({ bilet, onKapat }: { bilet: AcikBilet; onKapat: () => void }) {
  const yonetici = isYonetici(useAuth().profile)
  const { data: ayarlar } = useAyarlar()
  const { data: onizleme, isPending: ucretYukleniyor } = useUcretOnizleme(bilet)
  const { data: puan } = usePuanDurumu(bilet.plaka, Boolean(ayarlar?.puan_aktif))

  const kapat = useBiletKapat()
  const puanKullan = usePuanKullan()
  const puanGeriAl = usePuanGeriAl()

  const [yontem, setYontem] = useState<OdemeYontemi | null>('NAKIT')
  const [hata, setHata] = useState<string | null>(null)
  const [puanModal, setPuanModal] = useState(false)
  const [puanGirdi, setPuanGirdi] = useState('')
  const [puanHata, setPuanHata] = useState<string | null>(null)
  const [degistirModal, setDegistirModal] = useState(false)
  const [yeniTutar, setYeniTutar] = useState('')
  const [sebep, setSebep] = useState('')
  const [degistirHata, setDegistirHata] = useState<string | null>(null)
  const [override, setOverride] = useState<{ kurus: number; sebep: string } | null>(null)
  const [sonuc, setSonuc] = useState<{ tahsil: number; ucret: number; indirim: number } | null>(
    null,
  )

  const abonman = Boolean(bilet.abonman_id)
  const brutKurus = override?.kurus ?? onizleme ?? 0
  const netKurus = Math.max(0, brutKurus - bilet.indirim_kurus)
  const odemeGerekli = netKurus > 0

  const kurusPerPuan = useMemo(() => {
    if (!puan || puan.bakiye <= 0) return 0
    return Math.round(puan.karsiligi_kurus / puan.bakiye)
  }, [puan])

  const maxPuan = useMemo(() => {
    if (!puan || kurusPerPuan <= 0) return 0
    return Math.min(puan.bakiye, Math.floor(netKurus / kurusPerPuan))
  }, [puan, kurusPerPuan, netKurus])

  async function tahsilEt() {
    setHata(null)
    if (odemeGerekli && !yontem) {
      setHata('Ödeme yöntemi seçin.')
      return
    }
    try {
      const r = await kapat.mutateAsync({
        bilet_id: bilet.id,
        odeme_yontemi: odemeGerekli ? yontem : null,
        ucret_override_kurus: override?.kurus ?? null,
        sebep: override?.sebep ?? null,
      })
      // The RECEIPT shows what the server actually charged, not the preview.
      setSonuc({ tahsil: r.tahsil_kurus, ucret: r.ucret_kurus, indirim: r.indirim_kurus })
    } catch (err) {
      setHata(
        rpcErrorText(
          err,
          'Tahsilat kaydedilemedi. Tekrar deneyin — tahsilat otomatik tekrarlanmaz.',
        ),
      )
    }
  }

  if (sonuc) {
    return <Fis plaka={bilet.plaka} sonuc={sonuc} onTamam={onKapat} />
  }

  return (
    <div className="flex min-h-dvh flex-col md:min-h-0">
      {/* onBack, not `back`: this is a sub-view of the same route, so
          navigate(-1) would leave Çıkış entirely instead of returning to the
          search list. */}
      <ScreenHeader title="Tahsilat" onBack={onKapat} />

      <div className="flex-1 space-y-5 px-5">
        {/* ---- the one thing at full contrast -------------------------- */}
        {/* The amount being collected is the single most important number in
            the whole app, so it gets the one branded surface. Everything on
            this panel is either the fee or an explanation of the fee. */}
        <BrandPanel className="text-center">
          <p className="text-lead font-medium tracking-wide text-on-brand-soft tnum">
            {formatPlaka(bilet.plaka)}
          </p>

          <div className="mt-3 mb-1 no-select">
            {ucretYukleniyor && !override ? (
              <div className="py-3">
                <Spinner label="Ücret hesaplanıyor" görünürEtiket tone="inherit" />
              </div>
            ) : (
              <p className="text-hero font-semibold tnum">
                {formatTutar(netKurus)}
                <span className="ml-1 text-title font-medium text-on-brand-soft">₺</span>
              </p>
            )}
          </div>

          {/* Everything else steps down. No labels — a duration looks like a
              duration and an entry time looks like an entry time. */}
          <p className="text-label text-on-brand-soft">
            {sureMetni(bilet.giris_at)} · {formatGoreceli(bilet.giris_at)}
          </p>

          {abonman && (
            <p className="mt-3 rounded-field bg-success-soft px-3 py-2 text-body text-success">
              Abonman — ücretsiz çıkış
            </p>
          )}

          {/* on-brand-soft, not text-accent: indigo on the indigo panel would
              be all but unreadable. */}
          {bilet.indirim_kurus > 0 && (
            <p className="mt-3 flex items-center justify-center gap-2 text-label text-on-brand-soft">
              {bilet.puan_kullanilan} puan kullanıldı · −{formatTL(bilet.indirim_kurus)}
              <button
                type="button"
                onClick={() => void puanGeriAl.mutateAsync(bilet.id)}
                className="min-h-[44px] font-medium text-on-brand underline"
              >
                geri al
              </button>
            </p>
          )}

          {override && (
            <p className="mt-3 rounded-field bg-warn-soft px-3 py-2 text-label text-warn">
              Ücret elle değiştirildi ({formatTL(onizleme ?? 0)} → {formatTL(override.kurus)}).
              Yönetici bilgilendirilecek.
            </p>
          )}
        </BrandPanel>

        {/* ---- points ------------------------------------------------- */}
        {!abonman && puan?.hesap_var && bilet.indirim_kurus === 0 && maxPuan > 0 && (
          <button
            type="button"
            onClick={() => {
              setPuanGirdi(String(maxPuan))
              setPuanHata(null)
              setPuanModal(true)
            }}
            className="flex w-full items-center justify-between rounded-card bg-accent-soft px-4 py-3.5 text-left"
          >
            <span className="text-body text-accent">
              <strong className="font-semibold">{puan.hesap_adi}</strong> · {puan.bakiye} puan
            </span>
            <span className="text-body font-medium text-accent">Kullan</span>
          </button>
        )}

        {/* Above the method picker, not below it: changing the fee changes
            what is being collected, so it belongs with the amount it edits —
            and the last thing under the operator's thumb should be the choice
            they actually make on every single ticket. */}
        {!abonman && (
          <button
            type="button"
            onClick={() => {
              setYeniTutar(kurusToInput(netKurus))
              setSebep('')
              setDegistirHata(null)
              setDegistirModal(true)
            }}
            className="min-h-[44px] w-full text-label text-faint underline"
          >
            Ücreti elle değiştir
          </button>
        )}

        {/* ---- payment ------------------------------------------------ */}
        {odemeGerekli && <YontemSecici value={yontem} onChange={setYontem} />}

        {/* Staff-visible, unlike the Yönetici-only detail panel below: the
            operator who typed the name at the barrier is the one standing
            here when the driver corrects a digit of it. */}
        <EkBilgiBolumu biletId={bilet.id} />

        {/* Tapping a car on the list opens THIS screen, so the ticket detail
            — and with it cancelling and deleting — lives here rather than
            behind a link that would take the operator off the collection they
            are in the middle of. Yönetici only, exactly as the old link was:
            this is a visibility change, not an RBAC one. */}
        {yonetici && <BiletDetayBolumu bilet={bilet} onSilindi={onKapat} />}

        {hata && (
          <p role="alert" className="rounded-card bg-danger-soft px-4 py-3 text-body text-danger">
            {hata}
          </p>
        )}
      </div>

      <FloatingBar>
        <Button size="lg" block loading={kapat.isPending} onClick={() => void tahsilEt()}>
          {odemeGerekli ? `${formatTL(netKurus)} Tahsil Et` : 'Çıkışı Kaydet'}
        </Button>
      </FloatingBar>

      {/* ---- points modal --------------------------------------------- */}
      <FormModal
        open={puanModal}
        onOpenChange={setPuanModal}
        title="Puan kullan"
        submitLabel="Uygula"
        loading={puanKullan.isPending}
        error={puanHata}
        onSubmit={() => {
          const adet = Number(puanGirdi)
          if (!adet || adet <= 0) {
            setPuanHata('Geçerli bir puan girin.')
            return
          }
          void puanKullan
            .mutateAsync({ bilet_id: bilet.id, puan: adet })
            .then(() => setPuanModal(false))
            .catch((e) => setPuanHata(rpcErrorText(e, 'Puan kullanılamadı.')))
        }}
      >
        <Input
          label="Kullanılacak puan"
          value={puanGirdi}
          onChange={(e) => setPuanGirdi(digitsOnly(e.target.value, 6))}
          inputMode="numeric"
          hint={`En fazla ${maxPuan} puan · 1 puan = ${formatTL(kurusPerPuan)}`}
        />
      </FormModal>

      {/* ---- manual fee override -------------------------------------- */}
      <FormModal
        open={degistirModal}
        onOpenChange={setDegistirModal}
        title="Ücreti değiştir"
        submitLabel="Uygula"
        error={degistirHata}
        onSubmit={() => {
          const kurus = parseTLToKurus(yeniTutar)
          if (kurus === null) {
            setDegistirHata('Geçerli bir tutar girin (örn. 250 ya da 250,50).')
            return
          }
          if (!sebep.trim()) {
            // A Yönetici is not notified of their own override — notify_yonetici
            // excludes auth.uid(), so the sole manager gets nothing at all.
            // Promising them a notification was simply false; what the reason
            // is actually FOR is the audit row, and that is written either way.
            setDegistirHata(
              yonetici
                ? 'Sebep zorunludur — denetim kaydına yazılır.'
                : 'Sebep zorunludur — bu değişiklik Yöneticiye bildirilir.',
            )
            return
          }
          if (kurus < bilet.indirim_kurus) {
            setDegistirHata('Yeni ücret kullanılan puandan düşük olamaz.')
            return
          }
          setOverride({ kurus, sebep: sebep.trim() })
          setDegistirModal(false)
        }}
      >
        <p className="text-body text-soft">
          Hesaplanan ücret <strong className="text-ink">{formatTL(onizleme ?? 0)}</strong>. Bunu
          değiştirmek denetim kaydına yazılır
          {yonetici ? '.' : ' ve Yöneticiye bildirim gider.'}
        </p>
        <Input
          label="Yeni tutar (₺)"
          value={yeniTutar}
          onChange={(e) => setYeniTutar(e.target.value)}
          inputMode="decimal"
        />
        <Input
          label="Sebep"
          value={sebep}
          onChange={(e) => setSebep(e.target.value)}
          placeholder="Örn. cihaz arızası, müşteri itirazı"
          maxLength={200}
        />
      </FormModal>
    </div>
  )
}

/* ============================================================== receipt === */

function Fis({
  plaka,
  sonuc,
  onTamam,
}: {
  plaka: string
  sonuc: { tahsil: number; ucret: number; indirim: number }
  onTamam: () => void
}) {
  return (
    <div className="flex min-h-dvh flex-col items-center justify-center px-6 text-center">
      <div className="mb-5 flex size-16 items-center justify-center rounded-chip bg-success-soft text-success">
        <IconTik size={34} />
      </div>

      <p className="text-lead font-medium tracking-wide text-soft tnum">{formatPlaka(plaka)}</p>

      <p className="mt-2 text-hero font-semibold text-ink tnum">
        {formatTutar(sonuc.tahsil)}
        <span className="ml-1 text-title font-medium text-faint">₺</span>
      </p>
      <p className="mt-1 text-label text-faint">tahsil edildi</p>

      {sonuc.indirim > 0 && (
        <p className="mt-3 text-label text-faint">
          {formatTL(sonuc.ucret)} ücret · −{formatTL(sonuc.indirim)} puan indirimi
        </p>
      )}

      <div className="safe-bottom mt-10 w-full max-w-[360px]">
        <Button size="lg" block onClick={onTamam}>
          Tamam
        </Button>
      </div>
    </div>
  )
}

/* ========================================================== lost ticket === */

function KayipBiletBolumu() {
  const [acik, setAcik] = useState(false)
  const [plaka, setPlaka] = useState('')
  const [yontem, setYontem] = useState<OdemeYontemi | null>('NAKIT')
  const [hata, setHata] = useState<string | null>(null)
  const islemIdRef = useRef<string>(crypto.randomUUID())
  const kayip = useKayipBilet()

  return (
    <>
      <div className="safe-bottom px-5 pt-6">
        <button
          type="button"
          onClick={() => {
            setPlaka('')
            setHata(null)
            islemIdRef.current = crypto.randomUUID()
            setAcik(true)
          }}
          className="min-h-[44px] w-full text-label text-faint underline"
        >
          Kaydı olmayan araç — kayıp bilet ücreti al
        </button>
      </div>

      <ConfirmDialog
        open={acik}
        onOpenChange={setAcik}
        title="Kayıp bilet"
        description="Girişi kaydedilmemiş bir araç için tarifedeki kayıp bilet ücreti tahsil edilir."
        confirmLabel="Tahsil Et"
        loading={kayip.isPending}
        error={hata}
        onConfirm={() => {
          setHata(null)
          if (!plaka.trim()) {
            setHata('Plaka girin.')
            return
          }
          if (!yontem) {
            setHata('Ödeme yöntemi seçin.')
            return
          }
          void kayip
            .mutateAsync({
              plaka,
              odeme_yontemi: yontem,
              islem_id: islemIdRef.current,
            })
            .then(() => setAcik(false))
            .catch((e) => setHata(rpcErrorText(e, 'Kayıp bilet tahsil edilemedi.')))
        }}
      >
        <div className="space-y-4">
          <Input
            label="Plaka"
            value={plaka}
            onChange={(e) => setPlaka(e.target.value.toUpperCase())}
            placeholder="34ABC123"
            autoCapitalize="characters"
            autoCorrect="off"
            spellCheck={false}
            className="text-center tracking-widest tnum"
          />
          <YontemSecici value={yontem} onChange={setYontem} />
        </div>
      </ConfirmDialog>
    </>
  )
}

/**
 * The ticket's detail, inline on the collection screen.
 *
 * It expands in place rather than navigating: an operator is mid-collection
 * with a car at the barrier, and sending them to another route to check an
 * entry photo — or to cancel a ticket they just realised is wrong — loses the
 * screen they were on.
 *
 * Collapsed means NOT FETCHED. That mattered more before the customer panel
 * above began reading the same `['bilet', id]` row eagerly — the two now share
 * one cache entry, so opening this costs nothing either way, and the `enabled`
 * flag simply keeps the panel honest if that ever changes back. Tahsilat only
 * ever holds the slim AcikBilet projection, which carries neither the photos
 * nor the override flags, so the full row has to come from somewhere.
 */
function BiletDetayBolumu({ bilet, onSilindi }: { bilet: AcikBilet; onSilindi: () => void }) {
  const yerKodlari = useYerKodlari()
  const [acik, setAcik] = useState(false)
  const { data: tam, isPending, error, refetch } = useBilet(acik ? bilet.id : undefined)
  const aksiyon = useBiletAksiyonlari(tam, { onSilindi })

  return (
    // ONE surface, header and body together — the same panel grows rather
    // than dropping a second, unattached block onto the page background.
    <section className="overflow-hidden rounded-card border border-border bg-surface shadow-card">
      <button
        type="button"
        onClick={() => setAcik((v) => !v)}
        aria-expanded={acik}
        className="flex w-full items-center gap-3 px-4 py-3 text-left transition-[filter] active:brightness-[0.97]"
      >
        <span className="flex size-10 shrink-0 items-center justify-center rounded-field bg-accent-soft text-accent">
          <IconEtiket size={20} />
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-body font-medium text-ink">Bilet detayı</span>
          <span className="block text-label text-faint">Giriş, fotoğraflar, iptal ve silme</span>
        </span>
        {/* Closed points DOWN, at the content it will reveal; open points UP.
            IconIleri is a right-pointing chevron, so neither state is the
            unrotated one. */}
        <IconIleri
          size={18}
          className={`shrink-0 text-faint transition-transform duration-150 ${
            acik ? '-rotate-90' : 'rotate-90'
          }`}
        />
      </button>

      {acik && (
        // A hairline, not a gap: the divider says "same panel, next part".
        <div className="space-y-4 border-t border-divider px-4 pt-4 pb-5">
          <ListeDurumu
            pending={isPending}
            error={error}
            onRetry={() => void refetch()}
            // A ticket always exists here — we were just collecting on it —
            // so the empty branch is unreachable and carries no state.
            empty={false}
            bos={null}
          >
            {tam && (
              <div className="space-y-4">
                <BiletBilgileri
                  bilet={tam}
                  yerKod={tam.park_yeri_id ? (yerKodlari[tam.park_yeri_id] ?? null) : null}
                />
                <BiletEkleri bilet={tam} />

                {/* Both undo paths, kept below a divider and well clear of
                    "Tahsil Et" at the foot of the screen. Sil is the quiet
                    one: İptal reverses the money and keeps the history,
                    deleting takes the record away. */}
                <div className="space-y-3 border-t border-divider pt-4">
                  <IptalButonu onClick={aksiyon.iptalAc} />
                  {aksiyon.silinebilir && (
                    <button
                      type="button"
                      onClick={aksiyon.silAc}
                      className="flex min-h-[44px] w-full items-center justify-center gap-2 text-label font-medium text-faint"
                    >
                      <IconCop size={16} />
                      Bileti sil
                    </button>
                  )}
                </div>
              </div>
            )}
          </ListeDurumu>
        </div>
      )}

      {aksiyon.dialoglar}
    </section>
  )
}

/**
 * Customer details and the visit note, editable while the car is still inside.
 *
 * Fetched EAGERLY, unlike the ticket-detail panel below it: the collapsed
 * header has to say what is already on file, and "who is this" is worth a
 * glance before taking money. It is the same `['bilet', id]` row that panel
 * reads, so the two share one cache entry and the second one costs nothing.
 *
 * The Kaydet button is disabled until the row has actually arrived. That is
 * not politeness — the draft starts empty, so saving against a failed load
 * would write three NULLs over a real name and phone and look exactly like the
 * app had deleted them. Same trap the Mesai settings form hit in PilotGarage.
 */
function EkBilgiBolumu({ biletId }: { biletId: string }) {
  const [acik, setAcik] = useState(false)
  const { data: bilet, isPending, error, refetch } = useBilet(biletId)
  const guncelle = useBiletMusteriGuncelle()

  const [taslak, setTaslak] = useState<EkBilgiler>(BOS_EK_BILGI)
  const [telHata, setTelHata] = useState<string | null>(null)
  const [hata, setHata] = useState<string | null>(null)
  const [kaydedildi, setKaydedildi] = useState(false)

  // Hydrate once per ticket, tracked by id rather than by object identity: a
  // refetch after saving must not overwrite what is on screen, and collapsing
  // the section must not throw away something typed but not yet saved.
  const doldurulan = useRef<string | null>(null)
  useEffect(() => {
    if (bilet && doldurulan.current !== bilet.id) {
      doldurulan.current = bilet.id
      setTaslak(ekBilgiAlanlari(bilet))
    }
  }, [bilet])

  useEffect(() => {
    if (!kaydedildi) return
    const t = setTimeout(() => setKaydedildi(false), 3000)
    return () => clearTimeout(t)
  }, [kaydedildi])

  async function kaydet() {
    if (!bilet) return
    setHata(null)
    setTelHata(null)
    if (!telGecerli(taslak.tel)) {
      setTelHata('10 hane girin ya da alanı boş bırakın.')
      return
    }
    try {
      await guncelle.mutateAsync({ bilet_id: bilet.id, ...ekBilgiGonder(taslak) })
      setKaydedildi(true)
    } catch (err) {
      setHata(rpcErrorText(err, 'Kaydedilemedi.'))
    }
  }

  return (
    <section className="overflow-hidden rounded-card border border-border bg-surface shadow-card">
      <button
        type="button"
        onClick={() => setAcik((v) => !v)}
        aria-expanded={acik}
        className="flex w-full items-center gap-3 px-4 py-3 text-left transition-[filter] active:brightness-[0.97]"
      >
        <span className="flex size-10 shrink-0 items-center justify-center rounded-field bg-accent-soft text-accent">
          <IconKisi size={20} />
        </span>
        <span className="min-w-0 flex-1">
          <span className="block text-body font-medium text-ink">Müşteri ve not</span>
          <span className="block truncate text-label text-faint">
            {error ? 'Yüklenemedi' : isPending ? 'Yükleniyor…' : ekBilgiOzet(taslak)}
          </span>
        </span>
        <IconIleri
          size={18}
          className={`shrink-0 text-faint transition-transform duration-150 ${
            acik ? '-rotate-90' : 'rotate-90'
          }`}
        />
      </button>

      {acik && (
        <div className="border-t border-divider px-4 pt-4 pb-5">
          {error ? (
            <LoadError error={error} onRetry={() => void refetch()} />
          ) : isPending ? (
            <div className="py-6">
              <Spinner label="Bilgiler yükleniyor" />
            </div>
          ) : (
            <div className="space-y-4">
              <EkBilgiFormu deger={taslak} onChange={setTaslak} telHatasi={telHata} />

              {hata && (
                <p role="alert" className="rounded-field bg-danger-soft px-3 py-2.5 text-body text-danger">
                  {hata}
                </p>
              )}

              <div className="flex items-center gap-3">
                <Button
                  onClick={() => void kaydet()}
                  loading={guncelle.isPending}
                  disabled={!bilet}
                >
                  Kaydet
                </Button>
                {kaydedildi && (
                  <span className="flex items-center gap-1.5 text-label font-medium text-success">
                    <IconTik size={16} />
                    Kaydedildi
                  </span>
                )}
              </div>
            </div>
          )}
        </div>
      )}
    </section>
  )
}
