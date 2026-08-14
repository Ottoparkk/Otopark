import { useMemo, useState } from 'react'
import { Card, EmptyState, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { SegmentedControl } from '../../components/ui/primitives'
import { useApproveSignup, useProfiller, useSetRole, useSetStatus } from './api'
import { useAuth } from '../../app/providers/AuthProvider'
import { formatGoreceli } from '../../lib/dates'
import { rpcErrorText } from '../../lib/errors'
import { IconKisi } from '../../components/ui/icons'
import type { Profile, Rol } from '../../lib/types'

export default function Personel() {
  const { profile: ben } = useAuth()
  const { data: liste = [], isPending, error, refetch } = useProfiller()

  const onayla = useApproveSignup()
  const rolDegistir = useSetRole()
  const durumDegistir = useSetStatus()

  const [onaylanan, setOnaylanan] = useState<Profile | null>(null)
  const [secilenRol, setSecilenRol] = useState<Rol>('PERSONEL')
  const [rolHedef, setRolHedef] = useState<Profile | null>(null)
  const [durumHedef, setDurumHedef] = useState<Profile | null>(null)
  const [hata, setHata] = useState<string | null>(null)

  const { bekleyen, aktif, kapali } = useMemo(
    () => ({
      bekleyen: liste.filter((p) => p.durum === 'PENDING'),
      aktif: liste.filter((p) => p.durum === 'ACTIVE'),
      kapali: liste.filter((p) => p.durum === 'DISABLED'),
    }),
    [liste],
  )

  if (error) {
    return (
      <div className="px-5">
        <ScreenHeader title="Personel" back="/yonetim" />
        <LoadError error={error} onRetry={() => void refetch()} />
      </div>
    )
  }

  return (
    <div>
      <ScreenHeader title="Personel" back="/yonetim" />

      <div className="space-y-5 px-5">
        {/* The failed-load case already returned above, so this is only the
            genuine loading state — never an empty list standing in for one. */}
        {isPending ? (
          <div className="py-14">
            <Spinner label="Yükleniyor" />
          </div>
        ) : (
          <>
            {bekleyen.length > 0 && (
              <section>
                <Baslik>Onay bekleyen ({bekleyen.length})</Baslik>
                <div className="space-y-2">
                  {bekleyen.map((p) => (
                    <Card key={p.id}>
                      <p className="text-body font-medium text-ink">{p.ad_soyad || 'İsimsiz'}</p>
                      <p className="mt-0.5 text-label text-faint">
                        {formatGoreceli(p.created_at)} tarihinde kaydoldu
                      </p>
                      <button
                        type="button"
                        onClick={() => {
                          setSecilenRol('PERSONEL')
                          setHata(null)
                          setOnaylanan(p)
                        }}
                        className="mt-3 min-h-[44px] w-full rounded-field bg-accent text-body font-medium text-accent-ink"
                      >
                        Onayla ve rol ata
                      </button>
                    </Card>
                  ))}
                </div>
              </section>
            )}

            <section>
              <Baslik>Aktif ({aktif.length})</Baslik>
              {aktif.length === 0 ? (
                <EmptyState icon={<IconKisi size={40} />} title="Aktif personel yok" />
              ) : (
                <div className="space-y-2">
                  {aktif.map((p) => (
                    <KisiKart
                      key={p.id}
                      p={p}
                      ben={ben?.id === p.id}
                      onRol={() => {
                        setSecilenRol(p.rol === 'YONETICI' ? 'PERSONEL' : 'YONETICI')
                        setHata(null)
                        setRolHedef(p)
                      }}
                      onDurum={() => {
                        setHata(null)
                        setDurumHedef(p)
                      }}
                    />
                  ))}
                </div>
              )}
            </section>

            {kapali.length > 0 && (
              <section>
                <Baslik>Kapalı ({kapali.length})</Baslik>
                <div className="space-y-2">
                  {kapali.map((p) => (
                    <KisiKart
                      key={p.id}
                      p={p}
                      ben={ben?.id === p.id}
                      onDurum={() => {
                        setHata(null)
                        setDurumHedef(p)
                      }}
                    />
                  ))}
                </div>
              </section>
            )}
          </>
        )}
      </div>

      {/* ---- approve ------------------------------------------------- */}
      <ConfirmDialog
        open={onaylanan !== null}
        onOpenChange={() => setOnaylanan(null)}
        title="Kaydı onayla"
        description={`${onaylanan?.ad_soyad || 'Bu kullanıcı'} için bir rol seçin.`}
        confirmLabel="Onayla"
        loading={onayla.isPending}
        error={hata}
        onConfirm={() => {
          if (!onaylanan) return
          void onayla
            .mutateAsync({ id: onaylanan.id, rol: secilenRol })
            .then(() => setOnaylanan(null))
            .catch((e) => setHata(rpcErrorText(e, 'Onaylanamadı.')))
        }}
      >
        <RolSecici value={secilenRol} onChange={setSecilenRol} />
      </ConfirmDialog>

      {/* ---- role change --------------------------------------------- */}
      <ConfirmDialog
        open={rolHedef !== null}
        onOpenChange={() => setRolHedef(null)}
        title="Rol değiştir"
        description={`${rolHedef?.ad_soyad || 'Kullanıcı'} için yeni rol seçin.`}
        confirmLabel="Değiştir"
        loading={rolDegistir.isPending}
        error={hata}
        onConfirm={() => {
          if (!rolHedef) return
          void rolDegistir
            .mutateAsync({ id: rolHedef.id, rol: secilenRol })
            .then(() => setRolHedef(null))
            .catch((e) => setHata(rpcErrorText(e, 'Rol değiştirilemedi.')))
        }}
      >
        <RolSecici value={secilenRol} onChange={setSecilenRol} />
      </ConfirmDialog>

      {/* ---- enable / disable ---------------------------------------- */}
      <ConfirmDialog
        open={durumHedef !== null}
        onOpenChange={() => setDurumHedef(null)}
        tone={durumHedef?.durum === 'ACTIVE' ? 'danger' : 'primary'}
        title={durumHedef?.durum === 'ACTIVE' ? 'Hesabı kapat' : 'Hesabı aç'}
        description={
          durumHedef?.durum === 'ACTIVE'
            ? 'Kullanıcı bir sonraki isteğinde tüm erişimini kaybeder.'
            : 'Kullanıcı yeniden giriş yapabilir.'
        }
        confirmLabel={durumHedef?.durum === 'ACTIVE' ? 'Kapat' : 'Aç'}
        loading={durumDegistir.isPending}
        error={hata}
        onConfirm={() => {
          if (!durumHedef) return
          void durumDegistir
            .mutateAsync({
              id: durumHedef.id,
              durum: durumHedef.durum === 'ACTIVE' ? 'DISABLED' : 'ACTIVE',
            })
            .then(() => setDurumHedef(null))
            .catch((e) => setHata(rpcErrorText(e, 'Durum değiştirilemedi.')))
        }}
      />
    </div>
  )
}

function Baslik({ children }: { children: React.ReactNode }) {
  return (
    <p className="mb-2 text-label font-medium tracking-wide text-faint uppercase">{children}</p>
  )
}

function RolSecici({ value, onChange }: { value: Rol; onChange: (r: Rol) => void }) {
  return (
    <SegmentedControl
      value={value}
      onChange={onChange}
      options={[
        { value: 'PERSONEL', label: 'Personel' },
        { value: 'YONETICI', label: 'Yönetici' },
      ]}
    />
  )
}

function KisiKart({
  p,
  ben,
  onRol,
  onDurum,
}: {
  p: Profile
  ben: boolean
  onRol?: () => void
  onDurum?: () => void
}) {
  return (
    <Card>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate text-body font-medium text-ink">
            {p.ad_soyad || 'İsimsiz'}
            {ben && <span className="ml-2 text-label text-faint">(siz)</span>}
          </p>
          <p className="mt-0.5 text-label text-faint">
            {p.rol === 'YONETICI' ? 'Yönetici' : p.rol === 'PERSONEL' ? 'Personel' : 'Rol yok'}
          </p>
        </div>
        <span
          className={`shrink-0 rounded-chip px-2.5 py-1 text-label font-medium ${
            p.durum === 'ACTIVE'
              ? 'bg-success-soft text-success'
              : p.durum === 'PENDING'
                ? 'bg-warn-soft text-warn'
                : 'bg-danger-soft text-danger'
          }`}
        >
          {p.durum === 'ACTIVE' ? 'Aktif' : p.durum === 'PENDING' ? 'Bekliyor' : 'Kapalı'}
        </span>
      </div>

      {/* Self-service is blocked server-side too — these buttons are hidden
          because they would only ever produce a Turkish refusal. */}
      {!ben && (
        <div className="mt-3 flex gap-2">
          {onRol && (
            <button
              type="button"
              onClick={onRol}
              className="min-h-[44px] flex-1 rounded-field bg-field text-body font-medium text-soft"
            >
              Rol değiştir
            </button>
          )}
          {onDurum && (
            <button
              type="button"
              onClick={onDurum}
              className={`min-h-[44px] flex-1 rounded-field text-body font-medium ${
                p.durum === 'ACTIVE' ? 'bg-danger-soft text-danger' : 'bg-success-soft text-success'
              }`}
            >
              {p.durum === 'ACTIVE' ? 'Hesabı kapat' : 'Hesabı aç'}
            </button>
          )}
        </div>
      )}
    </Card>
  )
}
