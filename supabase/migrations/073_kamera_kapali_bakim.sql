-- ============================================================================
-- 073  Kamera girişi kapalıyken sahte uyarı yok; cron geçmişi temizliği; dizinler
-- ============================================================================

begin;

-- Bulgu 2026-11-20 (köprü + sistem uyum kontrolü), sahibin kararı aynı gün:
--
-- 1. Kamera girişi Ayarlar'dan kapatıldığında (otopark_ayarlari.kamera_aktif)
--    kameranın gördüğü araçlar ATILIR — sahip bilerek kapatmıştır (kamera
--    arızası, bakım), personel elle kaydeder. Atma webhook'ta (410,
--    _shared/serit.ts kapaliCevabi); burada yalnızca uyarılar:
--      · run_kamera_kontrol (son gövde 037) kapalı kameraya saatte bir
--        "haber yok" yazıyordu. Kapalıyken iki kamera uyarısı da yazılmaz;
--        doluluk uyarısı aynen kalır.
--      · kamera_kalp_bilgi (070) kapalıyken kalbi SAKLAR (sağlık sayfası
--        görsün) ama kuyruk / ret / izleme uyarısı yazmaz.
--      · kamera_durum_ozet (070) kapalıyken her şeyden önce KAPALI döner
--        (Gişe şeridi: "Kamera girişi kapalı — araçları elle kaydedin").
--    kamera_gunluk_rapor (058) zaten kapalıyken susuyordu.
-- 2. cron.job_run_details hiç temizlenmiyordu (Supabase kendisi yapmaz;
--    dakikalık istisna işi günde ~1.440 satır ekler). Supabase'in kendi cron
--    belgesindeki desen: her gün 7 günden eskisi silinir.
-- 3. En sık koşan iki sorguya dizin: webhook'un her kamera olayındaki hız
--    sınırı sayımı (biletler, giris_kaynak = KAMERA, created_at) ve her uyarı
--    işlevindeki "son saatte aynı uyarı var mı" sorgusu (notifications tur +
--    link + created_at). 067'nin biletler_kapali_cikis_ix'i 001'deki
--    biletler_kapali_ix'in aynısıdır (aynı sütun, aynı koşul): kopya gider.
-- PASS 92 sınar; PASS 57e ve 88 artık kamerayı açıkça açar.

-- ------------------------------------------------------------- nöbetçi ----

-- Gövde 037'den BİREBİR; yalnızca kamera girişi kapalıyken iki kamera uyarısı
-- (1a, 1b) atlanır. Doluluk (2) kameradan bağımsızdır, aynen kalır.
create or replace function public.run_kamera_kontrol() returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_o     public.otopark_ayarlari;
  v_c     record;
  v_link  text;
  v_dolu  integer;
  v_yuzde integer;
