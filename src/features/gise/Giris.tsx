import { useEffect, useMemo, useRef, useState } from 'react'
import { useNavigate } from 'react-router'
import { Button, FloatingBar, Select } from '../../components/ui/primitives'
import { PlakaInput } from '../../components/ui/PlakaInput'
import { PlakaKamera } from '../plaka/PlakaKamera'

import {
  BOS_EK_BILGI,
  FotoOnizleme,
  EkBilgiFormu,
  ekBilgiGonder,
  type EkBilgiler,
} from './components'
import {
  fotoYukle,
  useAbonmanKontrol,
  useAyarlar,
  useBiletAc,
  useParkYeriDurumu,
  usePuanDurumu,
  useBiletOkumaBagla,
} from './api'
import { ilkBosYer, yerSecenekEtiketi } from '../../lib/yerkodu'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../lib/plaka'
import { formatTarih } from '../../lib/dates'
import { formatTL } from '../../lib/money'
import { telGecerli } from '../../lib/telefon'
import { rpcErrorText } from '../../lib/errors'
import { IconUyari } from '../../components/ui/icons'

/**
 * The Giriş half of the Gişe page.
 *
 * `autoFocus` is a prop rather than a constant: the plate field should grab
 * the keyboard when an operator deliberately switches to Giriş, but NOT when
 * the app merely opens on the Gişe page — popping the keyboard over someone
 * who came to glance at the lot is the kind of small rudeness that makes an
 * app feel wrong to use all day.
 */
