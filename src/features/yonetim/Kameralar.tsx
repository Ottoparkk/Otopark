import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router'
import {
  Button,
  Card,
  Chip,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
  SegmentedControl,
} from '../../components/ui/primitives'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { FormModal } from '../../components/ui/FormModal'
import { IconKamera, IconCop, IconUyari } from '../../components/ui/icons'
import { useAyarlar } from '../gise/api'
import {
  useKameraDurum,
  useKameraEskiKopruUnut,
  useKameraKaldir,
  useKameraKodDurum,
  useKameraKodIptal,
  useKameraKodUret,
  useKameraKodlar,
  useKameralar,
} from './api'
import { SUPABASE_URL } from '../../lib/supabase'
import { formatGoreceli } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { metniIndir, panoyaKopyala } from '../../lib/pano'
import {
  KAMERA_YON_ETIKET,
  type KameraCihaz,
  type KameraYeniKod,
  type KameraYon,
} from '../../lib/types'

const WEBHOOK_URL = `${SUPABASE_URL}/functions/v1/kamera-webhook`

/** A camera that has not connected this long after pairing was abandoned. */
const YARIM_KURULUM_MS = 60 * 60_000

/** Re-renders on a timer so countdowns and "alive" badges stay honest. */
function useSimdi(aralikMs = 1000): number {
  const [simdi, setSimdi] = useState(() => Date.now())
  useEffect(() => {
    const t = setInterval(() => setSimdi(Date.now()), aralikMs)
    return () => clearInterval(t)
  }, [aralikMs])
  return simdi
}

function kalanMetni(bitis: string, simdi: number): string {
  const kalan = Math.floor((new Date(bitis).getTime() - simdi) / 1000)
  if (kalan <= 0) return 'Süresi doldu'
  const dk = Math.floor(kalan / 60)
  const sn = kalan % 60
  return `${dk}:${String(sn).padStart(2, '0')}`
}

/**
 * The badge is the whole point of the screen, so it distinguishes four states
 * rather than two. "Henüz bağlanmadı" and "Yanıt yok" look identical to a
 * watchdog but mean opposite things to whoever is standing at the barrier:
 * one is a setup that never finished, the other is a camera that died.
 */
function durumRozeti(k: KameraCihaz, esikDk: number, simdi: number) {
  if (!k.aktif) return <Chip tone="warn">Devre dışı</Chip>
  if (!k.son_gorulme) return <Chip tone="neutral">Henüz bağlanmadı</Chip>
  const yas = simdi - new Date(k.son_gorulme).getTime()
  return yas < esikDk * 60_000 ? (
    <Chip tone="success">Çalışıyor</Chip>
  ) : (
    <Chip tone="danger">Yanıt yok</Chip>
  )
}

/**
 * Where a setup has got to, from the Yönetici's side of the phone call.
 *
 *   BEKLIYOR   the code is out, nobody has typed it in yet
 *   ESLESTI    the installer exchanged it; the bridge is not running yet
 *   CALISIYOR  first heartbeat seen — the BRIDGE is up. The installer's own
 *              connection test does not count: it sends `x-kamera-deneme` and
 *              the webhook stamps nothing for it.
 *   DOLDU/YOK  the code died unused (expired / cancelled)
 */
type KurulumAdimi = 'BEKLIYOR' | 'ESLESTI' | 'CALISIYOR' | 'DOLDU' | 'YOK'

