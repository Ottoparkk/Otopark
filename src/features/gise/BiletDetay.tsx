import { useState } from 'react'
import { useNavigate, useParams } from 'react-router'
import { Button, Card, DataPoint, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { YontemSecici } from '../../components/ui/YontemSecici'
import {
  useBilet,
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
  PlakaBasligi,
  useBiletAksiyonlari,
} from './components'
import { plakaGecerli } from '../../lib/plaka'
import { formatTL } from '../../lib/money'
import { sureMetni } from '../../lib/sure'
import { biletBorcu, gosterilenUcret, odemeAlindi, sureBitisi } from '../../lib/bilet'
import { rpcErrorText } from '../../lib/errors'
import { IconCop, IconKalem } from '../../components/ui/icons'
import { ODEME_DURUM_ETIKET, type Bilet, type OdemeYontemi } from '../../lib/types'

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
  const [degistirAcik, setDegistirAcik] = useState(false)
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

        <PlakaBasligi
          plaka={bilet.plaka}
          durum={bilet.durum}
          kapida={Boolean(bilet.cikis_bekliyor_at)}
        />

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
                {ODEME_DURUM_ETIKET.ALINMADI}
              </p>
              <p className="mt-1 text-body text-soft">
                Araç <strong className="font-semibold text-ink">{formatTL(borc)}</strong>{' '}
                borçlu çıktı. Parayı şimdi tahsil edebilirsiniz.
              </p>
            </div>

            <YontemSecici value={yontem} onChange={setYontem} />

            {tahsilHata && (
              <p role="alert" className="rounded-field bg-danger-soft px-3.5 py-3 text-body text-danger">
                {tahsilHata}
              </p>
            )}

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
                void tahsil
                  .mutateAsync({ bilet_id: bilet.id, odeme_yontemi: yontem })
                  .catch((e) =>
                    setTahsilHata(
                      rpcErrorText(e, 'Tahsilat kaydedilemedi. Tahsilat otomatik tekrarlanmaz.'),
                    ),
                  )
              }}
            >
              {formatTL(borc)} Tahsil Et
            </Button>
          </Card>
        )}

        <BiletDetayKarti
          bilet={bilet}
          yerKod={bilet.park_yeri_id ? (yerKodlari[bilet.park_yeri_id] ?? null) : null}
        />

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
            <IptalButonu onClick={aksiyon.iptalAc} size="lg" />
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
  const calisiyor = dogrula.isPending || duzelt.isPending
  const degisti = yeni !== bilet.plaka

  async function onayla() {
    if (calisiyor) return
    setHata(null)
    if (degisti && !plakaGecerli(yeni)) {
      setHata('Geçerli bir plaka girin.')
      return
    }
    try {
      if (degisti) await duzelt.mutateAsync({ bilet_id: bilet.id, plaka: yeni })
      else await dogrula.mutateAsync(bilet.id)
    } catch (e) {
      // The field keeps what was typed. The likeliest error is "another open
      // ticket already has this plate", and the sentence explains what next.
      setHata(rpcErrorText(e, degisti ? 'Plaka değiştirilemedi.' : 'Doğrulanamadı.'))
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
        onEnter={() => void onayla()}
      />
      <div className="flex gap-2">
        <Button className="flex-1" loading={calisiyor} onClick={() => void onayla()}>
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
    </PlakaKontrol>
  )
}
