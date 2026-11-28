import { useEffect, useId, useState, type ReactNode } from 'react'
import { useNavigate } from 'react-router'
import {
  Button,
  Card,
  Chip,
  IconTile,
  Input,
  Label,
  OranCubugu,
  SegmentedControl,
} from '../../components/ui/primitives'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { FormModal } from '../../components/ui/FormModal'
import { FotoGoruntuleyici } from '../../components/ui/FotoGoruntuleyici'
import { PlakaInput } from '../../components/ui/PlakaInput'
import {
  useBiletGirisDuzelt,
  useBiletIptal,
  useBiletMusteriGuncelle,
  useBiletPlakaDuzelt,
  useAnlasmaFazla,
  useAsimKarar,
  useAsimOnizleme,
  useBiletAnlasma,
  useBiletYikama,
  useFazlaOnizleme,
  useFotoUrl,
} from './api'
import { useBiletSil } from '../cop/api'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'
import { formatTam } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { formatPlaka, normalizePlaka, plakaGecerli } from '../../lib/plaka'
import { formatTel, normalizeTel, telGonderilebilir } from '../../lib/telefon'
import { formatGoreceli } from '../../lib/dates'
import { digitsOnly, formatTL, kurusToInput, parseTLToKurus } from '../../lib/money'
import {
  degisiklikler,
  degistirBaslangic,
  type DegistirAlan,
  type DegistirAraclari,
  type DegistirTaslak,
} from './degistir'
import { formatSure, sureMetni } from '../../lib/sure'
import {
  anlasmaBitis,
  anlasmaBittiUyarisi,
  anlasmaDurumu,
  anlasmaSaat,
  anlasmaSaatGecerli,
  bitisMetni,
  kalanMetni,
  type AnlasmaBirim,
} from './anlasma'
import { biletBorcu, odemeAlindi, uzunKalan } from '../../lib/bilet'
import { asimDurumu, asimKararMetni, type AsimDurumu, type AsimOnizleme } from './asim'
import {
  ODEME_CHIP,
  ODEME_DURUM_ETIKET,
  ODEME_ETIKET,
  ONAY_CHIP,
  ONAY_ETIKET,
  type AcikBilet,
  type Bilet,
  type Kaynak,
  type OnayDurum,
} from '../../lib/types'
import {
  IconAraba,
  IconCikis,
  IconIleri,
  IconKalem,
  IconGuvenlikKamerasi,
  IconKamera,
  IconKasa,
  IconNot,
  IconTakvim,
  IconUyari,
  IconYikama,
} from '../../components/ui/icons'
import { listeUcretMetni, otoparkKurus } from './yikama'
import { useVardiyaOzetim } from '../vardiya/api'
import { olusturanAdi } from '../../lib/olusturan'
import { ucretsizEtiket } from '../../lib/ucretsiz'
import { useAdlar } from '../yonetim/api'

/**
 * One row in the open-vehicles list.
 *
 * Hierarchy by de-emphasis: the plate is the only thing at full contrast
 * because it is the only thing an operator scans for. Entry time and duration
 * step down to `text-faint`, and there are no labels on either — a duration
 * looks like a duration.
 *
 * The state chip sits on the SECOND line, not beside the plate. A row says
 * which list it belongs to (the two lists once rendered together) — but "Ödeme alınmadı" beside a plate and an Abonman chip overflows a
 * 375px row, and the thing that would give way is the plate.
 */
export function BiletKart({
  bilet,
  yerKod,
  adlar,
  uzunKalanSaat,
  fisIste = false,
  onClick,
}: {
  bilet: AcikBilet
  /** Looked up by the list, not here: fifty cards must not mean fifty
   *  subscriptions to the same cached spot query. `adlar` rides along for
   *  exactly the same reason. */
  yerKod?: string | null
  adlar: Map<string, string>
  /** F14 (1.4.2): `terk_esik_saat` — past it the row says "Uzun süredir
   *  içeride" (its exit may have been missed). From the list, like yerKod. */
  uzunKalanSaat?: number | null
  /** 088: a recent camera entry with no entry fiş yet (from the list). */
  fisIste?: boolean
  onClick: () => void
}) {
  // The tile colour carries the row's state, so a scanning eye sorts the list
  // before reading a single word. (052: the camera's "Kapıda" stamp is no
  // longer shown — the owner keeps only its push notification.)
  const tone = bilet.abonman_id ? 'success' : 'neutral'
  // Points already redeemed come off the fee in listeUcretMetni, the same
  // subtraction the collect screen makes, so the row never quotes more than
  // will be asked for. 078: an abonman with a wash reads "Ücretsiz + 150 ₺".

  return (
    <button
      type="button"
      onClick={onClick}
      className="flex w-full items-center gap-3.5 rounded-card border border-border bg-surface p-3.5 text-left shadow-card transition-[filter,transform] duration-100 [contain-intrinsic-size:auto_100px] [content-visibility:auto] active:scale-[0.99] active:brightness-[0.97]"
    >
      {/* 078: the badge sits on the car box, so a washed car is spotted from
          arm's length without taking room from line two (owner chose it). */}
      <span className="relative shrink-0">
        <IconTile tone={tone}>
          <IconAraba size={21} />
        </IconTile>
        {bilet.yikama_kurus ? (
          <span
            role="img"
            aria-label="Oto yıkama"
            className="absolute -top-1.5 -left-1.5 flex size-[22px] items-center justify-center rounded-full bg-accent text-accent-ink ring-2 ring-surface"
          >
            <IconYikama size={13} strokeWidth={2.2} />
          </span>
        ) : null}
      </span>

      <div className="min-w-0 flex-1">
        {/* Line one is the plate and the two numbers worth reading at arm's
            length, and nothing else — so the plate is never what gives way.
            The fee is stacked under the duration because they answer the same
            question ("how long, therefore how much") and because the amount is
            what the operator is about to ask for. It is priced server-side by
            acik_bilet_ara, so it is the same figure the collect screen will
            show rather than a second opinion. */}
        <div className="flex items-start gap-3">
          <div className="min-w-0 flex-1">
            <div className="flex items-center gap-2">
              <span className="min-w-0 truncate text-lead font-semibold tracking-wide text-ink tnum">
                {formatPlaka(bilet.plaka)}
              </span>
              {/* The plate was read from a photo and the model was not
                  confident (029). Beside the PLATE rather than among the chips:
                  it is a warning about this exact text. */}
              {bilet.plaka_supheli && (
                <span
                  aria-label="Plaka doğrulanmalı"
                  className="flex size-[22px] shrink-0 items-center justify-center rounded-full bg-warn-soft text-label font-bold text-warn"
                >
                  !
                </span>
              )}
            </div>
            {/* Owner, 27.11: the time sits under the plate on its own row, so
                the chips can no longer squeeze it out. Spot first (what someone
                scans the list for), then when, then who let the car in.
                'gecikmeli': the event arrived from a buffer after the fact. */}
            <p className="mt-0.5 truncate text-label text-faint tnum">
              {yerKod && <span className="font-medium text-soft">{yerKod} · </span>}
              {formatGoreceli(bilet.giris_at)}
              {bilet.gecikmeli_kayit && ' · gecikmeli'}
              {' · '}
              <OlusturanEtiketi id={bilet.giris_by} kaynak={bilet.giris_kaynak} adlar={adlar} />
            </p>
          </div>
          {/* Duration over fee: "how long, therefore how much". The fee is
              bold (owner, 27.11: it stayed behind) and priced server-side by
              acik_bilet_ara — the same figure the collect screen shows. */}
          <span className="shrink-0 text-right">
            <span className="block text-body font-semibold text-ink tnum">
              {sureMetni(bilet.giris_at)}
            </span>
            <span
              className={`block text-body font-bold tnum ${
                bilet.abonman_id ? 'text-success' : 'text-ink'
              }`}
            >
              {listeUcretMetni({ ...bilet, yikama_kurus: bilet.yikama_kurus ?? null }, formatTL)}
            </span>
          </span>
        </div>

        {/* Line three: the labels. They wrap instead of hiding anything. */}
        <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
          <Chip size="sm" tone="neutral" className="shrink-0">
            İçeride
          </Chip>
          {/* 088: "Gişe asks to print" — tap the row, then "Giriş fişi yazdır". */}
          {fisIste && (
            <Chip size="sm" tone="accent" className="shrink-0">
              Fiş ver
            </Chip>
          )}
          {/* F14 (1.4.2): inside longer than the "Terk edilmiş" threshold —
              the exit may have been missed. Never for abonman (uzunKalan).
              Two words: with "İptal bekliyor" and the note icon a longer
              label pushed the row past 360 px (checked in the browser). */}
          {uzunKalan(bilet, uzunKalanSaat) && (
            <Chip size="sm" tone="warn" className="shrink-0">
              Uzun kalış
            </Chip>
          )}
          {/* 080: the agreed time is over and nobody added the extra time yet
              (owner: a warning on the card, nothing charged by itself). */}
          {anlasmaBittiUyarisi(bilet, Date.now()) && (
            <Chip size="sm" tone="warn" className="shrink-0">
              Anlaşma bitti
            </Chip>
          )}
          {/* 082: past the first tier and nobody has decided yet — the fee
              shown is the first tier's until someone does. */}
          {bilet.asim_bekliyor && (
            <Chip size="sm" tone="warn" className="shrink-0">
              Süre aşımı
            </Chip>
          )}
          {/* 050: a Personel asked to cancel; the ticket stays open until a
              Yönetici decides, so the list must say why it is still here. */}
          {bilet.iptal_talebi && (
            <Chip size="sm" tone="warn" className="shrink-0">
              İptal bekliyor
            </Chip>
          )}
          {bilet.abonman_id && (
            <Chip size="sm" tone="success" className="shrink-0">
              Abonman
            </Chip>
          )}
          {/* Marker only. The note itself is not in this list on purpose — see
              acik_bilet_ara — so the icon says "there is something to read at
              the till", which is exactly what a scanning eye needs. */}
          {bilet.notu_var && (
            <IconNot
              size={15}
              className="shrink-0 text-faint"
              aria-label="Notu var"
              role="img"
            />
          )}
        </div>
        {/* 077 H's "İçeride görüldü" line was dropped (owner, 27.11). The
            server still records the time. */}
      </div>

    </button>
  )
}