begin
  select * into v_o from public.otopark_ayarlari where id = 1;
  if not found then
    return;
  end if;

  -- 073: kamera girişi bilerek kapatıldıysa susan kamera beklenen şeydir —
  -- "haber yok" uyarısı yanlış alarm olurdu.
  if v_o.kamera_aktif then
  -- 1. A camera that stopped reporting looks EXACTLY like a car park with no
  --    cars — entries silently stop being recorded and nobody finds out until
  --    the numbers look wrong. Only alert once a camera has ever reported,
  --    otherwise a lot with no hardware would alarm forever.
  -- 1a. Eşleştirilmiş kameralar: her biri KENDİ satırından izlenir.
  for v_c in
    select * from public.kamera_cihazlari
     where aktif and son_gorulme is not null
     order by ad
  loop
    -- Tekilleştirme cihaz başına, link üzerinden. Genel "son bir saatte
    -- KAMERA bildirimi var mı" kontrolü burada YANLIŞ olurdu: ilk ölen
    -- kamera ikincisinin uyarısını susturur ve düzeltilen hata geri gelirdi.
    v_link := '/yonetim/kameralar?c=' || v_c.id::text;
    -- greatest NULL'ı yok sayar: durum_at hiç yazılmadıysa son_gorulme kalır.
    -- Yeni etkinleştirilen kamera böylece bir eşik süresi kadar tanınır.
    if greatest(v_c.son_gorulme, v_c.durum_at)
         < now() - make_interval(mins => v_o.kamera_kalp_esik_dk)
       and not exists (
         select 1 from public.notifications n
          where n.tur = 'KAMERA' and n.link = v_link
            and n.created_at > now() - interval '60 minutes')
    then
      perform public.notify_yonetici('KAMERA',
        v_c.ad || ' kamerasından haber yok',
        'Son kayıt: ' || to_char(v_c.son_gorulme at time zone 'Europe/Istanbul',
                                 'DD.MM.YYYY HH24:MI')
        || '. ' || case v_c.yon
                     when 'CIKIS' then 'Çıkışlar'
                     when 'ORTAK' then 'Girişler ve çıkışlar'
                     else 'Girişler'
                   end
        || ' kaydedilmiyor olabilir.',
        v_link);
    end if;
  end loop;

  -- 1b. Elle (env anahtarıyla) kurulmuş köprü: genel damgadan izlenir ve
  --     yukarıdakinden BAĞIMSIZDIR — `elsif` DEĞİL. Bir şeridi eşleştirilmiş,
  --     öbürü hâlâ ortak anahtarla çalışan otoparkta bu dal atlanırsa, ölen
  --     elle kurulmuş köprü hiç uyarı üretmez. Eşleştirilmiş kameralar bu
  --     damgaya dokunmuyor (kamera_kalp_cihaz), dolayısıyla onu canlı da
  --     gösteremezler. Artık elle kurulmuş köprüsü olmayan otopark damgayı
  --     kamera_eski_kopru_unut ile NULL yapar.
  --     Tekilleştirme TAM link üzerinden: cihaz uyarıları (?c=...) bunu,
  --     bu da onları susturmamalı.
  if v_o.kamera_kalp_atisi is not null
     and v_o.kamera_kalp_atisi < now() - make_interval(mins => v_o.kamera_kalp_esik_dk)
     and not exists (
       select 1 from public.notifications n
        where n.tur = 'KAMERA' and n.link = '/yonetim/kameralar'
          and n.created_at > now() - interval '60 minutes')
  then
    perform public.notify_yonetici('KAMERA', 'Elle kurulmuş kamera köprüsünden haber yok',
      'Son kayıt: ' || to_char(v_o.kamera_kalp_atisi at time zone 'Europe/Istanbul',
                               'DD.MM.YYYY HH24:MI')
      || '. Girişler kaydedilmiyor olabilir.',
      '/yonetim/kameralar');
  end if;
  end if;  -- 073: kamera_aktif

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
end
$fn$;

-- ---------------------------------------------------------- kalp bilgisi --

-- Gövde 070'ten BİREBİR; yalnızca kamera girişi kapalıyken kalp saklandıktan
-- sonra üç uyarı atlanır (kapalıyken araçlar atılır, kuyruk ve ret beklenir).
create or replace function public.kamera_kalp_bilgi(p_cihaz_id uuid, p_bilgi jsonb)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_sayilar  constant text[] := array['fps', 'model_ms', 'kuyruk', 'kuyruk_en_eski_sn',
                                      'reddedilen', 'kare_gecikme_ms', 'saat_farki_sn',
                                      'emilirdi', 'emildi'];
  v_metinler constant text[] := array['surum', 'takip', 'kume'];
  v_temiz    jsonb := '{}'::jsonb;
  v_k        text;
  v_v        jsonb;
  v_kaynak   text;
  v_link     text;
