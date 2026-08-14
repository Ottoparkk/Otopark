-- =====================================================================
--  Otopark — 003_rls.sql
--  Row-level security, table/column grants, function EXECUTE grants,
--  and the plate-photo storage bucket.
--
--  Method: revoke EVERYTHING first, then grant back deliberately. Supabase
--  hands anon/authenticated broad default privileges on new objects, so
--  starting from zero is the only way to know what is actually reachable.
--
--  ⚠ THE ONE RULE THAT IS EASY TO GET WRONG:
--  `revoke ... from anon, authenticated` closes NOTHING on functions.
--  PostgreSQL grants EXECUTE on every new function to PUBLIC, and both roles
--  inherit from PUBLIC. The revoke MUST name `public` or the function stays
--  callable by anyone with a login. (This exact gap sat undetected in a sister
--  project for months.)
-- =====================================================================

-- ================================================== enable RLS on all ====

alter table public.profiles          enable row level security;
alter table public.otopark_ayarlari  enable row level security;
alter table public.park_yerleri      enable row level security;
alter table public.tarifeler         enable row level security;
alter table public.vardiyalar        enable row level security;
alter table public.abonmanlar        enable row level security;
alter table public.rezervasyonlar    enable row level security;
alter table public.hesaplar          enable row level security;
alter table public.hesap_araclari    enable row level security;
alter table public.puan_kurallari    enable row level security;
alter table public.biletler          enable row level security;
alter table public.puan_hareketleri  enable row level security;
alter table public.tahsilatlar       enable row level security;
alter table public.kasa_hareketleri  enable row level security;
alter table public.istisnalar        enable row level security;
alter table public.plaka_okuma_log   enable row level security;
alter table public.notifications     enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.audit_log         enable row level security;

-- ======================================================= policy helper ====

-- Used by the biletler/tahsilatlar policies. SECURITY DEFINER so the policy
-- does not recurse into vardiyalar's own RLS, and so there is exactly one
-- definition of "the till I am currently on".
create or replace function public.acik_vardiyam() returns uuid
language sql stable security definer set search_path = public as $$
  select v.id from public.vardiyalar v
   where v.personel_id = auth.uid() and v.kapanis_at is null
   limit 1;
$$;

-- ============================================ reset every table grant ====

do $$
declare r record;
begin
  for r in
    select c.relname
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'v')
  loop
    execute format('revoke all on public.%I from anon, authenticated', r.relname);
  end loop;
end $$;

-- =============================================================== policies

-- ---- profiles ------------------------------------------------------------
-- Own row always; Yönetici sees everyone (including PENDING signups to
-- approve); staff see each other's names so a ticket can say who made it —
-- but PENDING users stay invisible to Personel.
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (
    id = auth.uid()
    or public.is_yonetici()
    or (public.is_staff() and rol is not null and durum = 'ACTIVE')
  );

-- The write path exists, but the COLUMN grant below is what makes rol and
-- durum unreachable: a policy alone would let a user promote themselves.
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

grant select on public.profiles to authenticated;
grant update (ad_soyad, notif_prefs) on public.profiles to authenticated;

-- ---- otopark_ayarlari ----------------------------------------------------
drop policy if exists ayarlar_select on public.otopark_ayarlari;
create policy ayarlar_select on public.otopark_ayarlari for select to authenticated
  using (public.is_staff());
drop policy if exists ayarlar_update on public.otopark_ayarlari;
create policy ayarlar_update on public.otopark_ayarlari for update to authenticated
  using (public.is_yonetici()) with check (public.is_yonetici());

grant select, update on public.otopark_ayarlari to authenticated;

-- ---- park_yerleri --------------------------------------------------------
drop policy if exists yerler_select on public.park_yerleri;
create policy yerler_select on public.park_yerleri for select to authenticated
  using (public.is_staff());
drop policy if exists yerler_insert on public.park_yerleri;
create policy yerler_insert on public.park_yerleri for insert to authenticated
  with check (public.is_yonetici());
drop policy if exists yerler_update on public.park_yerleri;
create policy yerler_update on public.park_yerleri for update to authenticated
  using (public.is_yonetici()) with check (public.is_yonetici());
drop policy if exists yerler_delete on public.park_yerleri;
create policy yerler_delete on public.park_yerleri for delete to authenticated
  using (public.is_yonetici());

grant select, insert, update, delete on public.park_yerleri to authenticated;

-- ---- tarifeler -----------------------------------------------------------
-- Readable by all staff: the price is on the sign at the gate anyway, and the
-- exit screen needs it. NO write policy for anyone, including Yönetici —
-- tarife_guncelle() is the only way in, so the versioning discipline (close
-- the old row, open a new one) cannot be bypassed by an UPDATE.
drop policy if exists tarifeler_select on public.tarifeler;
create policy tarifeler_select on public.tarifeler for select to authenticated
  using (public.is_staff());

