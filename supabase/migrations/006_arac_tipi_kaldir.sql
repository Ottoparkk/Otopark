-- ============================================================================
-- 006  Araç tipi kaldırıldı — tek tarife
-- ============================================================================
--
-- Owner decision (2026-08-25): the lot charges ONE rate. The four vehicle
-- classes (MOTOSIKLET / OTOMOBIL / MINIBUS / KAMYONET) were a distinction the
-- business does not make, and every one of them cost a decision at the barrier
-- plus a tariff to keep current.
--
-- WHAT SURVIVES, AND WHY
--
--   Closed tickets keep their money. `biletler.tarife_id` is a SNAPSHOT taken
--   at entry, and `ucret_hesapla(giris, cikis, tarife_id)` never took the
--   vehicle type — it reads the rate off the snapshotted row. So a motorbike
--   that entered under the motorbike rate is still priced by that rate
--   forever, and no historical total moves because of this migration. Only
--   the `arac_tipi` LABEL is dropped from the row.
--
--   Of the four currently-active tariffs, OTOMOBIL is kept as the single
--   active one and the other three are closed with `gecerli_bitis = now()`.
--   Closing rather than deleting is the versioning rule this schema already
--   follows: a tariff row is referenced by every ticket priced under it, so
--   it must remain readable.
--
-- 001-005 ARE LEFT ALONE ON PURPOSE. They still create the enum and seed four
-- tariffs, and that is fine in both directions: a fresh database runs
-- 001→006 and this file collapses them, while the already-deployed one runs
-- only this file. Editing 005 instead would break the fresh path, because
-- 001 still declares tarifeler.arac_tipi NOT NULL at that point.
--
-- ORDER MATTERS. Functions that mention `public.arac_tipi` in their SIGNATURE
-- must be DROPPED before the type can go, and `create or replace` cannot be
-- used to change a parameter list — it would add an OVERLOAD and leave the old
-- one callable. So: drop functions → drop columns → drop type → recreate.
-- ============================================================================

begin;

-- ---------------------------------------------------------------- tariffs --
-- Collapse to one active row BEFORE the column goes, while the type is still
-- there to choose by. Guard on the count so re-running is harmless.
update public.tarifeler
   set gecerli_bitis = now()
 where gecerli_bitis is null
   and arac_tipi <> 'OTOMOBIL';

-- If OTOMOBIL was never seeded there would now be zero active tariffs and the
-- gate would refuse every entry. Fail loudly here instead.
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.tarifeler where gecerli_bitis is null;
  if v_n <> 1 then
    raise exception '006: tam olarak 1 aktif tarife bekleniyordu, % bulundu', v_n;
  end if;
end $$;

-- ------------------------------------------------- drop dependent objects --
-- Signature-level dependencies on the enum.
drop function if exists public.aktif_tarife(public.arac_tipi);
drop function if exists public.bilet_ac(text, public.arac_tipi, uuid, public.kaynak, timestamptz, text, uuid, jsonb);
drop function if exists public.kayip_bilet_tahsil(text, public.arac_tipi, public.odeme_yontemi, uuid);
drop function if exists public.tarife_guncelle(public.arac_tipi, integer, integer, integer, integer, integer);
drop function if exists public.acik_bilet_ara(text);

-- Gone for good: with a single tariff there is no type to correct, and the
-- RPC existed only to re-snapshot the tariff after a mis-typed vehicle.
drop function if exists public.bilet_arac_tipi_duzelt(uuid, public.arac_tipi);

-- ------------------------------------------------------------- columns ----
-- The partial unique index was "one active tariff PER TYPE". With the type
-- gone the invariant becomes "one active tariff, full stop" — expressed as a
-- unique index on a constant, which is the standard way to say it.
drop index if exists public.tarifeler_aktif_ux;
alter table public.tarifeler      drop column if exists arac_tipi;
create unique index if not exists tarifeler_aktif_ux
  on public.tarifeler ((true)) where gecerli_bitis is null;

alter table public.biletler       drop column if exists arac_tipi;
alter table public.otopark_ayarlari drop column if exists kamera_varsayilan_arac_tipi;

drop type if exists public.arac_tipi;

-- ------------------------------------------------------------ functions ---
--
-- NOTE: every body below is the ORIGINAL from 002_functions.sql with only the
-- araç-tipi references removed — derived mechanically, not retyped. A hand
-- rewrite of bilet_ac dropped three load-bearing things on the first attempt:
-- the check that refuses `p_kaynak = 'KAMERA'` from a logged-in client (which
-- would have handed staff `p_zaman` and made silent under-billing trivial),
-- the `biletler_acik_plaka_ux` branch that turns a duplicate open ticket into
-- a Turkish message, and the "no points on a ₺0 subscriber stay" guard.
-- If these ever need editing again, transform the source — do not retype it.

