-- ============================================================================
-- 016  Personel ödemeleri — maaş, avans, prim
-- ============================================================================
--
-- Owner request (2026-08-31): PilotGarage'ın Personel bölümündeki ödeme
-- özellikleri Otopark'a. PilotGarage yalnızca OKUNDU, orada hiçbir şey
-- değiştirilmedi.
--
-- PilotGarage'dan alınan desen ve onun acı pahasına öğrendikleri:
--
-- 1. AVANS BORCU SAKLANMAZ, TÜRETİLİR. Bakiye her zaman satırların üzerinde
--    bir görünümdür (projenin her yerindeki kural). Borç =
--    Σ(borca sayılan avans) − Σ(maaşlarda düşülen). Saklanan bir sayı, bir
--    yerde güncellenmeyi unutunca sessizce yanlışa döner.
--
-- 2. MAAŞ, BORÇ DÜŞÜLEREK ÖDENİR. PilotGarage'da bu bir HATAYDI ve 057'ye
--    kadar sürdü: ekran "maaştan düşülecek" yazıyor, ödeme ise tam maaşı
--    kasadan çıkarıyordu — yani avans iki kez ödeniyordu. Burada ilk günden
--    düşülerek ödenir, karşılanamayan kısım BİR SONRAKİ DÖNEME DEVREDER
--    (ayrı bir devir kaydı yok, formül taşır).
--
-- 3. OKU-KARAR VER-YAZ KİLİTLİDİR. Borcu okuyup maaşı yazmak arasında kilit
--    yoksa, iki eşzamanlı ödeme aynı borcu iki kez düşer ve personel eksik
--    alır — üstelik her ödeme tek tek doğru göründüğü için denetimde iz
--    kalmaz (PilotGarage 059). `pg_advisory_xact_lock` kişi başına alınır.
--
-- 4. NET SIFIR OLSA BİLE KASAYA SATIR YAZILIR (owner isteği; PilotGarage da
--    böyle yapar). Borç maaşın tamamını yiyebilir ve o gün kasadan gerçekten
--    para çıkmaz — ama ₺0,00'lık satır "bu ay maaş ödendi, tamamı avanstan
--    düşüldü" diyen görünür kayıttır. Bunun için `tutar_kurus > 0` kısıtı
--    DAR bir istisnayla gevşetilir: sıfır yalnızca satır bir personele
--    bağlıysa yazılabilir. Bilet, abonman ve elle girilen kasa kaydında
--    `> 0` aynen sürer, yoksa sıfır tutarlı çöp kayıtlar mümkün olurdu.
--
-- OTOPARK'A UYARLARKEN BİLEREK AYRILDIĞIMIZ YERLER:
--   • Onay kuyruğu yok — kasa zaten Yönetici'ye özel, ödeme doğrudan işlenir.
--   • İşletme kavramı yok — maaş `profiles` üzerinde tek kolon.
--   • Otomatik aylık maaş VAR (owner isteği): `profiles.odeme_gunu` doluysa
--     gece işi o gün maaşı öder. Elle ödemeyle AYNI yolu kullanır — ayrı bir
--     kopya, iki farklı maaş hesabı demek olurdu.
-- ============================================================================

begin;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'odeme_tur') then
    create type public.odeme_tur as enum ('MAAS', 'AVANS', 'PRIM');
  end if;
end $$;

alter table public.profiles
  add column if not exists maas_kurus integer not null default 0,
  -- NULL = otomatik ödeme yok. 28 sınırı: 31'i seçilen bir kural şubatta
  -- atlanır, 29'u dört yılda bir kayar.
  add column if not exists odeme_gunu smallint,
  -- Yöntem TANIMIN üstünde durur: gece işi kimseye soramaz.
  add column if not exists maas_yontemi public.odeme_yontemi;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'profiles_maas_ck') then
    alter table public.profiles
      add constraint profiles_maas_ck check (maas_kurus >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'profiles_odeme_gunu_ck') then
    alter table public.profiles
      add constraint profiles_odeme_gunu_ck
      check (odeme_gunu is null or odeme_gunu between 1 and 28);
  end if;
end $$;

-- ---------------------------------------------------------- kasa bağı ------
-- Kural 4'ün taşıyıcısı: sıfır tutara izin veren istisna, satırın bir
-- personele ait olduğunu KANITLAYAN bir kolona dayanmalı. `kategori` metni
-- bunun için kullanılamaz — serbest metindir, yeniden adlandırılabilir ve
-- kısıtı ona bağlamak, birinin "Personel" yazıp sıfırlık çöp kayıt açmasına
-- kapı aralardı.
alter table public.kasa_hareketleri
  add column if not exists personel_id uuid references public.profiles(id) on delete set null;

