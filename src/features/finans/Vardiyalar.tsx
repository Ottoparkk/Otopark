import { useState } from 'react'
import { useNavigate } from 'react-router'
import { Button, EmptyState, ListeDurumu, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { useGunToplamlari, useIlkGun, type GunToplami } from './api'
import { useAcikVardiya } from '../vardiya/api'
import { useProfiller } from '../yonetim/api'
import { IconIleri, IconTakvim, IconVardiya } from '../../components/ui/icons'
import { gecenGunMetni, gecmisGunler, gunEtiketi, oncekiAy, oncekiAyVar, yuzdeFark } from './vardiyaEtiket'
import { KarsilastirmaChip, kisaTL } from './raporParcalari'
import { ayAraligi, formatAy, istanbulAy, istanbulGun } from '../../lib/dates'

/**
 * The Yönetici's Rapor tab (was "Vardiyalar"; owner 28.11) as a list of days
 * (087; "how the whole day went", calendar day 00:00–24:00). Today is the
 * hero — its live total, who is working, how it compares with the same
 * weekday last week — and each earlier day of THIS month is one quiet row.
 * "Önceki ayı gör" (owner 28.11) adds the month before below, again and
 * again, down to the first month with records. A day opens its summary; its
 * shifts, and their cash counts, sit inside it.
 */
export default function Vardiyalar() {
  const navigate = useNavigate()
  const bugun = istanbulGun()
  const buAy = istanbulAy()
  const { data: gunler, isPending, error, refetch } = useGunToplamlari(`${buAy}-01`, bugun)
  const { data: acik } = useAcikVardiya()
  const { data: profiller = [] } = useProfiller()
  const { data: ilkGun } = useIlkGun()
  // How many earlier months are open below this one.
  const [eskiAy, setEskiAy] = useState(0)

  const bugunku = gunler?.get(bugun)
  const kars = bugunku ? yuzdeFark(bugunku.toplam, bugunku.onceki) : null
  const calisan = acik
    ? acik.personel_id === null
      ? 'Otomatik'
      : profiller.find((p) => p.id === acik.personel_id)?.ad_soyad || 'Bilinmiyor'
    : null
  const gecmis = gecmisGunler(gunler, bugun)

  const aylar: string[] = []
  for (let i = 0, ay = buAy; i < eskiAy; i++) aylar.push((ay = oncekiAy(ay)))
  const enEski = aylar[aylar.length - 1] ?? buAy

  return (
    <div className="pb-6">
      <ScreenHeader title="Rapor" />

      <div className="space-y-4 px-5">
        <ListeDurumu
          pending={isPending}
          error={error}
          onRetry={() => void refetch()}
          empty={false}
          bos={<EmptyState icon={<IconVardiya size={44} />} title="Kayıt yok" />}
        >
          <div className="rounded-card border border-border bg-surface p-5 shadow-card">
            <button
              type="button"
              onClick={() => navigate(`/vardiya/gun/${bugun}`)}
              className="block w-full text-left"
            >
              <div className="flex items-center justify-between gap-3">
                <p className="text-label font-medium text-accent">Bugün</p>
                <IconIleri size={17} className="shrink-0 text-faint" />
              </div>
              <p className="mt-2 text-hero font-semibold text-ink tnum">
                {kisaTL(bugunku?.toplam ?? 0)}
              </p>
              <p className="mt-1.5 text-body text-soft">
                {calisan ? `${calisan} çalışıyor` : 'Açık vardiya yok'} · {bugunku?.arac ?? 0} araç
              </p>
              {kars && (
                <KarsilastirmaChip
                  className="mt-2.5"
                  kars={kars}
                  metin={`${gecenGunMetni(bugun)}, bu saate kadar`}
                />
              )}
            </button>
            {acik && (
              <Button
                className="mt-4"
                variant="secondary"
                block
                onClick={() => navigate('/vardiya/kasa')}
              >
                Kasayı say
              </Button>
            )}
          </div>

          {gecmis.length > 0 && <GunListesi gunler={gecmis} bugun={bugun} />}

          {aylar.map((ay) => (
            <AyBolumu key={ay} ay={ay} bugun={bugun} />
          ))}

          {oncekiAyVar(enEski, ilkGun) && (
            <Button variant="secondary" block onClick={() => setEskiAy((n) => n + 1)}>
              Önceki ayı gör
            </Button>
          )}
        </ListeDurumu>
      </div>
    </div>
  )
}

/** One earlier month: its heading and its days (087's limit is 62 days a call). */
function AyBolumu({ ay, bugun }: { ay: string; bugun: string }) {
  const { bas, bit } = ayAraligi(ay)
  const { data, isPending, error, refetch } = useGunToplamlari(bas, bit)
  const gunler = gecmisGunler(data, bugun)
  return (
    <section>
      <h2 className="mb-2 px-1 text-label font-medium text-soft">{formatAy(ay)}</h2>
      {isPending ? (
        <div className="py-6">
          <Spinner label="Yükleniyor" />
        </div>
      ) : error ? (
        <button
          type="button"
          onClick={() => void refetch()}
          className="min-h-[44px] w-full rounded-card bg-danger-soft px-4 text-body text-danger"
        >
          Yüklenemedi — tekrar dene
        </button>
      ) : gunler.length === 0 ? (
        <p className="rounded-card border border-border bg-surface px-4 py-4 text-body text-faint shadow-card">
          Bu ayda kayıt yok
        </p>
      ) : (
        <GunListesi gunler={gunler} bugun={bugun} />
      )}
    </section>
  )
}

function GunListesi({ gunler, bugun }: { gunler: [string, GunToplami][]; bugun: string }) {
  const navigate = useNavigate()
  return (
    <div className="divide-y divide-divider overflow-hidden rounded-card border border-border bg-surface shadow-card">
      {gunler.map(([g, t]) => (
        <button
          key={g}
          type="button"
          onClick={() => navigate(`/vardiya/gun/${g}`)}
          className="flex min-h-[64px] w-full items-center gap-3 px-4 py-3 text-left active:bg-field"
        >
          <span className="flex size-9 shrink-0 items-center justify-center rounded-field bg-field text-soft">
            <IconTakvim size={19} />
          </span>
          <div className="min-w-0 flex-1">
            <p className="truncate text-body font-semibold text-ink">{gunEtiketi(g, bugun)}</p>
            <p className="truncate text-label text-faint tnum">{t.arac} araç</p>
          </div>
          <p className="shrink-0 text-body font-semibold text-ink tnum">{kisaTL(t.toplam)}</p>
        </button>
      ))}
    </div>
  )
}