create or replace function public.aktif_tarife()
returns uuid
language sql stable security definer set search_path = public as $$
  select t.id from public.tarifeler t
  where t.gecerli_bitis is null
  limit 1;
$$;

create or replace function public.bilet_ac(
  p_plaka        text,
  p_islem_id     uuid,
  p_kaynak       public.kaynak default 'MOBIL',
  p_zaman        timestamptz default null,
  p_foto         text default null,
  p_park_yeri_id uuid default null,
  p_ham_yanit    jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plaka      text;
  v_zaman      timestamptz;
  v_limit_dk   integer;
  v_puan_aktif boolean;
  v_tarife     uuid;
  v_abonman    uuid;
  v_vardiya    uuid;
  v_gecikmeli  boolean := false;
  v_id         uuid;
  v_con        text;
begin
  -- Two disjoint callers, and keeping them disjoint is load-bearing:
  --   • staff (a JWT is present)                  → MOBIL/MANUEL, and the time
  --                                                 is ALWAYS the server's
  --   • the webhook (service_role, auth.uid() IS NULL) → KAMERA, the only
  --                                                 caller allowed to supply
  --                                                 p_zaman
  --
  -- `is_staff() OR (uid IS NULL AND KAMERA)` was NOT enough: staff satisfy the
  -- first branch, so they could pass p_kaynak = 'KAMERA' themselves — and that
  -- hands them p_zaman. It is a silent mis-billing tool: record an 08:00
  -- arrival as 13:00 and five billable hours vanish, leaving a ticket that
  -- looks completely ordinary. The source must match WHO is calling, not
  -- merely what the caller claims to be.
  if p_kaynak = 'KAMERA' then
    if auth.uid() is not null then
      raise exception 'Kamera kaynağı istemciden kullanılamaz.';
    end if;
  elsif not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;

  v_plaka := public.normalize_plaka(p_plaka);
  if v_plaka !~ '^[A-Z0-9]{2,15}$' then
    raise exception 'Geçersiz plaka: %', coalesce(p_plaka, '(boş)');
  end if;

  if p_kaynak = 'KAMERA' then
    if p_zaman is null then
      raise exception 'Kamera kaydı zaman damgası olmadan kabul edilmez.';
    end if;
    v_zaman := p_zaman;
  else
    v_zaman := now();   -- a client-supplied timestamp is ignored, by design
  end if;

  select o.kamera_gecikme_limiti_dk, o.puan_aktif
    into v_limit_dk, v_puan_aktif
    from public.otopark_ayarlari o where o.id = 1;
  v_limit_dk := coalesce(v_limit_dk, 720);

  -- A clock ahead of ours is not a late event, it is a broken camera.
  if v_zaman > now() + interval '5 minutes' then
    perform public.istisna_yaz('GELECEK', 'GIRIS', v_plaka, p_kaynak, p_islem_id,
                               p_ham_yanit, p_foto, v_zaman);
    return null;
  end if;

  -- Too old to be honest: the car has almost certainly already left, and a
  -- ticket opened now would be fiction that bills someone at exit.
  if v_zaman < now() - make_interval(mins => v_limit_dk) then
    perform public.istisna_yaz('BAYAT', 'GIRIS', v_plaka, p_kaynak, p_islem_id,
                               p_ham_yanit, p_foto, v_zaman);
    return null;
  end if;

  v_gecikmeli := (p_kaynak = 'KAMERA' and v_zaman < now() - interval '2 minutes');

  v_tarife := public.aktif_tarife();
  if v_tarife is null then
    raise exception 'Aktif tarife tanımlı değil.';
  end if;

  -- A valid subscriber enters free; the ticket exists purely as a record.
  select a.id into v_abonman
    from public.abonmanlar a
   where a.plaka = v_plaka and a.durum = 'AKTIF'
     and (now() at time zone 'Europe/Istanbul')::date between a.baslangic and a.bitis
   limit 1;

  if auth.uid() is not null then
    select v.id into v_vardiya from public.vardiyalar v
     where v.personel_id = auth.uid() and v.kapanis_at is null limit 1;
  end if;

  begin
    insert into public.biletler (
      islem_id, plaka, giris_at, tarife_id, abonman_id, park_yeri_id,
      vardiya_id, giris_by, giris_kaynak, giris_foto,
      gecikmeli_kayit, kaynak_zaman, alindi_zaman
    ) values (
      p_islem_id, v_plaka, v_zaman, v_tarife, v_abonman, p_park_yeri_id,
      v_vardiya, auth.uid(), p_kaynak, p_foto,
      v_gecikmeli, case when p_kaynak = 'KAMERA' then p_zaman end, now()
    ) returning id into v_id;
  exception when unique_violation then
    -- Which index fired is decided by LOOKING, not by trusting the diagnostic
    -- string: a row already carrying this islem_id is the definitive proof of
    -- a replay, and it stays correct if an index is ever renamed.
    select b.id into v_id from public.biletler b where b.islem_id = p_islem_id;
    if v_id is not null then
      -- Replay. Every ANPR camera retries a failed POST, and retry-on-blip
      -- retries from the phone: return the original, never a second ticket.
      return v_id;
    end if;

    get stacked diagnostics v_con = constraint_name;
    if v_con = 'biletler_acik_plaka_ux'
       or exists (select 1 from public.biletler b
                   where b.plaka = v_plaka and b.durum = 'ACIK') then
      raise exception 'Bu plaka için zaten açık bir bilet var: %', v_plaka;
    end if;
    raise;
  end;

  -- No points on a ₺0 stay: subscribers would otherwise farm rewards for
  -- parking they did not pay for.
  if coalesce(v_puan_aktif, false) and v_abonman is null then
    perform public.puan_kazandir(v_id, v_plaka);
  end if;

  return v_id;
end $$;

create or replace function public.kayip_bilet_tahsil(
  p_plaka         text,
  p_odeme_yontemi public.odeme_yontemi,
  p_islem_id      uuid
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plaka   text;
  v_t       public.tarifeler;
  v_now     timestamptz := now();
  v_vardiya uuid;
  v_id      uuid;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;

  v_plaka := public.normalize_plaka(p_plaka);
  if v_plaka !~ '^[A-Z0-9]{2,15}$' then
    raise exception 'Geçersiz plaka: %', coalesce(p_plaka, '(boş)');
  end if;

  select * into v_t from public.tarifeler where gecerli_bitis is null;
  if not found then
    raise exception 'Aktif tarife tanımlı değil.';
  end if;
  if v_t.kayip_bilet_kurus <= 0 then
    raise exception 'Kayıp bilet ücreti tanımlı değil. Tarifeden belirleyin.';
  end if;

  select v.id into v_vardiya from public.vardiyalar v
   where v.personel_id = auth.uid() and v.kapanis_at is null limit 1;

  begin
    insert into public.biletler (
      islem_id, plaka, giris_at, cikis_at, tarife_id,
      ucret_kurus, tahsil_kurus, odeme_yontemi, durum,
      vardiya_id, kapatan_vardiya_id, giris_by, cikis_by,
      giris_kaynak, cikis_kaynak, kayip_bilet, alindi_zaman
    ) values (
      p_islem_id, v_plaka, v_now, v_now, v_t.id,
      v_t.kayip_bilet_kurus, v_t.kayip_bilet_kurus, p_odeme_yontemi, 'KAPALI',
      v_vardiya, v_vardiya, auth.uid(), auth.uid(),
      'MANUEL', 'MANUEL', true, v_now
    ) returning id into v_id;
  exception when unique_violation then
    select b.id into v_id from public.biletler b where b.islem_id = p_islem_id;
    if v_id is not null then
      return v_id;   -- replay
    end if;
    raise;
  end;

  insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, created_by, aciklama)
  values ('BILET', v_id, v_t.kayip_bilet_kurus, p_odeme_yontemi, v_vardiya, auth.uid(), 'Kayıp bilet');

  perform public.audit('kayip_bilet', 'biletler', v_id,
    jsonb_build_object('plaka', v_plaka, 'tutar', v_t.kayip_bilet_kurus));

  return v_id;
end $$;

create or replace function public.acik_bilet_ara(p_q text default null)
returns table (
  id uuid, plaka text, giris_at timestamptz,
  abonman_id uuid, park_yeri_id uuid, cikis_bekliyor_at timestamptz,
  indirim_kurus integer, puan_kullanilan integer, tarife_id uuid,
  gecikmeli_kayit boolean
)
language plpgsql stable security definer set search_path = public as $$
declare v_q text := public.normalize_plaka(p_q);
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  return query
  select b.id, b.plaka, b.giris_at,
         b.abonman_id, b.park_yeri_id, b.cikis_bekliyor_at,
         b.indirim_kurus, b.puan_kullanilan, b.tarife_id, b.gecikmeli_kayit
    from public.biletler b
   where b.durum = 'ACIK'
     and (v_q = '' or b.plaka like '%' || v_q || '%'
                   or (length(v_q) >= 3 and right(b.plaka, length(v_q)) = v_q))
   order by
     case when v_q = '' then 2
          when b.plaka = v_q then 0
          when b.plaka like v_q || '%' then 1
          else 2 end,
     b.cikis_bekliyor_at desc nulls last,
     b.giris_at desc
   limit 50;
end $$;

create or replace function public.tarife_guncelle(
  p_ucretsiz_dakika    integer,
  p_ilk_saat_kurus     integer,
  p_sonraki_saat_kurus integer,
  p_gunluk_tavan_kurus integer,
  p_kayip_bilet_kurus  integer
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_kesim timestamptz;
  v_id    uuid;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici tarife değiştirebilir.';
  end if;

  -- Two concurrent edits must not both close the current row and race to
  -- insert; the partial unique index would refuse the loser with a confusing
  -- error instead of simply serialising.
  perform pg_advisory_xact_lock(hashtext('tarife'));

  select greatest(now(), t.gecerli_baslangic + interval '1 millisecond')
    into v_kesim
    from public.tarifeler t
   where t.gecerli_bitis is null;
  v_kesim := coalesce(v_kesim, now());

  update public.tarifeler set gecerli_bitis = v_kesim
   where gecerli_bitis is null;

  insert into public.tarifeler (
    ucretsiz_dakika, ilk_saat_kurus, sonraki_saat_kurus,
    gunluk_tavan_kurus, kayip_bilet_kurus, gecerli_baslangic, olusturan)
  values (
    p_ucretsiz_dakika, p_ilk_saat_kurus, p_sonraki_saat_kurus,
    p_gunluk_tavan_kurus, p_kayip_bilet_kurus, v_kesim, auth.uid())
  returning id into v_id;

  perform public.audit('tarife_guncelle', 'tarifeler', v_id,
    jsonb_build_object('ilk_saat', p_ilk_saat_kurus,
                       'sonraki_saat', p_sonraki_saat_kurus,
                       'gunluk_tavan', p_gunluk_tavan_kurus));
  return v_id;
end $$;

-- ---------------------------------------------------------------- grants --
-- The dropped functions took their grants with them; the new signatures need
-- their own. Anything not listed stays revoked from every client role.
-- İKİ yol birden kapatılmalı, ve `from public` yalnızca birincisini kapatır:
--   1. PostgreSQL yeni fonksiyona EXECUTE'u PUBLIC'e verir (`authenticated` de
--      PUBLIC üyesidir).
--   2. Supabase ayrıca `anon`, `authenticated` ve `service_role` rollerine
--      DOĞRUDAN verir — bu, PUBLIC'ten geri alınınca kalkmaz.
-- 009'un doğrulama bloğu bunu canlıda yakaladı; ayrıntısı 012'de.
revoke all on function public.aktif_tarife() from public, anon, authenticated, service_role;
revoke all on function public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb) from public, anon, authenticated, service_role;
revoke all on function public.kayip_bilet_tahsil(text, public.odeme_yontemi, uuid) from public, anon, authenticated, service_role;
revoke all on function public.acik_bilet_ara(text) from public, anon, authenticated, service_role;
revoke all on function public.tarife_guncelle(integer, integer, integer, integer, integer) from public, anon, authenticated, service_role;

grant execute on function public.aktif_tarife() to authenticated;
grant execute on function public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb) to authenticated;
grant execute on function public.kayip_bilet_tahsil(text, public.odeme_yontemi, uuid) to authenticated;
grant execute on function public.acik_bilet_ara(text) to authenticated;
grant execute on function public.tarife_guncelle(integer, integer, integer, integer, integer) to authenticated;