export default function Kameralar() {
  const simdi = useSimdi()
  const [params] = useSearchParams()
  // Notifications link to /yonetim/kameralar?c=<id>, so the camera the alert
  // is about is the one the eye lands on.
  const vurgu = params.get('c')

  const [ekleAcik, setEkleAcik] = useState(false)
  const [ad, setAd] = useState('')
  const [yon, setYon] = useState<KameraYon>('GIRIS')
  const [yeniKod, setYeniKod] = useState<KameraYeniKod | null>(null)
  const [modalHata, setModalHata] = useState<string | null>(null)

  const { data: ayar, refetch: ayarYenile } = useAyarlar()
  // While a setup is in progress someone is watching for it to land, so the
  // list is asked every few seconds instead of once a minute.
  const kameralar = useKameralar(yeniKod ? 3_000 : 60_000)
  const kodlar = useKameraKodlar()
  const kodDurum = useKameraKodDurum(yeniKod?.id ?? null)

  const kodUret = useKameraKodUret()
  const kodIptal = useKameraKodIptal()
  const kaldir = useKameraKaldir()
  const durum = useKameraDurum()
  const eskiUnut = useKameraEskiKopruUnut()

  const [silinecek, setSilinecek] = useState<KameraCihaz | null>(null)
  const [silHata, setSilHata] = useState<string | null>(null)

  const [eskiSor, setEskiSor] = useState(false)
  const [eskiHata, setEskiHata] = useState<string | null>(null)

  const [kopyalandi, setKopyalandi] = useState<string | null>(null)
  const [sayfaHata, setSayfaHata] = useState<string | null>(null)

  const esikDk = ayar?.kamera_kalp_esik_dk ?? 15

  // The settings query is cached for five minutes everywhere else, which is
  // right for a tariff and wrong for a heartbeat: the hand-installed bridge's
  // badge below is computed from a timestamp inside it.
  useEffect(() => {
    void ayarYenile()
    const t = setInterval(() => void ayarYenile(), 60_000)
    return () => clearInterval(t)
  }, [ayarYenile])

  const kodHali = kodDurum.data?.durum ?? 'BEKLIYOR'
  const eslesenId = kodDurum.data?.durum === 'KULLANILDI' ? kodDurum.data.cihaz_id : null
  const eslesen = eslesenId ? ((kameralar.data ?? []).find((k) => k.id === eslesenId) ?? null) : null
  const adim: KurulumAdimi =
    kodHali === 'KULLANILDI' ? (eslesen?.son_gorulme ? 'CALISIYOR' : 'ESLESTI') : kodHali

  // The moment the code is spent (or dies), the two lists behind the sheet are
  // out of date: a pending code has gone and a camera may have appeared.
  const { refetch: kodlarYenile } = kodlar
  const { refetch: kameralarYenile } = kameralar
  useEffect(() => {
    if (kodHali === 'BEKLIYOR') return
    void kodlarYenile()
    void kameralarYenile()
  }, [kodHali, kodlarYenile, kameralarYenile])

  async function kopyala(anahtar: string, metin: string) {
    const ok = await panoyaKopyala(metin)
    // Only claim success when it happened — see panoyaKopyala.
    if (!ok) {
      setSayfaHata('Kopyalanamadı. Metni seçip elle kopyalayabilirsiniz.')
      return
    }
    setSayfaHata(null)
    setKopyalandi(anahtar)
    setTimeout(() => setKopyalandi(null), 2500)
  }

  function modalKapat() {
    setEkleAcik(false)
    setYeniKod(null)
    setModalHata(null)
    setAd('')
    setYon('GIRIS')
  }

  async function kodOlustur() {
    setModalHata(null)
    if (!ad.trim()) {
      setModalHata('Kameraya bir ad verin.')
      return
    }
    try {
      const sonuc = await kodUret.mutateAsync({ ad: ad.trim(), yon })
      setYeniKod(sonuc)
    } catch (err) {
      setModalHata(rpcErrorText(err, 'Kurulum kodu üretilemedi.'))
    }
  }

  async function kameraSil() {
    if (!silinecek) return
    setSilHata(null)
    try {
      await kaldir.mutateAsync(silinecek.id)
      setSilinecek(null)
    } catch (err) {
      setSilHata(rpcErrorText(err, 'Kamera kaldırılamadı.'))
    }
  }

  async function durumDegistir(k: KameraCihaz) {
    setSayfaHata(null)
    try {
      await durum.mutateAsync({ id: k.id, aktif: !k.aktif })
    } catch (err) {
      setSayfaHata(rpcErrorText(err, 'Kamera durumu değiştirilemedi.'))
    }
  }

  async function kodIptalEt(id: string) {
    setSayfaHata(null)
    try {
      await kodIptal.mutateAsync(id)
    } catch (err) {
      // Was swallowed: a refused cancel left the code in the list with no
      // word about why, and it still counted toward the limit of ten.
      setSayfaHata(rpcErrorText(err, 'Kurulum kodu iptal edilemedi.'))
    }
  }

  async function eskiKopruUnut() {
    setEskiHata(null)
    try {
      await eskiUnut.mutateAsync()
      setEskiSor(false)
    } catch (err) {
      setEskiHata(rpcErrorText(err, 'İşlem yapılamadı.'))
    }
  }

  const kodDosyasi = yeniKod
    ? btoa(JSON.stringify({ WEBHOOK_URL, KOD: yeniKod.kod }))
    : ''

  // The code can still be exchanged again until the camera's first heartbeat
  // (a lost reply must not burn it), so it stays on screen through ESLESTI.
  const kodGorunur = adim === 'BEKLIYOR' || adim === 'ESLESTI'

  const eskiKalp = ayar?.kamera_kalp_atisi ?? null
  const eskiCanli = eskiKalp !== null && simdi - new Date(eskiKalp).getTime() < esikDk * 60_000

  return (
    <div>
      <ScreenHeader title="Kamera Kurulumu" back="/yonetim" />

      <div className="space-y-4 px-5">
        {/* Pairing a camera while the webhook refuses everything is a dead
            end that only shows up at the very last step of the installer. */}
        {ayar && !ayar.kamera_aktif && (
          <p className="flex items-start gap-2.5 rounded-field bg-warn-soft px-3.5 py-3 text-label text-warn">
            <IconUyari size={16} className="mt-0.5 shrink-0" />
            <span>
              Kamera girişi kapalı — eşleştirseniz bile hiçbir olay kabul edilmez.{' '}
              <Link to="/yonetim/ayarlar" className="underline">
                Otopark ayarlarından açın.
              </Link>
            </span>
          </p>
        )}

        {sayfaHata && (
          <p role="alert" className="rounded-card bg-danger-soft px-4 py-3 text-body text-danger">
            {sayfaHata}
          </p>
        )}

        <Card className="space-y-4">
          <div className="flex items-center justify-between gap-3">
            <p className="text-label font-medium tracking-wide text-faint uppercase">Kameralar</p>
            <Button size="md" onClick={() => setEkleAcik(true)}>
              Yeni kamera
            </Button>
          </div>

          <ListeDurumu
            pending={kameralar.isPending}
            error={kameralar.error}
            onRetry={() => void kameralar.refetch()}
            empty={(kameralar.data ?? []).length === 0}
            bos={
              <EmptyState
                icon={<IconKamera size={30} />}
                title="Henüz kamera yok"
                hint="Yeni kamera ekleyip çıkan kodu otoparktaki bilgisayara girin."
              />
            }
          >
            <ul className="space-y-2.5">
              {(kameralar.data ?? []).map((k) => (
                <li
                  key={k.id}
                  className={`rounded-field bg-field px-3.5 py-3 ${
                    k.id === vurgu ? 'ring-2 ring-danger' : ''
                  }`}
                >
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="truncate text-body font-medium text-ink">{k.ad}</p>
                      <p className="mt-1 text-label text-faint">
                        {k.yon === 'ORTAK'
                          ? 'Tek kapı · giriş ve çıkış'
                          : `${KAMERA_YON_ETIKET[k.yon]} şeridi`}{' '}
                        ·{' '}
                        {k.son_gorulme ? formatGoreceli(k.son_gorulme) : 'hiç bağlanmadı'}
                      </p>
                    </div>
                    <div className="shrink-0">{durumRozeti(k, esikDk, simdi)}</div>
                  </div>

                  {/* A camera that never connected raises no alert (there is
                      no "last seen" to go stale), so the only place an
                      abandoned setup can be noticed is here. */}
                  {k.aktif &&
                    !k.son_gorulme &&
                    simdi - new Date(k.created_at).getTime() > YARIM_KURULUM_MS && (
                      <p className="mt-2 text-label text-warn">
                        Kurulum tamamlanmamış görünüyor. Otoparktaki bilgisayarda kurulumu
                        yeniden çalıştırın; vazgeçildiyse kamerayı kaldırın.
                      </p>
                    )}

                  <div className="mt-3 flex items-center gap-2">
                    <Button
                      size="md"
                      variant="soft"
                      onClick={() => void durumDegistir(k)}
                      // Only the row that was tapped spins; one shared flag
                      // put every camera's button into loading at once.
                      loading={durum.isPending && durum.variables?.id === k.id}
                      disabled={durum.isPending && durum.variables?.id !== k.id}
                    >
                      {k.aktif ? 'Devre dışı bırak' : 'Etkinleştir'}
                    </Button>
                    <Button
                      size="md"
                      variant="ghost"
                      onClick={() => {
                        setSilHata(null)
                        setSilinecek(k)
                      }}
                      aria-label={`${k.ad} kamerasını kaldır`}
                    >
                      <IconCop size={16} />
                    </Button>
                  </div>
                </li>
              ))}
            </ul>
          </ListeDurumu>
        </Card>

        {(kodlar.data ?? []).length > 0 && (
          <Card className="space-y-4">
            <p className="text-label font-medium tracking-wide text-faint uppercase">
              Bekleyen kodlar
            </p>
            <ul className="space-y-2.5">
              {(kodlar.data ?? []).map((k) => (
                <li
                  key={k.id}
                  className="flex items-center justify-between gap-3 rounded-field bg-field px-3.5 py-3"
                >
                  <div className="min-w-0">
                    <p className="truncate text-body text-ink">{k.ad}</p>
                    <p className="mt-0.5 text-label text-faint">
                      {KAMERA_YON_ETIKET[k.yon]} · kalan{' '}
                      <span className="tnum">{kalanMetni(k.bitis, simdi)}</span>
                    </p>
                  </div>
                  <Button
                    size="md"
                    variant="ghost"
                    onClick={() => void kodIptalEt(k.id)}
                    loading={kodIptal.isPending && kodIptal.variables === k.id}
                  >
                    İptal
                  </Button>
                </li>
              ))}
            </ul>
            <p className="text-label text-faint">
              Kod yalnızca üretildiği anda görünür. Kaybolduysa iptal edip yenisini alın.
            </p>
          </Card>
        )}

        {/* The bridge set up by hand with the shared secret has no row of its
            own — it is watched through one global timestamp. Shown only once
            such a bridge has ever reported. */}
        {eskiKalp !== null && (
          <Card className="space-y-3">
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="text-label font-medium tracking-wide text-faint uppercase">
                  Elle kurulmuş köprü
                </p>
                <p className="mt-1.5 text-label text-faint">
                  Kodsuz, ortak anahtarla kurulmuş köprü · {formatGoreceli(eskiKalp)}
                </p>
              </div>
              <div className="shrink-0">
                {eskiCanli ? (
                  <Chip tone="success">Çalışıyor</Chip>
                ) : (
                  <Chip tone="danger">Yanıt yok</Chip>
                )}
              </div>
            </div>
            <p className="text-label text-faint">
              Böyle bir köprünüz kalmadıysa izlemeyi kapatın; yoksa her saat “haber yok” uyarısı
              gelir.
            </p>
            <Button
              size="md"
              variant="soft"
              onClick={() => {
                setEskiHata(null)
                setEskiSor(true)
              }}
            >
              Artık kullanılmıyor
            </Button>
          </Card>
        )}

        <Card className="space-y-3">
          <p className="text-label font-medium tracking-wide text-faint uppercase">
            Webhook adresi
          </p>
          <p className="text-label text-faint">
            Kodla kurulumda buna gerek yok — kurulum bu adresi kendisi öğrenir. Elle kurulum
            yapan biri için burada duruyor.
          </p>
          <p className="rounded-field bg-field px-3.5 py-3 text-label break-all text-soft">
            {WEBHOOK_URL}
          </p>
          <Button size="md" variant="soft" onClick={() => void kopyala('webhook', WEBHOOK_URL)}>
            {kopyalandi === 'webhook' ? 'Kopyalandı' : 'Kopyala'}
          </Button>
        </Card>
      </div>

      {/* One modal, two states: ask, then reveal. The code replaces the form
          rather than opening a second dialog, so there is never a moment where
          the code is behind something.

          `sabit` while the code is still unused: it cannot be shown again, and
          on a phone a tap beside the sheet used to close it and throw the code
          away. "Tamam" stays the one deliberate way out. */}
      <FormModal
        open={ekleAcik}
        onOpenChange={(o) => (o ? setEkleAcik(true) : modalKapat())}
        title={yeniKod ? 'Kurulum kodu' : 'Yeni kamera'}
        submitLabel={yeniKod ? 'Tamam' : 'Kod üret'}
        onSubmit={yeniKod ? modalKapat : () => void kodOlustur()}
        loading={kodUret.isPending}
        error={modalHata}
        sabit={yeniKod !== null && adim === 'BEKLIYOR'}
      >
        {yeniKod ? (
          <div className="space-y-4">
            {kodGorunur && (
              <div className="rounded-field bg-field px-3.5 py-4 text-center">
                {/* text-hero (44px) WRAPS here and that is not cosmetic: the
                    hyphen is a break opportunity, so a letter-heavy code like
                    MWMWM-MWMWM splits across two lines and reads as two codes.
                    Measured at 375px — 422px of text in a 314px box. text-title
                    with wide tracking fits the widest possible code on one line
                    down to a 320px screen; nowrap makes the guarantee explicit. */}
                <p className="tnum text-title font-semibold tracking-widest whitespace-nowrap text-ink">
                  {yeniKod.kod}
                </p>
                <p className="mt-1.5 text-label text-faint">
                  Kalan süre <span className="tnum">{kalanMetni(yeniKod.bitis, simdi)}</span>
                </p>
              </div>
            )}

            {/* Live: the Yönetici is usually on the phone with whoever is at
                the car park, and "did it work?" should be answered here. */}
            <div
              role="status"
              aria-live="polite"
              // Bordered, not filled: the neutral chip is bg-field itself and
              // would vanish into a bg-field box.
              className="flex items-start gap-3 rounded-field border border-border px-3.5 py-3"
            >
              <div className="shrink-0">
                {adim === 'BEKLIYOR' && <Chip tone="neutral">Bekleniyor</Chip>}
                {adim === 'ESLESTI' && <Chip tone="accent">Eşleştirildi</Chip>}
                {adim === 'CALISIYOR' && <Chip tone="success">Çalışıyor</Chip>}
                {adim === 'DOLDU' && <Chip tone="warn">Süresi doldu</Chip>}
                {adim === 'YOK' && <Chip tone="warn">İptal edildi</Chip>}
              </div>
              <p className="min-w-0 text-label text-soft">
                {adim === 'BEKLIYOR' &&
                  'Kod otoparktaki bilgisayara girildiğinde burada görünecek.'}
                {adim === 'ESLESTI' &&
                  (ayar && !ayar.kamera_aktif
                    ? 'Kod girildi. Kamera girişi kapalı olduğu için bağlantı görünmüyor — Otopark ayarlarından açın.'
                    : 'Kod girildi. Kurulum otoparkta sürüyor; köprü çalışmaya başladığında burada görünecek.')}
                {adim === 'CALISIYOR' &&
                  `${eslesen?.ad ?? 'Kamera'} köprüsü çalışıyor. Bu pencereyi kapatabilirsiniz.`}
                {adim === 'DOLDU' && 'Kod kullanılmadan süresi doldu. Kapatıp yeni bir kod üretin.'}
                {adim === 'YOK' && 'Bu kod iptal edildi. Kapatıp yeni bir kod üretin.'}
              </p>
            </div>

            {adim === 'BEKLIYOR' && (
              <>
                <p className="rounded-field bg-warn-soft px-3.5 py-3 text-label text-warn">
                  Bu kod bir daha gösterilmeyecek. Şimdi kopyalayın ya da dosyayı indirin.
                </p>

                <div className="flex flex-wrap gap-2">
                  <Button
                    size="md"
                    variant="soft"
                    onClick={() => void kopyala('kod', yeniKod.kod)}
                  >
                    {kopyalandi === 'kod' ? 'Kopyalandı' : 'Kodu kopyala'}
                  </Button>
                  <Button
                    size="md"
                    variant="soft"
                    onClick={() => metniIndir('kurulum-kodu.txt', kodDosyasi)}
                  >
                    kurulum-kodu.txt indir
                  </Button>
                </div>

                <div className="space-y-2 text-label text-faint">
                  <p>
                    1. Dosyayı OtoparkKamera.exe ile aynı klasöre koyun; kurulum onu kendisi
                    okur.
                  </p>
                  <p>2. Dosya gönderemiyorsanız kodu kuruluma elle yazdırın.</p>
                  <p>3. Kod 15 dakika geçerli ve yalnızca bu kamera içindir.</p>
                </div>
              </>
            )}

            {adim === 'ESLESTI' && (
              <p className="text-label text-faint">
                Kurulum yarıda kaldıysa aynı kod, süresi dolana kadar otoparktaki bilgisayarda
                yeniden girilebilir.
              </p>
            )}
          </div>
        ) : (
          <div className="space-y-4">
            <Input
              label="Kamera adı"
              value={ad}
              onChange={(e) => setAd(e.target.value)}
              maxLength={60}
              hint="Bu listede görünecek ad. Örnek: Giriş bariyeri."
            />
            <SegmentedControl
              label="Şerit"
              value={yon}
              options={[
                { value: 'GIRIS', label: KAMERA_YON_ETIKET.GIRIS },
                { value: 'CIKIS', label: KAMERA_YON_ETIKET.CIKIS },
                { value: 'ORTAK', label: KAMERA_YON_ETIKET.ORTAK },
              ]}
              onChange={setYon}
            />
            {/* Shown only when chosen: it explains a behaviour the other two
                lanes do not have, and under them it would read as a warning
                about something the Yönetici did not pick. */}
            {yon === 'ORTAK' && (
              <p className="text-label text-soft">
                Araçlar aynı kapıdan girip çıkıyorsa bunu seçin. Kamera, içeride bileti olan
                aracı çıkıyor, olmayanı giriyor sayar; emin olamadığını Çözülmemiş kayıtlar’a
                bırakır.
              </p>
            )}
            <p className="text-label text-faint">
              Şerit sonradan değiştirilemez — çıkış kamerasını giriş sanan bir köprü, çıkan
              araçlara bilet açar. Yanlışsa kamerayı kaldırıp yeniden ekleyin.
            </p>
          </div>
        )}
      </FormModal>

      <ConfirmDialog
        open={silinecek !== null}
        onOpenChange={(o) => {
          if (!o) setSilinecek(null)
        }}
        title="Kamera kaldırılsın mı?"
        description={
          silinecek
            ? `${silinecek.ad} kaldırılacak ve anahtarı geçersiz olacak. Geri eklemek için otoparktaki bilgisayarda kurulumu yeniden çalıştırmak gerekir — geçici bir arıza için "Devre dışı bırak" daha uygun.`
            : undefined
        }
        confirmLabel="Kaldır"
        tone="danger"
        loading={kaldir.isPending}
        error={silHata}
        onConfirm={() => void kameraSil()}
      />

      <ConfirmDialog
        open={eskiSor}
        onOpenChange={(o) => {
          if (!o) setEskiSor(false)
        }}
        title="Elle kurulmuş köprü izlenmesin mi?"
        description="Bu köprü için “haber yok” uyarısı artık gönderilmez. Köprü yeniden bağlanırsa izleme kendiliğinden geri gelir. Eşleştirilmiş kameralar etkilenmez."
        confirmLabel="İzlemeyi kapat"
        loading={eskiUnut.isPending}
        error={eskiHata}
        onConfirm={() => void eskiKopruUnut()}
      />
    </div>
  )
}
