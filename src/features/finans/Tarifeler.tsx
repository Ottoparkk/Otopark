import { useState, type ReactNode } from 'react'
import {
  Button,
  Card,
  ListeDurumu,
  Input,
  LoadError,
  ScreenHeader,
  SegmentedControl,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { Spinner } from '../../components/ui/Spinner'
import { useAktifTarifeler } from '../gise/api'
import { useTarifeGuncelle } from '../yonetim/api'
import { useTarifeGecmisi } from './api'
import { useTarifeSil } from '../cop/api'
import { formatTL, kurusToInput, parseTLToKurus, digitsOnly } from '../../lib/money'
import { formatTarih, istanbulGun } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconArti, IconCarpi, IconCop } from '../../components/ui/icons'
import { type Tarife, type TarifeTur } from '../../lib/types'
import {
  KADEME_EN_COK,
  kademeAraliklari,
  kademeBaslangic,
  kademeHatasi,
  kademeListesi,
  kademeUcret,
  type KademeSatiri,
} from './kademe'

/** The real money helpers, handed to the pure band module (see kademe.ts). */
const PARA = { parseTLToKurus, kurusToInput }

/** Stays shown as examples under the band editor: the cases people ask about. */
const ORNEK_SURELER: { etiket: string; dakika: number }[] = [
  { etiket: '1 sa', dakika: 60 },
  { etiket: '2 sa 30 dk', dakika: 150 },
  { etiket: '6 sa', dakika: 360 },
  { etiket: '30 sa', dakika: 1800 },
]

/** One line describing a tariff, for the history list. */
function tarifeOzeti(t: Tarife): string {
  if (t.tur === 'SABIT') return `Sabit ${formatTL(t.sabit_kurus)}`
  if (t.tur === 'KADEMELI') {
    const k = t.kademeler ?? []
    const ilkK = k[0]
    const sonK = k[k.length - 1]
    return ilkK && sonK ? `Kademeli ${formatTL(ilkK.kurus)} – ${formatTL(sonK.kurus)}` : 'Kademeli'
  }
  return `${formatTL(t.ilk_saat_kurus)} · sonraki ${formatTL(t.sonraki_saat_kurus)}`
}

