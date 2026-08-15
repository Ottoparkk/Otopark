import { useState } from 'react'
import { useNavigate } from 'react-router'
import {
  BrandPanel,
  EmptyState,
  Input,
  ListeDurumu,
  OranCubugu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { BiletKart, DolulukRozeti, dolulukYuzde } from './components'
import { useAcikBiletler, useGunlukOzet } from './api'
import { useAcikIstisnaSayisi } from '../istisna/api'
import { formatTL } from '../../lib/money'
import { IconAra, IconAraba } from '../../components/ui/icons'
import { useAuth } from '../../app/providers/AuthProvider'
import { isYonetici } from '../../lib/rbac'

/**
 * Everything currently inside the lot.
 *
 * Personel see the summary numbers through `gunluk_ozet()` — an aggregate
 * RPC, not row access. If they could SELECT today's tickets to sum them,
 * they would also have per-ticket revenue history, which is exactly what the
 * role is not meant to see.
 */
export default function AcikBiletler() {
  const navigate = useNavigate()
  const { profile } = useAuth()
  const [sorgu, setSorgu] = useState('')

  const { data: biletler = [], isPending, error, refetch } = useAcikBiletler(sorgu)
  const { data: ozet } = useGunlukOzet()
  const { data: acikIstisna = 0 } = useAcikIstisnaSayisi()

  const kapidakiler = biletler.filter((b) => b.cikis_bekliyor_at).length

  return (
    <div>
      <ScreenHeader
        title="Araçlar"
        right={ozet ? <DolulukRozeti dolu={ozet.doluluk} kapasite={ozet.kapasite} /> : null}
      />

      <div className="space-y-4 px-5">
        {/* Today at a glance.
            Occupancy is the headline because it is the question an operator
            actually has — "can I let another car in?" — and the two money/count
            figures step down to a quieter row beneath it rather than competing
            as three equal numbers. */}
        {ozet && (
          <BrandPanel>
            <div className="flex items-end justify-between gap-3">
              <div>
                <p className="text-label font-medium tracking-wide text-on-brand-soft uppercase">
                  Doluluk
                </p>
                <p className="mt-1 text-hero font-semibold tnum">
                  {ozet.doluluk}
                  <span className="ml-1 text-title font-medium text-on-brand-soft">
                    / {ozet.kapasite}
                  </span>
                </p>
              </div>
              <p className="pb-1.5 text-title font-semibold tnum">
                %{dolulukYuzde(ozet.doluluk, ozet.kapasite)}
              </p>
            </div>

            <div className="mt-3">
              <OranCubugu yuzde={dolulukYuzde(ozet.doluluk, ozet.kapasite)} />
            </div>

            <div className="mt-4 flex gap-6 border-t border-white/15 pt-3.5">
              <div>
                <p className="text-lead font-semibold tnum">{ozet.arac_sayisi}</p>
                <p className="text-label text-on-brand-soft">bugün giren</p>
              </div>
              <div>
                <p className="text-lead font-semibold tnum">
                  {formatTL(ozet.toplam_kurus, { decimals: 0 })}
                </p>
                <p className="text-label text-on-brand-soft">bugün tahsilat</p>
              </div>
            </div>
          </BrandPanel>
        )}

        {kapidakiler > 0 && (
          <p className="rounded-card bg-accent-soft px-4 py-3 text-body text-accent">
            {kapidakiler} araç çıkış kapısında bekliyor.
          </p>
        )}

        {/* An event that could not become a ticket is a car that will be
            argued about at the barrier. It belongs on the screen the operator
            is already looking at, not only on a menu they never open. */}
        {acikIstisna > 0 && (
          <button
            type="button"
            onClick={() => navigate('/istisnalar')}
            className="w-full rounded-card bg-warn-soft px-4 py-3 text-left text-body font-medium text-warn"
          >
            {acikIstisna} çözülmemiş kayıt var →
          </button>
        )}

        <div className="relative">
          <IconAra
            size={20}
            className="pointer-events-none absolute top-1/2 left-4 -translate-y-1/2 text-faint"
          />
          <Input
            label="Plaka ara"
            hideLabel
            value={sorgu}
            onChange={(e) => setSorgu(e.target.value.toUpperCase())}
            placeholder="Plaka ara"
            autoCapitalize="characters"
            autoCorrect="off"
            spellCheck={false}
            className="pl-11 tnum"
          />
        </div>

        <div className="space-y-2">
          <ListeDurumu
            pending={isPending}
            error={error}
            onRetry={() => void refetch()}
            empty={biletler.length === 0}
            bos={
              <EmptyState
                icon={<IconAraba size={44} />}
                title={sorgu ? 'Eşleşen araç yok' : 'Bugün henüz araç girişi yok'}
                hint={
                  sorgu
                    ? 'Plakanın son rakamlarını da arayabilirsiniz.'
                    : 'Giriş yapılan araçlar burada görünür.'
                }
              />
            }
          >
            {biletler.map((b) => (
              <BiletKart
                key={b.id}
                bilet={b}
                onClick={() =>
                  navigate(isYonetici(profile) ? `/gise/bilet/${b.id}` : '/gise/cikis')
                }
              />
            ))}
          </ListeDurumu>
        </div>
      </div>
    </div>
  )
}