/**
 * Occupancy as a whole percent.
 *
 * One definition, because this number is rendered three ways on two screens —
 * the header badge, the headline figure, and the width of the capacity bar. If
 * the bar were fed the unrounded value and the label the rounded one they
 * could disagree, which is the sort of tiny inconsistency that makes an
 * interface feel untrustworthy on the screen where trust matters most.
 *
 * A zero or missing capacity yields 0 rather than NaN or Infinity.
 */
/**
 * Shown while no till shift is open.
 *
 * Not a nicety. With no open shift `bilet_kapat` writes the collection with
 * `vardiya_id = null`, so the cash is still recorded as revenue but belongs to
 * no shift — and a drawer count can therefore never account for it. The money
 * is not lost, the accountability is, and nothing else on the screen would
 * say so. Silent by construction is exactly the failure this app exists to end.
 */
export function VardiyaUyarisi() {
  const navigate = useNavigate()
  const { data: ozet, isPending } = useVardiyaOzetim()
  // Nothing while the answer is unknown: a warning that flashes on every load
  // and then disappears is one operators learn to ignore.
  if (isPending || ozet) return null
  return (
    <button
      type="button"
      onClick={() => navigate('/vardiya/kasa')}
      className="flex w-full items-center gap-3 rounded-card bg-warn-soft px-4 py-3 text-left"
    >
      <IconUyari size={20} className="shrink-0 text-warn" />
      <span className="flex-1 text-body font-medium text-warn">
        Vardiya açık değil — tahsilat hiçbir sayıma girmez
      </span>
      <IconIleri size={17} className="shrink-0 text-warn" />
    </button>
  )
}

export function dolulukYuzde(dolu: number, kapasite: number): number {
  if (!kapasite || kapasite <= 0) return 0
  return Math.round((dolu / kapasite) * 100)
}

/**
 * One row in the list of vehicles that have already left.
 *
 * A separate component from `BiletKart` rather than a flag on it, because
 * almost every field means something different once a ticket is closed: the
 * duration is final instead of ticking, the timestamp is the EXIT rather than
 * the entry, and the number on the right is what was actually collected rather
 * than how long the car has been sitting there. One shared component would
 * have meant a card that lies in one of its two modes.
 */
export function CikanKart({
  bilet,
  adlar,
  onClick,
  onay = null,
  islem = true,
}: {
  bilet: Bilet
  /** Same rule as BiletKart: the list subscribes once, the rows do not. */
  adlar: Map<string, string>
  onClick: () => void
  /**
   * Approval state of the money, or null to show nothing.
   *
   * Passed IN rather than derived here, and that is the safety property: only
   * the screen knows whether the viewer is a Yönetici, and a Personel's embed
   * carries collections from their own open shift and nothing else — so a
   * card that derived this itself would print "Onaylanmadı" over other
   * people's approved tickets.
   */
  onay?: OnayDurum | null
  /**
   * Whether this viewer may act on the ticket (`kapaliBiletIslemYapabilir`,
   * 067). A Personel reading another shift's exit sees the debt as a state
   * ("Ödeme alınmadı"), not as a to-do they would be refused.
   */
  islem?: boolean
}) {
  // Since 027 a closed ticket can owe money, so "tahsil_kurus === 0" no longer
  // means the exit was free — it means no cash changed hands, which is now two
  // different situations. They are separated here:
  //
  //   borç 0            → genuinely free: an abonman, or inside the grace
  //                       period. Neutral, and the amount says "Ücretsiz".
  //   borç > 0, alındı  → the normal exit.
  //   borç > 0, alınmadı → the car left owing. Amber, and the amount shows
  //                       what is owed rather than the ₺0 that was taken.
  //
  // The amount column reads the FEE in every case, because "what this stay
  // cost" is the same question whether or not it has been paid yet.
  const borc = biletBorcu(bilet)
  const alindi = odemeAlindi(bilet)
  const bedava = borc === 0
  // 054 (owner, 2026-11-10): the camera now closes the ticket at exit and the
  // money is collected afterwards, so an owed exit is a to-do. The tile says
  // so before a word is read: the till icon in amber, and the chip names the
  // action ("Ödeme topla") rather than the state.
  const toplanacak = !bedava && !alindi && islem

  return (
    <button
      type="button"
      onClick={onClick}
      className="flex w-full items-center gap-3.5 rounded-card border border-border bg-surface p-3.5 text-left shadow-card transition-[filter,transform] duration-100 [contain-intrinsic-size:auto_100px] [content-visibility:auto] active:scale-[0.99] active:brightness-[0.97]"
    >
      <IconTile tone={toplanacak ? 'warn' : 'neutral'}>
        {toplanacak ? <IconKasa size={21} /> : <IconCikis size={21} />}
      </IconTile>

      <div className="min-w-0 flex-1">
        {/* Plate with the time under it, amount on the right — same layout
            as the open rows (owner, 27.11). */}
        <div className="flex items-start gap-3">
          <div className="min-w-0 flex-1">
            <span className="block truncate text-lead font-semibold tracking-wide text-ink tnum">
              {formatPlaka(bilet.plaka)}
            </span>
            <p className="mt-0.5 truncate text-label text-faint tnum">
              {bilet.cikis_at ? formatGoreceli(bilet.cikis_at) : '—'}
              {' · '}
              {sureMetni(bilet.giris_at, bilet.cikis_at)}
              {/* The EXIT side here, not the entry: on a closed ticket the
                  question a reader has is who took the money. */}
              {' · '}
              <OlusturanEtiketi id={bilet.cikis_by} kaynak={bilet.cikis_kaynak} adlar={adlar} />
            </p>
          </div>
          <span
            className={`shrink-0 text-body font-bold tnum ${
              bedava ? 'text-success' : alindi ? 'text-ink' : 'text-warn'
            }`}
          >
            {bedava ? 'Ücretsiz' : formatTL(borc)}
          </span>
        </div>

        {/* The chips (up to four: ödeme, abonman, onay, yöntem) wrap on
            their own row; the time no longer shares it. */}
        <div className="mt-1.5 flex flex-wrap items-center gap-1.5">
          <Chip
            size="sm"
            tone={alindi ? 'success' : bedava ? 'neutral' : 'warn'}
            className="shrink-0"
          >
            {toplanacak ? 'Ödeme topla' : ODEME_DURUM_ETIKET[alindi ? 'ALINDI' : 'ALINMADI']}
          </Chip>
          {bilet.abonman_id && (
            <Chip size="sm" tone="success" className="shrink-0">
              Abonman
            </Chip>
          )}
          {/* Whether this money counts is a bigger fact about the exit than
              how it was paid, so it sits ahead of the method chip — same
              order as the Finans list, which shows the same three states. */}
          {onay && (
            <span
              className={`shrink-0 rounded-chip px-2 py-0.5 text-micro font-medium ${ONAY_CHIP[onay]}`}
            >
              {ONAY_ETIKET[onay]}
            </span>
          )}
          {/* Not a Chip: the payment tones are their own scale (ODEME_CHIP),
              and feeding them through `className` would race Chip's own tone
              classes — equal specificity, so the winner would depend on
              stylesheet order rather than on anything visible here. */}
          {alindi && bilet.odeme_yontemi && (
            <span
              className={`shrink-0 rounded-chip px-2 py-0.5 text-micro font-medium ${ODEME_CHIP[bilet.odeme_yontemi]}`}
            >
              {ODEME_ETIKET[bilet.odeme_yontemi]}
            </span>
          )}
        </div>
      </div>

    </button>
  )
}