export default function Tarifeler() {
  const { data: tarifeler = [], isPending, error, refetch } = useAktifTarifeler()
  const gecmis = useTarifeGecmisi()
  const guncelle = useTarifeGuncelle()
  const sil = useTarifeSil()

  const [duzenlenen, setDuzenlenen] = useState<Tarife | null>(null)
  const [tur, setTur] = useState<TarifeTur>('SURELI')
  const [sabit, setSabit] = useState('')
  const [ucretsiz, setUcretsiz] = useState('')
  const [ilk, setIlk] = useState('')
  const [sonraki, setSonraki] = useState('')
  const [tavan, setTavan] = useState('')
  const [kayip, setKayip] = useState('')
  const [kademeler, setKademeler] = useState<KademeSatiri[]>([])
  const [hata, setHata] = useState<string | null>(null)
  const [silinecek, setSilinecek] = useState<Tarife | null>(null)
  const [silHata, setSilHata] = useState<string | null>(null)

  function ac(t: Tarife) {
    setDuzenlenen(t)
    setTur(t.tur)
    setSabit(kurusToInput(t.sabit_kurus))
    setUcretsiz(String(t.ucretsiz_dakika))
    setIlk(kurusToInput(t.ilk_saat_kurus))
    setSonraki(kurusToInput(t.sonraki_saat_kurus))
    setTavan(kurusToInput(t.gunluk_tavan_kurus))
    setKayip(kurusToInput(t.kayip_bilet_kurus))
    setKademeler(kademeBaslangic(t.kademeler, PARA))
    setHata(null)
  }

  function kademeDegistir(i: number, yama: Partial<KademeSatiri>) {
    setKademeler((onceki) => onceki.map((s, j) => (j === i ? { ...s, ...yama } : s)))
  }

  // Examples only while the bands are valid: a preview built from a list the
  // server would refuse would quote prices nobody will ever be charged.
  const kademeOrnekleri =
    tur === 'KADEMELI' && kademeHatasi(kademeler, PARA) === null
      ? ORNEK_SURELER.map((o) => ({
          etiket: o.etiket,
          kurus: kademeUcret(o.dakika, Number(ucretsiz) || 0, kademeListesi(kademeler, PARA)),
        }))
      : null

  return (
    <div>
      <ScreenHeader title="Tarifeler" back="/finans" subtitle="Değişiklik yeni sürüm oluşturur" />

      <div className="space-y-3 px-5">
        <p className="rounded-card bg-accent-soft px-4 py-3 text-label text-accent">
          Fiyat değiştirdiğinizde eski tarife kapatılır ve yenisi açılır.
          <strong className="font-semibold"> İçeride bekleyen araçlar girdikleri fiyatı korur.</strong>
        </p>

        {error ? (
          <LoadError error={error} onRetry={() => void refetch()} />
        ) : isPending ? (
          <div className="py-14">
            <Spinner label="Yükleniyor" />
          </div>
        ) : (
          tarifeler.map((t) => (
            <Card key={t.id}>
              <button type="button" onClick={() => ac(t)} className="w-full text-left">
                <div className="flex items-baseline justify-between gap-3">
                  <span className="text-lead font-medium text-ink">Geçerli tarife</span>
                  <span className="text-lead font-semibold text-ink tnum">
                    {t.tur === 'KADEMELI'
                      ? 'Kademeli'
                      : formatTL(t.tur === 'SABIT' ? t.sabit_kurus : t.ilk_saat_kurus)}
                  </span>
                </div>
                <dl className="mt-3 space-y-1.5">
                  {/* A fixed or banded tariff's hourly columns are written as 0
                      by the RPC, so showing them would state a price that is
                      never charged. */}
                  {t.tur === 'SABIT' ? (
                    <Satir k="Sabit ücret" v={`${formatTL(t.sabit_kurus)} · giriş başına`} />
                  ) : t.tur === 'KADEMELI' ? (
                    <>
                      {kademeAraliklari(t.kademeler ?? []).map((a) => (
                        <Satir key={a.etiket} k={a.etiket} v={formatTL(a.kurus)} />
                      ))}
                      <Satir k="24 saatten sonra" v="her gün + kalan süre kademeyle" />
                    </>
                  ) : (
                    <>
                      <Satir k="İlk saat" v={formatTL(t.ilk_saat_kurus)} />
                      <Satir k="Sonraki her saat" v={formatTL(t.sonraki_saat_kurus)} />
                      <Satir
                        k="Günlük tavan"
                        v={t.gunluk_tavan_kurus > 0 ? formatTL(t.gunluk_tavan_kurus) : 'yok'}
                      />
                    </>
                  )}
                  <Satir k="Ücretsiz süre" v={`${t.ucretsiz_dakika} dk`} />
                  <Satir
                    k="Kayıp bilet"
                    v={t.kayip_bilet_kurus > 0 ? formatTL(t.kayip_bilet_kurus) : 'tanımsız'}
                  />
                </dl>
              </button>
            </Card>
          ))
        )}

        {/* ---- superseded versions ----------------------------------- */}
        <section className="pt-3">
          <h2 className="mb-2 text-label font-medium tracking-wide text-faint uppercase">
            Geçmiş sürümler
          </h2>
          {/* Most of these cannot actually be deleted: `biletler.tarife_id` is
              ON DELETE RESTRICT, so any version that ever priced a ticket is
              pinned by it. Counting tickets client-side to hide the button
              would be a second, drifting copy of that rule — the RPC answers
              instead, and its Turkish message lands in the dialog. */}
          <ListeDurumu
            pending={gecmis.isPending}
            error={gecmis.error}
            onRetry={() => void gecmis.refetch()}
            empty={(gecmis.data ?? []).length === 0}
            bos={
              <p className="py-2 text-body text-faint">
                Henüz eski sürüm yok — fiyat hiç değişmemiş.
              </p>
            }
          >
            <div className="space-y-2">
              {(gecmis.data ?? []).map((t) => (
                <Card key={t.id} className="flex items-center gap-3">
                  <div className="min-w-0 flex-1">
                    <p className="truncate text-body text-ink tnum">{tarifeOzeti(t)}</p>
                    <p className="mt-0.5 truncate text-label text-faint tnum">
                      {formatTarih(istanbulGun(new Date(t.gecerli_baslangic)))} —{' '}
                      {t.gecerli_bitis ? formatTarih(istanbulGun(new Date(t.gecerli_bitis))) : ''}
                    </p>
                  </div>
                  <button
                    type="button"
                    onClick={() => {
                      setSilHata(null)
                      setSilinecek(t)
                    }}
                    aria-label="Tarife sürümünü sil"
                    className="flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field"
                  >
                    <IconCop size={18} />
                  </button>
                </Card>
              ))}
            </div>
          </ListeDurumu>
        </section>
      </div>

      <ConfirmDialog
        open={silinecek !== null}
        onOpenChange={() => setSilinecek(null)}
        tone="danger"
        title="Tarife sürümünü sil"
        description="Bu eski fiyat sürümü silinecek. Bu sürümle ücretlendirilmiş bilet varsa silinemez. Çöp Kutusu'ndan geri alınabilir."
        confirmLabel="Sil"
        loading={sil.isPending}
        error={silHata}
        onConfirm={() => {
          if (!silinecek) return
          void sil
            .mutateAsync(silinecek.id)
            .then(() => setSilinecek(null))
            .catch((e) => setSilHata(rpcErrorText(e, 'Tarife silinemedi.')))
        }}
      />

      <FormModal
        open={duzenlenen !== null}
        onOpenChange={() => setDuzenlenen(null)}
        title="Tarife"
        submitLabel="Yeni sürümü kaydet"
        loading={guncelle.isPending}
        error={hata}
        onSubmit={() => {
          if (!duzenlenen) return
          const sabitMi = tur === 'SABIT'
          const kademeliMi = tur === 'KADEMELI'
          const saatlikMi = !sabitMi && !kademeliMi
          // Only the fields of the chosen type are read, so a half of the form
          // the operator never opened cannot fail the validation.
          const ilkK = saatlikMi ? parseTLToKurus(ilk) : 0
          const sonK = saatlikMi ? parseTLToKurus(sonraki) : 0
          const tavK = saatlikMi ? parseTLToKurus(tavan || '0') : 0
          const sabitK = sabitMi ? parseTLToKurus(sabit) : 0
          const kayK = parseTLToKurus(kayip || '0')
          const ucD = Number(ucretsiz)

          if (ilkK === null || sonK === null || tavK === null || kayK === null || sabitK === null) {
            setHata('Tutarları geçerli girin (örn. 60 ya da 60,50).')
            return
          }
          if (sabitMi && sabitK <= 0) {
            setHata('Sabit ücret sıfırdan büyük olmalı.')
            return
          }
          if (!Number.isFinite(ucD) || ucD < 0 || ucD > 1440) {
            setHata('Ücretsiz süre 0-1440 dakika arasında olmalı.')
            return
          }
          if (saatlikMi && tavK > 0 && tavK < ilkK) {
            setHata('Günlük tavan ilk saat ücretinden düşük olamaz.')
            return
          }
          if (kademeliMi) {
            const kademeSorun = kademeHatasi(kademeler, PARA)
            if (kademeSorun) {
              setHata(kademeSorun)
              return
            }
          }

          void guncelle
            .mutateAsync({
              tur,
              sabit_kurus: sabitK,
              ucretsiz_dakika: ucD,
              ilk_saat_kurus: ilkK,
              sonraki_saat_kurus: sonK,
              gunluk_tavan_kurus: tavK,
              kayip_bilet_kurus: kayK,
              kademeler: kademeliMi ? kademeListesi(kademeler, PARA) : null,
            })
            .then(() => setDuzenlenen(null))
            .catch((e) => setHata(rpcErrorText(e, 'Tarife güncellenemedi.')))
        }}
      >
        {/* First, because it decides which of the fields below even exist.
            Putting it anywhere else would let someone fill in three hourly
            boxes and then find out none of them are used. */}
        <SegmentedControl
          value={tur}
          onChange={(v) => {
            setTur(v)
            setHata(null)
          }}
          label="Ücretlendirme"
          options={[
            { value: 'SABIT', label: 'Sabit' },
            { value: 'SURELI', label: 'Süreli' },
            { value: 'KADEMELI', label: 'Kademeli' },
          ]}
        />
        <Input
          label="Ücretsiz süre (dakika)"
          value={ucretsiz}
          onChange={(e) => setUcretsiz(digitsOnly(e.target.value, 4))}
          inputMode="numeric"
          // Only where it is not obvious: an hourly tariff does NOT subtract
          // the free minutes once they are exceeded.
          hint={tur === 'SURELI' ? 'Aşan araç ilk saatten ücret öder.' : undefined}
        />
        {tur === 'SABIT' ? (
          <Input
            label="Giriş başına ücret (₺)"
            value={sabit}
            onChange={(e) => setSabit(e.target.value)}
            inputMode="decimal"
          />
        ) : tur === 'KADEMELI' ? (
          // Owner (2026-11-10): "easy to use, not overblown with texts". The
          // rows read as "2 sa → 60 ₺" on their own; the examples below show
          // what a stay costs, including past 24 h, instead of a paragraph.
          <div className="space-y-2">
            <div className="flex gap-2 text-label font-medium tracking-wide text-faint uppercase">
              <span className="min-w-0 flex-1">Saate kadar</span>
              <span className="min-w-0 flex-1">Ücret</span>
              <span aria-hidden className="w-11 shrink-0" />
            </div>
            {kademeler.map((s, i) => {
              const sonSatir = i === kademeler.length - 1
              return (
                <div key={i} className="flex items-center gap-2">
                  <div className="min-w-0 flex-1">
                    {sonSatir ? (
                      // The last band is the day: always 24 h, so it is text,
                      // not a greyed-out field that looks broken.
                      <p className="flex min-h-[52px] items-center px-4 text-body text-soft tnum">
                        24 sa
                      </p>
                    ) : (
                      <Birimli birim="sa">
                        <Input
                          aria-label={`${i + 1}. kademe: saate kadar`}
                          value={s.saat}
                          onChange={(e) =>
                            kademeDegistir(i, { saat: digitsOnly(e.target.value, 2) })
                          }
                          inputMode="numeric"
                          className="pr-10 tnum"
                        />
                      </Birimli>
                    )}
                  </div>
                  <div className="min-w-0 flex-1">
                    <Birimli birim="₺">
                      <Input
                        aria-label={`${i + 1}. kademe: ücret`}
                        value={s.tutar}
                        onChange={(e) => kademeDegistir(i, { tutar: e.target.value })}
                        inputMode="decimal"
                        className="pr-10 tnum"
                      />
                    </Birimli>
                  </div>
                  {sonSatir ? (
                    // Same width as the remove button, so the columns line up.
                    <span aria-hidden className="size-11 shrink-0" />
                  ) : (
                    <button
                      type="button"
                      aria-label={`${i + 1}. kademeyi kaldır`}
                      onClick={() => setKademeler((o) => o.filter((_, j) => j !== i))}
                      className="flex size-11 shrink-0 items-center justify-center rounded-chip text-faint active:bg-field"
                    >
                      <IconCarpi size={18} />
                    </button>
                  )}
                </div>
              )
            })}
            {kademeler.length < KADEME_EN_COK && (
              <Button
                // type="button" is REQUIRED: Button has no default type, and
                // inside FormModal's <form> it would submit — "Kademe ekle"
                // on a valid list would save a new tariff version.
                type="button"
                variant="secondary"
                block
                onClick={() =>
                  // New rows go above the fixed 24-hour row.
                  setKademeler((o) => [...o.slice(0, -1), { saat: '', tutar: '' }, ...o.slice(-1)])
                }
              >
                <IconArti size={18} />
                Kademe ekle
              </Button>
            )}
            {kademeOrnekleri && (
              <div className="rounded-field bg-field px-4 py-3">
                <p className="mb-1.5 text-label font-medium text-faint">Örnek</p>
                <dl className="space-y-1">
                  {kademeOrnekleri.map((o) => (
                    <Satir key={o.etiket} k={o.etiket} v={formatTL(o.kurus)} />
                  ))}
                </dl>
              </div>
            )}
          </div>
        ) : (
          <>
            <Input
              label="İlk saat (₺)"
              value={ilk}
              onChange={(e) => setIlk(e.target.value)}
              inputMode="decimal"
            />
            <Input
              label="Sonraki her saat (₺)"
              value={sonraki}
              onChange={(e) => setSonraki(e.target.value)}
              inputMode="decimal"
            />
            <Input
              label="Günlük tavan (₺)"
              value={tavan}
              onChange={(e) => setTavan(e.target.value)}
              inputMode="decimal"
              hint="0 = tavan yok"
            />
          </>
        )}
        <Input
          label="Kayıp bilet ücreti (₺)"
          value={kayip}
          onChange={(e) => setKayip(e.target.value)}
          inputMode="decimal"
          hint="0 = kapalı"
        />
      </FormModal>
    </div>
  )
}

/** A field with its unit inside, on the right ("sa", "₺"). */
function Birimli({ birim, children }: { birim: string; children: ReactNode }) {
  return (
    <div className="relative">
      {children}
      <span
        aria-hidden
        className="pointer-events-none absolute top-1/2 right-4 -translate-y-1/2 text-body text-faint"
      >
        {birim}
      </span>
    </div>
  )
}

function Satir({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="text-body text-faint">{k}</dt>
      <dd className="text-body text-soft tnum">{v}</dd>
    </div>
  )
}
