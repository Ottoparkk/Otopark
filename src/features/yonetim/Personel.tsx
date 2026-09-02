import { useMemo, useState } from 'react'
import { useNavigate } from 'react-router'
import { Card, EmptyState, LoadError, ScreenHeader } from '../../components/ui/primitives'
import { Spinner } from '../../components/ui/Spinner'
import { ConfirmDialog } from '../../components/ui/ConfirmDialog'
import { RolBilgisi } from './RolBilgisi'
import { SegmentedControl } from '../../components/ui/primitives'
import {
  useApproveSignup,
  usePersonelListesi,
  useSetRole,
  useSetStatus,
  type PersonelSatiri,
} from './api'
import { useAuth } from '../../app/providers/AuthProvider'
import { formatGoreceli } from '../../lib/dates'
import { formatTL } from '../../lib/money'
import { rpcErrorText } from '../../lib/errors'
import { IconKisi } from '../../components/ui/icons'
import type { Rol } from '../../lib/types'

export default function Personel() {
  const navigate = useNavigate()
  const { profile: ben } = useAuth()
  const { data: liste = [], isPending, error, refetch } = usePersonelListesi()

  const onayla = useApproveSignup()
  const rolDegistir = useSetRole()
  const durumDegistir = useSetStatus()

  const [onaylanan, setOnaylanan] = useState<PersonelSatiri | null>(null)
  const [secilenRol, setSecilenRol] = useState<Rol>('PERSONEL')
  const [rolHedef, setRolHedef] = useState<PersonelSatiri | null>(null)
  const [durumHedef, setDurumHedef] = useState<PersonelSatiri | null>(null)
  const [hata, setHata] = useState<string | null>(null)
  const [rolBilgisi, setRolBilgisi] = useState(false)

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
      {/* Reference, not an action, so it stays quiet — but labelled, because
          a lone icon here would be a guess about what it opens. */}
      <ScreenHeader
        title="Personel"
        back="/yonetim"
        right={
          <button
            type="button"
            onClick={() => setRolBilgisi(true)}
            className="rounded-chip bg-field px-3 py-2 text-label font-medium text-soft active:bg-border"
          >
            Rol bilgisi
          </button>
        }
      />

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
                      onAc={() => navigate(`/yonetim/personel/${p.id}`)}
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
                <Baslik>Silinen ({kapali.length})</Baslik>
                <div className="space-y-2">
                  {kapali.map((p) => (
                    <KisiKart
                      key={p.id}
                      p={p}
                      ben={ben?.id === p.id}
                      onAc={() => navigate(`/yonetim/personel/${p.id}`)}
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
        title={durumHedef?.durum === 'ACTIVE' ? 'Personeli sil' : 'Erişimi geri ver'}
        // Says what is kept, not only what is taken away. The records are the
        // whole point: tickets, shifts and payments stay exactly where they
        // are, and the person keeps their name on them.
        description={
          durumHedef?.durum === 'ACTIVE'
            ? (durumHedef?.ad_soyad || 'Bu kişi') +
              ' bir sonraki isteğinde tüm erişimini kaybeder. Geçmiş kayıtları — bilet, vardiya ve ödemeler — silinmez, listede Silinen altında kalır ve erişim geri verilebilir.'
            : 'Kullanıcı yeniden giriş yapabilir.'
        }
        confirmLabel={durumHedef?.durum === 'ACTIVE' ? 'Sil' : 'Geri ver'}
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

      <RolBilgisi open={rolBilgisi} onOpenChange={setRolBilgisi} />
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
  onAc,
}: {
  p: PersonelSatiri
  ben: boolean
  onRol?: () => void
  onDurum?: () => void
  /** Opens the pay screen. Absent for people who have no pay to show. */
  onAc?: () => void
}) {
  return (
    <Card>
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="truncate text-body font-semibold text-ink">
            {p.ad_soyad || 'İsimsiz'}
            {ben && <span className="ml-2 text-label font-normal text-faint">(siz)</span>}
          </p>
          {/* The role as a chip rather than a grey line: it is a label on a
              person, and it reads as one. */}
          <span className="mt-1.5 inline-block rounded-chip bg-field px-2 py-0.5 text-micro font-medium text-soft">
            {p.rol === 'YONETICI' ? 'Yönetici' : p.rol === 'PERSONEL' ? 'Personel' : 'Rol yok'}
          </span>
        </div>

        {/* Pay on the right, captioned. The status chip that used to sit here
            is gone: every row already lives under an Aktif / Kapalı / Onay
            bekleyen heading, so it said the same thing twice. Shown only when
            a salary is set — a row of ₺0 for staff who are paid another way
            would read as an error. */}
        {p.maas_kurus > 0 && (
          <div className="shrink-0 text-right">
            <p className="text-micro font-medium tracking-wide text-faint uppercase">Maaş</p>
            <p className="text-body font-semibold text-ink tnum">{formatTL(p.maas_kurus)}</p>
          </div>
        )}
      </div>

      {/* Self-service is blocked server-side too — these buttons are hidden
          because they would only ever produce a Turkish refusal. */}
      {/* Ödemeler is its own row above the role controls, and it is offered
          for YOURSELF too: a Yönetici who pays themselves a salary still
          needs the screen. Role and status are the ones that must not be
          self-served, which is why only those sit behind `!ben`. */}
      {onAc && (
        <button
          type="button"
          onClick={onAc}
          className="mt-3 min-h-[44px] w-full rounded-field bg-accent-soft text-body font-medium text-accent"
        >
          Ödemeler
        </button>
      )}

      {!ben && (
        <div className="mt-2 flex gap-2">
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
              {p.durum === 'ACTIVE' ? 'Sil' : 'Geri ver'}
            </button>
          )}
        </div>
      )}
    </Card>
  )
}