/** Occupancy, sized to sit quietly in a header. Amber past 90%. */
export function DolulukRozeti({ dolu, kapasite }: { dolu: number; kapasite: number }) {
  const yuzde = dolulukYuzde(dolu, kapasite)
  const dolmak = yuzde >= 90
  return (
    <span
      className={[
        'inline-flex items-center gap-1.5 rounded-chip px-2.5 py-1 text-label font-medium tnum',
        dolmak ? 'bg-warn-soft text-warn' : 'bg-field text-soft',
      ].join(' ')}
      title={`${dolu} / ${kapasite} dolu`}
    >
      {dolmak ? <IconUyari size={14} /> : <IconAraba size={14} />}
      {dolu}/{kapasite}
    </span>
  )
}

/** Small thumbnail strip for a captured-but-not-yet-uploaded photo. */
export function FotoOnizleme({ url, onKaldir }: { url: string; onKaldir: () => void }) {
  return (
    <div className="flex items-center gap-3 rounded-field bg-field p-2.5">
      <img
        src={url}
        alt="Çekilen fotoğraf"
        className="size-14 shrink-0 rounded-field object-cover"
      />
      <span className="flex-1 text-label text-soft">
        <IconKamera size={14} className="mr-1 inline" />
        Fotoğraf eklendi
      </span>
      <button
        type="button"
        onClick={onKaldir}
        className="min-h-[44px] px-3 text-label font-medium text-danger"
      >
        Kaldır
      </button>
    </div>
  )
}

/* ======================================================= ticket detail === */
/*
 * The ticket screen's parts, shared by Tahsilat (car inside) and Bilet Detay
 * (any ticket) so the two never drift: a warning that shows on one and not the
 * other is how an operator collects a fee somebody already flagged.
 *
 * Both screens read top to bottom in the same order (owner, 2026-11-02):
 *   photo → plate → fee + stay → ticket facts │ müşteri → Değiştir → undo.
 */

/**
 * Who opened or closed a ticket. The camera is shown as its icon only (owner,
 * 27.11: "no need to write it"); screen readers still hear "Kamera". A person
 * stays a name (olusturanAdi decides camera / name / Otomatik / Bilinmiyor).
 */
export function OlusturanEtiketi({
  id,
  kaynak,
  adlar,
}: {
  id: string | null
  kaynak: Kaynak | null
  adlar: Map<string, string>
}) {
  if (kaynak === 'KAMERA') {
    return (
      <IconGuvenlikKamerasi
        size={18}
        role="img"
        aria-label="Kamera"
        className="inline-block shrink-0 align-[-4px]"
      />
    )
  }
  return <>{olusturanAdi(id, kaynak, adlar)}</>
}

function Satir({ k, v }: { k: string; v: ReactNode }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="shrink-0 text-body text-faint">{k}</dt>
      <dd className="text-right text-body text-ink">{v}</dd>
    </div>
  )
}

/**
 * The ticket's facts, as a definition list. Not the stay (shown big beside the
 * fee) and not the customer (its own part below the separator).
 */
export function BiletBilgileri({ bilet, yerKod }: { bilet: Bilet; yerKod?: string | null }) {
  // Subscribing here is fine, unlike in the row components: this renders once
  // per screen, so there is no fifty-cards-fifty-subscriptions problem to
  // avoid and threading a prop through two detail screens would buy nothing.
  const adlar = useAdlar()
  return (
    <dl className="space-y-2.5">
      <Satir k="Giriş" v={formatTam(bilet.giris_at)} />
      {bilet.cikis_at && <Satir k="Çıkış" v={formatTam(bilet.cikis_at)} />}
      {/* Only while the bay still exists: a retired spot leaves the id on the
          ticket, and "Park yeri —" says less than nothing. */}
      {yerKod && <Satir k="Park yeri" v={yerKod} />}
      {bilet.ucret_kurus > 0 && <Satir k="Ücret" v={formatTL(bilet.ucret_kurus)} />}
      {/* 078: while the car is inside the Hizmetler card shows the wash; once
          closed it is a fact of the ticket (its fee above includes it). */}
      {bilet.durum !== 'ACIK' && bilet.yikama_kurus ? (
        <Satir k="Oto yıkama" v={formatTL(bilet.yikama_kurus)} />
      ) : null}
      {bilet.indirim_kurus > 0 && (
        <Satir
          k="Puan indirimi"
          v={`−${formatTL(bilet.indirim_kurus)} (${bilet.puan_kullanilan} puan)`}
        />
      )}
      {bilet.odeme_yontemi && (
        <div className="flex items-center justify-between gap-3">
          <dt className="text-body text-faint">Ödeme</dt>
          <dd>
            <span
              className={`rounded-chip px-2.5 py-1 text-label font-medium ${ODEME_CHIP[bilet.odeme_yontemi]}`}
            >
              {ODEME_ETIKET[bilet.odeme_yontemi]}
            </span>
          </dd>
        </div>
      )}
      {/* Replaces the old "Kaynak: Kamera / Elle" row. 'Elle' answered a
          question nobody had — whether a person did it — while leaving out
          WHICH person, which is the part that matters when a ticket is being
          questioned. The camera still names itself, because it has no
          profile row to name. */}
      <Satir
        k="Girişi yapan"
        v={<OlusturanEtiketi id={bilet.giris_by} kaynak={bilet.giris_kaynak} adlar={adlar} />}
      />
      {bilet.cikis_at && (
        <Satir
          k="Çıkışı yapan"
          v={<OlusturanEtiketi id={bilet.cikis_by} kaynak={bilet.cikis_kaynak} adlar={adlar} />}
        />
      )}
      {/* 065: a free exit's reason and note — a fact about the ticket, so
          every role sees it. Wraps: the note is the operator's own words. */}
      {bilet.ucretsiz_sebep && (
        <div className="flex items-baseline justify-between gap-3">
          <dt className="shrink-0 text-body text-faint">Ücretsiz çıkış</dt>
          <dd className="min-w-0 text-right text-body break-words text-ink">
            {ucretsizEtiket(bilet.ucretsiz_sebep)}
            {bilet.ucretsiz_not ? ` — ${bilet.ucretsiz_not}` : ''}
          </dd>
        </div>
      )}
      {bilet.gecikmeli_kayit && bilet.kaynak_zaman && (
        <Satir
          k="Kameradan gelme"
          v={`${formatGoreceli(bilet.kaynak_zaman)} olayı, sonradan işlendi`}
        />
      )}
      {bilet.abonman_id && <Satir k="Abonman" v="Ücretsiz giriş" />}
      {bilet.kayip_bilet && <Satir k="Kayıp bilet" v="Evet" />}
    </dl>
  )
}

/** The flags that change how a ticket should be read. */
export function BiletUyarilari({ bilet }: { bilet: Bilet }) {
  return (
    <>
      {/* rounded-field, not rounded-card: these now sit INSIDE the details
          card, and a nested radius has to be the smaller one. */}
      {bilet.ucret_degistirildi && (
        <div className="rounded-field bg-warn-soft px-3.5 py-3">
          <p className="text-body font-medium text-warn">Ücret elle değiştirilmiş</p>
          {bilet.ucret_sebep && (
            <p className="mt-1 text-label text-warn opacity-90">{bilet.ucret_sebep}</p>
          )}
        </div>
      )}

      {bilet.durum === 'IPTAL' && bilet.iptal_sebep && (
        <div className="rounded-field bg-danger-soft px-3.5 py-3">
          <p className="text-body font-medium text-danger">İptal edildi</p>
          <p className="mt-1 text-label text-danger opacity-90">{bilet.iptal_sebep}</p>
        </div>
      )}
    </>
  )
}

