import { useState } from 'react'
import {
  Button,
  Card,
  EmptyState,
  Input,
  ScreenHeader,
} from '../../components/ui/primitives'
import { FormModal } from '../../components/ui/FormModal'
import { Spinner } from '../../components/ui/Spinner'
import {
  useAcikVardiya,
  useVardiyaAc,
  useVardiyaKapat,
  useVardiyaOzetim,
  useVardiyalarim,
} from './api'
import { formatTL, kurusToInput, parseTLToKurus } from '../../lib/money'
import { formatGoreceli, formatTam } from '../../lib/dates'
import { sureMetni } from '../../lib/sure'
import { rpcErrorText } from '../../lib/errors'
import { IconVardiya } from '../../components/ui/icons'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'

export default function Vardiya() {
  const { profile } = useAuth()
  const { data: ozet, isPending } = useVardiyaOzetim()
  const yonetici = isYonetici(profile)
  const { data: gecmis = [] } = useVardiyalarim(yonetici)
  // The open shift row, for the one thing the summary RPC does not carry:
  // whether a count is already sitting in the Yönetici's approval queue.
  const { data: acik } = useAcikVardiya()
  const talepVar = Boolean(acik?.kapatma_talebi_at)
  // A Yönetici tapping the same button CLOSES the till outright, so the
  // "correct your count" wording belongs only to the person whose count is
  // actually waiting. Same state, two different acts.
  const duzeltme = talepVar && !yonetici

  const ac = useVardiyaAc()
  const kapat = useVardiyaKapat()

  const [acModal, setAcModal] = useState(false)
  const [kapatModal, setKapatModal] = useState(false)
  const [acilisNakit, setAcilisNakit] = useState('0')
  const [sayilan, setSayilan] = useState('')
  const [notlar, setNotlar] = useState('')
  const [hata, setHata] = useState<string | null>(null)
  const [sonuc, setSonuc] = useState<{
    /** False = the count became a request; the till is still open. */
    kapandi: boolean
    beklenen: number
    sayilan: number
    fark: number
  } | null>(null)

  const beklenenKurus = ozet ? ozet.acilis_nakit_kurus + ozet.nakit_kurus : 0
  const sayilanKurus = parseTLToKurus(sayilan)
  const canliFark = sayilanKurus === null ? null : sayilanKurus - beklenenKurus

  if (isPending) {
    return (
      <div className="py-20">
        <Spinner label="Vardiya yükleniyor" />
      </div>
    )
  }

  return (
    <div>
      {/* Not the operator's name any more: one drawer, one shift, shared by
          whoever is on it. Titling it with a person would say the opposite. */}
      <ScreenHeader title="Vardiya" subtitle="Ortak kasa" />

      <div className="space-y-4 px-5">
        {!ozet ? (
          <>
            <EmptyState
              icon={<IconVardiya size={44} />}
              title="Kasa vardiyası açık değil"
              hint="Vardiya açık değilken tahsil edilen nakit hiçbir sayıma girmez."
              action={
                <Button size="lg" onClick={() => setAcModal(true)}>
                  Vardiya Aç
                </Button>
              }
            />
          </>
        ) : (
          <>
            <Card>
              <p className="text-label text-faint">
                {formatGoreceli(ozet.acilis_at)} · {sureMetni(ozet.acilis_at)}
                {ozet.otomatik_acildi && ' · otomatik açıldı'}
              </p>

              <p className="mt-3 text-hero font-semibold text-ink tnum">
                {formatTL(ozet.toplam_kurus, { decimals: 0 })}
              </p>
              <p className="mt-0.5 text-label text-faint">
                bu vardiyada tahsil edildi · {ozet.bilet_sayisi} işlem
              </p>

              <div className="mt-5 grid grid-cols-3 gap-2 border-t border-divider pt-4">
                <Kova etiket="Nakit" kurus={ozet.nakit_kurus} renk="text-nakit" />
                <Kova etiket="Kart" kurus={ozet.kart_kurus} renk="text-kart" />
                <Kova etiket="Havale" kurus={ozet.havale_kurus} renk="text-havale" />
              </div>
            </Card>

            {/* Only cash is in the drawer — card and transfer never were. */}
            <Card>
              <div className="flex items-baseline justify-between gap-3">
                <span className="text-body text-faint">Kasada olması gereken nakit</span>
                <span className="text-title font-semibold text-ink tnum">
                  {formatTL(beklenenKurus)}
                </span>
              </div>
              <p className="mt-1.5 text-label text-faint">
                Açılış {formatTL(ozet.acilis_nakit_kurus)} + nakit tahsilat{' '}
                {formatTL(ozet.nakit_kurus)}
              </p>
              {/* An automatic shift's opening float came from the setting, not
                  from anyone counting the drawer. If the two differ, every
                  close reports a difference that nobody caused — so say where
                  the number came from rather than letting it look counted. */}
              {ozet.otomatik_acildi && (
                <p className="mt-1.5 text-label text-warn">
                  Açılış nakdi ayardan geldi, sayılmadı. Kasadaki para farklıysa
                  fark bu tutardan doğar.
                </p>
              )}
            </Card>

            {/* A filed request is a state the operator must be able to SEE.
                Without this the screen looks exactly as it did before they
                counted, and the natural read is that the tap did nothing. */}
            {talepVar && (
              <Card className="bg-warn-soft">
                <p className="text-body font-semibold text-warn">
                  Kapatma isteği yönetici onayında
                </p>
                <p className="mt-1 text-label text-warn">
                  Sayılan {formatTL(acik?.talep_sayilan_kurus ?? 0)} ·{' '}
                  {yonetici
                    ? 'Onay ekranından karara bağlayabilirsiniz.'
                    : 'yönetici onayladığında vardiya kapanacak.'}
                </p>
              </Card>
            )}

            <Button
              variant="secondary"
              size="lg"
              block
              onClick={() => {
                // Prefilled when correcting a filed count: the operator is
                // adjusting a number they already sent, not entering a new one.
                setSayilan(
                  duzeltme && acik?.talep_sayilan_kurus != null
                    ? kurusToInput(acik.talep_sayilan_kurus)
                    : '',
                )
                setNotlar(duzeltme ? (acik?.talep_notlar ?? '') : '')
                setHata(null)
                setKapatModal(true)
              }}
            >
              {duzeltme ? 'Sayımı Düzelt' : 'Vardiyayı Kapat'}
            </Button>
          </>
        )}

        {gecmis.length > 0 && (
          <div className="pt-2">
            <p className="mb-2 text-label font-medium tracking-wide text-faint uppercase">
              Geçmiş vardiyalar
            </p>
            <div className="space-y-2">
              {gecmis.map((v) => (
                <Card key={v.id} className="flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <p className="text-body text-ink">{formatTam(v.acilis_at)}</p>
                    <p className="mt-0.5 text-label text-faint">
                      {v.kapanis_at ? sureMetni(v.acilis_at, v.kapanis_at) : '—'}
                    </p>
                  </div>
                  <FarkRozeti fark={v.fark_kurus} />
                </Card>
              ))}
            </div>
          </div>
        )}
      </div>

      {/* ---- open ---------------------------------------------------- */}
      <FormModal
        open={acModal}
        onOpenChange={setAcModal}
        title="Vardiya aç"
        submitLabel="Aç"
        loading={ac.isPending}
        error={hata}
        onSubmit={() => {
          const kurus = parseTLToKurus(acilisNakit || '0')
          if (kurus === null) {
            setHata('Geçerli bir tutar girin.')
            return
          }
          void ac
            .mutateAsync(kurus)
            .then(() => setAcModal(false))
            .catch((e) => setHata(rpcErrorText(e, 'Vardiya açılamadı.')))
        }}
      >
        <Input
          label="Kasadaki açılış nakdi (₺)"
          value={acilisNakit}
          onChange={(e) => setAcilisNakit(e.target.value)}
          inputMode="decimal"
          hint="Vardiyaya başlarken kasada duran para. Yoksa 0 bırakın."
        />
      </FormModal>

      {/* ---- close --------------------------------------------------- */}
      <FormModal
        open={kapatModal}
        onOpenChange={setKapatModal}
        title={duzeltme ? 'Sayımı düzelt' : 'Vardiyayı kapat'}
        submitLabel={duzeltme ? 'Gönder' : 'Kapat'}
        loading={kapat.isPending}
        error={hata}
        onSubmit={() => {
          if (sayilanKurus === null) {
            setHata('Sayılan nakdi girin.')
            return
          }
          void kapat
            .mutateAsync({ sayilan: sayilanKurus, notlar: notlar.trim() || null })
            .then((r) => {
              setKapatModal(false)
              setSonuc({
                // The server decides, not the client's idea of the role: a
                // Personel files a request, a Yönetici closes outright.
                kapandi: r.kapandi,
                beklenen: r.beklenen_kurus,
                sayilan: r.sayilan_kurus,
                fark: r.fark_kurus,
              })
            })
            .catch((e) => setHata(rpcErrorText(e, 'Vardiya kapatılamadı.')))
        }}
      >
        <div className="rounded-field bg-field px-4 py-3">
          <div className="flex items-baseline justify-between">
            <span className="text-body text-faint">Olması gereken</span>
            <span className="text-lead font-semibold text-ink tnum">
              {formatTL(beklenenKurus)}
            </span>
          </div>
        </div>

        <Input
          label="Sayılan nakit (₺)"
          value={sayilan}
          onChange={(e) => setSayilan(e.target.value)}
          inputMode="decimal"
          autoFocus
        />

        {/* Live difference: the operator sees the discrepancy BEFORE
            committing, while they can still recount. */}
        {canliFark !== null && (
          <div
            className={[
              'rounded-field px-4 py-3',
              canliFark === 0
                ? 'bg-success-soft'
                : canliFark < 0
                  ? 'bg-danger-soft'
                  : 'bg-warn-soft',
            ].join(' ')}
          >
            <div className="flex items-baseline justify-between">
              <span
                className={[
                  'text-body',
                  canliFark === 0
                    ? 'text-success'
                    : canliFark < 0
                      ? 'text-danger'
                      : 'text-warn',
                ].join(' ')}
              >
                {canliFark === 0 ? 'Kasa tutuyor' : canliFark < 0 ? 'Eksik' : 'Fazla'}
              </span>
              <span
                className={[
                  'text-lead font-semibold tnum',
                  canliFark === 0
                    ? 'text-success'
                    : canliFark < 0
                      ? 'text-danger'
                      : 'text-warn',
                ].join(' ')}
              >
                {canliFark > 0 ? '+' : ''}
                {formatTL(canliFark)}
              </span>
            </div>
          </div>
        )}

        <Input
          label="Not (isteğe bağlı)"
          value={notlar}
          onChange={(e) => setNotlar(e.target.value)}
          placeholder="Fark varsa sebebi"
          maxLength={300}
        />

        {/* Said before the tap, not only after it. A confirmation that
            explains what just happened is too late to be a choice. */}
        {!yonetici && (
          <p className="text-label text-faint">
            Sayımınız Yönetici onayına gönderilir; vardiya onaylandığında kapanır.
          </p>
        )}
      </FormModal>

      {/* ---- closed summary ------------------------------------------ */}
      <FormModal
        open={sonuc !== null}
        onOpenChange={() => setSonuc(null)}
        title={sonuc?.kapandi ? 'Vardiya kapandı' : 'Kapatma isteği gönderildi'}
        submitLabel="Tamam"
        onSubmit={() => setSonuc(null)}
      >
        {sonuc && (
          <div className="space-y-3">
            {/* The whole point of the request flow: the operator must leave
                this modal knowing the till is still OPEN. */}
            {!sonuc.kapandi && (
              <div className="rounded-field bg-warn-soft px-4 py-3">
                <p className="text-body text-warn">
                  Kapatma isteği yöneticiye gönderildi. Yönetici onayladığında
                  vardiya kapanacak.
                </p>
              </div>
            )}

            <Kalem k="Olması gereken" v={formatTL(sonuc.beklenen)} />
            <Kalem k="Sayılan" v={formatTL(sonuc.sayilan)} />
            <div className="border-t border-divider pt-3">
              <Kalem
                k="Fark"
                v={`${sonuc.fark > 0 ? '+' : ''}${formatTL(sonuc.fark)}`}
                vurgu={sonuc.fark !== 0}
              />
            </div>
            {sonuc.fark !== 0 && sonuc.kapandi && (
              <p className="text-label text-faint">Fark Yöneticiye bildirildi.</p>
            )}
          </div>
        )}
      </FormModal>
    </div>
  )
}