grant select on public.tarifeler to authenticated;

-- ---- vardiyalar ----------------------------------------------------------
drop policy if exists vardiyalar_select on public.vardiyalar;
create policy vardiyalar_select on public.vardiyalar for select to authenticated
  using (personel_id = auth.uid() or public.is_yonetici());

grant select on public.vardiyalar to authenticated;

-- ---- abonmanlar ----------------------------------------------------------
-- Yönetici only. Personel learn "let this car out free until 30 Nisan" from
-- abonman_gecerli_mi(), which returns a validity, never the negotiated price.
drop policy if exists abonmanlar_all on public.abonmanlar;
create policy abonmanlar_all on public.abonmanlar for all to authenticated
  using (public.is_yonetici()) with check (public.is_yonetici());

grant select, insert, update, delete on public.abonmanlar to authenticated;

-- ---- rezervasyonlar ------------------------------------------------------
-- Staff may READ these (they need to know a spot is spoken for) but carry no
-- price, so nothing financial leaks.
drop policy if exists rezervasyonlar_select on public.rezervasyonlar;
create policy rezervasyonlar_select on public.rezervasyonlar for select to authenticated
  using (public.is_staff());
drop policy if exists rezervasyonlar_insert on public.rezervasyonlar;
create policy rezervasyonlar_insert on public.rezervasyonlar for insert to authenticated
  with check (public.is_yonetici());
drop policy if exists rezervasyonlar_update on public.rezervasyonlar;
create policy rezervasyonlar_update on public.rezervasyonlar for update to authenticated
  using (public.is_yonetici()) with check (public.is_yonetici());
drop policy if exists rezervasyonlar_delete on public.rezervasyonlar;
create policy rezervasyonlar_delete on public.rezervasyonlar for delete to authenticated
  using (public.is_yonetici());

grant select, insert, update, delete on public.rezervasyonlar to authenticated;

-- ---- puan (loyalty) ------------------------------------------------------
-- Accounts, history and the earn rate are Yönetici-only. Personel reach
-- exactly one plate's balance through hesap_puan_durumu().
drop policy if exists hesaplar_all on public.hesaplar;
create policy hesaplar_all on public.hesaplar for all to authenticated
  using (public.is_yonetici()) with check (public.is_yonetici());
drop policy if exists hesap_araclari_all on public.hesap_araclari;
create policy hesap_araclari_all on public.hesap_araclari for all to authenticated
  using (public.is_yonetici()) with check (public.is_yonetici());
drop policy if exists puan_kurallari_select on public.puan_kurallari;
create policy puan_kurallari_select on public.puan_kurallari for select to authenticated
  using (public.is_yonetici());

grant select, insert, update, delete on public.hesaplar to authenticated;
grant select, insert, update, delete on public.hesap_araclari to authenticated;
grant select on public.puan_kurallari to authenticated;

-- Append-only ledger: SELECT for Yönetici, and no write policy for anyone.
-- Outstanding points are a real lira liability, so corrections are
-- counter-entries via RPC — never an UPDATE, never a DELETE.
drop policy if exists puan_hareketleri_select on public.puan_hareketleri;
create policy puan_hareketleri_select on public.puan_hareketleri for select to authenticated
  using (public.is_yonetici());

grant select on public.puan_hareketleri to authenticated;

-- ---- biletler ------------------------------------------------------------
-- Personel see what they need to do their job and nothing more: every open
-- ticket, plus the ones they themselves closed on the till they are currently
-- signed in to. When their shift closes those rows leave their view, so
-- "historical revenue" never accumulates.
--
-- NO insert/update/delete policy exists. Every write goes through a
-- SECURITY DEFINER RPC, which is what makes "the client cannot set a fee"
-- structural instead of a promise.
drop policy if exists biletler_select on public.biletler;
create policy biletler_select on public.biletler for select to authenticated
  using (
    public.is_yonetici()
    or (public.is_staff()
        and (durum = 'ACIK' or kapatan_vardiya_id = public.acik_vardiyam()))
  );

grant select on public.biletler to authenticated;

-- ---- tahsilatlar ---------------------------------------------------------
-- Personel see only their own open shift's collections — their own cash
-- drawer, which they must be able to reconcile. Not history, not other people.
drop policy if exists tahsilatlar_select on public.tahsilatlar;
create policy tahsilatlar_select on public.tahsilatlar for select to authenticated
  using (public.is_yonetici() or vardiya_id = public.acik_vardiyam());