/**
 * The car's photo(s), first thing on the screen — the plate in the picture is
 * what the plate text below it is checked against.
 *
 * `object-contain` on a field-coloured well, never `object-cover`: a camera
 * crop is wide and a phone photo is tall, and cover would cut either one —
 * possibly right through the plate this photo exists to show.
 *
 * One photo spans the width. Entry + exit sit side by side, captioned, because
 * then the reader has to know which is which. No photo at all → nothing, not
 * an empty frame: a manual entry has no picture and that is not an error. A
 * photo whose link failed (retention purge, storage hiccup) drops out the same
 * way rather than leaving a broken image.
 */
export function BiletFoto({ bilet }: { bilet: Pick<Bilet, 'giris_foto' | 'cikis_foto'> }) {
  const giris = useFotoUrl(bilet.giris_foto)
  const cikis = useFotoUrl(bilet.cikis_foto)
  // Tapping a photo opens it full screen, zoomable (FotoGoruntuleyici): at
  // this size a plate's characters are too small to check.
  const [buyuk, setBuyuk] = useState<{ url: string; etiket: string } | null>(null)

  // `isPending` is only meaningful when there is a path: a disabled query
  // (no path) also reports pending, which is why the path is checked first.
  const kareler = [
    { etiket: 'Giriş', path: bilet.giris_foto, q: giris },
    { etiket: 'Çıkış', path: bilet.cikis_foto, q: cikis },
  ].filter((k) => k.path && (k.q.isPending || k.q.data))

  if (kareler.length === 0) return null
  const tek = kareler.length === 1

  return (
    <div className={tek ? '' : 'grid grid-cols-2 gap-3'}>
      {kareler.map((k) => (
        <figure key={k.etiket}>
          <div
            className={`overflow-hidden rounded-card bg-field ${tek ? 'aspect-video' : 'aspect-[4/3]'}`}
          >
            {k.q.data ? (
              <button
                type="button"
                onClick={() => setBuyuk({ url: k.q.data!, etiket: k.etiket })}
                aria-label={`${k.etiket} fotoğrafını büyüt`}
                className="block size-full"
              >
                <img
                  src={k.q.data}
                  alt={`${k.etiket} fotoğrafı`}
                  className="size-full object-contain"
                />
              </button>
            ) : (
              // Holds the space while the signed link loads, so the plate and
              // the fee below do not jump down the moment it arrives.
              <div className="size-full animate-pulse" aria-hidden="true" />
            )}
          </div>
          {/* A lone entry photo needs no caption — it is the default. */}
          {(!tek || k.etiket === 'Çıkış') && (
            <figcaption className="mt-1.5 text-label text-faint">{k.etiket}</figcaption>
          )}
        </figure>
      ))}
      <FotoGoruntuleyici
        url={buyuk?.url ?? null}
        etiket={buyuk?.etiket}
        onKapat={() => setBuyuk(null)}
      />
    </div>
  )
}

/** The ticket's state as one chip — same words as the vehicle list. */
export function DurumChip({ durum }: { durum: Bilet['durum'] }) {
  if (durum === 'IPTAL') return <Chip tone="danger">İptal</Chip>
  if (durum === 'KAPALI') return <Chip tone="success">Çıktı</Chip>
  return <Chip tone="accent">İçeride</Chip>
}

/**
 * The plate as text, right under the photo it is read against.
 *
 * Same size and tracking as the plate entry field (28px, wide, tabular): the
 * plate is the ticket's identity, so it reads louder than the screen title and
 * looks the same wherever it is typed or shown. `break-all` rather than
 * truncate — a plate is never worth hiding a character of.
 */
export function PlakaBasligi({
  plaka,
  durum,
}: {
  plaka: string
  durum: Bilet['durum']
}) {
  return (
    <div className="flex items-center justify-between gap-3">
      <p className="min-w-0 text-[28px] leading-tight font-semibold tracking-[0.06em] break-all text-ink tnum">
        {formatPlaka(plaka)}
      </p>
      <DurumChip durum={durum} />
    </div>
  )
}

function BolumBasligi({
  children,
  sag,
  guclu = false,
}: {
  children: ReactNode
  sag?: ReactNode
  /** The card's own title (Bilet) — darker and bolder than its sub-sections. */
  guclu?: boolean
}) {
  return (
    // min-h-11: the row is as tall as the 44px icon button that may sit in it,
    // so the two halves of the card start their lists at the same rhythm.
    <div className="flex min-h-11 items-center justify-between gap-3">
      <h2
        className={`text-label tracking-wide uppercase ${
          guclu ? 'font-bold text-ink' : 'font-medium text-faint'
        }`}
      >
        {children}
      </h2>
      {sag}
    </div>
  )
}

/**
 * Ticket facts, one hairline, then the customer — ONE card, so the separator
 * says "same ticket, other half" rather than starting a new thing.
 *
 * `sag`: an action beside the "Bilet" title (owner, 2026-11-27: the detail
 * screen's "Değiştir" sits there, on the right, instead of a full-width row).
 */
/**
 * 078: the oto yıkama switch — one row, the same on Giriş, the ticket detail
 * and Tahsilat. Switch first (the mockup the owner approved), then the drop,
 * the label and the price. The whole row is the target (≥ 44 px).
 */
export function YikamaAnahtari({
  acik,
  kurus,
  bekliyor = false,
  onDegis,
  zemin = 'field',
}: {
  acik: boolean
  /** The price shown: the ticket's locked one when on, the tariff's when off. */
  kurus: number | null
  bekliyor?: boolean
  onDegis: (acik: boolean) => void
  zemin?: 'field' | 'surface'
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={acik}
      aria-label={kurus ? `Oto yıkama ${formatTL(kurus)}` : 'Oto yıkama'}
      disabled={bekliyor}
      onClick={() => onDegis(!acik)}
      className={`flex min-h-14 w-full items-center gap-3 rounded-card px-4 py-2.5 text-left disabled:opacity-60 ${
        zemin === 'field' ? 'bg-field' : 'border border-border bg-surface shadow-card'
      }`}
    >
      <span
        aria-hidden="true"
        className={`relative h-[32px] w-[54px] shrink-0 rounded-full transition-colors ${
          // Off: the faint ink, not bg-field / bg-border — the row itself is
          // field-coloured, and in dark mode the knob vanished on those.
          acik ? 'bg-accent' : 'bg-faint'
        }`}
      >
        <span
          className={`absolute top-[3px] size-[26px] rounded-full bg-surface shadow-card transition-[left] ${
            acik ? 'left-[25px]' : 'left-[3px]'
          }`}
        />
      </span>
      <IconYikama size={22} className="shrink-0 text-accent" />
      <span className="min-w-0 flex-1 text-body font-medium text-ink">Oto yıkama</span>
      {kurus ? (
        <span className="shrink-0 text-body font-semibold text-ink tnum">+{formatTL(kurus)}</span>
      ) : null}
    </button>
  )
}

/**
 * 078: "Hizmetler" — what the fee is made of while the car is inside: the
 * parking part, then the wash switch. Same heading as "Bilet" (owner). The
 * switch talks to the server (bilet_yikama); the price is locked there.
 */
export function HizmetlerKarti({
  bilet,
  toplamKurus,
  tarifeKurus,
  onDegisti,
}: {
  bilet: Bilet
  /** The live fee (bilet_ucret_onizle): parking + wash. Undefined while loading. */
  toplamKurus: number | undefined
  /** The tariff's wash price, for the switch while it is off. */
  tarifeKurus: number | null
  /** Called after the server accepted a switch (Tahsilat clears its override). */
  onDegisti?: () => void
}) {
  const yikama = useBiletYikama()
  const [hata, setHata] = useState<string | null>(null)
  const acik = Boolean(bilet.yikama_kurus)
  // 080: with a deal, the deal block says what the parking costs; the
  // "Otopark" row would only repeat it.
  const anlasmaVar = Boolean(bilet.anlasma_kurus)
  return (
    <Card>
      <BolumBasligi guclu>Hizmetler</BolumBasligi>
      {!anlasmaVar && (
        <dl className="mt-1 space-y-2.5">
          <Satir
            k="Otopark"
            v={
              toplamKurus === undefined
                ? '—'
                : bilet.abonman_id
                  ? 'Ücretsiz (abonman)'
                  : formatTL(otoparkKurus(toplamKurus, bilet.yikama_kurus ?? null))
            }
          />
        </dl>
      )}
      {/* 082: past the first tier — the report and the decision. */}
      {!anlasmaVar && !bilet.abonman_id && (
        <AsimBlogu bilet={bilet} onDegisti={onDegisti} className="mt-3" />
      )}
      {/* 080: no deal for an abonman car (the server refuses it too). */}
      {!bilet.abonman_id && (
        <div className={anlasmaVar ? 'mt-1' : 'mt-3'}>
          <AnlasmaBlogu bilet={bilet} onDegisti={onDegisti} />
        </div>
      )}
      <div className="mt-3">
        <YikamaAnahtari
          acik={acik}
          kurus={acik ? (bilet.yikama_kurus ?? null) : tarifeKurus}
          bekliyor={yikama.isPending}
          onDegis={(v) => {
            setHata(null)
            yikama.mutate(
              { bilet_id: bilet.id, acik: v },
              {
                onSuccess: () => onDegisti?.(),
                onError: (e) => setHata(rpcErrorText(e, 'Oto yıkama değiştirilemedi.')),
              },
            )
          }}
        />
      </div>
      {hata && (
        <p role="alert" className="mt-2 text-label text-danger">
          {hata}
        </p>
      )}
    </Card>
  )
}

