import { useId, useState, type ReactNode } from 'react'
import { Button, Chip, IconTile, Input, Label } from '../../components/ui/primitives'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { useBiletIptal, useFotoUrl } from './api'
import { useBiletSil } from '../cop/api'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'
import { formatTam } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { formatPlaka } from '../../lib/plaka'
import { formatTel, normalizeTel } from '../../lib/telefon'
import { formatGoreceli } from '../../lib/dates'
import { formatTL } from '../../lib/money'
import { sureMetni } from '../../lib/sure'
import { biletBorcu, odemeAlindi } from '../../lib/bilet'
import {
  ODEME_CHIP,
  ODEME_DURUM_ETIKET,
  ODEME_ETIKET,
  ONAY_CHIP,
  ONAY_ETIKET,
  type AcikBilet,
  type Bilet,
  type OnayDurum,
} from '../../lib/types'
import {
  IconAraba,
  IconCikis,
  IconKamera,
  IconNot,
  IconUyari,
} from '../../components/ui/icons'

/**
 * One row in the open-vehicles list.
 *
 * Hierarchy by de-emphasis: the plate is the only thing at full contrast
 * because it is the only thing an operator scans for. Entry time and duration
 * step down to `text-faint`, and there are no labels on either — a duration
 * looks like a duration.
 *
 * The state chip sits on the SECOND line, not beside the plate. Both lists
 * render together under "Tümü", so a row has to say which of them it belongs
 * to — but "Ödeme alınmadı" beside a plate and an Abonman chip overflows a
 * 375px row, and the thing that would give way is the plate.
 */
