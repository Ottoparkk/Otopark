import { useMemo, useState } from 'react'
import { useParams } from 'react-router'
import {
  Card,
  Input,
  ListeDurumu,
  LoadError,
  ScreenHeader,
  Select,
} from '../../components/ui/primitives'
import { Button } from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { YontemSecici } from '../../components/ui/YontemSecici'
import { Spinner } from '../../components/ui/Spinner'
import {
  useAvansVer,
  useMaasGuncelle,
  useMaasOde,
  usePersonelOdemeler,
  usePersonelOzet,
  usePrimVer,
  useProfiller,
} from './api'
import { formatTL, kurusToInput, parseTLToKurus } from '../../lib/money'
import { formatTarih } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { ODEME_TUR_ETIKET } from '../../lib/types'
import type { OdemeYontemi, PersonelOdeme } from '../../lib/types'

type Islem = 'MAAS' | 'AVANS' | 'PRIM' | null

/**
 * One member of staff: what they are paid, what they owe, and what they have
 * been given.
 *
 * Yönetici only — the route guard says so and every RPC behind it re-checks,
 * because what one person earns is the single most private thing this app
 * stores about them.
 *
 * The figures come from `personel_ozet`, NOT from summing the rows below.
 * Advance debt is derived server-side and the same number decides what a
 * salary payment actually pays out; computing it a second time here would
 * eventually disagree with what leaves the kasa, and the screen would be
 * confidently wrong about somebody's pay.
 */
