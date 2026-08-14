-- =====================================================================
--  Otopark — 004_cron.sql
--  Nightly maintenance and the camera watchdog.
--
--  Prerequisite: pg_cron enabled (Database → Extensions in the dashboard).
--
--  Timezone: Turkey is UTC+3 all year (no DST since 2016), so 21:05 UTC is
--  00:05 Istanbul.
--
--  ⚠ Neither function can carry an is_yonetici() guard: cron runs them with
--  auth.uid() = NULL and the guard would fail every single night. The ONLY
--  protection is the grant, and it must revoke from `public` — otherwise any
--  logged-in user could trigger them by hand.
-- =====================================================================

create extension if not exists pg_cron;

-- ================================================== nightly maintenance ==

create or replace function public.run_gunluk_bakim() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_bugun    date := (now() at time zone 'Europe/Istanbul')::date;
  v_saklama  integer;
  v_terk     integer;
  v_r        record;
begin
  select o.foto_saklama_gun, o.terk_esik_saat
    into v_saklama, v_terk
    from public.otopark_ayarlari o where o.id = 1;
  v_saklama := coalesce(v_saklama, 30);
  v_terk    := coalesce(v_terk, 48);

  -- 1. Subscriptions that ran out yesterday stop being AKTIF. The ticket
  --    flow reads durum, so this is what makes a lapsed car start paying.
  update public.abonmanlar
     set durum = 'DOLDU'
   where durum = 'AKTIF' and bitis < v_bugun;

  -- 2. Expiring within a week — one notice per subscription, ever.
  for v_r in
    select a.id, a.plaka, a.musteri_ad, a.bitis
      from public.abonmanlar a
     where a.durum = 'AKTIF'
       and a.bitis between v_bugun and v_bugun + 7
       and not exists (
         select 1 from public.notifications n
          where n.tur = 'ABONMAN_BITIYOR'
            and n.link = '/yonetim/abonman/' || a.id::text)
  loop
    perform public.notify_yonetici('ABONMAN_BITIYOR', 'Abonman bitiyor',
      v_r.plaka || ' — ' || to_char(v_r.bitis, 'DD.MM.YYYY') || ' tarihinde doluyor.',
      '/yonetim/abonman/' || v_r.id::text);
  end loop;

  -- 3. KVKK retention. A plate is personal data; the ticket is kept as an
  --    accounting record, the photo is evidence with a short life.
  --    foto_saklama_gun = 0 disables the purge entirely.
  if v_saklama > 0 then
    delete from storage.objects
     where bucket_id = 'plaka-foto'
       and created_at < now() - make_interval(days => v_saklama);

    -- Drop the now-dangling paths so the UI shows "no photo" instead of a
    -- broken image. Permitted on closed tickets by the immutability guard,
    -- which treats a reference going NULL as a detach, not an edit.
    update public.biletler
       set giris_foto = null
     where giris_foto is not null
       and created_at < now() - make_interval(days => v_saklama);
    update public.biletler
       set cikis_foto = null
     where cikis_foto is not null
       and created_at < now() - make_interval(days => v_saklama);
    update public.istisnalar
       set foto_path = null
     where foto_path is not null
       and created_at < now() - make_interval(days => v_saklama);
  end if;

  -- 4. Abandoned vehicles: still open long past any plausible stay. One
  --    notice per ticket — the link doubles as the dedupe key.
  for v_r in
    select b.id, b.plaka, b.giris_at
      from public.biletler b
     where b.durum = 'ACIK'
       and b.giris_at < now() - make_interval(hours => v_terk)
       and not exists (
         select 1 from public.notifications n
          where n.tur = 'TERK_EDILMIS'
            and n.link = '/gise/bilet/' || b.id::text)
  loop
    perform public.notify_yonetici('TERK_EDILMIS', 'Terk edilmiş olabilir',
      v_r.plaka || ' — ' || round(extract(epoch from (now() - v_r.giris_at)) / 3600.0)
        || ' saattir içeride.',
      '/gise/bilet/' || v_r.id::text);
  end loop;
