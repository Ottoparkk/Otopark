import { useState } from 'react'
import { useNavigate, useParams } from 'react-router'
import { Button, Card, DataPoint, Input, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { YontemSecici } from '../../components/ui/YontemSecici'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import {
  useBilet,
  useBiletTahsilatlari,
  useBiletCikisGeriAl,
  useBiletGeriAc,
  useBiletPlakaDogrula,
  useBiletPlakaDuzelt,
  useBiletTahsil,
  useFotoUrl,
  useUcretOnizleme,
  useYerKodlari,
} from './api'
import { PlakaInput } from '../../components/ui/PlakaInput'
import { PlakaKontrol } from '../../components/ui/PlakaKontrol'
import {
  BiletDegistirModal,
  BiletDetayKarti,
  BiletFoto,
  IptalButonu,
  IptalTalebiNotu,
  PlakaBasligi,
  useBiletAksiyonlari,
} from './components'
import { formatPlaka, plakaGecerli } from '../../lib/plaka'
import { formatTL } from '../../lib/money'
import { sureMetni } from '../../lib/sure'
import { biletBorcu, cikisGeriAlma, gosterilenUcret, odemeAlindi, sureBitisi } from '../../lib/bilet'
import { rpcErrorText } from '../../lib/errors'
import { IconCop, IconKalem } from '../../components/ui/icons'
import { ODEME_CHIP, ODEME_ETIKET, ONAY_ETIKET, type Bilet, type OdemeYontemi } from '../../lib/types'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'
import { useAdlar } from '../yonetim/api'
import { useSonKararlar } from '../finans/api'
import { adCoz, tahsilatKisileri, type KimSatiri } from '../../lib/kimYapti'
import { KimSatirlari } from '../../components/ui/KimSatirlari'
import { formatTam } from '../../lib/dates'

/**
 * Full history of one ticket. Reached from the vehicles list, Finans and
 * Çözülmemiş kayıtlar (the last one opens it for a car still INSIDE).
 *
 * Same order as Tahsilat (owner, 2026-11-02): photo → plate → fee + stay →
 * ticket facts │ müşteri → Değiştir → İptal.
 */
export default function BiletDetay() {
  const { id } = useParams()
  const navigate = useNavigate()
  const { data: bilet, isPending, error, refetch } = useBilet(id)
  const yerKodlari = useYerKodlari()

  // Every hook runs on every render, so they all sit above the early returns
  // and simply get `undefined` while the ticket is loading.
  const aksiyon = useBiletAksiyonlari(bilet, { onSilindi: () => navigate('/gise') })
  const tahsil = useBiletTahsil()
  const [yontem, setYontem] = useState<OdemeYontemi | null>('NAKIT')
  const [tahsilHata, setTahsilHata] = useState<string | null>(null)
  const [tahsilOnay, setTahsilOnay] = useState(false)
  const [degistirAcik, setDegistirAcik] = useState(false)
  const geriAc = useBiletGeriAc()
  const [geriAcOnay, setGeriAcOnay] = useState(false)
  const [geriAcHata, setGeriAcHata] = useState<string | null>(null)
  // 060: the same "Araç çıkmadı" for any other closed ticket — with a reason,
  // and any payment reversed.
  const geriAl = useBiletCikisGeriAl()
  const [geriAlOnay, setGeriAlOnay] = useState(false)
  const [geriAlSebep, setGeriAlSebep] = useState('')
  const [geriAlSebepHata, setGeriAlSebepHata] = useState<string | null>(null)
  const [geriAlHata, setGeriAlHata] = useState<string | null>(null)
  // An open ticket's stored fee is 0 until exit; the live price is the
  // server's, the same one Tahsilat shows. Not fetched for a closed ticket.
  const { data: canliUcret } = useUcretOnizleme(bilet?.durum === 'ACIK' ? bilet : null)

  if (isPending) {
    return (
      <div className="py-20">
        <Spinner label="Bilet yükleniyor" />
      </div>
    )
  }
  if (error || !bilet) {
    return (
      <div className="px-5 pt-4">
        <ScreenHeader title="Bilet" back />
        <LoadError error={error} onRetry={() => void refetch()} />
      </div>
    )
  }

  const acik = bilet.durum === 'ACIK'
  const ucret = gosterilenUcret(bilet, canliUcret)
  const borc = biletBorcu(bilet)
  const odenmedi = bilet.durum === 'KAPALI' && borc > 0 && !odemeAlindi(bilet)
  const kameraKapatti = bilet.durum === 'KAPALI' && bilet.cikis_kaynak === 'KAMERA'
  const geriAlma = cikisGeriAlma(bilet)

  return (
    <div>
      {/* Delete sits in the header, where the app puts "remove this record"
          everywhere else, and deliberately NOT beside İptal at the bottom:
          cancelling reverses the money and keeps the history, deleting takes
          the record away, and a mis-tap between the two is not a mistake
          worth making easy. */}
      <ScreenHeader
        title="Bilet"
        back
        right={
          aksiyon.silinebilir ? (
            <button
              type="button"
              onClick={aksiyon.silAc}
              // Labelled and red. A lone grey bin in a header is the one
              // control here that destroys a record, and it read as the
              // quietest thing on the screen.
              className="flex min-h-[44px] shrink-0 items-center gap-1.5 rounded-chip px-3 text-body font-medium text-danger active:bg-danger-soft"
            >
              <IconCop size={18} />
              Sil
            </button>
          ) : undefined
        }
      />

      <div className="space-y-4 px-5 pb-6">
        <BiletFoto bilet={bilet} />

        <PlakaBasligi plaka={bilet.plaka} durum={bilet.durum} />

        {acik && bilet.iptal_talebi_at && <IptalTalebiNotu sebep={bilet.iptal_talebi_sebep} />}

        {/* Right under the plate on purpose: if this plate is wrong, nothing
            below it matters — the car cannot be found at exit. Only while the
            ticket is open, which is the window where the correction is still
            cheap. */}
        {acik && bilet.plaka_supheli && <PlakaSuphesi bilet={bilet} />}

        {/* The FEE, not what was collected: since 027 a closed ticket can owe
            money, and showing ₺0 on a debt would read as "nothing to pay".
            They are the same number on a paid ticket. */}
        <Card className="grid grid-cols-2 gap-4">
          <DataPoint
            size="lg"
            value={<span className="tnum">{ucret === null ? '—' : formatTL(ucret)}</span>}
            caption={acik ? 'Ücret (şu ana kadar)' : 'Ücret'}
          />
          <DataPoint
            size="lg"
            align="right"
            value={<span className="tnum">{sureMetni(bilet.giris_at, sureBitisi(bilet))}</span>}
            caption="Süre"
          />
        </Card>

        {/* The other half of "Çıkış Ver": the car has gone, the money has
            not. Only ever shown on a closed ticket that owes something —
            never on an open one, which is collected at the gate. Beside the
            fee, because it is about the fee. */}
        {odenmedi && (
          <Card className="space-y-4">
            <div>
              <p className="text-label font-medium tracking-wide text-warn uppercase">
                Ödeme topla
              </p>
              <p className="mt-1 text-body text-soft">
                {kameraKapatti ? 'Kamera aracın çıkışını gördü. ' : 'Araç borçlu çıktı. '}
                <strong className="font-semibold text-ink">{formatTL(borc)}</strong> ödeme
                bekliyor. Toplanan ödeme Yönetici onayına gider.
              </p>
            </div>

            <YontemSecici value={yontem} onChange={setYontem} />

            {tahsilHata && !tahsilOnay && (
              <p role="alert" className="rounded-field bg-danger-soft px-3.5 py-3 text-body text-danger">
                {tahsilHata}
              </p>
            )}

            {/* Only ASKS (owner, 2026-11-14): the payment is recorded from the
                box below, after the amount and method are read back. */}
            <Button
              size="lg"
              block
              loading={tahsil.isPending}
              onClick={() => {
                setTahsilHata(null)
                if (!yontem) {
                  setTahsilHata('Ödeme yöntemi seçin.')
                  return
                }
                setTahsilOnay(true)
              }}
            >
              {formatTL(borc)} Ödeme topla
            </Button>
          </Card>
        )}

        {/* The car never actually left — put it back inside with its first
            entry time. 054: the camera closed it and no money was taken (it
            waited at the gate) → today's box, no reason. 060 (owner,
            2026-11-15): any other closed ticket — the exit was given to the
            wrong car, or the debt was already collected → the box asks a
            reason and reverses the payment. The server checks everything
            again (own shift, no second open ticket for this plate). */}
        {geriAlma && (
          <Button
            variant="soft"
            block
            onClick={() => {
              if (geriAlma === 'KAMERA') {
                setGeriAcHata(null)
                setGeriAcOnay(true)
                return
              }
              setGeriAlSebep('')
              setGeriAlSebepHata(null)
              setGeriAlHata(null)
              setGeriAlOnay(true)
            }}
          >
            Araç çıkmadı
          </Button>
        )}

        <BiletDetayKarti
          bilet={bilet}
          yerKod={bilet.park_yeri_id ? (yerKodlari[bilet.park_yeri_id] ?? null) : null}
        />

        <BiletKimKarti bilet={bilet} />

        {/* Only while the car is inside: after exit the money is in a shift,
            and the way to undo it is İptal below (owner, 2026-11-02). */}
        {acik && (
          <Button variant="soft" block onClick={() => setDegistirAcik(true)}>
            <IconKalem size={18} />
            Değiştir
          </Button>
        )}

        {/* Not on a ticket that is already cancelled — the server would only
            refuse it. */}
        {bilet.durum !== 'IPTAL' && (
          <div className="border-t border-divider pt-4">
            <IptalButonu
              onClick={aksiyon.iptalAc}
              size="lg"
              etiket={aksiyon.iptalEtiketi}
              disabled={aksiyon.iptalKapali}
            />
          </div>
        )}
      </div>

      {acik && (
        <BiletDegistirModal
          open={degistirAcik}
          onOpenChange={setDegistirAcik}
          bilet={bilet}
          // The fee of an open ticket is set at exit — that is where the
          // override is applied (bilet_kapat). A subscriber has no fee.
          ucret={null}
          ucretNotu={
            bilet.abonman_id ? undefined : 'Ücret, çıkışta Tahsilat ekranında değiştirilir.'
          }
        />
      )}

      {aksiyon.dialoglar}

      {/* "Ödeme topla", read back before it is recorded. Stays open on a
          refusal (already paid, another shift) so the reason is read here. */}
      <ConfirmDialog
        open={tahsilOnay}
        onOpenChange={setTahsilOnay}
        title="Ödeme toplansın mı?"
        description={
          <>
            <span className="block text-title font-semibold tracking-wide text-ink tnum">
              {formatPlaka(bilet.plaka)}
            </span>
            <span className="mt-1 block">
              <strong className="font-semibold text-ink tnum">{formatTL(borc)}</strong>
              {yontem ? ` · ${ODEME_ETIKET[yontem]}` : ''}. Ödeme Yönetici onayına gider.
            </span>
          </>
        }
        confirmLabel={`${formatTL(borc)} Ödeme topla`}
        loading={tahsil.isPending}
        error={tahsilHata}
        onConfirm={() => {
          if (tahsil.isPending || !yontem) return
          setTahsilHata(null)
          tahsil
            .mutateAsync({ bilet_id: bilet.id, odeme_yontemi: yontem })
            .then(() => setTahsilOnay(false))
            .catch((e) =>
              setTahsilHata(
                rpcErrorText(e, 'Tahsilat kaydedilemedi. Tahsilat otomatik tekrarlanmaz.'),
              ),
            )
        }}
      />

      {/* Stays open on a refusal, so the server's Turkish reason (another
          open ticket for this plate, another shift, already paid) is read
          beside the button that failed. */}
      <ConfirmDialog
        open={geriAcOnay}
        onOpenChange={setGeriAcOnay}
        title="Araç çıkmadı mı?"
        description={`${formatPlaka(bilet.plaka)} yeniden içeride görünecek. Bilet açılır; ücret çıkışta hesaplanır. Yönetici bilgilendirilir.`}
        confirmLabel="Bileti geri aç"
        loading={geriAc.isPending}
        error={geriAcHata}
        onConfirm={() => {
          setGeriAcHata(null)
          geriAc.mutate(bilet.id, {
            onSuccess: () => setGeriAcOnay(false),
            onError: (e) => setGeriAcHata(rpcErrorText(e, 'Bilet geri açılamadı.')),
          })
        }}
      />

      {/* 060: the reason goes to the audit log and the Yönetici. A taken
          payment is read back, because it is reversed. Stays open on a
          refusal (another open ticket for this plate, another shift). */}
      <ConfirmDialog
        open={geriAlOnay}
        onOpenChange={setGeriAlOnay}
        title="Araç çıkmadı mı?"
        description={
          <>
            <span className="block text-title font-semibold tracking-wide text-ink tnum">
              {formatPlaka(bilet.plaka)}
            </span>
            {odemeAlindi(bilet) && (
              <span className="mt-1 block font-semibold text-warn tnum">
                {formatTL(bilet.tahsil_kurus)}
                {bilet.odeme_yontemi ? ` · ${ODEME_ETIKET[bilet.odeme_yontemi]}` : ''} ödemesi geri
                alınır.
              </span>
            )}
            <span className="mt-1 block">
              Bilet yeniden açılır; ücret çıkışta hesaplanır. Yönetici bilgilendirilir.
            </span>
          </>
        }
        confirmLabel="Bileti geri aç"
        loading={geriAl.isPending}
        error={geriAlHata}
        onConfirm={() => {
          if (geriAl.isPending) return
          const sebep = geriAlSebep.trim()
          if (!sebep) {
            setGeriAlSebepHata('Sebep yazın — denetim kaydına geçer.')
            return
          }
          setGeriAlHata(null)
          geriAl.mutate(
            { bilet_id: bilet.id, sebep },
            {
              onSuccess: () => setGeriAlOnay(false),
              onError: (e) => setGeriAlHata(rpcErrorText(e, 'Bilet geri açılamadı.')),
            },
          )
        }}
      >
        <Input
          label="Sebep"
          maxLength={200}
          placeholder="Yanlış araca çıkış verildi"
          value={geriAlSebep}
          error={geriAlSebepHata}
          onChange={(e) => {
            setGeriAlSebep(e.target.value)
            setGeriAlSebepHata(null)
          }}
        />
      </ConfirmDialog>
    </div>
  )
}

/**
 * "Plaka yanlış olabilir" — the read that produced this plate scored below
 * `plaka_supheli_esigi` and the operator accepted it unchanged (029).
 *
 * Compact (2026-10-31): the entry photo, one line, and the plate already in
 * an editable field. ONE button that follows the field — unchanged → "Doğru"
 * (bilet_plaka_dogrula), edited → "Kaydet" (bilet_plaka_duzelt); both clear
 * the flag server-side (029), so the card leaves on either.
 *
 * Still deliberately no dismiss that skips the check: "Doğru" IS the dismiss,
 * and it is a decision. A badge that can be waved away without one is a badge
 * everybody waves away, and the entire value here is catching a wrong plate
 * BEFORE the car tries to leave — after that it is a dispute with a queue
 * forming behind it.
 */
function PlakaSuphesi({ bilet }: { bilet: Bilet }) {
  const dogrula = useBiletPlakaDogrula()
  const duzelt = useBiletPlakaDuzelt()
  const { data: fotoUrl } = useFotoUrl(bilet.giris_foto)
  const [yeni, setYeni] = useState(bilet.plaka)
  const [hata, setHata] = useState<string | null>(null)
  // The plate AS IT WAS when the box opened — what the box reads back and
  // what is sent. The field behind the box must not be able to change it.
  const [onayPlaka, setOnayPlaka] = useState<string | null>(null)
  const [onayHata, setOnayHata] = useState<string | null>(null)
  const calisiyor = dogrula.isPending || duzelt.isPending
  const degisti = yeni !== bilet.plaka
  const onayDegisti = onayPlaka !== null && onayPlaka !== bilet.plaka

  /** The button (and Enter) only ASKS (owner, 2026-11-14); the box acts. */
  function sor() {
    if (calisiyor) return
    setHata(null)
    if (degisti && !plakaGecerli(yeni)) {
      setHata('Geçerli bir plaka girin.')
      return
    }
    setOnayHata(null)
    // Off the field (Enter leaves it focused): on a phone this also drops the
    // keyboard that would cover the box's buttons.
    ;(document.activeElement as HTMLElement | null)?.blur()
    setOnayPlaka(yeni)
  }

  async function onayla() {
    if (calisiyor || onayPlaka === null) return
    setOnayHata(null)
    try {
      if (onayDegisti) await duzelt.mutateAsync({ bilet_id: bilet.id, plaka: onayPlaka })
      else await dogrula.mutateAsync(bilet.id)
      setOnayPlaka(null)
    } catch (e) {
      // The field keeps what was typed. The likeliest error is "another open
      // ticket already has this plate", and the sentence explains what next.
      setOnayHata(rpcErrorText(e, onayDegisti ? 'Plaka değiştirilemedi.' : 'Doğrulanamadı.'))
    }
  }

  return (
    <PlakaKontrol fotoUrl={fotoUrl} durum="Plaka tam olarak okunamadı — kontrol edin">
      <PlakaInput
        value={yeni}
        onChange={(v) => {
          setYeni(v)
          setHata(null)
        }}
        hideLabel
        placeholder="Plakayı yazın"
        error={hata}
        onEnter={sor}
      />
      <div className="flex gap-2">
        <Button className="flex-1" loading={calisiyor} onClick={sor}>
          {degisti ? 'Kaydet' : 'Doğru'}
        </Button>
        {degisti && (
          <Button
            variant="ghost"
            disabled={calisiyor}
            onClick={() => {
              setYeni(bilet.plaka)
              setHata(null)
            }}
          >
            Geri al
          </Button>
        )}
      </div>

      <ConfirmDialog
        open={onayPlaka !== null}
        onOpenChange={(o) => {
          if (!o) setOnayPlaka(null)
        }}
        title={onayDegisti ? 'Plaka değiştirilsin mi?' : 'Plaka doğru mu?'}
        description={
          onayDegisti ? (
            <span className="block text-title font-semibold tracking-wide text-ink tnum">
              {formatPlaka(bilet.plaka)} → {formatPlaka(onayPlaka ?? yeni)}
            </span>
          ) : (
            <>
              <span className="block text-title font-semibold tracking-wide text-ink tnum">
                {formatPlaka(bilet.plaka)}
              </span>
              <span className="mt-1 block">Fotoğraftaki plakayla aynı.</span>
            </>
          )
        }
        confirmLabel={onayDegisti ? 'Kaydet' : 'Doğru'}
        loading={calisiyor}
        error={onayHata}
        onConfirm={() => void onayla()}
      />
    </PlakaKontrol>
  )
}

const IPTAL_KARARI = ['bilet_iptal_onay']

/**
 * Who did what with this ticket's money (063, owner 2026-11-15): each
 * payment's collector and approver, and for a cancelled ticket who asked and
 * who cancelled. Yönetici only — Personel see nothing here (owner's choice),
 * and the queries do not even run for them.
 */
function BiletKimKarti({ bilet }: { bilet: Bilet }) {
  const { profile } = useAuth()
  const yonetici = isYonetici(profile)
  const adlar = useAdlar()
  const iptal = bilet.durum === 'IPTAL'
  const { data: tahsilatlar = [] } = useBiletTahsilatlari(bilet.id, yonetici)
  // The requester is cleared from the ticket on approval (050); it survives
  // only in the decision's audit row.
  const { data: kararlar } = useSonKararlar(IPTAL_KARARI, [bilet.id], yonetici && iptal)
  if (!yonetici) return null

  const isteyen = adCoz(kararlar?.get(bilet.id)?.talep_eden, adlar)
  const iptalEden = adCoz(bilet.iptal_by, adlar)
  const iptalSatirlari: (KimSatiri | null)[] = iptal
    ? [
        isteyen ? { etiket: 'İptal isteyen', ad: isteyen, zaman: null } : null,
        iptalEden ? { etiket: 'İptal eden', ad: iptalEden, zaman: bilet.iptal_at } : null,
      ]
    : []
  if (tahsilatlar.length === 0 && !iptalSatirlari.some(Boolean)) return null

  return (
    <section>
      <h2 className="mb-2 text-label font-medium tracking-wide text-faint uppercase">
        Kim yaptı
      </h2>
      <div className="space-y-2">
        {tahsilatlar.map((t) => (
          <Card key={t.id} className="flex items-start justify-between gap-3">
            <div className="min-w-0">
              <p className="text-body font-medium text-ink tnum">{formatTL(t.tutar_kurus)}</p>
              <p className="mt-0.5 text-label text-faint tnum">
                {formatTam(t.created_at)}
                {t.durum ? ` · ${ONAY_ETIKET[t.durum]}` : ''}
              </p>
              <KimSatirlari
                className="mt-1"
                satirlar={tahsilatKisileri({
                  tutar_kurus: t.tutar_kurus,
                  iptal_of: t.iptal_of,
                  durum: t.durum,
                  toplayan: adCoz(t.created_by, adlar),
                  onaylayan: adCoz(t.onaylayan, adlar),
                  onay_at: t.onay_at,
                })}
              />
            </div>
            <span
              className={`shrink-0 rounded-chip px-2.5 py-1 text-label font-medium ${ODEME_CHIP[t.yontem]}`}
            >
              {ODEME_ETIKET[t.yontem]}
            </span>
          </Card>
        ))}
        {iptalSatirlari.some(Boolean) && (
          <Card>
            <p className="text-body font-medium text-danger">İptal</p>
            <KimSatirlari className="mt-1" satirlar={iptalSatirlari} />
          </Card>
        )}
      </div>
    </section>
  )
}
