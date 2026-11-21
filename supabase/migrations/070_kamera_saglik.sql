-- ============================================================================
-- 070  Kamera sağlığı: kalpteki sayılar, Yönetici şeridi, Yönetici karnesi
-- ============================================================================

begin;

-- Plan 2026-11-17 adım 2 (sahibin onayı):
--   · Köprünün kalp atışı boş bir POST'tu: kuyrukta takılı araçlar varken de
--     ekranda "Çalışıyor" görünebiliyordu. Köprü 1.4.3 kalbe sayılar koyar
--     (sürüm, işlenen kare/sn, model ms, kuyruk ve en eski bekleyen, sunucunun
--     reddettiği, izleme açık/kapalı/kapandı, model kümesi, kare gecikmesi,
--     saat farkı, "emilirdi / emildi" sayıları). Webhook bunları
--     kamera_kalp_bilgi ile yazar — yalnızca service_role (PASS 41 listesine
--     bu tek ad eklenir). Eski köprünün boş POST'u eskisi gibi kabul edilir.
--   · Kuyruk 5 dakikadır takılıysa, izleme çalışırken kapandıysa ya da köprü
--     son bir saatte sunucunun reddettiği bir aracı atmak zorunda kaldıysa
--     (şerit uyuşmazlığı, bozuk gövde — 071'den sonra kalan tek kayıp yolu)
--     Yönetici uyarılır (her biri saatte en çok bir kez, kendi link'iyle).
--   · kamera_durum_ozet: Gişe'deki şerit için. Yalnızca Yönetici okur (sahip
--     2026-11-18: şerit Yöneticiye; plan önce bütün personel diyordu).
--     Yalnızca TAMAM / HABER_YOK / REDDEDILIYOR / KUYRUK_TAKILDI /
--     IZLEME_KAPANDI döner — plaka, sayı, cihaz adı yok. Personel, PENDING ve
--     anon hiçbir şey okumaz.
--   · kamera_karne: yalnızca Yönetici; Istanbul günü başına kamera / elle
--     giriş-çıkış, kart türleri, plakasız kart, "Araç çıkmadı" ile geri açılan,
--     yönü bilinmeden açılan/kapanan (069), ortalama gecikme. Mevcut
--     tablolardan okur: geçmiş günler de sayılır (1.4.3 öncesi / sonrası).
-- PASS 88 sınar.

-- --------------------------------------------------------------- tablo -----

-- Kaynak başına SON kalp bilgisi: eşleştirilmiş kamera (cihaz kimliği) ya da
-- elle kurulmuş köprü ('genel'). Geçmiş tutulmaz — karne mevcut tablolardan.
create table if not exists public.kamera_saglik (
  kaynak    text primary key,
  cihaz_id  uuid references public.kamera_cihazlari(id) on delete cascade,
  bilgi     jsonb not null default '{}'::jsonb,
  zaman     timestamptz not null default now()
);

alter table public.kamera_saglik enable row level security;

drop policy if exists kamera_saglik_select on public.kamera_saglik;
create policy kamera_saglik_select on public.kamera_saglik for select to authenticated
  using (public.is_yonetici());

-- Yazma yalnızca kamera_kalp_bilgi'den (SECURITY DEFINER). Webhook tabloya
-- doğrudan dokunmaz: service_role'e tablo yetkisi YOK.
revoke all on public.kamera_saglik from anon, authenticated, service_role;
grant select on public.kamera_saglik to authenticated;

-- ---------------------------------------------------------- kalp bilgisi --

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

-- ----------------------------------------------------------------- karne --

create or replace function public.kamera_karne(p_gun integer default 14)
returns jsonb
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_bugun date := (now() at time zone 'Europe/Istanbul')::date;
  v_sonuc jsonb;
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.' using errcode = '42501';
  end if;
  if p_gun is null or p_gun < 1 or p_gun > 31 then
    raise exception 'Gün sayısı 1 ile 31 arasında olmalı.';
  end if;

  select coalesce(jsonb_agg(satir order by g.gun desc), '[]'::jsonb) into v_sonuc
    from (select (v_bugun - i) as gun from generate_series(0, p_gun - 1) i) g
    cross join lateral (
      select (g.gun::timestamp at time zone 'Europe/Istanbul') as bas,
             ((g.gun + 1)::timestamp at time zone 'Europe/Istanbul') as son
    ) a
    cross join lateral (
      select jsonb_build_object(
        'gun', to_char(g.gun, 'YYYY-MM-DD'),
        -- Giriş günü giris_at'tan (aracın girdiği an), çıkış günü cikis_at'tan.
        'kamera_giris', (select count(*) from public.biletler b
                          where b.giris_at >= a.bas and b.giris_at < a.son
                            and b.giris_kaynak = 'KAMERA'),
        'elle_giris',   (select count(*) from public.biletler b
                          where b.giris_at >= a.bas and b.giris_at < a.son
                            and b.giris_kaynak <> 'KAMERA'),
        'kamera_cikis', (select count(*) from public.biletler b
                          where b.cikis_at >= a.bas and b.cikis_at < a.son
                            and b.cikis_kaynak = 'KAMERA'),
        'elle_cikis',   (select count(*) from public.biletler b
                          where b.cikis_at >= a.bas and b.cikis_at < a.son
                            and b.cikis_kaynak is not null and b.cikis_kaynak <> 'KAMERA'),
        'kart',         (select count(*) from public.istisnalar i
                          where i.created_at >= a.bas and i.created_at < a.son
                            and i.kaynak = 'KAMERA'),
        'kart_plakasiz', (select count(*) from public.istisnalar i
                           where i.created_at >= a.bas and i.created_at < a.son
                             and i.kaynak = 'KAMERA' and i.plaka is null),
        'kart_tur', (select coalesce(jsonb_object_agg(t.tur, t.n), '{}'::jsonb)
                       from (select i.tur::text as tur, count(*) as n
                               from public.istisnalar i
                              where i.created_at >= a.bas and i.created_at < a.son
                                and i.kaynak = 'KAMERA'
                              group by i.tur) t),
        'geri_acilan',  (select count(*) from public.audit_log l
                          where l.created_at >= a.bas and l.created_at < a.son
                            and l.action = 'bilet_kamera_geri_acildi'),
        'yon_bilinmiyor', (select count(*) from public.audit_log l
                            where l.created_at >= a.bas and l.created_at < a.son
                              and l.action = 'kamera_yon_bilinmiyor'),
        'gecikme_sn', (select round(avg(extract(epoch from (b.alindi_zaman - b.kaynak_zaman)))::numeric, 1)
                         from public.biletler b
                        where b.giris_at >= a.bas and b.giris_at < a.son
                          and b.giris_kaynak = 'KAMERA'
                          and b.alindi_zaman is not null and b.kaynak_zaman is not null)
      ) as satir
    ) x;
  return v_sonuc;
end
$fn$;

-- ---------------------------------------------------------------- yetki ----

revoke all on function public.kamera_kalp_bilgi(uuid, jsonb) from public;
revoke all on function public.kamera_kalp_bilgi(uuid, jsonb) from anon, authenticated, service_role;
grant execute on function public.kamera_kalp_bilgi(uuid, jsonb) to service_role;

revoke all on function public.kamera_durum_ozet() from public;
revoke all on function public.kamera_durum_ozet() from anon, authenticated, service_role;
grant execute on function public.kamera_durum_ozet() to authenticated;

revoke all on function public.kamera_karne(integer) from public;
revoke all on function public.kamera_karne(integer) from anon, authenticated, service_role;
grant execute on function public.kamera_karne(integer) to authenticated;

-- ------------------------------------------------------------- doğrulama ---

do $do$
declare
  f text;
begin
  foreach f in array array['public.kamera_kalp_bilgi(uuid, jsonb)',
                           'public.kamera_durum_ozet()',
                           'public.kamera_karne(integer)'] loop
    if not exists (select 1 from pg_proc where oid = f::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
      raise exception '070: % SECURITY DEFINER + search_path=public değil', f;
    end if;
    if has_function_privilege('anon', f, 'execute') then
      raise exception '070: % anon rolüne açık', f;
    end if;
  end loop;
  if has_function_privilege('authenticated', 'public.kamera_kalp_bilgi(uuid, jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.kamera_kalp_bilgi(uuid, jsonb)', 'execute') then
    raise exception '070: kamera_kalp_bilgi yalnızca service_role olmalı';
  end if;
  foreach f in array array['public.kamera_durum_ozet()', 'public.kamera_karne(integer)'] loop
    if has_function_privilege('service_role', f, 'execute')
       or not has_function_privilege('authenticated', f, 'execute') then
      raise exception '070: % yalnızca authenticated olmalı', f;
    end if;
  end loop;
  if not exists (select 1 from pg_class where oid = 'public.kamera_saglik'::regclass
                  and relrowsecurity) then
    raise exception '070: kamera_saglik RLS kapalı';
  end if;
  if has_table_privilege('anon', 'public.kamera_saglik', 'select')
     or has_table_privilege('service_role', 'public.kamera_saglik', 'insert')
     or has_table_privilege('authenticated', 'public.kamera_saglik', 'insert') then
    raise exception '070: kamera_saglik tablo yetkileri fazla';
  end if;
end
$do$;

commit;