end $$;

-- ==================================================== camera watchdog ====

create or replace function public.run_kamera_kontrol() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_o        public.otopark_ayarlari;
  v_dolu     integer;
  v_yuzde    integer;
begin
  select * into v_o from public.otopark_ayarlari where id = 1;
  if not found then
    return;
  end if;

  -- 1. A camera that stopped reporting looks EXACTLY like a car park with no
  --    cars — entries silently stop being recorded and nobody finds out until
  --    the numbers look wrong. Only alert once a camera has ever reported,
  --    otherwise a lot with no hardware would alarm forever.
  if v_o.kamera_kalp_atisi is not null
     and v_o.kamera_kalp_atisi < now() - make_interval(mins => v_o.kamera_kalp_esik_dk)
     and not exists (
       select 1 from public.notifications n
        where n.tur = 'KAMERA' and n.created_at > now() - interval '60 minutes')
  then
    perform public.notify_yonetici('KAMERA', 'Kameradan haber yok',
      'Son kayıt: ' || to_char(v_o.kamera_kalp_atisi at time zone 'Europe/Istanbul',
                               'DD.MM.YYYY HH24:MI')
      || '. Girişler kaydedilmiyor olabilir.',
      '/yonetim/ayarlar');
  end if;

  -- 2. Occupancy. Rate-limited to one alert an hour so a lot hovering at the
  --    threshold does not page the owner every ten minutes.
  select count(*)::integer into v_dolu from public.biletler where durum = 'ACIK';
  v_yuzde := case when v_o.kapasite > 0 then (v_dolu * 100) / v_o.kapasite else 0 end;

  if v_yuzde >= v_o.doluluk_uyari_yuzde
     and not exists (
       select 1 from public.notifications n
        where n.tur = 'DOLULUK' and n.created_at > now() - interval '60 minutes')
  then
    perform public.notify_yonetici('DOLULUK', 'Otopark doluyor',
      '%' || v_yuzde || ' dolu (' || v_dolu || '/' || v_o.kapasite || ').', '/');
  end if;
end $$;

-- ========================================================== schedule =====

-- Idempotent: unschedule first so re-running this migration does not stack
-- duplicate jobs. cron.unschedule raises if the job is absent, hence the
-- swallow.
do $$
begin
  perform cron.unschedule('otopark-gunluk');
exception when others then null;
end $$;

do $$
begin
  perform cron.unschedule('otopark-kamera');
exception when others then null;
end $$;

-- 21:05 UTC = 00:05 Istanbul.
select cron.schedule('otopark-gunluk', '5 21 * * *', $$select public.run_gunluk_bakim()$$);
select cron.schedule('otopark-kamera', '*/10 * * * *', $$select public.run_kamera_kontrol()$$);

-- ============================================================== grants ====

-- `from public` is the load-bearing half — see the warning at the top. Without
-- it, `authenticated` inherits EXECUTE through PUBLIC and any logged-in user
-- could run the maintenance job by hand.
revoke all on function public.run_gunluk_bakim()   from public, anon, authenticated, service_role;
revoke all on function public.run_kamera_kontrol() from public, anon, authenticated, service_role;

-- Prove both halves: closed to clients, and still runnable by the job owner.
-- A silent failure here would first show up as a missed run at 00:05.
do $$
begin
  if has_function_privilege('authenticated', 'public.run_gunluk_bakim()', 'execute')
     or has_function_privilege('authenticated', 'public.run_kamera_kontrol()', 'execute') then
    raise exception 'GÜVENLİK: cron fonksiyonları hâlâ istemciye açık.';
  end if;

  if not has_function_privilege('postgres', 'public.run_gunluk_bakim()', 'execute') then
    raise exception 'Cron sahibi run_gunluk_bakim çalıştıramıyor — gece işi sessizce durur.';
  end if;
end $$;