export function GirisBolumu({ autoFocus = false }: { autoFocus?: boolean }) {
  const navigate = useNavigate()
  const [plaka, setPlaka] = useState('')
  const [musteri, setMusteri] = useState<EkBilgiler>(BOS_EK_BILGI)
  const [telHata, setTelHata] = useState<string | null>(null)
  const [foto, setFoto] = useState<File | null>(null)
  const [fotoUrl, setFotoUrl] = useState<string | null>(null)
  const [ocrLogId, setOcrLogId] = useState<string | null>(null)

  /**
   * null means "follow the proposal", NOT "no bay" — '' is no bay.
   *
   * Stored as an override rather than seeded into state by an effect: the
   * proposal has to stay live (the bay it names can be taken by another
   * operator between two entries), and an effect that writes state from a
   * query would either fight the operator's choice or go stale the one time a
   * refetch happens to return an identical array.
   */
  const [yer, setYer] = useState<string | null>(null)

  const [hata, setHata] = useState<string | null>(null)
  const [uyari, setUyari] = useState<string | null>(null)


  /**
   * ONE idempotency key per form session, deliberately not per attempt.
   *
   * It survives retry-on-blip AND a double-tap: the server returns the
   * original ticket instead of opening a second one. Regenerating it on each
   * attempt would silently defeat the whole guard.
   */
  const islemIdRef = useRef<string>(crypto.randomUUID())

  const { data: ayarlar } = useAyarlar()
  const biletAc = useBiletAc()
  const okumaBagla = useBiletOkumaBagla()

  const normalize = normalizePlaka(plaka)
  const gecerli = plakaGecerli(normalize)

  /**
   * No error branch on purpose: if this call fails — migration 010 not run
   * yet, or a blip — the picker simply does not appear and entries carry on
   * without a bay. A gate screen may lose an optional field; it may never
   * lose the ticket.
   */
  const { data: yerler } = useParkYeriDurumu()
  const oneri = useMemo(() => ilkBosYer(yerler ?? []), [yerler])
  // The override wins while it names a bay that still exists; otherwise the
  // proposal does. Falling back matters because a bay can be retired between
  // the choice and the save, and a <select> whose value matches no option
  // shows one thing while sending another.
  const seciliYer = yer ?? oneri ?? ''
  const yerGecerli = (yerler ?? []).some((d) => d.id === seciliYer) ? seciliYer : ''
  const bosSayi = (yerler ?? []).filter((d) => !d.dolu_plaka).length

  const { data: abonman } = useAbonmanKontrol(normalize, gecerli)
  const { data: puan } = usePuanDurumu(normalize, gecerli && Boolean(ayarlar?.puan_aktif))

  // Object URLs leak if they are not revoked; a gate phone stays open all day.
  useEffect(() => {
    if (!foto) {
      setFotoUrl(null)
      return
    }
    const url = URL.createObjectURL(foto)
    setFotoUrl(url)
    return () => URL.revokeObjectURL(url)
  }, [foto])

  function sifirla() {
    setPlaka('')
    setMusteri(BOS_EK_BILGI)
    setTelHata(null)
    setFoto(null)
    setOcrLogId(null)
    // Back to the proposal, which by then is the NEXT free bay: the ticket
    // just saved has taken this one, and the save invalidates the list.
    setYer(null)
    islemIdRef.current = crypto.randomUUID()
  }

  async function kaydet() {
    setHata(null)
    setUyari(null)

    if (!gecerli) {
      setHata('Geçerli bir plaka girin.')
      return
    }

    // Checked here rather than by disabling the button. These fields are
    // optional, and a half-typed phone number must never be the reason a car
    // in the lot has no ticket — the operator sees exactly what is wrong and
    // can either finish the number or clear it and carry on.
    setTelHata(null)
    if (!telGecerli(musteri.tel)) {
      setTelHata('10 hane girin ya da alanı boş bırakın.')
      setHata('Müşteri numarasını düzeltin veya boş bırakın.')
      return
    }

    // The photo is evidence, not a precondition. A failed upload is REPORTED
    // and the ticket still opens — at a barrier the record of the car matters
    // more than the picture of it.
    let fotoPath: string | null = null
    if (foto) {
      const sonuc = await fotoYukle(foto, 'giris', normalize)
      fotoPath = sonuc.path
      if (sonuc.hata) setUyari(sonuc.hata)
    }

    try {
      const id = await biletAc.mutateAsync({
        plaka: normalize,
        islem_id: islemIdRef.current,
        foto: fotoPath,
        park_yeri_id: yerGecerli || null,
        ...ekBilgiGonder(musteri),
      })
      if (!id) {
        setHata('Kayıt oluşturulamadı. Tekrar deneyin.')
        return
      }
      // Fire-and-forget: the accuracy log must never block a ticket.
      // Records what was accepted AND flags a low-confidence read on the
      // ticket (029). Fire-and-forget: the accuracy log and the badge must
      // never stand between a car and its ticket.
      if (ocrLogId) okumaBagla.mutate({ bilet_id: id, log_id: ocrLogId, kabul: normalize })
      sifirla()
      // Back to the list, which is where the next thing an operator does
      // always is. The confirmation travels with the navigation rather than
      // being left behind on a screen nobody is looking at any more — the car
      // being in the list is proof it was saved, but the BAY it was given is
      // not visible there, and that is the part somebody has to be told.
      navigate('/gise', {
        state: {
          girisBasari: {
            plaka: formatPlaka(normalize),
            yerKod: (yerler ?? []).find((d) => d.id === yerGecerli)?.kod ?? null,
          },
        },
      })
    } catch (err) {
      setHata(
        rpcErrorText(
          err,
          'Giriş kaydedilemedi. Bağlantınızı kontrol edip tekrar deneyin; sorun sürerse plakayı kâğıda not edin.',
        ),
      )
    }
  }

  return (
    <div className="flex flex-1 flex-col">
      <div className="flex-1 space-y-5 px-5">
        {/* No label: a giant tracked uppercase field with a plate-shaped
            placeholder already says what it is. */}
        <PlakaInput
          value={plaka}
          onChange={setPlaka}
          hideLabel
          autoFocus={autoFocus}
          onEnter={() => void kaydet()}
        />

        {/* Knowing this BEFORE the ticket opens is the point — the operator
            should not wave a subscriber through wondering if it was free. */}
        {abonman?.gecerli && (
          <p className="rounded-card bg-success-soft px-4 py-3 text-body text-success">
            <strong className="font-semibold">Abonman geçerli</strong>
            {abonman.musteri_ad ? ` · ${abonman.musteri_ad}` : ''}
            {abonman.bitis_tarihi ? ` · ${formatTarih(abonman.bitis_tarihi)} tarihine kadar` : ''}
            <span className="mt-0.5 block text-label opacity-80">Bu araç ücretsiz girer.</span>
          </p>
        )}

        {puan?.hesap_var && !abonman?.gecerli && (
          <p className="rounded-card bg-accent-soft px-4 py-3 text-body text-accent">
            <strong className="font-semibold">{puan.hesap_adi}</strong> · {puan.bakiye} puan
            {puan.karsiligi_kurus > 0 && ` (${formatTL(puan.karsiligi_kurus)})`}
          </p>
        )}

        {/* The bay, between the plate and the camera: it is part of deciding
            what this entry IS, while the camera and the customer fields are
            things added to it. Pre-set to the first free ordinary bay — the
            same one bos_park_yeri() would give a camera entry — so the fast
            path stays plate → Kaydet and the operator only touches this when
            the car goes somewhere else.

            Occupied bays stay in the list, disabled and showing the plate on
            them. A bay that simply vanished would read as a bug; this answers
            "why can't I pick P-03" without anyone having to ask. */}
        {(yerler?.length ?? 0) > 0 && (
          <Select
            label="Park yeri"
            value={yerGecerli}
            onChange={(e) => setYer(e.target.value)}
            hint={bosSayi > 0 ? `${bosSayi} yer boş` : 'Boş yer kalmadı'}
          >
            <option value="">Yer atanmadı</option>
            {(yerler ?? []).map((d) => (
              <option key={d.id} value={d.id} disabled={Boolean(d.dolu_plaka)}>
                {yerSecenekEtiketi(d)}
              </option>
            ))}
          </Select>
        )}

        <PlakaKamera
          aktif={(ayarlar?.plaka_saglayici ?? 'KAPALI') !== 'KAPALI'}
          onFoto={setFoto}
          onPlaka={(p, logId) => {
            // Empty means the read was suppressed: keep the log id, but never
            // wipe a plate the operator had already typed.
            if (p) setPlaka(p)
            setOcrLogId(logId)
          }}
        />

        {fotoUrl && <FotoOnizleme url={fotoUrl} onKaldir={() => setFoto(null)} />}

        {/* Optional, and placed after the plate and the camera on purpose: the
            fast path is plate → Girişi Kaydet, and "Girişi Kaydet" lives in the
            floating bar, so nothing here can push the primary action off
            screen. Editable again at Tahsilat while the car is inside. */}
        <section>
          <h3 className="mb-3 flex items-baseline gap-2 text-body font-semibold text-ink">
            Müşteri ve not
            <span className="text-label font-normal text-faint">(isteğe bağlı)</span>
          </h3>
          <EkBilgiFormu deger={musteri} onChange={setMusteri} telHatasi={telHata} />
        </section>

        {uyari && (
          <p className="flex items-start gap-2 rounded-card bg-warn-soft px-4 py-3 text-body text-warn">
            <IconUyari size={18} className="mt-0.5 shrink-0" />
            {uyari}
          </p>
        )}

        {hata && (
          <p
            role="alert"
            className="rounded-card bg-danger-soft px-4 py-3 text-body text-danger"
          >
            {hata}
          </p>
        )}
      </div>

      <FloatingBar>
        <Button
          size="lg"
          block
          loading={biletAc.isPending}
          disabled={!gecerli}
          onClick={() => void kaydet()}
        >
          {biletAc.isPending ? 'Kaydediliyor…' : 'Girişi Kaydet'}
        </Button>
      </FloatingBar>
    </div>
  )
}
