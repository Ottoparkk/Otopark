-- ============================================================================
-- 045  Okunamayan plaka bildirimi: yeniden denemelerden sonra, herkese
-- ============================================================================

begin;

-- Owner (2026-10-31). The "Çözülmemiş kayıt — OKUNAMADI" notification went
-- out the moment the camera could not read a plate. If the webhook's answer
-- never reached the bridge (a read slower than its 30 s, a Wi-Fi blip), the
-- bridge retried the same event and might read it — on the single gate the
-- record then closed itself (041), but everyone had already been told about a
-- problem that fixed itself. Now:
--   • the notification waits until the bridge's retries are surely over —
--     3 minutes (bridge 1.2.4 worst case ≈ 2 min 7 s: 4 × 30 s + 1/2/4 s
--     pauses) — and goes out only if the record is STILL open;
--   • it goes to every role (Yönetici and Personel), not just the Yönetici;
--   • on the entrance lane too, a camera retry that opens the ticket closes
--     the record (041 did this only on the single gate).
-- The server cannot see whether the bridge received its answer, which is why
-- it waits: until the retry window has passed, a retry may still come.
-- Other exception kinds are unchanged (immediate, Yönetici only): a retry
-- cannot change their outcome. Service-down rows (039 kamera_okuma_hatasi)
-- still produce no per-car notification at all.

alter table public.istisnalar
  add column if not exists bildirim_bekliyor boolean not null default false;
create index if not exists istisnalar_bildirim_bekliyor_ix
  on public.istisnalar (created_at) where bildirim_bekliyor;

