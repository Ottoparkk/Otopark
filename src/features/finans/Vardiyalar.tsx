import { useNavigate } from 'react-router'
import { Button, EmptyState, ListeDurumu, ScreenHeader } from '../../components/ui/primitives'
import { useGunToplamlari } from './api'
import { useAcikVardiya } from '../vardiya/api'
import { useProfiller } from '../yonetim/api'
import { IconIleri, IconTakvim, IconVardiya } from '../../components/ui/icons'
import { gecenGunMetni, gunEtiketi, yuzdeFark } from './vardiyaEtiket'
import { KarsilastirmaChip, kisaTL } from './raporParcalari'
import { gunEkle, istanbulGun } from '../../lib/dates'

/**
 * The Yönetici's Vardiya tab as a list of days (087; owner 28.11: "how the
 * whole day went", calendar day 00:00–24:00). Today is the hero — its live
 * total, who is working, how it compares with the same weekday last week —
 * and each earlier day is one quiet row. A day opens its summary; its
 * shifts, and their cash counts, sit inside it.
 */
export default function Vardiyalar() {
  const navigate = useNavigate()
  const bugun = istanbulGun()
  const { data: gunler, isPending, error, refetch } = useGunToplamlari(gunEkle(-29, bugun), bugun)
  const { data: acik } = useAcikVardiya()
  const { data: profiller = [] } = useProfiller()

  const bugunku = gunler?.get(bugun)
  const kars = bugunku ? yuzdeFark(bugunku.toplam, bugunku.onceki) : null
  const calisan = acik
    ? acik.personel_id === null
      ? 'Otomatik'
      : profiller.find((p) => p.id === acik.personel_id)?.ad_soyad || 'Bilinmiyor'
    : null
  // Newest first; a day with no money and no cars is not worth a row.
  const gecmis = [...(gunler?.entries() ?? [])]
    .filter(([g, t]) => g !== bugun && (t.toplam !== 0 || t.arac > 0))
    .sort(([a], [b]) => (a < b ? 1 : -1))

  return (
    <div className="pb-6">
      <ScreenHeader title="Vardiyalar" />

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

          {gecmis.length > 0 && (
            <div className="divide-y divide-divider overflow-hidden rounded-card border border-border bg-surface shadow-card">
              {gecmis.map(([g, t]) => (
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
          )}
        </ListeDurumu>
      </div>
    </div>
  )
}