/**
 * 082: where a ticket stands on the first-tier cap. One query per ticket (the
 * key is shared, so the card and the exit button ask once).
 */
export function useAsim(bilet: Bilet | null | undefined): { durum: AsimDurumu; onizle: AsimOnizleme | null } {
  const aktif =
    Boolean(bilet) && !bilet?.abonman_id && bilet?.anlasma_kurus == null && bilet?.durum !== 'IPTAL'
  const q = useAsimOnizleme(bilet, aktif)
  return { durum: bilet ? asimDurumu(bilet, q.data) : 'YOK', onizle: q.data ?? null }
}

/**
 * 082 (owner, 27.11): a normal ticket stops at the first tier's price. Past
 * it, the ticket shows how long the car stayed and what the tariff says, and
 * a person decides: "Onayla" (the full price) or keep the first tier. Exit
 * and collection wait for it (the server refuses them too). After the
 * decision, one quiet line says who decided what.
 */
export function AsimBlogu({
  bilet,
  onDegisti,
  className = '',
}: {
  bilet: Bilet
  onDegisti?: () => void
  className?: string
}) {
  const { durum, onizle } = useAsim(bilet)
  const karar = useAsimKarar()
  const adlar = useAdlar()
  const [hata, setHata] = useState<string | null>(null)

  if (durum === 'TAM' || durum === 'ILK') {
    const ad = bilet.asim_karar_by ? (adlar.get(bilet.asim_karar_by) ?? null) : null
    return <p className={`text-label text-soft ${className}`}>{asimKararMetni(durum, ad)}</p>
  }
  if (durum !== 'BEKLIYOR' || !onizle) return null

  const ver = (tam: boolean) => {
    setHata(null)
    karar.mutate(
      { bilet_id: bilet.id, tam },
      {
        onSuccess: () => onDegisti?.(),
        onError: (e) => setHata(rpcErrorText(e, 'Karar kaydedilemedi.')),
      },
    )
  }

  return (
    <div className={`rounded-field bg-warn-soft p-3.5 ${className}`}>
      <p className="text-body font-semibold text-warn">İlk kademe aşıldı</p>
      <dl className="mt-2 space-y-1.5 text-body">
        <div className="flex justify-between gap-3">
          <dt className="text-soft">Kaldığı süre</dt>
          <dd className="font-medium text-ink tnum">{sureMetni(bilet.giris_at, bilet.cikis_at)}</dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-soft">İlk kademe</dt>
          <dd className="font-medium text-ink tnum">{formatTL(onizle.ilk_kurus)}</dd>
        </div>
        <div className="flex justify-between gap-3">
          <dt className="text-soft">Tarifeye göre</dt>
          <dd className="font-bold text-ink tnum">{formatTL(onizle.tam_kurus)}</dd>
        </div>
      </dl>
      <div className="mt-3 space-y-2">
        <button
          type="button"
          disabled={karar.isPending}
          onClick={() => ver(true)}
          className="flex min-h-12 w-full items-center justify-center rounded-field bg-warn px-4 text-body font-semibold text-surface active:brightness-95 disabled:opacity-60"
        >
          Onayla · {formatTL(onizle.tam_kurus)}
        </button>
        <button
          type="button"
          disabled={karar.isPending}
          onClick={() => ver(false)}
          className="flex min-h-12 w-full items-center justify-center rounded-field bg-surface px-4 text-body font-semibold text-ink active:brightness-95 disabled:opacity-60"
        >
          {formatTL(onizle.ilk_kurus)} kalsın
        </button>
      </div>
      {hata && (
        <p role="alert" className="mt-2 text-label text-danger">
          {hata}
        </p>
      )}
    </div>
  )
}

/** A clock for the deal bar: re-renders every 30 s (the server re-prices on its own 30 s tick). */
function useSimdi(aralikMs = 30_000): number {
  const [simdi, setSimdi] = useState(() => Date.now())
  useEffect(() => {
    const t = setInterval(() => setSimdi(Date.now()), aralikMs)
    return () => clearInterval(t)
  }, [aralikMs])
  return simdi
}

/** "3 gün" / "5 saat" — how the deal was agreed. */
function anlasmaSureEtiketi(saat: number): string {
  return saat % 24 === 0 ? `${saat / 24} gün` : `${saat} saat`
}

function anlasmaSaatiOf(bilet: Bilet): number | null {
  if (!bilet.anlasma_bitis) return null
  return Math.round((Date.parse(bilet.anlasma_bitis) - Date.parse(bilet.giris_at)) / 3_600_000)
}

/**
 * 080: the agreed price as a time budget (layout E, owner): a bar that fills
 * from entry to the deal's end, green while running, orange once over. The
 * extra time is never added by itself — one button, with its amount.
 * Tapping the deal opens the form to change or remove it.
 */
function AnlasmaBlogu({ bilet, onDegisti }: { bilet: Bilet; onDegisti?: () => void }) {
  const simdi = useSimdi()
  const [form, setForm] = useState(false)
  const [hata, setHata] = useState<string | null>(null)
  const fazla = useAnlasmaFazla()
  const kurus = bilet.anlasma_kurus ?? null
  const bitis = bilet.anlasma_bitis ?? null
  const d = kurus && bitis ? anlasmaDurumu(bilet.giris_at, bitis, simdi) : null
  const eklendi = Boolean(bilet.anlasma_fazla_at)
  const onizleme = useFazlaOnizleme(bilet, Boolean(d?.doldu))
  const fazlaKurus = onizleme.data
  const saat = anlasmaSaatiOf(bilet)

  const formu = form ? (
    <AnlasmaFormu
      bilet={bilet}
      onKapat={() => setForm(false)}
      onDegisti={() => {
        setForm(false)
        onDegisti?.()
      }}
    />
  ) : null

  if (!d || !kurus || !bitis) {
    return (
      <>
        <button
          type="button"
          onClick={() => setForm(true)}
          className="flex min-h-14 w-full items-center gap-3 rounded-card text-left"
        >
          <IconTile tone="accent" size="sm">
            <IconTakvim size={20} />
          </IconTile>
          <span className="text-body font-semibold text-accent">Anlaşmalı fiyat ekle</span>
        </button>
        {formu}
      </>
    )
  }

  return (
    <>
      <button type="button" onClick={() => setForm(true)} className="flex w-full gap-3 py-1 text-left">
        <IconTile tone={d.doldu ? 'warn' : 'accent'} size="sm">
          <IconTakvim size={20} />
        </IconTile>
        <span className="min-w-0 flex-1">
          <span className="block text-body text-ink">
            <span className="font-semibold tnum">Anlaşma {formatTL(kurus)}</span>
            {saat ? ` · ${anlasmaSureEtiketi(saat)}` : ''}
          </span>
          <span className="mt-2 block">
            <OranCubugu yuzde={d.yuzde} tone={d.doldu ? 'warn' : 'success'} label="Anlaşma süresi" />
          </span>
          <span className={`mt-1.5 block text-label tnum ${d.doldu ? 'font-semibold text-warn' : 'text-soft'}`}>
            {d.doldu
              ? `Süre doldu · ${kalanMetni(d, formatSure)}`
              : `${kalanMetni(d, formatSure)} · ${bitisMetni(bitis)}’e kadar`}
          </span>
        </span>
      </button>

      {d.doldu && !eklendi && (
        <button
          type="button"
          disabled={fazla.isPending || fazlaKurus === undefined}
          onClick={() => {
            setHata(null)
            fazla.mutate(bilet.id, {
              onSuccess: () => onDegisti?.(),
              onError: (e) => setHata(rpcErrorText(e, 'Fazla süre eklenemedi.')),
            })
          }}
          className="mt-3 flex min-h-12 w-full items-center justify-center rounded-field bg-warn px-4 text-body font-semibold text-surface active:brightness-95 disabled:opacity-60"
        >
          Fazla süreyi ekle{fazlaKurus !== undefined ? `: +${formatTL(fazlaKurus)}` : ''}
        </button>
      )}
      {d.doldu && eklendi && (
        <p className="mt-2 text-label font-semibold text-warn tnum">
          Fazla süre ekleniyor{fazlaKurus !== undefined ? ` · +${formatTL(fazlaKurus)}` : ''}
        </p>
      )}
      {hata && (
        <p role="alert" className="mt-2 text-label text-danger">
          {hata}
        </p>
      )}
      {formu}
    </>
  )
}

