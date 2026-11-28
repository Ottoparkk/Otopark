import { useState } from 'react'
import { flushSync } from 'react-dom'
import { AltSayfa } from '../../components/ui/AltSayfa'
import { Button } from '../../components/ui/primitives'
import { IconAsagi, IconTik } from '../../components/ui/icons'
import { Spinner } from '../../components/ui/Spinner'
import { formatTL } from '../../lib/money'
import { formatSaat, formatTam } from '../../lib/dates'
import { ucretsizEtiket } from '../../lib/ucretsiz'
import { rpcErrorText } from '../../lib/errors'
import { formatPlaka } from '../../lib/plaka'
import { useAyarlar, useBilet } from '../gise/api'
import { useBiletTarifesi, useFisBasildi, useFisBasimlari, useFisTahmini, type FisTur } from './api'
import { cikisFisi, girisFisi, sureMetni, type FisAraclari, type FisSatiri } from './fisIcerik'
import { fisTahminSecenekleri } from './fisSecenek'
import { kademeAraliklari } from '../finans/kademe'
import { FisBaskiPortal, FisKagidi } from './FisBaski'

const ARACLAR: FisAraclari = { tl: formatTL, saat: formatSaat, tam: formatTam, ucretsizEtiket, plaka: formatPlaka }

/**
 * Preview, then print (088). "Yazdır" first records the print on the server
 * (`fis_basildi`) — which refuses an exit fiş while money is owed or the 082
 * over-time decision is pending, in its own words shown here — and only then
 * opens Chrome's print screen with the numbered copy (1st, "TEKRAR BASIM (2)"…).
 * The entry fiş can carry the customer's stated stay, priced by the server.
 */