do $$
begin
  alter table public.kasa_hareketleri drop constraint if exists kasa_hareketleri_tutar_kurus_check;
  if not exists (select 1 from pg_constraint where conname = 'kasa_tutar_ck') then
    alter table public.kasa_hareketleri
      add constraint kasa_tutar_ck
      check (tutar_kurus > 0 or (tutar_kurus = 0 and personel_id is not null));
  end if;
end $$;

create table if not exists public.personel_odemeler (
  id            uuid primary key default gen_random_uuid(),
  profile_id    uuid not null references public.profiles(id) on delete cascade,
  tur           public.odeme_tur not null,
  -- Kural 4: borcun tamamen yediği maaş sıfır tutarla defterde durur.
  tutar_kurus   integer not null check (tutar_kurus >= 0),
  aciklama      text not null default '',
  -- MAAS satırında: bu ödemenin kapattığı avans borcu.
  avans_dusulen integer not null default 0 check (avans_dusulen >= 0),
  -- AVANS satırında: maaştan düşülecek mi. Prim asla düşülmez (bahşiş değil,
  -- maaşın üstüne verilen ödüldür), maaş zaten borcun kendisi değildir.
  borca_sayilir boolean not null default true,
  -- Kasadaki karşılığı. `set null`: kasa satırı silinse bile ödeme geçmişi
  -- durur, yoksa "bu avans verilmiş miydi" sorusu cevapsız kalır.
  kasa_id       uuid references public.kasa_hareketleri(id) on delete set null,
  tarih         date not null default ((now() at time zone 'Europe/Istanbul')::date),
  created_by    uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);

create index if not exists personel_odemeler_kisi_ix
  on public.personel_odemeler (profile_id, tarih desc);

-- ---------------------------------------------------------------- RLS ------
alter table public.personel_odemeler enable row level security;

drop policy if exists personel_odemeler_select on public.personel_odemeler;
-- Yalnızca okuma, ve yalnızca Yönetici: bir personelin ne kadar avans
-- aldığı, diğer personelin görmesi gereken bir şey değil.
create policy personel_odemeler_select on public.personel_odemeler
  for select to authenticated using (public.is_yonetici());

-- Supabase, `public` şemasında YARATILAN her tabloya da anon/authenticated
-- için varsayılan yetki verir (fonksiyonlardaki 012 tuzağının tablo hâli).
-- 003 o süpürmeyi yapar ama yalnızca O AN var olan tablolar için; bu tablo
-- sonradan doğduğu için kendi revoke'unu kendisi taşımak zorunda. Revoke
-- olmadan RLS tek başına yeter gibi görünür — ta ki bir politika gevşeyene
-- kadar; yetki ile politika birbirinin yedeğidir, biri diğerinin yerine
-- geçmez.
revoke all on public.personel_odemeler from anon, authenticated;

-- Yazma yolu YOK: her satır aşağıdaki RPC'lerden doğar, çünkü her biri aynı
-- anda kasaya da yazar ve ikisinin ayrı ayrı yazılabilmesi, defterle kasanın
-- ayrışabilmesi demektir.
grant select on public.personel_odemeler to authenticated;