/** 080: price + duration (hours or days, from entry). Change or remove an existing deal. */
function AnlasmaFormu({
  bilet,
  onKapat,
  onDegisti,
}: {
  bilet: Bilet
  onKapat: () => void
  onDegisti: () => void
}) {
  const anlasma = useBiletAnlasma()
  const mevcut = anlasmaSaatiOf(bilet)
  const gunle = mevcut === null || mevcut % 24 === 0
  const [fiyat, setFiyat] = useState(bilet.anlasma_kurus ? kurusToInput(bilet.anlasma_kurus) : '')
  const [birim, setBirim] = useState<AnlasmaBirim>(gunle ? 'gun' : 'saat')
  const [sayi, setSayi] = useState(mevcut === null ? '' : String(gunle ? mevcut / 24 : mevcut))
  const [hata, setHata] = useState<string | null>(null)
  const kurus = parseTLToKurus(fiyat)
  const saat = anlasmaSaat(Number(sayi), birim)
  const saatGecerli = sayi !== '' && anlasmaSaatGecerli(saat)
  const bitis = saatGecerli ? anlasmaBitis(bilet.giris_at, saat) : null
  const sureId = useId()

  function kaydet(p_kurus: number | null, p_saat: number | null) {
    setHata(null)
    anlasma.mutate(
      { bilet_id: bilet.id, kurus: p_kurus, saat: p_saat },
      {
        onSuccess: onDegisti,
        onError: (e) => setHata(rpcErrorText(e, 'Anlaşma kaydedilemedi.')),
      },
    )
  }

  return (
    <FormModal
      open
      onOpenChange={(o) => !o && onKapat()}
      title="Anlaşmalı fiyat"
      onSubmit={() => kaydet(kurus, saat)}
      loading={anlasma.isPending}
      error={hata}
      disabled={kurus === null || kurus <= 0 || !saatGecerli}
    >
      <div className="space-y-4">
        <Input
          label="Fiyat (₺)"
          inputMode="decimal"
          autoComplete="off"
          value={fiyat}
          onChange={(e) => setFiyat(e.target.value)}
        />
        <div>
          <Label htmlFor={sureId}>Süre</Label>
          <div className="flex gap-2.5">
            <div className="flex-1">
              <Input
                id={sureId}
                label="Süre"
                hideLabel
                inputMode="numeric"
                autoComplete="off"
                value={sayi}
                onChange={(e) => setSayi(digitsOnly(e.target.value, 4))}
              />
            </div>
            <div className="flex-[1.2]">
              <SegmentedControl
                value={birim}
                options={[
                  { value: 'saat', label: 'Saat' },
                  { value: 'gun', label: 'Gün' },
                ]}
                onChange={setBirim}
              />
            </div>
          </div>
          {sayi !== '' && !saatGecerli && (
            <p className="mt-1.5 text-label text-danger">Süre 1 saat ile 90 gün arasında olmalı.</p>
          )}
        </div>
        {bitis && (
          <p className="text-body text-soft">
            Girişten sayılır · Bitiş: <span className="font-semibold text-ink tnum">{bitisMetni(bitis)}</span>
          </p>
        )}
        {bitis && bitis.getTime() <= Date.now() && (
          <p className="text-label font-semibold text-warn">Bu süre zaten doldu.</p>
        )}
        {bilet.anlasma_kurus ? (
          <Button
            type="button"
            variant="ghost"
            block
            disabled={anlasma.isPending}
            onClick={() => kaydet(null, null)}
          >
            Anlaşmayı kaldır
          </Button>
        ) : null}
      </div>
    </FormModal>
  )
}

export function BiletDetayKarti({
  bilet,
  yerKod,
  sag,
}: {
  bilet: Bilet
  yerKod?: string | null
  sag?: ReactNode
}) {
  return (
    <Card>
      <BolumBasligi guclu sag={sag}>
        Bilet
      </BolumBasligi>
      <div className="mt-1 space-y-4">
        <BiletUyarilari bilet={bilet} />
        <BiletBilgileri bilet={bilet} yerKod={yerKod} />
      </div>

      <div className="-mx-4 my-4 border-t border-divider" />

      <MusteriBolumu bilet={bilet} />
    </Card>
  )
}

/**
 * Who the car belongs to, with an icon-only edit button beside the heading.
 *
 * The pencil shows only while the car is inside: bilet_musteri_guncelle
 * refuses a closed ticket, and a button that can only fail is worse than none.
 * The form is a modal, so the list stays readable and the edit is one tap away
 * on both screens. It is handed a ticket that has already LOADED — the old
 * inline form had to guard against saving three blanks over a real name after
 * a failed load; here there is nothing to open until the row exists.
 */
export function MusteriBolumu({ bilet }: { bilet: Bilet }) {
  const [duzenle, setDuzenle] = useState(false)
  const duzenlenebilir = bilet.durum === 'ACIK'
  const bos = !bilet.arac_bilgi && !bilet.musteri_ad && !bilet.musteri_tel && !bilet.notlar

  return (
    <section>
      <BolumBasligi
        sag={
          duzenlenebilir ? (
            <button
              type="button"
              onClick={() => setDuzenle(true)}
              aria-label="Müşteri bilgilerini düzenle"
              title="Müşteri bilgilerini düzenle"
              className="-mr-2 flex size-11 shrink-0 items-center justify-center rounded-chip text-accent active:bg-field"
            >
              <IconKalem size={20} />
            </button>
          ) : undefined
        }
      >
        Müşteri
      </BolumBasligi>

      {bos ? (
        <p className="mt-1 text-body text-faint">Bilgi eklenmemiş</p>
      ) : (
        // Optional fields (008): each row only when it has something to say —
        // a list of empty labels reads as missing data.
        <dl className="mt-1 space-y-2.5">
          {bilet.musteri_ad && <Satir k="Ad" v={bilet.musteri_ad} />}
          {bilet.musteri_tel && (
            <div className="flex items-baseline justify-between gap-3">
              <dt className="shrink-0 text-body text-faint">Telefon</dt>
              <dd>
                {/* Tappable: the usual reason to look this up at a barrier is
                    that the car is blocking someone and its driver is not in it. */}
                <a
                  href={`tel:+90${bilet.musteri_tel}`}
                  className="text-body font-medium text-accent tnum underline"
                >
                  {formatTel(bilet.musteri_tel)}
                </a>
              </dd>
            </div>
          )}
          {bilet.arac_bilgi && <Satir k="Araç" v={bilet.arac_bilgi} />}
          {bilet.notlar && (
            <div className="flex items-baseline justify-between gap-3">
              <dt className="shrink-0 text-body text-faint">Not</dt>
              {/* whitespace-pre-line: a note is typed with line breaks and
                  losing them turns two remarks into one run-on sentence. */}
              <dd className="text-right text-body whitespace-pre-line text-ink">{bilet.notlar}</dd>
            </div>
          )}
        </dl>
      )}

      {/* Mounted only while open: every opening starts from what is saved,
          never from a half-typed draft somebody walked away from. */}
      {duzenle && <MusteriFormu bilet={bilet} onKapat={() => setDuzenle(false)} />}
    </section>
  )
}