export function BiletKart({
  bilet,
  yerKod,
  onClick,
}: {
  bilet: AcikBilet
  /** Looked up by the list, not here: fifty cards must not mean fifty
   *  subscriptions to the same cached spot query. */
  yerKod?: string | null
  onClick: () => void
}) {
  // The tile colour carries the row's state, so a scanning eye sorts the list
  // before reading a single word. "Kapıda" wins over "Abonman": a car waiting
  // at the barrier is the one that needs attention right now.
  const tone = bilet.cikis_bekliyor_at ? 'accent' : bilet.abonman_id ? 'success' : 'neutral'
  // Points already redeemed come off here as well, the same subtraction the
  // collect screen makes, so the row never quotes more than will be asked for.
  const netKurus = Math.max(0, bilet.ucret_kurus - bilet.indirim_kurus)

  return (
    <button
      type="button"
      onClick={onClick}
      className="flex w-full items-center gap-3.5 rounded-card border border-border bg-surface p-3.5 text-left shadow-card transition-[filter,transform] duration-100 active:scale-[0.99] active:brightness-[0.97]"
    >
      <IconTile tone={tone}>
        <IconAraba size={21} />
      </IconTile>

      <div className="min-w-0 flex-1">
        {/* Line one is the plate and the two numbers worth reading at arm's
            length, and nothing else — so the plate is never what gives way.
            The fee is stacked under the duration because they answer the same
            question ("how long, therefore how much") and because the amount is
            what the operator is about to ask for. It is priced server-side by
            acik_bilet_ara, so it is the same figure the collect screen will
            show rather than a second opinion. */}
        <div className="flex items-baseline gap-3">
          <span className="min-w-0 flex-1 truncate text-lead font-semibold tracking-wide text-ink tnum">
            {formatPlaka(bilet.plaka)}
          </span>
          <span className="shrink-0 text-right">
            <span className="block text-body font-semibold text-ink tnum">
              {sureMetni(bilet.giris_at)}
            </span>
            <span
              className={`block text-label font-medium tnum ${
                bilet.abonman_id ? 'text-success' : 'text-soft'
              }`}
            >
              {bilet.abonman_id ? 'Ücretsiz' : formatTL(netKurus)}
            </span>
          </span>
        </div>

        {/* Line two is every label, then the timestamp. The chips are all
            shrink-0, so what gives way on a full row is the relative time —
            the one part a glance can do without. */}
        <div className="mt-1 flex items-center gap-1.5">
          {/* One state chip, not two: a car at the barrier is also inside, and
              "Kapıda" is the half that needs doing something about. */}
          <Chip size="sm" tone={bilet.cikis_bekliyor_at ? 'accent' : 'neutral'} className="shrink-0">
            {bilet.cikis_bekliyor_at ? 'Kapıda' : 'İçeride'}
          </Chip>
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
          <p className="truncate text-label text-faint">
            {/* One step up in weight from the timestamp beside it and still
                well below the plate: where the car is parked is what someone
                scans this list for, but it must not compete with what the
                row is about. */}
            {yerKod && <span className="font-medium text-soft">{yerKod} · </span>}
            {formatGoreceli(bilet.giris_at)}
            {bilet.gecikmeli_kayit && ' · kameradan'}
          </p>
        </div>
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
  onClick,
  onay = null,
}: {
  bilet: Bilet
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

  return (
    <button
      type="button"
      onClick={onClick}
      className="flex w-full items-center gap-3.5 rounded-card border border-border bg-surface p-3.5 text-left shadow-card transition-[filter,transform] duration-100 active:scale-[0.99] active:brightness-[0.97]"
    >
      <IconTile tone="neutral">
        <IconCikis size={21} />
      </IconTile>

      <div className="min-w-0 flex-1">
        {/* Plate and amount alone on line one — same rule as the open rows. */}
        <div className="flex items-baseline gap-3">
          <span className="min-w-0 flex-1 truncate text-lead font-semibold tracking-wide text-ink tnum">
            {formatPlaka(bilet.plaka)}
          </span>
          <span
            className={`shrink-0 text-body font-semibold tnum ${
              bedava ? 'text-success' : alindi ? 'text-ink' : 'text-warn'
            }`}
          >
            {bedava ? 'Ücretsiz' : formatTL(borc)}
          </span>
        </div>

        {/* Wraps: this row can carry four chips (ödeme, abonman, onay, yöntem)
            plus the time, which at 375px squeezed the timestamp to "2 …".
            Same treatment as the Finans list, which shows the same chips. */}
        <div className="mt-1 flex flex-wrap items-center gap-1.5">
          <Chip
            size="sm"
            tone={alindi ? 'success' : bedava ? 'neutral' : 'warn'}
            className="shrink-0"
          >
            {ODEME_DURUM_ETIKET[alindi ? 'ALINDI' : 'ALINMADI']}
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
          <p className="truncate text-label text-faint">
            {bilet.cikis_at ? formatGoreceli(bilet.cikis_at) : '—'}
            {' · '}
            {sureMetni(bilet.giris_at, bilet.cikis_at)}
          </p>
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
 * The ticket's facts, its warnings and its two undo actions, split so that
 * BOTH the detail screen and the inline panel on Tahsilat can compose them.
 *
 * Shared rather than copied because the two places must never drift: a
 * warning that shows on one and not the other is how an operator collects a
 * fee somebody already flagged.
 */

function Satir({ k, v }: { k: string; v: string }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="shrink-0 text-body text-faint">{k}</dt>
      <dd className="text-right text-body text-ink">{v}</dd>
    </div>
  )
}

/** Everything known about the ticket, as a definition list. */
export function BiletBilgileri({ bilet, yerKod }: { bilet: Bilet; yerKod?: string | null }) {
  return (
    <dl className="space-y-2.5">
      <Satir k="Giriş" v={formatTam(bilet.giris_at)} />
      {bilet.cikis_at && <Satir k="Çıkış" v={formatTam(bilet.cikis_at)} />}
      <Satir k="Süre" v={sureMetni(bilet.giris_at, bilet.cikis_at)} />
      {/* Only while the bay still exists: a retired spot leaves the id on the
          ticket, and "Park yeri —" says less than nothing. */}
      {yerKod && <Satir k="Park yeri" v={yerKod} />}
      {bilet.ucret_kurus > 0 && <Satir k="Ücret" v={formatTL(bilet.ucret_kurus)} />}
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
      <Satir k="Kaynak" v={bilet.giris_kaynak === 'KAMERA' ? 'Kamera' : 'Elle'} />
      {bilet.gecikmeli_kayit && bilet.kaynak_zaman && (
        <Satir
          k="Kameradan gelme"
          v={`${formatGoreceli(bilet.kaynak_zaman)} olayı, sonradan işlendi`}
        />
      )}
      {bilet.abonman_id && <Satir k="Abonman" v="Ücretsiz giriş" />}
      {bilet.kayip_bilet && <Satir k="Kayıp bilet" v="Evet" />}

      {/* Optional (008), so each row appears only when it has something to
          say — a list of empty labels reads as missing data rather than as
          data nobody was asked for. */}
      {bilet.arac_bilgi && <Satir k="Araç" v={bilet.arac_bilgi} />}
      {bilet.musteri_ad && <Satir k="Müşteri" v={bilet.musteri_ad} />}
      {bilet.notlar && (
        <div className="flex items-baseline justify-between gap-3">
          <dt className="shrink-0 text-body text-faint">Not</dt>
          {/* whitespace-pre-line: a note is typed with line breaks and losing
              them turns two remarks into one run-on sentence. */}
          <dd className="text-right text-body whitespace-pre-line text-ink">{bilet.notlar}</dd>
        </div>
      )}
      {bilet.musteri_tel && (
        <div className="flex items-baseline justify-between gap-3">
          <dt className="shrink-0 text-body text-faint">Telefon</dt>
          <dd>
            {/* Tappable: the usual reason to look this up at a barrier is that
                the car is blocking someone and its driver is not in it. */}
            <a
              href={`tel:+90${bilet.musteri_tel}`}
              className="text-body font-medium text-accent tnum underline"
            >
              {formatTel(bilet.musteri_tel)}
            </a>
          </dd>
        </div>
      )}
    </dl>
  )
}

function Foto({ url, etiket }: { url: string; etiket: string }) {
  return (
    <figure>
      <img src={url} alt={`${etiket} fotoğrafı`} className="w-full rounded-card object-cover" />
      <figcaption className="mt-1.5 text-label text-faint">{etiket}</figcaption>
    </figure>
  )
}

/** The flags that change how a ticket should be read, plus its photos. */
export function BiletEkleri({ bilet }: { bilet: Bilet }) {
  const { data: girisFoto } = useFotoUrl(bilet.giris_foto)
  const { data: cikisFoto } = useFotoUrl(bilet.cikis_foto)

  return (
    <>
      {bilet.ucret_degistirildi && (
        <div className="rounded-card bg-warn-soft px-4 py-3">
          <p className="text-body font-medium text-warn">Ücret elle değiştirilmiş</p>
          {bilet.ucret_sebep && (
            <p className="mt-1 text-label text-warn opacity-90">{bilet.ucret_sebep}</p>
          )}
        </div>
      )}

      {bilet.durum === 'IPTAL' && bilet.iptal_sebep && (
        <div className="rounded-card bg-danger-soft px-4 py-3">
          <p className="text-body font-medium text-danger">İptal edildi</p>
          <p className="mt-1 text-label text-danger opacity-90">{bilet.iptal_sebep}</p>
        </div>
      )}

      {(girisFoto || cikisFoto) && (
        <div className="grid grid-cols-2 gap-3">
          {girisFoto && <Foto url={girisFoto} etiket="Giriş" />}
          {cikisFoto && <Foto url={cikisFoto} etiket="Çıkış" />}
        </div>
      )}
    </>
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
        title="Bileti iptal et"
        description={
          (bilet.durum === 'KAPALI'
            ? 'Tahsil edilen tutar için ters kayıt yazılır. İşlem geri alınamaz'
            : 'Bu bilet iptal edilecek. İşlem geri alınamaz') +
          // A Yönetici is not notified of their own cancellation —
          // notify_yonetici excludes auth.uid() — so telling them otherwise is
          // false. The audit row is written for everyone, and that is the
          // sentence that is true in both cases.
          (yonetici ? ' ve denetim kaydına yazılır.' : ' ve Yöneticiye bildirilir.')
        }
        confirmLabel="İptal Et"
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
            .catch((e) => setIptalHata(rpcErrorText(e, 'Bilet iptal edilemedi.')))
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

  return {
    /** Delete is Yönetici-only in the RPC; this only hides a doomed control. */
    silinebilir: yonetici,
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
export function IptalButonu({ onClick, size }: { onClick: () => void; size?: 'lg' }) {
  return (
    <Button variant="danger" size={size} block onClick={onClick}>
      Bileti İptal Et
    </Button>
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
 * One line for a collapsed header — what is on file, or that nothing is.
 *
 * The note goes LAST and only if nothing else is set: it is the one field that
 * can run to 500 characters, and a summary that opens with half a sentence
 * tells you less at a glance than a name does.
 */
export function ekBilgiOzet(m: EkBilgiler): string {
  const parcalar = [m.ad.trim(), m.arac.trim(), formatTel(m.tel)].filter(Boolean)
  if (parcalar.length) return parcalar.join(' · ')
  const not = m.not.trim()
  if (not) return not
  return 'Bilgi eklenmemiş'
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
 * invalid is to stop short of ten digits; the caller checks `telGecerli`
 * before submitting and shows `telHatasi`.
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