grant select on public.tahsilatlar to authenticated;

-- ---- kasa_hareketleri ----------------------------------------------------
drop policy if exists kasa_all on public.kasa_hareketleri;
create policy kasa_all on public.kasa_hareketleri for all to authenticated
  using (public.is_yonetici()) with check (public.is_yonetici());

grant select, insert, update, delete on public.kasa_hareketleri to authenticated;

-- ---- istisnalar ----------------------------------------------------------
-- Staff-readable on purpose: an orphan exit is a problem at the gate, and it
-- holds no financial data. Resolution goes through istisna_coz().
drop policy if exists istisnalar_select on public.istisnalar;
create policy istisnalar_select on public.istisnalar for select to authenticated
  using (public.is_staff());

grant select on public.istisnalar to authenticated;

-- ---- plaka_okuma_log -----------------------------------------------------
drop policy if exists plaka_log_select on public.plaka_okuma_log;
create policy plaka_log_select on public.plaka_okuma_log for select to authenticated
  using (public.is_yonetici());

grant select on public.plaka_okuma_log to authenticated;

-- ---- notifications -------------------------------------------------------
-- Own rows, re-checking the CURRENT role per type: rows generated while
-- someone was Yönetici must stop being visible the moment they are demoted.
drop policy if exists notifications_select on public.notifications;
create policy notifications_select on public.notifications for select to authenticated
  using (
    profile_id = auth.uid()
    and (not public.bildirim_yonetici_turu(tur) or public.is_yonetici())
  );
drop policy if exists notifications_update on public.notifications;
create policy notifications_update on public.notifications for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());

grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;

-- ---- push_subscriptions --------------------------------------------------
drop policy if exists push_select on public.push_subscriptions;
create policy push_select on public.push_subscriptions for select to authenticated
  using (profile_id = auth.uid());
drop policy if exists push_update on public.push_subscriptions;
create policy push_update on public.push_subscriptions for update to authenticated
  using (profile_id = auth.uid()) with check (profile_id = auth.uid());
drop policy if exists push_delete on public.push_subscriptions;
create policy push_delete on public.push_subscriptions for delete to authenticated
  using (profile_id = auth.uid());

grant select, update, delete on public.push_subscriptions to authenticated;

-- ---- audit_log -----------------------------------------------------------
drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log for select to authenticated
  using (public.is_yonetici());

grant select on public.audit_log to authenticated;

-- ---- v_hesap_puan --------------------------------------------------------
-- security_invoker = true is set on the view itself (002). Without it the
-- view would run as its owner and hand Personel the whole ledger.
grant select on public.v_hesap_puan to authenticated;

-- ================================================ function EXECUTE ========

-- Close everything, including the implicit grant to PUBLIC. See the warning
-- at the top of this file — omitting `public` here closes nothing.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
  loop
    execute format('revoke all on function %s from public, anon, authenticated, service_role', r.sig);
  end loop;
end $$;

-- Trigger functions: invoked by the system, never by a client. Called
-- directly they raise ("trigger functions can only be called as triggers"),
-- so re-granting them is harmless and avoids any doubt about whether the
-- executor re-checks EXECUTE at fire time.
grant execute on function public.handle_new_user() to public;
grant execute on function public.biletler_immutable_guard() to public;

-- Predicates evaluated INSIDE policies, so the querying role must be able to
-- run them. They return false for anon and leak nothing.
grant execute on function public.is_yonetici() to anon, authenticated;
grant execute on function public.is_staff() to anon, authenticated;
grant execute on function public.acik_vardiyam() to anon, authenticated;
-- service_role too: send-push re-checks the recipient's CURRENT role before
-- delivering, so a demoted user's phone stops receiving Yönetici notices.
-- Without that check push would be a side channel around the RLS policy.
grant execute on function public.bildirim_yonetici_turu(public.bildirim_tur)
  to anon, authenticated, service_role;
grant execute on function public.normalize_plaka(text) to anon, authenticated;

