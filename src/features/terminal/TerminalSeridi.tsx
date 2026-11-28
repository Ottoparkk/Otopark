import { useEffect, useState } from 'react'
import { useAuth } from '../../app/providers/AuthProvider'
import { IconKisi, IconVardiya } from '../../components/ui/icons'
import { safeStorage } from '../../lib/storage'
import { useAcikVardiya } from '../vardiya/api'
import { useVardiyaSaatleri } from './api'
import { DevralModal } from './Devral'
import { devirHatirlatmasi, siradakiPersonel, sonBitis } from './devirHatirlatma'
import { useTerminal } from './useTerminal'

/** "Devam ediyorum" hides the band until the NEXT end time (085). */
const GIZLE_ANAHTAR = 'op.devirHatirlatmaGizli'

function useDakikalik(): Date {
  const [simdi, setSimdi] = useState(() => new Date())
  useEffect(() => {
    const t = setInterval(() => setSimdi(new Date()), 30_000)
    return () => clearInterval(t)
  }, [])
  return simdi
}

/**
 * On the shared handheld only: who is holding the shift right now, the one
 * button the incoming worker needs, and — once the current worker's shift
 * has ended (085) — a reminder naming who is due. Nothing renders elsewhere.
 */
export function TerminalSeridi() {
  const terminal = useTerminal()
  const { profile } = useAuth()
  if (!terminal || !profile) return null
  return <Serit profileId={profile.id} ad={profile.ad_soyad} />
}

/** Mounted only on a terminal, so other devices never run these queries. */
function Serit({ profileId, ad }: { profileId: string; ad: string | null }) {
  const [acik, setAcik] = useState(false)
  const [onerilen, setOnerilen] = useState<string | null>(null)
  const simdi = useDakikalik()
  const { data: vardiya } = useAcikVardiya()
  const { data: saatler = [] } = useVardiyaSaatleri()
  const [gizli, setGizli] = useState(() => safeStorage.getItem(GIZLE_ANAHTAR))

  const calisanId = vardiya?.personel_id ?? profileId
  const bitis = saatler.find((s) => s.id === calisanId)?.vardiya_bitis ?? null
  const son = sonBitis(simdi, bitis)?.toISOString() ?? null
  const hatirlat =
    Boolean(vardiya) && devirHatirlatmasi(vardiya!.acilis_at, simdi, bitis) && gizli !== son
  const sirada = hatirlat ? siradakiPersonel(saatler, bitis, calisanId) : null

  function devralAc(kim: string | null) {
    setOnerilen(kim)
    setAcik(true)
  }

  return (
    <>
      <div className="flex items-center gap-3 border-b border-divider bg-surface px-5 py-1.5 md:rounded-b-card md:border-x">
        <IconKisi size={18} className="shrink-0 text-faint" />
        <p className="min-w-0 flex-1 truncate text-body text-soft">
          <span className="font-semibold text-ink">{ad || 'İsimsiz'}</span> çalışıyor
        </p>
        <button
          type="button"
          onClick={() => devralAc(null)}
          className="min-h-[44px] shrink-0 rounded-chip bg-accent-soft px-4 text-body font-medium text-accent active:brightness-95"
        >
          Devral
        </button>
      </div>

      {hatirlat && (
        <div role="status" className="mx-5 mt-3 rounded-card border border-warn/40 bg-warn-soft p-4">
          <div className="flex gap-3">
            <IconVardiya size={22} className="mt-0.5 shrink-0 text-warn" />
            <p className="text-body text-ink">
              Vardiya bitiş saatin ({bitis?.slice(0, 5)}) geçti.{' '}
              <span className="font-semibold">{sirada ? sirada.ad_soyad : 'Yeni personel'}</span> geldiyse{' '}
              <span className="font-semibold">Devral</span>'a dokunun.
            </p>
          </div>
          <div className="mt-3 flex gap-2">
            <button
              type="button"
              onClick={() => devralAc(sirada?.id ?? null)}
              className="min-h-[44px] flex-1 rounded-field bg-accent text-body font-medium text-accent-ink active:brightness-95"
            >
              Devral
            </button>
            <button
              type="button"
              onClick={() => {
                if (son) safeStorage.setItem(GIZLE_ANAHTAR, son)
                setGizli(son)
              }}
              className="min-h-[44px] flex-1 rounded-field bg-surface text-body font-medium text-ink active:brightness-95"
            >
              Devam ediyorum
            </button>
          </div>
        </div>
      )}

      <DevralModal open={acik} onOpenChange={setAcik} onerilen={onerilen} />
    </>
  )
}
