-- =====================================================================
-- 085  Vardiya kendi kendine döner + vardiya sonu hatırlatması
-- =====================================================================
-- Sahibin isteği (28.11.2026): Personel vardiya açıp kapatmaz, saymaz;
-- vardiya ortak terminaldeki PIN devriyle el değiştirir (084). Bunun için
-- kasada HER ZAMAN açık bir vardiya olmalı — açık vardiya yokken alınan
-- tahsilat `vardiya_id = null` ile yazılıyor ve hiçbir sayıma girmiyordu.
--
--   * run_vardiya_otomatik_ac: açık vardiya yoksa HEMEN açar. "Günde bir
--     kez, şu saatte" kuralı (030) kalktı; vardiya_otomatik_saat artık
--     okunmuyor (kolon silinmedi). Açılış nakdi: son vardiya sayımsız
--     kapandıysa (DEVIR / OTOMATIK) onun beklenen nakdi — kesedeki para
--     taşınır; sayılarak kapandıysa ayardaki açılış nakdi. Kişi, son
--     vardiyanınki (hatırlatma kime gideceğini bilsin).
--   * vardiya_kapat: gövde 035'ten BİREBİR; Yönetici dalı kapattıktan sonra
--     sonraki vardiyayı HEMEN açar. Yeni parametre p_birakilan_kurus:
--     Yöneticinin kesede bıraktığı tutar (verilmezse ayardaki açılış nakdi).
--     Parametre eklendiği için drop + create; yetkiler yeniden kuruluyor.
--     Personel dalı veritabanında değişmedi, ama artık hiçbir ekran onu
--     çağırmıyor.
--   * profiles.vardiya_baslangic / vardiya_bitis: her personelin vardiya
--     saatleri (sahip: "ileride değişirse değiştirebilelim"). Yalnızca
--     Yönetici yazar (personel_vardiya_saati); herkes okur.
--   * run_vardiya_degisim_hatirlat (5 dk'da bir): açık vardiyanın kişisinin
--     bitiş saatinden 15 dk sonra hâlâ devir olmamışsa ona BİR KEZ
--     hatırlatma (VARDIYA_DEGISIM). Asla kendisi devretmez.
--
-- Önce 084 çalışmış olmalı. Sonra tüm smoke test (PASS 121-124).
-- =====================================================================

begin;

do $do$
begin
  if to_regprocedure('public.vardiya_devret(uuid)') is null then
    raise exception '085: önce 084''ü çalıştırın (vardiya_devret yok)';
  end if;
end
$do$;

-- 035 deseni: yalnızca tanımlanır, bu işlemde kullanılmaz.
alter type public.bildirim_tur add value if not exists 'VARDIYA_DEGISIM';

-- ---------------------------------------------------------------- şema ----

alter table public.profiles
  add column if not exists vardiya_baslangic time,
  add column if not exists vardiya_bitis     time;

do $do$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.profiles'::regclass
                    and conname = 'profiles_vardiya_saati_ck') then
    alter table public.profiles add constraint profiles_vardiya_saati_ck
      check ((vardiya_baslangic is null) = (vardiya_bitis is null));
  end if;
end
$do$;