export function FisSayfasi({
  biletId,
  tur,
  open,
  onOpenChange,
}: {
  biletId: string
  tur: FisTur
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const { data: bilet } = useBilet(open ? biletId : undefined)
  const { data: ayar } = useAyarlar()
  const giris = tur === 'GIRIS'
  const tahminli = giris && bilet?.durum === 'ACIK' && !bilet.abonman_id
  const { data: basimlar } = useFisBasimlari(biletId, open)
  // Owner 28.11: the choices are the ticket's own tariff bands (0–2, 2–4…).
  const { data: tarife } = useBiletTarifesi(open && tahminli ? bilet?.tarife_id : undefined)
  const secenekler = fisTahminSecenekleri(tarife, { araliklar: kademeAraliklari, sure: sureMetni })
  const { data: tahminler } = useFisTahmini(
    biletId,
    secenekler.map((s) => s.dakika),
    open && tahminli,
  )
  const basildi = useFisBasildi()

  const [tahminDk, setTahminDk] = useState<number | null>(null)
  // One opener (owner 28.11): the stay is one row; tapping it opens the list.
  const [secimAcik, setSecimAcik] = useState(false)
  const [basim, setBasim] = useState<number | null>(null)
  const [hata, setHata] = useState<string | null>(null)

  function kapat(o: boolean) {
    if (!o) {
      setBasim(null)
      setHata(null)
      setTahminDk(null)
      setSecimAcik(false)
    }
    onOpenChange(o)
  }

  const onceki = basimlar?.filter((b) => b.tur === tur).length ?? 0
  const sira = basim ?? onceki + 1
  const tahminKurus = tahminDk === null ? undefined : tahminler?.get(tahminDk)

  let satirlar: FisSatiri[] | null = null
  let icerikHatasi: string | null = null
  if (bilet && ayar) {
    const basimAt = new Date().toISOString()
    try {
      satirlar = giris
        ? girisFisi(
            {
              otopark: ayar,
              bilet,
              basim: sira,
              basimAt,
              tahmin: tahminDk !== null && tahminKurus !== undefined ? { dakika: tahminDk, kurus: tahminKurus } : null,
            },
            ARACLAR,
          )
        : cikisFisi({ otopark: ayar, bilet, basim: sira, basimAt }, ARACLAR)
    } catch (e) {
      icerikHatasi = (e as Error).message
    }
  }

  async function yazdir() {
    setHata(null)
    try {
      const n = await basildi.mutateAsync({ biletId, tur, tahminDk: giris ? tahminDk : null })
      // The paper copy must carry the server's number before Chrome snapshots it.
      flushSync(() => setBasim(n))
      window.print()
    } catch (e) {
      setHata(rpcErrorText(e, 'Fiş kaydedilemedi.'))
    }
  }

  return (
    <AltSayfa
      open={open}
      onOpenChange={kapat}
      baslik={giris ? 'Giriş fişi' : 'Çıkış fişi'}
      aciklama="Fişin önizlemesi ve yazdırma."
    >
      {!satirlar && !icerikHatasi ? (
        <div className="py-10">
          <Spinner label="Fiş hazırlanıyor" />
        </div>
      ) : (
        <div className="space-y-4">
          {tahminli && (
            <div className="overflow-hidden rounded-card border border-border bg-surface">
              <button
                type="button"
                aria-expanded={secimAcik}
                onClick={() => setSecimAcik((v) => !v)}
                className="flex min-h-[52px] w-full items-center gap-3 px-4 text-left active:bg-field"
              >
                <span className="flex-1 text-body text-soft">Müşteri ne kadar kalacak?</span>
                <span className="text-body font-semibold text-ink tnum">
                  {tahminDk === null
                    ? 'Belirsiz'
                    : (secenekler.find((s) => s.dakika === tahminDk)?.etiket ?? sureMetni(tahminDk))}
                </span>
                <IconAsagi
                  size={18}
                  className={`shrink-0 text-faint transition-transform ${secimAcik ? 'rotate-180' : ''}`}
                />
              </button>
              {secimAcik && (
                <ul className="divide-y divide-divider border-t border-divider">
                  {[null, ...secenekler].map((s) => {
                    const dk = s?.dakika ?? null
                    const secili = tahminDk === dk
                    const kurus = dk === null ? undefined : tahminler?.get(dk)
                    return (
                      <li key={dk ?? 'belirsiz'}>
                        <button
                          type="button"
                          aria-pressed={secili}
                          onClick={() => {
                            setTahminDk(dk)
                            setSecimAcik(false)
                          }}
                          className="flex min-h-[48px] w-full items-center gap-3 px-4 text-left active:bg-field"
                        >
                          <span className={`flex-1 text-body ${secili ? 'font-semibold text-ink' : 'text-soft'}`}>
                            {s === null ? 'Belirsiz' : s.etiket}
                          </span>
                          {kurus !== undefined && (
                            <span className="text-body text-faint tnum">{formatTL(kurus)}</span>
                          )}
                          <span className="flex w-5 shrink-0 justify-center text-accent">
                            {secili && <IconTik size={18} />}
                          </span>
                        </button>
                      </li>
                    )
                  })}
                </ul>
              )}
              {tahminDk !== null && tahminKurus === undefined && (
                <p className="border-t border-divider px-4 py-2 text-label text-faint">Tahmin hesaplanıyor…</p>
              )}
            </div>
          )}

          {satirlar && (
            <div className="mx-auto w-full max-w-[280px] rounded-field border border-border bg-surface px-4 py-3 shadow-card">
              <FisKagidi satirlar={satirlar} />
            </div>
          )}

          {(hata || icerikHatasi) && (
            <p role="alert" className="rounded-card bg-danger-soft px-4 py-3 text-body text-danger">
              {hata || icerikHatasi}
            </p>
          )}
          {basim !== null && !hata && (
            <p role="status" className="text-center text-label text-success">
              {basim === 1 ? 'Fiş yazdırıldı.' : `Yazdırıldı (${basim}. basım).`}
            </p>
          )}

          <Button
            size="lg"
            block
            loading={basildi.isPending}
            disabled={!satirlar || (tahminDk !== null && tahminKurus === undefined)}
            onClick={() => void yazdir()}
          >
            {basim === null ? 'Yazdır' : 'Tekrar yazdır'}
          </Button>
        </div>
      )}
      {open && satirlar && <FisBaskiPortal satirlar={satirlar} />}
    </AltSayfa>
  )
}
