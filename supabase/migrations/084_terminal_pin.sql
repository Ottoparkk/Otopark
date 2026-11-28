-- =====================================================================
-- 084  Ortak terminal: isim + PIN ile devir
-- =====================================================================
-- Sahibin isteği (28.11.2026): gündüz (09-21) ve gece (21-09) personeli TEK
-- el terminalini kullanıyor. Kimse e-posta / şifre yazmasın; gelen kişi
-- adını seçip 4 haneli PIN'ini girsin ("Devral"). O an kasa vardiyası yeni
-- kişiye geçer — vardiya artık saate değil kişiye bağlı.
--
--   * terminaller: Yöneticinin kaydettiği cihazlar. 036 kamera deseni: 64 hex
--     gizli anahtar bir kez cihaza verilir, burada yalnızca sha256'sı durur.
--   * personel_pin: PIN'in bcrypt hash'i ve hatalı deneme sayacı. Hiçbir
--     istemci rolüne açık değil.
--   * terminal_pin_dogrula: terminal-giris Edge Function'ı çağırır
--     (service_role). PIN doğruysa vardiyayı devreder ve e-postayı döner;
--     Edge Function o e-postayla tek kullanımlık giriş anahtarı üretir.
--     Hatalı PIN exception ATMAZ, jsonb döner: exception sayacı da geri
--     alırdı ve kilit hiç devreye girmezdi.
--   * personel_pin_olustur: personel-olustur Edge Function'ı, e-postasız
--     (isim + PIN) personel açtıktan sonra çağırır.
--   * 'DEVIR' yeni bir kapanış kaynağı: OTOMATIK gibi SAYIMSIZDIR. Para
--     kimsenin cebinde değil, ortak kesede; beklenen nakit yeni vardiyanın
--     açılış nakdi olur, kesenin toplamı devirler boyunca taşınır.
--   * handle_new_user: gövde 002'den BİREBİR; tek fark, Yöneticinin isim +
--     PIN ile açtığı hesap (app_metadata.pin_personel) için "Yeni kayıt
--     isteği" bildirimi gitmez — onu açan zaten Yönetici.
--   * PIN_KILIT: 5 hatalı denemede kişi 15 dakika kilitlenir, Yönetici
--     uyarılır. bildirim_yonetici_turu: gövde 083'ten BİREBİR + 'PIN_KILIT'.
--
-- Önce 078 → 083 çalışmış olmalı. Sonra tüm smoke test (PASS 116-120).
-- =====================================================================

begin;

do $do$
begin
  if to_regprocedure('public.abonman_bitis_bildirimleri(date)') is null then
    raise exception '084: önce 083''ü çalıştırın (abonman_bitis_bildirimleri yok)';
  end if;
  -- Supabase pgcrypto'yu extensions şemasına kurar. Fonksiyonlar
  -- search_path = public'e sabitli olduğu için adı tam yazılıyor.
  if to_regprocedure('extensions.crypt(text, text)') is null
     or to_regprocedure('extensions.gen_salt(text, integer)') is null then
    raise exception '084: pgcrypto (extensions.crypt / gen_salt) yok — Database → Extensions''tan açın';
  end if;
end
$do$;

-- Yalnızca tanımlanır, bu işlemde KULLANILMAZ (035 deseni): PL/pgSQL
-- gövdelerindeki literal çalışma anında, yani commit sonrasında çözülür.
alter type public.bildirim_tur add value if not exists 'PIN_KILIT';

-- ---------------------------------------------------------------- şema ----