function MusteriFormu({ bilet, onKapat }: { bilet: Bilet; onKapat: () => void }) {
  const guncelle = useBiletMusteriGuncelle()
  const [taslak, setTaslak] = useState<EkBilgiler>(() => ekBilgiAlanlari(bilet))
  const [telHata, setTelHata] = useState<string | null>(null)
  const [hata, setHata] = useState<string | null>(null)

  return (
    <FormModal
      open
      onOpenChange={(o) => {
        if (!o) onKapat()
      }}
      title="Müşteri bilgileri"
      loading={guncelle.isPending}
      error={hata}
      onSubmit={() => {
        setHata(null)
        setTelHata(null)
        if (!telGonderilebilir(taslak.tel)) {
          setTelHata('10 hane girin ya da alanı boş bırakın.')
          return
        }
        void guncelle
          .mutateAsync({ bilet_id: bilet.id, ...ekBilgiGonder(taslak) })
          .then(onKapat)
          .catch((e) => setHata(rpcErrorText(e, 'Kaydedilemedi.')))
      }}
    >
      <EkBilgiFormu
        deger={taslak}
        onChange={(m) => {
          setTaslak(m)
          setTelHata(null)
        }}
        telHatasi={telHata}
      />
    </FormModal>
  )
}

/* ============================================================ Değiştir === */

/** The real helpers, handed to the pure rules (see degistir.ts for why). */
const DEGISTIR_ARACLARI: DegistirAraclari = {
  normalizePlaka,
  plakaGecerli,
  parseTLToKurus,
  kurusToInput,
}

/** The fee half of the form — Tahsilat only, where an override can be applied. */
export interface DegistirUcret {
  /** Gross fee the field starts from: the override if one is set, else the computed fee. */
  kurus: number
  /** The computed fee, for the hint. */
  hesaplanan: number
  onUygula: (kurus: number, sebep: string) => void
}

/**
 * "Değiştir": plate, entry time and (on Tahsilat) the fee of an OPEN ticket.
 *
 * Only what changed is sent, in order plate → time → fee, and the modal stays
 * open on any error with the server's own sentence in it. A retry after a
 * partial save re-sends nothing that already landed (the baseline moves with
 * each success), and the server treats a repeat as a no-op anyway.
 */
export function BiletDegistirModal({
  open,
  ...rest
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  bilet: { id: string; plaka: string; giris_at: string; indirim_kurus: number }
  /** null: the fee is not editable here — say why in `ucretNotu`, or say nothing. */
  ucret: DegistirUcret | null
  ucretNotu?: string
}) {
  // Mounted only while open, so the form always starts from the ticket as it
  // is NOW — not from the values of the last time it was opened.
  if (!open) return null
  return <DegistirFormu {...rest} />
}

function DegistirFormu({
  onOpenChange,
  bilet,
  ucret,
  ucretNotu,
}: {
  onOpenChange: (open: boolean) => void
  bilet: { id: string; plaka: string; giris_at: string; indirim_kurus: number }
  ucret: DegistirUcret | null
  ucretNotu?: string
}) {
  const yonetici = isYonetici(useAuth().profile)
  const plakaDuzelt = useBiletPlakaDuzelt()
  const girisDuzelt = useBiletGirisDuzelt()

  const [bas, setBas] = useState(() =>
    degistirBaslangic(bilet, ucret?.kurus ?? null, DEGISTIR_ARACLARI),
  )
  const [taslak, setTaslak] = useState<DegistirTaslak>(() => ({
    plaka: bas.plaka,
    girisYerel: bas.girisYerel,
    ucretMetni: bas.ucretMetni ?? '',
    sebep: '',
  }))
  const [alanHata, setAlanHata] = useState<{ alan: DegistirAlan; metin: string } | null>(null)
  const [hata, setHata] = useState<string | null>(null)
  const [calisiyor, setCalisiyor] = useState(false)

  const set = (yama: Partial<DegistirTaslak>) => {
    setTaslak((t) => ({ ...t, ...yama }))
    setAlanHata(null)
    setHata(null)
  }
  const hataOf = (alan: DegistirAlan) => (alanHata?.alan === alan ? alanHata.metin : null)

  async function kaydet() {
    if (calisiyor) return
    setHata(null)
    setAlanHata(null)
    const s = degisiklikler(bas, taslak, new Date(), DEGISTIR_ARACLARI)
    if (s.hata !== null) {
      setAlanHata({ alan: s.alan, metin: s.hata })
      return
    }
    if (s.bos) {
      onOpenChange(false)
      return
    }
    setCalisiyor(true)
    try {
      if (s.plaka !== null) {
        await plakaDuzelt.mutateAsync({ bilet_id: bilet.id, plaka: s.plaka })
        const plaka = s.plaka
        setBas((b) => ({ ...b, plaka }))
      }
      if (s.girisISO !== null) {
        await girisDuzelt.mutateAsync({
          bilet_id: bilet.id,
          giris_at: s.girisISO,
          sebep: s.sebep ?? '',
        })
        const girisYerel = taslak.girisYerel
        setBas((b) => ({ ...b, girisYerel }))
      }
      // Last, and local: it only takes effect when the car is let out, so it
      // must not be applied if a server step above failed.
      if (s.ucretKurus !== null && ucret) ucret.onUygula(s.ucretKurus, s.sebep ?? '')
      onOpenChange(false)
    } catch (e) {
      setHata(rpcErrorText(e, 'Değişiklik kaydedilemedi.'))
    } finally {
      setCalisiyor(false)
    }
  }

  return (
    <FormModal
      open
      onOpenChange={onOpenChange}
      title="Bileti değiştir"
      submitLabel="Kaydet"
      loading={calisiyor}
      error={hata}
      onSubmit={() => void kaydet()}
    >
      {/* Words, not the "34ABC123" example: on a ticket screen a grey sample
          plate would read as what the camera saw (see PlakaInput). */}
      <PlakaInput
        value={taslak.plaka}
        onChange={(v) => set({ plaka: v })}
        error={hataOf('plaka')}
        placeholder="Plakayı yazın"
      />

      {/* No min/max attributes on purpose: the browser enforces them on submit
          with its own English tooltip, and a `max` fixed when the form opened
          would reject "now" a minute later. The rules live in degistir.ts and
          answer in Turkish; the server re-checks them. */}
      <Input
        label="Giriş tarihi ve saati"
        type="datetime-local"
        // The calendar icon and the picker are drawn by the browser, in the
        // page's colour scheme — "light" unless told otherwise, which left a
        // dark glyph on the dark field. Scoped to this field on purpose.
        className="tnum dark:[color-scheme:dark]"
        value={taslak.girisYerel}
        onChange={(e) => set({ girisYerel: e.target.value })}
        error={hataOf('giris')}
        hint="İstanbul saati. Değişirse ücret yeniden hesaplanır."
      />

      {ucret ? (
        <Input
          label="Ücret (₺)"
          value={taslak.ucretMetni}
          onChange={(e) => set({ ucretMetni: e.target.value })}
          inputMode="decimal"
          className="tnum"
          error={hataOf('ucret')}
          hint={
            `Hesaplanan ücret ${formatTL(ucret.hesaplanan)}.` +
            (bilet.indirim_kurus > 0
              ? ` Kullanılan puan (−${formatTL(bilet.indirim_kurus)}) bundan ayrıca düşülür.`
              : '')
          }
        />
      ) : ucretNotu ? (
        <p className="text-label text-faint">{ucretNotu}</p>
      ) : null}

      <Input
        label="Sebep"
        value={taslak.sebep}
        onChange={(e) => set({ sebep: e.target.value })}
        maxLength={200}
        placeholder="Örn. kamera geç okudu, müşteri itirazı"
        error={hataOf('sebep')}
        hint={
          // A Yönetici is not notified of their own change (notify_yonetici
          // excludes the caller), so promising them a notification is false.
          yonetici
            ? 'Saat ya da ücret değişirse zorunlu — denetim kaydına yazılır.'
            : 'Saat ya da ücret değişirse zorunlu — Yöneticiye bildirilir.'
        }
      />
    </FormModal>
  )
}

/**
 * The two ways to undo a ticket, with their confirmations.
 *
 * A hook rather than a component, because the caller decides WHERE the
 * triggers sit — a header icon on the detail screen, a panel header inside
 * Tahsilat — while the dialogs, the mutations and the error handling stay in
 * one place. Render `dialoglar` once, anywhere in the caller's tree.
 */