function Kova({ etiket, kurus, renk }: { etiket: string; kurus: number; renk: string }) {
  return (
    <div className="text-center">
      <p className={`text-body font-semibold tnum ${renk}`}>{formatTL(kurus, { decimals: 0 })}</p>
      <p className="mt-0.5 text-label text-faint">{etiket}</p>
    </div>
  )
}

function Kalem({ k, v, vurgu = false }: { k: string; v: string; vurgu?: boolean }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <span className="text-body text-faint">{k}</span>
      <span
        className={`tnum ${vurgu ? 'text-lead font-semibold text-danger' : 'text-body text-ink'}`}
      >
        {v}
      </span>
    </div>
  )
}

function FarkRozeti({ fark }: { fark: number | null }) {
  if (fark === null) return <span className="text-label text-faint">—</span>
  if (fark === 0) {
    return (
      <span className="rounded-chip bg-success-soft px-2.5 py-1 text-label font-medium text-success">
        Tutuyor
      </span>
    )
  }
  return (
    <span
      className={`rounded-chip px-2.5 py-1 text-label font-medium tnum ${
        fark < 0 ? 'bg-danger-soft text-danger' : 'bg-warn-soft text-warn'
      }`}
    >
      {fark > 0 ? '+' : ''}
      {formatTL(fark)}
    </span>
  )
}