create table if not exists public.terminaller (
  id          uuid primary key default gen_random_uuid(),
  ad          text not null check (length(btrim(ad)) between 1 and 60),
  gizli_hash  text not null unique,
  aktif       boolean not null default true,
  son_gorulme timestamptz,
  olusturan   uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.personel_pin (
  profile_id  uuid primary key references public.profiles(id) on delete cascade,
  pin_hash    text not null,
  hatali      integer not null default 0 check (hatali >= 0),
  kilit_bitis timestamptz,
  updated_at  timestamptz not null default now()
);

alter table public.terminaller  enable row level security;
alter table public.personel_pin enable row level security;

-- Terminal listesi Yöneticinin. Yazma politikası YOK: yalnızca RPC'ler.
drop policy if exists terminaller_select on public.terminaller;
create policy terminaller_select on public.terminaller for select to authenticated
  using (public.is_yonetici());

revoke all on public.terminaller from anon, authenticated, service_role;
-- gizli_hash kolon listesinde YOK (036 deseni).
grant select (id, ad, aktif, son_gorulme, olusturan, created_at)
  on public.terminaller to authenticated;
-- Edge Function bu tabloya doğrudan DOKUNMAZ (yalnızca aşağıdaki SECURITY
-- DEFINER fonksiyonlar, sahibin yetkisiyle) — service_role'e tablo yetkisi
-- bu yüzden verilmiyor.

-- Politika YOK, grant YOK: PIN hash'ini kimse okuyamaz.
revoke all on public.personel_pin from anon, authenticated, service_role;

-- ------------------------------------------------------- kapanış kaynağı --

alter table public.vardiyalar drop constraint if exists vardiyalar_kapanis_kaynak_ck;
alter table public.vardiyalar add constraint vardiyalar_kapanis_kaynak_ck
  check (kapanis_kaynak is null
         or kapanis_kaynak in ('ELLE','YONETICI','OTOMATIK','DEVIR'));

-- Devir de otomatik kapanış gibi sayım UYDURAMAZ (025'in en önemli kısıdı).
alter table public.vardiyalar drop constraint if exists vardiyalar_otomatik_sayim_ck;
alter table public.vardiyalar add constraint vardiyalar_otomatik_sayim_ck
  check (kapanis_kaynak is null
         or kapanis_kaynak not in ('OTOMATIK','DEVIR')
         or (sayilan_nakit_kurus is null and fark_kurus is null));

-- ------------------------------------------------------- vardiya_devret ---

-- Açık vardiyayı p_personel'e devreder ve yeni vardiyanın id'sini döner.
--   * Açık vardiya zaten bu kişininse: dokunmaz.
--   * Başkasınınsa (ya da kimsenin değilse — otomatik açılmış): sayımsız
--     DEVIR ile kapatır; beklenen = açılış + vardiyanın NAKİT tahsilatı;
--     yeni vardiya o beklenenle açılır (kesedeki para el değiştirmez).
--   * Açık vardiya yoksa: ayardaki açılış nakdiyle açar.
-- İçeriden çağrılır; rol kontrolü YOK, tek koruması kapalı yetkidir
-- (vardiya_yeniden_hesapla deseni, PASS 116f).
create or replace function public.vardiya_devret(p_personel uuid)
returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_v      public.vardiyalar;
  v_bek    integer;
  v_acilis integer;
  v_yeni   uuid;
begin
  if p_personel is null then
    raise exception 'vardiya_devret: kişi yok';
  end if;

  select * into v_v from public.vardiyalar where kapanis_at is null for update;

  if found then
    if v_v.personel_id is not distinct from p_personel then
      return v_v.id;
    end if;

    select v_v.acilis_nakit_kurus + coalesce(sum(t.tutar_kurus), 0)::integer
      into v_bek
      from public.tahsilatlar t
     where t.vardiya_id = v_v.id and t.yontem = 'NAKIT';

    update public.vardiyalar
       set kapanis_at           = now(),
           beklenen_nakit_kurus = v_bek,
           kapanis_kaynak       = 'DEVIR'
     where id = v_v.id;
    v_acilis := v_bek;
  else
    select coalesce(o.vardiya_acilis_nakit_kurus, 0) into v_acilis
      from public.otopark_ayarlari o where o.id = 1;
    v_acilis := coalesce(v_acilis, 0);
  end if;

  -- Beklenen eksiye düşemez (açılış >= 0 kontrolü): geri alınan bir tahsilat
  -- toplamı eksiye çekebilir. Keseden eksik para devredilmez.
  insert into public.vardiyalar (personel_id, acilis_nakit_kurus, otomatik_acildi)
  values (p_personel, greatest(v_acilis, 0), false)
  returning id into v_yeni;

  -- auth.uid() burada null olabilir (service_role): kişi AÇIKÇA yazılır.
  insert into public.audit_log (actor, action, tablo, row_id, detay)
  values (p_personel, 'vardiya_devir', 'vardiyalar', v_yeni,
          jsonb_build_object('onceki', v_v.id, 'onceki_personel', v_v.personel_id,
                             'acilis_nakit', greatest(v_acilis, 0)));
  return v_yeni;
end
$fn$;

-- --------------------------------------------------------------- terminal --

create or replace function public.terminal_kaydet(p_ad text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_ad    text := btrim(coalesce(p_ad, ''));
  v_gizli text;
  v_id    uuid;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici terminal kaydedebilir.';
  end if;
  if length(v_ad) not between 1 and 60 then
    raise exception 'Terminal adı 1-60 karakter olmalı.';
  end if;

  -- 244 bit, kamera_eslestir (036) ile aynı üretici.
  v_gizli := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');

  insert into public.terminaller (ad, gizli_hash, olusturan)
  values (v_ad, encode(sha256(convert_to(v_gizli, 'UTF8')), 'hex'), auth.uid())
  returning id into v_id;

  perform public.audit('terminal_kaydet', 'terminaller', v_id, jsonb_build_object('ad', v_ad));
  -- Anahtar yalnızca burada, bir kez döner; cihaz onu kendi deposunda tutar.
  return jsonb_build_object('id', v_id, 'ad', v_ad, 'gizli', v_gizli);
end
$fn$;

create or replace function public.terminal_kaldir(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_ad text;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici terminal kaldırabilir.';
  end if;
  delete from public.terminaller where id = p_id returning ad into v_ad;
  if not found then
    raise exception 'Terminal bulunamadı.';
  end if;
  perform public.audit('terminal_kaldir', 'terminaller', p_id, jsonb_build_object('ad', v_ad));
end
$fn$;

-- -------------------------------------------------------------------- PIN --

-- PIN'i yalnızca Yönetici koyar / değiştirir; yalnızca etkin Personele.
create or replace function public.pin_ayarla(p_profile_id uuid, p_pin text)
returns void
language plpgsql security definer set search_path = public as $fn$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici PIN belirleyebilir.';
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    raise exception 'PIN tam 4 rakam olmalı.';
  end if;
  if not exists (select 1 from public.profiles p
                  where p.id = p_profile_id and p.rol = 'PERSONEL' and p.durum = 'ACTIVE') then
    raise exception 'PIN yalnızca etkin bir Personele verilir.';
  end if;

  insert into public.personel_pin (profile_id, pin_hash)
  values (p_profile_id, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)))
  on conflict (profile_id) do update
     set pin_hash = excluded.pin_hash, hatali = 0, kilit_bitis = null, updated_at = now();

  -- PIN'in kendisi audit'e YAZILMAZ.
  perform public.audit('pin_ayarla', 'profiles', p_profile_id, null);
end
$fn$;

-- Terminalin isim listesi. service_role (terminal-giris) çağırır; terminal
-- anahtarı kimliktir. Tanınmayan terminal hata alır (TG001).
create or replace function public.terminal_personel_listesi(p_gizli_hash text)
returns table (id uuid, ad_soyad text)
language plpgsql security definer set search_path = public as $fn$
begin
  update public.terminaller t set son_gorulme = now()
   where t.gizli_hash = p_gizli_hash and t.aktif;
  if not found then
    raise exception 'Bu cihaz terminal olarak tanınmıyor.' using errcode = 'TG001';
  end if;

  return query
    select p.id, p.ad_soyad
      from public.profiles p
      join public.personel_pin pp on pp.profile_id = p.id
     where p.rol = 'PERSONEL' and p.durum = 'ACTIVE'
     order by p.ad_soyad, p.id;
end
$fn$;

-- PIN doğrulama + devir. Dönüş: {ok:true, email, vardiya} ya da
-- {ok:false, mesaj}. Ret exception DEĞİL: sayaç güncellemesi kalmalı.
create or replace function public.terminal_pin_dogrula(
  p_gizli_hash text, p_profile_id uuid, p_pin text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_pp      public.personel_pin;
  v_ad      text;
  v_email   text;
  v_vardiya uuid;
  v_kalan   integer;
begin
  update public.terminaller t set son_gorulme = now()
   where t.gizli_hash = p_gizli_hash and t.aktif;
  if not found then
    return jsonb_build_object('ok', false, 'mesaj', 'Bu cihaz terminal olarak tanınmıyor.');
  end if;

  select pp.* into v_pp
    from public.personel_pin pp
    join public.profiles p on p.id = pp.profile_id
   where pp.profile_id = p_profile_id and p.rol = 'PERSONEL' and p.durum = 'ACTIVE'
   for update of pp;
  if not found then
    return jsonb_build_object('ok', false, 'mesaj', 'Bu kişi için PIN tanımlı değil.');
  end if;

  if v_pp.kilit_bitis is not null and v_pp.kilit_bitis > now() then
    v_kalan := greatest(1, ceil(extract(epoch from v_pp.kilit_bitis - now()) / 60)::integer);
    return jsonb_build_object('ok', false,
      'mesaj', 'Çok fazla hatalı deneme. ' || v_kalan || ' dakika sonra tekrar deneyin.');
  end if;

  if coalesce(p_pin, '') !~ '^[0-9]{4}$'
     or extensions.crypt(p_pin, v_pp.pin_hash) <> v_pp.pin_hash then
    if v_pp.hatali + 1 >= 5 then
      update public.personel_pin
         set hatali = 0, kilit_bitis = now() + interval '15 minutes', updated_at = now()
       where profile_id = p_profile_id;
      select p.ad_soyad into v_ad from public.profiles p where p.id = p_profile_id;
      insert into public.audit_log (actor, action, tablo, row_id, detay)
      values (null, 'pin_kilit', 'profiles', p_profile_id, null);
      perform public.notify_yonetici('PIN_KILIT', 'PIN kilitlendi',
        coalesce(nullif(btrim(v_ad), ''), 'Personel')
          || ' için 5 hatalı PIN denemesi — 15 dakika kilitli.',
        '/yonetim/personel');
      return jsonb_build_object('ok', false,
        'mesaj', 'Çok fazla hatalı deneme. 15 dakika sonra tekrar deneyin.');
    end if;
    update public.personel_pin
       set hatali = hatali + 1, updated_at = now()
     where profile_id = p_profile_id;
    return jsonb_build_object('ok', false, 'mesaj', 'PIN hatalı.');
  end if;

  update public.personel_pin
     set hatali = 0, kilit_bitis = null, updated_at = now()
   where profile_id = p_profile_id;

  select u.email into v_email from auth.users u where u.id = p_profile_id;
  if v_email is null then
    return jsonb_build_object('ok', false, 'mesaj', 'Hesap bulunamadı.');
  end if;

  v_vardiya := public.vardiya_devret(p_profile_id);

  insert into public.audit_log (actor, action, tablo, row_id, detay)
  values (p_profile_id, 'terminal_giris', 'profiles', p_profile_id,
          jsonb_build_object('vardiya', v_vardiya));

  return jsonb_build_object('ok', true, 'email', v_email, 'vardiya', v_vardiya);
end
$fn$;

-- personel-olustur Edge Function'ı auth kullanıcısını açtıktan sonra çağırır.
-- Çağıranı (p_olusturan) burada da yeniden doğrular: Edge Function'a
-- güvenmek, onun bir hatasına güvenmek olurdu.
create or replace function public.personel_pin_olustur(
  p_id uuid, p_pin text, p_olusturan uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
begin
  if not exists (select 1 from public.profiles p
                  where p.id = p_olusturan and p.rol = 'YONETICI' and p.durum = 'ACTIVE') then
    raise exception 'Yalnızca Yönetici personel ekleyebilir.';
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    raise exception 'PIN tam 4 rakam olmalı.';
  end if;

  update public.profiles
     set rol = 'PERSONEL', durum = 'ACTIVE'
   where id = p_id and durum = 'PENDING' and rol is null;
  if not found then
    raise exception 'Yeni personel bulunamadı ya da zaten onaylı.';
  end if;

  insert into public.personel_pin (profile_id, pin_hash)
  values (p_id, extensions.crypt(p_pin, extensions.gen_salt('bf', 8)));

  insert into public.audit_log (actor, action, tablo, row_id, detay)
  values (p_olusturan, 'personel_pin_olustur', 'profiles', p_id, null);
end
$fn$;

-- ------------------------------------------------------- handle_new_user ---
-- Gövde 002'den BİREBİR; yalnızca bildirim, Yöneticinin isim + PIN ile
-- açtığı hesapta atlanır. app_metadata'yı yalnızca service_role yazabilir —
-- normal kayıt bu bayrağı koyamaz.
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, ad_soyad)
  values (new.id, coalesce(nullif(btrim(new.raw_user_meta_data ->> 'ad_soyad'), ''), ''))
  on conflict (id) do nothing;

  if coalesce(new.raw_app_meta_data ->> 'pin_personel', '') <> 'true' then
  perform public.notify_yonetici(
    'YENI_UYELIK',
    'Yeni kayıt isteği',
    coalesce(nullif(btrim(new.raw_user_meta_data ->> 'ad_soyad'), ''), new.email, 'Yeni kullanıcı')
      || ' onay bekliyor.',
    '/yonetim/personel');
  end if;
  return new;
end $$;

-- --------------------------------------------- bildirim_yonetici_turu -----
-- Gövde 083'ten BİREBİR; 'PIN_KILIT' eklendi.
create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $fn$
  select p_tur::text in (
    'YENI_UYELIK','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA',
    'KAMERA_HAREKET','VARDIYA_ACIK','ONAY_BEKLIYOR','PLAKA_SUPHE',
    'VARDIYA_KAPATMA','BILET_IPTAL_TALEBI','KAMERA_GERI_ACILDI',
    'KAMERA_GUNLUK','YENI_ABONMAN','UCRETSIZ_CIKIS','SURE_ASIMI',
    'PIN_KILIT'
  );
$fn$;

-- ---------------------------------------------------------------- yetki ---

revoke all on function public.vardiya_devret(uuid) from public;
revoke all on function public.vardiya_devret(uuid) from anon, authenticated, service_role;

revoke all on function public.terminal_kaydet(text) from public;
revoke all on function public.terminal_kaydet(text) from anon, authenticated, service_role;
grant execute on function public.terminal_kaydet(text) to authenticated;

revoke all on function public.terminal_kaldir(uuid) from public;
revoke all on function public.terminal_kaldir(uuid) from anon, authenticated, service_role;
grant execute on function public.terminal_kaldir(uuid) to authenticated;

revoke all on function public.pin_ayarla(uuid, text) from public;
revoke all on function public.pin_ayarla(uuid, text) from anon, authenticated, service_role;
grant execute on function public.pin_ayarla(uuid, text) to authenticated;

revoke all on function public.terminal_personel_listesi(text) from public;
revoke all on function public.terminal_personel_listesi(text) from anon, authenticated, service_role;
grant execute on function public.terminal_personel_listesi(text) to service_role;

revoke all on function public.terminal_pin_dogrula(text, uuid, text) from public;
revoke all on function public.terminal_pin_dogrula(text, uuid, text) from anon, authenticated, service_role;
grant execute on function public.terminal_pin_dogrula(text, uuid, text) to service_role;

revoke all on function public.personel_pin_olustur(uuid, text, uuid) from public;
revoke all on function public.personel_pin_olustur(uuid, text, uuid) from anon, authenticated, service_role;
grant execute on function public.personel_pin_olustur(uuid, text, uuid) to service_role;

-- handle_new_user ve bildirim_yonetici_turu: `create or replace` mevcut
-- yetkileri korur (003: handle_new_user PUBLIC'e açık — tetik çağırır).

-- ---------------------------------------------------------- doğrulama -----
do $do$
declare
  v_f text;
begin
  foreach v_f in array array[
    'public.terminal_kaydet(text)', 'public.terminal_kaldir(uuid)', 'public.pin_ayarla(uuid, text)'
  ] loop
    if has_function_privilege('anon', v_f, 'execute')
       or has_function_privilege('service_role', v_f, 'execute')
       or not has_function_privilege('authenticated', v_f, 'execute') then
      raise exception '084: % yalnızca authenticated''a açık olmalı', v_f;
    end if;
  end loop;

  foreach v_f in array array[
    'public.terminal_personel_listesi(text)', 'public.terminal_pin_dogrula(text, uuid, text)',
    'public.personel_pin_olustur(uuid, text, uuid)'
  ] loop
    if has_function_privilege('anon', v_f, 'execute')
       or has_function_privilege('authenticated', v_f, 'execute')
       or not has_function_privilege('service_role', v_f, 'execute') then
      raise exception '084: % yalnızca service_role''e açık olmalı', v_f;
    end if;
  end loop;

  if has_function_privilege('anon', 'public.vardiya_devret(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.vardiya_devret(uuid)', 'execute')
     or has_function_privilege('service_role', 'public.vardiya_devret(uuid)', 'execute') then
    raise exception '084: vardiya_devret bir role açık';
  end if;

  if has_table_privilege('authenticated', 'public.personel_pin', 'SELECT')
     or has_table_privilege('service_role', 'public.personel_pin', 'SELECT')
     or has_column_privilege('authenticated', 'public.terminaller', 'gizli_hash', 'SELECT') then
    raise exception '084: PIN ya da terminal anahtarı istemciye açık';
  end if;

  if not public.bildirim_yonetici_turu('SURE_ASIMI') then
    raise exception '084: bildirim_yonetici_turu 083''ün listesini kaybetti';
  end if;
  if public.bildirim_yonetici_turu('ABONMAN_BITIYOR') then
    raise exception '084: ABONMAN_BITIYOR yine yalnızca Yönetici türü oldu (083 geri alındı)';
  end if;
end
$do$;

commit;