-- Okuma herkese (018'in kolon listesine ek): terminal kimin sıradaki
-- olduğunu bunlardan bulur. Yazma YOK — profiles_update_self'in kolon
-- yetkisi (ad_soyad, notif_prefs) olduğu gibi kalır.
grant select (vardiya_baslangic, vardiya_bitis) on public.profiles to authenticated;

-- Hatırlatma vardiya başına bir kez.
alter table public.vardiyalar
  add column if not exists devir_hatirlatma_at timestamptz;

-- ------------------------------------------------- personel_vardiya_saati --

create or replace function public.personel_vardiya_saati(
  p_id uuid, p_baslangic time, p_bitis time)
returns void
language plpgsql security definer set search_path = public as $fn$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici vardiya saatlerini değiştirebilir.';
  end if;
  if (p_baslangic is null) <> (p_bitis is null) then
    raise exception 'Başlangıç ve bitiş birlikte verilmeli (ya da ikisi de boş).';
  end if;
  update public.profiles
     set vardiya_baslangic = p_baslangic, vardiya_bitis = p_bitis
   where id = p_id and rol = 'PERSONEL';
  if not found then
    raise exception 'Vardiya saatleri yalnızca Personele verilir.';
  end if;
  perform public.audit('personel_vardiya_saati', 'profiles', p_id,
    jsonb_build_object('baslangic', p_baslangic, 'bitis', p_bitis));
end
$fn$;

-- ------------------------------------------------- run_vardiya_otomatik_ac --

create or replace function public.run_vardiya_otomatik_ac() returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_son    public.vardiyalar;
  v_ayar   integer;
  v_acilis integer;
  v_id     uuid;
begin
  -- Üst üste binen iki tik aynı boşluğu görüp iki vardiya açmaya kalkmasın.
  if not pg_try_advisory_xact_lock(hashtext('vardiya_otomatik_ac')) then
    return;
  end if;

  if exists (select 1 from public.vardiyalar v where v.kapanis_at is null) then
    return;
  end if;

  select coalesce(o.vardiya_acilis_nakit_kurus, 0) into v_ayar
    from public.otopark_ayarlari o where o.id = 1;
  v_ayar := coalesce(v_ayar, 0);

  select * into v_son from public.vardiyalar v
   where v.kapanis_at is not null and v.silindi_at is null
   order by v.kapanis_at desc, v.acilis_at desc
   limit 1;

  -- Sayımsız kapanış (devir, bayat kapanış): kimse kesesi boşaltmadı, para
  -- olduğu yerde — beklenen taşınır. Sayılmış kapanış: Yönetici kesesi
  -- boşalttı; yalnızca ayardaki açılış nakdi kalır.
  if found and v_son.kapanis_kaynak in ('DEVIR', 'OTOMATIK') then
    v_acilis := coalesce(v_son.beklenen_nakit_kurus, v_ayar);
  else
    v_acilis := v_ayar;
  end if;

  begin
    insert into public.vardiyalar (personel_id, acilis_nakit_kurus, otomatik_acildi)
    values (v_son.personel_id, greatest(v_acilis, 0), true)
    returning id into v_id;
  exception when unique_violation then
    return;                      -- bu arada biri açtı
  end;

  perform public.audit('vardiya_otomatik_ac', 'vardiyalar', v_id,
    jsonb_build_object('onceki', v_son.id, 'acilis_nakit', greatest(v_acilis, 0)));
end
$fn$;

-- Gecikme 5 dk'dan 1 dk'ya: vardiyasız geçen her dakika sayımsız paradır.
do $do$
begin
  perform cron.unschedule('otopark-vardiya-ac');
exception when others then null;
end
$do$;

select cron.schedule('otopark-vardiya-ac', '* * * * *',
  $$select public.run_vardiya_otomatik_ac()$$);

-- ------------------------------------------------------------ kapatma -----
-- Gövde 035'ten BİREBİR; yalnızca imza (p_birakilan_kurus) ve Yönetici
-- dalının sonundaki "sonrakini aç" eklendi. Dönüş tipi aynı, ama imza
-- değiştiği için drop + create; drop ACL'i de siler, yetkiler aşağıda.
drop function if exists public.vardiya_kapat(integer, text);
create function public.vardiya_kapat(
  p_sayilan_nakit_kurus integer, p_notlar text default null,
  p_birakilan_kurus integer default null
) returns table (kapandi boolean, beklenen_kurus integer, sayilan_kurus integer,
                 fark_kurus integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_v        public.vardiyalar;
  v_nakit    integer;
  v_beklenen integer;
  v_fark     integer;
  v_ad       text;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_sayilan_nakit_kurus is null or p_sayilan_nakit_kurus < 0 then
    raise exception 'Sayılan nakit negatif olamaz.';
  end if;
  if p_birakilan_kurus is not null and p_birakilan_kurus < 0 then
    raise exception 'Kesede bırakılan tutar negatif olamaz.';
  end if;

  select * into v_v from public.vardiyalar
   where kapanis_at is null for update;
  if not found then
    raise exception 'Açık kasa vardiyası yok.';
  end if;

  select coalesce(sum(t.tutar_kurus), 0)::integer into v_nakit
    from public.tahsilatlar t
   where t.vardiya_id = v_v.id and t.yontem = 'NAKIT';

  v_beklenen := v_v.acilis_nakit_kurus + v_nakit;
  v_fark     := p_sayilan_nakit_kurus - v_beklenen;

  v_ad := coalesce((select p.ad_soyad from public.profiles p where p.id = auth.uid()),
                   'Personel');

  -- Personel kapatmaz, İSTER. Çekmece Yönetici onaylayana kadar açık kalır;
  -- aynı personel sayımını düzeltip yeniden gönderebilir (satırın üstüne
  -- yazılır, ikinci bir istek doğmaz).
  if not public.is_yonetici() then
    update public.vardiyalar
       set kapatma_talebi_at    = now(),
           kapatma_talebi_by    = auth.uid(),
           talep_sayilan_kurus  = p_sayilan_nakit_kurus,
           talep_beklenen_kurus = v_beklenen,
           talep_notlar         = nullif(btrim(p_notlar), '')
     where id = v_v.id;

    perform public.audit('vardiya_kapatma_talebi', 'vardiyalar', v_v.id,
      jsonb_build_object('beklenen', v_beklenen, 'sayilan', p_sayilan_nakit_kurus,
                         'fark', v_fark));
    -- Farkı bildirimin İÇİNE yazmak şart. Kapanış artık onayda olduğu için
    -- oradaki VARDIYA_FARK satırı `notify_yonetici`nin "çağıranı hariç tut"
    -- kuralına takılır — onaylayan Yöneticinin kendisidir — ve tek Yöneticili
    -- bir kasada fark hiçbir bildirimde görünmezdi. Farkı gören ilk mesaj bu.
    perform public.notify_yonetici('VARDIYA_KAPATMA', 'Vardiya kapatma isteği',
      v_ad || ' — sayılan ' || (p_sayilan_nakit_kurus / 100.0)::numeric(12,2)
        || ' TL, fark ' || (v_fark / 100.0)::numeric(12,2) || ' TL',
      '/finans/onay');

    -- `return query` akışı DURDURMAZ; bu `return` olmasa Yönetici dalı da
    -- çalışır ve vardiya sessizce kapanırdı.
    return query select false, v_beklenen, p_sayilan_nakit_kurus, v_fark;
    return;
  end if;

  -- Yönetici kendi sayımıyla doğrudan kapatır. Bekleyen bir istek varsa
  -- birlikte temizlenir: kapanmış satırda kalan istek hiçbir listede
  -- görünmez ve isteği yapan personel isteğinin ne olduğunu asla öğrenemezdi.
  update public.vardiyalar
     set kapanis_at           = now(),
         sayilan_nakit_kurus  = p_sayilan_nakit_kurus,
         beklenen_nakit_kurus = v_beklenen,
         fark_kurus           = v_fark,
         kapanis_kaynak       = 'ELLE',
         kapatan_id           = auth.uid(),
         notlar               = nullif(btrim(p_notlar), ''),
         kapatma_talebi_at    = null,
         kapatma_talebi_by    = null,
         talep_sayilan_kurus  = null,
         talep_beklenen_kurus = null,
         talep_notlar         = null
   where id = v_v.id;

  if v_v.kapatma_talebi_by is not null and v_v.kapatma_talebi_by <> auth.uid() then
    perform public.notify_kisi(v_v.kapatma_talebi_by, 'VARDIYA_KARAR',
      'Vardiya kapatıldı',
      'Vardiya Yönetici tarafından kendi sayımıyla kapatıldı.', '/vardiya');
  end if;

  if v_fark <> 0 then
    perform public.audit('vardiya_fark', 'vardiyalar', v_v.id,
      jsonb_build_object('beklenen', v_beklenen, 'sayilan', p_sayilan_nakit_kurus,
                         'fark', v_fark));
    perform public.notify_yonetici('VARDIYA_FARK', 'Vardiya farkı',
      v_ad || ' — fark ' || (v_fark / 100.0)::numeric(12,2) || ' TL',
      '/finans/vardiyalar');
  end if;

  -- 085: kasa vardiyasız kalmaz. Yönetici kesede bıraktığı tutarı söyler;
  -- söylemezse ayardaki açılış nakdi. Kişi aynı kalır (çalışan değişmedi).
  insert into public.vardiyalar (personel_id, acilis_nakit_kurus, otomatik_acildi)
  values (v_v.personel_id,
          coalesce(p_birakilan_kurus,
                   (select o.vardiya_acilis_nakit_kurus from public.otopark_ayarlari o where o.id = 1),
                   0),
          v_v.personel_id is null);

  return query select true, v_beklenen, p_sayilan_nakit_kurus, v_fark;
end
$fn$;

revoke all on function public.vardiya_kapat(integer, text, integer) from public;
revoke all on function public.vardiya_kapat(integer, text, integer) from anon, authenticated, service_role;
grant execute on function public.vardiya_kapat(integer, text, integer) to authenticated;

-- ----------------------------------------------- vardiya sonu hatırlatma --

create or replace function public.run_vardiya_degisim_hatirlat() returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_v     public.vardiyalar;
  v_bitis time;
  v_simdi timestamp := now() at time zone 'Europe/Istanbul';
  v_son   timestamp;   -- bitişin en son geçtiği an, İstanbul saatiyle
begin
  if not pg_try_advisory_xact_lock(hashtext('vardiya_degisim_hatirlat')) then
    return;
  end if;

  select * into v_v from public.vardiyalar
   where kapanis_at is null and devir_hatirlatma_at is null and personel_id is not null;
  if not found then
    return;
  end if;

  select p.vardiya_bitis into v_bitis
    from public.profiles p
   where p.id = v_v.personel_id and p.rol = 'PERSONEL' and p.durum = 'ACTIVE';
  if v_bitis is null then
    return;
  end if;

  -- 21:00 → bugün 21:00 henüz gelmediyse dünkü 21:00. Gece yarısını
  -- geçen vardiya (21-09) böyle doğru günü bulur.
  v_son := v_simdi::date + v_bitis;
  if v_son > v_simdi then
    v_son := v_son - interval '1 day';
  end if;

  -- Vardiya bitişten ÖNCE açılmış olmalı (sonra açıldıysa devir olmuştur);
  -- bitişin üstünden 15 dk geçmiş ama 3 saat geçmemiş olmalı (günler sonra
  -- eski bir bitiş için hatırlatma anlamsız).
  if (v_v.acilis_at at time zone 'Europe/Istanbul') >= v_son
     or v_simdi < v_son + interval '15 minutes'
     or v_simdi >= v_son + interval '3 hours' then
    return;
  end if;

  update public.vardiyalar set devir_hatirlatma_at = now() where id = v_v.id;

  -- Saat parantez içinde: "21:00'de" / "09:00'da" ekini tahmin etmeye gerek yok.
  perform public.notify_kisi(v_v.personel_id, 'VARDIYA_DEGISIM', 'Vardiya bitti',
    'Vardiya bitiş saatin (' || to_char(v_bitis, 'HH24:MI')
      || ') geçti — yeni personel geldiyse Devral''a dokunun.',
    '/gise');
end
$fn$;

do $do$
begin
  perform cron.unschedule('otopark-vardiya-hatirlat');
exception when others then null;
end
$do$;

select cron.schedule('otopark-vardiya-hatirlat', '*/5 * * * *',
  $$select public.run_vardiya_degisim_hatirlat()$$);

-- ---------------------------------------------------------------- yetki ---

revoke all on function public.personel_vardiya_saati(uuid, time, time) from public;
revoke all on function public.personel_vardiya_saati(uuid, time, time) from anon, authenticated, service_role;
grant execute on function public.personel_vardiya_saati(uuid, time, time) to authenticated;

-- Cron'da auth.uid() null'dır, rol kontrolü konamaz: tek koruma yetkidir.
revoke all on function public.run_vardiya_otomatik_ac() from public;
revoke all on function public.run_vardiya_otomatik_ac() from anon, authenticated, service_role;
revoke all on function public.run_vardiya_degisim_hatirlat() from public;
revoke all on function public.run_vardiya_degisim_hatirlat() from anon, authenticated, service_role;

-- ---------------------------------------------------------- doğrulama -----
do $do$
declare
  v_f text;
begin
  foreach v_f in array array['public.run_vardiya_otomatik_ac()', 'public.run_vardiya_degisim_hatirlat()'] loop
    if has_function_privilege('anon', v_f, 'execute')
       or has_function_privilege('authenticated', v_f, 'execute')
       or has_function_privilege('service_role', v_f, 'execute') then
      raise exception '085: % bir role açık', v_f;
    end if;
  end loop;
  foreach v_f in array array['public.vardiya_kapat(integer, text, integer)',
                             'public.personel_vardiya_saati(uuid, time, time)'] loop
    if has_function_privilege('anon', v_f, 'execute')
       or has_function_privilege('service_role', v_f, 'execute')
       or not has_function_privilege('authenticated', v_f, 'execute') then
      raise exception '085: % yalnızca authenticated''a açık olmalı', v_f;
    end if;
  end loop;
  if to_regprocedure('public.vardiya_kapat(integer, text)') is not null then
    raise exception '085: eski iki parametreli vardiya_kapat hâlâ duruyor';
  end if;
  if has_column_privilege('authenticated', 'public.profiles', 'vardiya_bitis', 'UPDATE') then
    raise exception '085: vardiya saatleri istemciden yazılabiliyor';
  end if;
end
$do$;

commit;