-- ------------------------------------------------------------ borç ---------
-- Kural 1. İçeride rol kontrolü yok çünkü yalnızca aşağıdaki RPC'ler çağırır;
-- istemciye kapalıdır (012'nin dersi: `from public` tek başına yetmez).
create or replace function public.avans_borcu(p_profile uuid) returns integer
language sql stable security definer set search_path = public as $$
  select greatest(
    coalesce(sum(case when tur = 'AVANS' and borca_sayilir then tutar_kurus else 0 end), 0)
      - coalesce(sum(avans_dusulen), 0),
    0)::integer
    from public.personel_odemeler
   where profile_id = p_profile;
$$;

-- ------------------------------------------------------------ ortak --------
-- Üç ödeme de aynı iki satırı yazar; tek fark tür, borç ve açıklamadır.
create or replace function public.personel_odeme_yaz(
  p_profile  uuid,
  p_tur      public.odeme_tur,
  p_tutar    integer,
  p_dusulen  integer,
  p_yontem   public.odeme_yontemi,
  p_aciklama text
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_ad    text;
  v_kasa  uuid;
  v_id    uuid;
begin
  select ad_soyad into v_ad from public.profiles where id = p_profile;

  -- Kural 4: sıfır tutarlı maaş da yazılır; `personel_id` hem kısıtın
  -- istisnasını açar hem satırın kime ait olduğunu söyler.
  insert into public.kasa_hareketleri
    (tur, tutar_kurus, kategori, aciklama, yontem, personel_id, created_by)
  values
    ('GIDER', p_tutar, 'Personel',
     coalesce(nullif(trim(p_aciklama), ''),
              initcap(lower(p_tur::text))) || ' — ' || coalesce(v_ad, 'personel')
     || case when p_tutar = 0 then ' (tamamı avanstan düşüldü)' else '' end,
     p_yontem, p_profile, auth.uid())
  returning id into v_kasa;

  insert into public.personel_odemeler
    (profile_id, tur, tutar_kurus, aciklama, avans_dusulen, kasa_id, created_by)
  values
    (p_profile, p_tur, p_tutar, coalesce(trim(p_aciklama), ''), p_dusulen,
     v_kasa, auth.uid())
  returning id into v_id;

  perform public.audit('personel_' || lower(p_tur::text), 'personel_odemeler', v_id,
    jsonb_build_object('profile', p_profile, 'tutar', p_tutar, 'dusulen', p_dusulen));
  return v_id;
end $$;

-- ------------------------------------------------------------- maaş --------
-- Elle ödeme ile gece işinin ORTAK gövdesi. Rol kontrolü taşımaz: cron'da
-- `auth.uid()` null'dır ve guard her gece patlardı. Çağıranlar korur, ve bu
-- fonksiyon istemciye kapalıdır.
--
-- İki yol tek gövdeyi paylaşır çünkü ayrı kopyalar "maaş nasıl hesaplanır"
-- sorusuna iki cevap demektir; biri düzeltilip diğeri unutulduğunda fark,
-- birinin eksik maaş almasıdır.
create or replace function public.maas_ode_ic(
  p_profile  uuid,
  p_yontem   public.odeme_yontemi default null,
  p_aciklama text default ''
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_maas  integer;
  v_borc  integer;
  v_dus   integer;
begin
  -- Kural 3: borcu okumadan ÖNCE kilit. Elle ödeme ve gece işi AYNI anahtarı
  -- kullanmak zorunda — farklı anahtar, iki yolun birbirine karşı hiç
  -- sıralanmaması demektir.
  perform pg_advisory_xact_lock(hashtext('maas:' || p_profile::text));

  select maas_kurus into v_maas from public.profiles where id = p_profile;
  if v_maas is null then
    raise exception 'Personel bulunamadı.';
  end if;
  if v_maas <= 0 then
    raise exception 'Bu personel için maaş tanımlı değil.';
  end if;

  v_borc := public.avans_borcu(p_profile);
  v_dus  := least(v_borc, v_maas);

  -- Kural 2: kasadan çıkan net, defterde kalan ise ne kadarının borca
  -- gittiği. Karşılanamayan borç kendiliğinden sonraki döneme devreder.
  return public.personel_odeme_yaz(
    p_profile, 'MAAS', v_maas - v_dus, v_dus, p_yontem, p_aciklama);
end $$;

create or replace function public.maas_ode(
  p_profile  uuid,
  p_yontem   public.odeme_yontemi default null,
  p_aciklama text default ''
) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici ödeme yapabilir.';
  end if;
  return public.maas_ode_ic(p_profile, p_yontem, p_aciklama);
end $$;

-- ------------------------------------------------------- otomatik maaş -----
create or replace function public.maas_otomatik() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_bugun date := (now() at time zone 'Europe/Istanbul')::date;
  v_gun   smallint := extract(day from (now() at time zone 'Europe/Istanbul'))::smallint;
  v_r     record;
begin
  for v_r in
    select p.id, p.maas_yontemi
      from public.profiles p
     where p.durum = 'ACTIVE'
       and p.maas_kurus > 0
       and p.odeme_gunu = v_gun
     -- Belirli sıra: xact kilitleri commit'e kadar tutulur, yani döngü kilit
     -- BİRİKTİRİR. İki iş farklı sırada ilerlerse kilitlenirler.
     order by p.id
  loop
    -- Ayda bir kez. Elle ödeme de aynı deftere yazar, dolayısıyla ayın
    -- 5'inde elle ödenen maaşı gece işi ikinci kez ödemez.
    if not exists (
      select 1 from public.personel_odemeler o
       where o.profile_id = v_r.id
         and o.tur = 'MAAS'
         and date_trunc('month', o.tarih) = date_trunc('month', v_bugun))
    then
      perform public.maas_ode_ic(v_r.id, v_r.maas_yontemi, 'Otomatik maaş');
    end if;
  end loop;
end $$;

-- ------------------------------------------------------------ avans --------
create or replace function public.avans_ver(
  p_profile  uuid,
  p_tutar    integer,
  p_yontem   public.odeme_yontemi default null,
  p_aciklama text default ''
) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici ödeme yapabilir.';
  end if;
  if p_tutar is null or p_tutar <= 0 then
    raise exception 'Tutar sıfırdan büyük olmalı.';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile) then
    raise exception 'Personel bulunamadı.';
  end if;
  return public.personel_odeme_yaz(
    p_profile, 'AVANS', p_tutar, 0, p_yontem, p_aciklama);
end $$;

-- ------------------------------------------------------------- prim --------
create or replace function public.prim_ver(
  p_profile  uuid,
  p_tutar    integer,
  p_yontem   public.odeme_yontemi default null,
  p_aciklama text default ''
) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici ödeme yapabilir.';
  end if;
  if p_tutar is null or p_tutar <= 0 then
    raise exception 'Tutar sıfırdan büyük olmalı.';
  end if;
  if not exists (select 1 from public.profiles where id = p_profile) then
    raise exception 'Personel bulunamadı.';
  end if;
  -- Prim borca sayılmaz: maaşın üstüne verilir, ondan düşülmez.
  return public.personel_odeme_yaz(
    p_profile, 'PRIM', p_tutar, 0, p_yontem, p_aciklama);
end $$;

-- -------------------------------------------------------- maaş tanımı ------
-- `profiles` üzerinde kolon bazlı grant yok (003 yalnızca ad_soyad ve
-- notif_prefs veriyor); maaş da o yoldan değil, RPC'den yazılır.
create or replace function public.maas_guncelle(
  p_profile uuid,
  p_maas    integer,
  p_gun     smallint default null,
  p_yontem  public.odeme_yontemi default null
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici maaş tanımlayabilir.';
  end if;
  if p_maas is null or p_maas < 0 then
    raise exception 'Maaş sıfır ya da daha büyük olmalı.';
  end if;
  if p_gun is not null and (p_gun < 1 or p_gun > 28) then
    raise exception 'Ödeme günü 1 ile 28 arasında olmalı.';
  end if;
  -- coalesce YOK: gün ve yöntem bilerek TEMİZLENEBİLİR olmalı, yoksa bir kez
  -- kurulan otomatik ödeme bir daha kapatılamazdı.
  update public.profiles
     set maas_kurus = p_maas, odeme_gunu = p_gun, maas_yontemi = p_yontem
   where id = p_profile;
  if not found then
    raise exception 'Personel bulunamadı.';
  end if;
  perform public.audit('maas_guncelle', 'profiles', p_profile,
    jsonb_build_object('maas', p_maas, 'gun', p_gun, 'yontem', p_yontem));
end $$;

-- --------------------------------------------------------- özet ------------
-- Borç istemcide İKİNCİ KEZ hesaplanmaz: iki formül ayrışırsa ekranda yazan
-- ile ödenen tutar farklı olur (PilotGarage 057'de tam olarak bu oldu).
create or replace function public.personel_ozet(p_profile uuid)
returns table (maas_kurus integer, odeme_gunu smallint,
               maas_yontemi public.odeme_yontemi, borc_kurus integer,
               avans_kurus bigint, prim_kurus bigint, maas_odenen bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  return query
  select (select p.maas_kurus from public.profiles p where p.id = p_profile),
         (select p.odeme_gunu from public.profiles p where p.id = p_profile),
         (select p.maas_yontemi from public.profiles p where p.id = p_profile),
         public.avans_borcu(p_profile),
         coalesce(sum(o.tutar_kurus) filter (where o.tur = 'AVANS'), 0)::bigint,
         coalesce(sum(o.tutar_kurus) filter (where o.tur = 'PRIM'), 0)::bigint,
         coalesce(sum(o.tutar_kurus) filter (where o.tur = 'MAAS'), 0)::bigint
    from public.personel_odemeler o
   where o.profile_id = p_profile;
end $$;

-- -------------------------------------------------------------- grants -----
revoke all on function public.avans_borcu(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.personel_odeme_yaz(
  uuid, public.odeme_tur, integer, integer, public.odeme_yontemi, text)
  from public, anon, authenticated, service_role;

revoke all on function public.maas_ode(uuid, public.odeme_yontemi, text)
  from public, anon, authenticated, service_role;
revoke all on function public.maas_ode_ic(uuid, public.odeme_yontemi, text)
  from public, anon, authenticated, service_role;
revoke all on function public.maas_otomatik()
  from public, anon, authenticated, service_role;
revoke all on function public.avans_ver(uuid, integer, public.odeme_yontemi, text)
  from public, anon, authenticated, service_role;
revoke all on function public.prim_ver(uuid, integer, public.odeme_yontemi, text)
  from public, anon, authenticated, service_role;
revoke all on function public.maas_guncelle(
  uuid, integer, smallint, public.odeme_yontemi)
  from public, anon, authenticated, service_role;
revoke all on function public.personel_ozet(uuid)
  from public, anon, authenticated, service_role;

grant execute on function public.maas_ode(uuid, public.odeme_yontemi, text) to authenticated;
grant execute on function public.avans_ver(uuid, integer, public.odeme_yontemi, text)
  to authenticated;
grant execute on function public.prim_ver(uuid, integer, public.odeme_yontemi, text)
  to authenticated;
grant execute on function public.maas_guncelle(
  uuid, integer, smallint, public.odeme_yontemi) to authenticated;
grant execute on function public.personel_ozet(uuid) to authenticated;

-- ---------------------------------------------------------------- cron -----
do $$
begin
  perform cron.unschedule('otopark-maas');
exception when others then null;
end $$;

-- 21:20 UTC = 00:20 İstanbul. Günlük bakım (21:05) ve düzenli kasa kayıtları
-- (21:15) ile aynı dakikaya düşmesin.
select cron.schedule('otopark-maas', '20 21 * * *', $$select public.maas_otomatik()$$);

-- ------------------------------------------------------------- verify ------
do $$
declare v_sig text;
begin
  -- İçeriden çağrılanlar hiçbir istemci rolüne açık olmamalı: personel_odeme_yaz
  -- rol kontrolü TAŞIMAZ (çağıranlar taşır), açık kalsaydı herhangi bir
  -- kullanıcı kasadan para çıkarabilirdi.
  foreach v_sig in array array[
    'public.avans_borcu(uuid)',
    'public.personel_odeme_yaz(uuid, public.odeme_tur, integer, integer,'
      ' public.odeme_yontemi, text)',
    -- Rol kontrolü taşımayan iki yol: açık kalsalar herhangi bir kullanıcı
    -- kasadan maaş çıkarabilirdi.
    'public.maas_ode_ic(uuid, public.odeme_yontemi, text)',
    'public.maas_otomatik()'
  ] loop
    if has_function_privilege('authenticated', v_sig, 'execute')
       or has_function_privilege('anon', v_sig, 'execute')
       or has_function_privilege('service_role', v_sig, 'execute') then
      raise exception '016: % istemciye açık', v_sig;
    end if;
  end loop;

  if not has_function_privilege('authenticated',
       'public.maas_ode(uuid, public.odeme_yontemi, text)', 'execute') then
    raise exception '016: maas_ode yöneticiye kapalı kaldı';
  end if;

  -- Ödeme defterine istemcinin doğrudan yazma yolu olmamalı.
  if not exists (select 1 from cron.job where jobname = 'otopark-maas') then
    raise exception '016: otomatik maaş işi kurulmadı';
  end if;

  -- Sıfır istisnası DAR olmalı: personelsiz sıfırlık kasa kaydı hâlâ
  -- reddedilmeli, yoksa kısıt anlamını yitirir.
  begin
    insert into public.kasa_hareketleri (tur, tutar_kurus, aciklama)
    values ('GIDER', 0, '016 kısıt denemesi');
    raise exception '016: personelsiz sıfır tutarlı kasa kaydı kabul edildi';
  exception when check_violation then
    null;
  end;

  if has_table_privilege('authenticated', 'public.personel_odemeler', 'INSERT')
     or has_table_privilege('authenticated', 'public.personel_odemeler', 'UPDATE')
     or has_table_privilege('authenticated', 'public.personel_odemeler', 'DELETE') then
    raise exception '016: personel_odemeler istemciye yazılabilir';
  end if;
  if has_table_privilege('anon', 'public.personel_odemeler', 'SELECT') then
    raise exception '016: personel_odemeler anon rolüne açık';
  end if;
end $$;

commit;
