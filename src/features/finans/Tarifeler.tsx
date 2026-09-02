import { useState } from 'react'
import {
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
import { IconCop } from '../../components/ui/icons'
import { type Tarife, type TarifeTur } from '../../lib/types'

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
    setHata(null)
  }

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
                    {formatTL(t.tur === 'SABIT' ? t.sabit_kurus : t.ilk_saat_kurus)}
                  </span>
                </div>
                <dl className="mt-3 space-y-1.5">
                  {/* A fixed tariff's hourly columns are written as 0 by the
                      RPC, so showing them would state a price that is never
                      charged. */}
                  {t.tur === 'SABIT' ? (
                    <Satir k="Sabit ücret" v={`${formatTL(t.sabit_kurus)} · giriş başına`} />
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
                    <p className="truncate text-body text-ink tnum">
                      {formatTL(t.ilk_saat_kurus)}
                      <span className="text-faint"> · sonraki {formatTL(t.sonraki_saat_kurus)}</span>
                    </p>
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
          // A fixed tariff never reads the hourly boxes, so they must not be
          // able to fail its validation — the operator may never have opened
          // that half of the form.
          const ilkK = sabitMi ? 0 : parseTLToKurus(ilk)
          const sonK = sabitMi ? 0 : parseTLToKurus(sonraki)
          const tavK = sabitMi ? 0 : parseTLToKurus(tavan || '0')
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
          if (!sabitMi && tavK > 0 && tavK < ilkK) {
            setHata('Günlük tavan ilk saat ücretinden düşük olamaz.')
            return
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
          onChange={setTur}
          label="Ücretlendirme"
          options={[
            { value: 'SABIT', label: 'Sabit' },
            { value: 'SURELI', label: 'Süreli' },
          ]}
        />
        <Input
          label="Ücretsiz süre (dakika)"
          value={ucretsiz}
          onChange={(e) => setUcretsiz(digitsOnly(e.target.value, 4))}
          inputMode="numeric"
          hint={
            tur === 'SABIT'
              ? 'Bu süre içinde çıkan araç ücret ödemez.'
              : 'Bu süreyi aşan araç ilk saat ücretini öder.'
          }
        />
        {tur === 'SABIT' ? (
          <Input
            label="Sabit ücret (₺)"
            value={sabit}
            onChange={(e) => setSabit(e.target.value)}
            inputMode="decimal"
            hint="Süreden bağımsız, giriş başına alınır."
          />
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
          hint="Girişi kaydedilmemiş araçtan alınır. 0 = kapalı"
        />
      </FormModal>
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