-- Staff RPCs. Each one re-checks the role internally: hiding a button is
-- cosmetic, the RPC is the boundary.
grant execute on function public.ucret_hesapla_core(timestamptz, timestamptz, integer, integer, integer, integer) to authenticated;
grant execute on function public.ucret_hesapla(timestamptz, timestamptz, uuid) to authenticated;
grant execute on function public.aktif_tarife(public.arac_tipi) to authenticated;
grant execute on function public.bilet_ac(text, public.arac_tipi, uuid, public.kaynak, timestamptz, text, uuid, jsonb) to authenticated;
grant execute on function public.bilet_kapat(uuid, public.odeme_yontemi, integer, text, text, public.kaynak) to authenticated;
grant execute on function public.bilet_iptal(uuid, text) to authenticated;
grant execute on function public.bilet_arac_tipi_duzelt(uuid, public.arac_tipi) to authenticated;
grant execute on function public.kayip_bilet_tahsil(text, public.arac_tipi, public.odeme_yontemi, uuid) to authenticated;
grant execute on function public.acik_bilet_ara(text) to authenticated;
grant execute on function public.abonman_gecerli_mi(text) to authenticated;
grant execute on function public.hesap_puan_durumu(text) to authenticated;
grant execute on function public.puan_kullan(uuid, integer) to authenticated;
grant execute on function public.puan_kullanim_geri_al(uuid) to authenticated;
grant execute on function public.vardiya_ac(integer) to authenticated;
grant execute on function public.vardiya_kapat(integer, text) to authenticated;
grant execute on function public.vardiya_ozetim() to authenticated;
grant execute on function public.gunluk_ozet() to authenticated;
grant execute on function public.istisna_coz(uuid, text) to authenticated;
grant execute on function public.plaka_okuma_kabul(uuid, text) to authenticated;
grant execute on function public.save_push_subscription(text, text, text) to authenticated;

-- Yönetici-only RPCs. Granted to `authenticated` because the guard lives in
-- the function body — a Personel calling these gets a Turkish refusal, not a
-- 404, which is both the correct boundary and a better error.
grant execute on function public.approve_signup(uuid, public.rol) to authenticated;
grant execute on function public.set_role(uuid, public.rol) to authenticated;
grant execute on function public.set_status(uuid, public.kullanici_durum) to authenticated;
grant execute on function public.abonman_tahsil(uuid, public.odeme_yontemi, integer) to authenticated;
grant execute on function public.tarife_guncelle(public.arac_tipi, integer, integer, integer, integer, integer) to authenticated;
grant execute on function public.puan_kural_guncelle(integer, integer, integer, integer) to authenticated;
grant execute on function public.rapor_gunluk(date, date) to authenticated;
grant execute on function public.rapor_ozet(date, date) to authenticated;

-- The camera path only. These three are all the webhook may call.
--
-- Honest note on the limit of this control: service_role is a BYPASSRLS role,
-- so it is privileged by construction and this grant list is not a sandbox —
-- it constrains our Edge Function, not an attacker holding the key. The real
-- protection is that the service key never leaves the function, the webhook
-- validates a shared secret before doing anything, and it is rate-limited and
-- daily-capped. Treat a leaked service key as total compromise, as always.
grant execute on function public.bilet_ac(text, public.arac_tipi, uuid, public.kaynak, timestamptz, text, uuid, jsonb) to service_role;
grant execute on function public.kamera_cikis_bildir(text, uuid, timestamptz, text, jsonb) to service_role;
grant execute on function public.kamera_kalp() to service_role;

-- Deliberately granted to NOBODY: audit(), notify_yonetici(), istisna_yaz()
-- and puan_kazandir() are reachable only from inside the SECURITY DEFINER
-- functions above, where the owner's privileges apply. A client that could
-- call notify_yonetici() directly could forge alerts; one that could call
-- puan_kazandir() could mint points.

-- ================================================ verify the revokes ======

-- If the loop above ever stops matching (a function added later, a rename),
-- this fails the migration loudly instead of leaving a hole open silently.
do $$
declare v_leak text;
begin
  select string_agg(p.oid::regprocedure::text, ', ')
    into v_leak
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prokind = 'f'
     and p.proname in ('audit','notify_yonetici','istisna_yaz','puan_kazandir')
     and has_function_privilege('authenticated', p.oid, 'execute');

  if v_leak is not null then
    raise exception 'GÜVENLİK: içeride kalması gereken fonksiyonlar istemciye açık: %', v_leak;
  end if;
end $$;

-- ==================================================== storage bucket ======

-- Private bucket. Plate photos are personal data under KVKK and are purged
-- nightly by 004; access is always via short-lived signed URLs.
insert into storage.buckets (id, name, public)
values ('plaka-foto', 'plaka-foto', false)
on conflict (id) do nothing;

drop policy if exists plaka_foto_select on storage.objects;
create policy plaka_foto_select on storage.objects for select to authenticated
  using (bucket_id = 'plaka-foto' and public.is_staff());
drop policy if exists plaka_foto_insert on storage.objects;
create policy plaka_foto_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'plaka-foto' and public.is_staff());
drop policy if exists plaka_foto_delete on storage.objects;
create policy plaka_foto_delete on storage.objects for delete to authenticated
  using (bucket_id = 'plaka-foto' and public.is_yonetici());