export function useBiletAksiyonlari(
  bilet: Bilet | undefined,
  { onSilindi }: { onSilindi?: () => void } = {},
) {
  const yonetici = isYonetici(useAuth().profile)
  const iptal = useBiletIptal()
  const sil = useBiletSil()

  const [iptalAcik, setIptalAcik] = useState(false)
  const [sebep, setSebep] = useState('')
  const [iptalHata, setIptalHata] = useState<string | null>(null)
  const [silAcik, setSilAcik] = useState(false)
  const [silHata, setSilHata] = useState<string | null>(null)

  const dialoglar: ReactNode = bilet ? (
    <>
      <ConfirmDialog
        open={silAcik}
        onOpenChange={setSilAcik}
        tone="danger"
        title="Bileti sil"
        description={
          bilet.tahsil_kurus > 0
            ? "Bu bilet ve tahsil edilen tutar silinecek; ilgili vardiyanın kasa farkı yeniden hesaplanır. Kayıt Çöp Kutusu'ndan geri alınabilir."
            : "Bu bilet silinecek. Çöp Kutusu'ndan geri alınabilir."
        }
        confirmLabel="Sil"
        loading={sil.isPending}
        error={silHata}
        onConfirm={() => {
          void sil
            .mutateAsync(bilet.id)
            .then(() => {
              setSilAcik(false)
              onSilindi?.()
            })
            .catch((e) => setSilHata(rpcErrorText(e, 'Bilet silinemedi.')))
        }}
      />

      <ConfirmDialog
        open={iptalAcik}
        onOpenChange={setIptalAcik}
        tone="danger"
        // 050: a Personel does not cancel, they ASK — the server files a
        // request and the ticket stays open. Saying "iptal edilecek" to them
        // would describe something that does not happen.
        title={yonetici ? 'Bileti iptal et' : 'İptal iste'}
        description={
          yonetici
            ? (bilet.durum === 'KAPALI'
                ? 'Tahsil edilen tutar için ters kayıt yazılır. İşlem geri alınamaz'
                : 'Bu bilet iptal edilecek. İşlem geri alınamaz') +
              // A Yönetici is not notified of their own cancellation —
              // notify_yonetici excludes auth.uid() — so the audit row is the
              // sentence that is true here.
              ' ve denetim kaydına yazılır.'
            : 'İptal isteği Yönetici onayına gönderilir. Onaylanana kadar bilet açık kalır.'
        }
        confirmLabel={yonetici ? 'İptal Et' : 'İsteği Gönder'}
        cancelLabel="Vazgeç"
        loading={iptal.isPending}
        error={iptalHata}
        onConfirm={() => {
          if (!sebep.trim()) {
            setIptalHata('İptal sebebi zorunludur.')
            return
          }
          void iptal
            .mutateAsync({ bilet_id: bilet.id, sebep: sebep.trim() })
            .then(() => setIptalAcik(false))
            .catch((e) =>
              setIptalHata(
                rpcErrorText(e, yonetici ? 'Bilet iptal edilemedi.' : 'İptal isteği gönderilemedi.'),
              ),
            )
        }}
      >
        <Input
          label="İptal sebebi"
          value={sebep}
          onChange={(e) => setSebep(e.target.value)}
          placeholder="Örn. yanlış plaka girildi"
          maxLength={200}
        />
      </ConfirmDialog>
    </>
  ) : null

  // 050: a request already waiting on this ticket. A second one is refused by
  // the server; the button says so instead of offering it.
  const iptalBekliyor = Boolean(bilet?.iptal_talebi_at)

  return {
    /** Delete is Yönetici-only in the RPC; this only hides a doomed control. */
    silinebilir: yonetici,
    /** What the İptal button says for this person (050: Personel asks). */
    iptalEtiketi: yonetici
      ? 'Bileti İptal Et'
      : iptalBekliyor
        ? 'İptal onayı bekliyor'
        : 'İptal İste',
    /** True only for a Personel whose request is already waiting. */
    iptalKapali: !yonetici && iptalBekliyor,
    iptalAc: () => {
      setSebep('')
      setIptalHata(null)
      setIptalAcik(true)
    },
    silAc: () => {
      setSilHata(null)
      setSilAcik(true)
    },
    dialoglar,
  }
}

/** The İptal trigger, identical wherever it appears. */
export function IptalButonu({
  onClick,
  size,
  etiket = 'Bileti İptal Et',
  disabled = false,
}: {
  onClick: () => void
  size?: 'lg'
  /** From useBiletAksiyonlari: a Personel ASKS (050), so their label differs. */
  etiket?: string
  disabled?: boolean
}) {
  return (
    <Button variant="danger" size={size} block onClick={onClick} disabled={disabled}>
      {etiket}
    </Button>
  )
}

/**
 * 050: a Personel's cancel request is waiting for a Yönetici. Shown on the
 * ticket screens so nobody mistakes the still-open ticket for a cancel that
 * did not happen.
 */
export function IptalTalebiNotu({ sebep }: { sebep?: string | null }) {
  return (
    <div className="rounded-field bg-warn-soft px-4 py-3">
      <p className="text-body font-semibold text-warn">İptal onayı bekliyor</p>
      {sebep && <p className="mt-0.5 text-label text-warn">{sebep}</p>}
    </div>
  )
}

/* ==================================================== customer details === */

export interface EkBilgiler {
  arac: string
  ad: string
  tel: string
  not: string
}

export const BOS_EK_BILGI: EkBilgiler = { arac: '', ad: '', tel: '', not: '' }

/** What the RPCs want: trimmed, blank collapsed to null, phone normalised. */
export function ekBilgiGonder(m: EkBilgiler) {
  return {
    arac_bilgi: m.arac.trim() || null,
    musteri_ad: m.ad.trim() || null,
    musteri_tel: normalizeTel(m.tel) || null,
    notlar: m.not.trim() || null,
  }
}

/** Reads a ticket back into the form. Inverse of `ekBilgiGonder`. */
export function ekBilgiAlanlari(bilet: Bilet): EkBilgiler {
  return {
    arac: bilet.arac_bilgi ?? '',
    ad: bilet.musteri_ad ?? '',
    tel: bilet.musteri_tel ?? '',
    not: bilet.notlar ?? '',
  }
}

/**
 * The three optional fields, identical at the barrier and at the till.
 *
 * Shared rather than written twice because the two screens must normalise the
 * same way: a number typed at entry and the same number corrected at
 * collection have to end up as the same ten digits, or the app would disagree
 * with itself about whether anything changed. `bilet_ac` and
 * `bilet_musteri_guncelle` run that same normalisation again server-side —
 * this is convenience, never the boundary.
 *
 * The phone strips its own trunk prefix as you type, so the only way to be
 * invalid is to stop short of ten digits; the caller checks
 * `telGonderilebilir` before submitting and shows `telHatasi`. Not
 * `telGecerli` — the field is optional, and an empty one must pass.
 */
export function EkBilgiFormu({
  deger,
  onChange,
  telHatasi,
}: {
  deger: EkBilgiler
  onChange: (m: EkBilgiler) => void
  telHatasi?: string | null
}) {
  const set = (yama: Partial<EkBilgiler>) => onChange({ ...deger, ...yama })
  // The Input primitive generates its own id; a raw textarea needs one to be
  // reachable by its label, which is the bug that made every labelled field in
  // the app anonymous until Input got the same treatment.
  const notId = useId()

  return (
    <div className="space-y-3">
      <Input
        label="Araç marka model"
        value={deger.arac}
        onChange={(e) => set({ arac: e.target.value })}
        maxLength={60}
        autoCapitalize="words"
      />
      <div className="grid gap-3 md:grid-cols-2">
        <Input
          label="Müşteri adı"
          value={deger.ad}
          onChange={(e) => set({ ad: e.target.value })}
          maxLength={80}
          autoCapitalize="words"
        />
        <Input
          label="Müşteri numarası"
          value={deger.tel}
          // Normalised on the way IN, so an operator who types the way people
          // dictate a number ("0532…") never sees it rejected afterwards.
          onChange={(e) => set({ tel: normalizeTel(e.target.value) })}
          inputMode="tel"
          autoComplete="tel"
          maxLength={10}
          className="tnum"
          error={telHatasi}
          hint={deger.tel && !telHatasi ? formatTel(deger.tel) : undefined}
        />
      </div>

      {/* A textarea, not an Input: the other three are one value each, this is
          whatever the operator needs to remember about the visit — "ön tampon
          çizik", "anahtarı bizde". Three rows is enough to see a sentence
          without pushing the rest of the form off a phone screen. */}
      <div>
        <Label htmlFor={notId}>
          <span className="inline-flex items-center gap-1.5">
            <IconNot size={14} className="text-danger" />
            Not
          </span>
        </Label>
        <textarea
          id={notId}
          value={deger.not}
          onChange={(e) => set({ not: e.target.value })}
          maxLength={500}
          rows={3}
          className="w-full resize-y rounded-field border border-border bg-field px-4 py-3 text-body text-ink outline-none focus:border-accent"
        />
      </div>
    </div>
  )
}
