import { useEffect, useMemo, useRef, useState } from 'react'
import { Button, Card, Input, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Toggle } from '../../components/ui/Toggle'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { Spinner } from '../../components/ui/Spinner'
import { useAyarlar } from '../gise/api'
import { useTumParkYerleri, useYerDuzeniUret, type YerDuzeniSonuc } from '../yerler/api'
import { useAyarGuncelle } from './api'
import { digitsOnly } from '../../lib/money'
import { rpcErrorText } from '../../lib/errors'
import { YER_GRUPLARI, kodAraligi, yerDegisimi, yerDuzeni } from '../../lib/yerkodu'
import type { YerGrup } from '../../lib/yerkodu'
import type { PlakaSaglayici } from '../../lib/types'

/** What pressing Kaydet will do to the layout, in one line. */
function degisimMetni(d: { eklenecek: number; kapanacak: number }): string {
  const p: string[] = []
  if (d.eklenecek > 0) p.push(`${d.eklenecek} yer eklenecek`)
  if (d.kapanacak > 0) p.push(`${d.kapanacak} yer kapatılacak`)
  if (p.length === 0) return 'Yerler zaten bu düzende.'
  return d.kapanacak > 0
    ? `${p.join(' · ')} — kapatılan yer silinmez, kapasiteyi büyütünce geri gelir.`
    : p.join(' · ')
}

/** Settings read back as words, so the confirmation lists a change, not a number. */
// 0 is out of range since 024, but a row written before it can still hold one.
const gunMetni = (g: number) => (g > 0 ? `${g} gün` : 'kapalı')
const acikKapali = (v: boolean) => (v ? 'açık' : 'kapalı')

/**
 * What it actually did. Reported even when nothing changed, so a no-op run
 * reads as "already correct" rather than as a button that did nothing.
 */
function sonucMetni(s: YerDuzeniSonuc): string {
  const p: string[] = []
  if (s.eklenen > 0) p.push(`${s.eklenen} yer eklendi`)
  if (s.guncellenen > 0) p.push(`${s.guncellenen} yer düzeltildi`)
  if (s.kapanan > 0) p.push(`${s.kapanan} yer kapatıldı`)
  const bas = p.length > 0 ? p.join(' · ') : 'Yer düzeni zaten güncel'
  return `${bas} — şu an ${s.aktif} aktif yer.`
}