-- ---------------------------------------------------------------- yazma ----
-- Body from 002 (its only definition); the one change is the OKUNAMADI
-- branch: held instead of notified. Same signature → grants (none) kept.
create or replace function public.istisna_yaz(
  p_tur          public.istisna_tur,
  p_yon          text,
  p_plaka        text,
  p_kaynak       public.kaynak,
  p_islem_id     uuid,
  p_ham          jsonb,
  p_foto         text,
  p_kaynak_zaman timestamptz,
  p_adaylar      uuid[] default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.istisnalar (
    tur, yon, plaka, kaynak, islem_id, ham_yanit, foto_path, kaynak_zaman, aday_bilet_ids,
    bildirim_bekliyor)
  values (p_tur, p_yon, p_plaka, p_kaynak, p_islem_id, p_ham, p_foto, p_kaynak_zaman, p_adaylar,
          p_tur::text = 'OKUNAMADI')
  on conflict (islem_id) where islem_id is not null do nothing
  returning id into v_id;

  if v_id is null then
    select i.id into v_id from public.istisnalar i where i.islem_id = p_islem_id;
    return v_id;   -- already logged; stay quiet
  end if;

  -- 045: an unreadable plate is told later, by istisna_bildirim_gonder, and
  -- only if no camera retry has closed it by then.
  if p_tur::text = 'OKUNAMADI' then
    return v_id;
  end if;

  perform public.notify_yonetici(
    'ISTISNA', 'Çözülmemiş kayıt',
    p_tur::text || ' — ' || coalesce(p_plaka, 'plaka okunamadı'),
    -- Not under /yonetim: istisnalar is staff-readable by design (an orphan
    -- exit is a problem at the gate) and the screen lives at /istisnalar.
    '/istisnalar');
  return v_id;
end $$;

-- ---------------------------------------------------------------- herkes ---
-- Every active staff member — same filters as notify_yonetici (active,
-- preference not off, never the caller). A Yönetici-only type still reaches
-- only Yöneticis, so this can never write a row its reader may not see.
create or replace function public.notify_herkes(
  p_tur public.bildirim_tur, p_baslik text, p_govde text, p_link text default null
) returns void
language sql security definer set search_path = public as $fn$
  insert into public.notifications (profile_id, tur, baslik, govde, link)
  select p.id, p_tur, p_baslik, p_govde, p_link
  from public.profiles p
  where p.rol is not null
    and p.durum = 'ACTIVE'
    and (not public.bildirim_yonetici_turu(p_tur) or p.rol = 'YONETICI')
    and (auth.uid() is null or p.id <> auth.uid())
    and coalesce(p.notif_prefs ->> p_tur::text, 'true') <> 'false';
$fn$;

-- ------------------------------------------------------------ gecikmeli ----
-- Runs every minute (cron below). Each held record is decided ONCE: still
-- open → everyone is told; closed meanwhile (camera retry, or a person) →
-- nothing. `try` lock (060 pattern): an overlapping tick skips instead of
-- queueing, and `skip locked` keeps two runs from touching the same row.
create or replace function public.istisna_bildirim_gonder() returns void
language plpgsql security definer set search_path = public as $fn$
declare
  r record;
begin
  if not pg_try_advisory_xact_lock(hashtext('istisna_bildirim_gonder')) then
    return;
  end if;
  for r in
    select i.id, i.plaka, i.cozuldu_at
      from public.istisnalar i
     where i.bildirim_bekliyor
       and i.created_at <= now() - interval '3 minutes'
     order by i.created_at
     for update skip locked
  loop
    if r.cozuldu_at is null then
      perform public.notify_herkes(
        'ISTISNA', 'Çözülmemiş kayıt',
        'OKUNAMADI — ' || coalesce(r.plaka, 'plaka okunamadı'),
        '/istisnalar');
    end if;
    update public.istisnalar set bildirim_bekliyor = false where id = r.id;
  end loop;
end
$fn$;

-- -------------------------------------------------------- giriş şeridi ----
-- A camera ticket for an event that already has an open OKUNAMADI record on
-- the entrance lane means a retry read the plate: the record closes itself,
-- like 041 does on the single gate. ORTAK rows are left to 041 (its own note
-- carries the decision); a ticket opened by staff (MOBIL, 044) never fires
-- this — istisna_bilet_ac closes its record itself.
create or replace function public.kamera_okunamadi_kapat() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  update public.istisnalar
     set cozuldu_at = now(),
         cozum_notu = 'Kamera yeniden denedi ve okudu: ' || new.plaka || ' → GIRIS'
   where islem_id = new.islem_id
     and tur::text = 'OKUNAMADI'
     and yon = 'GIRIS'
     and cozuldu_at is null;
  return null;
end
$fn$;

drop trigger if exists kamera_okunamadi_kapat_tg on public.biletler;
create trigger kamera_okunamadi_kapat_tg
  after insert on public.biletler
  for each row
  when (new.giris_kaynak = 'KAMERA' and new.islem_id is not null)
  execute function public.kamera_okunamadi_kapat();

-- ------------------------------------------------------- herkese açık tür --
-- Body from 035 (latest) without 'ISTISNA': Personel now receives these, and
-- the notifications policy (003) and send-push both ask this function. Rows
-- written before 045 belong to Yönetici profiles only, so nothing old
-- becomes visible to anyone new. Same signature → grants kept.
create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $fn$
  select p_tur::text in (
    'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA',
    'KAMERA_HAREKET','VARDIYA_ACIK','ONAY_BEKLIYOR','PLAKA_SUPHE',
    'VARDIYA_KAPATMA'
  );
$fn$;

-- ---------------------------------------------------------------- yetki ----
-- All four roles, `public` included (033/058): Supabase grants new functions
-- to anon, authenticated and service_role separately, and PUBLIC on top.
revoke all on function public.notify_herkes(public.bildirim_tur, text, text, text)
  from public, anon, authenticated, service_role;
revoke all on function public.istisna_bildirim_gonder()
  from public, anon, authenticated, service_role;
revoke all on function public.kamera_okunamadi_kapat()
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------- cron ----
-- Every minute: a held notification goes out 3–4 minutes after the car.
-- Same name = update in place if it already exists.
select cron.schedule('otopark-istisna-bildirim', '* * * * *',
                     $$select public.istisna_bildirim_gonder()$$);

-- ------------------------------------------------------------- doğrulama ---
do $do$
declare
  f text;
  r text;
  v_def text;
begin
  foreach f in array array[
    'public.notify_herkes(public.bildirim_tur, text, text, text)',
    'public.istisna_bildirim_gonder()',
    'public.kamera_okunamadi_kapat()'] loop
    if not exists (select 1 from pg_proc where oid = f::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
      raise exception '045: % SECURITY DEFINER + search_path=public değil', f;
    end if;
    foreach r in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception '045: % % rolüne açık', f, r;
      end if;
    end loop;
  end loop;

  if not exists (select 1 from pg_trigger
                  where tgname = 'kamera_okunamadi_kapat_tg'
                    and tgrelid = 'public.biletler'::regclass) then
    raise exception '045: kamera_okunamadi_kapat_tg tetiği yok';
  end if;
  if not exists (select 1 from cron.job
                  where jobname = 'otopark-istisna-bildirim' and schedule = '* * * * *') then
    raise exception '045: otopark-istisna-bildirim işi kurulmadı';
  end if;
  if public.bildirim_yonetici_turu('ISTISNA') then
    raise exception '045: ISTISNA hâlâ yalnızca Yönetici türü';
  end if;
  if not public.bildirim_yonetici_turu('KAMERA') then
    raise exception '045: bildirim_yonetici_turu listesi bozuldu';
  end if;

  v_def := pg_get_functiondef('public.istisna_yaz(public.istisna_tur, text, text, public.kaynak, uuid, jsonb, text, timestamptz, uuid[])'::regprocedure);
  if position('notify_yonetici' in v_def) = 0 or position('OKUNAMADI' in v_def) = 0 then
    raise exception '045: istisna_yaz beklenen gövdede değil';
  end if;
end
$do$;

commit;
