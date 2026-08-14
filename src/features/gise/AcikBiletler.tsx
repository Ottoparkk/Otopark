import { useState } from 'react'
import { useNavigate } from 'react-router'
import {
  Card,
  EmptyState,
  Input,
  ListeDurumu,
  ScreenHeader,
} from '../../components/ui/primitives'
import { BiletKart, DolulukRozeti } from './components'
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
        {/* Today at a glance. Numbers at full contrast, their captions faint —
            the figure is what gets read, the word only explains it. */}
        {ozet && (
          <Card>
            <div className="grid grid-cols-3 gap-3 text-center">
              <div>
                <p className="text-title font-semibold text-ink tnum">{ozet.doluluk}</p>
                <p className="mt-0.5 text-label text-faint">içeride</p>
              </div>
              <div>
                <p className="text-title font-semibold text-ink tnum">{ozet.arac_sayisi}</p>
                <p className="mt-0.5 text-label text-faint">bugün giren</p>
              </div>
              <div>
                <p className="text-title font-semibold text-ink tnum">
                  {formatTL(ozet.toplam_kurus, { decimals: 0 })}
                </p>
                <p className="mt-0.5 text-label text-faint">bugün tahsilat</p>
              </div>
            </div>
          </Card>
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