export default function PersonelDetay() {
  const { id = '' } = useParams()
  const { data: liste = [] } = useProfiller()
  const ozet = usePersonelOzet(id)
  const odemeler = usePersonelOdemeler(id)

  const maasGuncelle = useMaasGuncelle()
  const maasOde = useMaasOde()
  const avansVer = useAvansVer()
  const primVer = usePrimVer()

  const kisi = useMemo(() => liste.find((p) => p.id === id), [liste, id])

  const [maas, setMaas] = useState<string | null>(null)
  /** '' = no automatic payment. Otherwise the day of the month. */
  const [maasGun, setMaasGun] = useState('')
  const [maasYontem, setMaasYontem] = useState<OdemeYontemi | null>(null)
  const [maasHata, setMaasHata] = useState<string | null>(null)

  const [islem, setIslem] = useState<Islem>(null)
  const [tutar, setTutar] = useState('')
  const [aciklama, setAciklama] = useState('')
  const [yontem, setYontem] = useState<OdemeYontemi | null>(null)
  const [hata, setHata] = useState<string | null>(null)

  const borc = ozet.data?.borc_kurus ?? 0
  const maasKurus = ozet.data?.maas_kurus ?? 0
  // What pressing "Maaş Öde" will actually move. Mirrors maas_ode exactly:
  // the debt is deducted, and anything it cannot cover carries to next time.
  const netMaas = Math.max(0, maasKurus - borc)

  function ac(t: Exclude<Islem, null>) {
    setIslem(t)
    setTutar('')
    setAciklama('')
    setYontem(null)
    setHata(null)
  }

  function gonder() {
    if (!islem) return
    const kurus = parseTLToKurus(tutar)
    if (islem !== 'MAAS' && (kurus === null || kurus <= 0)) {
      setHata('Geçerli bir tutar girin.')
      return
    }
    const istek: Promise<unknown> =
      islem === 'MAAS'
        ? maasOde.mutateAsync({ profile_id: id, yontem, aciklama: aciklama.trim() })
        : islem === 'AVANS'
          ? avansVer.mutateAsync({
              profile_id: id,
              tutar_kurus: kurus ?? 0,
              yontem,
              aciklama: aciklama.trim(),
            })
          : primVer.mutateAsync({
              profile_id: id,
              tutar_kurus: kurus ?? 0,
              yontem,
              aciklama: aciklama.trim(),
            })

    void istek
      .then(() => setIslem(null))
      .catch((e) => setHata(rpcErrorText(e, 'Ödeme kaydedilemedi.')))
  }

  return (
    <div>
      <ScreenHeader
        title={kisi?.ad_soyad || 'Personel'}
        back="/yonetim/personel"
        subtitle={kisi?.rol === 'YONETICI' ? 'Yönetici' : 'Personel'}
      />

      <div className="space-y-4 px-5">
        {ozet.error ? (
          <LoadError error={ozet.error} onRetry={() => void ozet.refetch()} />
        ) : ozet.isPending ? (
          <Spinner />
        ) : (
          <>
            <Card>
              {/* items-center, not items-baseline: the button is a pill now,
                  and baseline alignment would hang it above and below the
                  caption it sits beside. */}
              <div className="flex items-center justify-between gap-3">
                <span className="text-label font-medium tracking-wide text-faint uppercase">
                  Maaş
                </span>
                <button
                  type="button"
                  onClick={() => {
                    setMaas(kurusToInput(maasKurus))
                    setMaasGun(ozet.data?.odeme_gunu ? String(ozet.data.odeme_gunu) : '')
                    setMaasYontem(ozet.data?.maas_yontemi ?? null)
                    setMaasHata(null)
                  }}
                  // A tinted pill, not bare accent text. At 13px on white the
                  // link was the least visible thing on the card while being
                  // the only way to change the number above it; the background
                  // is what makes it read as a control rather than a caption.
                  className="min-h-[40px] rounded-chip bg-accent-soft px-3.5 text-body font-medium text-accent"
                >
                  Düzenle
                </button>
              </div>
              <p className="mt-1 text-title font-semibold text-ink tnum">{formatTL(maasKurus)}</p>
              {/* Says so on the card, not only inside the form: money that
                  moves on its own at night has to be visible without opening
                  anything. */}
              <p className="mt-0.5 text-label text-faint tnum">
                {ozet.data?.odeme_gunu
                  ? `Her ayın ${ozet.data.odeme_gunu}. günü otomatik ödenir`
                  : 'Otomatik ödeme yok'}
              </p>

              {/* Only when there is one. A permanent "0 ₺ borç" line trains
                  the eye to skip the place the real number will appear. */}
              {borc > 0 && (
                <p className="mt-2 text-body text-danger tnum">
                  Avans borcu: {formatTL(borc)}
                  <span className="text-faint"> · maaştan düşülecek</span>
                </p>
              )}
              {borc > 0 && (
                <p className="mt-0.5 text-label text-faint tnum">
                  Ödenecek net: {formatTL(netMaas)}
                  {netMaas === 0 && ' — borç bir sonraki maaşa devreder'}
                </p>
              )}

              {/* Three across only from md. At 375px each button is 95px wide
                  with 32px of that padding, so "Maaş Öde" and "Avans Ver" both
                  broke across two lines. The primary action takes the full
                  width on a phone and the two secondary ones share the row
                  below; `md:contents` dissolves that wrapper so the desktop
                  layout stays the three-column row it was. */}
              <div className="mt-4 space-y-2 md:grid md:grid-cols-3 md:gap-2 md:space-y-0">
                <Button block onClick={() => ac('MAAS')} disabled={maasKurus <= 0}>
                  Maaş Öde
                </Button>
                <div className="grid grid-cols-2 gap-2 md:contents">
                  <Button block variant="secondary" onClick={() => ac('AVANS')}>
                    Avans Ver
                  </Button>
                  <Button block variant="secondary" onClick={() => ac('PRIM')}>
                    Prim Ver
                  </Button>
                </div>
              </div>
            </Card>

            <Card>
              <h3 className="mb-3 text-label font-medium tracking-wide text-faint uppercase">
                Ödeme geçmişi
              </h3>
              <ListeDurumu
                pending={odemeler.isPending}
                error={odemeler.error}
                onRetry={() => void odemeler.refetch()}
                empty={(odemeler.data ?? []).length === 0}
                bos={<p className="py-1 text-body text-faint">Henüz ödeme yapılmadı.</p>}
              >
                <ul className="space-y-2.5">
                  {(odemeler.data ?? []).map((o: PersonelOdeme) => (
                    <li key={o.id} className="flex items-baseline justify-between gap-3">
                      <div className="min-w-0">
                        <p className="truncate text-body text-ink">
                          {ODEME_TUR_ETIKET[o.tur]}
                          {o.aciklama && <span className="text-faint"> · {o.aciklama}</span>}
                        </p>
                        <p className="mt-0.5 text-label text-faint tnum">
                          {formatTarih(o.tarih)}
                          {/* A salary that paid off debt moved less cash than
                              it was worth; saying so here is what stops the
                              history reading as an underpayment. */}
                          {o.avans_dusulen > 0 &&
                            ` · ${formatTL(o.avans_dusulen)} avans düşüldü`}
                        </p>
                      </div>
                      <span className="shrink-0 text-body font-semibold text-ink tnum">
                        {formatTL(o.tutar_kurus)}
                      </span>
                    </li>
                  ))}
                </ul>
              </ListeDurumu>
            </Card>
          </>
        )}
      </div>

      {/* ------------------------------------------------------ maaş ---- */}
      <FormModal
        open={maas !== null}
        onOpenChange={() => setMaas(null)}
        title="Maaş"
        submitLabel="Kaydet"
        loading={maasGuncelle.isPending}
        error={maasHata}
        onSubmit={() => {
          const kurus = parseTLToKurus(maas ?? '')
          if (kurus === null || kurus < 0) {
            setMaasHata('Geçerli bir tutar girin.')
            return
          }
          void maasGuncelle
            .mutateAsync({
              profile_id: id,
              maas_kurus: kurus,
              odeme_gunu: maasGun ? Number(maasGun) : null,
              yontem: maasYontem,
            })
            .then(() => setMaas(null))
            .catch((e) => setMaasHata(rpcErrorText(e, 'Maaş kaydedilemedi.')))
        }}
      >
        <Input
          label="Aylık maaş (₺)"
          value={maas ?? ''}
          onChange={(e) => setMaas(e.target.value)}
          inputMode="decimal"
          hint="Maaş Öde bu tutarı, varsa avans borcu düşülerek öder."
        />
        <Select
          id="maas-gun"
          label="Otomatik ödeme günü"
          value={maasGun}
          onChange={(e) => setMaasGun(e.target.value)}
          hint={
            maasGun
              ? 'Gece işi o gün maaşı öder. O ay elle ödenmişse tekrar ödemez.'
              : 'Seçilmezse maaş yalnızca elle ödenir.'
          }
        >
          <option value="">Yok (elle öde)</option>
          {Array.from({ length: 28 }, (_, i) => i + 1).map((g) => (
            <option key={g} value={g}>
              Her ayın {g}. günü
            </option>
          ))}
        </Select>
        {/* The night job cannot ask anyone, so the method lives on the
            definition rather than being chosen at payment time. */}
        <YontemSecici
          value={maasYontem}
          onChange={setMaasYontem}
          label="Otomatik ödeme yöntemi (isteğe bağlı)"
        />
      </FormModal>

      {/* --------------------------------------------------- ödemeler --- */}
      <FormModal
        open={islem !== null}
        onOpenChange={() => setIslem(null)}
        title={islem === 'MAAS' ? 'Maaş ödemesi' : islem === 'AVANS' ? 'Avans Ver' : 'Prim Ver'}
        submitLabel={islem === 'MAAS' ? 'Öde' : 'Ver'}
        loading={maasOde.isPending || avansVer.isPending || primVer.isPending}
        error={hata}
        onSubmit={gonder}
      >
        {islem === 'MAAS' ? (
          // No amount field: the salary is what it is, and the deduction is
          // the server's to compute. A typed number here would be a second
          // opinion about somebody's pay.
          <p className="rounded-field bg-field px-3.5 py-3 text-body text-soft tnum">
            {formatTL(maasKurus)} maaş
            {borc > 0 && <> − {formatTL(Math.min(borc, maasKurus))} avans</>} ={' '}
            <strong className="font-semibold text-ink">{formatTL(netMaas)}</strong> ödenecek
          </p>
        ) : (
          <Input
            label="Tutar (₺)"
            value={tutar}
            onChange={(e) => setTutar(e.target.value)}
            inputMode="decimal"
            hint={islem === 'AVANS' ? 'Bir sonraki maaştan düşülür.' : 'Maaşın üstüne verilir.'}
          />
        )}
        <Input
          label="Açıklama (isteğe bağlı)"
          value={aciklama}
          onChange={(e) => setAciklama(e.target.value)}
          maxLength={120}
        />
        <YontemSecici value={yontem} onChange={setYontem} label="Ödeme yöntemi (isteğe bağlı)" />
      </FormModal>
    </div>
  )
}