-- The camera webhook runs as service_role and has no JWT, which is why
-- bilet_ac tolerates a null auth.uid().
grant execute on function public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb) to service_role;

-- Prove the removal actually landed rather than assuming it did. An earlier
-- draft asked has_function_privilege() for a signature that can no longer be
-- parsed once the enum is gone — it always took the exception branch and
-- therefore always "passed" without checking anything. Ask the catalogue.
do $$
declare v_n integer;
begin
  select count(*) into v_n from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'bilet_arac_tipi_duzelt';
  if v_n <> 0 then
    raise exception '006: bilet_arac_tipi_duzelt hâlâ mevcut (% adet)', v_n;
  end if;

  if exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
              where n.nspname = 'public' and t.typname = 'arac_tipi') then
    raise exception '006: arac_tipi tipi hâlâ mevcut';
  end if;

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and column_name = 'arac_tipi') then
    raise exception '006: arac_tipi kolonu hâlâ mevcut';
  end if;

  -- Overload check: changing a parameter list with `create or replace` adds a
  -- second function instead of replacing the first, and the old one stays
  -- callable. Exactly one of each must exist.
  select count(*) into v_n from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('bilet_ac', 'kayip_bilet_tahsil', 'tarife_guncelle', 'aktif_tarife');
  if v_n <> 4 then
    raise exception '006: beklenen 4 fonksiyon yerine % bulundu (aşırı yükleme?)', v_n;
  end if;
end $$;

commit;