begin
  -- Webhook'un service anahtarıyla, JWT'siz çağrılır (037 deseni). Asıl sınır
  -- grant'tır; JWT taşıyan çağıran ayrıca reddedilir.
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.' using errcode = '42501';
  end if;
  if p_cihaz_id is not null
     and not exists (select 1 from public.kamera_cihazlari c where c.id = p_cihaz_id) then
    return;
  end if;
  v_kaynak := coalesce(p_cihaz_id::text, 'genel');

  -- Yalnızca tanınan anahtarlar, doğru türde ve sınırlı: köprünün gövdesi
  -- güvenilmez veri sayılır (sızan anahtarla şişirilemesin).
  if jsonb_typeof(p_bilgi) = 'object' then
    for v_k, v_v in select e.key, e.value from jsonb_each(p_bilgi) e loop
      if v_k = any(v_sayilar) and jsonb_typeof(v_v) = 'number'
         and abs((v_v #>> '{}')::numeric) < 1e9 then
        v_temiz := v_temiz || jsonb_build_object(v_k, v_v);
      elsif v_k = any(v_metinler) and jsonb_typeof(v_v) = 'string'
            and length(v_v #>> '{}') <= 40 then
        v_temiz := v_temiz || jsonb_build_object(v_k, v_v);
      end if;
    end loop;
  end if;
  if v_temiz ? 'takip' and v_temiz ->> 'takip' not in ('acik', 'kapali', 'kapandi') then
    v_temiz := v_temiz - 'takip';
  end if;

  insert into public.kamera_saglik (kaynak, cihaz_id, bilgi, zaman)
  values (v_kaynak, p_cihaz_id, v_temiz, now())
  on conflict (kaynak) do update
    set bilgi = excluded.bilgi, zaman = excluded.zaman, cihaz_id = excluded.cihaz_id;

  -- 073: kamera girişi bilerek kapatıldı — kalp saklandı, uyarı yok.
  if not coalesce((select o.kamera_aktif from public.otopark_ayarlari o where o.id = 1), false) then
    return;
  end if;

  -- Kuyruk takıldı: araçlar diske yazılıyor ama sunucuya gitmiyor (ağ, ret).
  -- Saatte en çok bir uyarı (link üzerinden, 037 deseni).
  v_link := '/yonetim/kameralar?saglik=kuyruk';
  if coalesce((v_temiz ->> 'kuyruk_en_eski_sn')::numeric, 0) >= 300
     and not exists (select 1 from public.notifications n
                      where n.tur = 'KAMERA' and n.link = v_link
                        and n.created_at > now() - interval '60 minutes') then
    perform public.notify_yonetici('KAMERA', 'Kamera araçları gönderemiyor',
      coalesce(v_temiz ->> 'kuyruk', '?') || ' araç köprüde bekliyor; en eskisi '
      || round((v_temiz ->> 'kuyruk_en_eski_sn')::numeric / 60) || ' dakikadır.',
      v_link);
  end if;
  -- Köprü son bir saatte sunucunun reddettiği araç(lar)ı attı: her biri
  -- kayıp bir araç. Ayarda bir yanlış (şerit) ya da köprüde bir hata demek.
  v_link := '/yonetim/kameralar?saglik=ret';
  if coalesce((v_temiz ->> 'reddedilen')::numeric, 0) > 0
     and not exists (select 1 from public.notifications n
                      where n.tur = 'KAMERA' and n.link = v_link
                        and n.created_at > now() - interval '60 minutes') then
    perform public.notify_yonetici('KAMERA', 'Sunucu kamera araçlarını reddediyor',
      'Son bir saatte ' || (v_temiz ->> 'reddedilen') || ' araç kaydedilemedi. '
      || 'Kameranın şeridini ve köprü günlüğünü kontrol edin.',
      v_link);
  end if;
  -- İzleme çalışırken kapandı: araçlar eski (1.3.4) kuralla, daha çok kartla.
  v_link := '/yonetim/kameralar?saglik=izleme';
  if v_temiz ->> 'takip' = 'kapandi'
     and not exists (select 1 from public.notifications n
                      where n.tur = 'KAMERA' and n.link = v_link
                        and n.created_at > now() - interval '60 minutes') then
    perform public.notify_yonetici('KAMERA', 'Kamera araç izlemesi kapandı',
      'Köprü araçları eski kuralla işliyor; daha çok kart çıkabilir. Köprü '
      || 'kendisi yeniden deniyor.',
      v_link);
  end if;
end
$fn$;

-- ------------------------------------------------------- Yönetici şeridi --

-- Gövde 070'ten BİREBİR; yalnızca en başa KAPALI eklendi. Yanıt yine tek bir
-- kelime: TAMAM / KAPALI / HABER_YOK / REDDEDILIYOR / KUYRUK_TAKILDI /
-- IZLEME_KAPANDI.
create or replace function public.kamera_durum_ozet()
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_o      public.otopark_ayarlari;
  v_esik   interval;
  v_durum  text := 'TAMAM';
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.' using errcode = '42501';
  end if;
  select * into v_o from public.otopark_ayarlari where id = 1;

  -- 0. 073: kamera girişi bilerek kapatıldı — susan köprü ve atılan araçlar
  --    beklenen şeydir; şerit yalnızca "kapalı, elle kaydedin" der.
  if not coalesce(v_o.kamera_aktif, false) then
    return jsonb_build_object('durum', 'KAPALI');
  end if;

  v_esik := make_interval(mins => coalesce(v_o.kamera_kalp_esik_dk, 15));

  -- 1. Haber yok: run_kamera_kontrol'ün (037) iki kaynağıyla aynı kural.
  if exists (select 1 from public.kamera_cihazlari c
              where c.aktif and c.son_gorulme is not null
                and greatest(c.son_gorulme, c.durum_at) < now() - v_esik)
     or (v_o.kamera_kalp_atisi is not null and v_o.kamera_kalp_atisi < now() - v_esik) then
    return jsonb_build_object('durum', 'HABER_YOK');
  end if;

  -- 2. Taze kalp bilgisi olan kaynaklarda: atılan araç (kayıp), takılı kuyruk
  --    (gecikme), kapanan izleme (daha çok kart) — bu sırayla.
  if exists (select 1 from public.kamera_saglik s
              where s.zaman >= now() - v_esik
                and coalesce((s.bilgi ->> 'reddedilen')::numeric, 0) > 0) then
    v_durum := 'REDDEDILIYOR';
  elsif exists (select 1 from public.kamera_saglik s
              where s.zaman >= now() - v_esik
                and coalesce((s.bilgi ->> 'kuyruk_en_eski_sn')::numeric, 0) >= 300) then
    v_durum := 'KUYRUK_TAKILDI';
  elsif exists (select 1 from public.kamera_saglik s
                 where s.zaman >= now() - v_esik and s.bilgi ->> 'takip' = 'kapandi') then
    v_durum := 'IZLEME_KAPANDI';
  end if;
  return jsonb_build_object('durum', v_durum);
end
$fn$;

-- ---------------------------------------------------------------- yetki ----

-- create or replace yetkileri korur; yine de 070 / 037'deki gibi açıkça
-- yazılır (bir gün biri drop + create yaparsa yetki sessizce açılmasın).
revoke all on function public.kamera_kalp_bilgi(uuid, jsonb) from public;
revoke all on function public.kamera_kalp_bilgi(uuid, jsonb) from anon, authenticated, service_role;
grant execute on function public.kamera_kalp_bilgi(uuid, jsonb) to service_role;

revoke all on function public.kamera_durum_ozet() from public;
revoke all on function public.kamera_durum_ozet() from anon, authenticated, service_role;
grant execute on function public.kamera_durum_ozet() to authenticated;

revoke all on function public.run_kamera_kontrol() from public;
revoke all on function public.run_kamera_kontrol() from anon, authenticated, service_role;

-- ---------------------------------------------------------------- dizinler -

-- Webhook'un hız sınırı (kamera-webhook/index.ts): her kamera olayında iki
-- sayım, giris_kaynak = 'KAMERA' ve created_at >= (1 dk / 24 saat önce).
create index if not exists biletler_kamera_created_ix
  on public.biletler (created_at) where giris_kaynak = 'KAMERA';

-- Her uyarı işlevinin tekilleştirmesi: tur + link (+ son saat). Bugün yalnızca
-- profile_id'li dizinler var.
create index if not exists notifications_tur_link_ix
  on public.notifications (tur, link, created_at desc);

-- 067'nin kopyası; 001'deki biletler_kapali_ix (cikis_at desc) where durum =
-- 'KAPALI' aynısıdır ve kalır.
drop index if exists public.biletler_kapali_cikis_ix;

-- ---------------------------------------------------------------- cron -----

do $$
begin
  perform cron.unschedule('otopark-cron-temizlik');
exception when others then null;
end $$;

-- 21:30 UTC = 00:30 İstanbul: gece işlerinden (21:05 / 21:15 / 21:20) sonra.
select cron.schedule('otopark-cron-temizlik', '30 21 * * *',
                     $$delete from cron.job_run_details where end_time < now() - interval '7 days'$$);

-- ------------------------------------------------------------- doğrulama ---

do $do$
declare
  f text;
begin
  foreach f in array array['public.run_kamera_kontrol()',
                           'public.kamera_kalp_bilgi(uuid, jsonb)',
                           'public.kamera_durum_ozet()'] loop
    if not exists (select 1 from pg_proc where oid = f::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
      raise exception '073: % SECURITY DEFINER + search_path=public değil', f;
    end if;
    if has_function_privilege('anon', f, 'execute') then
      raise exception '073: % anon rolüne açık', f;
    end if;
  end loop;
  if has_function_privilege('authenticated', 'public.run_kamera_kontrol()', 'execute')
     or has_function_privilege('service_role', 'public.run_kamera_kontrol()', 'execute') then
    raise exception '073: run_kamera_kontrol istemciye açık';
  end if;
  if has_function_privilege('authenticated', 'public.kamera_kalp_bilgi(uuid, jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.kamera_kalp_bilgi(uuid, jsonb)', 'execute') then
    raise exception '073: kamera_kalp_bilgi yalnızca service_role olmalı';
  end if;
  if has_function_privilege('service_role', 'public.kamera_durum_ozet()', 'execute')
     or not has_function_privilege('authenticated', 'public.kamera_durum_ozet()', 'execute') then
    raise exception '073: kamera_durum_ozet yalnızca authenticated olmalı';
  end if;

  -- Gövdeler: üç işlevin de kamera_aktif'e baktığı, şeridin KAPALI döndüğü.
  if position('if v_o.kamera_aktif then' in pg_get_functiondef('public.run_kamera_kontrol()'::regprocedure)) = 0 then
    raise exception '073: run_kamera_kontrol kamera_aktif''e bakmıyor';
  end if;
  if position('kamera_aktif' in pg_get_functiondef('public.kamera_kalp_bilgi(uuid, jsonb)'::regprocedure)) = 0 then
    raise exception '073: kamera_kalp_bilgi kamera_aktif''e bakmıyor';
  end if;
  if position('''KAPALI''' in pg_get_functiondef('public.kamera_durum_ozet()'::regprocedure)) = 0 then
    raise exception '073: kamera_durum_ozet KAPALI dönmüyor';
  end if;

  if not exists (select 1 from pg_indexes where schemaname = 'public'
                  and indexname = 'biletler_kamera_created_ix') then
    raise exception '073: biletler_kamera_created_ix yok';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'public'
                  and indexname = 'notifications_tur_link_ix') then
    raise exception '073: notifications_tur_link_ix yok';
  end if;
  if exists (select 1 from pg_indexes where schemaname = 'public'
              and indexname = 'biletler_kapali_cikis_ix') then
    raise exception '073: kopya dizin biletler_kapali_cikis_ix duruyor';
  end if;
  if not exists (select 1 from pg_indexes where schemaname = 'public'
                  and indexname = 'biletler_kapali_ix') then
    raise exception '073: biletler_kapali_ix (asıl dizin) yok';
  end if;

  if not exists (select 1 from cron.job where jobname = 'otopark-cron-temizlik'
                  and command like '%delete from cron.job_run_details%') then
    raise exception '073: cron geçmişi temizlik işi kurulmadı';
  end if;
end
$do$;

commit;