export default function OtoparkAyarlari() {
  const { data: ayar, isPending, error, refetch } = useAyarlar()
  const guncelle = useAyarGuncelle()
  // The spot rows themselves are the record of the current layout — there is
  // no second copy of "how many engelli bays are there" to drift from them.
  const { data: yerler, isPending: yerPending, error: yerError } = useTumParkYerleri()
  const yerUret = useYerDuzeniUret()

  const [ad, setAd] = useState('')
  const [kapasite, setKapasite] = useState('')
  const [engelli, setEngelli] = useState('')
  const [rezerve, setRezerve] = useState('')
  const [digerKapat, setDigerKapat] = useState(false)
  const [yerSonuc, setYerSonuc] = useState<YerDuzeniSonuc | null>(null)
  const [saklama, setSaklama] = useState('')
  const [terk, setTerk] = useState('')
  const [dolulukUyari, setDolulukUyari] = useState('')
  const [vardiyaEsik, setVardiyaEsik] = useState('')
  const [saglayici, setSaglayici] = useState<PlakaSaglayici>('KAPALI')
  const [model, setModel] = useState('')
  const [kameraAktif, setKameraAktif] = useState(false)
  const [gecikme, setGecikme] = useState('')
  const [onayAcik, setOnayAcik] = useState(false)
  const [hata, setHata] = useState<string | null>(null)
  const [kaydedildi, setKaydedildi] = useState(false)

  // Hydrate once the row arrives. The early return below guarantees the form
  // is never drawn before this runs.
  useEffect(() => {
    if (!ayar) return
    setAd(ayar.ad)
    setKapasite(String(ayar.kapasite))
    setSaklama(String(ayar.foto_saklama_gun))
    setTerk(String(ayar.terk_esik_saat))
    setDolulukUyari(String(ayar.doluluk_uyari_yuzde))
    // ?? : the column arrives with 025. Reading it before the migration has
    // run must not put the string "undefined" into the field.
    setVardiyaEsik(String(ayar.vardiya_esik_saat ?? 16))
    setSaglayici(ayar.plaka_saglayici)
    setModel(ayar.plaka_model ?? '')
    setKameraAktif(ayar.kamera_aktif)
    setGecikme(String(ayar.kamera_gecikme_limiti_dk))
  }, [ayar])

  /**
   * Spot counts come from the spots, and are hydrated ONCE.
   *
   * Re-running on every refetch would overwrite whatever the user is typing
   * the moment another query settled. The ref, not a `yerler`-keyed effect:
   * after a save the rows change, and the numbers on screen are already the
   * ones that produced them.
   */
  const yerlerHazir = !yerPending && !yerError && yerler !== undefined
  const mevcutDuzen = useMemo(() => yerDuzeni(yerler ?? []), [yerler])
  const yerHidrate = useRef(false)
  useEffect(() => {
    if (!yerlerHazir || yerHidrate.current) return
    yerHidrate.current = true
    setEngelli(String(mevcutDuzen.engelli))
    setRezerve(String(mevcutDuzen.rezerve))
  }, [yerlerHazir, mevcutDuzen])

  // Normal is what is LEFT, not a fourth field: the three groups have to add up
  // to the capacity occupancy is measured against, and asking for all three
  // separately is asking for a total that disagrees with it.
  const kapasiteSayi = Number(kapasite) || 0
  const engelliSayi = Number(engelli) || 0
  const rezerveSayi = Number(rezerve) || 0
  const ozelSayi = engelliSayi + rezerveSayi
  const normalSayi = Math.max(0, kapasiteSayi - ozelSayi)
  const grupAdedi: Record<YerGrup, number> = {
    NORMAL: normalSayi,
    ENGELLI: engelliSayi,
    REZERVE: rezerveSayi,
  }
  const degisim = useMemo(
    () =>
      yerDegisimi(yerler ?? [], {
        normal: normalSayi,
        engelli: engelliSayi,
        rezerve: rezerveSayi,
      }),
    [yerler, normalSayi, engelliSayi, rezerveSayi],
  )

  /**
   * ⚠ Never render the form over a failed load.
   *
   * If the query errors and we draw the inputs at their empty defaults, the
   * first Save silently overwrites real settings with blanks — and the user,
   * seeing an empty form, reasonably concludes the data was deleted. Fail
   * loudly instead.
   */
  if (isPending) {
    return (
      <div className="py-20">
        <Spinner label="Ayarlar yükleniyor" />
      </div>
    )
  }
  if (error || !ayar) {
    return (
      <div className="px-5">
        <ScreenHeader title="Otopark Ayarları" back="/yonetim" />
        <LoadError error={error} onRetry={() => void refetch()} />
      </div>
    )
  }

  /**
   * Everything Kaydet is about to write, in ONE object.
   *
   * Built here rather than inside kaydet() so the confirmation screen and the
   * mutation read the same values. A dialog that lists one thing while the
   * save writes another is worse than no dialog at all.
   */
  const yeniAyar = {
    ad: ad.trim() || 'Otopark',
    kapasite: kapasiteSayi,
    foto_saklama_gun: Number(saklama) || 0,
    terk_esik_saat: Number(terk) || 48,
    doluluk_uyari_yuzde: Number(dolulukUyari) || 90,
    vardiya_esik_saat: Number(vardiyaEsik) || 16,
    plaka_saglayici: saglayici,
    plaka_model: model.trim() || null,
    kamera_aktif: kameraAktif,
    kamera_gecikme_limiti_dk: Number(gecikme) || 720,
  }

  // The only irreversible-feeling part of this screen: bays leaving service.
  const kapanacakYer = yerlerHazir
    ? degisim.kapanacak + (digerKapat ? mevcutDuzen.digerleri.length : 0)
    : 0

  /**
   * The diff, in the operator's words.
   *
   * Only rows that actually change are listed — a confirmation that repeats
   * every setting is one nobody reads, and an unread warning is the same as
   * no warning.
   */
  const degisimListesi: string[] = []
  const fark = (etiket: string, eski: string | number, yeni: string | number) => {
    if (String(eski) !== String(yeni)) degisimListesi.push(`${etiket}: ${eski} → ${yeni}`)
  }
  fark('Ad', ayar.ad, yeniAyar.ad)
  fark('Kapasite', ayar.kapasite, yeniAyar.kapasite)
  fark('Doluluk uyarısı', `%${ayar.doluluk_uyari_yuzde}`, `%${yeniAyar.doluluk_uyari_yuzde}`)
  fark('Terk süresi', `${ayar.terk_esik_saat} saat`, `${yeniAyar.terk_esik_saat} saat`)
  fark(
    'Vardiya kapanma eşiği',
    `${ayar.vardiya_esik_saat} saat`,
    `${yeniAyar.vardiya_esik_saat} saat`,
  )
  fark('Fotoğraf saklama', gunMetni(ayar.foto_saklama_gun), gunMetni(yeniAyar.foto_saklama_gun))
  fark(
    'Plaka okuma',
    acikKapali(ayar.plaka_saglayici !== 'KAPALI'),
    acikKapali(yeniAyar.plaka_saglayici !== 'KAPALI'),
  )
  fark('Kamera girişi', acikKapali(ayar.kamera_aktif), acikKapali(yeniAyar.kamera_aktif))
  if (yeniAyar.kamera_aktif) {
    fark(
      'Kamera gecikme sınırı',
      `${ayar.kamera_gecikme_limiti_dk} dk`,
      `${yeniAyar.kamera_gecikme_limiti_dk} dk`,
    )
  }
  if (yerlerHazir && (degisim.eklenecek > 0 || degisim.kapanacak > 0)) {
    degisimListesi.push(degisimMetni(degisim))
  }
  if (yerlerHazir && digerKapat && mevcutDuzen.digerleri.length > 0) {
    degisimListesi.push(`Düzen dışı ${mevcutDuzen.digerleri.length} yer kapatılacak`)
  }

  /** The single validation site: the dialog never promises a save that cannot happen. */
  function dogrula(): string | null {
    if (kapasiteSayi < 1) return 'Kapasite en az 1 olmalı.'
    // Mirrors the RPC's own ceiling, so the limit is explained here instead of
    // arriving as a rejection after the settings have already been written.
    if (kapasiteSayi > 2000) {
      return 'Kapasite en fazla 2000 olabilir — yerler bu sayıdan üretiliyor.'
    }
    if (ozelSayi > kapasiteSayi) return 'Engelli ve rezerve yer sayısı kapasiteyi aşamaz.'
    // Mirrors the CHECK added in 024. Storage is finite and a plate photo is
    // personal data, so "keep forever" is not an option the screen offers.
    const gun = Number(saklama) || 0
    if (gun < 1 || gun > 30) return 'Fotoğraf saklama süresi 1-30 gün arasında olmalı.'
    // Mirrors the CHECK in 025. Below 4 hours a normal shift would be closed
    // out from under an operator who is still working.
    const esik = Number(vardiyaEsik) || 0
    if (esik < 4 || esik > 72) return 'Vardiya kapanma eşiği 4-72 saat arasında olmalı.'
    return null
  }

  function kaydetOnayla() {
    setYerSonuc(null)
    const sorun = dogrula()
    setHata(sorun)
    if (sorun) return
    setOnayAcik(true)
  }

  /** Runs only from the confirmation dialog — dogrula() has already passed. */
  async function kaydet() {
    setHata(null)
    try {
      await guncelle.mutateAsync(yeniAyar)
    } catch (err) {
      setHata(rpcErrorText(err, 'Ayarlar kaydedilemedi.'))
      return
    }

    /**
     * The layout runs SECOND, and only over spot data that actually loaded.
     *
     * If the spot query failed we would be reading zeroes for engelli and
     * rezerve, and "apply zero" is a request to retire every E and R bay in
     * the lot. Skipping is the safe half of the save; the settings above are
     * already stored either way.
     *
     * A failure here is reported rather than retried: the RPC is idempotent,
     * so pressing Kaydet again finishes the job with no risk of doing it
     * twice — which is exactly why it is safe to bundle into this button.
     */
    if (yerlerHazir) {
      try {
        setYerSonuc(
          await yerUret.mutateAsync({
            normal: normalSayi,
            engelli: engelliSayi,
            rezerve: rezerveSayi,
            digerlerini_kapat: digerKapat,
          }),
        )
        setDigerKapat(false)
      } catch (err) {
        setHata(
          rpcErrorText(
            err,
            "Ayarlar kaydedildi, park yerleri güncellenemedi. Kaydet'e tekrar basın.",
          ),
        )
        return
      }
    } else if (yerError) {
      setHata('Ayarlar kaydedildi. Park yerleri okunamadığı için düzen uygulanmadı.')
      return
    }

    setOnayAcik(false)
    setKaydedildi(true)
    setTimeout(() => setKaydedildi(false), 2500)
  }

  return (
    <div>
      <ScreenHeader title="Otopark Ayarları" back="/yonetim" />

      <div className="space-y-4 px-5">
        <Card className="space-y-4">
          <p className="text-label font-medium tracking-wide text-faint uppercase">Otopark</p>
          <Input label="Ad" value={ad} onChange={(e) => setAd(e.target.value)} maxLength={80} />
          <Input
            label="Doluluk uyarısı (%)"
            value={dolulukUyari}
            onChange={(e) => setDolulukUyari(digitsOnly(e.target.value, 3))}
            inputMode="numeric"
            hint="Bu orana ulaşınca bildirim gönderilir."
          />
          <Input
            label="Terk edilmiş sayılma süresi (saat)"
            value={terk}
            onChange={(e) => setTerk(digitsOnly(e.target.value, 3))}
            inputMode="numeric"
          />
          <Input
            label="Vardiya kapanma eşiği (saat)"
            value={vardiyaEsik}
            onChange={(e) => setVardiyaEsik(digitsOnly(e.target.value, 2))}
            inputMode="numeric"
            hint="Bu kadar süredir açık kalan vardiya otomatik kapatılır — nakit sayılmadan, fark boş bırakılarak. Yoksa personel bir daha vardiya açamaz."
          />
        </Card>

        {/* Capacity lives here, not with the name, because it is no longer just
            a number occupancy is divided by — it is the input the bays are
            generated from, and the preview underneath is what it produces. */}
        <Card className="space-y-4">
          <p className="text-label font-medium tracking-wide text-faint uppercase">
            Park yerleri
          </p>
          <Input
            label="Kapasite"
            value={kapasite}
            onChange={(e) => setKapasite(digitsOnly(e.target.value, 4))}
            inputMode="numeric"
            hint="Yerler bu sayıdan üretilir. Engelli ve rezerve dışında kalanlar normal yer olur."
          />
          <div className="grid grid-cols-2 gap-3">
            <Input
              label="Engelli yer"
              value={engelli}
              onChange={(e) => setEngelli(digitsOnly(e.target.value, 4))}
              inputMode="numeric"
            />
            <Input
              label="Rezerve yer"
              value={rezerve}
              onChange={(e) => setRezerve(digitsOnly(e.target.value, 4))}
              inputMode="numeric"
            />
          </div>

          {yerPending && <p className="text-label text-faint">Yerler yükleniyor…</p>}

          {/* Same rule as the settings form above: never let a failed load look
              like empty data. Zero engelli bays is a request to retire every one
              of them, so the preview and the layout write both stand down. */}
          {yerError != null && (
            <p className="rounded-field bg-warn-soft px-3.5 py-3 text-label text-warn">
              Park yerleri okunamadı. Kaydet ayarları yazar, yer düzenine dokunmaz.
            </p>
          )}

          {yerlerHazir &&
            (ozelSayi > kapasiteSayi ? (
              <p className="rounded-field bg-danger-soft px-3.5 py-3 text-label text-danger">
                Engelli ve rezerve yer sayısı kapasiteyi aşıyor.
              </p>
            ) : (
              <div className="space-y-2.5 rounded-field bg-field px-3.5 py-3">
                {YER_GRUPLARI.map((g) => (
                  <div key={g.grup} className="flex items-baseline justify-between gap-3">
                    <span className="shrink-0 text-label text-soft">
                      {g.etiket}
                      <span className="text-faint"> · {grupAdedi[g.grup]}</span>
                    </span>
                    <span className="truncate text-label font-medium text-ink tnum">
                      {kodAraligi(g.onek, grupAdedi[g.grup]) ?? '—'}
                    </span>
                  </div>
                ))}
                <p
                  className={`border-t border-border pt-2.5 text-label ${
                    degisim.kapanacak > 0 ? 'text-warn' : 'text-faint'
                  }`}
                >
                  {degisimMetni(degisim)}
                </p>
              </div>
            ))}

          {/* Opt-in, and only shown when there is something to opt into. The
              generator owns P/E/R and nothing else, so the sample rows from the
              seed — and any bay added by hand — survive until asked about. */}
          {yerlerHazir && mevcutDuzen.digerleri.length > 0 && (
            <Toggle
              checked={digerKapat}
              onChange={setDigerKapat}
              label={`Düzen dışı ${mevcutDuzen.digerleri.length} yeri kapat`}
              hint={`${mevcutDuzen.digerleri
                .slice(0, 6)
                .map((y) => y.kod)
                .join(', ')}${
                mevcutDuzen.digerleri.length > 6 ? '…' : ''
              } — silinmez, yalnızca kullanım dışına alınır.`}
            />
          )}

          {yerSonuc && (
            <div className="space-y-1">
              <p className="text-label text-success">{sonucMetni(yerSonuc)}</p>
              {yerSonuc.atlanan.length > 0 && (
                <p className="text-label text-warn">
                  Aracı ya da rezervasyonu olduğu için kapatılmadı:{' '}
                  <span className="tnum">{yerSonuc.atlanan.join(', ')}</span>
                </p>
              )}
            </div>
          )}
        </Card>

        <Card className="space-y-4">
          <p className="text-label font-medium tracking-wide text-faint uppercase">
            Fotoğraf saklama (KVKK)
          </p>
          <Input
            label="Saklama süresi (gün)"
            value={saklama}
            onChange={(e) => setSaklama(digitsOnly(e.target.value, 2))}
            inputMode="numeric"
            hint="Plaka fotoğrafları bu süre sonunda gece işiyle silinir. 1-30 gün — depolama alanı sınırlı."
          />
        </Card>

        <Card className="space-y-4">
          <p className="text-label font-medium tracking-wide text-faint uppercase">Plaka okuma</p>
          <Toggle
            checked={saglayici !== 'KAPALI'}
            onChange={(v) => setSaglayici(v ? 'VLM' : 'KAPALI')}
            label="Plaka okuma açık"
            hint="Fotoğraftan plaka önerilir. Kapalıyken kamera yalnızca fotoğraf çeker."
          />
          <p className="text-label text-faint">
            Okuma her zaman bir <strong className="text-soft">öneridir</strong> — operatör
            onaylamadan hiçbir kayıt oluşmaz.
          </p>
        </Card>

        <Card className="space-y-4">
          <p className="text-label font-medium tracking-wide text-faint uppercase">Kamera</p>
          <Toggle
            checked={kameraAktif}
            onChange={setKameraAktif}
            label="Kamera girişi açık"
            hint="Kapalıyken webhook hiçbir olayı kabul etmez."
          />
          {kameraAktif && (
            <>
              <Input
                label="Gecikme sınırı (dakika)"
                value={gecikme}
                onChange={(e) => setGecikme(digitsOnly(e.target.value, 5))}
                inputMode="numeric"
                hint="Bundan eski kamera olayı bilete dönüşmez, istisna olarak işaretlenir."
              />
              <p className="rounded-field bg-warn-soft px-3 py-2.5 text-label text-warn">
                Kameranın saatini NTP'ye bağlayın. Bir saat kaymış kamera her aracı
                sessizce yanlış ücretlendirir.
              </p>
            </>
          )}
        </Card>


        {/* While a dialog is open the same message is shown INSIDE it, next to
            the button that failed. Repeating it behind the overlay would just
            be a second copy the user cannot see. */}
        {hata && !onayAcik && (
          <p role="alert" className="rounded-card bg-danger-soft px-4 py-3 text-body text-danger">
            {hata}
          </p>
        )}

        <div className="safe-bottom flex items-center gap-3 pt-2">
          {/* Disabled rather than left to fail on press: kaydet() validates
              this first and writes nothing, so the button could only ever
              bounce, and the reason is already stated up beside the fields. */}
          <Button
            size="lg"
            block
            onClick={kaydetOnayla}
            loading={guncelle.isPending || yerUret.isPending}
            disabled={ozelSayi > kapasiteSayi}
          >
            Kaydet
          </Button>
        </div>
        {kaydedildi && <p className="pb-4 text-center text-label text-success">Kaydedildi</p>}
      </div>

      {/* The confirmation is a diff, not a rhetorical question. "Emin misiniz?"
          trains people to tap through; a list of what is about to change is
          the only version that can actually catch a mistyped capacity. It
          stays open on a server refusal so the Turkish message is read. */}
      <ConfirmDialog
        open={onayAcik}
        onOpenChange={setOnayAcik}
        title="Değişiklikleri kaydet"
        description={
          degisimListesi.length === 0
            ? 'Kaydedilecek bir değişiklik görünmüyor.'
            : 'Kaydedince şunlar uygulanacak:'
        }
        confirmLabel={degisimListesi.length === 0 ? 'Yine de kaydet' : 'Kaydet'}
        tone={kapanacakYer > 0 ? 'danger' : 'primary'}
        loading={guncelle.isPending || yerUret.isPending}
        error={hata}
        onConfirm={() => void kaydet()}
      >
        {degisimListesi.length > 0 && (
          <ul className="space-y-2 rounded-field bg-field px-3.5 py-3">
            {degisimListesi.map((d) => (
              <li key={d} className="text-body text-ink">
                {d}
              </li>
            ))}
          </ul>
        )}
        {kapanacakYer > 0 && (
          <p className="mt-3 rounded-field bg-warn-soft px-3.5 py-3 text-label text-warn">
            {kapanacakYer} park yeri kullanım dışına alınacak. Silinmez — kapasiteyi
            büyütünce geri gelir.
          </p>
        )}
      </ConfirmDialog>

    </div>
  )
}
