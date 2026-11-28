-- ============================================================
--  Otopark — RLS & invariant smoke test
--
--  HOW TO RUN: paste this whole file into the Supabase SQL editor and run.
--  Everything happens inside one transaction that is ROLLED BACK at the end,
--  so no test data survives and it is safe to run against a live project.
--
--  Prerequisite: migrations 001–005 applied.
--
--  On success the last message is:   ALL TESTS PASSED (rolled back)
--  On the first failure it stops at: FAIL: <what broke>
--
--  Covers:
--    • PENDING / NULL-role and DISABLED users see zero rows and cannot write
--    • Personel cannot reach revenue history, other shifts, kasa, audit log,
--      subscription prices, points accounts or the earn rate
--    • Personel CAN use the scoped RPCs (gunluk_ozet, abonman_gecerli_mi,
--      hesap_puan_durumu) without row access to what they summarise
--    • Fee math hand-checked: grace period, hour rounding, daily cap, per-type
--    • One open ticket per plate; closed tickets immutable; no client fee write
--    • Idempotency: a replayed islem_id is a no-op, not a second ticket
--    • The clock rule: phone uses the server clock, camera must supply one,
--      replays keep their original time, stale/future events become exceptions
--    • Orphan exit is flagged instead of inventing a phantom ticket
--    • Points: cooldown, no earning on ₺0 stays, redemption capped by fee and
--      balance, ledger is append-only
--    • Tariff versioning does not re-price a car already inside
--    • Internal and cron functions are unreachable from the client
--    • The spot layout is generated from the capacity, and shrinking it
--      retires bays instead of deleting them, skipping occupied ones
--    • One car per bay: an operator's pick is validated, a camera entry takes
--      the first free ordinary bay, and a full lot still opens the ticket
--    • Every function anon or service_role can execute is one we meant them
--      to — the guard against a migration forgetting a revoke
--    • A car can be moved to another bay while it is inside — and only to one
--      that exists, is in use and is empty
--    • Single gate (037): direction comes from the ticket state, a doubtful
--      read goes to a person, and the camera still never closes or collects
--    • A false "Kapıda" mark (038) is cleared only by active staff, only on an
--      open ticket, and leaves an audit row
--    • A camera car whose plate cannot be read, or that arrives while plate
--      reading is down, is no longer lost silently (039): an exception row,
--      and an hourly alert when the reading service fails
--    • Paid camera reads are countable and capped (040): every camera read
--      is tagged in the read log, nobody can forge or erase those rows from
--      the client, and crossing the cap raises one alert an hour
--    • The entry time of an open ticket can be corrected (046) — active staff
--      only, with a reason, never into the future or past a year, never below
--      the points already used; audited and reported to the Yönetici
--    • The tables the Edge Functions read and write directly are granted to
--      service_role explicitly (047), so a project created after Supabase
--      stopped auto-granting new tables (2026-10-30) still works
--    • Single gate (048): a late camera event is judged by its own time
--    • An old, closed shift is deleted only by a Yönetici (049): soft delete
--      into the bin, money and ticket links untouched, Geri al / Kalıcı sil
--    • Personel's cancel of an open ticket is a request (050): the Yönetici
--      approves or rejects it, an exit drops it, both sides are notified
--    • Kademeli tariff (051): price bands, the boundary in the lower band,
--      full days + bands past 24 h, invalid band lists refused
-- ============================================================

begin;

-- ------------------------------------------------------------ impersonation

create or replace function pg_temp.login(p_id uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_id::text, 'role', 'authenticated')::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.logout() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  execute 'reset role';
end $$;

-- The camera webhook: holds the service key, carries NO JWT. Both halves
-- matter. Clearing the claims is what makes auth.uid() NULL, and bilet_ac's
-- camera branch refuses any caller whose uid is non-NULL — so leaving a stale
-- claim behind would make the camera tests fail for the wrong reason.
create or replace function pg_temp.kamera() returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('role', 'service_role', true);
end $$;

do $$
declare
  u_yonetici uuid := gen_random_uuid();
  u_personel uuid := gen_random_uuid();
  u_personel2 uuid := gen_random_uuid();
  u_pending  uuid := gen_random_uuid();
  u_disabled uuid := gen_random_uuid();

  v_n            integer;
  v_n2           integer;
  v_bigint       bigint;
  v_bigint2      bigint;
  v_id           uuid;
  v_id2          uuid;
  v_bilet        uuid;
  v_bilet2       uuid;
  v_tarife_eski  uuid;
  v_tarife_yeni  uuid;
  v_hesap        uuid;
  v_vardiya      uuid;
  v_eski_vardiya uuid;
  v_yer          uuid;
  v_abonman      uuid;
  v_islem        uuid;
  v_ucret        integer;
  v_ucret2       integer;
  v_tr           public.tarifeler;                 -- PASS 100-103 (078)
  v_gun          date;
  v_ts           timestamptz;
  v_ts2          timestamptz;
  v_txt          text;
  v_txt2         text;
  v_txt3         text;
  v_bool         boolean;
  v_json         jsonb;
  v_json2        jsonb;
  v_rec          record;
  v_liste        text[];
  v_beklenen     text[];
begin

-- =====================================================================
-- FIXTURES
-- =====================================================================

perform pg_temp.logout();

insert into auth.users (instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, created_at, updated_at,
                        raw_app_meta_data, raw_user_meta_data)
select '00000000-0000-0000-0000-000000000000'::uuid, v.id, 'authenticated', 'authenticated',
       v.email, '', now(), now(), now(), '{}'::jsonb,
       jsonb_build_object('ad_soyad', v.ad)
  from (values
    (u_yonetici, 'test_yonetici@otopark.local', 'Test Yönetici'),
    (u_personel, 'test_personel@otopark.local', 'Test Personel'),
    (u_personel2,'test_personel2@otopark.local','Test Personel 2'),
    (u_pending,  'test_pending@otopark.local',  'Test Bekleyen'),
    (u_disabled, 'test_disabled@otopark.local', 'Test Kapalı')
  ) as v(id, email, ad);

-- The signup trigger should have created a PENDING profile with rol = NULL.
select count(*) into v_n from public.profiles
 where id in (u_yonetici, u_personel, u_personel2, u_pending, u_disabled)
   and durum = 'PENDING' and rol is null;
if v_n <> 5 then
  raise exception 'FAIL: handle_new_user 5 PENDING profil oluşturmadı (bulunan: %)', v_n;
end if;
raise notice 'PASS 01: yeni kayıtlar PENDING + rol NULL olarak açılıyor';

update public.profiles set rol = 'YONETICI', durum = 'ACTIVE' where id = u_yonetici;
update public.profiles set rol = 'PERSONEL', durum = 'ACTIVE' where id in (u_personel, u_personel2);
update public.profiles set rol = 'PERSONEL', durum = 'DISABLED' where id = u_disabled;

select id into v_tarife_eski from public.tarifeler
 where gecerli_bitis is null;
if v_tarife_eski is null then
  raise exception 'FAIL: 005_seed çalıştırılmamış — aktif tarife yok';
end if;

insert into public.park_yerleri (kod, tip, rezerve)
values ('TEST-' || substr(gen_random_uuid()::text, 1, 8), 'NORMAL', true)
returning id into v_yer;

-- =====================================================================
-- 02–04  PENDING / NULL-role and DISABLED see nothing
-- =====================================================================

perform pg_temp.login(u_pending);

select count(*) into v_n from public.biletler;             if v_n <> 0 then raise exception 'FAIL 02: PENDING bilet görüyor'; end if;
select count(*) into v_n from public.tarifeler;            if v_n <> 0 then raise exception 'FAIL 02: PENDING tarife görüyor'; end if;
select count(*) into v_n from public.abonmanlar;           if v_n <> 0 then raise exception 'FAIL 02: PENDING abonman görüyor'; end if;
select count(*) into v_n from public.tahsilatlar;          if v_n <> 0 then raise exception 'FAIL 02: PENDING tahsilat görüyor'; end if;
select count(*) into v_n from public.kasa_hareketleri;     if v_n <> 0 then raise exception 'FAIL 02: PENDING kasa görüyor'; end if;
select count(*) into v_n from public.audit_log;            if v_n <> 0 then raise exception 'FAIL 02: PENDING audit görüyor'; end if;
select count(*) into v_n from public.hesaplar;             if v_n <> 0 then raise exception 'FAIL 02: PENDING hesap görüyor'; end if;
select count(*) into v_n from public.puan_hareketleri;     if v_n <> 0 then raise exception 'FAIL 02: PENDING puan görüyor'; end if;
select count(*) into v_n from public.otopark_ayarlari;     if v_n <> 0 then raise exception 'FAIL 02: PENDING ayar görüyor'; end if;
select count(*) into v_n from public.park_yerleri;         if v_n <> 0 then raise exception 'FAIL 02: PENDING park yeri görüyor'; end if;
select count(*) into v_n from public.istisnalar;           if v_n <> 0 then raise exception 'FAIL 02: PENDING istisna görüyor'; end if;
raise notice 'PASS 02: PENDING/rol NULL kullanıcı hiçbir tabloda satır görmüyor';

begin
  perform public.bilet_ac('34TEST01', gen_random_uuid());
  raise exception 'FAIL 03: PENDING bilet açabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.gunluk_ozet();
  raise exception 'FAIL 03: PENDING günlük özet alabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 03: PENDING kullanıcı yazamıyor ve özet RPC''lerini çağıramıyor';

perform pg_temp.login(u_disabled);
select count(*) into v_n from public.biletler;   if v_n <> 0 then raise exception 'FAIL 04: DISABLED bilet görüyor'; end if;
select count(*) into v_n from public.tarifeler;  if v_n <> 0 then raise exception 'FAIL 04: DISABLED tarife görüyor'; end if;
begin
  perform public.bilet_ac('34TEST02', gen_random_uuid());
  raise exception 'FAIL 04: DISABLED bilet açabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 04: DISABLED hesap bir sonraki istekte erişimini kaybediyor';

-- =====================================================================
-- 05  Fee math, hand-checked against literals
-- =====================================================================

perform pg_temp.logout();

-- Tariff: 15 min grace, ilk saat 60,00 ₺, sonraki 30,00 ₺, günlük tavan 250,00 ₺
if public.ucret_hesapla_core('2026-01-01 09:00+03','2026-01-01 09:10+03',15,6000,3000,25000) <> 0 then
  raise exception 'FAIL 05a: ücretsiz süre içinde ücret çıktı';
end if;
if public.ucret_hesapla_core('2026-01-01 09:00+03','2026-01-01 09:15+03',15,6000,3000,25000) <> 0 then
  raise exception 'FAIL 05b: ücretsiz sürenin tam sınırı ücretlendirildi';
end if;
-- 16 minutes: past the grace period, so the whole first hour is charged.
if public.ucret_hesapla_core('2026-01-01 09:00+03','2026-01-01 09:16+03',15,6000,3000,25000) <> 6000 then
  raise exception 'FAIL 05c: ücretsiz süre aşımında ilk saat ücreti uygulanmadı';
end if;
if public.ucret_hesapla_core('2026-01-01 09:00+03','2026-01-01 10:00+03',15,6000,3000,25000) <> 6000 then
  raise exception 'FAIL 05d: tam 1 saat ilk saat ücreti değil';
end if;
-- 61 minutes rounds up into a second hour.
if public.ucret_hesapla_core('2026-01-01 09:00+03','2026-01-01 10:01+03',15,6000,3000,25000) <> 9000 then
  raise exception 'FAIL 05e: saat sınırı yukarı yuvarlanmadı';
end if;
-- 10 hours = 6000 + 9*3000 = 33000, above the 25000 cap.
if public.ucret_hesapla_core('2026-01-01 09:00+03','2026-01-01 19:00+03',15,6000,3000,25000) <> 25000 then
  raise exception 'FAIL 05f: günlük tavan uygulanmadı';
end if;
-- Exactly 24 h = one capped day.
if public.ucret_hesapla_core('2026-01-01 09:00+03','2026-01-02 09:00+03',15,6000,3000,25000) <> 25000 then
  raise exception 'FAIL 05g: 24 saat bir tam gün olarak ücretlendirilmedi';
end if;
-- 25 h = one capped day + the first hour of the next.
if public.ucret_hesapla_core('2026-01-01 09:00+03','2026-01-02 10:00+03',15,6000,3000,25000) <> 31000 then
  raise exception 'FAIL 05h: 25 saat yanlış (beklenen 31000)';
end if;
-- gunluk_tavan = 0 means no cap: 10 h = 33000.
if public.ucret_hesapla_core('2026-01-01 09:00+03','2026-01-01 19:00+03',15,6000,3000,0) <> 33000 then
  raise exception 'FAIL 05i: tavan 0 iken sınırsız davranmadı';
end if;
-- A cheaper vehicle type prices differently on the same duration.
if public.ucret_hesapla_core('2026-01-01 09:00+03','2026-01-01 11:00+03',15,3000,1500,10000) <> 4500 then
  raise exception 'FAIL 05j: araç tipine göre tarife farkı uygulanmadı';
end if;
begin
  perform public.ucret_hesapla_core('2026-01-01 10:00+03','2026-01-01 09:00+03',15,6000,3000,25000);
  raise exception 'FAIL 05k: çıkış girişten önce olmasına rağmen hesaplandı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 05: ücret matematiği (ücretsiz süre, saat yuvarlama, tavan, tip, ters zaman) doğru';

-- =====================================================================
-- 06  Personel: what they can and cannot see
-- =====================================================================

perform pg_temp.logout();

insert into public.abonmanlar (plaka, musteri_ad, baslangic, bitis, ucret_kurus)
values ('34ABON01', 'Abonman Müşteri',
        (now() at time zone 'Europe/Istanbul')::date - 5,
        (now() at time zone 'Europe/Istanbul')::date + 25, 150000)
returning id into v_abonman;

insert into public.kasa_hareketleri (tur, tutar_kurus, aciklama) values ('GIDER', 5000, 'test gider');
insert into public.hesaplar (ad) values ('Test Puan Hesabı') returning id into v_hesap;
insert into public.hesap_araclari (hesap_id, plaka) values (v_hesap, '34PUAN01');

perform pg_temp.login(u_personel);

-- 062 (sahip, 2026-11-15): Personel abonmanları takip eder ve tahsil eder —
-- satırı (fiyat dahil) GÖRÜR; yazma yetkisi yok (PASS 80h), yalnızca RPC.
select count(*) into v_n from public.abonmanlar where id = v_abonman;
if v_n <> 1 then raise exception 'FAIL 06a: Personel abonmanı göremiyor (062''den beri görmeli)'; end if;
select count(*) into v_n from public.kasa_hareketleri;
if v_n <> 0 then raise exception 'FAIL 06b: Personel kasa görüyor'; end if;
select count(*) into v_n from public.audit_log;
if v_n <> 0 then raise exception 'FAIL 06c: Personel audit log görüyor'; end if;
select count(*) into v_n from public.hesaplar;
if v_n <> 0 then raise exception 'FAIL 06d: Personel puan hesaplarını görüyor'; end if;
select count(*) into v_n from public.puan_hareketleri;
if v_n <> 0 then raise exception 'FAIL 06e: Personel puan hareketlerini görüyor'; end if;
select count(*) into v_n from public.puan_kurallari;
if v_n <> 0 then raise exception 'FAIL 06f: Personel kazanım oranını görüyor'; end if;
select count(*) into v_n from public.plaka_okuma_log;
if v_n <> 0 then raise exception 'FAIL 06g: Personel plaka okuma logunu görüyor'; end if;
-- Tariffs ARE readable: the price is on the sign at the gate.
select count(*) into v_n from public.tarifeler;
if v_n = 0 then raise exception 'FAIL 06h: Personel tarifeyi göremiyor (görmeli)'; end if;
raise notice 'PASS 06: Personel kasa, audit, puan ve okuma logunu göremiyor; tarifeyi ve abonmanları görüyor';

-- The scoped RPCs still work without any of that row access.
select a.gecerli into v_bool from public.abonman_gecerli_mi('34ABON01') a;
if not v_bool then raise exception 'FAIL 06i: abonman_gecerli_mi geçerli abonmanı bulamadı'; end if;
select a.gecerli into v_bool from public.abonman_gecerli_mi('34YOK999') a;
if v_bool then raise exception 'FAIL 06j: abonman_gecerli_mi olmayan aboneyi geçerli saydı'; end if;
perform public.gunluk_ozet();
perform public.hesap_puan_durumu('34PUAN01');
raise notice 'PASS 07: Personel kapsamlı RPC''leri (abonman/günlük özet/puan) çağırabiliyor';

-- Tariff writes are closed to everyone; versioning only via tarife_guncelle.
begin
  insert into public.tarifeler (ilk_saat_kurus, sonraki_saat_kurus)
  values (1, 1);
  raise exception 'FAIL 08: Personel tarife ekleyebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
-- Either outcome is a pass: no UPDATE grant raises "permission denied", and a
-- grant with no policy silently matches zero rows. The assertion is that
-- NOTHING changes — not which of the two mechanisms stopped it.
begin
  update public.tarifeler set ilk_saat_kurus = 1 where id = v_tarife_eski;
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'FAIL 08: Personel tarife güncelleyebildi (% satır)', v_n; end if;
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.tarife_guncelle(15, 1, 1, 0, 0);
  raise exception 'FAIL 08: Personel tarife_guncelle çağırabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 08: Personel tarife ekleyemiyor/güncelleyemiyor, RPC de reddediyor';

begin
  perform public.set_role(u_personel2, 'YONETICI');
  raise exception 'FAIL 09: Personel rol değiştirebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.approve_signup(u_pending, 'YONETICI');
  raise exception 'FAIL 09: Personel kayıt onaylayabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  update public.profiles set rol = 'YONETICI' where id = u_personel;
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'FAIL 09: Personel kendi rolünü yükseltebildi'; end if;
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
-- ...while the columns they DO own stay writable.
update public.profiles set ad_soyad = 'Test Personel (düzenlendi)' where id = u_personel;
get diagnostics v_n = row_count;
if v_n <> 1 then raise exception 'FAIL 09: Personel kendi adını düzenleyemedi'; end if;
raise notice 'PASS 09: rol/durum istemciden yazılamıyor (kolon izni + RPC koruması)';

-- =====================================================================
-- 10  Ticket lifecycle, idempotency, money identity
-- =====================================================================

-- 085: canlıda kasa vardiyası artık hep açık. Bilinen vardiya (PASS 52
-- deseni): açık olan kapanır (sonunda geri alınır), personel açar.
perform pg_temp.logout();
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE'
 where kapanis_at is null;
perform pg_temp.login(u_personel);
select public.vardiya_ac(10000) into v_vardiya;

v_islem := gen_random_uuid();
select public.bilet_ac('34 abc 123', v_islem) into v_bilet;
if v_bilet is null then raise exception 'FAIL 10a: bilet açılamadı'; end if;

select plaka into v_txt from public.biletler where id = v_bilet;
if v_txt <> '34ABC123' then raise exception 'FAIL 10b: plaka normalize edilmedi (%)', v_txt; end if;

-- Replay of the same islem_id must return the SAME ticket, not a second one.
select public.bilet_ac('34 abc 123', v_islem) into v_bilet2;
if v_bilet2 <> v_bilet then raise exception 'FAIL 10c: aynı islem_id ikinci bilet üretti'; end if;
select count(*) into v_n from public.biletler where islem_id = v_islem;
if v_n <> 1 then raise exception 'FAIL 10c: islem_id için % satır var', v_n; end if;
raise notice 'PASS 10: bilet açılıyor, plaka normalize ediliyor, aynı islem_id tekrarı no-op';

-- A different islem_id for a plate already inside must be refused. Since 010
-- a pre-check answers first so the message is a sentence; the partial index is
-- still what makes it true when two operators race.
begin
  perform public.bilet_ac('34ABC123', gen_random_uuid());
  raise exception 'FAIL 11: aynı plakaya ikinci açık bilet verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 11: bir plaka için ikinci açık bilet kısmi tekil indeksle reddediliyor';

-- No client write path to the fee at all.
begin
  update public.biletler set ucret_kurus = 999999 where id = v_bilet;
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'FAIL 12: istemci ücret yazabildi'; end if;
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  insert into public.tahsilatlar (tur, tutar_kurus, yontem) values ('BILET', 100000, 'NAKIT');
  raise exception 'FAIL 12: istemci tahsilat ekleyebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 12: istemci ücret/tahsilat yazamıyor (RPC dışında yol yok)';

-- =====================================================================
-- 13  The clock rule
-- =====================================================================

-- A phone may send a timestamp; the server ignores it.
v_islem := gen_random_uuid();
select public.bilet_ac('34SAAT01', v_islem, 'MOBIL',
                       now() - interval '5 hours') into v_bilet2;
select giris_at into v_ts from public.biletler where id = v_bilet2;
if v_ts < now() - interval '1 minute' then
  raise exception 'FAIL 13a: telefon girişinde istemci saati kullanıldı (%)', v_ts;
end if;

-- ...and a signed-in client may NOT claim the camera source to get around it.
-- This is the assertion that keeps the clock rule honest: the camera branch is
-- the ONLY one that accepts p_zaman, so staff who could pass
-- p_kaynak = 'KAMERA' would be able to set any entry time they liked — logging
-- an 08:00 arrival as 13:00 erases five billable hours and leaves a ticket
-- that looks completely ordinary.
begin
  perform public.bilet_ac('34SAHTE1', gen_random_uuid(), 'KAMERA',
                          now() - interval '5 hours');
  raise exception 'FAIL 13b: personel KAMERA kaynağını kullanabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  -- The refusal has to be the guard itself. A permission error or a typo would
  -- otherwise look exactly like a pass.
  if sqlerrm not like '%istemciden%' then
    raise exception 'FAIL 13b: beklenmeyen hata: %', sqlerrm;
  end if;
end;
if exists (select 1 from public.biletler where plaka = '34SAHTE1') then
  raise exception 'FAIL 13c: reddedilen KAMERA çağrısı yine de bilet açtı';
end if;

-- Same rule on the way out: no camera closes a ticket, so no ticket may be
-- labelled as closed by one.
begin
  -- FROM-clause form: bilet_kapat RETURNS TABLE, and this is the shape the
  -- rest of the file already uses for it.
  select b.tahsil_kurus into v_ucret2
    from public.bilet_kapat(v_bilet, 'NAKIT', null, null, null, 'KAMERA') b;
  raise exception 'FAIL 13d: çıkış kaynağı KAMERA kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%KAMERA olamaz%' then
    raise exception 'FAIL 13d: beklenmeyen hata: %', sqlerrm;
  end if;
end;
raise notice 'PASS 13: telefon girişi sunucu saatini kullanıyor; istemci KAMERA kaynağını ne girişte ne çıkışta kullanamıyor';

-- ---------------------------------------------------------------------
-- From here to PASS 17 the caller is the CAMERA, not a person: the webhook
-- runs as service_role with no JWT. Running these as a logged-in user would
-- now fail on the guard above and pass for entirely the wrong reason.
-- ---------------------------------------------------------------------
perform pg_temp.kamera();

-- A camera MUST supply a timestamp.
begin
  perform public.bilet_ac('34KAM001', gen_random_uuid(), 'KAMERA', null);
  raise exception 'FAIL 14: kamera zaman damgasız kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%zaman damgası%' then
    raise exception 'FAIL 14: beklenmeyen hata: %', sqlerrm;
  end if;
end;
raise notice 'PASS 14: zaman damgası olmayan kamera kaydı reddediliyor';

-- A replayed camera event keeps its ORIGINAL time, and pricing that pair
-- equals pricing the live one. This is the buffered-event bug: billing a
-- 14:00 arrival from 16:30 turns a 3-hour stay into 30 minutes.
v_ts := now() - interval '3 hours';
select public.bilet_ac('34KAM002', gen_random_uuid(), 'KAMERA', v_ts) into v_bilet2;
select giris_at, gecikmeli_kayit into v_ts2, v_bool
  from public.biletler where id = v_bilet2;
if abs(extract(epoch from (v_ts2 - v_ts))) > 1 then
  raise exception 'FAIL 15a: kamera kaydı orijinal zamanını korumadı (% vs %)', v_ts2, v_ts;
end if;
if not v_bool then raise exception 'FAIL 15b: gecikmeli kayıt işaretlenmedi'; end if;

-- Pricing is a STAFF function: 003 grants ucret_hesapla to `authenticated` and
-- deliberately not to service_role, because a camera never needs to know what
-- anything costs. So step back into the operator's shoes to price it.
perform pg_temp.login(u_personel);
select public.ucret_hesapla(v_ts2, now(), v_tarife_eski) into v_ucret;
select public.ucret_hesapla(v_ts,  now(), v_tarife_eski) into v_ucret2;
if v_ucret <> v_ucret2 then
  raise exception 'FAIL 15c: tekrar oynatılan kayıt farklı ücretlendi (% vs %)', v_ucret, v_ucret2;
end if;
if v_ucret = 0 then raise exception 'FAIL 15d: 3 saatlik park ücretsiz çıktı'; end if;
raise notice 'PASS 15: tekrar oynatılan kamera kaydı orijinal zamanıyla, canlı kayıtla aynı ücretle';

perform pg_temp.kamera();   -- back to the camera for 16 and 17

-- Too old: an exception row, and NO ticket.
select count(*) into v_n from public.istisnalar;
select public.bilet_ac('34ESKI01', gen_random_uuid(), 'KAMERA',
                       now() - interval '13 hours') into v_bilet2;
if v_bilet2 is not null then raise exception 'FAIL 16a: 13 saatlik bayat kayıt bilet açtı'; end if;
select count(*) into v_n from public.istisnalar where tur = 'BAYAT' and plaka = '34ESKI01';
if v_n <> 1 then raise exception 'FAIL 16b: BAYAT istisnası yazılmadı'; end if;
select count(*) into v_n from public.biletler where plaka = '34ESKI01';
if v_n <> 0 then raise exception 'FAIL 16c: bayat kayıt için bilet oluştu'; end if;

-- Dated in the future: a broken clock, not a late event.
select public.bilet_ac('34GELE01', gen_random_uuid(), 'KAMERA',
                       now() + interval '1 hour') into v_bilet2;
if v_bilet2 is not null then raise exception 'FAIL 16d: gelecek tarihli kayıt bilet açtı'; end if;
select count(*) into v_n from public.istisnalar where tur = 'GELECEK' and plaka = '34GELE01';
if v_n <> 1 then raise exception 'FAIL 16e: GELECEK istisnası yazılmadı'; end if;
raise notice 'PASS 16: bayat kayıt işaretlenip bilet açılmıyor, gelecek tarihli kayıt reddediliyor';

-- Orphan exit: flagged, and no phantom open ticket invented.
select public.kamera_cikis_bildir('34YOKBI01', gen_random_uuid(), now()) into v_bilet2;
if v_bilet2 is not null then raise exception 'FAIL 17a: olmayan araç için çıkış eşleşti'; end if;
select count(*) into v_n from public.istisnalar
 where tur = 'ACIK_BILET_YOK' and plaka = '34YOKBI01';
if v_n <> 1 then raise exception 'FAIL 17b: ACIK_BILET_YOK istisnası yazılmadı'; end if;
select count(*) into v_n from public.biletler where plaka = '34YOKBI01';
if v_n <> 0 then raise exception 'FAIL 17c: çıkış kaydı hayalet bilet yarattı'; end if;
raise notice 'PASS 17: girişi olmayan çıkış işaretleniyor, hayalet bilet oluşmuyor';

-- The camera's turn is over; everything below is a person again.
perform pg_temp.login(u_personel);

-- =====================================================================
-- 18  Closing: money identity and immutability
-- =====================================================================

select b.tahsil_kurus into v_ucret
  from public.bilet_kapat(v_bilet, 'NAKIT') b;

select ucret_kurus, indirim_kurus, tahsil_kurus, durum
  into v_rec from public.biletler where id = v_bilet;
if v_rec.durum <> 'KAPALI' then raise exception 'FAIL 18a: bilet kapanmadı'; end if;
if v_rec.tahsil_kurus <> v_rec.ucret_kurus - v_rec.indirim_kurus then
  raise exception 'FAIL 18b: tahsil <> ücret - indirim';
end if;

-- The ticket above is seconds old, so its fee is 0 and it proves nothing about
-- money. Close the 3-hour-old CAMERA ticket instead, where the duration is
-- exactly 180 minutes: now() is the transaction timestamp and therefore
-- identical everywhere in this file, so this is deterministic rather than
-- timing-dependent.
--
-- The EXPECTED amount is computed from the tariff the ticket snapshotted, not
-- from the seeded prices. An earlier version hard-coded 12000 and failed the
-- moment the owner changed the price list — a test that breaks when the
-- business changes its prices is testing the prices, not the arithmetic. The
-- sum below is written out by hand rather than calling `ucret_hesapla`, which
-- is the function under test; two implementations agreeing is the check.
select id into v_id from public.biletler where plaka = '34KAM002' and durum = 'ACIK';
if v_id is null then raise exception 'FAIL 18c: 3 saatlik kamera bileti bulunamadı'; end if;

-- The quote the operator sees, taken BEFORE the charge...
select public.ucret_hesapla(b.giris_at, now(), b.tarife_id) into v_ucret2
  from public.biletler b where b.id = v_id;
-- 082: canlı tarife KADEMELI ise 3 saatlik bilet ilk kademeyi aşar ve kapanış
-- karar ister. Tam tarife seçilir (ücret = ucret_hesapla); aşım yoksa geçilir.
begin
  perform public.bilet_asim_karar(v_id, true);
exception when others then
  if sqlerrm <> 'Bu bilette süre aşımı yok.' then raise; end if;
end;
select b.tahsil_kurus into v_ucret from public.bilet_kapat(v_id, 'NAKIT') b;

-- ...must equal the charge. One function prices a stay, so these cannot differ.
if v_ucret <> v_ucret2 then
  raise exception 'FAIL 18d: gösterilen ücret (%) tahsil edilenden (%) farklı', v_ucret2, v_ucret;
end if;
select t.tur, t.sabit_kurus, t.ucretsiz_dakika, t.ilk_saat_kurus,
       t.sonraki_saat_kurus, t.gunluk_tavan_kurus, t.kademeler
  into v_rec
  from public.tarifeler t
  join public.biletler b on b.tarife_id = t.id
 where b.id = v_id;

if v_rec.ucretsiz_dakika >= 180 then
  v_n2 := 0;                                   -- ücretsiz süre 3 saati yutuyor
elsif v_rec.tur = 'SABIT' then
  v_n2 := v_rec.sabit_kurus;                   -- giriş başına tek fiyat
elsif v_rec.tur::text = 'KADEMELI' then
  -- 051: 180 dakika bir günden kısa; sınır alttaki kademeye ait, yani üst
  -- sınırı 180 ya da üstü olan İLK kademe. (Bu dal yokken canlı tarife
  -- kademeliye geçince test 0 bekliyordu — 2026-11-15.)
  select (k.e ->> 'kurus')::integer into v_n2
    from jsonb_array_elements(v_rec.kademeler) with ordinality as k(e, sira)
   where (k.e ->> 'dakika')::integer >= 180
   order by k.sira
   limit 1;
else
  v_n2 := v_rec.ilk_saat_kurus + 2 * v_rec.sonraki_saat_kurus;
  if v_rec.gunluk_tavan_kurus > 0 then
    v_n2 := least(v_n2, v_rec.gunluk_tavan_kurus);
  end if;
end if;

-- Boş bir beklenti `<>` ile hiç başarısız olmaz; sessizce geçmesin.
if v_n2 is null then
  raise exception 'FAIL 18e: tarifeden beklenen ücret hesaplanamadı (tür %)', v_rec.tur;
end if;
if v_ucret <> v_n2 then
  raise exception 'FAIL 18e: 3 saatlik park % kuruş çıktı, tarifeye göre % olmalıydı',
    v_ucret, v_n2;
end if;
select count(*) into v_n from public.tahsilatlar
 where bilet_id = v_id and tutar_kurus = v_n2 and yontem = 'NAKIT';
if v_n <> 1 then
  raise exception 'FAIL 18f: % kuruşluk tahsilat satırı yazılmadı', v_n2;
end if;
raise notice 'PASS 18: gösterilen ücret = tahsil edilen ücret (3 saat = % kuruş, tarifeye göre), tahsilat yazılıyor', v_n2;

-- A closed ticket is immutable.
begin
  update public.biletler set ucret_kurus = 1 where id = v_bilet;
  raise exception 'FAIL 19: kapanmış bilet değiştirilebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();
begin
  update public.biletler set ucret_kurus = 1 where id = v_bilet;
  raise exception 'FAIL 19: kapanmış bilet postgres olarak bile değiştirilebildi (guard yok)';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 19: kapanmış bilet değişmez (tetikleyici sahibi bile geçemiyor)';

-- ...but a parent going away must still be allowed to detach. A CLOSED ticket
-- has to actually HOLD the spot first, or this proves nothing: ON DELETE SET
-- NULL fires an UPDATE on that ticket, which is precisely what the guard must
-- let through. Get this wrong and deleting one spot is blocked forever by
-- last year's tickets.
perform pg_temp.login(u_personel);
select public.bilet_ac(p_plaka => '34YER001',
                       p_islem_id => gen_random_uuid(), p_park_yeri_id => v_yer) into v_id;
select park_yeri_id into v_id2 from public.biletler where id = v_id;
if v_id2 is null then raise exception 'FAIL 20a: park yeri bilete yazılmadı'; end if;
perform public.bilet_kapat(v_id, 'NAKIT');
perform pg_temp.logout();

delete from public.park_yerleri where id = v_yer;   -- must not raise

select park_yeri_id into v_id2 from public.biletler where id = v_id;
if v_id2 is not null then raise exception 'FAIL 20b: silinen yer bilette kaldı'; end if;
select durum into v_txt from public.biletler where id = v_id;
if v_txt <> 'KAPALI' then raise exception 'FAIL 20c: bilet durumu bozuldu (%)', v_txt; end if;
raise notice 'PASS 20: silinen park yeri kapanmış bileti kilitlemiyor (referans NULL''a düşüyor)';

-- =====================================================================
-- 21  Reservations and subscriptions: overlap refused by the database
-- =====================================================================

insert into public.park_yerleri (kod, tip, rezerve)
values ('TEST-EX-' || substr(gen_random_uuid()::text, 1, 6), 'NORMAL', true)
returning id into v_yer;

insert into public.rezervasyonlar (park_yeri_id, plaka, gecerlilik)
values (v_yer, '34REZ001', tstzrange(now(), now() + interval '30 days'));
begin
  insert into public.rezervasyonlar (park_yeri_id, plaka, gecerlilik)
  values (v_yer, '34REZ002', tstzrange(now() + interval '10 days', now() + interval '40 days'));
  raise exception 'FAIL 21: çakışan rezervasyon kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
-- A non-overlapping window on the same spot is fine.
insert into public.rezervasyonlar (park_yeri_id, plaka, gecerlilik)
values (v_yer, '34REZ003', tstzrange(now() + interval '31 days', now() + interval '60 days'));
raise notice 'PASS 21: aynı yerde çakışan rezervasyon EXCLUDE ile reddediliyor, bitişik olan kabul';

begin
  insert into public.abonmanlar (plaka, baslangic, bitis, ucret_kurus)
  values ('34ABON01',
          (now() at time zone 'Europe/Istanbul')::date + 10,
          (now() at time zone 'Europe/Istanbul')::date + 40, 150000);
  raise exception 'FAIL 22: aynı plakaya çakışan abonman kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 22: aynı plakada çakışan abonman dönemi reddediliyor';

-- =====================================================================
-- 23  Tariff versioning does not re-price a car already inside
-- =====================================================================

perform pg_temp.login(u_personel);
v_islem := gen_random_uuid();
select public.bilet_ac('34FIYAT1', v_islem) into v_bilet2;
select tarife_id into v_id from public.biletler where id = v_bilet2;

perform pg_temp.login(u_yonetici);
select public.tarife_guncelle(15, 99000, 99000, 0, 40000) into v_tarife_yeni;

select tarife_id into v_id2 from public.biletler where id = v_bilet2;
if v_id2 <> v_id then raise exception 'FAIL 23a: içerideki aracın tarifesi değişti'; end if;
if v_id2 = v_tarife_yeni then raise exception 'FAIL 23b: eski bilet yeni tarifeye bağlandı'; end if;
select count(*) into v_n from public.tarifeler
 where gecerli_bitis is null;
if v_n <> 1 then raise exception 'FAIL 23c: % açık tarife var, 1 bekleniyordu', v_n; end if;
select gecerli_bitis into v_ts from public.tarifeler where id = v_tarife_eski;
if v_ts is null then raise exception 'FAIL 23d: eski tarife kapatılmadı'; end if;
raise notice 'PASS 23: tarife sürümleniyor; içerideki araç girdiği fiyatı koruyor';

-- =====================================================================
-- 24  Fee override needs a reason, and is audited + notified
-- =====================================================================

perform pg_temp.login(u_personel);
begin
  perform public.bilet_kapat(v_bilet2, 'NAKIT', 100, null);
  raise exception 'FAIL 24: sebepsiz ücret değişikliği kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

select count(*) into v_n from public.audit_log where action = 'bilet_ucret_degisikligi';
perform public.bilet_kapat(v_bilet2, 'NAKIT', 100, 'Müşteri itirazı - test');
perform pg_temp.logout();
select count(*) into v_bigint from public.audit_log where action = 'bilet_ucret_degisikligi';
if v_bigint <= v_n then raise exception 'FAIL 24: ücret değişikliği audit''e yazılmadı'; end if;
select count(*) into v_n from public.notifications
 where tur = 'UCRET_DEGISIKLIGI' and profile_id = u_yonetici;
if v_n = 0 then raise exception 'FAIL 24: ücret değişikliği Yöneticiye bildirilmedi'; end if;
select ucret_kurus, tahsil_kurus into v_rec from public.biletler where id = v_bilet2;
if v_rec.ucret_kurus <> 100 or v_rec.tahsil_kurus <> 100 then
  raise exception 'FAIL 24: değiştirilen ücret uygulanmadı';
end if;
raise notice 'PASS 24: ücret değişikliği sebep istiyor, audit''e ve bildirime düşüyor';

-- =====================================================================
-- 25  Points: cooldown, ₺0 stays, redemption caps, append-only ledger
-- =====================================================================

-- Turning points on and setting the earn rate are BOTH Yönetici actions, so
-- do them as one. logout() drops to the session superuser with a NULL
-- auth.uid(), and is_yonetici() is application logic — superuser rights do not
-- satisfy it, so the RPC refuses exactly as it should in production.
perform pg_temp.login(u_yonetici);
update public.otopark_ayarlari set puan_aktif = true where id = 1;
perform public.puan_kural_guncelle(10, 100, 6, 0);   -- 10 puan/giriş, 1 puan = 1,00 ₺

perform pg_temp.login(u_personel);
select public.bilet_ac('34PUAN01', gen_random_uuid()) into v_bilet;
perform pg_temp.logout();
select coalesce(sum(puan), 0) into v_n from public.puan_hareketleri where hesap_id = v_hesap;
if v_n <> 10 then raise exception 'FAIL 25a: girişte puan kazanılmadı (bakiye %)', v_n; end if;

-- Inside the cooldown, a second entry earns nothing.
perform pg_temp.login(u_personel);
perform public.bilet_kapat(v_bilet, 'NAKIT');
select public.bilet_ac('34PUAN01', gen_random_uuid()) into v_bilet;
perform pg_temp.logout();
select coalesce(sum(puan), 0) into v_n from public.puan_hareketleri where hesap_id = v_hesap;
if v_n <> 10 then raise exception 'FAIL 25b: bekleme süresi içinde tekrar puan verildi (%)', v_n; end if;
raise notice 'PASS 25: girişte puan kazanılıyor, bekleme süresi içinde tekrar kazanılmıyor';

-- A ₺0 subscriber stay earns nothing.
insert into public.hesap_araclari (hesap_id, plaka) values (v_hesap, '34ABON01');
perform pg_temp.login(u_personel);
select public.bilet_ac('34ABON01', gen_random_uuid()) into v_id;
perform pg_temp.logout();
select abonman_id into v_id2 from public.biletler where id = v_id;
if v_id2 is null then raise exception 'FAIL 26a: abonman girişi abonmana bağlanmadı'; end if;
select coalesce(sum(puan), 0) into v_n from public.puan_hareketleri where hesap_id = v_hesap;
if v_n <> 10 then raise exception 'FAIL 26b: ücretsiz abonman girişinde puan verildi'; end if;
raise notice 'PASS 26: ₺0 abonman girişinde puan kazanılmıyor';

-- Redemption is capped by the fee and by the balance.
perform pg_temp.login(u_personel);
begin
  perform public.puan_kullan(v_bilet, 99999);
  raise exception 'FAIL 27: bakiyeden fazla puan kullanılabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.puan_kullan(v_id, 5);
  raise exception 'FAIL 27: abonman bileti üzerinde puan kullanılabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 27: puan kullanımı bakiye ve ücret ile sınırlı, abonmanda kapalı';

-- The ledger is append-only for every client role.
perform pg_temp.login(u_yonetici);
begin
  update public.puan_hareketleri set puan = 9999 where hesap_id = v_hesap;
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'FAIL 28: puan hareketi güncellenebildi'; end if;
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  delete from public.puan_hareketleri where hesap_id = v_hesap;
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'FAIL 28: puan hareketi silinebildi'; end if;
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 28: puan defteri yalnızca ekleme (Yönetici bile değiştiremiyor/silemiyor)';

-- =====================================================================
-- 29  Shifts
-- =====================================================================

perform pg_temp.login(u_personel);
begin
  perform public.vardiya_ac(0);
  raise exception 'FAIL 29: ikinci açık vardiya açılabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

-- 035: personelin sayımı yalnızca İSTEKTİR, kapanışı Yönetici yapar. Fark
-- hesabı bu yüzden onaydan sonra okunuyor.
select v.fark_kurus into v_ucret from public.vardiya_kapat(0, 'test kapanış') v;
perform pg_temp.logout();
perform pg_temp.login(u_yonetici);
perform public.vardiya_kapatma_onayla(v_vardiya);
perform pg_temp.logout();
select beklenen_nakit_kurus, sayilan_nakit_kurus, fark_kurus
  into v_rec from public.vardiyalar where id = v_vardiya;
if v_rec.fark_kurus <> 0 - v_rec.beklenen_nakit_kurus then
  raise exception 'FAIL 29: vardiya farkı yanlış hesaplandı';
end if;
-- Bildirim artık İSTEK anında gidiyor ve farkı kendisi taşıyor. Onaydaki
-- VARDIYA_FARK burada aranmaz: `notify_yonetici` çağıranı hariç tutar, ve
-- onaylayan Yöneticinin kendisidir — tek Yöneticili bir kasada o satır hiç
-- doğmaz. Değişmeyen kural şu: farkı bir Yönetici görmüş olmalı.
select count(*) into v_n from public.notifications
 where tur::text = 'VARDIYA_KAPATMA' and profile_id = u_yonetici
   and govde like '%fark%';
if v_n = 0 then
  raise exception 'FAIL 29: kapatma isteği ve farkı Yöneticiye bildirilmedi';
end if;
raise notice 'PASS 29: tek açık vardiya kuralı ve fark hesabı + bildirimi doğru';

-- Personel no longer see a closed shift's tickets through the SHIFT once it
-- is shut. Since 067 (owner, 2026-11-15) an exit from the last 3 Istanbul
-- days stays readable anyway — v_bilet2 was closed just now, so it must
-- still show — but an older exit from that same shift must not.
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum,
                             cikis_kaynak, kapatan_vardiya_id)
values (gen_random_uuid(), 'ZZ30ESKI', now() - interval '10 days 1 hour',
        now() - interval '10 days', v_tarife_yeni, 'KAPALI', 'KAMERA', v_vardiya);
perform pg_temp.login(u_personel);
select count(*) into v_n from public.biletler where plaka = 'ZZ30ESKI';
if v_n <> 0 then raise exception 'FAIL 30: kapanmış vardiyanın eski biletleri hâlâ görünüyor'; end if;
select count(*) into v_n from public.biletler where id = v_bilet2;
if v_n <> 1 then raise exception 'FAIL 30: bugünkü çıkış 3 günlük pencerede görünmüyor (067)'; end if;
perform pg_temp.logout();
raise notice 'PASS 30: vardiya kapanınca eski biletler Personel görüşünden çıkıyor; son 3 günün çıkışları kalıyor (067)';

-- =====================================================================
-- 31  Last-Yönetici protection
-- =====================================================================

perform pg_temp.logout();
update public.profiles set durum = 'DISABLED'
 where rol = 'YONETICI' and durum = 'ACTIVE' and id <> u_yonetici;

perform pg_temp.login(u_yonetici);
begin
  perform public.set_role(u_yonetici, 'PERSONEL');
  raise exception 'FAIL 31: kendi rolünü değiştirebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

perform pg_temp.logout();
update public.profiles set rol = 'YONETICI', durum = 'ACTIVE' where id = u_personel2;
perform pg_temp.login(u_personel2);
begin
  perform public.set_role(u_yonetici, 'PERSONEL');   -- allowed: two remain
exception when others then
  raise exception 'FAIL 31: iki Yönetici varken görevden alma reddedildi: %', sqlerrm;
end;
begin
  perform public.set_status(u_personel2, 'DISABLED');
  raise exception 'FAIL 31: kendi hesabını kapatabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
-- FİKSTÜRÜ GERİ AL. Bu blok kanıtını u_yonetici'yi GERÇEKTEN görevden alarak
-- verir ve eskiden onu öyle bırakırdı: sonraki her `login(u_yonetici)` aslında
-- bir Personel oturumu oluyordu, PASS 36'daki ilk Yönetici-gerektiren çağrıya
-- kadar da kimse fark etmiyordu. Bir testin bıraktığı durum, kendisinden
-- sonrakilerin girdisidir.
perform pg_temp.logout();
update public.profiles set rol = 'YONETICI', durum = 'ACTIVE' where id = u_yonetici;
-- u_personel2 KASITLI olarak Yönetici bırakılır: PASS 33 kapanmış bir bileti
-- onunla iptal eder ve satırında öyle yazar. Onu da geri almak, bu bloğun
-- düzelttiği hatanın aynısını bir sonraki bloğa taşımak olurdu.

raise notice 'PASS 31: son Yönetici korunuyor, kendi rolü/durumu değiştirilemiyor';

-- =====================================================================
-- 32  Internal and cron functions are unreachable from the client
-- =====================================================================

perform pg_temp.logout();

if has_function_privilege('authenticated', 'public.audit(text,text,uuid,jsonb)', 'execute')
   or has_function_privilege('authenticated',
        'public.notify_yonetici(public.bildirim_tur,text,text,text)', 'execute')
   or has_function_privilege('authenticated', 'public.puan_kazandir(uuid,text)', 'execute') then
  raise exception 'FAIL 32: iç fonksiyonlar istemciye açık';
end if;

if has_function_privilege('authenticated', 'public.run_gunluk_bakim()', 'execute')
   or has_function_privilege('authenticated', 'public.run_kamera_kontrol()', 'execute') then
  raise exception 'FAIL 32: cron fonksiyonları istemciye açık';
end if;

-- The revoke must name PUBLIC, not just the two roles — they inherit from it.
if has_function_privilege('public', 'public.run_gunluk_bakim()', 'execute') then
  raise exception 'FAIL 32: PUBLIC hâlâ cron fonksiyonunu çalıştırabiliyor';
end if;
raise notice 'PASS 32: audit/notify/puan_kazandir ve cron fonksiyonları istemciye kapalı';

-- =====================================================================
-- 33  Lost ticket, and cancelling a closed ticket writes a counter-entry
-- =====================================================================

perform pg_temp.login(u_personel);
select public.vardiya_ac(0) into v_vardiya;
select public.kayip_bilet_tahsil('34KAYIP1', 'NAKIT', gen_random_uuid()) into v_bilet;
select durum, kayip_bilet, tahsil_kurus into v_rec from public.biletler where id = v_bilet;
if v_rec.durum <> 'KAPALI' or not v_rec.kayip_bilet then
  raise exception 'FAIL 33a: kayıp bilet kapalı olarak açılmadı';
end if;
if v_rec.tahsil_kurus <= 0 then raise exception 'FAIL 33b: kayıp bilet ücreti alınmadı'; end if;

-- Personel may not cancel a CLOSED ticket.
begin
  perform public.bilet_iptal(v_bilet, 'test');
  raise exception 'FAIL 33c: Personel kapanmış bileti iptal edebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

perform pg_temp.login(u_personel2);   -- now a Yönetici
perform public.bilet_iptal(v_bilet, 'Test iptali');
perform pg_temp.logout();
select durum into v_txt from public.biletler where id = v_bilet;
if v_txt <> 'IPTAL' then raise exception 'FAIL 33d: bilet iptal edilmedi'; end if;
select coalesce(sum(tutar_kurus), 0) into v_n from public.tahsilatlar where bilet_id = v_bilet;
if v_n <> 0 then raise exception 'FAIL 33e: iptal karşı kaydı net sıfır yapmadı (%)', v_n; end if;
select count(*) into v_n from public.tahsilatlar
 where bilet_id = v_bilet and iptal_of is not null;
if v_n <> 1 then raise exception 'FAIL 33f: iptal karşı kaydı yazılmadı'; end if;
raise notice 'PASS 33: kayıp bilet tahsil ediliyor; kapanmış bilet iptali karşı kayıtla nötrleniyor';

-- =====================================================================
-- 34  Tek tarife (006): araç tipi kaldırıldıktan sonraki değişmezler
--     Replaces the old vehicle-type-correction test. The invariant it used
--     to rely on — "exactly one open-ended tariff" — was per-type before and
--     is now global, enforced by tarifeler_aktif_ux on a constant expression.
-- =====================================================================

perform pg_temp.logout();

-- The enum, the column and the correction RPC are all gone.
if exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
            where n.nspname = 'public' and t.typname = 'arac_tipi') then
  raise exception 'FAIL 34: arac_tipi tipi hâlâ var';
end if;
if exists (select 1 from information_schema.columns
            where table_schema = 'public' and column_name = 'arac_tipi') then
  raise exception 'FAIL 34: arac_tipi kolonu hâlâ var';
end if;
if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'bilet_arac_tipi_duzelt') then
  raise exception 'FAIL 34: bilet_arac_tipi_duzelt hâlâ var';
end if;

-- A second open-ended tariff must be refused by the index, not merely avoided
-- by convention. Superuser here on purpose: no RLS or grant can mask it.
begin
  insert into public.tarifeler (ilk_saat_kurus, sonraki_saat_kurus)
  values (1, 1);
  raise exception 'FAIL 34: ikinci aktif tarife kabul edildi';
exception when unique_violation then
  null;  -- expected
when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

raise notice 'PASS 34: araç tipi tamamen kaldırıldı; tek aktif tarife DB''de zorunlu';

-- =====================================================================
-- 35  Park yerleri / rezervasyonlar: Personel READS, never WRITES
--     Spots are now a section at the bottom of Gişe, so a Personel reaches
--     them daily. That makes this split load-bearing: they must see free bays
--     (a gate question) and must not be able to create, rename, retire or
--     un-retire one, nor touch a reservation.
-- =====================================================================

perform pg_temp.login(u_personel);

select count(*) into v_n from public.park_yerleri;
if v_n = 0 then raise exception 'FAIL 35: Personel park yerlerini göremiyor'; end if;
select count(*) into v_n from public.rezervasyonlar;
if v_n = 0 then raise exception 'FAIL 35: Personel rezervasyonları göremiyor'; end if;

begin
  insert into public.park_yerleri (kod, tip, rezerve) values ('P-999', 'NORMAL', false);
  raise exception 'FAIL 35: Personel park yeri ekleyebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

-- UPDATE/DELETE are refused by RLS as ZERO ROWS, not as an error: the row
-- simply falls outside the USING clause. Asserting on a raise would pass
-- for the wrong reason, so count the damage instead.
update public.park_yerleri set is_active = false;
get diagnostics v_n = row_count;
if v_n <> 0 then raise exception 'FAIL 35: Personel park yerini güncelleyebildi (% satır)', v_n; end if;

-- Wrapped, unlike the update above: 007 took the direct DELETE grant off this
-- table so that deletion has to go through `kayit_sil()` and land in the bin.
-- So this is refused by the PRIVILEGE system (42501) before RLS is consulted —
-- a stronger stop than a zero-row refusal, and both count as a pass here.
begin
  delete from public.rezervasyonlar;
  get diagnostics v_n = row_count;
  if v_n <> 0 then
    raise exception 'FAIL 35: Personel rezervasyon silebildi (% satır)', v_n;
  end if;
exception
  when insufficient_privilege then null;
  when others then raise;
end;

-- The window is deliberately FAR from every reservation PASS 21 wrote. An
-- overlapping one would be refused by the EXCLUDE constraint too, so the
-- test would pass without proving anything about RLS.
begin
  insert into public.rezervasyonlar (park_yeri_id, plaka, gecerlilik)
  values (v_yer, '34REZ999',
          tstzrange(now() + interval '100 days', now() + interval '110 days'));
  raise exception 'FAIL 35: Personel rezervasyon ekleyebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

raise notice 'PASS 35: Personel park yeri/rezervasyon okuyor, hiçbirini yazamıyor';

-- =====================================================================
-- 36  Çöp Kutusu (007): silme para geri alır, geri alma geri getirir
-- =====================================================================

perform pg_temp.login(u_yonetici);

-- (a) Personel cannot delete, and cannot read the bin.
perform pg_temp.login(u_personel);
begin
  perform public.bilet_sil(gen_random_uuid());
  raise exception 'FAIL 36: Personel bilet silebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
select count(*) into v_n from public.cop;
if v_n <> 0 then raise exception 'FAIL 36: Personel çöp kutusunu görüyor'; end if;

-- Direct DELETE must be gone too, or the RPC is not the only way out.
begin
  delete from public.kasa_hareketleri;
  raise exception 'FAIL 36: Personel doğrudan DELETE yapabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

-- (b) A collected ticket: deleting it must take the money with it.
perform pg_temp.login(u_personel);
-- 030: vardiya kasaya ait, kişiye değil — "açık mı" sorusunun tek doğru
-- sorulma biçimi budur. Kişiye göre sorulsaydı başkasının (ya da otomatik
-- açılmış) bir vardiyası varken vardiya_ac çağrılır ve fixture patlardı.
select public.acik_vardiyam() into v_vardiya;
if v_vardiya is null then
  select public.vardiya_ac(0) into v_vardiya;
end if;
select public.bilet_ac('34COP001', gen_random_uuid()) into v_bilet;

-- KURULUM, iddia değil: istemcinin `biletler` üzerinde UPDATE yetkisi yoktur
-- (003 yalnızca SELECT verir; PASS 37e bunu ayrıca sınar), dolayısıyla bileti
-- geriye tarihlemek migration rolüyle yapılır. Oturum açıkken denenirse 42501
-- alınır ve test, sınadığı şeyle ilgisiz bir sebeple düşer.
perform pg_temp.logout();
update public.biletler set giris_at = now() - interval '3 hours' where id = v_bilet;
perform pg_temp.login(u_personel);

perform public.bilet_kapat(v_bilet, 'NAKIT');

select coalesce(sum(t.tutar_kurus), 0) into v_n
  from public.tahsilatlar t where t.vardiya_id = v_vardiya and t.yontem = 'NAKIT';
if v_n <= 0 then raise exception 'FAIL 36: kurulum — tahsilat yazılmadı'; end if;

perform pg_temp.login(u_yonetici);
perform public.bilet_sil(v_bilet);

if exists (select 1 from public.biletler where id = v_bilet) then
  raise exception 'FAIL 36: bilet silinmedi';
end if;
select count(*) into v_n from public.tahsilatlar where bilet_id = v_bilet;
if v_n <> 0 then raise exception 'FAIL 36: tahsilat bilete bağlı kaldı'; end if;
-- The real test: no detached row left behind inflating the day's takings.
select count(*) into v_n from public.tahsilatlar
 where vardiya_id = v_vardiya and bilet_id is null and tur = 'BILET';
if v_n <> 0 then raise exception 'FAIL 36: kopmuş tahsilat kaldı (% satır)', v_n; end if;

-- (c) It landed in the bin, with its collections attached.
select count(*) into v_n from public.cop
 where tablo = 'biletler' and kayit_id = v_bilet;
if v_n <> 1 then raise exception 'FAIL 36: bilet çöpe düşmedi'; end if;
select id into v_id from public.cop where tablo = 'biletler' and kayit_id = v_bilet;
select jsonb_array_length(ek -> 'tahsilatlar') into v_n from public.cop where id = v_id;
if v_n < 1 then raise exception 'FAIL 36: tahsilat anlık görüntüsü alınmadı'; end if;

-- (d) Restore brings back the row under its ORIGINAL id, and the money.
perform public.cop_geri_al(v_id);
if not exists (select 1 from public.biletler where id = v_bilet) then
  raise exception 'FAIL 36: bilet geri gelmedi';
end if;
select count(*) into v_n from public.tahsilatlar where bilet_id = v_bilet;
if v_n <> 1 then raise exception 'FAIL 36: tahsilat geri gelmedi'; end if;
if exists (select 1 from public.cop where id = v_id) then
  raise exception 'FAIL 36: geri alınan kayıt çöpte kaldı';
end if;

-- (e) A closed shift is repaired, and the COUNTED cash is never rewritten.
perform pg_temp.login(u_personel);
perform public.vardiya_kapat(500000, null);
perform pg_temp.login(u_yonetici);
-- 035: istek onaylanmadan vardiya kapanmaz, ve bu blok KAPALI vardiya ister.
perform public.vardiya_kapatma_onayla(v_vardiya);
select sayilan_nakit_kurus, beklenen_nakit_kurus into v_rec
  from public.vardiyalar where id = v_vardiya;
v_n := v_rec.beklenen_nakit_kurus;
perform public.bilet_sil(v_bilet);
select sayilan_nakit_kurus, beklenen_nakit_kurus, fark_kurus into v_rec
  from public.vardiyalar where id = v_vardiya;
if v_rec.sayilan_nakit_kurus <> 500000 then
  raise exception 'FAIL 36: sayılan nakit değiştirildi';
end if;
if v_rec.beklenen_nakit_kurus >= v_n then
  raise exception 'FAIL 36: kapanmış vardiyanın beklenen nakdi düşmedi';
end if;
if v_rec.fark_kurus <> v_rec.sayilan_nakit_kurus - v_rec.beklenen_nakit_kurus then
  raise exception 'FAIL 36: fark yeniden hesaplanmadı';
end if;

-- (f) The active tariff cannot be deleted — the gate would have no price.
begin
  perform public.tarife_sil((select id from public.tarifeler where gecerli_bitis is null));
  raise exception 'FAIL 36: geçerli tarife silinebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

-- (g) An account holding a points ledger is refused: the cascade would
--     destroy a liability record the snapshot does not carry.
insert into public.hesaplar (ad) values ('Çöp Test') returning id into v_hesap;

-- Yine KURULUM: `puan_hareketleri` istemciye SELECT-only verilir (003) çünkü
-- defter yalnızca RPC'lerle büyür. Satırı migration rolüyle yazıyoruz; asıl
-- iddia zaten aşağıdaki silme reddi.
perform pg_temp.logout();
insert into public.puan_hareketleri (hesap_id, tur, puan, kural_id)
select v_hesap, 'DUZELTME', 10, k.id from public.puan_kurallari k
 where k.gecerli_bitis is null;
perform pg_temp.login(u_yonetici);
begin
  perform public.kayit_sil('hesaplar', v_hesap);
  raise exception 'FAIL 36: puan hareketi olan hesap silindi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
if not exists (select 1 from public.puan_hareketleri where hesap_id = v_hesap) then
  raise exception 'FAIL 36: puan defteri yok edildi';
end if;

-- (h) An unknown table name is refused rather than interpolated anywhere.
begin
  perform public.kayit_sil('profiles', u_personel);
  raise exception 'FAIL 36: izin listesi dışı tablo silinebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

raise notice 'PASS 36: silme parayı geri alıyor, çöp kutusu geri getiriyor, sayılan nakit korunuyor';

-- ==========================================================================
-- PASS 37  Müşteri bilgisi (008)
-- ==========================================================================
perform pg_temp.login(u_personel);

-- (a) Written at entry and normalised on the way in: spacing is dropped, and
--     blank is stored as NULL rather than ''. The number is given WITHOUT the
--     trunk zero because that is the server's actual contract — ten digits,
--     no leading zero — and this line used to hand it '0532 …' while asserting
--     a completely different number, so it was wrong twice over. Stripping the
--     zero an operator types is the CLIENT's job (lib/telefon.ts).
v_bilet := public.bilet_ac('37AAA111', gen_random_uuid(), 'MOBIL', null, null, null, null,
                           '  Volkswagen Passat  ', '  Ahmet Yılmaz  ', ' 532 111 22 33 ');
if v_bilet is null then
  raise exception 'FAIL 37a: bilet açılmadı';
end if;
select arac_bilgi, musteri_ad, musteri_tel into v_txt, v_txt2, v_txt3
  from public.biletler where id = v_bilet;
if v_txt <> 'Volkswagen Passat' or v_txt2 <> 'Ahmet Yılmaz' or v_txt3 <> '5321112233' then
  raise exception 'FAIL 37a: normalizasyon yanlış (%, %, %)', v_txt, v_txt2, v_txt3;
end if;

-- (b) A driver who says nothing still gets a ticket, and blank is NULL.
v_bilet2 := public.bilet_ac('37BBB222', gen_random_uuid(), 'MOBIL', null, null, null, null,
                            '   ', '', null);
select arac_bilgi, musteri_ad, musteri_tel into v_txt, v_txt2, v_txt3
  from public.biletler where id = v_bilet2;
if v_txt is not null or v_txt2 is not null or v_txt3 is not null then
  raise exception 'FAIL 37b: boş alan '''' olarak yazıldı, NULL olmalıydı';
end if;

-- (c) A bad number is refused rather than silently dropped.
begin
  perform public.bilet_musteri_guncelle(v_bilet, null, null, '12345');
  raise exception 'FAIL 37c: geçersiz numara kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

-- (d) Personel — the operator who typed it — can correct it, and the RPC
--     writes ALL THREE columns, so clearing a field really clears it.
perform public.bilet_musteri_guncelle(v_bilet, 'Renault Clio', null, '5330001122');
select arac_bilgi, musteri_ad, musteri_tel into v_txt, v_txt2, v_txt3
  from public.biletler where id = v_bilet;
if v_txt <> 'Renault Clio' or v_txt2 is not null or v_txt3 <> '5330001122' then
  raise exception 'FAIL 37d: güncelleme kısmi kaldı (%, %, %)', v_txt, v_txt2, v_txt3;
end if;

-- (e) The client has NO update path of its own — this is what makes the RPC
--     the only way in, and biletler_immutable_guard the only answer to "can
--     this row change".
begin
  update public.biletler set musteri_ad = 'Sızıntı' where id = v_bilet;
  raise exception 'FAIL 37e: istemci biletler tablosunu doğrudan güncelleyebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
if exists (select 1 from public.biletler where id = v_bilet and musteri_ad = 'Sızıntı') then
  raise exception 'FAIL 37e: doğrudan güncelleme yazdı';
end if;

-- (f) Once the car has left the details freeze with the rest of the ticket.
if public.acik_vardiyam() is null then
  perform public.vardiya_ac(0);
end if;
perform public.bilet_kapat(v_bilet, 'NAKIT');
begin
  perform public.bilet_musteri_guncelle(v_bilet, 'Sonradan', null, null);
  raise exception 'FAIL 37f: kapanmış bilette müşteri bilgisi değiştirilebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
if exists (select 1 from public.biletler where id = v_bilet and arac_bilgi = 'Sonradan') then
  raise exception 'FAIL 37f: kapanmış bilet değişti';
end if;

-- (g) The note rides the same path, and the LIST derives its two columns
--     server-side: the marker, and a fee priced by the same ucret_hesapla
--     bilet_kapat uses — so a row can never quote a number the collect screen
--     would disagree with.
perform pg_temp.login(u_personel);
v_bilet2 := public.bilet_ac('37CCC333', gen_random_uuid(), 'MOBIL', null, null, null, null,
                            null, null, null, '  Ön tamponda çizik var  ');
select notlar into v_txt from public.biletler where id = v_bilet2;
if v_txt <> 'Ön tamponda çizik var' then
  raise exception 'FAIL 37g: not normalize edilmedi (%)', v_txt;
end if;

select a.notu_var, a.ucret_kurus into v_bool, v_ucret
  from public.acik_bilet_ara('37CCC333') a where a.id = v_bilet2;
if not v_bool then
  raise exception 'FAIL 37g: notu_var listede false';
end if;
if v_ucret is distinct from public.ucret_hesapla(
     (select giris_at from public.biletler where id = v_bilet2), now(),
     (select tarife_id from public.biletler where id = v_bilet2)) then
  raise exception 'FAIL 37g: liste ücreti ucret_hesapla ile uyuşmuyor (%)', v_ucret;
end if;

-- A ticket with no note must not light the marker.
select a.notu_var into v_bool from public.acik_bilet_ara('37BBB222') a;
if v_bool then
  raise exception 'FAIL 37g: notsuz bilette notu_var true';
end if;

-- Clearing the note through the RPC really clears it.
perform public.bilet_musteri_guncelle(v_bilet2, null, null, null, null);
if (select notlar from public.biletler where id = v_bilet2) is not null then
  raise exception 'FAIL 37g: not temizlenemedi';
end if;
perform pg_temp.logout();

raise notice 'PASS 37: müşteri bilgisi ve not normalize ediliyor, liste ücreti sunucudan geliyor';

-- =====================================================================
-- 38  Yer düzeni (009): kapasiteden üretilir, küçültmek kapatır ama silmez
--     The whole point of the generator is that nobody hand-numbers a lot any
--     more — which means one bad call could retire every bay in it. These
--     checks are about what it REFUSES to do.
-- =====================================================================

-- Fixture: boş bir otopark. 38 ve 39 P-01…P-05'te yalnızca testin kendi
-- koyduklarının durduğunu varsayar; ama dosya CANLI veritabanında koşar.
-- 2026-10-31 tezgâh kurulumundan beri kamera gerçek biletler açıyor ve kamera
-- bileti ilk boş yeri (P-01) alıyor — 39c bu yüzden "P-02" ile patladı.
-- Uygulama doğru çalışıyordu; testin şu an park etmiş araçlara bağlı olmaması
-- gerekir. Canlı açık biletler yerlerinden alınır, güncel/gelecek
-- rezervasyonlar 1900'e (her biri kendi günü — çakışma kısıtı tutmasın)
-- taşınır. Hiçbir şey silinmez; dosyanın sonundaki ROLLBACK hepsini geri alır.
perform pg_temp.logout();
update public.biletler
   set park_yeri_id = null
 where durum = 'ACIK' and park_yeri_id is not null;
update public.rezervasyonlar r
   set gecerlilik = tstzrange(timestamptz '1900-01-01 00:00+00' + make_interval(days => s.rn),
                              timestamptz '1900-01-01 01:00+00' + make_interval(days => s.rn))
  from (select x.id, row_number() over (order by x.id)::int as rn
          from public.rezervasyonlar x
         where upper(x.gecerlilik) is null or upper(x.gecerlilik) > now()) s
 where r.id = s.id;
if exists (select 1 from public.biletler where durum = 'ACIK' and park_yeri_id is not null)
   or exists (select 1 from public.rezervasyonlar
               where upper(gecerlilik) is null or upper(gecerlilik) > now()) then
  raise exception 'FAIL 38: fixture — otopark boşaltılamadı (yerde açık bilet ya da güncel rezervasyon kaldı)';
end if;

-- (a) Personel cannot run it. The settings screen is Yönetici-only, but a
--     hidden screen has never been the boundary.
perform pg_temp.login(u_personel);
begin
  perform public.park_yerleri_uret(3, 1, 1, false);
  raise exception 'FAIL 38a: Personel yer düzeni üretebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

perform pg_temp.login(u_yonetici);

-- (b) Nonsense is refused before a single row is written.
begin
  perform public.park_yerleri_uret(-1, 0, 0, false);
  raise exception 'FAIL 38b: negatif yer sayısı kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.park_yerleri_uret(2001, 0, 0, false);
  raise exception 'FAIL 38b: 2000 üstü yer sayısı kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

-- (c) The layout comes out with the right codes, types and reserve flags.
v_json := public.park_yerleri_uret(5, 2, 1, false);
select count(*) into v_n from public.park_yerleri
 where is_active
   and kod in ('P-01','P-02','P-03','P-04','P-05','E-01','E-02','R-01');
if v_n <> 8 then raise exception 'FAIL 38c: 8 aktif yer bekleniyordu, % var', v_n; end if;
if (select tip from public.park_yerleri where kod = 'E-01') <> 'ENGELLI' then
  raise exception 'FAIL 38c: E-01 engelli değil';
end if;
if not (select rezerve from public.park_yerleri where kod = 'R-01') then
  raise exception 'FAIL 38c: R-01 rezerve değil';
end if;
if (select rezerve from public.park_yerleri where kod = 'P-01') then
  raise exception 'FAIL 38c: P-01 rezerve işaretlenmiş';
end if;

-- (d) Idempotent. This is the property that makes it safe to hang off the
--     settings Save button, and the one that makes "press Kaydet again" the
--     correct recovery when the layout write fails.
v_json := public.park_yerleri_uret(5, 2, 1, false);
if (v_json->>'eklenen')::int <> 0
   or (v_json->>'guncellenen')::int <> 0
   or (v_json->>'kapanan')::int <> 0 then
  raise exception 'FAIL 38d: ikinci çalıştırma değişiklik yaptı: %', v_json;
end if;

-- (e) Shrinking RETIRES, never deletes — and growing back reuses the very same
--     row, which is what keeps a bay's history and reservations attached to it
--     instead of stranding them on a dead id.
select id into v_yer from public.park_yerleri where kod = 'P-05';
v_json := public.park_yerleri_uret(3, 2, 1, false);
if (v_json->>'kapanan')::int <> 2 then
  raise exception 'FAIL 38e: 2 yer kapanmalıydı: %', v_json;
end if;
if not exists (select 1 from public.park_yerleri where kod = 'P-05' and not is_active) then
  raise exception 'FAIL 38e: P-05 silinmiş ya da hâlâ aktif';
end if;
v_json := public.park_yerleri_uret(5, 2, 1, false);
if (select id from public.park_yerleri where kod = 'P-05') <> v_yer then
  raise exception 'FAIL 38e: P-05 yeniden yaratılmış, geri açılmamış';
end if;
if (v_json->>'eklenen')::int <> 0 then
  raise exception 'FAIL 38e: geri açmak yerine yeni satır eklendi: %', v_json;
end if;

-- (f) A bay with a car on it is never retired, and it comes back BY CODE so
--     the operator knows which one to deal with. Retiring it would hide a
--     parked car behind "Pasifleri göster".
select public.bilet_ac('34YER005', gen_random_uuid(), 'MOBIL', null, null, v_yer)
  into v_bilet;
v_json := public.park_yerleri_uret(4, 2, 1, false);
if not exists (select 1 from public.park_yerleri where kod = 'P-05' and is_active) then
  raise exception 'FAIL 38f: dolu yer kapatıldı';
end if;
if not (v_json->'atlanan' @> '["P-05"]'::jsonb) then
  raise exception 'FAIL 38f: dolu yer raporlanmadı: %', v_json;
end if;

-- (g) So is a bay someone has reserved for a date that has not passed. The
--     window is far out on purpose: an overlapping one would be refused by the
--     EXCLUDE constraint and the test would pass for the wrong reason.
select id into v_yer from public.park_yerleri where kod = 'P-04';
insert into public.rezervasyonlar (park_yeri_id, plaka, gecerlilik)
values (v_yer, '34REZ38',
        tstzrange(now() + interval '200 days', now() + interval '210 days'));
v_json := public.park_yerleri_uret(3, 2, 1, false);
if not exists (select 1 from public.park_yerleri where kod = 'P-04' and is_active) then
  raise exception 'FAIL 38g: rezervasyonlu yer kapatıldı';
end if;
if not (v_json->'atlanan' @> '["P-04"]'::jsonb) then
  raise exception 'FAIL 38g: rezervasyonlu yer raporlanmadı: %', v_json;
end if;

-- (h) Codes outside P/E/R are left completely alone unless explicitly asked
--     about — the sample rows from 005, and any bay added by hand.
insert into public.park_yerleri (kod, tip, rezerve) values ('X-38', 'NORMAL', false);
v_json := public.park_yerleri_uret(3, 2, 1, false);
if not exists (select 1 from public.park_yerleri where kod = 'X-38' and is_active) then
  raise exception 'FAIL 38h: düzen dışı yer istenmeden kapatıldı';
end if;
v_json := public.park_yerleri_uret(3, 2, 1, true);
if exists (select 1 from public.park_yerleri where kod = 'X-38' and is_active) then
  raise exception 'FAIL 38h: düzen dışı yer opt-in ile de kapanmadı';
end if;
if not exists (select 1 from public.park_yerleri where kod = 'X-38') then
  raise exception 'FAIL 38h: düzen dışı yer silinmiş';
end if;

-- (i) The occupancy helper is server-internal. It reads tickets and
--     reservations with RLS bypassed, so a client path to it would be a way
--     around both.
if has_function_privilege('authenticated', 'public.yer_mesgul(uuid)', 'execute') then
  raise exception 'FAIL 38i: yer_mesgul istemciye açık';
end if;
perform pg_temp.logout();

raise notice 'PASS 38: yer düzeni kapasiteden üretiliyor; dolu/rezerveli yer kapanmıyor, hiçbiri silinmiyor';

-- =====================================================================
-- 39  Park yeri seçimi (010): elle seçilen doğrulanır, kamera kendi bulur
--     A bay is not money, but it decides where a car IS. These checks are
--     about the three ways that can go wrong: two cars recorded on one bay,
--     a camera losing a ticket because the lot is full, and an entry that
--     silently ends up somewhere nobody chose.
--     State inherited from PASS 38: P-01…P-03 free, P-04 reserved (future
--     window), P-05 holding 34YER005, E-01/E-02 engelli, R-01 rezerve.
-- =====================================================================

perform pg_temp.login(u_personel);

-- (a) The picker is Personel-callable and says WHY each bay is or is not
--     free. Hiding the taken ones instead would make "why can't I pick P-05"
--     unanswerable at the barrier.
select count(*) into v_n from public.park_yeri_durumu();
if v_n = 0 then raise exception 'FAIL 39a: personel park yeri durumunu okuyamadı'; end if;
select dolu_plaka into v_txt from public.park_yeri_durumu() where kod = 'P-05';
if v_txt is distinct from '34YER005' then
  raise exception 'FAIL 39a: dolu yerin plakası gelmedi (%)', coalesce(v_txt, 'yok');
end if;
select rezervasyonlu into v_bool from public.park_yeri_durumu() where kod = 'P-04';
if not coalesce(v_bool, false) then
  raise exception 'FAIL 39a: rezervasyonlu yer işaretlenmedi';
end if;
-- Natural order, and it is load-bearing: the client proposes the FIRST row it
-- can use, so an order that disagrees with the server's would propose a
-- different bay than the camera would have taken.
select kod into v_txt from public.park_yeri_durumu() limit 1;
if v_txt <> 'P-01' then
  raise exception 'FAIL 39a: doğal sıra bozuk (ilk sıra: %)', coalesce(v_txt, 'yok');
end if;

-- (b) The two internals stay server-side. yer_listesi reads tickets and
--     reservations with RLS bypassed, and bos_park_yeri is a decision the
--     client is not allowed to make for the server.
if has_function_privilege('authenticated', 'public.yer_listesi()', 'execute') then
  raise exception 'FAIL 39b: yer_listesi istemciye açık';
end if;
if has_function_privilege('authenticated', 'public.bos_park_yeri()', 'execute') then
  raise exception 'FAIL 39b: bos_park_yeri istemciye açık';
end if;
if not has_function_privilege('authenticated', 'public.park_yeri_durumu()', 'execute') then
  raise exception 'FAIL 39b: park_yeri_durumu personele kapalı';
end if;

-- (c) An entry that arrives from the camera places itself in the first free
--     ordinary bay — nobody is standing there to choose one.
perform pg_temp.kamera();
select public.bilet_ac('39KAM001', gen_random_uuid(), 'KAMERA', now()) into v_bilet;
if v_bilet is null then raise exception 'FAIL 39c: kamera girişi bilet açmadı'; end if;
select p.kod into v_txt
  from public.biletler b join public.park_yerleri p on p.id = b.park_yeri_id
 where b.id = v_bilet;
if v_txt is distinct from 'P-01' then
  raise exception 'FAIL 39c: kamera girişi ilk boş yere konmadı (%)', coalesce(v_txt, 'yer yok');
end if;

-- ...and it takes ONLY a plain bay. Filling the two remaining P bays leaves
-- an engelli, a rezerve, a reserved and an occupied one — every category the
-- automatic path must refuse — so a non-NULL answer here is a bay somebody
-- else is owed.
perform pg_temp.login(u_personel);
select id into v_yer from public.park_yerleri where kod = 'P-02';
perform public.bilet_ac('39DOLU02', gen_random_uuid(), 'MOBIL', null, null, v_yer);
select id into v_yer from public.park_yerleri where kod = 'P-03';
perform public.bilet_ac('39DOLU03', gen_random_uuid(), 'MOBIL', null, null, v_yer);

perform pg_temp.logout();
select public.bos_park_yeri() into v_id;
if v_id is not null then
  raise exception 'FAIL 39c: otomatik atama engelli/rezerve/rezervasyonlu yeri seçti (%)',
    (select kod from public.park_yerleri where id = v_id);
end if;

-- (d) Rule 2. A full lot must never cost a camera ticket: the bay stays NULL
--     and the car is still recorded. A car in the lot with no ticket is
--     unbillable and an argument at the barrier; a car with no bay recorded
--     is a cosmetic gap.
perform pg_temp.kamera();
select public.bilet_ac('39KAM002', gen_random_uuid(), 'KAMERA', now()) into v_bilet2;
if v_bilet2 is null then
  raise exception 'FAIL 39d: otopark doluyken kamera kaydı kaybedildi';
end if;
if (select park_yeri_id from public.biletler where id = v_bilet2) is not null then
  raise exception 'FAIL 39d: boş yer yokken bir yer atandı';
end if;

-- (e) An operator's pick is validated, and a refusal writes NOTHING — the
--     same p_islem_id can be sent again once they choose another bay.
perform pg_temp.login(u_personel);
select id into v_yer from public.park_yerleri where kod = 'P-01';
v_islem := gen_random_uuid();
begin
  perform public.bilet_ac('39RED001', v_islem, 'MOBIL', null, null, v_yer);
  raise exception 'FAIL 39e: dolu park yerine ikinci araç konuldu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%başka bir araç%' then
    raise exception 'FAIL 39e: beklenmeyen hata: %', sqlerrm;
  end if;
end;
if exists (select 1 from public.biletler where islem_id = v_islem) then
  raise exception 'FAIL 39e: reddedilen girişten bilet kaldı';
end if;

-- A retired bay is refused too. Without this the gate could keep filling a
-- row that no longer appears anywhere in the app.
select id into v_yer from public.park_yerleri where kod = 'X-38';
begin
  perform public.bilet_ac('39RED002', gen_random_uuid(), 'MOBIL', null, null, v_yer);
  raise exception 'FAIL 39e: kullanım dışı yere araç konuldu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%kullanım dışı%' then
    raise exception 'FAIL 39e: beklenmeyen hata (pasif yer): %', sqlerrm;
  end if;
end;

begin
  perform public.bilet_ac('39RED003', gen_random_uuid(), 'MOBIL', null, null, gen_random_uuid());
  raise exception 'FAIL 39e: olmayan park yeri kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%bulunamadı%' then
    raise exception 'FAIL 39e: beklenmeyen hata (olmayan yer): %', sqlerrm;
  end if;
end;

-- (f) THE regression this migration had to be written around: the bay is now
--     read BEFORE the insert, so a retry-on-blip whose first attempt actually
--     succeeded would find its OWN ticket in the bay it picked and report the
--     operator's car as somebody else's. A repeat must still be a no-op.
--     Also the proof that a HUMAN may take an engelli bay — that is a call
--     only the person at the barrier can make.
select id into v_yer from public.park_yerleri where kod = 'E-01';
v_islem := gen_random_uuid();
select public.bilet_ac('39TEK001', v_islem, 'MOBIL', null, null, v_yer) into v_bilet;
if v_bilet is null then raise exception 'FAIL 39f: engelli yer elle seçilemedi'; end if;
select public.bilet_ac('39TEK001', v_islem, 'MOBIL', null, null, v_yer) into v_bilet2;
if v_bilet2 is distinct from v_bilet then
  raise exception 'FAIL 39f: yerli girişin tekrarı aynı bileti döndürmedi';
end if;
select count(*) into v_n from public.biletler where islem_id = v_islem;
if v_n <> 1 then raise exception 'FAIL 39f: tekrar % bilet üretti', v_n; end if;

-- (g) The friendly message above is a MESSAGE; this index is the rule. Two
--     operators tapping Kaydet in the same second are not serialised by a
--     check that ran a moment earlier.
if not exists (select 1 from pg_indexes
                where schemaname = 'public' and indexname = 'biletler_acik_yer_ux') then
  raise exception 'FAIL 39g: biletler_acik_yer_ux indeksi yok';
end if;

-- (h) Restoring a deleted open ticket must not double-book a bay that was
--     taken in the meantime — and must not be refused over one either. The
--     ticket comes back without the bay.
select id into v_yer from public.park_yerleri where kod = 'R-01';
select public.bilet_ac('39COP001', gen_random_uuid(), 'MOBIL', null, null, v_yer) into v_bilet;
perform pg_temp.login(u_yonetici);
perform public.bilet_sil(v_bilet);
perform pg_temp.login(u_personel);
select public.bilet_ac('39COP002', gen_random_uuid(), 'MOBIL', null, null, v_yer) into v_bilet2;
perform pg_temp.login(u_yonetici);
select id into v_id from public.cop where tablo = 'biletler' and kayit_id = v_bilet;
if v_id is null then raise exception 'FAIL 39h: silinen bilet çöpe düşmedi'; end if;
perform public.cop_geri_al(v_id);
if not exists (select 1 from public.biletler where id = v_bilet) then
  raise exception 'FAIL 39h: bilet park yeri yüzünden geri alınamadı';
end if;
if (select park_yeri_id from public.biletler where id = v_bilet) is not null then
  raise exception 'FAIL 39h: geri alınan bilet dolu yeri geri aldı';
end if;
if (select park_yeri_id from public.biletler where id = v_bilet2) is distinct from v_yer then
  raise exception 'FAIL 39h: yerde duran aracın kaydı bozuldu';
end if;
perform pg_temp.logout();

raise notice 'PASS 39: park yeri elle seçiliyor ve doğrulanıyor, kamera ilk boş yeri alıyor, bir yerde tek araç';

-- =====================================================================
-- 40  Aracı başka yere taşı (011)
--     One field on one open ticket, and the reason it needs testing is that
--     it is the second writer of `park_yeri_id`: everything 010 made true
--     about one car per bay has to survive a car being moved.
--     State inherited from PASS 39: P-01/P-02/P-03/P-05 occupied, E-01 and
--     R-01 occupied, P-04 empty but reserved, X-38 retired.
-- =====================================================================

perform pg_temp.login(u_personel);

-- (a) Personel move a car, deliberately: they choose the bay at Giriş, and an
--     operator who may set a field but not correct it stops setting it.
--     P-04 is the destination on purpose — a bay with a future reservation is
--     a legal place for a person to put a car, exactly as it is at entry. Only
--     the AUTOMATIC path refuses those.
select b.id into v_bilet from public.biletler b
 where b.plaka = '39DOLU02' and b.durum = 'ACIK';
select id into v_yer  from public.park_yerleri where kod = 'P-02';
select id into v_id   from public.park_yerleri where kod = 'P-04';
if v_bilet is null or v_yer is null or v_id is null then
  raise exception 'FAIL 40a: kurulum — PASS 39 durumu yok';
end if;

perform public.bilet_yer_degistir(v_bilet, v_id);
if (select park_yeri_id from public.biletler where id = v_bilet) is distinct from v_id then
  raise exception 'FAIL 40a: araç taşınmadı';
end if;
-- The bay it came off is free the moment the row moves: occupancy is a view
-- over the open tickets, never a counter that has to be put back.
if exists (select 1 from public.biletler
            where park_yeri_id = v_yer and durum = 'ACIK') then
  raise exception 'FAIL 40a: eski yer boşalmadı';
end if;

-- ...and nothing else on the ticket moved with it. A move must never be able
-- to change what the car will be charged.
select b.giris_at into v_ts from public.biletler b where b.id = v_bilet;
if v_ts is null or (select durum from public.biletler where id = v_bilet) <> 'ACIK' then
  raise exception 'FAIL 40a: taşıma bileti bozdu';
end if;

-- (b) An occupied bay is refused — the same sentence Giriş gives, naming the
--     car that is already there.
select b.id into v_bilet2 from public.biletler b
 where b.plaka = '39DOLU03' and b.durum = 'ACIK';
begin
  perform public.bilet_yer_degistir(v_bilet2, v_id);
  raise exception 'FAIL 40b: dolu yere taşındı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%başka bir araç%' then
    raise exception 'FAIL 40b: beklenmeyen hata: %', sqlerrm;
  end if;
end;

-- (c) A retired bay is refused. Filling one would put a car somewhere the app
--     no longer draws.
begin
  perform public.bilet_yer_degistir(v_bilet2,
    (select id from public.park_yerleri where kod = 'X-38'));
  raise exception 'FAIL 40c: kullanım dışı yere taşındı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%kullanım dışı%' then
    raise exception 'FAIL 40c: beklenmeyen hata: %', sqlerrm;
  end if;
end;

begin
  perform public.bilet_yer_degistir(v_bilet2, gen_random_uuid());
  raise exception 'FAIL 40c: olmayan yere taşındı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%bulunamadı%' then
    raise exception 'FAIL 40c: beklenmeyen hata (olmayan yer): %', sqlerrm;
  end if;
end;

-- (d) Moving a car to the bay it is already on is a NO-OP, not an error: two
--     taps on the same tile and a retried request are the same event, and the
--     occupancy pre-check would otherwise report the car against itself.
-- audit_log is Yönetici-only, so both counts are read with the session
-- dropped; taken as Personel they would both be 0 and the check would pass
-- while proving nothing.
perform pg_temp.logout();
select count(*) into v_n from public.audit_log where action = 'bilet_yer_degistir';
perform pg_temp.login(u_personel);
perform public.bilet_yer_degistir(v_bilet, v_id);
if (select park_yeri_id from public.biletler where id = v_bilet) is distinct from v_id then
  raise exception 'FAIL 40d: aynı yere taşıma bileti bozdu';
end if;
perform pg_temp.logout();
select count(*) into v_n2 from public.audit_log where action = 'bilet_yer_degistir';
if v_n2 <> v_n then
  raise exception 'FAIL 40d: yapılmayan taşıma denetim kaydı yazdı';
end if;
-- (a) DID write one: moving a car is the one write that changes where the app
--     says a car is, and "it was on P-02 an hour ago" has to be answerable.
if v_n < 1 then
  raise exception 'FAIL 40d: taşıma denetime yazılmadı';
end if;

-- (e) A closed ticket cannot be moved. The immutability guard would refuse it
--     anyway; this answers with which of the two states the ticket is in.
--     Still logged out for the lookup: Personel see a closed ticket only while
--     the shift that closed it is open, and PASS 36 closed theirs.
select b.id into v_bilet2 from public.biletler b where b.durum = 'KAPALI' limit 1;
perform pg_temp.login(u_personel);
if v_bilet2 is null then raise exception 'FAIL 40e: kurulum — kapanmış bilet yok'; end if;
begin
  perform public.bilet_yer_degistir(v_bilet2, v_yer);
  raise exception 'FAIL 40e: kapanmış biletin yeri değiştirildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%kapanmış%' then
    raise exception 'FAIL 40e: beklenmeyen hata: %', sqlerrm;
  end if;
end;

-- (f) The bay a car left is immediately usable at the gate. This is the whole
--     point of occupancy being derived: nothing has to be released.
select public.bilet_ac('40YENI01', gen_random_uuid(), 'MOBIL', null, null, v_yer) into v_bilet2;
if v_bilet2 is null then raise exception 'FAIL 40f: boşalan yere giriş yapılamadı'; end if;

-- (g) Not staff, no move. A PENDING signup carries role NULL and must not be
--     able to reach a ticket through this door either.
perform pg_temp.login(u_pending);
begin
  perform public.bilet_yer_degistir(v_bilet, v_yer);
  raise exception 'FAIL 40g: PENDING kullanıcı araç taşıdı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yetkiniz yok%' then
    raise exception 'FAIL 40g: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

raise notice 'PASS 40: araç başka yere taşınıyor; dolu/pasif hedef ve kapanmış bilet reddediliyor';

-- =====================================================================
-- 41  İstemci rollerinin EXECUTE yüzeyi (012)
--     Bu, tek tek fonksiyon kontrollerinin YAKALAYAMADIĞI şeyi yakalar:
--     yeni eklenen ve revoke'u UNUTULAN bir fonksiyon. Supabase, public
--     şemasında oluşturulan her fonksiyona anon/authenticated/service_role
--     için DOĞRUDAN EXECUTE verir, ve `revoke ... from public` bunu
--     kaldırmaz — 009'un doğrulama bloğu bu yüzden canlıda patladı (012).
--
--     Karşılaştırma imza değil İSİM üzerinden yapılır: `timestamptz` mi
--     `timestamp with time zone` mı yazıldığı testi kırmamalı, ama yüzeye
--     giren yeni bir isim mutlaka görünmeli.
-- =====================================================================

-- (a) anon: giriş yapmamış ziyaretçi. Buradaki beşi bilerek açıktır —
--     giriş ekranı ve RLS politikalarının çağırdığı yardımcılar — artı
--     PUBLIC'e verilmiş iki trigger fonksiyonu, ki doğrudan çağrılınca
--     "trigger functions can only be called as triggers" diye reddederler.
select coalesce(array_agg(distinct p.proname order by p.proname), '{}'::text[])
  into v_liste
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f'
   and has_function_privilege('anon', p.oid, 'execute');

v_beklenen := array[
  'acik_vardiyam', 'bildirim_yonetici_turu', 'biletler_immutable_guard',
  'handle_new_user', 'is_staff', 'is_yonetici', 'normalize_plaka'];

if exists (select 1 from unnest(v_liste) x where x <> all(v_beklenen)) then
  raise exception 'FAIL 41a: anon fazladan fonksiyon çağırabiliyor: %',
    (select string_agg(x, ', ') from unnest(v_liste) x where x <> all(v_beklenen));
end if;
if exists (select 1 from unnest(v_beklenen) x where x <> all(v_liste)) then
  raise exception 'FAIL 41a: anon''un ihtiyacı olan yetki kapatılmış: %',
    (select string_agg(x, ', ') from unnest(v_beklenen) x where x <> all(v_liste));
end if;

-- (b) service_role: kamera webhook'u ve send-push. Kamera bilet AÇAR ve
--     054'ten beri plakası TAM tutan açık bileti olayın saatinde ÖDEMESİZ
--     kapatır — para toplayamaz, tahsilat yazamaz, tarifeye dokunamaz.
--     Bu yüzden kamera anahtarı, saati seçilmiş bir çıkışla ücreti düşürebilir
--     (gecikme sınırı kamera_gecikme_limiti_dk içinde): anahtar gizli kalmalı.
--     Bu listenin uzaması, kameranın yapabileceklerinin sessizce artması
--     demektir.
--
--     `kamera_okuma_bagla` (029) bu listeye BİLEREK eklendi ve sınırı
--     genişletmiyor: açık bir bilette yalnızca `plaka_okuma_id` ve
--     `plaka_supheli` kolonlarını yazar. İkisi de para değildir, ücreti
--     etkilemez, bileti kapatmaz ve kapanmış bir bilete hiç dokunmaz —
--     durum ACIK değilse false döner. Kameraya kendi açtığı bileti
--     "kontrol edilmeli" diye işaretlemekten başka bir yetki vermez, ve
--     is_staff() guard'ı taşıyamadığı için (webhook'ta auth.uid() null)
--     tek koruması zaten bu grant'tır.
select coalesce(array_agg(distinct p.proname order by p.proname), '{}'::text[])
  into v_liste
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f'
   and has_function_privilege('service_role', p.oid, 'execute');

--     `kamera_eslestir` ve `kamera_kalp_cihaz` (036) de BİLEREK eklendi.
--     İkisi de sınırı genişletmiyor:
--       · kamera_eslestir yalnızca GEÇERLİ, SÜRESİ DOLMAMIŞ ve HENÜZ
--         KULLANILMAMIŞ bir eşleştirme kodunu bir cihaz kimliğine çevirir.
--         Kodu üreten Yöneticidir; bu fonksiyon kendi başına kod üretemez,
--         dolayısıyla anahtarı ele geçiren biri yeni kamera tanımlayamaz.
--       · kamera_kalp_cihaz yalnızca zaman damgası yazar.
--     İkisi de `auth.uid()` null olduğu için `is_yonetici()` guard'ı
--     taşıyamaz — tek korumaları bu grant'tır, tıpkı kamera_okuma_bagla
--     gibi. Kodu ÜRETEN dört RPC (kamera_kod_uret, kamera_bekleyen_kodlar,
--     kamera_kod_iptal, kamera_cihaz_kaldir/durum) bu listede YOKTUR ve
--     olmamalıdır: onlar Yöneticinin, kameranın değil.
--
--     `kamera_tek_kapi` (037) de BİLEREK eklendi ve sınırı genişletmiyor:
--     kendi başına hiçbir şey yazmaz, yalnızca bu listede ZATEN bulunan iki
--     kapıdan birini seçer — bilet_ac ya da kamera_cikis_bildir — ya da
--     hiçbirini (yok sayar / çözülmemiş kayıt yazar). Kameranın yapabildiği
--     şeyler aynı kalır: bilet açmak ve çıkışı bildirmek. (054: çıkış, plakası
--     TAM tutan bileti ÖDEMESİZ kapatır — tahsil 0, tahsilat satırı yok; parayı
--     yine bir insan toplar, Onay onaylar. PASS 75.)
--
--     `kamera_okunamadi` ve `kamera_okuma_hatasi` (039) de BİLEREK eklendi:
--     ikisi de yalnızca "OKUNAMADI" türünde çözülmemiş kayıt ve Yönetici
--     uyarısı yazar. Bilet açmaz, kapatmaz, para görmez; kayıt ve uyarı da
--     zaten bu listedeki bilet_ac'ın istisna yolunun yazdığı türden şeyler.
--
--     `kamera_okuma_siniri` (040) de BİLEREK eklendi: yalnızca saatte en
--     fazla bir Yönetici uyarısı yazar ("Kamera okuma sınırı aşıldı"). Bilet
--     açmaz, kapatmaz, para görmez, hiçbir satırı değiştirmez; sayıları da
--     çağırandan almaz, kendisi okuma günlüğünden sayar.
--
--     `kamera_foto_bagla` (042) de BİLEREK eklendi: yalnızca bir fotoğraf
--     YOLU yazar, o da yalnızca bu olayın kendi yoluysa (`kamera/<islem_id>
--     .jpg`), yalnızca boşsa ve yalnızca bu olayın açtığı/vurduğu/yazdığı
--     yere (kamera bileti, "kapıda" damgası, kamera kaydı). Kapanmış bilete
--     dokunmaz — tek istisna (054): kameranın TAM bu olayın saatinde kapattığı
--     bilet, çıkış fotoğrafı boşsa. Para görmez, hiçbir şeyi silmez ya da
--     ezmez (PASS 64, 75).
--
--     `foto_temizlik_listesi` ve `foto_temizlik_hata` (043) de BİLEREK
--     eklendi; çağıran kamera değil, gece fotoğraf temizliği (Edge Function
--     foto-temizle). Sınırı genişletmiyorlar:
--       · foto_temizlik_listesi yalnızca OKUR: `plaka-foto` kovasında saklama
--         süresini (foto_saklama_gun) aşmış dosyaların ADLARINI verir, en
--         fazla 1000. Hiçbir şey yazmaz, silmez. Asıl silme Storage API'si
--         ile yapılır — SQL ile silmek dosyayı kovada yetim bırakıyordu.
--       · foto_temizlik_hata yalnızca günde en fazla bir Yönetici uyarısı
--         yazar ("Fotoğraf temizliği başarısız"). Para görmez, satır
--         değiştirmez (PASS 65).
v_beklenen := array[
  'bildirim_yonetici_turu', 'bilet_ac', 'biletler_immutable_guard',
  'foto_temizlik_hata', 'foto_temizlik_listesi',
  'handle_new_user', 'kamera_cikis_bildir', 'kamera_eslestir', 'kamera_foto_bagla',
  'kamera_kalp', 'kamera_kalp_bilgi', 'kamera_kalp_cihaz', 'kamera_okuma_bagla', 'kamera_okuma_hatasi',
  'kamera_okuma_siniri', 'kamera_okunamadi', 'kamera_reddedildi', 'kamera_tahmin_cikis',
  'kamera_tek_kapi',
  -- 084: ortak terminal. Üçü de terminal-giris / personel-olustur Edge
  -- Function'larından çağrılır; kendi içlerinde terminal anahtarını ya da
  -- çağıran Yöneticiyi yeniden doğrularlar (PASS 116-119).
  'personel_pin_olustur', 'terminal_personel_listesi', 'terminal_pin_dogrula'];
--     `kamera_tahmin_cikis` (077) de BİLEREK eklendi ve sınırı genişletmiyor:
--     kendisi hiçbir şey yazmaz, yalnızca bu listedeki kamera_cikis_bildir'i
--     çağırır — o da yalnızca plakası TAM tutan, benzeri olmayan açık bileti
--     ödemesiz kapatır (PASS 96). Ya da hiçbir şey yapmaz.

if exists (select 1 from unnest(v_liste) x where x <> all(v_beklenen)) then
  raise exception 'FAIL 41b: service_role fazladan fonksiyon çağırabiliyor: %',
    (select string_agg(x, ', ') from unnest(v_liste) x where x <> all(v_beklenen));
end if;
if exists (select 1 from unnest(v_beklenen) x where x <> all(v_liste)) then
  raise exception 'FAIL 41b: kameranın/push''un ihtiyacı olan yetki kapatılmış: %',
    (select string_agg(x, ', ') from unnest(v_beklenen) x where x <> all(v_liste));
end if;

-- (c) İçeriden çağrılan yardımcılar hiçbir istemci rolüne açık olmamalı.
--     Bunlar RLS'i bypass eden SECURITY DEFINER fonksiyonlarıdır:
--     yer_listesi bir bekleyen kullanıcıya park edilmiş araçların
--     PLAKALARINI verir, vardiya_yeniden_hesapla ise içeride hiç rol
--     kontrolü taşımaz — tek koruması bu yetkinin kapalı olmasıdır.
foreach v_txt in array array[
  'public.yer_mesgul(uuid)', 'public.yer_listesi()', 'public.bos_park_yeri()',
  'public.vardiya_yeniden_hesapla(uuid)', 'public.cop_yaz()',
  'public.tahsilat_durum_ata()', 'public.kamera_giris_bildirimi()',
  'public.kamera_cikis_bildirimi()',
  -- Rol kontrolü YOK ve olamaz: cron'da auth.uid() null'dır, guard her
  -- çalıştırmada patlardı. Açık kalsaydı personel kendi vardiyasını
  -- istediği anda "otomatik" kapattırabilirdi.
  'public.run_vardiya_kurtarma()',
  -- 030: aynı gerekçe. Açık kalsaydı personel günün vardiyasını istediği
  -- anda açtırıp açılış nakdini ayardaki tutara sabitleyebilirdi.
  'public.run_vardiya_otomatik_ac()',
  -- 029: şüphe kararını veren yardımcı. Rol kontrolü taşımaz çünkü onu
  -- çağıran iki fonksiyon zaten kendi yetkisini kontrol eder; doğrudan
  -- çağrılabilseydi herhangi bir personel istediği okuma kaydının güven
  -- değerini yoklayabilirdi. Tek koruması bu yetkinin kapalı olmasıdır.
  'public.okuma_supheli_mi(uuid, text)',
  -- 037: tek kapı kararının "bir karakter fark" yardımcısı. Zararsız bir
  -- metin karşılaştırması, ama kimsenin doğrudan çağırması için sebep yok.
  'public.plaka_yakin(text, text)',
  -- 043: gece fotoğraf temizliğini tetikleyen yardımcı. Gizli anahtarı
  -- okuyup Edge Function'a istek atar; açık kalsaydı istemci temizliği
  -- istediği an tetikleyebilir ya da uyarı ürettirebilirdi.
  'public.foto_temizlik_tetikle()',
  -- 045: herkese bildirim yazan yardımcı, gecikmeli bildirim işi ve kamera
  -- biletiyle okunamadı kaydını kapatan tetik. Açık kalsaydı istemci herkese
  -- bildirim yazdırabilir ya da bekleyen bildirimleri erken gönderttirebilirdi.
  'public.notify_herkes(public.bildirim_tur, text, text, text)',
  'public.istisna_bildirim_gonder()',
  'public.kamera_okunamadi_kapat()',
  -- 058: kameranın günlük özeti. Yalnızca gece işi çağırır; açık kalsaydı
  -- istemci Yönetici'ye istediği gün için özet yazdırabilirdi.
  'public.kamera_gunluk_sayim(date)',
  'public.kamera_gunluk_rapor(date)'
] loop
  if has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('authenticated', v_txt, 'execute')
     or has_function_privilege('service_role', v_txt, 'execute') then
    raise exception 'FAIL 41c: % istemciye açık', v_txt;
  end if;
end loop;

-- (d) Aynı tuzağın TABLO hâli, ve bu kez canlıda yakalandı: Supabase yeni
--     tabloya da anon/authenticated için varsayılan yetki verir. 003 bir
--     süpürme yapar ama yalnızca o an var olanlar için, yani sonradan eklenen
--     her tablo kendi revoke'unu taşımak zorundadır — 016 bunu unuttuğu için
--     kendi doğrulama bloğunda patladı. Bu kontrol, bir daha unutulursa
--     testin yakalamasını sağlar.
select coalesce(array_agg(distinct c.relname order by c.relname), '{}'::text[])
  into v_liste
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind in ('r', 'v')
   and (has_table_privilege('anon', c.oid, 'SELECT')
        or has_table_privilege('anon', c.oid, 'INSERT')
        or has_table_privilege('anon', c.oid, 'UPDATE')
        or has_table_privilege('anon', c.oid, 'DELETE'));
if array_length(v_liste, 1) is not null then
  raise exception 'FAIL 41d: anon şu tablolara erişebiliyor: %',
    array_to_string(v_liste, ', ');
end if;

raise notice 'PASS 41: anon ve service_role yalnızca kendilerine ayrılan fonksiyonları çağırabiliyor';

-- =====================================================================
-- 42  Sabit ücretli tarife (013)
--     Süre ne olursa olsun tek fiyat. Buradaki asıl soru "doğru sayıyı
--     döndürüyor mu" değil, SÜREDEN GERÇEKTEN BAĞIMSIZ mı: on dakika ile
--     üç gün aynı ücreti ödemiyorsa sabit tarife diye bir şey yok demektir.
-- =====================================================================

perform pg_temp.login(u_yonetici);
select public.tarife_guncelle(15, 0, 0, 0, 40000, 'SABIT', 5000) into v_id;

-- (a) Ücretsiz süre sabit tarifede de işler (Kural 3).
if public.ucret_hesapla(now() - interval '10 minutes', now(), v_id) <> 0 then
  raise exception 'FAIL 42a: ücretsiz süre içinde ücret alındı';
end if;

-- (b) Süreden bağımsızlık: üç ölçüm, tek fiyat.
if public.ucret_hesapla(now() - interval '16 minutes', now(), v_id) <> 5000
   or public.ucret_hesapla(now() - interval '10 hours', now(), v_id) <> 5000
   or public.ucret_hesapla(now() - interval '3 days', now(), v_id) <> 5000 then
  raise exception 'FAIL 42b: sabit tarife süreye göre değişiyor';
end if;

-- (c) Kullanılmayan saatlik alanlar sıfır yazılır — saklanan bir sayı,
--     ileride "acaba bu mu geçerliydi" sorusunu doğurur.
select ilk_saat_kurus + sonraki_saat_kurus + gunluk_tavan_kurus into v_ucret
  from public.tarifeler where id = v_id;
if v_ucret <> 0 then
  raise exception 'FAIL 42c: sabit tarifede saatlik alanlar sıfırlanmadı';
end if;

-- (d) Ücretsiz bir sabit tarife yazılamaz; sınır sunucuda.
begin
  perform public.tarife_guncelle(15, 0, 0, 0, 0, 'SABIT', 0);
  raise exception 'FAIL 42d: ücretsiz sabit tarife kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%sıfırdan büyük%' then
    raise exception 'FAIL 42d: beklenmeyen hata: %', sqlerrm;
  end if;
end;

-- (e) Sürümleme korunur: süreliye dönmek, sabit tarifeyle fiyatlanan bir
--     bileti yeniden fiyatlamaz — bilet kendi tarife_id'sini taşır.
perform public.tarife_guncelle(15, 6000, 3000, 25000, 40000, 'SURELI', 0);
if public.ucret_hesapla(now() - interval '10 hours', now(), v_id) <> 5000 then
  raise exception 'FAIL 42e: eski sabit tarife yeni sürümden etkilendi';
end if;
perform pg_temp.logout();

raise notice 'PASS 42: sabit tarife süreden bağımsız tek ücret alıyor, sürümleme korunuyor';

-- =====================================================================
-- 43  Düzenli kasa kaydı (014)
--     Bu özellik her ay KENDİ BAŞINA para yazar, dolayısıyla sınanacak şey
--     "çalışıyor mu" değil, İKİ KEZ YAZMIYOR mu.
-- =====================================================================

perform pg_temp.login(u_yonetici);
select public.kasa_tekrar_ekle('GIDER', 12345, 5::smallint, 'Kira', 'Aylık kira') into v_id;

-- (a) Bugünün kaydı yazıldı ve kurala bağlandı.
select count(*) into v_n from public.kasa_hareketleri
 where tekrar_kural_id = v_id
   and tarih = (now() at time zone 'Europe/Istanbul')::date;
if v_n <> 1 then raise exception 'FAIL 43a: ilk kayıt yazılmadı (%)', v_n; end if;

-- (b) Sıradaki çalışma KESİNLİKLE bugünden sonra: aynı gün kurulan bir kural
--     bugünü ikinci kez yazarsa gider iki katına çıkar.
select next_run into v_ts from public.kasa_tekrar_kurallari where id = v_id;
if v_ts::date <= (now() at time zone 'Europe/Istanbul')::date then
  raise exception 'FAIL 43b: next_run bugün ya da öncesi (%)', v_ts;
end if;

-- (c) Gece işi vadesi geleni yazar — ve ikinci kez koşunca yazmaz.
--     Fonksiyon istemciye kapalı olduğu için oturum kapatılarak çağrılır.
perform pg_temp.logout();
update public.kasa_tekrar_kurallari
   set next_run = (now() at time zone 'Europe/Istanbul')::date
 where id = v_id;
perform public.kasa_tekrar_uygula();
perform public.kasa_tekrar_uygula();
select count(*) into v_n from public.kasa_hareketleri where tekrar_kural_id = v_id;
if v_n <> 1 then
  raise exception 'FAIL 43c: tekrar aynı güne % satır yazdı', v_n;
end if;

-- (d) Durdurulan kural bir daha yazmaz.
update public.kasa_tekrar_kurallari
   set is_active = false, next_run = (now() at time zone 'Europe/Istanbul')::date
 where id = v_id;
perform public.kasa_tekrar_uygula();
select count(*) into v_n2 from public.kasa_hareketleri where tekrar_kural_id = v_id;
if v_n2 <> v_n then raise exception 'FAIL 43d: durdurulmuş kural yazmaya devam etti'; end if;

-- (e) Personel bu kuralları ne görebilir ne kurabilir.
perform pg_temp.login(u_personel);
select count(*) into v_n from public.kasa_tekrar_kurallari;
if v_n <> 0 then raise exception 'FAIL 43e: personel düzenli kayıtları görüyor'; end if;
begin
  perform public.kasa_tekrar_ekle('GIDER', 500, 5::smallint, null, 'Deneme');
  raise exception 'FAIL 43e: personel düzenli kayıt kurdu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yalnızca Yönetici%' then
    raise exception 'FAIL 43e: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

raise notice 'PASS 43: düzenli kasa kaydı ayda bir kez yazıyor, tekrar koşusu çift kayıt üretmiyor';

-- =====================================================================
-- 44  Rapor RPC'leri personele kapalı + yöntem dağılımı (015)
--     Rapor fonksiyonları SECURITY DEFINER'dır, yani RLS devre dışıdır ve
--     TEK sınır içerideki rol kontrolüdür. O kontrol düşerse Personel bütün
--     ciroyu okur — "personelin görmemesi gereken yer" tanımının ta kendisi.
-- =====================================================================

perform pg_temp.login(u_yonetici);
insert into public.kasa_hareketleri (tur, tutar_kurus, aciklama, yontem, tarih)
values ('GIDER', 7000, '44 test gideri', 'NAKIT',
        (now() at time zone 'Europe/Istanbul')::date);

select gider_kurus into v_ucret from public.yontem_ozet(
  (now() at time zone 'Europe/Istanbul')::date,
  (now() at time zone 'Europe/Istanbul')::date) where yontem = 'NAKIT';
if coalesce(v_ucret, 0) < 7000 then
  raise exception 'FAIL 44a: nakit gideri dağılımda görünmüyor (%)', coalesce(v_ucret, 0);
end if;

-- Yöntemsiz satır hiçbir kovaya girmemeli (015, 2. not).
insert into public.kasa_hareketleri (tur, tutar_kurus, aciklama, tarih)
values ('GIDER', 5000, '44 yöntemsiz', (now() at time zone 'Europe/Istanbul')::date);
select coalesce(sum(gider_kurus), 0) into v_ucret2 from public.yontem_ozet(
  (now() at time zone 'Europe/Istanbul')::date,
  (now() at time zone 'Europe/Istanbul')::date);
if v_ucret2 <> v_ucret then
  raise exception 'FAIL 44b: yöntemsiz satır bir kovaya yazıldı';
end if;

perform pg_temp.login(u_personel);
begin
  perform public.yontem_ozet(current_date, current_date);
  raise exception 'FAIL 44c: personel yöntem dağılımını okudu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yetkiniz yok%' then
    raise exception 'FAIL 44c: beklenmeyen hata: %', sqlerrm;
  end if;
end;
begin
  perform public.rapor_ozet(current_date, current_date);
  raise exception 'FAIL 44c: personel rapor özetini okudu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yetkiniz yok%' then
    raise exception 'FAIL 44c: beklenmeyen hata (rapor_ozet): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

raise notice 'PASS 44: rapor RPC''leri personele kapalı, yöntem dağılımı doğru kovalıyor';

-- =====================================================================
-- 45  Personel ödemeleri (016)
--     Asıl sınanan, PilotGarage'ın aylarca canlıda taşıdığı hatadır: ekran
--     "avans maaştan düşülecek" der ama ödeme tam maaşı kasadan çıkarır,
--     yani avans iki kez ödenir. Buradaki her iddia o senaryonun etrafında.
-- =====================================================================

perform pg_temp.login(u_yonetici);
select id into v_id from public.profiles where id = u_personel;
perform public.maas_guncelle(v_id, 3000000);              -- 30.000 TL

-- (a) Borçsuz maaş: tam tutar kasadan çıkar.
select coalesce(sum(tutar_kurus), 0) into v_ucret
  from public.kasa_hareketleri where kategori = 'Personel';
perform public.maas_ode(v_id, 'NAKIT');
select coalesce(sum(tutar_kurus), 0) into v_ucret2
  from public.kasa_hareketleri where kategori = 'Personel';
if v_ucret2 - v_ucret <> 3000000 then
  raise exception 'FAIL 45a: borçsuz maaş % çıktı', v_ucret2 - v_ucret;
end if;

-- (b) Avans borç yaratır ve maaş ONU DÜŞEREK öder. 30.000 maaş, 15.000 avans
--     → kasadan 15.000 çıkmalı. Hata hâlinde 30.000 çıkar ve avans iki kez
--     ödenmiş olur.
perform public.avans_ver(v_id, 1500000, 'NAKIT');
select borc_kurus into v_n from public.personel_ozet(v_id);
if v_n <> 1500000 then raise exception 'FAIL 45b: borç % (1500000 bekleniyor)', v_n; end if;

select coalesce(sum(tutar_kurus), 0) into v_ucret
  from public.kasa_hareketleri where kategori = 'Personel';
perform public.maas_ode(v_id, 'NAKIT');
select coalesce(sum(tutar_kurus), 0) into v_ucret2
  from public.kasa_hareketleri where kategori = 'Personel';
if v_ucret2 - v_ucret <> 1500000 then
  raise exception 'FAIL 45b: avanslı maaş % çıktı (1500000 bekleniyor)', v_ucret2 - v_ucret;
end if;
select borc_kurus into v_n from public.personel_ozet(v_id);
if v_n <> 0 then raise exception 'FAIL 45b: borç kapanmadı (%)', v_n; end if;

-- (c) Maaştan büyük avans: kasadan para ÇIKMAZ ama görünür bir ₺0 satır
--     yazılır, kalan borç devreder. Toplamın değişmediğine bakmak yetmez —
--     sıfır eklemek toplamı zaten oynatmaz, yani o kontrol satır hiç
--     yazılmasa da geçerdi. Satırın kendisi sorulur.
perform public.avans_ver(v_id, 4000000, 'NAKIT');          -- 40.000 > 30.000
select coalesce(sum(tutar_kurus), 0) into v_ucret
  from public.kasa_hareketleri where kategori = 'Personel';
perform public.maas_ode(v_id, 'NAKIT');
select coalesce(sum(tutar_kurus), 0) into v_ucret2
  from public.kasa_hareketleri where kategori = 'Personel';
if v_ucret2 <> v_ucret then
  raise exception 'FAIL 45c: net sıfır maaş kasadan para çıkardı (%)', v_ucret2 - v_ucret;
end if;
if not exists (select 1 from public.kasa_hareketleri
                where personel_id = v_id and tutar_kurus = 0) then
  raise exception 'FAIL 45c: sıfır tutarlı maaş satırı kasada görünmüyor';
end if;
select borc_kurus into v_n from public.personel_ozet(v_id);
if v_n <> 1000000 then raise exception 'FAIL 45c: devreden borç % (1000000)', v_n; end if;

-- (d) Prim borca sayılmaz — maaşın üstüne verilir, ondan düşülmez.
select borc_kurus into v_n from public.personel_ozet(v_id);
perform public.prim_ver(v_id, 500000, 'NAKIT');
select borc_kurus into v_n2 from public.personel_ozet(v_id);
if v_n2 <> v_n then raise exception 'FAIL 45d: prim borcu değiştirdi'; end if;

-- (f) Gece işi: ödeme günü bugünse öder, aynı ay ikinci kez ÖDEMEZ. Elle
--     ödenmiş bir maaşın üstüne otomatik ikinci maaş yazmak, bu özelliğin
--     tek gerçek tehlikesi.
--
--     Ödeme günü 1–28 ile sınırlı (her ayda o gün olsun diye) ve gece işi
--     yalnızca `odeme_gunu = bugünün günü` olanlara öder (016). Ayın 29–31'inde
--     "ödeme günü bugün" hiç kurulamaz — eskiden bu adım o üç günde
--     "Ödeme günü 1 ile 28 arasında olmalı" ile patlıyordu (2026-10-31).
--     O günlerde bunun yerine o günlerin gerçek kuralı sınanır: kimseye
--     ödenmez. "Vadesi geleni öder" yarısı ayın 1–28'inde sınanır.
if extract(day from (now() at time zone 'Europe/Istanbul')) <= 28 then
  perform public.maas_guncelle(v_id, 3000000,
    extract(day from (now() at time zone 'Europe/Istanbul'))::smallint, 'NAKIT');
  -- Sayım cron'dan ÖNCE alınır: sonra alınsaydı ilk koşunun fazladan maaş
  -- yazıp yazmadığı ölçülemezdi, ki asıl tehlike odur.
  select count(*) into v_n from public.personel_odemeler
   where profile_id = v_id and tur = 'MAAS';
  perform pg_temp.logout();
  -- Bu ay (a)/(b)/(c)'de zaten elle ödendi; gece işi üstüne yazmamalı.
  perform public.maas_otomatik();
  perform public.maas_otomatik();
  select count(*) into v_n2 from public.personel_odemeler
   where profile_id = v_id and tur = 'MAAS';
  if v_n2 <> v_n then
    raise exception 'FAIL 45f: gece işi aynı ay % fazladan maaş yazdı', v_n2 - v_n;
  end if;

  -- Ödenmemiş bir ay ise ÖDEMELİ: yalnızca "yazmıyor" demek, hiç çalışmayan
  -- bir cron'la aynı sonucu verirdi.
  delete from public.personel_odemeler where profile_id = v_id and tur = 'MAAS';
  perform public.maas_otomatik();
  if not exists (select 1 from public.personel_odemeler
                  where profile_id = v_id and tur = 'MAAS') then
    raise exception 'FAIL 45f: gece işi vadesi gelen maaşı ödemedi';
  end if;
else
  -- Ayın 29–31'i: en geç ödeme günü (28) kurulu, bu ay ödenmemiş, yine de
  -- gece işi ödememeli.
  perform public.maas_guncelle(v_id, 3000000, 28::smallint, 'NAKIT');
  perform pg_temp.logout();
  delete from public.personel_odemeler where profile_id = v_id and tur = 'MAAS';
  perform public.maas_otomatik();
  if exists (select 1 from public.personel_odemeler
              where profile_id = v_id and tur = 'MAAS') then
    raise exception 'FAIL 45f: gece işi ayın 29–31''inde maaş ödedi';
  end if;
  raise notice '     (45f: bugün ayın %''i — ödeme günü 28 ile sınırlı; "vadesi geleni öder" kısmı ayın 1–28''inde sınanır)',
    extract(day from (now() at time zone 'Europe/Istanbul'));
end if;

-- Ödeme günü boşaltılabilmeli: kurulan otomatik ödeme kapatılamıyorsa,
-- kapatmanın tek yolu maaşı sıfırlamak olurdu.
perform pg_temp.login(u_yonetici);
perform public.maas_guncelle(v_id, 3000000, null, null);
-- `profiles.odeme_gunu` doğrudan OKUNAMAZ: 018 maaş kolonlarının SELECT yetkisini
-- istemciden aldı (PASS 47). Yönetici'nin gerçek yolu RPC'dir, test de onu
-- kullanır — tabloyu okumaya çalışmak 42501 verirdi.
if (select o.odeme_gunu from public.personel_ozet(v_id) o) is not null then
  raise exception 'FAIL 45f: otomatik ödeme kapatılamadı';
end if;

-- (e) Personel ne ödeme defterini okuyabilir ne ödeme yapabilir. Ücretinin
--     ve borcunun kimseye görünmemesi, bu ekranın bütün varlık sebebi.
perform pg_temp.login(u_personel);
select count(*) into v_n from public.personel_odemeler;
if v_n <> 0 then raise exception 'FAIL 45e: personel ödeme defterini görüyor'; end if;
begin
  perform public.avans_ver(u_personel, 100, 'NAKIT');
  raise exception 'FAIL 45e: personel kendine avans verdi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yalnızca Yönetici%' then
    raise exception 'FAIL 45e: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

raise notice 'PASS 45: maaş avans borcunu düşerek ödeniyor, kalan borç devrediyor, prim düşülmüyor';

-- =====================================================================
-- 46. TAHSİLAT ONAYI
--     Barierde toplanan para deftere ancak Yönetici kabul edince girer.
--     Ölçümler MUTLAK değil FARK üzerinden yapılır: bu dosya aynı gün
--     içinde başka tahsilatlar da üretiyor, mutlak bir ciro beklentisi
--     testin kendisine bağımlı olurdu.
-- =====================================================================
v_gun := (now() at time zone 'Europe/Istanbul')::date;
perform pg_temp.login(u_yonetici);

-- Vardiya, (g) adımı için: tahsilat satırı vardiya_id'sini kapanış anında
-- açık vardiyadan alır, dolayısıyla bilet kapanmadan ÖNCE açık olmalı.
if public.acik_vardiyam() is null then
  perform public.vardiya_ac(0);
end if;

-- (a) Kapanan biletin tahsilatı BEKLIYOR doğar ve ciroyu OYNATMAZ.
select ciro_kurus into v_bigint from public.rapor_ozet(v_gun, v_gun);
-- Backdated as the migration role, NOT opened with p_kaynak = 'KAMERA':
-- bilet_ac refuses a camera source from any caller carrying a JWT (006), so
-- the camera trick only works with no session at all. The stay has to be
-- three hours old for the fee to be non-zero, and this is the same setup
-- PASS 36 uses.
select public.bilet_ac('34ONAY01', gen_random_uuid()) into v_bilet;
perform pg_temp.logout();
update public.biletler set giris_at = now() - interval '3 hours' where id = v_bilet;
perform pg_temp.login(u_yonetici);
select b.tahsil_kurus into v_ucret
  from public.bilet_kapat(v_bilet, 'NAKIT', null, null, null, 'MOBIL') b;
if v_ucret <= 0 then
  raise exception 'FAIL 46a: ücretsiz bilet — onay testi ölçtüğünü ölçemez';
end if;

select id into v_id from public.tahsilatlar
 where bilet_id = v_bilet and iptal_of is null;
if (select durum from public.tahsilatlar where id = v_id) <> 'BEKLIYOR' then
  raise exception 'FAIL 46a: tahsilat BEKLIYOR doğmadı';
end if;
if (select ciro_kurus from public.rapor_ozet(v_gun, v_gun)) <> v_bigint then
  raise exception 'FAIL 46a: onaysız tahsilat ciroya girdi';
end if;

-- (g) Vardiya sayımı durumu UMURSAMAZ: para çekmecede, onaylansın ya da
--     onaylanmasın. Bu filtrenin Finans'a benzetilmesi, onaylanmamış her
--     vardiyada sahte bir kasa farkı üretirdi.
select toplam_kurus into v_bigint2 from public.vardiya_ozetim();
if v_bigint2 < v_ucret then
  raise exception 'FAIL 46g: bekleyen tahsilat vardiya özetinden düştü';
end if;

-- (b) Personel karar veremez. Asıl sınır burada, ekranı gizlemekte değil.
perform pg_temp.login(u_personel);
begin
  perform public.tahsilat_onayla(array[v_id]);
  raise exception 'FAIL 46b: personel tahsilat onayladı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yalnızca Yönetici%' then
    raise exception 'FAIL 46b: beklenmeyen hata: %', sqlerrm;
  end if;
end;
begin
  perform public.tahsilat_reddet(array[v_id], 'olmaz');
  raise exception 'FAIL 46b: personel tahsilat reddetti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yalnızca Yönetici%' then
    raise exception 'FAIL 46b: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.login(u_yonetici);

-- (c) Onaydan sonra ciro tam da o kadar artar. İkinci onay hata değil,
--     SESSİZ ATLAMADIR: dönen sayı 0'dır ve ciro kıpırdamaz — toplu onayda
--     tek bayat satırın bütün partiyi düşürmemesi için böyle.
if public.tahsilat_onayla(array[v_id]) <> 1 then
  raise exception 'FAIL 46c: onay 1 satır bildirmedi';
end if;
if (select ciro_kurus from public.rapor_ozet(v_gun, v_gun)) <> v_bigint + v_ucret then
  raise exception 'FAIL 46c: onaylanan tahsilat ciroya yansımadı';
end if;
if public.tahsilat_onayla(array[v_id]) <> 0 then
  raise exception 'FAIL 46c: karara bağlanmış tahsilat yeniden onaylandı';
end if;
if (select ciro_kurus from public.rapor_ozet(v_gun, v_gun)) <> v_bigint + v_ucret then
  raise exception 'FAIL 46c: ikinci onay ciroyu iki kez saydı';
end if;

-- (d) Reddedilen tahsilat ciroya hiç girmez, sebebi kayıtta durur.
select public.bilet_ac('34ONAY02', gen_random_uuid()) into v_bilet2;
perform pg_temp.logout();
update public.biletler set giris_at = now() - interval '3 hours' where id = v_bilet2;
perform pg_temp.login(u_yonetici);
perform public.bilet_kapat(v_bilet2, 'NAKIT', null, null, null, 'MOBIL');
select id into v_id2 from public.tahsilatlar
 where bilet_id = v_bilet2 and iptal_of is null;
if public.tahsilat_reddet(array[v_id2], 'Kasada karşılığı yok') <> 1 then
  raise exception 'FAIL 46d: ret 1 satır bildirmedi';
end if;
if (select ciro_kurus from public.rapor_ozet(v_gun, v_gun)) <> v_bigint + v_ucret then
  raise exception 'FAIL 46d: reddedilen tahsilat ciroyu oynattı';
end if;
select onay_notu into v_txt from public.tahsilatlar where id = v_id2;
if v_txt <> 'Kasada karşılığı yok' then
  raise exception 'FAIL 46d: ret sebebi kaydedilmedi';
end if;

-- (e) ONAYLANDI bir tahsilatın iptali ters kaydı ONAYLANDI doğurur: iptal
--     edilmiş bilet, ters kayıt onaylanana kadar ciro kazanmaya DEVAM
--     EDEMEZ.
perform public.bilet_iptal(v_bilet, 'Test iptali');
if (select durum from public.tahsilatlar where iptal_of = v_id) <> 'ONAYLANDI' then
  raise exception 'FAIL 46e: onaylı tahsilatın ters kaydı onaylı doğmadı';
end if;
if (select ciro_kurus from public.rapor_ozet(v_gun, v_gun)) <> v_bigint then
  raise exception 'FAIL 46e: iptalden sonra ciro başa dönmedi';
end if;

-- (f) BEKLIYOR bir tahsilatın iptali İKİ satırı da REDDEDILDI yapar. Aksi
--     hâlde net sıfır bir çift kuyrukta sonsuza dek karar beklerdi ve
--     yalnızca biri onaylanırsa defter şişerdi.
select adet into v_n from public.onay_ozet();
select public.bilet_ac('34ONAY03', gen_random_uuid()) into v_bilet2;
perform pg_temp.logout();
update public.biletler set giris_at = now() - interval '3 hours' where id = v_bilet2;
perform pg_temp.login(u_yonetici);
perform public.bilet_kapat(v_bilet2, 'NAKIT', null, null, null, 'MOBIL');
select id into v_id2 from public.tahsilatlar
 where bilet_id = v_bilet2 and iptal_of is null;
perform public.bilet_iptal(v_bilet2, 'Test iptali 2');
if (select durum from public.tahsilatlar where id = v_id2) <> 'REDDEDILDI'
   or (select durum from public.tahsilatlar where iptal_of = v_id2) <> 'REDDEDILDI' then
  raise exception 'FAIL 46f: onaysız tahsilatın iptali kuyrukta kaldı';
end if;
select adet into v_n2 from public.onay_ozet();
if v_n2 <> v_n then
  raise exception 'FAIL 46f: iptal edilmiş çift onay kuyruğunu şişirdi';
end if;

-- (h) rapor_gunluk'te süzgeç ON'da durur, WHERE'de değil: WHERE olsaydı
--     onaysız günler grafikten komple düşerdi.
select count(*) into v_n from public.rapor_gunluk(v_gun - 30, v_gun);
if v_n <> 31 then
  raise exception 'FAIL 46h: rapor_gunluk 31 gün yerine % gün döndü', v_n;
end if;

-- (i) Personel onay listesini hiç göremez.
perform pg_temp.login(u_personel);
begin
  perform * from public.onay_listesi('BEKLIYOR');
  raise exception 'FAIL 46i: personel onay listesini okudu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yetkiniz yok%' then
    raise exception 'FAIL 46i: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (j) Çöpten geri alınan 017 ÖNCESİ satırda `durum` anahtarı yoktur:
--     jsonb_populate_record NULL yazar ve açık NULL kolon varsayılanına
--     DÜŞMEZ. Tetikleyicideki coalesce olmasaydı cop_geri_al her eski
--     kayıtta not-null hatası verirdi.
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, durum)
values ('BILET', null, 1234, 'NAKIT', null) returning id into v_id2;
if (select durum from public.tahsilatlar where id = v_id2) <> 'ONAYLANDI' then
  raise exception 'FAIL 46j: geri alınan eski tahsilat onaylı doğmadı';
end if;

raise notice 'PASS 46: tahsilat onayı — ciro yalnızca onaylananı sayar, vardiya sayımı hepsini';

-- =====================================================================
-- 47. MAAŞ KOLONLARI İSTEMCİYE KAPALI
--     profiles_select her aktif personelin birbirinin SATIRINI görmesine
--     izin verir (bilet kimin açtığını yazabilsin diye) ve RLS'in kolon
--     boyutu yoktur — maaş 016'da bu tabloya eklendiği için tek koruma
--     kolon bazlı grant'tir. Bu dosya superuser olarak koştuğu için grant
--     ÇALIŞMAZ, dolayısıyla iddia doğrudan yetki katalogundan okunur.
-- =====================================================================
if has_column_privilege('authenticated', 'public.profiles', 'maas_kurus', 'SELECT')
   or has_column_privilege('authenticated', 'public.profiles', 'odeme_gunu', 'SELECT')
   or has_column_privilege('authenticated', 'public.profiles', 'maas_yontemi', 'SELECT') then
  raise exception 'FAIL 47a: personel herkesin maaşını okuyabiliyor';
end if;

-- Kimlik kolonları açık kalmalı: kapansaydı uygulama açılışta kendi rolünü
-- okuyamaz ve hiçbir ekran çizilmezdi.
if not has_column_privilege('authenticated', 'public.profiles', 'ad_soyad', 'SELECT')
   or not has_column_privilege('authenticated', 'public.profiles', 'rol', 'SELECT')
   or not has_column_privilege('authenticated', 'public.profiles', 'durum', 'SELECT') then
  raise exception 'FAIL 47b: kimlik kolonları da kapanmış';
end if;

-- Yönetici maaşı yalnızca RPC üzerinden okur.
perform pg_temp.login(u_yonetici);
select count(*) into v_n from public.personel_listesi();
if v_n = 0 then raise exception 'FAIL 47c: personel listesi boş döndü'; end if;

perform pg_temp.login(u_personel);
begin
  perform * from public.personel_listesi();
  raise exception 'FAIL 47d: personel maaş listesini okudu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yetkiniz yok%' then
    raise exception 'FAIL 47d: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

raise notice 'PASS 47: maaş kolonları istemciye kapalı, liste yalnızca Yöneticiye açık';

-- ---------------------------------------------------------------------------
-- 48. Fotoğraf saklama süresi 1-30 gün (024)
--
-- Ekrandaki doğrulama yalnızca UI'dır; asıl sınır CHECK'tir. 0 ("hiç silme")
-- bilerek reddedilir: plaka kişisel veridir ve sınırsız saklama hem kotayı
-- hem KVKK'yı zorlar.
-- ---------------------------------------------------------------------------
begin
  update public.otopark_ayarlari set foto_saklama_gun = 0 where id = 1;
  raise exception 'FAIL 48a: saklama süresi 0 kabul edildi';
exception when check_violation then null;
end;

begin
  update public.otopark_ayarlari set foto_saklama_gun = 31 where id = 1;
  raise exception 'FAIL 48b: saklama süresi 31 kabul edildi';
exception when check_violation then null;
end;

update public.otopark_ayarlari set foto_saklama_gun = 30 where id = 1;
if (select foto_saklama_gun from public.otopark_ayarlari where id = 1) <> 30 then
  raise exception 'FAIL 48c: aralık içindeki değer yazılamadı';
end if;

raise notice 'PASS 48: fotoğraf saklama süresi 1-30 gün ile sınırlı';

-- ---------------------------------------------------------------------------
-- 49. Kendini toparlama (025)
--
-- Açık kalan vardiya, sahibi kapatamadığı için o kişiyi kalıcı olarak
-- kilitliyordu (`vardiya_ac` ikinci açık vardiyayı reddeder). İki çıkış yolu
-- var ve ikisi de burada sınanır: gece değil 15 dakikada bir koşan kurtarma
-- işi, ve Yönetici'nin elle kapatması.
-- ---------------------------------------------------------------------------
-- Temiz başlangıç: açık bir vardiya varsa tekil indeks aşağıdaki insert'i
-- reddeder.
--
-- 030'dan beri KİŞİ değil KASA başına tek vardiya var, dolayısıyla yalnızca
-- u_personel2'nin satırını kapatmak yetmez: bu noktada PASS 46'nın kurulumu
-- u_yonetici adına bir vardiya açmış ve kapatmamış oluyor, ve o satır insert'i
-- reddettiriyordu. "Temiz başlangıç" artık açık olan HER vardiyayı kapatmak
-- demektir — modelin kendisi kişiyi umursamadığına göre fixture da
-- umursamamalı.
update public.vardiyalar
   set kapanis_at = now(), kapanis_kaynak = 'ELLE'
 where kapanis_at is null;

update public.otopark_ayarlari set vardiya_esik_saat = 16 where id = 1;

insert into public.vardiyalar (personel_id, acilis_at, acilis_nakit_kurus)
values (u_personel2, now() - interval '30 hours', 5000)
returning id into v_vardiya;

-- (a) Personel başkasının vardiyasını kapatamaz.
perform pg_temp.login(u_personel);
begin
  perform * from public.vardiya_zorla_kapat(v_vardiya, null, null);
  raise exception 'FAIL 49a: Personel başkasının vardiyasını kapattı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yalnızca Yönetici%' then
    raise exception 'FAIL 49a: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (b) Kurtarma işi eşiği aşan vardiyayı kapatır — SAYMADAN.
perform public.run_vardiya_kurtarma();

if not exists (select 1 from public.vardiyalar
                where id = v_vardiya
                  and kapanis_at is not null
                  and kapanis_kaynak = 'OTOMATIK'
                  and sayilan_nakit_kurus is null
                  and fark_kurus is null) then
  raise exception 'FAIL 49b: açık kalan vardiya otomatik kapatılmadı ya da sayım uyduruldu';
end if;

-- Beklenen YAZILIR: açılış nakdi + o vardiyanın nakit tahsilatı (burada yok).
if (select beklenen_nakit_kurus from public.vardiyalar where id = v_vardiya) <> 5000 then
  raise exception 'FAIL 49c: otomatik kapanışta beklenen nakit yanlış';
end if;

select count(*) into v_n from public.notifications
 where tur = 'VARDIYA_ACIK' and profile_id = u_yonetici;
if v_n = 0 then
  raise exception 'FAIL 49d: otomatik kapanış Yöneticiye bildirilmedi';
end if;

-- (e) Otomatik kapanan bir vardiyaya sonradan sayım yazılamaz. Bu kısıt
--     olmasaydı "sayılan = beklenen" yazan bir yol farkı sonsuza dek sıfır
--     gösterir ve eksik kasa görünmez olurdu.
begin
  update public.vardiyalar set sayilan_nakit_kurus = 5000 where id = v_vardiya;
  raise exception 'FAIL 49e: otomatik kapanışa sayım yazılabildi';
exception when check_violation then null;
end;

v_eski_vardiya := v_vardiya;   -- (h) otomatik kapanan satıra geri dönecek

-- (f) Yönetici elle kapatır ve sayım verirse fark normal kapanış gibi çıkar.
insert into public.vardiyalar (personel_id, acilis_at, acilis_nakit_kurus)
values (u_personel2, now() - interval '2 hours', 5000)
returning id into v_vardiya;

perform pg_temp.login(u_yonetici);
perform * from public.vardiya_zorla_kapat(v_vardiya, 7000, 'sayıldı');
perform pg_temp.logout();

if not exists (select 1 from public.vardiyalar
                where id = v_vardiya and kapanis_kaynak = 'YONETICI'
                  and sayilan_nakit_kurus = 7000 and fark_kurus = 2000) then
  raise exception 'FAIL 49f: Yönetici kapanışında fark yanlış';
end if;

-- (g) Kurtarma işi istemciye kapalı olmalı: açık olsaydı personel kendi
--     vardiyasını istediği anda "otomatik" kapattırabilirdi.
if has_function_privilege('authenticated', 'public.run_vardiya_kurtarma()', 'execute')
   or has_function_privilege('anon', 'public.run_vardiya_kurtarma()', 'execute') then
  raise exception 'FAIL 49g: kurtarma işi istemciye açık';
end if;

-- (h) Yeniden hesap NULL sayımı 0 sanmamalı. 007'nin eski hâli otomatik
--     kapanmış bir vardiyada `0 - beklenen` diye uydurma bir fark yazar,
--     kısıt da bunu reddeder — yani o vardiyanın bileti hiç silinemezdi.
-- Beklenen bilerek YANLIŞ yazılıyor: yeniden hesap ancak bir şey değiştiğinde
-- yazar, aynı değerlerle çağrılsa hiç yazmaz ve test boşa geçerdi.
update public.vardiyalar
   set beklenen_nakit_kurus = 999
 where id = v_eski_vardiya;
perform public.vardiya_yeniden_hesapla(v_eski_vardiya);
if (select fark_kurus from public.vardiyalar where id = v_eski_vardiya) is not null then
  raise exception 'FAIL 49h: sayılmamış vardiyaya yeniden hesapla fark uydurdu';
end if;
if (select beklenen_nakit_kurus from public.vardiyalar where id = v_eski_vardiya) <> 5000 then
  raise exception 'FAIL 49h: yeniden hesap beklenen nakdi düzeltmedi';
end if;

raise notice 'PASS 49: açık kalan vardiya kurtarılıyor, uydurma sayım engelleniyor';

-- ---------------------------------------------------------------------------
-- 50. Her ödemenin bir yöntemi var (026)
--
-- Elle yapılan ödemelerde seçici artık Nakit ile açılıyor, ama OTOMATİK
-- yollar kimseye soramaz: yöntemi tanımdan okurlar. Tanımda NULL kalırsa
-- kasa toplamını oynatan ama hiçbir kovaya girmeyen bir satır doğar.
-- ---------------------------------------------------------------------------
perform pg_temp.login(u_yonetici);

-- Maaş kolonları 018'den beri `authenticated`'a KAPALI (kolon bazlı grant),
-- yani buradan `profiles`'e doğrudan bakılamaz — Yönetici bile bakamaz, ve
-- bakabilmesi de istenmez. Okuma, ekranın kullandığı yoldan yapılır.
-- (a) Gün varsa yöntem yazılmasa da Nakit'e düşer.
perform public.maas_guncelle(u_personel2, 500000, 5::smallint, null);
select o.maas_yontemi::text into v_txt from public.personel_ozet(u_personel2) o;
if v_txt is distinct from 'NAKIT' then
  raise exception 'FAIL 50a: otomatik maaş yöntemsiz kaldı';
end if;

-- (b) 016'nın kaçış yolu duruyor: gün temizlenirken yöntem de temizlenebilir.
--     Bu olmasaydı bir kez kurulan otomatik ödeme bir daha kapatılamazdı.
perform public.maas_guncelle(u_personel2, 500000, null, null);
select o.maas_yontemi::text, o.odeme_gunu into v_txt, v_n
  from public.personel_ozet(u_personel2) o;
if v_n is not null or v_txt is not null then
  raise exception 'FAIL 50b: otomatik ödeme kapatılamadı';
end if;

-- (c) Düzenli kasa kuralı da yöntemsiz kurulamaz; ilk kayda da kopyalanır.
select public.kasa_tekrar_ekle('GIDER'::public.kasa_tur, 25000, 7::smallint,
                               'test', 'yöntemsiz kural', null, true) into v_id;
if (select yontem from public.kasa_tekrar_kurallari where id = v_id)
     is distinct from 'NAKIT' then
  raise exception 'FAIL 50c: düzenli kayıt kuralı yöntemsiz kuruldu';
end if;
if (select yontem from public.kasa_hareketleri where tekrar_kural_id = v_id)
     is distinct from 'NAKIT' then
  raise exception 'FAIL 50c: kuralın ilk kaydı yöntemsiz yazıldı';
end if;
perform pg_temp.logout();

-- (d) Asıl sınır kısıttır, RPC değil: doğrudan yazma da reddedilmeli.
begin
  update public.profiles set odeme_gunu = 5, maas_yontemi = null where id = u_personel2;
  raise exception 'FAIL 50d: yöntemsiz otomatik ödeme günü yazılabildi';
exception when check_violation then null;
end;

-- (e) Kural yöntemi artık NULL olamaz.
if exists (select 1 from information_schema.columns
            where table_schema = 'public' and table_name = 'kasa_tekrar_kurallari'
              and column_name = 'yontem' and is_nullable = 'YES') then
  raise exception 'FAIL 50e: kural yöntemi hâlâ NULL olabiliyor';
end if;

raise notice 'PASS 50: otomatik ödemeler yöntemsiz doğamıyor';

-- ---------------------------------------------------------------------------
-- 51. Ödemesiz çıkış ve sonradan tahsil (027)
--
-- Kapanmış bir bilet artık iki durumda olabilir: ödemesi alınmış ya da borçlu.
-- ARADA BİR DURUM YOK, ve kısıt bunu zorlar — yarım tahsil edilmiş bir bilet,
-- kasanın ne kadar eksik olduğunu her raporda ayrı hesaplamak demektir.
-- ---------------------------------------------------------------------------
perform pg_temp.login(u_personel);
if public.acik_vardiyam() is null then
  perform public.vardiya_ac(0);
end if;
select public.acik_vardiyam() into v_vardiya;

select public.bilet_ac('34BORC01', gen_random_uuid()) into v_bilet;
perform pg_temp.logout();
-- Ücret sıfırdan büyük olsun; sıfır ücrette "borç" diye bir şey olmaz.
update public.biletler set giris_at = now() - interval '3 hours' where id = v_bilet;
perform pg_temp.login(u_personel);

-- (a) Ödemesiz çıkışta yöntem gönderilemez.
begin
  perform * from public.bilet_kapat(v_bilet, 'NAKIT', null, null, null, 'MOBIL', false);
  raise exception 'FAIL 51a: ödemesiz çıkışta ödeme yöntemi kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Ödemesiz çıkışta%' then
    raise exception 'FAIL 51a: beklenmeyen hata: %', sqlerrm;
  end if;
end;

-- (b) Araç çıkar, para alınmaz: bilet KAPALI, tahsil 0, tahsilat satırı YOK.
perform * from public.bilet_kapat(v_bilet, null, null, null, null, 'MOBIL', false);

select b.ucret_kurus, b.tahsil_kurus into v_ucret, v_ucret2
  from public.biletler b where b.id = v_bilet;
if v_ucret <= 0 then raise exception 'FAIL 51b: kurulum — ücret sıfır çıktı'; end if;
if v_ucret2 <> 0 then raise exception 'FAIL 51b: ödemesiz çıkışta para tahsil edildi'; end if;
if (select durum from public.biletler where id = v_bilet) <> 'KAPALI' then
  raise exception 'FAIL 51b: bilet kapanmadı';
end if;
select count(*) into v_n from public.tahsilatlar where bilet_id = v_bilet;
if v_n <> 0 then
  raise exception 'FAIL 51b: ödemesiz çıkış ciroya giren bir tahsilat yazdı';
end if;

-- (c) Sonradan tahsil: para alınır, tahsilat satırı BEKLIYOR doğar — yani
--     onaydan geçmeden ciroya girmez, tıpkı normal tahsilat gibi.
select public.bilet_tahsil(v_bilet, 'NAKIT') into v_n;
if v_n <> v_ucret then raise exception 'FAIL 51c: yanlış tutar tahsil edildi'; end if;
if (select tahsil_kurus from public.biletler where id = v_bilet) <> v_ucret then
  raise exception 'FAIL 51c: bilet tahsil edilmiş görünmüyor';
end if;
select count(*) into v_n from public.tahsilatlar
 where bilet_id = v_bilet and durum = 'BEKLIYOR' and yontem = 'NAKIT';
if v_n <> 1 then raise exception 'FAIL 51c: tahsilat satırı doğmadı'; end if;

-- Çıkış hangi vardiyada yapıldıysa orada kalmalı: para tahsilat satırının
-- vardiyasına yazılır, aracın ne zaman çıktığı bilgisi biletin üstünde durur.
-- Bu iddia olmasaydı, ileride "doğru vardiyaya yazalım" diye eklenen bir satır
-- çıkışı sessizce tahsil edenin vardiyasına taşır ve hiçbir test patlamazdı.
if (select kapatan_vardiya_id from public.biletler where id = v_bilet)
     is distinct from v_vardiya then
  raise exception 'FAIL 51c: sonradan tahsil çıkışın vardiyasını değiştirdi';
end if;

-- (d) İki kez tahsil edilemez. Bu kontrol olmasaydı aynı bilet için ikinci bir
--     tahsilat satırı doğar ve kasa gerçekte alınmamış parayı sayardı.
begin
  perform public.bilet_tahsil(v_bilet, 'NAKIT');
  raise exception 'FAIL 51d: aynı bilet iki kez tahsil edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%zaten alınmış%' then
    raise exception 'FAIL 51d: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (e) Kısmi ödeme hâlâ imkânsız: ne 0 ne de tam tutar olan bir değer kısıttan
--     dönmeli. Gevşetilen kimlik yalnızca "hiç" ile "tamamı"na izin verir.
-- Bayrak ŞART: bayraksız güncelleme değişmezlik guard'ına takılır ve test,
-- sınadığı kısıt yerine ilgisiz bir sebeple geçmiş görünürdü. Bayrakla guard
-- parayı serbest bırakır — reddi bu kez gerçekten CHECK verir.
begin
  perform set_config('app.bilet_tahsil', v_bilet::text, true);
  update public.biletler set tahsil_kurus = v_ucret - 1 where id = v_bilet;
  perform set_config('app.bilet_tahsil', '', true);
  raise exception 'FAIL 51e: kısmi tahsilat yazılabildi';
exception
  when check_violation then perform set_config('app.bilet_tahsil', '', true);
  when others then
    perform set_config('app.bilet_tahsil', '', true);
    raise;
end;

-- (f) Muafiyet DAR olmalı: bayrak yokken kapanmış bilet hâlâ değişmez, ve
--     bayrak varken bile para dışındaki kolonlar korunur. Tam bypass verilmiş
--     olsaydı "sonradan tahsil" adı altında ücret de plaka da değişebilirdi.
begin
  update public.biletler set plaka = '34HILE99' where id = v_bilet;
  raise exception 'FAIL 51f: kapanmış biletin plakası değiştirilebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Kapanmış bilet değiştirilemez%' then
    raise exception 'FAIL 51f: beklenmeyen hata: %', sqlerrm;
  end if;
end;

begin
  perform set_config('app.bilet_tahsil', v_bilet::text, true);
  update public.biletler set ucret_kurus = ucret_kurus + 1000 where id = v_bilet;
  perform set_config('app.bilet_tahsil', '', true);
  raise exception 'FAIL 51f: tahsil bayrağı ücreti de değiştirmeye izin verdi';
exception when others then
  perform set_config('app.bilet_tahsil', '', true);
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Kapanmış bilet değiştirilemez%' then
    raise exception 'FAIL 51f: beklenmeyen hata: %', sqlerrm;
  end if;
end;

raise notice 'PASS 51: ödemesiz çıkış borç bırakıyor, sonradan tahsil bir kez çalışıyor';

-- ---------------------------------------------------------------------------
-- 52. Reddedilen tahsilat bileti borçlu bırakır (028)
--
-- "Reddet" = "bu para alınmadı". Red yalnızca tahsilat satırına dokunsaydı,
-- bilet "₺X tahsil edildi" demeye devam eder, ciro hiçbir şey saymaz ve
-- `bilet_tahsil` biletin kendi sayısına bakıp yeniden tahsili reddederdi —
-- yani borç arayüzden kurtarılamaz olurdu.
-- ---------------------------------------------------------------------------
perform pg_temp.login(u_yonetici);
select public.bilet_ac('34RED001', gen_random_uuid()) into v_bilet;
perform pg_temp.logout();
update public.biletler set giris_at = now() - interval '3 hours' where id = v_bilet;

perform pg_temp.login(u_yonetici);
perform * from public.bilet_kapat(v_bilet, 'NAKIT');
select b.ucret_kurus into v_ucret from public.biletler b where b.id = v_bilet;
if v_ucret <= 0 then raise exception 'FAIL 52: kurulum — ücret sıfır çıktı'; end if;

select t.id into v_id2 from public.tahsilatlar t
 where t.bilet_id = v_bilet and t.durum = 'BEKLIYOR';
if v_id2 is null then raise exception 'FAIL 52: kurulum — tahsilat doğmadı'; end if;

-- (a) Red bileti geri alır: para alınmamış say.
if public.tahsilat_reddet(array[v_id2], 'test') <> 1 then
  raise exception 'FAIL 52a: red uygulanmadı';
end if;
if (select tahsil_kurus from public.biletler where id = v_bilet) <> 0
   or (select odeme_yontemi from public.biletler where id = v_bilet) is not null then
  raise exception 'FAIL 52a: reddedilen tahsilat bileti hâlâ ödenmiş gösteriyor';
end if;
if (select durum from public.tahsilatlar where id = v_id2) <> 'REDDEDILDI' then
  raise exception 'FAIL 52a: tahsilat reddedilmedi';
end if;
perform pg_temp.logout();

-- (b) Personel BAŞKA BİR VARDİYADA kapanmış bileti tahsil edemez. RPC
--     `security definer` olduğu için RLS'i atlar; kontrol gövdenin içinde
--     olmasaydı okuma yolunda göremediği bileti tahsil edebilirdi.
--
--     030'dan sonra sınır "başkasının kapattığı bilet" DEĞİLDİR: vardiya
--     kasaya ait, dolayısıyla açık vardiyada kapanmış bir bileti o vardiyadaki
--     herkes tahsil edebilir — ortak çekmecede doğrusu budur, aksi hâlde
--     vardiya devrinde ödenmemiş her borç kurtarılamaz kalırdı. Sınanan sınır
--     bu yüzden vardiyanın KAPANMIŞ olması: bilet önceki vardiyaya ait.
perform pg_temp.logout();
update public.vardiyalar
   set kapanis_at = now(), kapanis_kaynak = 'ELLE'
 where kapanis_at is null;

perform pg_temp.login(u_personel);
perform public.vardiya_ac(0);
begin
  perform public.bilet_tahsil(v_bilet, 'NAKIT');
  raise exception 'FAIL 52b: Personel başka vardiyanın biletini tahsil etti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%yetkiniz yok%' then
    raise exception 'FAIL 52b: beklenmeyen hata: %', sqlerrm;
  end if;
end;

-- (b2) 034: açık vardiyası OLMAYAN personel de tahsil edememeli, ve bu tam
--      olarak guard'ın delindiği yerdi. `acik_vardiyam()` null dönünce
--      karşılaştırma NULL olur, `not (false or NULL)` NULL üretir ve PL/pgSQL
--      NULL'ı false saydığı için `raise` HİÇ çalışmazdı — RLS'in gizlediği
--      bileti RPC tahsil ettiriyordu. `using (...)` biçiminde aynı ifade
--      güvenli olduğu için bu yalnızca RPC'de vardı.
perform public.vardiya_kapat(0, null);
-- 035: kapanış Yönetici onayıyla tamamlanır. `acik_vardiyam()` kasanın açık
-- vardiyasını döndürdüğü için id'yi ayrıca taşımaya gerek yok.
perform pg_temp.login(u_yonetici);
perform public.vardiya_kapatma_onayla(public.acik_vardiyam());
perform pg_temp.login(u_personel);
if public.acik_vardiyam() is not null then
  raise exception 'FAIL 52b2: kurulum — vardiya kapanmadı';
end if;
begin
  perform public.bilet_tahsil(v_bilet, 'NAKIT');
  raise exception 'FAIL 52b2: vardiyası olmayan personel bilet tahsil etti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%yetkiniz yok%' then
    raise exception 'FAIL 52b2: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (c) Reddedilen bilet yeniden tahsil EDİLEBİLİR olmalı — 028'in bütün amacı.
perform pg_temp.login(u_yonetici);
if public.bilet_tahsil(v_bilet, 'NAKIT') <> v_ucret then
  raise exception 'FAIL 52c: reddedilen bilet yeniden tahsil edilemedi';
end if;
if (select tahsil_kurus from public.biletler where id = v_bilet) <> v_ucret then
  raise exception 'FAIL 52c: yeniden tahsil bilete yazılmadı';
end if;
perform pg_temp.logout();

raise notice 'PASS 52: red bileti borçlu bırakıyor ve yeniden tahsil edilebiliyor';

-- ---------------------------------------------------------------------------
-- 53. Plaka şüphesi (029)
--
-- Eşik 0.75'in ALTINDA olamaz: o güvenin altındaki okuma zaten kabul edilmiyor
-- ve bilete hiç girmiyor, dolayısıyla altında bir uyarı hiç tetiklenmezdi.
-- Sınanan bant "kabul edildi ama emin değiliz" bandıdır.
-- ---------------------------------------------------------------------------
perform pg_temp.logout();
insert into public.plaka_okuma_log (saglayici, guven, onerilen)
values ('claude-haiku-4-5', 0.78, '34SUP001') returning id into v_id2;

perform pg_temp.login(u_yonetici);
select public.bilet_ac('34SUP001', gen_random_uuid()) into v_bilet;

-- (a) Öneri aynen kabul edilmiş ve güven eşiğin altında → şüpheli.
if not public.bilet_okuma_bagla(v_bilet, v_id2, '34SUP001') then
  raise exception 'FAIL 53a: düşük güvenli okuma şüpheli işaretlenmedi';
end if;
if not (select b.plaka_supheli from public.biletler b where b.id = v_bilet) then
  raise exception 'FAIL 53a: bayrak bilete yazılmadı';
end if;
-- Doğruluk kaydı da yazılmalı: bagla, plaka_okuma_kabul'ü içeriden çağırır.
if (select l.kabul_edilen from public.plaka_okuma_log l where l.id = v_id2) <> '34SUP001' then
  raise exception 'FAIL 53a: doğruluk kaydı yazılmadı';
end if;

-- (b) Liste rozetinin kaynağı: acik_bilet_ara kolonu döndürmeli. Dönmezse
--     rozet sessizce hiç çıkmazdı.
if not exists (select 1 from public.acik_bilet_ara('34SUP001') x
                where x.id = v_bilet and x.plaka_supheli) then
  raise exception 'FAIL 53b: acik_bilet_ara şüpheyi göstermiyor';
end if;

-- (c) "Doğru" bayrağı kaldırır.
perform public.bilet_plaka_dogrula(v_bilet);
if (select b.plaka_supheli from public.biletler b where b.id = v_bilet) then
  raise exception 'FAIL 53c: doğrulama bayrağı kaldırmadı';
end if;
perform pg_temp.logout();

-- (d) Operatör öneriyi DEĞİŞTİRDİYSE plaka artık onundur, modelin değil —
--     şüpheli sayılmamalı. Yanlış alarmların en büyük kaynağı bu olurdu.
insert into public.plaka_okuma_log (saglayici, guven, onerilen)
values ('claude-haiku-4-5', 0.78, '34SUP009') returning id into v_id2;
perform pg_temp.login(u_yonetici);
select public.bilet_ac('34SUP002', gen_random_uuid()) into v_bilet;
if public.bilet_okuma_bagla(v_bilet, v_id2, '34SUP002') then
  raise exception 'FAIL 53d: operatörün düzelttiği plaka şüpheli sayıldı';
end if;
perform pg_temp.logout();

-- (e) Yüksek güvenli okuma işaretlenmemeli.
insert into public.plaka_okuma_log (saglayici, guven, onerilen)
values ('claude-haiku-4-5', 0.97, '34SUP003') returning id into v_id2;
perform pg_temp.login(u_yonetici);
select public.bilet_ac('34SUP003', gen_random_uuid()) into v_bilet;
if public.bilet_okuma_bagla(v_bilet, v_id2, '34SUP003') then
  raise exception 'FAIL 53e: yüksek güvenli okuma şüpheli sayıldı';
end if;

-- (f) "Yanlış, düzelt": içeride aynı plaka varsa reddedilmeli (kısmi tekil
--     indeks), yoksa normalize edilerek yazılmalı.
begin
  perform public.bilet_plaka_duzelt(v_bilet, '34SUP002');
  raise exception 'FAIL 53f: içeride bulunan bir plakaya düzeltmeye izin verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%zaten açık bir bilet%' then
    raise exception 'FAIL 53f: beklenmeyen hata: %', sqlerrm;
  end if;
end;

if public.bilet_plaka_duzelt(v_bilet, '34 sup 777') <> '34SUP777' then
  raise exception 'FAIL 53f: plaka düzeltilmedi ya da normalize edilmedi';
end if;
if (select b.plaka from public.biletler b where b.id = v_bilet) <> '34SUP777' then
  raise exception 'FAIL 53f: düzeltme bilete yazılmadı';
end if;
perform pg_temp.logout();

-- (g) KABUL KAPISININ ALTINDAKİ okuma işaretlenmemeli. 0.75'in altında olan
--     okuma operatöre hiç gösterilmez; plakayı insan yazar. Eşleşme tesadüftür
--     ve ilk sürümde tam burada yanlış alarm üretiliyordu — hem de en sık,
--     çünkü bastırılmış okumaların çoğu DOĞRUdur.
insert into public.plaka_okuma_log (saglayici, guven, onerilen)
values ('claude-haiku-4-5', 0.60, '34SUP004') returning id into v_id2;
perform pg_temp.login(u_yonetici);
select public.bilet_ac('34SUP004', gen_random_uuid()) into v_bilet;
if public.bilet_okuma_bagla(v_bilet, v_id2, '34SUP004') then
  raise exception 'FAIL 53g: bastırılmış okuma şüpheli sayıldı';
end if;
if (select b.plaka_supheli from public.biletler b where b.id = v_bilet) then
  raise exception 'FAIL 53g: bastırılmış okuma bilete bayrak yazdı';
end if;
perform pg_temp.logout();

-- (h) KAMERA yolu. İşaretin asıl gerekçesi burası: telefonda operatör plakaya
--     bakar, kamerada kimse bakmaz.
insert into public.plaka_okuma_log (saglayici, guven, onerilen)
values ('claude-haiku-4-5', 0.80, '34SUP005') returning id into v_id2;
perform pg_temp.login(u_yonetici);
select public.bilet_ac('34SUP005', gen_random_uuid()) into v_bilet;
perform pg_temp.logout();

if not public.kamera_okuma_bagla(v_bilet, v_id2) then
  raise exception 'FAIL 53h: kamera bileti şüpheli işaretlenmedi';
end if;
if not (select b.plaka_supheli from public.biletler b where b.id = v_bilet) then
  raise exception 'FAIL 53h: kamera bayrağı bilete yazılmadı';
end if;
-- kabul_edilen DOLDURULMAMALI: kamerada kimse kabul etmez. Doldurulsaydı her
-- satırda onerilen ile birebir aynı olur ve doğruluk ölçümü sahte bir tam
-- isabet gösterirdi.
if (select l.kabul_edilen from public.plaka_okuma_log l where l.id = v_id2) is not null then
  raise exception 'FAIL 53h: kamera yolu kabul_edilen yazdı';
end if;

-- (i) Kamera RPC'sinin tek koruması GRANT'tır — is_staff() guard'ı taşıyamaz,
--     çünkü webhook'ta auth.uid() null'dır.
if has_function_privilege('authenticated', 'public.kamera_okuma_bagla(uuid, uuid)', 'execute')
   or has_function_privilege('anon', 'public.kamera_okuma_bagla(uuid, uuid)', 'execute') then
  raise exception 'FAIL 53i: kamera_okuma_bagla istemciye açık';
end if;

raise notice 'PASS 53: düşük güvenli okuma işaretleniyor, doğrulanıyor ve düzeltiliyor';

-- =====================================================================
-- 54  Vardiya kasaya ait, kişiye değil (030)
-- =====================================================================

perform pg_temp.login(u_personel);
if public.acik_vardiyam() is null then
  perform public.vardiya_ac(0);
end if;
select public.acik_vardiyam() into v_vardiya;
select public.bilet_ac('34ORT001', gen_random_uuid()) into v_bilet;
perform pg_temp.logout();

-- (a) Ortak çekmece: BAŞKA bir personel aynı vardiyayı görür. Kişi başına
--     vardiyada ikisinin tahsilatı ayrı sayıma giderdi ve hiçbiri tutmazdı.
perform pg_temp.login(u_personel2);
if public.acik_vardiyam() is distinct from v_vardiya then
  raise exception 'FAIL 54a: vardiya hâlâ kişiye özel';
end if;

-- (b) ve ikinci bir vardiya AÇAMAZ — indeks artık kasa başına tek satır.
begin
  perform public.vardiya_ac(0);
  raise exception 'FAIL 54b: kasada ikinci vardiya açılabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

-- (c) Onun kapattığı bilet de o vardiyaya bağlanır. `kapatan_vardiya_id`
--     üzerinden bakılıyor çünkü ücretsiz süre içinde kapanan bir bilet hiç
--     tahsilat satırı üretmez — iddia ücrete bağlı olmamalı.
perform public.bilet_kapat(v_bilet, 'NAKIT');
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and kapatan_vardiya_id = v_vardiya) then
  raise exception 'FAIL 54c: başka personelin kapattığı bilet vardiyaya bağlanmadı';
end if;

-- (d) EN ÖNEMLİSİ. Eski `acik_vardiyam()` personel olmayanı auth.uid()
--     eşleşmediği için eliyordu; kasaya ait tek satır herkes için
--     eşleşeceğinden o örtük filtre kalktı ve `tahsilatlar_select`in kendi
--     is_staff() kontrolü YOKTU. Rolü null bir kullanıcı açık vardiyanın
--     bütün tahsilatlarını okuyabilir hâle gelirdi.
perform pg_temp.login(u_pending);
if public.acik_vardiyam() is not null then
  raise exception 'FAIL 54d: acik_vardiyam bekleyen kullanıcıya vardiya döndürdü';
end if;
select count(*) into v_n from public.tahsilatlar;
if v_n <> 0 then
  raise exception 'FAIL 54d: bekleyen kullanıcı tahsilatları görüyor (%)', v_n;
end if;
select count(*) into v_n from public.vardiyalar;
if v_n <> 0 then
  raise exception 'FAIL 54d: bekleyen kullanıcı vardiyaları görüyor (%)', v_n;
end if;
perform pg_temp.logout();

-- (e) Personel açık vardiyayı görür, kapananı GÖRMEZ: kapanmış vardiya artık
--     kişisel bir kayıt değil, işletmenin nakit geçmişi.
--
--     035'ten beri personelin sayımı KAPATMAZ, istek yazar; vardiya ancak
--     Yönetici onayladığında kapanır. Görünürlük iddiası bu yüzden onaydan
--     SONRA sınanıyor — `vardiya_kapat` tek başına artık yetmez.
perform pg_temp.login(u_personel);
if not exists (select 1 from public.vardiyalar where id = v_vardiya) then
  raise exception 'FAIL 54e: personel açık vardiyayı göremiyor';
end if;
perform public.vardiya_kapat(0, null);
if not exists (select 1 from public.vardiyalar
                where id = v_vardiya and kapanis_at is null) then
  raise exception 'FAIL 54e: personelin isteği vardiyayı doğrudan kapattı';
end if;
perform pg_temp.logout();

perform pg_temp.login(u_yonetici);
perform public.vardiya_kapatma_onayla(v_vardiya);
perform pg_temp.logout();

perform pg_temp.login(u_personel);
if exists (select 1 from public.vardiyalar where id = v_vardiya) then
  raise exception 'FAIL 54e: personel kapanmış vardiyayı hâlâ görüyor';
end if;
perform pg_temp.logout();

-- (f) Sayan kişi yazılır. Ortak çekmecede açan ile sayan aynı olmak zorunda
--     değil, ve hesap sorulacak kişi sayandır.
select kapatan_id into v_id from public.vardiyalar where id = v_vardiya;
if v_id is distinct from u_personel then
  raise exception 'FAIL 54f: sayan kişi kapatan_id''ye yazılmadı';
end if;

-- (g) Otomatik vardiyanın açanı YOKTUR; elle açılanın olmak zorundadır.
-- `check_violation`, `others` DEĞİL: bu noktada açık vardiya olmadığı için
-- insert kısıta takılmalı. `others` yazılsaydı satır tekil indekse takılsa da
-- test geçer ve sınamak istediği kısıtı hiç sınamamış olurdu.
begin
  insert into public.vardiyalar (personel_id, otomatik_acildi) values (null, false);
  raise exception 'FAIL 54g: açanı olmayan elle vardiya yazılabildi';
exception when check_violation then null;
end;
insert into public.vardiyalar (personel_id, otomatik_acildi) values (null, true)
  returning id into v_id;
delete from public.vardiyalar where id = v_id;

raise notice 'PASS 54: vardiya kasaya ait — ortak, tek, ve rolsüz kullanıcıya kapalı';

-- =====================================================================
-- 55  Kaydı kim açtı: liste satırı da taşımalı (031)
-- =====================================================================

-- Kart "Bilinmiyor" yerine gerçek adı yazabilsin diye `acik_bilet_ara` bu iki
-- kolonu döndürmek ZORUNDA. Eksik olsalar istemci sessizce 'Otomatik' yazardı
-- — yanlış bir cevap, hata değil, ve o yüzden test ediliyor.
perform pg_temp.login(u_personel);
if public.acik_vardiyam() is null then
  perform public.vardiya_ac(0);
end if;
select public.bilet_ac('34KIM001', gen_random_uuid()) into v_bilet;
select a.giris_by, a.giris_kaynak::text into v_id, v_txt
  from public.acik_bilet_ara('34KIM001') a where a.id = v_bilet;
if v_id is distinct from u_personel then
  raise exception 'FAIL 55: acik_bilet_ara girişi yapanı döndürmedi';
end if;
if v_txt is distinct from 'MOBIL' then
  raise exception 'FAIL 55: acik_bilet_ara kaynağı döndürmedi (%)', v_txt;
end if;
perform pg_temp.logout();

raise notice 'PASS 55: açık bilet listesi girişi yapanı ve kaynağı taşıyor';

-- =====================================================================
-- 56  Vardiya kapatma onayı (035)
--     Personelin sayımı bir İSTEKTİR; çekmece Yönetici onaylayana kadar
--     açık kalır.
-- =====================================================================

-- Önceki bloklardan (55) açık kalmış bir vardiya olabilir ve kasa başına tek
-- vardiya kuralı ikincisini engeller. Temiz çekmeceyle başla: aşağıdaki
-- aritmetik açılış nakdinin ve tahsilat geçmişinin bilinmesine dayanıyor.
update public.vardiyalar
   set kapanis_at           = now(),
       kapanis_kaynak       = 'ELLE',
       kapatma_talebi_at    = null,
       kapatma_talebi_by    = null,
       talep_sayilan_kurus  = null,
       talep_beklenen_kurus = null,
       talep_notlar         = null
 where kapanis_at is null;

perform pg_temp.login(u_personel);
select public.vardiya_ac(0) into v_vardiya;

-- (a) Sayım kapatmaz, istek yazar. `kapandi` dönüşü ekranın hangi mesajı
--     göstereceğine karar veren tek şey — yanlışsa operatöre vardiya kapandı
--     denir ve kimse kapatmaz.
select v.kapandi into v_bool from public.vardiya_kapat(12345, 'ilk sayım') v;
if v_bool then
  raise exception 'FAIL 56a: personelin sayımı vardiyayı doğrudan kapattı';
end if;
if not exists (select 1 from public.vardiyalar
                where id = v_vardiya and kapanis_at is null) then
  raise exception 'FAIL 56a: istek sırasında vardiya kapandı';
end if;
select kapatma_talebi_by, talep_sayilan_kurus into v_id, v_n
  from public.vardiyalar where id = v_vardiya;
if v_id is distinct from u_personel or v_n is distinct from 12345 then
  raise exception 'FAIL 56a: kapatma isteği yazılmadı (% / %)', v_id, v_n;
end if;

-- (b) Kararı personel VEREMEZ. Ekranı gizlemek güvenlik değildir; sınır
--     RPC'nin kendisinde durmalı.
begin
  perform public.vardiya_kapatma_onayla(v_vardiya);
  raise exception 'FAIL 56b: personel kendi kapatma isteğini onayladı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 56b: beklenmeyen hata (onayla): %', sqlerrm;
  end if;
end;
begin
  perform public.vardiya_kapatma_reddet(v_vardiya, null);
  raise exception 'FAIL 56b: personel kapatma isteğini reddedebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 56b: beklenmeyen hata (reddet): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (c) Ret vardiyayı AÇIK bırakır ve isteği siler: reddedilen bir sayım,
--     kapanmamış bir çekmecedir.
perform pg_temp.login(u_yonetici);
perform public.vardiya_kapatma_reddet(v_vardiya, 'tekrar say');
if not exists (select 1 from public.vardiyalar
                where id = v_vardiya and kapanis_at is null
                  and kapatma_talebi_at is null
                  and talep_sayilan_kurus is null) then
  raise exception 'FAIL 56c: ret sonrası vardiya ya da istek durumu yanlış';
end if;

-- (d) İstek yokken onay diye bir şey yoktur.
begin
  perform public.vardiya_kapatma_onayla(v_vardiya);
  raise exception 'FAIL 56d: istek yokken vardiya kapatıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%kapatma isteği yok%' then
    raise exception 'FAIL 56d: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (e) Karar bildirimi İSTEĞİ YAPANA gider, o yüzden VARDIYA_KARAR yönetici
--     tipi OLMAMALI — olsaydı `notifications_select` personeli kendi
--     bildiriminden men ederdi. İsteğin kendisi ise Yöneticinindir.
if not public.bildirim_yonetici_turu('VARDIYA_KAPATMA') then
  raise exception 'FAIL 56e: VARDIYA_KAPATMA yönetici tipi sayılmıyor';
end if;
if public.bildirim_yonetici_turu('VARDIYA_KARAR') then
  raise exception 'FAIL 56e: VARDIYA_KARAR yönetici tipi sayıldı';
end if;
-- 029 enum değerini eklemiş ama listeye koymayı atlamıştı; 035 kapattı.
if not public.bildirim_yonetici_turu('PLAKA_SUPHE') then
  raise exception 'FAIL 56e: PLAKA_SUPHE yönetici tipi sayılmıyor';
end if;
perform pg_temp.login(u_personel);
if not exists (select 1 from public.notifications
                where profile_id = u_personel and tur::text = 'VARDIYA_KARAR') then
  raise exception 'FAIL 56e: personel kendi kapatma kararını göremiyor';
end if;

-- (f) EN ÖNEMLİSİ. Sayımdan SONRA tahsil edilen nakit onayda hesaba katılır.
--     İsteğin içindeki eski `beklenen` kullanılsaydı, kasada olmayan para
--     "tutuyor" görünürdü.
-- Sayım anındaki nakit, ve sayımdan SONRAKİ nakit. İkisi de ölçülüyor:
-- sabit sayılara güvenmek, bu bloğun önüne bir tahsilat eklendiği gün testi
-- sessizce yanlış yerden geçirirdi.
select coalesce(sum(t.tutar_kurus), 0)::integer into v_n
  from public.tahsilatlar t
 where t.vardiya_id = v_vardiya and t.yontem = 'NAKIT';
perform public.vardiya_kapat(50000, 'ikinci sayım');
select public.kayip_bilet_tahsil('34SONRA1', 'NAKIT', gen_random_uuid()) into v_bilet;
select coalesce(sum(t.tutar_kurus), 0)::integer into v_ucret
  from public.tahsilatlar t
 where t.vardiya_id = v_vardiya and t.yontem = 'NAKIT';
if v_ucret <= v_n then
  raise exception 'FAIL 56f: sayımdan sonra nakit tahsilat üretilemedi';
end if;
perform pg_temp.logout();

perform pg_temp.login(u_yonetici);
select * into v_rec from public.vardiya_kapatma_onayla(v_vardiya);
perform pg_temp.logout();

select acilis_nakit_kurus into v_n from public.vardiyalar where id = v_vardiya;
if v_rec.beklenen_kurus is distinct from v_n + v_ucret then
  raise exception 'FAIL 56f: beklenen yeniden hesaplanmadı (% yerine %)',
    v_n + v_ucret, v_rec.beklenen_kurus;
end if;
if v_rec.fark_kurus is distinct from 50000 - (v_n + v_ucret) then
  raise exception 'FAIL 56f: fark eski beklenene göre hesaplandı (%)',
    v_rec.fark_kurus;
end if;

-- (g) Kapatan = nakdi SAYAN kişi, onaylayan değil; ve isteğin notu kaydın
--     notu olur.
select kapatan_id, sayilan_nakit_kurus, notlar, kapanis_at
  into v_id, v_n, v_txt, v_ts
  from public.vardiyalar where id = v_vardiya;
if v_ts is null then
  raise exception 'FAIL 56g: onay vardiyayı kapatmadı';
end if;
if v_id is distinct from u_personel then
  raise exception 'FAIL 56g: kapatan_id sayan kişi değil (%)', v_id;
end if;
if v_n is distinct from 50000 or v_txt is distinct from 'ikinci sayım' then
  raise exception 'FAIL 56g: isteğin sayımı/notu kayda geçmedi (% / %)', v_n, v_txt;
end if;
if exists (select 1 from public.vardiyalar
            where id = v_vardiya and kapatma_talebi_at is not null) then
  raise exception 'FAIL 56g: kapanan vardiyada istek temizlenmedi';
end if;

raise notice 'PASS 56: vardiya kapatma isteği Yönetici onayından geçiyor';

-- =====================================================================
-- 57  Kamera eşleştirme ve şerit başına nöbet (036)
--     Kurulum kodu tek kullanımlıktır, gizli anahtar HİÇ düz metin
--     saklanmaz, ve her kameranın ölümü AYRI uyarı üretir.
-- =====================================================================

perform pg_temp.logout();
delete from public.kamera_eslestirme;
delete from public.kamera_cihazlari;
delete from public.notifications where tur = 'KAMERA';

-- (a) Personel bu ekranın hiçbir yerine dokunamaz. Kamera kurulumu onun
--     işi değil; gördüğü her ekran görmemesi gereken bir ekran olabilir.
perform pg_temp.login(u_personel);
begin
  perform public.kamera_kod_uret('Deneme', 'GIRIS');
  raise exception 'FAIL 57a: personel kurulum kodu üretebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 57a: beklenmeyen hata (kod_uret): %', sqlerrm;
  end if;
end;
begin
  perform public.kamera_bekleyen_kodlar();
  raise exception 'FAIL 57a: personel bekleyen kodları görebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 57a: beklenmeyen hata (bekleyen_kodlar): %', sqlerrm;
  end if;
end;
begin
  perform public.kamera_cihaz_kaldir(gen_random_uuid());
  raise exception 'FAIL 57a: personel kamera kaldırabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 57a: beklenmeyen hata (cihaz_kaldir): %', sqlerrm;
  end if;
end;
begin
  perform public.kamera_cihaz_durum(gen_random_uuid(), false);
  raise exception 'FAIL 57a: personel kamerayı devre dışı bırakabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 57a: beklenmeyen hata (cihaz_durum): %', sqlerrm;
  end if;
end;
begin
  perform public.kamera_kod_durum(gen_random_uuid());
  raise exception 'FAIL 57a: personel kurulum kodunun durumunu okuyabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 57a: beklenmeyen hata (kod_durum): %', sqlerrm;
  end if;
end;
begin
  perform public.kamera_eski_kopru_unut();
  raise exception 'FAIL 57a: personel eski köprü nöbetini kapatabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 57a: beklenmeyen hata (eski_kopru_unut): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (b) Kimlik BASAN iki fonksiyon istemciye kapalı olmalı. Ekranı gizlemek
--     güvenlik değildir; sınır grant'ın kendisinde durmalı.
if has_function_privilege('authenticated', 'public.kamera_eslestir(text)', 'execute')
   or has_function_privilege('anon', 'public.kamera_eslestir(text)', 'execute') then
  raise exception 'FAIL 57b: kamera_eslestir istemciye açık';
end if;
if has_function_privilege('authenticated', 'public.kamera_kalp_cihaz(uuid)', 'execute')
   or has_function_privilege('anon', 'public.kamera_kalp_cihaz(uuid)', 'execute') then
  raise exception 'FAIL 57b: kamera_kalp_cihaz istemciye açık';
end if;
-- Canlı kodlar hiçbir role açık olmamalı; hash de istemciye görünmemeli.
if has_table_privilege('authenticated', 'public.kamera_eslestirme', 'SELECT')
   or has_table_privilege('service_role', 'public.kamera_eslestirme', 'SELECT') then
  raise exception 'FAIL 57b: kamera_eslestirme okunabiliyor';
end if;
if has_column_privilege('authenticated', 'public.kamera_cihazlari', 'gizli_hash', 'SELECT') then
  raise exception 'FAIL 57b: gizli_hash istemciye açık';
end if;
-- Yetkiler AÇIKÇA yazılmış olmalı, Supabase'in varsayılanına yaslanmamalı:
-- webhook hash üzerinden sorgu yapar (okuma şart), ama satır yazması için
-- hiçbir sebep yok — cihazı yalnızca kamera_eslestir oluşturur.
if not has_column_privilege('service_role', 'public.kamera_cihazlari', 'gizli_hash', 'SELECT') then
  raise exception 'FAIL 57b: webhook gizli_hash okuyamıyor — eşleştirilen her kamera 401 alır';
end if;
if has_table_privilege('service_role', 'public.kamera_cihazlari', 'INSERT')
   or has_table_privilege('service_role', 'public.kamera_cihazlari', 'UPDATE')
   or has_table_privilege('service_role', 'public.kamera_cihazlari', 'DELETE') then
  raise exception 'FAIL 57b: service_role kamera_cihazlari tablosuna yazabiliyor';
end if;
if has_table_privilege('authenticated', 'public.kamera_cihazlari', 'INSERT')
   or has_table_privilege('authenticated', 'public.kamera_cihazlari', 'UPDATE')
   or has_table_privilege('authenticated', 'public.kamera_cihazlari', 'DELETE') then
  raise exception 'FAIL 57b: istemci kamera_cihazlari tablosuna yazabiliyor';
end if;
if not has_column_privilege('authenticated', 'public.kamera_cihazlari', 'durum_at', 'SELECT') then
  raise exception 'FAIL 57b: ekranın okuduğu durum_at kolonu kapalı';
end if;
if has_function_privilege('anon', 'public.kamera_eski_kopru_unut()', 'execute')
   or has_function_privilege('service_role', 'public.kamera_eski_kopru_unut()', 'execute') then
  raise exception 'FAIL 57b: kamera_eski_kopru_unut istemci dışı bir role açık';
end if;
if has_function_privilege('anon', 'public.kamera_kod_durum(uuid)', 'execute')
   or has_function_privilege('service_role', 'public.kamera_kod_durum(uuid)', 'execute') then
  raise exception 'FAIL 57b: kamera_kod_durum istemci dışı bir role açık';
end if;

-- (c) Yönetici kod üretir, kamera onu KENDİ anahtarına çevirir. Saklanan
--     şey anahtarın kendisi değil, sha256'sı olmalı — veritabanını okuyan
--     biri çalışan bir kimlik elde edememeli.
perform pg_temp.login(u_yonetici);
select public.kamera_kod_uret('Çıkış bariyeri', 'CIKIS') into v_json;
v_txt := v_json ->> 'kod';
if length(v_txt) <> 11 or substr(v_txt, 6, 1) <> '-' then
  raise exception 'FAIL 57c: kod biçimi XXXXX-XXXXX değil: %', v_txt;
end if;
-- Ekran, kurulumun nereye vardığını kodun KENDİSİNİ bir daha okumadan
-- izleyebilmeli: üretim cevabı satır kimliğini taşır, durum sorgusu kodu
-- hiçbir zaman geri vermez.
v_islem := (v_json ->> 'id')::uuid;
if v_islem is null then
  raise exception 'FAIL 57c: kod_uret satır kimliğini döndürmedi';
end if;
select public.kamera_kod_durum(v_islem) into v_json;
if v_json ->> 'durum' <> 'BEKLIYOR' then
  raise exception 'FAIL 57c: yeni kodun durumu BEKLIYOR değil (%)', v_json ->> 'durum';
end if;
if v_json ? 'kod' or v_json::text like '%' || replace(v_txt, '-', '') || '%' then
  raise exception 'FAIL 57c: durum sorgusu kodu geri verdi';
end if;
select public.kamera_kod_durum(gen_random_uuid()) into v_json;
if v_json ->> 'durum' <> 'YOK' then
  raise exception 'FAIL 57c: olmayan kodun durumu YOK değil (%)', v_json ->> 'durum';
end if;
perform pg_temp.logout();

-- Personel eşleştirilmiş kamerayı da GÖREMEZ.
perform pg_temp.login(u_personel);
if exists (select 1 from public.kamera_cihazlari) then
  raise exception 'FAIL 57c: personel kamera listesini görebiliyor';
end if;
perform pg_temp.logout();

-- Küçük harf ve boşlukla gelen kod da çalışmalı: kod telefonda okunuyor.
perform pg_temp.kamera();
select public.kamera_eslestir(' ' || lower(v_txt) || ' ') into v_json;
perform pg_temp.logout();

v_id  := (v_json ->> 'cihaz')::uuid;
v_txt2 := v_json ->> 'gizli';
if v_json ->> 'yon' <> 'CIKIS' then
  raise exception 'FAIL 57c: şerit taşınmadı (%)', v_json ->> 'yon';
end if;
if length(v_txt2) <> 64 then
  raise exception 'FAIL 57c: gizli anahtar 64 karakter değil (%)', length(v_txt2);
end if;
if not exists (select 1 from public.kamera_cihazlari
                where id = v_id
                  and gizli_hash = encode(sha256(convert_to(v_txt2, 'UTF8')), 'hex')) then
  raise exception 'FAIL 57c: saklanan hash dönen anahtarla uyuşmuyor';
end if;
-- Düz metin hiçbir kolonda durmamalı.
if exists (select 1 from public.kamera_cihazlari where gizli_hash = v_txt2) then
  raise exception 'FAIL 57c: gizli anahtar düz metin saklanmış';
end if;
if not exists (select 1 from public.kamera_eslestirme
                where kullanildi_at is not null and cihaz_id = v_id) then
  raise exception 'FAIL 57c: kod kullanıldı olarak işaretlenmedi';
end if;
perform pg_temp.login(u_yonetici);
select public.kamera_kod_durum(v_islem) into v_json;
perform pg_temp.logout();
if v_json ->> 'durum' <> 'KULLANILDI' or (v_json ->> 'cihaz_id')::uuid is distinct from v_id then
  raise exception 'FAIL 57c: kullanılan kodun durumu cihazı göstermiyor (%)', v_json;
end if;

-- (d) Kod süreli ve tek bir kameraya bağlı. İkisi de olmazsa sızan bir kod
--     kalıcı bir arka kapıdır.
--
--     Kamera HİÇ bağlanmadıysa aynı kod yeniden denenebilir: cevabı yolda
--     kaybolan bir kurulum, yoksa hem kodu harcar hem de anahtarını kimsenin
--     bilmediği ölü bir cihaz satırı bırakırdı. Yeniden deneme YENİ cihaz
--     açmaz; aynı cihazın anahtarını değiştirir ve eskisini öldürür.
update public.otopark_ayarlari set kamera_kalp_atisi = null where id = 1;
perform pg_temp.kamera();
select public.kamera_eslestir(v_txt) into v_json;
perform pg_temp.logout();
if (v_json ->> 'cihaz')::uuid is distinct from v_id then
  raise exception 'FAIL 57d: yeniden deneme başka bir cihaz açtı';
end if;
if (select count(*) from public.kamera_cihazlari) <> 1 then
  raise exception 'FAIL 57d: yeniden deneme ikinci bir cihaz satırı bıraktı';
end if;
v_txt3 := v_json ->> 'gizli';
if length(v_txt3) <> 64 or v_txt3 = v_txt2 then
  raise exception 'FAIL 57d: yeniden deneme yeni bir anahtar üretmedi';
end if;
if exists (select 1 from public.kamera_cihazlari
            where gizli_hash = encode(sha256(convert_to(v_txt2, 'UTF8')), 'hex')) then
  raise exception 'FAIL 57d: yeniden denemeden sonra eski anahtar hâlâ geçerli';
end if;
if not exists (select 1 from public.kamera_cihazlari
                where id = v_id
                  and gizli_hash = encode(sha256(convert_to(v_txt3, 'UTF8')), 'hex')) then
  raise exception 'FAIL 57d: yeni anahtarın hash''i saklanmadı';
end if;

-- Süresi dolunca yeniden deneme de biter — hiç bağlanmamış olsa bile.
update public.kamera_eslestirme set bitis = now() - interval '1 minute'
 where cihaz_id = v_id;
perform pg_temp.kamera();
begin
  perform public.kamera_eslestir(v_txt);
  raise exception 'FAIL 57d: süresi dolmuş kodla yeniden eşleştirilebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlstate <> 'KE001' or lower(sqlerrm) not like '%süresi dolmuş%' then
    raise exception 'FAIL 57d: beklenmeyen hata (yeniden, süre): % %', sqlstate, sqlerrm;
  end if;
end;
perform pg_temp.logout();
update public.kamera_eslestirme set bitis = now() + interval '10 minutes'
 where cihaz_id = v_id;

-- Kamera bir kez bağlandıysa kod ÖLÜDÜR: çalışan bir kameranın anahtarı
-- eski bir kodla değiştirilememeli. Cihaz kalp atışı GENEL damgaya da
-- dokunmamalı — o damga yalnızca elle kurulmuş köprülerindir.
perform pg_temp.kamera();
perform public.kamera_kalp_cihaz(v_id);
begin
  perform public.kamera_eslestir(v_txt);
  raise exception 'FAIL 57d: bağlanmış kameranın kodu ikinci kez kullanılabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlstate <> 'KE001' or lower(sqlerrm) not like '%zaten kullanılmış%' then
    raise exception 'FAIL 57d: beklenmeyen hata (tekrar): % %', sqlstate, sqlerrm;
  end if;
end;
perform pg_temp.logout();
if not exists (select 1 from public.kamera_cihazlari
                where id = v_id and son_gorulme is not null
                  and gizli_hash = encode(sha256(convert_to(v_txt3, 'UTF8')), 'hex')) then
  raise exception 'FAIL 57d: reddedilen deneme çalışan kameranın anahtarını değiştirdi';
end if;
if (select kamera_kalp_atisi from public.otopark_ayarlari where id = 1) is not null then
  raise exception 'FAIL 57d: cihaz kalp atışı genel damgayı da vurdu';
end if;

perform pg_temp.login(u_yonetici);
select public.kamera_kod_uret('Süresi dolacak', 'GIRIS') into v_json;
v_txt := v_json ->> 'kod';
v_islem := (v_json ->> 'id')::uuid;
perform pg_temp.logout();
update public.kamera_eslestirme set bitis = now() - interval '1 minute'
 where kullanildi_at is null;
perform pg_temp.login(u_yonetici);
select public.kamera_kod_durum(v_islem) into v_json;
perform pg_temp.logout();
if v_json ->> 'durum' <> 'DOLDU' then
  raise exception 'FAIL 57d: süresi dolan kodun durumu DOLDU değil (%)', v_json ->> 'durum';
end if;
perform pg_temp.kamera();
begin
  perform public.kamera_eslestir(v_txt);
  raise exception 'FAIL 57d: süresi dolmuş kod kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlstate <> 'KE001' or lower(sqlerrm) not like '%süresi dolmuş%' then
    raise exception 'FAIL 57d: beklenmeyen hata (süre): % %', sqlstate, sqlerrm;
  end if;
end;
-- Var olmayan kod ve yanlış uzunluk AYNI mesajı vermeli: fark söylemek,
-- kod deneyen birine bilgi vermektir.
begin
  perform public.kamera_eslestir('ZZZZZ-ZZZZZ');
  raise exception 'FAIL 57d: olmayan kod kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlstate <> 'KE001' or lower(sqlerrm) not like '%geçersiz%' then
    raise exception 'FAIL 57d: beklenmeyen hata (olmayan): % %', sqlstate, sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (e) ASIL DÜZELTME. Eskiden tek bir genel kamera_kalp_atisi vardı ve iki
--     şeritli bir otoparkta giriş köprüsü onu taze tutuyordu — çıkış
--     kamerası ölünce HİÇBİR uyarı çıkmıyordu.
delete from public.notifications where tur = 'KAMERA';
select kamera_kalp_esik_dk into v_n from public.otopark_ayarlari where id = 1;
-- 073: kamera girişi kapalıyken "haber yok" uyarısı yok. Bu bölüm AÇIK kamerayı
-- sınar; canlı ayar ne olursa olsun açılır (geri alınır).
update public.otopark_ayarlari set kamera_aktif = true where id = 1;

-- İki kamera: biri ölü, biri canlı. Yalnızca ölü olan uyarı üretmeli.
update public.kamera_cihazlari
   set son_gorulme = now() - make_interval(mins => v_n + 10) where id = v_id;
insert into public.kamera_cihazlari (ad, yon, gizli_hash, son_gorulme)
values ('Giriş bariyeri', 'GIRIS', repeat('a', 64), now())
returning id into v_id2;

perform public.run_kamera_kontrol();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and profile_id = u_yonetici
       and link = '/yonetim/kameralar?c=' || v_id::text) <> 1 then
  raise exception 'FAIL 57e: ölü kamera için tam olarak bir uyarı üretilmedi';
end if;
if exists (select 1 from public.notifications
            where tur = 'KAMERA' and link = '/yonetim/kameralar?c=' || v_id2::text) then
  raise exception 'FAIL 57e: canlı kamera için uyarı üretildi';
end if;

-- Aynı saat içinde tekrar koşmak ikinci uyarı üretmemeli.
perform public.run_kamera_kontrol();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and profile_id = u_yonetici
       and link = '/yonetim/kameralar?c=' || v_id::text) <> 1 then
  raise exception 'FAIL 57e: aynı kamera için uyarı tekrarlandı';
end if;

-- İkinci kamera da ölünce KENDİ uyarısını almalı. Genel "son bir saatte
-- KAMERA bildirimi var mı" tekilleştirmesi burada olsaydı, ilk ölen ikinci
-- ölenin uyarısını susturur ve düzeltilen hata geri gelirdi.
update public.kamera_cihazlari
   set son_gorulme = now() - make_interval(mins => v_n + 10) where id = v_id2;
perform public.run_kamera_kontrol();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and profile_id = u_yonetici
       and link = '/yonetim/kameralar?c=' || v_id2::text) <> 1 then
  raise exception 'FAIL 57e: ikinci ölü kamera susturuldu — 036 öncesi hata geri geldi';
end if;

-- Devre dışı bırakılan kamera uyarı üretmemeli: tamire giden bir kamera
-- için saatte bir uyarı almanın tek alternatifi onu SİLMEK olmamalı.
delete from public.notifications where tur = 'KAMERA';
perform pg_temp.login(u_yonetici);
perform public.kamera_cihaz_durum(v_id, false);
perform public.kamera_cihaz_durum(v_id2, false);
perform pg_temp.logout();
perform public.run_kamera_kontrol();
if exists (select 1 from public.notifications where tur = 'KAMERA') then
  raise exception 'FAIL 57e: devre dışı kamera hâlâ uyarı üretiyor';
end if;

-- Yeniden etkinleştirilen kamera, son_gorulme günler öncesinde kaldı diye
-- ANINDA uyarı üretmemeli: tamirden dönen kamera henüz prize takılmamış
-- olabilir. Bir eşik süresi kadar tanınır, sonra hâlâ sessizse uyarılır.
perform pg_temp.login(u_yonetici);
perform public.kamera_cihaz_durum(v_id, true);
perform pg_temp.logout();
perform public.run_kamera_kontrol();
if exists (select 1 from public.notifications where tur = 'KAMERA') then
  raise exception 'FAIL 57e: yeniden etkinleştirilen kamera anında uyarı üretti';
end if;
if (select son_gorulme from public.kamera_cihazlari where id = v_id)
     is distinct from now() - make_interval(mins => v_n + 10) then
  raise exception 'FAIL 57e: etkinleştirme son_gorulme değerini değiştirdi';
end if;
update public.kamera_cihazlari
   set durum_at = now() - make_interval(mins => v_n + 10) where id = v_id;
perform public.run_kamera_kontrol();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and profile_id = u_yonetici
       and link = '/yonetim/kameralar?c=' || v_id::text) <> 1 then
  raise exception 'FAIL 57e: tanınan süre dolduğu hâlde sessiz kamera uyarı üretmedi';
end if;

-- (f) KARMA KURULUM. Bir şerit eşleştirilmiş, öbürü hâlâ ortak anahtarla
--     (env) çalışıyor olabilir. Eşleştirilmiş kamera canlıyken elle kurulmuş
--     köprü ölürse uyarı ÇIKMALI — yoksa 036'nın düzelttiği hata öbür
--     şeritte geri gelir. Cihaz kalp atışı genel damgayı tazelememeli.
delete from public.notifications where tur = 'KAMERA';
update public.kamera_cihazlari set aktif = true, son_gorulme = now(), durum_at = null;
v_ts := now() - make_interval(mins => v_n + 10);
update public.otopark_ayarlari set kamera_kalp_atisi = v_ts where id = 1;
perform public.kamera_kalp_cihaz(v_id2);
if (select kamera_kalp_atisi from public.otopark_ayarlari where id = 1)
     is distinct from v_ts then
  raise exception 'FAIL 57f: eşleştirilmiş kamera elle kurulmuş köprünün damgasını tazeledi';
end if;
perform public.run_kamera_kontrol();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and profile_id = u_yonetici
       and link = '/yonetim/kameralar') <> 1 then
  raise exception 'FAIL 57f: canlı bir eşleştirilmiş kamera, ölü elle kurulmuş köprüyü susturdu';
end if;
if exists (select 1 from public.notifications
            where tur = 'KAMERA' and link like '/yonetim/kameralar?c=%') then
  raise exception 'FAIL 57f: canlı eşleştirilmiş kameralar için uyarı üretildi';
end if;
perform public.run_kamera_kontrol();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and profile_id = u_yonetici
       and link = '/yonetim/kameralar') <> 1 then
  raise exception 'FAIL 57f: elle kurulmuş köprü uyarısı aynı saat içinde tekrarlandı';
end if;

-- Tamamen eşleştirmeye geçen otopark eski nöbeti KAPATABİLMELİ; yoksa
-- bayatlamış damga sonsuza dek saatte bir uyarı üretir.
delete from public.notifications where tur = 'KAMERA';
perform pg_temp.login(u_yonetici);
perform public.kamera_eski_kopru_unut();
perform pg_temp.logout();
if (select kamera_kalp_atisi from public.otopark_ayarlari where id = 1) is not null then
  raise exception 'FAIL 57f: eski köprü nöbeti kapanmadı';
end if;
perform public.run_kamera_kontrol();
if exists (select 1 from public.notifications where tur = 'KAMERA') then
  raise exception 'FAIL 57f: kapatılan eski köprü nöbeti hâlâ uyarı üretiyor';
end if;

-- Hiç cihaz yokken genel kontrol HÂLÂ çalışmalı: env anahtarıyla elle
-- kurulmuş köprülerin tek koruması odur.
delete from public.kamera_cihazlari;
update public.otopark_ayarlari set kamera_kalp_atisi = v_ts where id = 1;
perform public.run_kamera_kontrol();
if not exists (select 1 from public.notifications
                where tur = 'KAMERA' and link = '/yonetim/kameralar') then
  raise exception 'FAIL 57f: cihazsız kurulumda genel kamera kontrolü çalışmadı';
end if;

raise notice 'PASS 57: kamera eşleştirme tek kullanımlık, anahtar hash''li, nöbet şerit başına';

-- =====================================================================
-- 58  Tek kapı (037)
--     Giriş ve çıkış AYNI kapıdan. Şerit yönü söylemediği için kararı
--     sunucu bilet durumundan verir: açık bileti olan araç çıkıyordur,
--     olmayan giriyordur. Emin olunamayan olay TAHMİN EDİLMEZ, insana
--     gider. Kamera burada da bilet kapatmaz ve para almaz.
--
--     Bu dosya tek transaction'da koşar, yani now() SABİTTİR: az önce
--     açılan biletin yaşı sıfırdır. "Eskimiş" durumlar created_at geri
--     çekilerek kurulur (değişmezlik guard'ı AÇIK bileti serbest bırakır).
-- =====================================================================

perform pg_temp.logout();

-- (a) Sınır grant'ta: kimlik basmıyor ama bilet AÇIYOR, istemciye kapalı.
if has_function_privilege('anon',
     'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)', 'execute')
   or has_function_privilege('authenticated',
     'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)', 'execute') then
  raise exception 'FAIL 58a: kamera_tek_kapi istemciye açık';
end if;
if not has_function_privilege('service_role',
     'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)', 'execute') then
  raise exception 'FAIL 58a: webhook kamera_tek_kapi çağıramıyor';
end if;
foreach v_txt in array array['anon', 'authenticated', 'service_role'] loop
  if has_function_privilege(v_txt, 'public.plaka_yakin(text, text)', 'execute') then
    raise exception 'FAIL 58a: plaka_yakin % rolüne açık', v_txt;
  end if;
end loop;

-- Grant bir gün yanlışlıkla açılırsa gövdedeki guard da tutmalı: JWT taşıyan
-- çağıran (yani bir insan) kameranın zamanını kullanarak bilet açamamalı.
perform set_config('request.jwt.claims',
  json_build_object('sub', u_personel::text, 'role', 'authenticated')::text, true);
begin
  perform public.kamera_tek_kapi('ZZ58TK001', gen_random_uuid(), now());
  raise exception 'FAIL 58a: JWT taşıyan çağıran tek kapı kararını tetikleyebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 58a: beklenmeyen hata (jwt): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (b) "Bir karakter fark": tek değişim ya da tek eksik/fazla karakter.
--     İki fark YAKIN DEĞİLDİR; kısa plakalarda kural hiç çalışmaz (dört
--     karakterde bir fark, plakanın dörtte biridir).
if public.plaka_yakin('34ABC123', '34ABC123') then
  raise exception 'FAIL 58b: aynı plaka "yakın" sayıldı';
end if;
if not public.plaka_yakin('34ABC123', '34ABC128') then
  raise exception 'FAIL 58b: tek karakter değişimi yakalanmadı';
end if;
if not public.plaka_yakin('34ABC123', '34ABC12')
   or not public.plaka_yakin('34ABC12', '34ABC123') then
  raise exception 'FAIL 58b: düşen/eklenen tek karakter yakalanmadı';
end if;
if not public.plaka_yakin('34ABC123', '4ABC123')
   or not public.plaka_yakin('34ABC123', '34ABC1234') then
  raise exception 'FAIL 58b: baştan düşen ya da sona eklenen karakter yakalanmadı';
end if;
if public.plaka_yakin('34ABC123', '34ABD128') then
  raise exception 'FAIL 58b: iki fark "yakın" sayıldı';
end if;
if public.plaka_yakin('34ABC123', '43ABC123') then
  raise exception 'FAIL 58b: yer değiştiren iki karakter "yakın" sayıldı';
end if;
if public.plaka_yakin('34ABC123', '34ABC1') then
  raise exception 'FAIL 58b: iki karakter eksik "yakın" sayıldı';
end if;
if public.plaka_yakin('AB12', 'AB13') then
  raise exception 'FAIL 58b: kısa plakada yakınlık kuralı çalıştı';
end if;
if public.plaka_yakin(null, '34ABC123') or public.plaka_yakin('34ABC123', null) then
  raise exception 'FAIL 58b: null plaka "yakın" sayıldı';
end if;

-- (c) İki süre ayardan okunur. Giriş süresi 2 dakikanın altına inememeli
--     (068, sahip 2026-11-15; önceden 3): köprü, kadrajda bir şey kıpırdayıp
--     durulunca aynı aracı yeniden gönderebilir; süre kısa olursa kapıda
--     oyalanan, az önce girmiş araç "çıkıyor" diye işaretlenir.
select tek_kapi_giris_yoksay_dk, tek_kapi_cikis_yoksay_dk
  into v_n, v_n2 from public.otopark_ayarlari where id = 1;
if v_n is null or v_n2 is null then
  raise exception 'FAIL 58c: tek kapı süreleri tanımlı değil';
end if;
begin
  update public.otopark_ayarlari set tek_kapi_giris_yoksay_dk = 1 where id = 1;
  raise exception 'FAIL 58c: giriş yok sayma süresi 2 dakikanın altına indi';
exception when check_violation then
  null;
end;
begin
  update public.otopark_ayarlari set tek_kapi_cikis_yoksay_dk = 0 where id = 1;
  raise exception 'FAIL 58c: çıkış yok sayma süresi sıfıra indi';
exception when check_violation then
  null;
end;

select count(*) into v_bigint from public.tahsilatlar;

-- (d) Açık bileti olmayan plaka GİRİYORDUR.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58TK001', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'GIRIS' then
  raise exception 'FAIL 58d: yeni araç için karar GIRIS değil (%)', v_json;
end if;
v_bilet := (v_json ->> 'bilet_id')::uuid;
if not exists (select 1 from public.biletler
                where id = v_bilet and plaka = 'ZZ58TK001' and durum = 'ACIK'
                  and giris_kaynak = 'KAMERA' and cikis_bekliyor_at is null) then
  raise exception 'FAIL 58d: giriş bileti beklenen hâlde açılmadı';
end if;

-- (e) Aynı olay yeniden gelirse (köprü cevabı göremedi) AYNI bilet döner.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58TK001', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'GIRIS' or (v_json ->> 'bilet_id')::uuid is distinct from v_bilet then
  raise exception 'FAIL 58e: tekrar oynatılan giriş aynı bileti döndürmedi (%)', v_json;
end if;

-- (f) Araç hâlâ kameranın önünde: yeni bir olay ÇIKIŞ sayılmamalı.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58TK001', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'YOKSAY' then
  raise exception 'FAIL 58f: az önce giren araç yok sayılmadı (%)', v_json;
end if;
if (select cikis_bekliyor_at from public.biletler where id = v_bilet) is not null then
  raise exception 'FAIL 58f: az önce giren araç "kapıda" diye işaretlendi';
end if;

-- (g) Aynı aracın İKİNCİ okuması bir karakter farklı çıktı: ne yeni bilet,
--     ne de çözülmemiş kayıt — az önce giren araçtır.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58TK007', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'YOKSAY' then
  raise exception 'FAIL 58g: az önce girenin yanlış okunmuş hâli yok sayılmadı (%)', v_json;
end if;
if exists (select 1 from public.biletler where plaka = 'ZZ58TK007')
   or exists (select 1 from public.istisnalar where plaka = 'ZZ58TK007') then
  raise exception 'FAIL 58g: yanlış okuma hayalet bilet ya da kayıt üretti';
end if;

-- Bilet eskitiliyor: araç artık "az önce girmiş" değil.
update public.biletler
   set created_at = now() - make_interval(mins => v_n + 1) where id = v_bilet;

-- (h) ASIL KURAL. İçerideki bir araca bir karakter uzak plaka: çıkan aracın
--     yanlış okunması da olabilir, benzer plakalı YENİ bir araç da. Tahmin
--     edilmez — bilet açılmaz, mevcut bilet işaretlenmez, insana gider.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58TK007', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'ISTISNA' then
  raise exception 'FAIL 58h: belirsiz okuma insana gitmedi (%)', v_json;
end if;
if exists (select 1 from public.biletler where plaka = 'ZZ58TK007') then
  raise exception 'FAIL 58h: belirsiz okuma için bilet açıldı';
end if;
if (select cikis_bekliyor_at from public.biletler where id = v_bilet) is not null then
  raise exception 'FAIL 58h: belirsiz okuma benzer plakalı bileti "kapıda" yaptı';
end if;
if (select count(*) from public.istisnalar
     where islem_id = v_islem and tur::text = 'YON_BELIRSIZ' and yon = 'ORTAK'
       and plaka = 'ZZ58TK007' and aday_bilet_ids = array[v_bilet]) <> 1 then
  raise exception 'FAIL 58h: YON_BELIRSIZ kaydı adayıyla birlikte yazılmadı';
end if;
-- Tekrar oynatma ikinci kayıt üretmemeli.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58TK007', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'ISTISNA'
   or (select count(*) from public.istisnalar where plaka = 'ZZ58TK007') <> 1 then
  raise exception 'FAIL 58h: tekrar oynatılan belirsiz okuma ikinci kayıt üretti';
end if;

-- (i) Açık bileti olan plaka ÇIKIYORDUR. 054'ten beri (sahip, 2026-11-10)
--     kamera bileti KAPATIR — olayın saatinde, ÖDEMESİZ: tek kuruş hareket
--     etmez, tahsilatı yine insan yapar ("Ödeme topla", PASS 75).
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58TK001', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'CIKIS' or (v_json ->> 'bilet_id')::uuid is distinct from v_bilet then
  raise exception 'FAIL 58i: içerideki araç için karar CIKIS değil (%)', v_json;
end if;
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'KAPALI' and cikis_at = now()
                  and cikis_kaynak = 'KAMERA' and cikis_bekliyor_at = now()
                  and tahsil_kurus = 0 and odeme_yontemi is null) then
  raise exception 'FAIL 58i: çıkış olayı bileti olayın saatinde ödemesiz kapatmadı';
end if;
if (select count(*) from public.biletler where plaka = 'ZZ58TK001') <> 1 then
  raise exception 'FAIL 58i: çıkış olayı ikinci bilet açtı';
end if;
select count(*) into v_bigint2 from public.tahsilatlar;
if v_bigint2 <> v_bigint then
  raise exception 'FAIL 58i: kamera olayı tahsilat yazdı';
end if;

-- (j) Bilet kapandı (burada iptal — kapanış anı da now()), araç kapıdan
--     çıkarken kameraya bir kez daha yakalandı: YENİ BİLET AÇILMAMALI.
--     Bu mod tam olarak bu hata için var.
perform pg_temp.login(u_yonetici);
perform public.bilet_iptal(v_bilet, 'Test — tek kapı');
perform pg_temp.logout();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58TK001', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'YOKSAY' then
  raise exception 'FAIL 58j: az önce kapanan araç yok sayılmadı (%)', v_json;
end if;
if exists (select 1 from public.biletler where plaka = 'ZZ58TK001' and durum = 'ACIK') then
  raise exception 'FAIL 58j: ödeyip çıkan araca yeniden bilet açıldı';
end if;

-- (k) Aynı araç çıkarken bir karakter yanlış okundu: yine bilet yok.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58TK007', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'YOKSAY' then
  raise exception 'FAIL 58k: az önce kapananın yanlış okunmuş hâli yok sayılmadı (%)', v_json;
end if;
if exists (select 1 from public.biletler where plaka = 'ZZ58TK007') then
  raise exception 'FAIL 58k: çıkan aracın yanlış okuması hayalet bilet açtı';
end if;

-- (l) Yok sayma GEÇİCİDİR: bir saat önce çıkmış müşteri geri geldiyse bu
--     yeni bir park süresidir ve bileti açılmalıdır.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum,
                             iptal_sebep, iptal_at, created_at)
select gen_random_uuid(), 'ZZ58TK500', now() - interval '2 hours', t.id, 'IPTAL',
       'Test — eski kayıt', now() - interval '1 hour', now() - interval '2 hours'
  from public.tarifeler t order by t.id limit 1;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58TK500', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'GIRIS'
   or not exists (select 1 from public.biletler
                   where plaka = 'ZZ58TK500' and durum = 'ACIK') then
  raise exception 'FAIL 58l: bir saat önce çıkan araç geri gelince bilet açılmadı (%)', v_json;
end if;

-- (m) Saat kuralları değişmedi: bayat ve ileri tarihli olay bilet açmaz.
--     Plakalar yukarıdakilerden BİLEREK uzak: bir karakter yakın olsalardı
--     az önce açılan ZZ58TK500 yüzünden yok sayılır, saat kuralına hiç
--     varmazlardı ve test yanlış sebepten geçerdi.
select kamera_gecikme_limiti_dk into v_n2 from public.otopark_ayarlari where id = 1;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58BYT77', gen_random_uuid(),
         now() - make_interval(mins => v_n2 + 60)) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'ISTISNA' or exists (select 1 from public.biletler where plaka = 'ZZ58BYT77') then
  raise exception 'FAIL 58m: bayat olay bilet açtı ya da işaretlenmedi (%)', v_json;
end if;
if not exists (select 1 from public.istisnalar
                where plaka = 'ZZ58BYT77' and tur::text = 'BAYAT') then
  raise exception 'FAIL 58m: bayat olay için BAYAT kaydı yok';
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58GLC33', gen_random_uuid(),
         now() + interval '1 hour') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'ISTISNA' or exists (select 1 from public.biletler where plaka = 'ZZ58GLC33') then
  raise exception 'FAIL 58m: ileri tarihli olay bilet açtı ya da işaretlenmedi (%)', v_json;
end if;
if not exists (select 1 from public.istisnalar
                where plaka = 'ZZ58GLC33' and tur::text = 'GELECEK') then
  raise exception 'FAIL 58m: ileri tarihli olay için GELECEK kaydı yok';
end if;

-- Zaman damgasız ve geçersiz plakalı olay reddedilir, sessizce yutulmaz.
perform pg_temp.kamera();
begin
  perform public.kamera_tek_kapi('ZZ58TK902', gen_random_uuid(), null);
  raise exception 'FAIL 58m: zaman damgasız olay kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.kamera_tek_kapi('!', gen_random_uuid(), now());
  raise exception 'FAIL 58m: geçersiz plaka kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();

-- (n) Eşleştirme üçüncü şeridi taşır; anlamsız şerit hâlâ reddedilir.
--     Bekleyen kodlar temizleniyor: kod_uret en fazla 10 bekleyen koda izin
--     verir ve bu adım, PASS 57'den ya da canlıdan kalanlar yüzünden değil
--     kendi kuralı yüzünden geçmeli ya da kalmalı. (Rollback geri getirir.)
delete from public.kamera_eslestirme where kullanildi_at is null;
perform pg_temp.login(u_yonetici);
begin
  perform public.kamera_kod_uret('Bozuk', 'SAGA');
  raise exception 'FAIL 58n: anlamsız şerit kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%ORTAK%' then
    raise exception 'FAIL 58n: şerit reddi ORTAK seçeneğini söylemiyor: %', sqlerrm;
  end if;
end;
select public.kamera_kod_uret('Tek kapı kamerası', 'ortak') into v_json;
perform pg_temp.logout();
v_txt := v_json ->> 'kod';
perform pg_temp.kamera();
select public.kamera_eslestir(v_txt) into v_json;
perform pg_temp.logout();
v_id := (v_json ->> 'cihaz')::uuid;
if v_json ->> 'yon' <> 'ORTAK'
   or not exists (select 1 from public.kamera_cihazlari where id = v_id and yon = 'ORTAK') then
  raise exception 'FAIL 58n: ORTAK şeridi eşleştirmede taşınmadı (%)', v_json ->> 'yon';
end if;

-- (o) Tek kapı kamerası ölürse hem girişler hem çıkışlar durur; uyarı bunu
--     söylemeli — "Girişler" demek yarısını saklamak olurdu.
delete from public.notifications where tur = 'KAMERA';
select kamera_kalp_esik_dk into v_n from public.otopark_ayarlari where id = 1;
update public.kamera_cihazlari
   set son_gorulme = now() - make_interval(mins => v_n + 10) where id = v_id;
perform public.run_kamera_kontrol();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and profile_id = u_yonetici
       and link = '/yonetim/kameralar?c=' || v_id::text
       and govde like '%Girişler ve çıkışlar%') <> 1 then
  raise exception 'FAIL 58o: tek kapı kamerası uyarısı girişleri ve çıkışları birlikte söylemiyor';
end if;

raise notice 'PASS 58: tek kapıda yön bilet durumundan, belirsiz okuma insana, para yine insanda';

-- =====================================================================
-- 59  Yanlış "Kapıda" işareti kapıdaki personel tarafından kaldırılır (038)
--     Kamera bir aracı çıkıyor sandığında `cikis_bekliyor_at` damgalanır ve
--     bilet kapanana kadar öyle kalırdı. Kaldırmak para değildir, ama bileti
--     değiştirir: yalnızca aktif personel, yalnızca AÇIK bilette, izi kalır.
-- =====================================================================

perform pg_temp.logout();
if not exists (select 1 from public.profiles
                where id = u_personel and rol = 'PERSONEL' and durum = 'ACTIVE') then
  raise exception 'FAIL 59: fixture — u_personel aktif bir Personel değil';
end if;

-- Açık bilet, damgalı. 054'ten beri kameranın çıkışı bileti KAPATIR (PASS
-- 75), yani açık bir bilette damga artık yalnızca eski kayıtlarda bulunur:
-- fixture onu doğrudan basar. Damgayı kaldıran 038 fonksiyonu veritabanında
-- duruyor ve sınanmaya devam ediyor.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
select gen_random_uuid(), 'ZZ59KPD01', now() - interval '1 hour', t.id, 'ACIK'
  from public.tarifeler t where t.gecerli_bitis is null order by t.id limit 1
returning id into v_bilet;
update public.biletler set cikis_bekliyor_at = now() where id = v_bilet;
select cikis_bekliyor_at into v_ts from public.biletler where id = v_bilet;
if v_ts is null then
  raise exception 'FAIL 59: fixture — kamera çıkış olayı bileti damgalamadı';
end if;

-- (a) Rolü olmayan ve devre dışı kullanıcı kaldıramaz.
foreach v_id in array array[u_pending, u_disabled] loop
  perform pg_temp.login(v_id);
  begin
    perform public.bilet_kapida_temizle(v_bilet);
    raise exception 'FAIL 59a: rolsüz/devre dışı kullanıcı kapıda işaretini kaldırdı';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like '%Yetkiniz yok%' then
      raise exception 'FAIL 59a: beklenmeyen hata: %', sqlerrm;
    end if;
  end;
  perform pg_temp.logout();
end loop;
if (select cikis_bekliyor_at from public.biletler where id = v_bilet) is distinct from v_ts then
  raise exception 'FAIL 59a: reddedilen çağrı damgayı değiştirdi';
end if;

-- (b) Kapıdaki personel kaldırır; bilet açık kalır, iz yazılır.
perform pg_temp.login(u_personel);
select public.bilet_kapida_temizle(v_bilet) into v_bool;
perform pg_temp.logout();
if v_bool is distinct from true then
  raise exception 'FAIL 59b: kaldırma true dönmedi (%)', v_bool;
end if;
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'ACIK' and cikis_bekliyor_at is null) then
  raise exception 'FAIL 59b: damga kaldırılmadı ya da bilet açık kalmadı';
end if;
if (select count(*) from public.audit_log
     where action = 'bilet_kapida_temizlendi' and row_id = v_bilet
       and actor = u_personel and (detay ->> 'eski')::timestamptz = v_ts) <> 1 then
  raise exception 'FAIL 59b: kaldırma audit_log''a eski damgasıyla yazılmadı';
end if;

-- (c) İkinci basış zararsız: false döner, ikinci iz yazılmaz.
perform pg_temp.login(u_personel);
select public.bilet_kapida_temizle(v_bilet) into v_bool;
perform pg_temp.logout();
if v_bool is distinct from false then
  raise exception 'FAIL 59c: işaretsiz bilette true döndü (%)', v_bool;
end if;
if (select count(*) from public.audit_log
     where action = 'bilet_kapida_temizlendi' and row_id = v_bilet) <> 1 then
  raise exception 'FAIL 59c: işaretsiz bilette ikinci iz yazıldı';
end if;

-- (d) Kapanmış bilet: damga dursa bile dokunulmaz.
update public.biletler set cikis_bekliyor_at = now() where id = v_bilet;
perform pg_temp.login(u_yonetici);
perform public.bilet_iptal(v_bilet, 'Test — kapıda işareti');
perform pg_temp.logout();
select cikis_bekliyor_at into v_ts2 from public.biletler where id = v_bilet;
if v_ts2 is null then
  raise exception 'FAIL 59d: fixture — iptal öncesi bilet yeniden damgalanmadı';
end if;
perform pg_temp.login(u_personel);
begin
  perform public.bilet_kapida_temizle(v_bilet);
  raise exception 'FAIL 59d: kapanmış biletin işareti kaldırıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%açık değil%' then
    raise exception 'FAIL 59d: beklenmeyen hata: %', sqlerrm;
  end if;
end;
-- (e) Olmayan bilet açıkça reddedilir, sessizce "tamam" denmez.
begin
  perform public.bilet_kapida_temizle(gen_random_uuid());
  raise exception 'FAIL 59e: olmayan bilet için hata verilmedi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%bulunamadı%' then
    raise exception 'FAIL 59e: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if (select cikis_bekliyor_at from public.biletler where id = v_bilet) is distinct from v_ts2 then
  raise exception 'FAIL 59d: kapanmış biletin damgası değişti';
end if;

-- (f) Yalnızca giriş yapmış kullanıcıya açık; kamera bu kapıyı kullanamaz.
if not has_function_privilege('authenticated', 'public.bilet_kapida_temizle(uuid)', 'execute') then
  raise exception 'FAIL 59f: bilet_kapida_temizle authenticated rolüne kapalı';
end if;
foreach v_txt in array array['anon', 'service_role'] loop
  if has_function_privilege(v_txt, 'public.bilet_kapida_temizle(uuid)', 'execute') then
    raise exception 'FAIL 59f: bilet_kapida_temizle % rolüne açık', v_txt;
  end if;
end loop;

raise notice 'PASS 59: yanlış kapıda işaretini yalnızca aktif personel, yalnızca açık bilette, izli kaldırıyor';

-- =====================================================================
-- 60  Okunamayan plaka çözülmemiş kayıt olur (039)
--     Model bir araç gördü ama plakasını okuyamadı: eskiden webhook 422
--     dönüyor, bilet açılmıyor ve kimse bunu bilmiyordu — giriş kapısından
--     geçen araç sessizce kayboluyordu. Artık giriş ve tek kapı şeridinde
--     bir "OKUNAMADI" kaydı yazılır ve Yöneticiye her zamanki gibi bildirilir.
--     Çıkış şeridi kayıt yazmaz: orada para zaten insanda.
-- =====================================================================

perform pg_temp.logout();

-- Bildirim sayımları u_yonetici'nin bu iki türü SUSTURMAMIŞ olmasına dayanır
-- (notify_yonetici notif_prefs'e bakar). Susturulmuşsa test yanlış sebepten
-- kalırdı; açıkça söylensin.
if not exists (select 1 from public.profiles
                where id = u_yonetici and rol = 'YONETICI' and durum = 'ACTIVE'
                  and coalesce(notif_prefs ->> 'ISTISNA', 'true') <> 'false'
                  and coalesce(notif_prefs ->> 'KAMERA', 'true') <> 'false') then
  raise exception 'FAIL 60: fixture — u_yonetici aktif Yönetici değil ya da ISTISNA/KAMERA bildirimlerini susturmuş';
end if;

-- (a) Sınır grant'ta: yalnızca kamera (service_role) çağırır.
if not has_function_privilege('service_role',
     'public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)', 'execute') then
  raise exception 'FAIL 60a: kamera_okunamadi service_role rolüne kapalı';
end if;
foreach v_txt in array array['anon', 'authenticated'] loop
  if has_function_privilege(v_txt,
       'public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)', 'execute') then
    raise exception 'FAIL 60a: kamera_okunamadi % rolüne açık', v_txt;
  end if;
end loop;

-- (b) Giriş şeridinde okunamayan araç: TEK kayıt. Fotoğraf ham yanıtta
--     SAKLANMAZ (her satırı yüzlerce KB yapıyordu). 045'ten beri bildirim
--     HEMEN gitmez: kayıt "bildirim bekliyor" işaretlenir, köprünün yeniden
--     denemeleri bitince (3 dk) hâlâ açıksa herkese gider — bkz. PASS 67.
select count(*) into v_n from public.notifications
 where tur = 'ISTISNA' and profile_id = u_yonetici;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now() - interval '1 minute', '34AB12', 0.62,
         jsonb_build_object('cihaz', 'test-60', 'foto_base64', 'QUJD'))
  into v_id;
perform pg_temp.logout();
if v_id is null or not exists (
     select 1 from public.istisnalar
      where id = v_id and islem_id = v_islem and tur::text = 'OKUNAMADI'
        and yon = 'GIRIS' and plaka is null and kaynak = 'KAMERA'
        and kaynak_zaman = now() - interval '1 minute'
        and ham_yanit ->> 'tahmin' = '34AB12'
        and (ham_yanit ->> 'guven')::numeric = 0.62
        and ham_yanit ->> 'cihaz' = 'test-60'
        and not (ham_yanit ? 'foto_base64')) then
  raise exception 'FAIL 60b: okunamayan araç doğru kaydedilmedi';
end if;
if (select count(*) from public.notifications
     where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n
   or not (select bildirim_bekliyor from public.istisnalar where id = v_id) then
  raise exception 'FAIL 60b: bildirim hemen gitti ya da kayıt "bildirim bekliyor" değil (045)';
end if;

-- (c) Aynı olay yeniden gelirse ikinci kayıt ve bildirim olmaz.
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now(), null, null, null) into v_id2;
perform pg_temp.logout();
if v_id2 is distinct from v_id
   or (select count(*) from public.istisnalar where islem_id = v_islem) <> 1
   or (select count(*) from public.notifications
        where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n then
  raise exception 'FAIL 60c: tekrarlanan olay ikinci kayıt ya da bildirim üretti';
end if;

-- (d) Tek kapı kabul edilir; çıkış şeridi, eksik kimlik ve eksik zaman
--     reddedilir.
perform pg_temp.kamera();
select public.kamera_okunamadi('ORTAK', gen_random_uuid(), now(), null, null, null) into v_id2;
if v_id2 is null or not exists (select 1 from public.istisnalar
                                 where id = v_id2 and yon = 'ORTAK'
                                   and tur::text = 'OKUNAMADI') then
  raise exception 'FAIL 60d: tek kapıda okunamayan araç kaydedilmedi';
end if;
begin
  perform public.kamera_okunamadi('CIKIS', gen_random_uuid(), now(), null, null, null);
  raise exception 'FAIL 60d: çıkış şeridi kayıt yazdı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.kamera_okunamadi('GIRIS', null, now(), null, null, null);
  raise exception 'FAIL 60d: işlem kimliği olmadan kayıt yazıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.kamera_okunamadi('GIRIS', gen_random_uuid(), null, null, null, null);
  raise exception 'FAIL 60d: zaman damgası olmadan kayıt yazıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();

-- (e) Grant bir gün açılırsa gövdedeki guard da tutmalı: JWT taşıyan
--     çağıran (yani bir insan) sahte "okunamadı" kaydı yazamamalı.
perform set_config('request.jwt.claims',
  json_build_object('sub', u_personel::text, 'role', 'authenticated')::text, true);
begin
  perform public.kamera_okunamadi('GIRIS', gen_random_uuid(), now(), null, null, null);
  raise exception 'FAIL 60e: JWT taşıyan çağıran kayıt yazabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 60e: beklenmeyen hata (jwt): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

raise notice 'PASS 60: okunamayan plaka giriş ve tek kapıda çözülmemiş kayıt oluyor, bir kez bildiriliyor';

-- =====================================================================
-- 61  Plaka okuma servisi çöktüğünde haber verilir (039)
--     Anthropic bakiyesi biterse ya da anahtar geçersizleşirse webhook her
--     araçta 502 dönüyordu ve tek iz okuma günlüğündeki bir satırdı. Kalp
--     atışı sürdüğü için "kameradan haber yok" uyarısı da susuyordu: bütün
--     kamera girişleri kimse bilmeden duruyordu. Artık:
--       · her hatada Yöneticiye uyarı — saatte EN FAZLA bir kez;
--       · köprünün SON denemesinde (x-kamera-son-gonderim) giriş ve tek kapı
--         şeridinde araç başına bir "OKUNAMADI" kaydı, araç başına bildirim
--         olmadan (bir arıza yüz bildirim olmasın).
--     Son deneme dışında kayıt YAZILMAZ: kamera_tek_kapi, kaydı olan bir
--     islem_id'yi "ISTISNA TEKRAR" diye kısa keser; ilk hatada yazılan kayıt,
--     başarılı bir yeniden denemenin biletini engellerdi. (h) bunu sınar.
-- =====================================================================

perform pg_temp.logout();

-- (a) Sınır grant'ta: yalnızca kamera (service_role) çağırır.
if not has_function_privilege('service_role',
     'public.kamera_okuma_hatasi(text, uuid, timestamptz, text, boolean, jsonb)', 'execute') then
  raise exception 'FAIL 61a: kamera_okuma_hatasi service_role rolüne kapalı';
end if;
foreach v_txt in array array['anon', 'authenticated'] loop
  if has_function_privilege(v_txt,
       'public.kamera_okuma_hatasi(text, uuid, timestamptz, text, boolean, jsonb)', 'execute') then
    raise exception 'FAIL 61a: kamera_okuma_hatasi % rolüne açık', v_txt;
  end if;
end loop;

-- Canlıdan kalmış bir uyarı bu testin tekilleştirmesini etkilemesin.
-- (Rollback geri getirir.)
delete from public.notifications where tur = 'KAMERA' and baslik = 'Plaka okuma çalışmıyor';
select count(*) into v_n from public.notifications
 where tur = 'ISTISNA' and profile_id = u_yonetici;

-- (b) İlk hata: tek uyarı, son deneme değilse kayıt YOK.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
perform public.kamera_okuma_hatasi('GIRIS', v_islem, now(),
          'Anthropic 400: credit balance is too low', false, null);
perform pg_temp.logout();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and baslik = 'Plaka okuma çalışmıyor'
       and profile_id = u_yonetici and link = '/istisnalar'
       and govde like '%credit balance is too low%'
       and govde like '%Anthropic bakiyesini%') <> 1 then
  raise exception 'FAIL 61b: okuma hatası Yöneticiye tam bir kez bildirilmedi';
end if;
if exists (select 1 from public.istisnalar where islem_id = v_islem) then
  raise exception 'FAIL 61b: son deneme olmayan hata kayıt yazdı';
end if;

-- (c) Aynı saat içinde ikinci ve üçüncü hata yeni uyarı ÜRETMEZ — çıkış
--     şeridindeki hata da (uyarı her şerit için, kayıt yalnızca girişte).
perform pg_temp.kamera();
perform public.kamera_okuma_hatasi('GIRIS', v_islem, now(), 'Anthropic 401', false, null);
perform public.kamera_okuma_hatasi('CIKIS', gen_random_uuid(), now(), 'Anthropic 401', false, null);
perform pg_temp.logout();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and baslik = 'Plaka okuma çalışmıyor'
       and profile_id = u_yonetici) <> 1 then
  raise exception 'FAIL 61c: aynı saat içinde ikinci uyarı gönderildi';
end if;

-- (d) Saat dolunca yeniden uyarır. (Tek transaction'da now() sabit:
--     önceki uyarı geri çekilerek kurulur.)
update public.notifications set created_at = now() - interval '61 minutes'
 where tur = 'KAMERA' and baslik = 'Plaka okuma çalışmıyor';
perform pg_temp.kamera();
perform public.kamera_okuma_hatasi('CIKIS', gen_random_uuid(), now(), 'Anthropic 529', false, null);
perform pg_temp.logout();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and baslik = 'Plaka okuma çalışmıyor'
       and profile_id = u_yonetici) <> 2 then
  raise exception 'FAIL 61d: bir saat sonra uyarı yinelenmedi';
end if;

-- (e) Son denemede giriş şeridi: TEK kayıt, sebebi içinde, araç başına
--     bildirim YOK. Uzun hata metni kısaltılır, fotoğraf saklanmaz.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
perform public.kamera_okuma_hatasi('GIRIS', v_islem, now() - interval '30 seconds',
          'Anthropic 400: ' || repeat('x', 600), true,
          jsonb_build_object('cihaz', 'test-61', 'foto_base64', 'QUJD'));
perform public.kamera_okuma_hatasi('GIRIS', v_islem, now(), 'Anthropic 400', true, null);
perform pg_temp.logout();
if (select count(*) from public.istisnalar
     where islem_id = v_islem and tur::text = 'OKUNAMADI' and yon = 'GIRIS'
       and plaka is null and kaynak = 'KAMERA'
       and kaynak_zaman = now() - interval '30 seconds'
       and ham_yanit ->> 'hata' like 'Anthropic 400: x%'
       and length(ham_yanit ->> 'hata') <= 300
       and ham_yanit ->> 'cihaz' = 'test-61'
       and not (ham_yanit ? 'foto_base64')) <> 1 then
  raise exception 'FAIL 61e: son denemedeki okuma hatası tek ve doğru kayıt olmadı';
end if;
if (select count(*) from public.notifications
     where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n then
  raise exception 'FAIL 61e: okuma hatası kaydı araç başına bildirim üretti';
end if;

-- (f) Son denemede çıkış şeridi kayıt yazmaz.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
perform public.kamera_okuma_hatasi('CIKIS', v_islem, now(), 'Anthropic 401', true, null);
perform pg_temp.logout();
if exists (select 1 from public.istisnalar where islem_id = v_islem) then
  raise exception 'FAIL 61f: çıkış şeridindeki okuma hatası kayıt yazdı';
end if;

-- (g) Anlamsız şerit, eksik kimlik ya da zaman reddedilir; JWT taşıyan
--     çağıran (bir insan) sahte uyarı üretemez.
perform pg_temp.kamera();
begin
  perform public.kamera_okuma_hatasi('SAGA', gen_random_uuid(), now(), 'x', true, null);
  raise exception 'FAIL 61g: anlamsız şerit kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.kamera_okuma_hatasi('GIRIS', null, now(), 'x', true, null);
  raise exception 'FAIL 61g: işlem kimliği olmadan kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.kamera_okuma_hatasi('GIRIS', gen_random_uuid(), null, 'x', true, null);
  raise exception 'FAIL 61g: zaman damgası olmadan kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();
perform set_config('request.jwt.claims',
  json_build_object('sub', u_personel::text, 'role', 'authenticated')::text, true);
begin
  perform public.kamera_okuma_hatasi('GIRIS', gen_random_uuid(), now(), 'x', true, null);
  raise exception 'FAIL 61g: JWT taşıyan çağıran okuma hatası bildirebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 61g: beklenmeyen hata (jwt): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (h) Asıl tuzak: tek kapıda ilk deneme okunamadı (son deneme DEĞİL), sonraki
--     deneme okudu. Aynı islem_id ile tek kapı kararı bilet AÇMALI — erken
--     yazılmış bir kayıt onu "ISTISNA TEKRAR" diye keserdi.
if exists (select 1 from public.biletler where plaka = 'ZZ61TK001' and durum = 'ACIK') then
  raise exception 'FAIL 61h: fixture — ZZ61TK001 zaten içeride';
end if;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
perform public.kamera_okuma_hatasi('ORTAK', v_islem, now(), 'Anthropic 529: overloaded', false, null);
select public.kamera_tek_kapi('ZZ61TK001', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'GIRIS' or (v_json ->> 'bilet_id') is null then
  raise exception 'FAIL 61h: okuma hatasından sonraki başarılı deneme bilet açmadı (%)', v_json;
end if;

raise notice 'PASS 61: okuma servisi çöktüğünde saatte bir uyarı, son denemede araç başına kayıt';

-- =====================================================================
-- 62  Ücretli kamera okumalarına sınır (040)
--     Kameradan gelen her fotoğraf parayla okunur. Webhook'un eski sınırı
--     yalnızca BİLETLERİ sayıyordu; okumaların çoğu bilet açmaz (boş şerit,
--     okunamayan plaka, okuma hatası, her çıkış, her yeniden deneme), yani
--     sınırsızdı: bozulmuş bir köprü ya da sızmış bir kamera anahtarı
--     faturayı istediği kadar büyütebilirdi. Artık webhook her kamera
--     okumasını günlüğe `kaynak = 'KAMERA'` diye yazar, okumadan ÖNCE son
--     1 dakikayı ve 24 saati sayar (sınır sayıları webhook'ta:
--     _shared/serit.ts), sınırın üstünde 429 döner ve Yöneticiye saatte en
--     fazla bir uyarı gider.
--     Bu blok sınırın veritabanı yarısını sınar: sayılan satırlar doğru
--     etiketleniyor, istemci onları ne sahteleyebiliyor ne silebiliyor,
--     uyarı doğru sayıyla saatte bir kez gidiyor ve kamera nöbetçisinin
--     uyarısını susturmuyor.
-- =====================================================================

perform pg_temp.logout();

-- (a) Kolon `kaynak` enum'u, boş olabilir ve VARSAYILANSIZ: telefon okuması
--     (plaka-oku kaynak yazmaz) kameranın sınırına sayılmamalı. Sayım kısmi
--     indeksten okunur.
if not exists (
  select 1 from information_schema.columns c
   where c.table_schema = 'public' and c.table_name = 'plaka_okuma_log'
     and c.column_name = 'kaynak'
     and c.udt_schema = 'public' and c.udt_name = 'kaynak'
     and c.is_nullable = 'YES' and c.column_default is null
) then
  raise exception 'FAIL 62a: plaka_okuma_log.kaynak yok ya da biçimi yanlış (kaynak enum, boş olabilir, varsayılansız)';
end if;
if not exists (
  select 1 from pg_indexes i
   where i.schemaname = 'public' and i.tablename = 'plaka_okuma_log'
     and i.indexdef like '%(created_at DESC)%'
     and i.indexdef like '%WHERE%kaynak%KAMERA%'
) then
  raise exception 'FAIL 62a: kamera okumaları için kısmi indeks yok';
end if;

-- (b) Sınır grant'ta: yalnızca kamera (service_role) çağırır. İstemciye açık
--     olsaydı herkes sahte "sınır aşıldı" uyarısı üretebilirdi.
if not has_function_privilege('service_role', 'public.kamera_okuma_siniri()', 'execute') then
  raise exception 'FAIL 62b: kamera_okuma_siniri service_role rolüne kapalı — webhook çağıramaz';
end if;
foreach v_txt in array array['anon', 'authenticated'] loop
  if has_function_privilege(v_txt, 'public.kamera_okuma_siniri()', 'execute') then
    raise exception 'FAIL 62b: kamera_okuma_siniri % rolüne açık', v_txt;
  end if;
end loop;

-- (c) Webhook'un yazdığı biçim çalışır; telefonun biçimi kaynaksız kalır.
--     Önce o anki kamera okumaları sayılır (canlıdan satır gelebilir); tek
--     transaction'da now() sabittir, "şimdi" satırları tam now()'a düşer.
select count(*) filter (where l.created_at >= now() - interval '60 seconds'),
       count(*)
  into v_n, v_n2
  from public.plaka_okuma_log l
 where l.kaynak = 'KAMERA' and l.created_at >= now() - interval '24 hours';

perform pg_temp.kamera();
insert into public.plaka_okuma_log (saglayici, ham_yanit, guven, onerilen, kaynak)
values ('test-62', '{"test": 62}'::jsonb, 0.9, 'ZZ62AA001', 'KAMERA')
returning id into v_id;
insert into public.plaka_okuma_log (saglayici, ham_yanit, guven, onerilen)
values ('test-62-telefon', '{}'::jsonb, 0.9, 'ZZ62AA002')
returning id into v_id2;
-- Pencerenin kenarları: 2 saat önceki iki okuma günün içinde, 25 saat önceki
-- dışında.
insert into public.plaka_okuma_log (saglayici, kaynak, created_at)
values ('test-62', 'KAMERA', now() - interval '2 hours'),
       ('test-62', 'KAMERA', now() - interval '2 hours'),
       ('test-62', 'KAMERA', now() - interval '25 hours');
perform pg_temp.logout();

if (select l.kaynak::text from public.plaka_okuma_log l where l.id = v_id)
     is distinct from 'KAMERA' then
  raise exception 'FAIL 62c: kamera okuması KAMERA diye yazılamadı';
end if;
if (select l.kaynak from public.plaka_okuma_log l where l.id = v_id2) is not null then
  raise exception 'FAIL 62c: kaynaksız (telefon) okuma kendiliğinden bir kaynak aldı';
end if;

-- (d) İstemci bu satırlara dokunamaz — Yönetici de. Sahte bir KAMERA satırı
--     sınırı doldurup kamerayı kilitlerdi; silmek ya da etiketi değiştirmek
--     sınırı sıfırlardı. Günlükte yalnızca SELECT politikası var (003).
perform pg_temp.login(u_personel);
begin
  insert into public.plaka_okuma_log (saglayici, kaynak) values ('sahte-62', 'KAMERA');
  raise exception 'FAIL 62d: personel okuma günlüğüne kamera satırı yazabildi';
exception when insufficient_privilege then null;
end;
begin
  update public.plaka_okuma_log set kaynak = null where id = v_id;
exception when insufficient_privilege then null;
end;
begin
  delete from public.plaka_okuma_log where id = v_id;
exception when insufficient_privilege then null;
end;
perform pg_temp.login(u_yonetici);
begin
  insert into public.plaka_okuma_log (saglayici, kaynak) values ('sahte-62', 'KAMERA');
  raise exception 'FAIL 62d: Yönetici okuma günlüğüne kamera satırı yazabildi';
exception when insufficient_privilege then null;
end;
begin
  update public.plaka_okuma_log set kaynak = null where id = v_id;
exception when insufficient_privilege then null;
end;
begin
  delete from public.plaka_okuma_log where id = v_id;
exception when insufficient_privilege then null;
end;
perform pg_temp.logout();

if (select l.kaynak::text from public.plaka_okuma_log l where l.id = v_id)
     is distinct from 'KAMERA' then
  raise exception 'FAIL 62d: istemci bir kamera okumasını sildi ya da etiketini değiştirdi';
end if;
if exists (select 1 from public.plaka_okuma_log where saglayici = 'sahte-62') then
  raise exception 'FAIL 62d: istemcinin sahte satırı günlükte kaldı';
end if;

-- (e) Uyarı: tek, doğru sayılarla, yalnızca Yöneticiye. Okuma servisi
--     uyarısıyla ("Plaka okuma çalışmıyor", 039) tekilleştirmesi AYRI: önce o
--     uyarı yazılır, sınır uyarısı yine de gelmeli. Beklenen sayılar: son 1
--     dakikada taban + 1 (şimdiki satır), son 24 saatte taban + 3 (şimdiki +
--     2 saat önceki iki); 25 saatlik ve kaynaksız satır sayılmaz.
delete from public.notifications
 where tur = 'KAMERA'
   and baslik in ('Plaka okuma çalışmıyor', 'Kamera okuma sınırı aşıldı');
perform pg_temp.kamera();
perform public.kamera_okuma_hatasi('CIKIS', gen_random_uuid(), now(), 'Anthropic 529', false, null);
perform public.kamera_okuma_siniri();
perform pg_temp.logout();

if (select count(*) from public.notifications
     where tur = 'KAMERA' and baslik = 'Kamera okuma sınırı aşıldı'
       and profile_id = u_yonetici
       and govde like ('%son 1 dakikada ' || (v_n + 1) || ', son 24 saatte '
                       || (v_n2 + 3) || ' okuma%')) <> 1 then
  raise exception 'FAIL 62e: sınır uyarısı Yöneticiye doğru sayılarla tam bir kez gitmedi (beklenen % / %): %',
    v_n + 1, v_n2 + 3,
    (select string_agg(n.govde, ' | ') from public.notifications n
      where n.tur = 'KAMERA' and n.baslik = 'Kamera okuma sınırı aşıldı'
        and n.profile_id = u_yonetici);
end if;
if (select count(*) from public.notifications
     where tur = 'KAMERA' and baslik = 'Plaka okuma çalışmıyor'
       and profile_id = u_yonetici) <> 1 then
  raise exception 'FAIL 62e: okuma servisi uyarısı yazılmadı ya da kayboldu';
end if;
if exists (select 1 from public.notifications
            where baslik = 'Kamera okuma sınırı aşıldı' and profile_id = u_personel) then
  raise exception 'FAIL 62e: sınır uyarısı personele gitti';
end if;

-- (f) Kamera nöbetçisi (037) uyarılarını TAM link üzerinden tekilleştirir:
--     '/yonetim/kameralar' (elle kurulmuş köprü) ve
--     '/yonetim/kameralar?c=<id>' (eşleştirilmiş kamera). Sınır uyarısı
--     bunlardan birini taşısaydı "kameradan haber yok" uyarısını bir saat
--     susturabilirdi — tam da kameranın sorun çıkardığı saatte.
select n.link into v_txt from public.notifications n
 where n.tur = 'KAMERA' and n.baslik = 'Kamera okuma sınırı aşıldı'
   and n.profile_id = u_yonetici;
if v_txt is null or v_txt = '/yonetim/kameralar' or v_txt like '/yonetim/kameralar?c=%' then
  raise exception 'FAIL 62f: sınır uyarısının linki kamera nöbetçisinin tekilleştirmesine çarpıyor (%)', v_txt;
end if;

-- (g) Aynı saat içinde ikinci uyarı yok; saat dolunca yeniden uyarır.
--     (Tek transaction'da now() sabit: önceki uyarı geri çekilerek kurulur.)
perform pg_temp.kamera();
perform public.kamera_okuma_siniri();
perform pg_temp.logout();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and baslik = 'Kamera okuma sınırı aşıldı'
       and profile_id = u_yonetici) <> 1 then
  raise exception 'FAIL 62g: aynı saat içinde ikinci sınır uyarısı gönderildi';
end if;
update public.notifications set created_at = now() - interval '61 minutes'
 where tur = 'KAMERA' and baslik = 'Kamera okuma sınırı aşıldı';
perform pg_temp.kamera();
perform public.kamera_okuma_siniri();
perform pg_temp.logout();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and baslik = 'Kamera okuma sınırı aşıldı'
       and profile_id = u_yonetici) <> 2 then
  raise exception 'FAIL 62g: bir saat sonra sınır uyarısı yinelenmedi';
end if;

-- (h) JWT taşıyan çağıran — Yönetici bile — sahte uyarı üretemez. Kontrol
--     tekilleştirmeden ÖNCE olmalı: şu an saat içinde bir uyarı var, kontrol
--     sonra gelseydi çağrı sessizce dönerdi.
perform set_config('request.jwt.claims',
  json_build_object('sub', u_yonetici::text, 'role', 'authenticated')::text, true);
begin
  perform public.kamera_okuma_siniri();
  raise exception 'FAIL 62h: JWT taşıyan çağıran sınır uyarısı üretebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 62h: beklenmeyen hata (jwt): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

raise notice 'PASS 62: kamera okumaları etiketli ve istemciye kapalı, sınır uyarısı saatte bir, nöbetçiyi susturmuyor';

-- =====================================================================
-- 63  Tek kapı: kaybolan 422'den sonraki yeniden deneme aracı işler (041)
--     Model aracı gördü ama plakayı okuyamadı → OKUNAMADI kaydı İLK
--     denemede yazılır ve webhook 422 döner (039). O cevap köprüye
--     ulaşmazsa (okuma köprünün 30 sn'sini aştı, Wi-Fi koptu) köprü AYNI
--     islem_id ile yeniden dener — ve sınırdaki okumalar tam da ikinci
--     seferde okunanlardır. 037'de kamera_tek_kapi o islem_id'de bir kayıt
--     görünce "ISTISNA TEKRAR" diye kısa kesiyordu: kameranın OKUDUĞU araç
--     için ne giriş ne çıkış yazılıyordu. 041'de:
--       · çözülmemiş OKUNAMADI kaydı kararı engellemez, karar verilir;
--       · karar insan gerektirmiyorsa kayıt sistemce kapanır (cozuldu_by
--         boş, notta okunan plaka ve karar); gerektiriyorsa açık kalır ve
--         okunan plakayı taşır — ikinci kayıt da ikinci bildirim de yok;
--       · insanın çözdüğü kayıt ve olayın kendi kaydı eskisi gibi kısa
--         kesilir;
--       · yavaş ilk istek, bilet açıldıktan SONRA "okunamadı" ile biterse
--         kayıt yazılmaz.
--     Bugünkü (037/039) fonksiyonlarla bu blok kırmızıdır: (a) ISTISNA/
--     TEKRAR döner → FAIL 63a; (d) sebep TEKRAR, plaka boş → FAIL 63d;
--     (e) ISTISNA/TEKRAR → FAIL 63e; (f) 039 kaydı yazar → FAIL 63f;
--     (g) kamera_okunamadi tek kapı kilidini almaz → FAIL 63g. (b), (c) ve
--     (g)'nin geri kalanı korumadır. Dosya ilk hatada durduğu için 040
--     koşulmuş, 041 koşulmamış bir veritabanında koşu FAIL 63a ile durur —
--     beklenen budur.
--     Plakalar önceki blokların açık bıraktığı ZZ plakalarından ve
--     birbirinden en az İKİ karakter uzak (BN üçlüsü hariç — o bilerek bir
--     karakter fark). Örneğin "ZZ63TK001", 61h'nin açık bıraktığı
--     ZZ61TK001'e bir karakter uzak olurdu ve karar benzer-plaka kuralına
--     düşüp test yanlış sebepten kalırdı.
-- =====================================================================

perform pg_temp.logout();

v_liste := array['ZZ63GR101', 'ZZ63CZ202', 'ZZ63BN303', 'ZZ63BN308', 'ZZ63BN309',
                 'ZZ63CK404', 'ZZ63TS505'];
if exists (select 1 from public.biletler b, unnest(v_liste) as p(plaka)
            where b.plaka = p.plaka or public.plaka_yakin(b.plaka, p.plaka)) then
  raise exception 'FAIL 63: fixture — ZZ63 plakalarından birine eşit ya da bir karakter yakın bilet var';
end if;

-- İçeride iki eski araç: BN303 (benzer-plaka için) ve CK404 (çıkış için).
-- "Az önce girdi" sayılmasınlar diye created_at giriş süresinin ötesine
-- çekilir (PASS 58 deseni; değişmezlik guard'ı AÇIK bileti serbest bırakır).
select tek_kapi_giris_yoksay_dk into v_n2 from public.otopark_ayarlari where id = 1;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ63BN303', gen_random_uuid(), now()) into v_json;
v_bilet := case when v_json ->> 'karar' = 'GIRIS' then (v_json ->> 'bilet_id')::uuid end;
select public.kamera_tek_kapi('ZZ63CK404', gen_random_uuid(), now()) into v_json;
v_bilet2 := case when v_json ->> 'karar' = 'GIRIS' then (v_json ->> 'bilet_id')::uuid end;
perform pg_temp.logout();
if v_bilet is null or v_bilet2 is null then
  raise exception 'FAIL 63: fixture — içerideki iki araç açılamadı (%)', v_json;
end if;
update public.biletler
   set created_at = now() - make_interval(mins => v_n2 + 1)
 where id in (v_bilet, v_bilet2);

-- (a) Asıl kural. İlk deneme okuyamadı (kayıt), cevap kayboldu, yeniden
--     deneme okudu: araç YENİ — bilet bu olayın kimliğiyle açılır, önceki
--     kayıt sistemce kapanır. 045'ten beri HİÇ bildirim gitmez: bildirim
--     3 dk bekler ve kayıt o sırada kapanmışsa gönderilmez (sahibin isteği:
--     kendiliğinden düzelen şey için kimse uyarılmasın — PASS 67).
select count(*) into v_n from public.notifications
 where tur = 'ISTISNA' and profile_id = u_yonetici;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('ORTAK', v_islem, now(), 'ZZ63GR1O1', 0.58, null) into v_id;
select public.kamera_tek_kapi('ZZ63GR101', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS'
   or v_json ->> 'sebep' is distinct from 'YENI_ARAC' then
  raise exception 'FAIL 63a: okunamayan ilk denemeden sonra okuyan deneme aracı işlemedi (%)', v_json;
end if;
v_id2 := (v_json ->> 'bilet_id')::uuid;
if not exists (select 1 from public.biletler
                where id = v_id2 and islem_id = v_islem and plaka = 'ZZ63GR101'
                  and durum = 'ACIK' and giris_kaynak = 'KAMERA') then
  raise exception 'FAIL 63a: bilet bu olayın kimliğiyle açılmadı';
end if;
if (select count(*) from public.istisnalar where islem_id = v_islem) <> 1
   or not exists (
     select 1 from public.istisnalar
      where id = v_id and tur::text = 'OKUNAMADI'
        and cozuldu_at is not null and cozuldu_by is null
        and cozum_notu = 'Kamera yeniden denedi ve okudu: ZZ63GR101 → GIRIS (YENI_ARAC)') then
  raise exception 'FAIL 63a: önceki okunamadı kaydı sistemce kapanmadı';
end if;
if (select count(*) from public.notifications
     where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n then
  raise exception 'FAIL 63a: bildirim gitti — kendiliğinden kapanan kayıt için hiç bildirim gitmemeli (045)';
end if;

-- (b) Bu cevap da kaybolup deneme yine gelirse AYNI bilet döner; kapanış
--     notu değişmez.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ63GR101', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS'
   or v_json ->> 'sebep' is distinct from 'TEKRAR'
   or (v_json ->> 'bilet_id')::uuid is distinct from v_id2
   or (select count(*) from public.biletler where plaka = 'ZZ63GR101') <> 1 then
  raise exception 'FAIL 63b: tekrar oynatma aynı bileti döndürmedi (%)', v_json;
end if;
if (select cozum_notu from public.istisnalar where id = v_id)
     is distinct from 'Kamera yeniden denedi ve okudu: ZZ63GR101 → GIRIS (YENI_ARAC)' then
  raise exception 'FAIL 63b: tekrar oynatma kapanış notunu değiştirdi';
end if;

-- (c) Kaydı bir insan zaten çözdüyse karar onundur: yeniden deneme eskisi
--     gibi kısa kesilir, bilet açılmaz, kayıt olduğu gibi kalır.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('ORTAK', v_islem, now(), null, null, null) into v_id;
perform pg_temp.logout();
perform pg_temp.login(u_yonetici);
perform public.istisna_coz(v_id, 'Test 63c — kapıda bakıldı');
perform pg_temp.logout();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ63CZ202', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'ISTISNA'
   or v_json ->> 'sebep' is distinct from 'TEKRAR' then
  raise exception 'FAIL 63c: insanın çözdüğü kayıttan sonra karar yeniden verildi (%)', v_json;
end if;
if exists (select 1 from public.biletler where plaka = 'ZZ63CZ202') then
  raise exception 'FAIL 63c: insanın çözdüğü olay için bilet açıldı';
end if;
if not exists (select 1 from public.istisnalar
                where id = v_id and cozuldu_by = u_yonetici and plaka is null
                  and cozum_notu = 'Test 63c — kapıda bakıldı') then
  raise exception 'FAIL 63c: insanın çözdüğü kayıt değiştirildi';
end if;

-- (d) Yeniden deneme okudu ama karar yine insanın: plaka içerideki eski bir
--     araca (BN303) bir karakter uzak. İkinci kayıt AÇILMAZ — önceki kayıt
--     açık kalır, okunan plakayı ve sebebi taşır, modelin ilk tahmini durur;
--     şimdilik bildirim yok (045: kayıt açık kaldığı için 3 dk sonra TEK
--     bildirim gider — "bildirim bekliyor" işareti durur), benzer bilet
--     "kapıda" yapılmaz.
select count(*) into v_n from public.notifications
 where tur = 'ISTISNA' and profile_id = u_yonetici;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('ORTAK', v_islem, now(), 'ZZ63BN3O8', 0.55, null) into v_id;
select public.kamera_tek_kapi('ZZ63BN308', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'ISTISNA'
   or v_json ->> 'sebep' is distinct from 'BENZER_ACIK' then
  raise exception 'FAIL 63d: okuyan yeniden denemede belirsiz okuma kararı verilmedi (%)', v_json;
end if;
if (select count(*) from public.istisnalar where islem_id = v_islem) <> 1
   or not exists (
     select 1 from public.istisnalar
      where id = v_id and tur::text = 'OKUNAMADI' and cozuldu_at is null
        and plaka = 'ZZ63BN308'
        and ham_yanit ->> 'sonradan_okunan' = 'ZZ63BN308'
        and ham_yanit ->> 'sonradan_sebep' = 'BENZER_ACIK'
        and ham_yanit ->> 'tahmin' = 'ZZ63BN3O8') then
  raise exception 'FAIL 63d: önceki kayıt açık kalıp okunan plakayı taşımadı';
end if;
if (select count(*) from public.notifications
     where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n
   or not (select bildirim_bekliyor from public.istisnalar where id = v_id) then
  raise exception 'FAIL 63d: bildirim hemen gitti ya da açık kayıt "bildirim bekliyor" değil (045)';
end if;
if exists (select 1 from public.biletler where plaka = 'ZZ63BN308')
   or (select cikis_bekliyor_at from public.biletler where id = v_bilet) is not null then
  raise exception 'FAIL 63d: belirsiz okuma bilet açtı ya da benzer bileti "kapıda" yaptı';
end if;

-- (e) Yeniden deneme içerideki eski aracın (CK404) plakasını okudu: araç
--     çıkıyor. 054'ten beri bilet kamerayla ÖDEMESİZ kapanır (para yine
--     insanda, PASS 75), önceki kayıt sistemce kapanır.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('ORTAK', v_islem, now(), null, null, null) into v_id;
select public.kamera_tek_kapi('ZZ63CK404', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'CIKIS'
   or v_json ->> 'sebep' is distinct from 'ACIK_BILET'
   or (v_json ->> 'bilet_id')::uuid is distinct from v_bilet2 then
  raise exception 'FAIL 63e: okuyan yeniden deneme çıkışı işlemedi (%)', v_json;
end if;
if not exists (select 1 from public.biletler
                where id = v_bilet2 and durum = 'KAPALI' and cikis_kaynak = 'KAMERA'
                  and cikis_at is not null and tahsil_kurus = 0) then
  raise exception 'FAIL 63e: çıkan aracın bileti kamerayla ödemesiz kapanmadı';
end if;
if not exists (
     select 1 from public.istisnalar
      where id = v_id and cozuldu_at is not null and cozuldu_by is null
        and cozum_notu = 'Kamera yeniden denedi ve okudu: ZZ63CK404 → CIKIS (ACIK_BILET)') then
  raise exception 'FAIL 63e: önceki okunamadı kaydı sistemce kapanmadı';
end if;

-- (f) Ters sıra: yavaş ilk istek hâlâ okurken yeniden deneme aracı işleyip
--     bileti açtı. İlk istek "okunamadı" ile bittiğinde kayıt YAZILMAZ —
--     yazılsaydı bileti olan bir araç için açık kayıt ve bildirim kalırdı.
select count(*) into v_n from public.notifications
 where tur = 'ISTISNA' and profile_id = u_yonetici;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ63TS505', v_islem, now()) into v_json;
select public.kamera_okunamadi('ORTAK', v_islem, now(), 'ZZ63TS5O5', 0.41, null) into v_id;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' then
  raise exception 'FAIL 63f: kurulum — ZZ63TS505 girişi açılmadı (%)', v_json;
end if;
if v_id is not null or exists (select 1 from public.istisnalar where islem_id = v_islem) then
  raise exception 'FAIL 63f: bileti açılmış olay için okunamadı kaydı yazıldı';
end if;
if (select count(*) from public.notifications
     where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n then
  raise exception 'FAIL 63f: bileti açılmış olay bildirim üretti';
end if;

-- (g) Değişmeyenler. Olayın KENDİ kaydı (burada YON_BELIRSIZ) yeniden
--     denemede yine kısa kesilir ve dokunulmaz. İki fonksiyon da yalnızca
--     kameraya açık. İkisi de aynı tek kapı kilidini alır: (f)'deki yarış
--     ancak böyle tam kapanır — eşzamanlılığın kendisi tek transaction'da
--     sınanamaz, kilidin varlığı sınanır (059 deseni).
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ63BN309', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'ISTISNA'
   or v_json ->> 'sebep' is distinct from 'BENZER_ACIK' then
  raise exception 'FAIL 63g: kurulum — belirsiz okuma kaydı yazılmadı (%)', v_json;
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ63BN309', v_islem, now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'ISTISNA'
   or v_json ->> 'sebep' is distinct from 'TEKRAR'
   or (select count(*) from public.istisnalar where islem_id = v_islem) <> 1
   or not exists (
     select 1 from public.istisnalar
      where islem_id = v_islem and tur::text = 'YON_BELIRSIZ'
        and cozuldu_at is null and plaka = 'ZZ63BN309'
        and not (coalesce(ham_yanit, '{}'::jsonb) ? 'sonradan_okunan')) then
  raise exception 'FAIL 63g: olayın kendi kaydı yeniden denemede kısa kesilmedi ya da değişti (%)', v_json;
end if;

foreach v_txt in array array[
  'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)',
  'public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)'
] loop
  if not has_function_privilege('service_role', v_txt, 'execute') then
    raise exception 'FAIL 63g: % service_role rolüne kapalı — webhook çağıramaz', v_txt;
  end if;
  if has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('authenticated', v_txt, 'execute') then
    raise exception 'FAIL 63g: % istemciye açık', v_txt;
  end if;
end loop;

if (select count(distinct p.proname) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('kamera_tek_kapi', 'kamera_okunamadi')
       and p.prosrc like '%pg_advisory_xact_lock(hashtext(''kamera_tek_kapi''))%') <> 2 then
  raise exception 'FAIL 63g: kamera_okunamadi tek kapı kilidini almıyor — yeniden denemeyle yarışabilir';
end if;

raise notice 'PASS 63: tek kapıda kaybolan 422''den sonraki yeniden deneme aracı işliyor, okunamadı kaydı kendiliğinden kapanıyor';

-- =====================================================================
-- 64  Kamera fotoğrafı saklanır (042)
--     Webhook HİÇBİR kamera fotoğrafını saklamıyordu (her çağrıda p_foto
--     null): kameranın açtığı biletin, vurduğu "kapıda" damgasının ve
--     yazdığı her kaydın fotoğrafı yoktu. Artık köprü (1.2.3), okuduğu
--     plaka kesitinin sıkıştırılmış bir kopyasını (≤100 KB) da gönderir;
--     webhook KARARDAN SONRA onu `kamera/<islem_id>.jpg` olarak yükler ve
--     kamera_foto_bagla ile yalnızca BU olayın yazdığı yere bağlar:
--       · olayın açtığı kamera biletinin giris_foto'su,
--       · olayın yazdığı kamera kaydının foto_path'i,
--       · olayın vurduğu "kapıda" damgasının cikis_foto'su (aynı bilet VE
--         aynı zaman damgası).
--     Yol olaya bağlıdır (başka bir olayın ya da telefonun fotoğrafı
--     bağlanamaz), dolu yol asla ezilmez (ilk fotoğraf kalır), kapanmış ve
--     kamerasız bilete dokunulmaz.
--     042 koşulmamış bir veritabanında dosya PASS 41b'de durur (beklenen
--     listede adı var); 41 atlanırsa 64a temiz bir FAIL verir. (h) 041'in
--     davranışına dayanır: 040 → 041 → 042 sırayla koşulur.
-- =====================================================================

perform pg_temp.logout();

-- (a) Fonksiyon var, yalnızca kamera (service_role) çağırır.
-- 074: imza 5 argüman (p_yakin varsayılan null); aşağıdaki 4 argümanlı
-- çağrılar aynen çözülür. 074 henüz koşulmadıysa (yakın plan, köprü 1.4.6
-- ile gelir) 042'nin 4 argümanlı imzası sınanır. GEÇİCİ: 074 koşulunca bu
-- dal kalkar, yalnızca 5 argüman kalır.
v_txt2 := case when to_regprocedure('public.kamera_foto_bagla(uuid, uuid, timestamptz, text, text)') is not null
               then 'public.kamera_foto_bagla(uuid, uuid, timestamptz, text, text)'
               else 'public.kamera_foto_bagla(uuid, uuid, timestamptz, text)' end;
if to_regprocedure(v_txt2) is null then
  raise exception 'FAIL 64a: kamera_foto_bagla yok — 042 koşulmamış';
end if;
if not has_function_privilege('service_role', v_txt2, 'execute') then
  raise exception 'FAIL 64a: kamera_foto_bagla service_role rolüne kapalı — webhook bağlayamaz';
end if;
foreach v_txt in array array['anon', 'authenticated'] loop
  if has_function_privilege(v_txt, v_txt2, 'execute') then
    raise exception 'FAIL 64a: kamera_foto_bagla % rolüne açık', v_txt;
  end if;
end loop;

v_liste := array['ZZ64GA111', 'ZZ64CX222', 'ZZ64KP333', 'ZZ64MB444', 'ZZ64BY555',
                 'ZZ64YB666', 'ZZ64YB668', 'ZZ64OT777'];
if exists (select 1 from public.biletler b, unnest(v_liste) as p(plaka)
            where b.plaka = p.plaka or public.plaka_yakin(b.plaka, p.plaka)) then
  raise exception 'FAIL 64: fixture — ZZ64 plakalarından birine eşit ya da bir karakter yakın bilet var';
end if;

-- (b) JWT taşıyan çağıran (bir insan) reddedilir; olaya ait olmayan yol,
--     boş yol ve kimliksiz çağrı reddedilir. Sabit, harf içeren bir kimlik:
--     büyük harfli biçimin farklı olduğu kesin olsun.
perform set_config('request.jwt.claims',
  json_build_object('sub', u_personel::text, 'role', 'authenticated')::text, true);
begin
  perform public.kamera_foto_bagla(gen_random_uuid(), null, null, 'kamera/x.jpg');
  raise exception 'FAIL 64b: JWT taşıyan çağıran fotoğraf bağlayabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if lower(sqlerrm) not like '%yetkiniz yok%' then
    raise exception 'FAIL 64b: beklenmeyen hata (jwt): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

v_islem := 'abcdef12-3456-4789-abcd-ef1234567890'::uuid;
perform pg_temp.kamera();
foreach v_txt in array array[
  'kamera/' || gen_random_uuid()::text || '.jpg',
  'kamera/' || upper(v_islem::text) || '.jpg',
  'kamera/' || v_islem::text || '.png',
  '../kamera/' || v_islem::text || '.jpg',
  '2026-10-28/giris-34ABC123-1a2b3c4d.jpg'
] loop
  begin
    perform public.kamera_foto_bagla(v_islem, null, null, v_txt);
    raise exception 'FAIL 64b: olaya ait olmayan yol kabul edildi: %', v_txt;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end loop;
begin
  perform public.kamera_foto_bagla(v_islem, null, null, null);
  raise exception 'FAIL 64b: boş yol kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.kamera_foto_bagla(null, null, null, 'kamera/' || v_islem::text || '.jpg');
  raise exception 'FAIL 64b: işlem kimliği olmadan kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();

-- (c) Giriş kapısı: kameranın açtığı bilet fotoğrafını alır; ikinci çağrı
--     hiçbir şey değiştirmez (ilk fotoğraf kalır). Giriş biletinde "kapıda"
--     damgası olmadığı için çıkış fotoğrafı yazılmaz.
v_islem := gen_random_uuid();
v_txt2 := 'kamera/' || v_islem::text || '.jpg';
perform pg_temp.kamera();
select public.bilet_ac('ZZ64GA111', v_islem, 'KAMERA', now()) into v_bilet;
select public.kamera_foto_bagla(v_islem, v_bilet, now(), v_txt2) into v_n;
select public.kamera_foto_bagla(v_islem, v_bilet, now(), v_txt2) into v_n2;
perform pg_temp.logout();
if v_bilet is null or v_n <> 1 or v_n2 <> 0
   or not exists (select 1 from public.biletler
                   where id = v_bilet and giris_foto = v_txt2 and cikis_foto is null) then
  raise exception 'FAIL 64c: kamera bileti fotoğrafını almadı ya da ikinci çağrı değiştirdi (% / %)', v_n, v_n2;
end if;

-- (d) Çıkış kapısı: kameranın bu olayda kapattığı bilet (054) çıkış
--     fotoğrafını alır — ama yalnızca bu olayın kapanışı (aynı zaman). Başka
--     zamanla çağrı 0 döner; giriş fotoğrafına dokunulmaz (biletin islem_id'si
--     girişin kimliğidir).
v_islem := gen_random_uuid();
perform pg_temp.kamera();
-- Giriş bir saat önce: çıkış (aşağıda now() − 10 sn) girişten SONRA olmalı,
-- yoksa kamera bileti kapatamaz (biletler_cikis_ck; PASS 75 sınar).
select public.bilet_ac('ZZ64CX222', v_islem, 'KAMERA', now() - interval '1 hour') into v_bilet2;
v_islem := gen_random_uuid();
v_txt2 := 'kamera/' || v_islem::text || '.jpg';
v_ts := now() - interval '10 seconds';
select public.kamera_cikis_bildir('ZZ64CX222', v_islem, v_ts) into v_id;
select public.kamera_foto_bagla(v_islem, v_bilet2, v_ts + interval '1 second', v_txt2) into v_n;
select public.kamera_foto_bagla(v_islem, v_bilet2, v_ts, v_txt2) into v_n2;
perform pg_temp.logout();
if v_id is distinct from v_bilet2 or v_n <> 0 or v_n2 <> 1
   or not exists (select 1 from public.biletler
                   where id = v_bilet2 and durum = 'KAPALI' and cikis_kaynak = 'KAMERA'
                     and cikis_foto = v_txt2 and giris_foto is null
                     and cikis_at = v_ts and cikis_bekliyor_at = v_ts) then
  raise exception 'FAIL 64d: kameranın kapattığı biletin çıkış fotoğrafı yanlış bağlandı (% / %)', v_n, v_n2;
end if;
perform pg_temp.kamera();
select public.kamera_foto_bagla(v_islem, v_bilet2, v_ts, v_txt2) into v_n;
perform pg_temp.logout();
if v_n <> 0 then
  raise exception 'FAIL 64d: dolu çıkış fotoğrafı yeniden yazıldı';
end if;

-- (e) Kapanmış bilete dokunulmaz — ve hata da vermez (değişmezlik guard'ı
--     dolu bir foto yolunu reddederdi; fonksiyon oraya hiç gitmemeli).
v_islem := gen_random_uuid();
v_txt2 := 'kamera/' || v_islem::text || '.jpg';
perform pg_temp.kamera();
select public.bilet_ac('ZZ64KP333', v_islem, 'KAMERA', now()) into v_bilet;
perform pg_temp.logout();
perform pg_temp.login(u_yonetici);
perform public.bilet_iptal(v_bilet, 'Test — 64e');
perform pg_temp.logout();
perform pg_temp.kamera();
select public.kamera_foto_bagla(v_islem, v_bilet, now(), v_txt2) into v_n;
perform pg_temp.logout();
if v_n <> 0 or (select giris_foto from public.biletler where id = v_bilet) is not null then
  raise exception 'FAIL 64e: kapanmış bilete fotoğraf yazıldı';
end if;

-- (f) Telefonla açılmış bilet kameranın değildir: aynı kimlik gelse bile
--     fotoğrafı yazılmaz.
v_islem := gen_random_uuid();
v_txt2 := 'kamera/' || v_islem::text || '.jpg';
insert into public.biletler (islem_id, plaka, giris_at, tarife_id)
select v_islem, 'ZZ64MB444', now(), t.id from public.tarifeler t order by t.id limit 1
returning id into v_bilet;
perform pg_temp.kamera();
select public.kamera_foto_bagla(v_islem, v_bilet, now(), v_txt2) into v_n;
perform pg_temp.logout();
if v_n <> 0 or (select giris_foto from public.biletler where id = v_bilet) is not null then
  raise exception 'FAIL 64f: telefonla açılmış bilete kamera fotoğrafı yazıldı';
end if;

-- (g) Kamera kayıtları fotoğrafını alır: okunamayan plaka (giriş), bayat
--     olay (bilet yerine kayıt) ve tek kapıda belirsiz okuma.
v_islem := gen_random_uuid();
v_txt2 := 'kamera/' || v_islem::text || '.jpg';
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now(), null, null, null) into v_id;
select public.kamera_foto_bagla(v_islem, null, null, v_txt2) into v_n;
select public.kamera_foto_bagla(v_islem, null, null, v_txt2) into v_n2;
perform pg_temp.logout();
if v_id is null or v_n <> 1 or v_n2 <> 0
   or (select foto_path from public.istisnalar where id = v_id) is distinct from v_txt2 then
  raise exception 'FAIL 64g: okunamayan plaka kaydı fotoğrafını almadı (% / %)', v_n, v_n2;
end if;

select kamera_gecikme_limiti_dk into v_n2 from public.otopark_ayarlari where id = 1;
v_islem := gen_random_uuid();
v_txt2 := 'kamera/' || v_islem::text || '.jpg';
perform pg_temp.kamera();
select public.bilet_ac('ZZ64BY555', v_islem, 'KAMERA',
         now() - make_interval(mins => coalesce(v_n2, 720) + 60)) into v_bilet;
select public.kamera_foto_bagla(v_islem, v_bilet, now(), v_txt2) into v_n;
perform pg_temp.logout();
if v_bilet is not null or v_n <> 1
   or not exists (select 1 from public.istisnalar
                   where islem_id = v_islem and tur::text = 'BAYAT' and foto_path = v_txt2) then
  raise exception 'FAIL 64g: bayat olay kaydı fotoğrafını almadı (%)', v_n;
end if;

select tek_kapi_giris_yoksay_dk into v_n2 from public.otopark_ayarlari where id = 1;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ64YB666', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
v_bilet := case when v_json ->> 'karar' = 'GIRIS' then (v_json ->> 'bilet_id')::uuid end;
if v_bilet is null then
  raise exception 'FAIL 64: fixture — ZZ64YB666 girişi açılmadı (%)', v_json;
end if;
update public.biletler
   set created_at = now() - make_interval(mins => v_n2 + 1) where id = v_bilet;
v_islem := gen_random_uuid();
v_txt2 := 'kamera/' || v_islem::text || '.jpg';
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ64YB668', v_islem, now()) into v_json;
select public.kamera_foto_bagla(v_islem, (v_json ->> 'bilet_id')::uuid, now(), v_txt2) into v_n;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'ISTISNA'
   or v_json ->> 'sebep' is distinct from 'BENZER_ACIK' or v_n <> 1
   or not exists (select 1 from public.istisnalar
                   where islem_id = v_islem and tur::text = 'YON_BELIRSIZ' and foto_path = v_txt2)
   or (select giris_foto from public.biletler where id = v_bilet) is not null then
  raise exception 'FAIL 64g: tek kapıdaki belirsiz okuma kaydı fotoğrafını almadı (% / %)', v_json, v_n;
end if;

-- (h) 041 ile birlikte: tek kapıda ilk deneme okuyamadı, yeniden deneme
--     okudu ve bileti açtı. Aynı olayın fotoğrafı İKİ yere de bağlanır: açılan
--     bilete ve (sistemce kapanmış) okunamadı kaydına.
v_islem := gen_random_uuid();
v_txt2 := 'kamera/' || v_islem::text || '.jpg';
perform pg_temp.kamera();
perform public.kamera_okunamadi('ORTAK', v_islem, now(), null, null, null);
select public.kamera_tek_kapi('ZZ64OT777', v_islem, now()) into v_json;
select public.kamera_foto_bagla(v_islem, (v_json ->> 'bilet_id')::uuid, now(), v_txt2) into v_n;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' or v_n <> 2
   or not exists (select 1 from public.biletler
                   where islem_id = v_islem and giris_foto = v_txt2)
   or not exists (select 1 from public.istisnalar
                   where islem_id = v_islem and tur::text = 'OKUNAMADI' and foto_path = v_txt2) then
  raise exception 'FAIL 64h: tek kapıdaki okunamadı + yeniden deneme fotoğrafı iki yere bağlanmadı (% / %)', v_json, v_n;
end if;

-- (i) Hiçbir şeye ait olmayan olay: 0, hata yok.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_foto_bagla(v_islem, gen_random_uuid(), now(),
         'kamera/' || v_islem::text || '.jpg') into v_n;
perform pg_temp.logout();
if v_n <> 0 then
  raise exception 'FAIL 64i: hiçbir kayda ait olmayan olay % yere bağlandı', v_n;
end if;

raise notice 'PASS 64: kamera fotoğrafı yalnızca olayın kendi biletine, damgasına ya da kaydına, boşsa ve bir kez bağlanıyor';

-- =====================================================================
-- 65  Fotoğraf temizliği Storage API ile (043)
-- =====================================================================
-- 025'in gece işi saklama süresini aşan fotoğrafları `delete from
-- storage.objects` ile siliyordu. Supabase'e göre bu yalnızca KAYIT satırını
-- siler: dosya kovada YETİM kalır, ücretsiz 1 GB'a sayılmaya devam eder ve
-- saklama süresinden sonra da durur (KVKK). 043 SQL silmeyi kaldırır; silme
-- Edge Function foto-temizle'nin Storage API çağrısıdır (döngüsü:
-- tests/temizlik.check.mjs). Bu blok veritabanı yarısını sınar: liste doğru
-- dosyaları verir ve uygulamadaki saklama ayarına uyar, gece işi artık SQL
-- ile hiçbir şey silmez, eksik kurulum ve hata Yöneticiye günde bir kez
-- söylenir. Test dosyaları `zz-test-65/` önekli ve 2000 yılından: canlı
-- kovadaki gerçek fotoğraflardan ayrılır, sıralamada hep en eskidir.
-- 043'ten önce koşulursa dosya FAIL 41b'de durur (liste onu bekliyor).
perform pg_temp.logout();

if to_regprocedure('public.foto_temizlik_listesi(integer)') is null
   or to_regprocedure('public.foto_temizlik_hata(text)') is null
   or to_regprocedure('public.foto_temizlik_tetikle()') is null
   or to_regclass('public.foto_temizlik_ayar') is null then
  raise exception 'FAIL 65a: fotoğraf temizliği yok — 043 koşulmamış';
end if;

-- (b) Yetkiler: liste ve hata yalnızca service_role'e; ayar tablosu (gizli
--     anahtar) hiçbir istemciye.
foreach v_txt in array array['public.foto_temizlik_listesi(integer)',
                             'public.foto_temizlik_hata(text)'] loop
  if has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('authenticated', v_txt, 'execute') then
    raise exception 'FAIL 65b: % istemciye açık', v_txt;
  end if;
  if not has_function_privilege('service_role', v_txt, 'execute') then
    raise exception 'FAIL 65b: % foto-temizle''ye (service_role) kapalı', v_txt;
  end if;
end loop;
if has_table_privilege('anon', 'public.foto_temizlik_ayar', 'select')
   or has_table_privilege('authenticated', 'public.foto_temizlik_ayar', 'select')
   or has_table_privilege('authenticated', 'public.foto_temizlik_ayar', 'insert')
   or has_table_privilege('authenticated', 'public.foto_temizlik_ayar', 'update') then
  raise exception 'FAIL 65b: temizliğin gizli anahtarı istemciye açık';
end if;

-- (c) Gece işi artık SQL ile silmiyor, eski yolları hâlâ boşaltıyor ve
--     temizliği tetikliyor. public şemasında SQL ile storage silen HİÇBİR
--     fonksiyon kalmamalı.
v_txt := pg_get_functiondef('public.run_gunluk_bakim()'::regprocedure);
if v_txt ~* 'delete\s+from\s+storage\.objects' then
  raise exception 'FAIL 65c: run_gunluk_bakim fotoğrafları hâlâ SQL ile siliyor';
end if;
if position('foto_temizlik_tetikle' in v_txt) = 0 then
  raise exception 'FAIL 65c: run_gunluk_bakim fotoğraf temizliğini tetiklemiyor';
end if;
if v_txt !~* 'set\s+giris_foto\s*=\s*null' or v_txt !~* 'set\s+cikis_foto\s*=\s*null'
   or v_txt !~* 'set\s+foto_path\s*=\s*null' then
  raise exception 'FAIL 65c: run_gunluk_bakim eski fotoğraf yollarını artık boşaltmıyor';
end if;
select string_agg(p.proname, ', ') into v_txt2
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind in ('f', 'p')
   and pg_get_functiondef(p.oid) ~* 'delete\s+from\s+storage\.objects';
if v_txt2 is not null then
  raise exception 'FAIL 65c: SQL ile storage silen fonksiyon kaldı: %', v_txt2;
end if;

-- (d) Liste: yalnızca plaka-foto, yalnızca saklama süresini aşanlar, en eski
--     önce, en fazla 1000; uygulamadaki ayar (foto_saklama_gun) belirler.
insert into storage.buckets (id, name, public)
values ('zz-test-65', 'zz-test-65', false)
on conflict (id) do nothing;
insert into storage.objects (bucket_id, name, created_at, updated_at, metadata) values
  ('plaka-foto', 'zz-test-65/a-cok-eski.jpg', '2000-01-01', '2000-01-01', '{"size": 100}'),
  ('plaka-foto', 'zz-test-65/b-cok-eski.jpg', '2000-01-02', '2000-01-02', '{"size": 100}'),
  ('plaka-foto', 'zz-test-65/c-11-gun.jpg', now() - interval '11 days',
                 now() - interval '11 days', '{"size": 100}'),
  ('plaka-foto', 'zz-test-65/d-9-gun.jpg', now() - interval '9 days',
                 now() - interval '9 days', '{"size": 100}'),
  ('zz-test-65', 'zz-test-65/e-baska-kova.jpg', '2000-01-01', '2000-01-01', '{"size": 100}');
update public.otopark_ayarlari set foto_saklama_gun = 10 where id = 1;

perform pg_temp.kamera();
select coalesce(array_agg(x), '{}'::text[]) into v_liste
  from public.foto_temizlik_listesi(5000) as t(x);
perform pg_temp.logout();
if not ('zz-test-65/a-cok-eski.jpg' = any(v_liste)
        and 'zz-test-65/b-cok-eski.jpg' = any(v_liste)
        and 'zz-test-65/c-11-gun.jpg' = any(v_liste)) then
  raise exception 'FAIL 65d: saklama süresini (10 gün) aşan fotoğraf listede yok';
end if;
if 'zz-test-65/d-9-gun.jpg' = any(v_liste) then
  raise exception 'FAIL 65d: saklama süresi dolmamış (9 gün) fotoğraf silinecekler listesinde';
end if;
if 'zz-test-65/e-baska-kova.jpg' = any(v_liste) then
  raise exception 'FAIL 65d: başka kovadaki dosya silinecekler listesinde';
end if;
if cardinality(v_liste) > 1000 then
  raise exception 'FAIL 65d: liste 1000''i aştı (%)', cardinality(v_liste);
end if;

perform pg_temp.kamera();
select array_agg(x order by o) into v_liste
  from public.foto_temizlik_listesi(2) with ordinality as t(x, o);
select count(*) into v_n from public.foto_temizlik_listesi(-5);
perform pg_temp.logout();
if v_liste is distinct from array['zz-test-65/a-cok-eski.jpg', 'zz-test-65/b-cok-eski.jpg'] then
  raise exception 'FAIL 65d: limit/sıra yanlış — en eski ikisi beklenirken %', v_liste;
end if;
if v_n <> 0 then
  raise exception 'FAIL 65d: eksi limit % satır döndürdü', v_n;
end if;

update public.otopark_ayarlari set foto_saklama_gun = 30 where id = 1;
perform pg_temp.kamera();
select coalesce(array_agg(x), '{}'::text[]) into v_liste
  from public.foto_temizlik_listesi(1000) as t(x);
perform pg_temp.logout();
if 'zz-test-65/c-11-gun.jpg' = any(v_liste) then
  raise exception 'FAIL 65d: ayar 30 gün iken 11 günlük fotoğraf listede — ayara uyulmuyor';
end if;

-- (e) Gece işi koşar ve storage.objects'ten HİÇBİR satırı SQL ile silmez.
--     (Tetiklenen istek, varsa, pg_net kuyruğuna yazılır ve bu işlem geri
--     alındığı için hiç gönderilmez.)
update public.otopark_ayarlari set foto_saklama_gun = 1 where id = 1;
select count(*) into v_n from storage.objects where name like 'zz-test-65/%';
perform public.run_gunluk_bakim();
select count(*) into v_n2 from storage.objects where name like 'zz-test-65/%';
if v_n2 <> v_n then
  raise exception 'FAIL 65e: gece işi storage.objects''ten SQL ile % satır sildi', v_n - v_n2;
end if;
update public.otopark_ayarlari set foto_saklama_gun = 30 where id = 1;

-- (f) Kurulmamışsa Yöneticiye söylenir — günde bir kez, Personele değil.
delete from public.foto_temizlik_ayar;
delete from public.notifications
 where tur = 'KAMERA' and baslik in ('Fotoğraf temizliği kurulmamış',
                                     'Fotoğraf temizliği başarısız');
perform public.foto_temizlik_tetikle();
perform public.foto_temizlik_tetikle();
select count(*) into v_n from public.notifications
 where profile_id = u_yonetici and tur = 'KAMERA'
   and baslik = 'Fotoğraf temizliği kurulmamış';
if v_n <> 1 then
  raise exception 'FAIL 65f: kurulmamış temizlik için % uyarı (1 beklenirdi)', v_n;
end if;
select count(*) into v_n from public.notifications
 where profile_id = u_personel and baslik like 'Fotoğraf temizliği%';
if v_n <> 0 then
  raise exception 'FAIL 65f: temizlik uyarısı Personele gitti';
end if;

-- (g) Kuruluysa uyarı yok; istek gizli başlıkla kuyruğa girer.
delete from public.notifications where baslik = 'Fotoğraf temizliği kurulmamış';
insert into public.foto_temizlik_ayar (id, url, gizli)
values (1, 'https://zz-test-65.invalid/functions/v1/foto-temizle', repeat('x', 32));
perform public.foto_temizlik_tetikle();
select count(*) into v_n from public.notifications
 where baslik = 'Fotoğraf temizliği kurulmamış';
if v_n <> 0 then
  raise exception 'FAIL 65g: kurulu temizlik yine de "kurulmamış" uyarısı yazdı';
end if;
if to_regclass('net.http_request_queue') is not null then
  execute 'select count(*), max(headers ->> ''x-temizlik-secret'')
             from net.http_request_queue where url = $1'
    into v_n, v_txt
    using 'https://zz-test-65.invalid/functions/v1/foto-temizle';
  if v_n <> 1 or v_txt is distinct from repeat('x', 32) then
    raise exception 'FAIL 65g: istek kuyruğa gizli başlıkla girmedi (% satır)', v_n;
  end if;
else
  raise notice '     (65g: net.http_request_queue yok — kuyruk kontrolü atlandı)';
end if;

-- (h) Temizlik hatası Yöneticiye günde bir kez, mesajıyla; uzun mesaj kısalır.
perform pg_temp.kamera();
perform public.foto_temizlik_hata('Storage 503 ' || repeat('y', 1000));
perform public.foto_temizlik_hata('ikinci hata');
perform pg_temp.logout();
select count(*), max(govde) into v_n, v_txt from public.notifications
 where profile_id = u_yonetici and tur = 'KAMERA'
   and baslik = 'Fotoğraf temizliği başarısız';
if v_n <> 1 then
  raise exception 'FAIL 65h: temizlik hatası için % uyarı (1 beklenirdi)', v_n;
end if;
if position('Storage 503' in v_txt) = 0 or length(v_txt) > 400 then
  raise exception 'FAIL 65h: uyarı metni hatayı taşımıyor ya da çok uzun (% karakter)', length(v_txt);
end if;

raise notice 'PASS 65: fotoğraflar SQL ile değil Storage API ile silinir; liste saklama ayarına uyar; kurulum eksikliği ve hata Yöneticiye günde bir kez söylenir';

-- =====================================================================
-- 66  Okunamayan plakadan tek dokunuşla giriş (044)
--     istisna_bilet_ac: personel plakayı yazar, bilet KAMERANIN gördüğü
--     anda açılır ve kayıt aynı işlemde kapanır. Zamanı personel seçemez
--     (kayıttan gelir, kayda personel yazamaz); saati bozuk kamera ya da
--     günlerce açık kalmış kayıt bileti geçmişe yazamaz. Hata olursa ne
--     bilet açılır ne kayıt kapanır.
-- =====================================================================
perform pg_temp.logout();
if to_regprocedure('public.istisna_bilet_ac(uuid,text)') is null then
  raise exception 'FAIL 66: istisna_bilet_ac yok — 044 çalıştırılmadı';
end if;

-- (a) Giriş şeridi, kamera 10 dk önce gördü: plaka normalleşir, bilet o
--     ana yazılır, olayın işlem kimliğini ve fotoğrafını taşır, boş yere
--     oturur; kayıt personel adına notla kapanır; bir denetim satırı.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now() - interval '10 minutes',
                               'ZZ66GR1O1', 0.42, null) into v_id;
perform pg_temp.logout();
update public.istisnalar set foto_path = 'kamera/' || v_islem || '.jpg' where id = v_id;
v_yer := public.bos_park_yeri();
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac(v_id, ' zz 66 gr 101 ') into v_json;
perform pg_temp.logout();
v_bilet := (v_json ->> 'bilet_id')::uuid;
if v_bilet is null or (v_json ->> 'zaten_vardi')::boolean is distinct from false
   or v_json ->> 'plaka' is distinct from 'ZZ66GR101' then
  raise exception 'FAIL 66a: beklenmeyen dönüş %', v_json;
end if;
if not exists (
  select 1 from public.biletler b
   where b.id = v_bilet and b.durum = 'ACIK' and b.plaka = 'ZZ66GR101'
     and b.islem_id = v_islem
     and b.giris_at = now() - interval '10 minutes'
     and b.kaynak_zaman = now() - interval '10 minutes'
     and b.gecikmeli_kayit
     and b.giris_by = u_personel and b.giris_kaynak = 'MOBIL'
     and b.giris_foto = 'kamera/' || v_islem || '.jpg'
     and b.park_yeri_id is not distinct from v_yer) then
  raise exception 'FAIL 66a: bilet yanlış açıldı (zaman/kaynak/foto/yer)';
end if;
if (v_json ->> 'yer_kod') is distinct from (select p.kod from public.park_yerleri p where p.id = v_yer) then
  raise exception 'FAIL 66a: yer kodu dönmedi (%)', v_json;
end if;
if not exists (select 1 from public.istisnalar
                where id = v_id and cozuldu_by = u_personel and cozuldu_at is not null
                  and cozum_notu = 'Bilet açıldı: ZZ66GR101') then
  raise exception 'FAIL 66a: kayıt personel adına notla kapanmadı';
end if;
select count(*) into v_n from public.audit_log
 where action = 'istisna_bilet_acildi' and row_id = v_bilet and actor = u_personel;
if v_n <> 1 then
  raise exception 'FAIL 66a: % denetim satırı (1 beklenirdi)', v_n;
end if;

-- (b) Aynı dokunuş tekrar (cevap kaybolduysa): aynı bilet döner, ikinci
--     bilet yok, başka plaka yazılsa bile hiçbir şey değişmez.
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac(v_id, 'ZZ66FARK1') into v_json;
perform pg_temp.logout();
if (v_json ->> 'bilet_id')::uuid is distinct from v_bilet
   or (v_json ->> 'zaten_vardi')::boolean is distinct from true then
  raise exception 'FAIL 66b: tekrar dokunuş aynı bileti döndürmedi (%)', v_json;
end if;
select count(*) into v_n from public.biletler where islem_id = v_islem;
if v_n <> 1 or exists (select 1 from public.biletler where plaka = 'ZZ66FARK1') then
  raise exception 'FAIL 66b: tekrar dokunuş ikinci bilet açtı';
end if;
if (select cozum_notu from public.istisnalar where id = v_id) is distinct from 'Bilet açıldı: ZZ66GR101' then
  raise exception 'FAIL 66b: tekrar dokunuş kapanış notunu değiştirdi';
end if;

-- (c) Onaysız ve devre dışı kullanıcı reddedilir; kayıt açık kalır.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now(), null, null, null) into v_id2;
perform pg_temp.logout();
foreach v_txt in array array[u_pending::text, u_disabled::text] loop
  perform pg_temp.login(v_txt::uuid);
  begin
    perform public.istisna_bilet_ac(v_id2, 'ZZ66YT202');
    raise exception 'FAIL 66c: yetkisiz kullanıcı bilet açtı';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if lower(sqlerrm) not like '%yetkiniz yok%' then
      raise exception 'FAIL 66c: yanlış ret sebebi: %', sqlerrm;
    end if;
  end;
  perform pg_temp.logout();
end loop;
if exists (select 1 from public.biletler where islem_id = v_islem)
   or exists (select 1 from public.istisnalar where id = v_id2 and cozuldu_at is not null) then
  raise exception 'FAIL 66c: reddedilen çağrı iz bıraktı';
end if;

-- (d) Okunamayan plaka dışındaki kayıttan giriş açılmaz; kayıt değişmez.
select public.istisna_yaz('ACIK_BILET_YOK', 'CIKIS', 'ZZ66AB404', 'KAMERA',
                          gen_random_uuid(), null, null, now()) into v_id;
perform pg_temp.login(u_personel);
begin
  perform public.istisna_bilet_ac(v_id, 'ZZ66AB404');
  raise exception 'FAIL 66d: açık bilet yok kaydından giriş açıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Bu kayıttan giriş açılamaz%' then
    raise exception 'FAIL 66d: yanlış ret sebebi: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if exists (select 1 from public.biletler where plaka = 'ZZ66AB404')
   or exists (select 1 from public.istisnalar where id = v_id and cozuldu_at is not null) then
  raise exception 'FAIL 66d: reddedilen çağrı iz bıraktı';
end if;

-- (e) Plaka zaten içeride: bilet_ac'nin mesajı gelir; ne bilet açılır ne
--     kayıt kapanır (tek işlem). (c)'nin açık kaydı kullanılır.
perform pg_temp.login(u_personel);
perform public.bilet_ac('ZZ66IC303', gen_random_uuid());
begin
  perform public.istisna_bilet_ac(v_id2, 'ZZ66IC303');
  raise exception 'FAIL 66e: içerideki plakaya ikinci bilet açıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%zaten açık bir bilet var%' then
    raise exception 'FAIL 66e: yanlış ret sebebi: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if exists (select 1 from public.biletler where islem_id = v_islem)
   or exists (select 1 from public.istisnalar where id = v_id2 and cozuldu_at is not null) then
  raise exception 'FAIL 66e: başarısız çağrı bilet açtı ya da kaydı kapattı';
end if;

-- (f) Kamera aynı olayın biletini zaten açmış (yeniden deneme). 045'ten beri
--     giriş şeridinde kayıt o anda KENDİLİĞİNDEN kapanır (kamera notuyla,
--     cozuldu_by boş); personelin dokunuşu yine kameranın biletini döner,
--     o bilete dokunulmaz, yeni bilet yok, kapanış notu değişmez.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now() - interval '3 minutes', null, null, null) into v_id;
select public.bilet_ac('ZZ66KM505', v_islem, 'KAMERA', now() - interval '3 minutes') into v_bilet2;
perform pg_temp.logout();
select giris_at into v_ts from public.biletler where id = v_bilet2;
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac(v_id, 'ZZ66XX999') into v_json;
perform pg_temp.logout();
if (v_json ->> 'bilet_id')::uuid is distinct from v_bilet2
   or (v_json ->> 'zaten_vardi')::boolean is distinct from true
   or v_json ->> 'plaka' is distinct from 'ZZ66KM505' then
  raise exception 'FAIL 66f: kameranın bileti dönmedi (%)', v_json;
end if;
if exists (select 1 from public.biletler where plaka = 'ZZ66XX999')
   or not exists (select 1 from public.biletler
                   where id = v_bilet2 and plaka = 'ZZ66KM505' and giris_at = v_ts
                     and giris_kaynak = 'KAMERA') then
  raise exception 'FAIL 66f: kameranın biletine dokunuldu ya da yeni bilet açıldı';
end if;
if not exists (select 1 from public.istisnalar
                where id = v_id and cozuldu_at is not null and cozuldu_by is null
                  and cozum_notu = 'Kamera yeniden denedi ve okudu: ZZ66KM505 → GIRIS') then
  raise exception 'FAIL 66f: kayıt kamera notuyla kendiliğinden kapanmadı (045)';
end if;

-- (g) Kamera saati bozuk: 1 saat ileri ve gecikme sınırından eski olay
--     zamanına güvenilmez, bilet sunucunun kaydı aldığı ana (burada now())
--     yazılır; asla now()'dan ileri değil. Sınır canlı ayardan okunur.
select coalesce(kamera_gecikme_limiti_dk, 720) into v_n2 from public.otopark_ayarlari where id = 1;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now() + interval '1 hour', null, null, null) into v_id;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac(v_id, 'ZZ66IL606') into v_json;
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = (v_json ->> 'bilet_id')::uuid and giris_at = now()
                  and not gecikmeli_kayit) then
  raise exception 'FAIL 66g: ileri saatli olay bileti ileri tarihe yazdı';
end if;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now() - make_interval(mins => v_n2 + 60),
                               null, null, null) into v_id;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac(v_id, 'ZZ66GR707') into v_json;
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = (v_json ->> 'bilet_id')::uuid and giris_at = now()) then
  raise exception 'FAIL 66g: sınırdan eski saatli olay bileti geçmişe yazdı';
end if;

-- (g2) Günlerce açık kalmış kayıt: araç büyük olasılıkla çoktan çıktı.
--      Kamera yolunun BAYAT sınırıyla aynı sınır (v_n2); bilet açılmaz.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now() - make_interval(mins => v_n2 + 60),
                               null, null, null) into v_id;
perform pg_temp.logout();
update public.istisnalar set alindi_zaman = now() - make_interval(mins => v_n2 + 60) where id = v_id;
perform pg_temp.login(u_personel);
begin
  perform public.istisna_bilet_ac(v_id, 'ZZ66ES808');
  raise exception 'FAIL 66g2: çok eski kayıttan bilet açıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%çok eski%' then
    raise exception 'FAIL 66g2: yanlış ret sebebi: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if exists (select 1 from public.biletler where islem_id = v_islem)
   or exists (select 1 from public.istisnalar where id = v_id and cozuldu_at is not null) then
  raise exception 'FAIL 66g2: reddedilen çağrı iz bıraktı';
end if;

-- (h) Biletsiz kapatılmış kayıttan giriş açılmaz.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now(), null, null, null) into v_id;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
perform public.istisna_coz(v_id, 'Test 66h');
begin
  perform public.istisna_bilet_ac(v_id, 'ZZ66KP909');
  raise exception 'FAIL 66h: kapatılmış kayıttan bilet açıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%zaten kapatılmış%' then
    raise exception 'FAIL 66h: yanlış ret sebebi: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if exists (select 1 from public.biletler where islem_id = v_islem) then
  raise exception 'FAIL 66h: kapatılmış kayıttan bilet açıldı';
end if;

-- (i) Tek kapı kaydı da aynı yoldan açılır.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('ORTAK', v_islem, now() - interval '1 minute', null, null, null) into v_id;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac(v_id, 'ZZ66TK111') into v_json;
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = (v_json ->> 'bilet_id')::uuid and plaka = 'ZZ66TK111'
                  and islem_id = v_islem and giris_at = now() - interval '1 minute'
                  and not gecikmeli_kayit)
   or not exists (select 1 from public.istisnalar where id = v_id and cozuldu_at is not null) then
  raise exception 'FAIL 66i: tek kapı kaydından giriş açılmadı';
end if;

-- (j) Yalnızca oturum açmış personel çağırabilir.
if has_function_privilege('anon', 'public.istisna_bilet_ac(uuid,text)', 'execute')
   or has_function_privilege('service_role', 'public.istisna_bilet_ac(uuid,text)', 'execute')
   or not has_function_privilege('authenticated', 'public.istisna_bilet_ac(uuid,text)', 'execute') then
  raise exception 'FAIL 66j: istisna_bilet_ac yetkileri yanlış';
end if;

raise notice 'PASS 66: okunamayan plakadan giriş tek işlemde açılır, kameranın gördüğü ana yazılır, saati bozuk/eski kayıt bileti geçmişe yazamaz, tekrar dokunuş ikinci bilet açmaz';

-- =====================================================================
-- 67  Okunamayan plaka bildirimi: yeniden denemelerden SONRA, herkese (045)
--     Eskiden "Çözülmemiş kayıt — OKUNAMADI" bildirimi kayıt yazıldığı an
--     Yöneticiye gidiyordu. Webhook'un cevabı köprüye ulaşmazsa köprü aynı
--     olayı yeniden dener ve okuyabilir; o zaman kayıt kendiliğinden kapanıyor
--     ama bildirim çoktan gitmiş oluyordu. Sahibin kuralı (2026-10-31):
--       · bildirim köprünün denemeleri bitince gider — 3 dk (1.2.4'ün en kötü
--         hâli ≈ 2 dk 7 sn: 4 × 30 sn + 1/2/4 sn), yalnızca kayıt HÂLÂ açıksa;
--       · her role gider (Yönetici + Personel), tercihi kapalı olana gitmez;
--       · giriş şeridinde de kameranın yeniden denemesi bileti açınca kayıt
--         kendiliğinden kapanır (tek kapıda 041 zaten kapatıyordu).
--     Okuma servisi arızası kayıtları (039) araç başına hiç bildirim üretmez;
--     öbür kayıt türleri eskisi gibi HEMEN ve yalnızca Yöneticiye gider.
-- =====================================================================
perform pg_temp.logout();
if to_regprocedure('public.istisna_bildirim_gonder()') is null then
  raise exception 'FAIL 67: istisna_bildirim_gonder yok — 045 çalıştırılmadı';
end if;

-- İş, bekleyen TÜM kayıtları işler: canlıdan kalmış bir bekleyen kayıt bu
-- koşunun sayımlarını kirletmesin (işlem sonunda geri alınır).
update public.istisnalar set bildirim_bekliyor = false where bildirim_bekliyor;
update public.profiles set notif_prefs = coalesce(notif_prefs, '{}'::jsonb) - 'ISTISNA'
 where id in (u_yonetici, u_personel, u_personel2);

-- Kişi başı ISTISNA bildirimi sayısı (y: Yönetici, p/p2: personel,
-- b: onay bekleyen, d: devre dışı).
select jsonb_build_object(
         'y',  count(*) filter (where profile_id = u_yonetici),
         'p',  count(*) filter (where profile_id = u_personel),
         'p2', count(*) filter (where profile_id = u_personel2),
         'b',  count(*) filter (where profile_id = u_pending),
         'd',  count(*) filter (where profile_id = u_disabled))
  into v_json
  from public.notifications where tur = 'ISTISNA';

-- (a) Okunamadı: kayıt yazılır, bildirim YOK, "bildirim bekliyor" işareti var.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now(), null, null, null) into v_id;
perform pg_temp.logout();
if (select count(*) from public.notifications where tur = 'ISTISNA'
     and profile_id in (u_yonetici, u_personel, u_personel2))
   <> (v_json ->> 'y')::int + (v_json ->> 'p')::int + (v_json ->> 'p2')::int
   or not (select bildirim_bekliyor from public.istisnalar where id = v_id) then
  raise exception 'FAIL 67a: bildirim hemen gitti ya da kayıt bekliyor işaretli değil';
end if;

-- (b) 3 dk dolmadan iş çalışırsa hiçbir şey olmaz.
perform public.istisna_bildirim_gonder();
if (select count(*) from public.notifications where tur = 'ISTISNA'
     and profile_id in (u_yonetici, u_personel, u_personel2))
   <> (v_json ->> 'y')::int + (v_json ->> 'p')::int + (v_json ->> 'p2')::int
   or not (select bildirim_bekliyor from public.istisnalar where id = v_id) then
  raise exception 'FAIL 67b: 3 dakika dolmadan bildirim gitti';
end if;

-- (c) 3 dk geçti, kayıt hâlâ açık: herkese TEK bildirim; tercihi kapalı
--     olana, onay bekleyene ve devre dışı olana gitmez; işaret iner; ikinci
--     koşu bir şey yapmaz.
update public.istisnalar set created_at = now() - interval '4 minutes' where id = v_id;
update public.profiles set notif_prefs = coalesce(notif_prefs, '{}'::jsonb) || '{"ISTISNA": false}'::jsonb
 where id = u_personel2;
perform public.istisna_bildirim_gonder();
perform public.istisna_bildirim_gonder();
if (select count(*) from public.notifications where tur = 'ISTISNA' and profile_id = u_yonetici
      and baslik = 'Çözülmemiş kayıt' and govde = 'OKUNAMADI — plaka okunamadı' and link = '/istisnalar')
     < 1
   or (select count(*) from public.notifications where tur = 'ISTISNA' and profile_id = u_yonetici)
     <> (v_json ->> 'y')::int + 1
   or (select count(*) from public.notifications where tur = 'ISTISNA' and profile_id = u_personel)
     <> (v_json ->> 'p')::int + 1
   or (select count(*) from public.notifications where tur = 'ISTISNA' and profile_id = u_personel2)
     <> (v_json ->> 'p2')::int
   or (select count(*) from public.notifications where tur = 'ISTISNA' and profile_id = u_pending)
     <> (v_json ->> 'b')::int
   or (select count(*) from public.notifications where tur = 'ISTISNA' and profile_id = u_disabled)
     <> (v_json ->> 'd')::int then
  raise exception 'FAIL 67c: bildirim herkese tek kez gitmedi (ya da gitmemesi gerekene gitti)';
end if;
if (select bildirim_bekliyor from public.istisnalar where id = v_id) then
  raise exception 'FAIL 67c: gönderilen bildirimin işareti inmedi';
end if;

-- (d) Personel kendi bildirimini OKUYABİLİR (ISTISNA artık yalnızca
--     Yönetici türü değil — RLS ve send-push aynı listeye bakar).
if public.bildirim_yonetici_turu('ISTISNA') then
  raise exception 'FAIL 67d: ISTISNA hâlâ yalnızca Yönetici türü';
end if;
perform pg_temp.login(u_personel);
select count(*) into v_n from public.notifications where tur = 'ISTISNA';
perform pg_temp.logout();
if v_n < 1 then
  raise exception 'FAIL 67d: personel kendi ISTISNA bildirimini göremiyor';
end if;

-- (e) 3 dk dolmadan biri kaydı kapattıysa bildirim hiç gitmez.
select count(*) into v_n from public.notifications where tur = 'ISTISNA' and profile_id = u_yonetici;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now(), null, null, null) into v_id2;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
perform public.istisna_coz(v_id2, 'Test 67e');
perform pg_temp.logout();
update public.istisnalar set created_at = now() - interval '4 minutes' where id = v_id2;
perform public.istisna_bildirim_gonder();
if (select count(*) from public.notifications where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n
   or (select bildirim_bekliyor from public.istisnalar where id = v_id2) then
  raise exception 'FAIL 67e: kapatılmış kayıt için bildirim gitti ya da işaret inmedi';
end if;

-- (f) Okuma servisi arızası kaydı araç başına HİÇ bildirim üretmez (039).
v_islem := gen_random_uuid();
perform pg_temp.kamera();
perform public.kamera_okuma_hatasi('GIRIS', v_islem, now(), 'Test 67f', true, null);
perform pg_temp.logout();
select id into v_id2 from public.istisnalar where islem_id = v_islem;
if v_id2 is null or (select bildirim_bekliyor from public.istisnalar where id = v_id2) then
  raise exception 'FAIL 67f: arıza kaydı yazılmadı ya da bildirim bekliyor işaretli';
end if;
update public.istisnalar set created_at = now() - interval '4 minutes' where id = v_id2;
perform public.istisna_bildirim_gonder();
if (select count(*) from public.notifications where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n then
  raise exception 'FAIL 67f: arıza kaydı araç başına bildirim üretti';
end if;

-- (g) Öbür türler değişmedi: HEMEN ve yalnızca Yöneticiye.
select count(*) into v_n2 from public.notifications where tur = 'ISTISNA' and profile_id = u_personel;
select public.istisna_yaz('ACIK_BILET_YOK', 'CIKIS', 'ZZ67AB707', 'KAMERA',
                          gen_random_uuid(), null, null, now()) into v_id2;
if (select count(*) from public.notifications where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n + 1
   or (select count(*) from public.notifications where tur = 'ISTISNA' and profile_id = u_personel) <> v_n2
   or (select bildirim_bekliyor from public.istisnalar where id = v_id2) then
  raise exception 'FAIL 67g: açık bilet yok kaydı hemen ve yalnızca Yöneticiye gitmedi';
end if;

-- (h) Giriş şeridi: kameranın yeniden denemesi bileti açınca kayıt
--     kendiliğinden kapanır; bekleyen bildirim de hiç gitmez.
select count(*) into v_n from public.notifications where tur = 'ISTISNA' and profile_id = u_yonetici;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now(), null, null, null) into v_id2;
select public.bilet_ac('ZZ67GR808', v_islem, 'KAMERA', now()) into v_bilet;
perform pg_temp.logout();
if v_bilet is null or not exists (
     select 1 from public.istisnalar
      where id = v_id2 and cozuldu_at is not null and cozuldu_by is null
        and cozum_notu = 'Kamera yeniden denedi ve okudu: ZZ67GR808 → GIRIS') then
  raise exception 'FAIL 67h: giriş şeridinde kameranın açtığı bilet kaydı kapatmadı';
end if;
update public.istisnalar set created_at = now() - interval '4 minutes' where id = v_id2;
perform public.istisna_bildirim_gonder();
if (select count(*) from public.notifications where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n then
  raise exception 'FAIL 67h: kendiliğinden kapanan kayıt için bildirim gitti';
end if;

-- (i) Personelin elle açtığı bilet (MOBIL) kaydı tetikle kapatmaz — onu
--     istisna_bilet_ac kendisi kapatır (044).
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now(), null, null, null) into v_id2;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
perform public.bilet_ac('ZZ67MB909', v_islem);
perform pg_temp.logout();
if (select cozuldu_at from public.istisnalar where id = v_id2) is not null then
  raise exception 'FAIL 67i: elle açılan bilet kaydı tetikle kapattı';
end if;

-- (j) Her dakika koşan iş kurulu.
if to_regclass('cron.job') is not null and not exists (
     select 1 from cron.job
      where jobname = 'otopark-istisna-bildirim' and schedule = '* * * * *'
        and command like '%istisna_bildirim_gonder%') then
  raise exception 'FAIL 67j: otopark-istisna-bildirim işi kurulu değil';
end if;

raise notice 'PASS 67: okunamayan plaka bildirimi 3 dk bekler, kayıt hâlâ açıksa herkese bir kez gider; kendiliğinden kapanan kayıt (giriş şeridi dâhil) hiç bildirim üretmez';

-- =====================================================================
-- 68  Giriş saatini düzelt (046)
--     Bilet ekranındaki "Değiştir": araç içerideyken giriş saati düzeltilir.
--     Saati geri almak ücreti artırır, ileri almak düşürür — yani bu PARA:
--       · yalnızca aktif personel (is_staff), yalnızca AÇIK bilet;
--       · ileri bir zaman ve bir yıldan eski saat reddedilir;
--       · sebep zorunlu; her değişiklik audit_log'a eski/yeni/sebep ile
--         yazılır ve Yöneticiye "Ücret değişikliği" bildirimi gider
--         (değiştiren Yöneticinin kendisine gitmez — notify_yonetici);
--       · aynı saat zararsız: iz ve bildirim yazılmaz;
--       · kullanılan puan yeni ücreti aşarsa reddedilir (bilet_kapat çıkışta
--         zaten reddederdi — sorun kapıda değil burada söylenmeli).
-- =====================================================================
perform pg_temp.logout();
if to_regprocedure('public.bilet_giris_duzelt(uuid, timestamptz, text)') is null then
  raise exception 'FAIL 68: bilet_giris_duzelt yok — 046 çalıştırılmadı';
end if;
if not exists (select 1 from public.profiles
                where id = u_personel and rol = 'PERSONEL' and durum = 'ACTIVE') then
  raise exception 'FAIL 68: fixture — u_personel aktif bir Personel değil';
end if;

-- Yöneticilerin bu tür bildirimi kapalı olmasın (bir tercih sayımı bozmasın).
-- u_personel2 de dâhil: PASS 31 onu BİLEREK Yönetici bırakır.
update public.profiles set notif_prefs = coalesce(notif_prefs, '{}'::jsonb) - 'UCRET_DEGISIKLIGI'
 where id in (u_yonetici, u_personel2);

insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
select gen_random_uuid(), 'ZZ68GRS01', now() - interval '2 hours', t.id, 'ACIK'
  from public.tarifeler t where t.gecerli_bitis is null order by t.id limit 1
returning id, giris_at into v_bilet, v_ts;

-- (a) Rolü olmayan ve devre dışı kullanıcı değiştiremez.
foreach v_id in array array[u_pending, u_disabled] loop
  perform pg_temp.login(v_id);
  begin
    perform public.bilet_giris_duzelt(v_bilet, now() - interval '3 hours', 'Test 68a');
    raise exception 'FAIL 68a: rolsüz/devre dışı kullanıcı giriş saatini değiştirdi';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like '%Yetkiniz yok%' then
      raise exception 'FAIL 68a: beklenmeyen hata: %', sqlerrm;
    end if;
  end;
  perform pg_temp.logout();
end loop;

-- (b)–(e) Geçersiz girdiler, her biri kendi sebebiyle reddedilir.
perform pg_temp.login(u_personel);
foreach v_txt in array array['ileri', 'eski', 'sebep_bos', 'sebep_null', 'saat_null'] loop
  begin
    case v_txt
      when 'ileri' then
        perform public.bilet_giris_duzelt(v_bilet, now() + interval '5 minutes', 'Test 68b');
      when 'eski' then
        perform public.bilet_giris_duzelt(v_bilet, now() - interval '1 year 1 day', 'Test 68c');
      when 'sebep_bos' then
        perform public.bilet_giris_duzelt(v_bilet, now() - interval '3 hours', '   ');
      when 'sebep_null' then
        perform public.bilet_giris_duzelt(v_bilet, now() - interval '3 hours', null);
      else
        perform public.bilet_giris_duzelt(v_bilet, null, 'Test 68e');
    end case;
    raise exception 'FAIL 68b-e: % girdisi kabul edildi', v_txt;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    v_txt2 := case v_txt
                when 'ileri'      then '%ileri bir zaman%'
                when 'eski'       then '%bir yıldan eski%'
                when 'saat_null'  then '%Giriş saati boş%'
                else '%Sebep zorunlu%' end;
    if sqlerrm not like v_txt2 then
      raise exception 'FAIL 68b-e: % için beklenmeyen hata: %', v_txt, sqlerrm;
    end if;
  end;
end loop;
perform pg_temp.logout();
if (select giris_at from public.biletler where id = v_bilet) is distinct from v_ts then
  raise exception 'FAIL 68a-e: reddedilen çağrı giriş saatini değiştirdi';
end if;
if exists (select 1 from public.audit_log
            where action = 'bilet_giris_duzeltildi' and row_id = v_bilet) then
  raise exception 'FAIL 68a-e: reddedilen çağrı audit_log''a yazdı';
end if;

-- (f) Personel düzeltir: saat değişir, bir iz, Yöneticiye bir bildirim,
--     öbür personele hiç.
v_ts2 := date_trunc('minute', now()) - interval '3 hours';
perform pg_temp.login(u_personel);
perform public.bilet_giris_duzelt(v_bilet, v_ts2, '  Kamera geç okudu  ');
perform pg_temp.logout();
if (select giris_at from public.biletler where id = v_bilet) is distinct from v_ts2 then
  raise exception 'FAIL 68f: giriş saati değişmedi';
end if;
if not exists (select 1 from public.biletler where id = v_bilet and durum = 'ACIK') then
  raise exception 'FAIL 68f: bilet açık kalmadı';
end if;
if (select count(*) from public.audit_log
     where action = 'bilet_giris_duzeltildi' and row_id = v_bilet and actor = u_personel
       and (detay ->> 'eski')::timestamptz = v_ts
       and (detay ->> 'yeni')::timestamptz = v_ts2
       and detay ->> 'sebep' = 'Kamera geç okudu'
       and detay ->> 'plaka' = 'ZZ68GRS01') <> 1 then
  raise exception 'FAIL 68f: değişiklik audit_log''a eski/yeni/sebep ile yazılmadı';
end if;
if (select count(*) from public.notifications
     where profile_id = u_yonetici and tur = 'UCRET_DEGISIKLIGI'
       and link = '/gise/bilet/' || v_bilet
       and baslik = 'Giriş saati değiştirildi'
       and govde like 'ZZ68GRS01 — %Kamera geç okudu') <> 1 then
  raise exception 'FAIL 68f: Yöneticiye tek bir giriş saati bildirimi gitmedi';
end if;
-- Rol, değişken adına göre değil O ANKİ role göre okunur: PASS 31 u_personel2'yi
-- bilerek Yönetici bırakır, o yüzden o da bildirimi ALMALI. Personel kalan
-- test kullanıcıları hiç almamalı — ve en az biri Personel olmalı, yoksa bu
-- kontrol boşuna geçerdi.
if not exists (select 1 from public.profiles
                where id in (u_personel, u_personel2) and rol = 'PERSONEL' and durum = 'ACTIVE') then
  raise exception 'FAIL 68f: fixture — Personel rolünde test kullanıcısı kalmadı';
end if;
if exists (select 1 from public.notifications n
             join public.profiles p on p.id = n.profile_id
            where p.id in (u_personel, u_personel2) and p.rol = 'PERSONEL'
              and n.link = '/gise/bilet/' || v_bilet) then
  raise exception 'FAIL 68f: Personel giriş saati bildirimi aldı';
end if;
-- Öbür aktif test Yöneticileri de birer tane almalı — bildirim tek kişiye değil
-- bütün Yöneticilere gider.
if exists (select 1 from public.profiles p
            where p.id in (u_personel, u_personel2)
              and p.rol = 'YONETICI' and p.durum = 'ACTIVE'
              and (select count(*) from public.notifications n
                    where n.profile_id = p.id and n.tur = 'UCRET_DEGISIKLIGI'
                      and n.link = '/gise/bilet/' || v_bilet) <> 1) then
  raise exception 'FAIL 68f: her aktif Yöneticiye tek bir giriş saati bildirimi gitmedi';
end if;

-- (g) Aynı saat: zararsız, ikinci iz ve bildirim yok.
perform pg_temp.login(u_personel);
perform public.bilet_giris_duzelt(v_bilet, v_ts2, 'Test 68g');
perform pg_temp.logout();
if (select count(*) from public.audit_log
     where action = 'bilet_giris_duzeltildi' and row_id = v_bilet) <> 1
   -- Yalnızca test Yöneticisi sayılır: canlıdaki gerçek Yönetici de bildirim alır.
   or (select count(*) from public.notifications
        where profile_id = u_yonetici and link = '/gise/bilet/' || v_bilet) <> 1 then
  raise exception 'FAIL 68g: aynı saat ikinci iz ya da bildirim yazdı';
end if;

-- (h) Yönetici düzeltir: iz yazılır, kendine bildirim gitmez.
perform pg_temp.login(u_yonetici);
perform public.bilet_giris_duzelt(v_bilet, v_ts2 - interval '30 minutes', 'Test 68h');
perform pg_temp.logout();
if (select count(*) from public.audit_log
     where action = 'bilet_giris_duzeltildi' and row_id = v_bilet) <> 2 then
  raise exception 'FAIL 68h: Yöneticinin değişikliği audit_log''a yazılmadı';
end if;
if (select count(*) from public.notifications
     where profile_id = u_yonetici and link = '/gise/bilet/' || v_bilet) <> 1 then
  raise exception 'FAIL 68h: Yönetici kendi değişikliği için bildirim aldı';
end if;

-- (i) Kullanılan puan yeni ücreti aşarsa reddedilir.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum,
                             indirim_kurus, puan_kullanilan)
select gen_random_uuid(), 'ZZ68GRS02', now() - interval '5 hours', t.id, 'ACIK', 100000000, 1
  from public.tarifeler t where t.gecerli_bitis is null order by t.id limit 1
returning id, giris_at into v_bilet2, v_ts;
perform pg_temp.login(u_personel);
begin
  perform public.bilet_giris_duzelt(v_bilet2, now() - interval '1 minute', 'Test 68i');
  raise exception 'FAIL 68i: puanı aşan ücrete düşüren saat kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%puan%' then
    raise exception 'FAIL 68i: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if (select giris_at from public.biletler where id = v_bilet2) is distinct from v_ts then
  raise exception 'FAIL 68i: reddedilen çağrı giriş saatini değiştirdi';
end if;

-- (j) Kapanmış bilet ve olmayan bilet açıkça reddedilir.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum, iptal_sebep)
select gen_random_uuid(), 'ZZ68GRS03', now() - interval '5 hours', t.id, 'IPTAL', 'Test 68j'
  from public.tarifeler t where t.gecerli_bitis is null order by t.id limit 1
returning id into v_id2;
perform pg_temp.login(u_personel);
begin
  perform public.bilet_giris_duzelt(v_id2, now() - interval '6 hours', 'Test 68j');
  raise exception 'FAIL 68j: kapanmış biletin giriş saati değişti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%açık değil%' then
    raise exception 'FAIL 68j: beklenmeyen hata: %', sqlerrm;
  end if;
end;
begin
  perform public.bilet_giris_duzelt(gen_random_uuid(), now() - interval '6 hours', 'Test 68j');
  raise exception 'FAIL 68j: olmayan bilet için hata verilmedi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%bulunamadı%' then
    raise exception 'FAIL 68j: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (k) Yalnızca giriş yapmış kullanıcıya açık; kamera ve anon kullanamaz.
if not has_function_privilege('authenticated',
     'public.bilet_giris_duzelt(uuid, timestamptz, text)', 'execute') then
  raise exception 'FAIL 68k: bilet_giris_duzelt authenticated rolüne kapalı';
end if;
foreach v_txt in array array['anon', 'service_role'] loop
  if has_function_privilege(v_txt, 'public.bilet_giris_duzelt(uuid, timestamptz, text)', 'execute') then
    raise exception 'FAIL 68k: bilet_giris_duzelt % rolüne açık', v_txt;
  end if;
end loop;

raise notice 'PASS 68: giriş saati yalnızca aktif personelce, yalnızca açık bilette, sebeple düzeltilir; ileri/çok eski saat ve puanı aşan ücret reddedilir; iz yazılır, Yöneticiye bildirim gider';

-- =====================================================================
-- 69  Edge Function'ların tablo yetkileri yazılı (047)
--     kamera-webhook, plaka-oku ve send-push service_role ile beş tabloya
--     DOĞRUDAN dokunur. 2026-10-30'dan önce açılmış projelerde bu yetkiyi
--     Supabase'in otomatik verdiği izin sağlıyordu; o tarihten sonra açılan
--     YENİ bir projede (birinin kendi kopyası) otomatik izin yok — kamera
--     girişi, plaka okuma ve anlık bildirim "permission denied" ile dururdu.
--     047 tam gerekeni yazılı verir. Eski projede bu blok 047'den önce de
--     geçer (otomatik izin duruyor); asıl görevi yeni kurulumu yakalamak.
--     Fazla yetki aranmaz: eski projede otomatik izin ALL'dır ve kaldırılmaz.
-- =====================================================================
perform pg_temp.logout();
foreach v_txt in array array[
  'public.profiles:SELECT',            -- plaka-oku, send-push: rol/durum/tercih
  'public.otopark_ayarlari:SELECT',    -- kamera-webhook, plaka-oku: ayarlar
  'public.biletler:SELECT',            -- kamera-webhook: açık bilet sayımı
  'public.plaka_okuma_log:SELECT',     -- okuma sınırı sayımı
  'public.plaka_okuma_log:INSERT',     -- her okuma kaydı
  'public.push_subscriptions:SELECT',  -- send-push: aboneler
  'public.push_subscriptions:DELETE',  -- send-push: ölü abonelikleri temizler
  'public.kamera_cihazlari:SELECT'     -- kamera-webhook: cihaz doğrulama (036)
] loop
  if not has_table_privilege('service_role', split_part(v_txt, ':', 1), split_part(v_txt, ':', 2)) then
    raise exception 'FAIL 69: service_role % yetkisi yok — 047 çalıştırılmadı', v_txt;
  end if;
end loop;
-- anon'un hiçbir tabloya dokunamadığını PASS 41(d) zaten bütün şema için sınar.

raise notice 'PASS 69: Edge Function''ların ihtiyaç duyduğu tablo yetkileri service_role''e yazılı verilmiş';

-- =====================================================================
-- 70  Tek kapı geç gelen olayı OLAYIN saatiyle değerlendirir (048)
--     Köprü 1.3.0 internet kesilince araçları diske yazar ve bağlantı
--     dönünce SIRAYLA gönderir. 041'deki pencereler SUNUCU saatine
--     (created_at, cikis_at/iptal_at karşısında now()) bakıyordu; toplu
--     gelen olaylarda (1) girişiyle birlikte gelen çıkış yok sayılıp
--     kayboluyordu, (2) personelin kapattığı aracın geç gelen olayı hayalet
--     bilet açıyordu, (3) personelin elle girdiği aracın geç gelen girişi
--     sahte "kapıda" damgası basıyordu. 048 olayın zamanını (p_zaman)
--     ziyaretin başladığı anla — least(kaynak_zaman, created_at) — ve
--     kapandığı anla kıyaslar. Canlı olayda p_zaman ≈ now(): PASS 58, 63 ve
--     64 hiç değişmeden geçmeli.
--     Süreler ve gecikme sınırı bu blokta sabitlenir (rollback geri alır):
--     canlıdaki ayar ne olursa olsun senaryolar aynı dakikalarla kurulur.
-- =====================================================================
perform pg_temp.logout();
update public.otopark_ayarlari
   set tek_kapi_giris_yoksay_dk = 3, tek_kapi_cikis_yoksay_dk = 5,
       kamera_gecikme_limiti_dk = 720
 where id = 1;

v_liste := array['ZZ70AA001', 'ZZ70BB002', 'ZZ70CC003', 'ZZ70DD004', 'ZZ70DD094',
                 'ZZ70EE005', 'ZZ70EE095'];
if exists (select 1 from public.biletler b, unnest(v_liste) as p(plaka)
            where b.plaka = p.plaka or public.plaka_yakin(b.plaka, p.plaka)) then
  raise exception 'FAIL 70: fixture — ZZ70 plakalarından birine eşit ya da bir karakter yakın bilet var';
end if;

-- T0: kesintinin başladığı an. Bütün olaylar bundan sonra, şimdi teslim edilir.
v_ts := now() - interval '60 minutes';

-- (a) Giriş (T0), aynı aracın ikinci karesi (T0+1) ve çıkışı (T0+30) kesinti
--     bitince birlikte, sırayla gelir. 041 çıkışı "az önce açıldı" diye yok
--     sayıyordu (bilet şimdi açıldı) — araç çıkmış ama bilet açık kalırdı.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ70AA001', v_islem, v_ts) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' then
  raise exception 'FAIL 70a: geç gelen giriş bilet açmadı (%)', v_json;
end if;
v_bilet := (v_json ->> 'bilet_id')::uuid;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ70AA001', gen_random_uuid(), v_ts + interval '1 minute') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' then
  raise exception 'FAIL 70a: aynı aracın bir dakika sonraki karesi yok sayılmadı (%)', v_json;
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ70AA001', gen_random_uuid(), v_ts + interval '30 minutes') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'CIKIS'
   or (v_json ->> 'bilet_id')::uuid is distinct from v_bilet then
  raise exception 'FAIL 70a: girişiyle birlikte gelen çıkış işlenmedi (%)', v_json;
end if;
if (select cikis_bekliyor_at from public.biletler where id = v_bilet)
   is distinct from v_ts + interval '30 minutes' then
  raise exception 'FAIL 70a: "kapıda" damgası olayın saatini taşımıyor';
end if;
-- 054: geç gelen çıkış bileti OLAYIN saatinde kapatır — ücret de o ana kadar.
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'KAPALI' and cikis_kaynak = 'KAMERA'
                  and cikis_at = v_ts + interval '30 minutes' and tahsil_kurus = 0
                  and ucret_kurus = public.ucret_hesapla(giris_at, v_ts + interval '30 minutes',
                                                         tarife_id)) then
  raise exception 'FAIL 70a: geç gelen çıkış bileti olayın saatinde, o ana kadarki ücretle kapatmadı';
end if;

-- (b) Kesintide personel aracı elle girdi (T0+1) ve kapattı (T0+30). Kamera
--     olayları (giriş T0, çıkış T0+30, bir kare daha T0+34) sonradan gelir:
--     ziyaret bitmiş, YENİ BİLET AÇILMAMALI. 041 kapanışı now()'a göre
--     "eski" bulup hayalet bilet açıyordu. (IPTAL, PASS 58(l) gibi: adım 2
--     KAPALI ve IPTAL'i aynı coalesce ile ele alır.)
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum,
                             iptal_sebep, iptal_at, created_at)
select gen_random_uuid(), 'ZZ70BB002', v_ts + interval '1 minute', t.id, 'IPTAL',
       'Test — kesintide elle kapandı', v_ts + interval '30 minutes', v_ts + interval '1 minute'
  from public.tarifeler t order by t.id limit 1;
foreach v_txt in array array['0', '30', '34'] loop
  perform pg_temp.kamera();
  select public.kamera_tek_kapi('ZZ70BB002', gen_random_uuid(),
           v_ts + make_interval(mins => v_txt::integer)) into v_json;
  perform pg_temp.logout();
  if v_json ->> 'karar' is distinct from 'YOKSAY' then
    raise exception 'FAIL 70b: kapanmış ziyaretin T0+% olayı yok sayılmadı (%)', v_txt, v_json;
  end if;
end loop;
if (select count(*) from public.biletler where plaka = 'ZZ70BB002') <> 1 then
  raise exception 'FAIL 70b: kapanmış ziyaretin geç olayı hayalet bilet açtı';
end if;

-- (c) Kesintide personel aracı elle girdi (T0+1, bilet AÇIK). Kameranın T0
--     girişi sonradan gelir: aynı ziyaret, YOK SAYILMALI — 041 bileti "eski"
--     bulup sahte "kapıda" damgası basıyordu. Aracın gerçek çıkışı (T0+30)
--     ise çıkıştır.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum, created_at)
select gen_random_uuid(), 'ZZ70CC003', v_ts + interval '1 minute', t.id, 'ACIK',
       v_ts + interval '1 minute'
  from public.tarifeler t order by t.id limit 1
returning id into v_bilet2;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ70CC003', gen_random_uuid(), v_ts) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY'
   or (select cikis_bekliyor_at from public.biletler where id = v_bilet2) is not null then
  raise exception 'FAIL 70c: elle girilen aracın geç gelen girişi "kapıda" damgası bastı (%)', v_json;
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ70CC003', gen_random_uuid(), v_ts + interval '30 minutes') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'CIKIS'
   or (select cikis_bekliyor_at from public.biletler where id = v_bilet2)
      is distinct from v_ts + interval '30 minutes' then
  raise exception 'FAIL 70c: elle girilen aracın geç gelen çıkışı işlenmedi (%)', v_json;
end if;

-- (d) Bir karakter benzeri AÇIK bilet (adım 3): girişten bir dakika sonraki
--     yanlış okuma aynı araçtır (yok say); yarım saat sonraki benzeri ise
--     belirsizdir, insana gider. 041 ikisini de now()'a göre "yeni" bulup
--     yok sayıyordu.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ70DD004', gen_random_uuid(), v_ts) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' then
  raise exception 'FAIL 70d: fixture — ZZ70DD004 girişi açılmadı (%)', v_json;
end if;
v_bilet := (v_json ->> 'bilet_id')::uuid;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ70DD094', gen_random_uuid(), v_ts + interval '1 minute') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' then
  raise exception 'FAIL 70d: girişten bir dakika sonraki benzer okuma yok sayılmadı (%)', v_json;
end if;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ70DD094', v_islem, v_ts + interval '30 minutes') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'ISTISNA'
   or v_json ->> 'sebep' is distinct from 'BENZER_ACIK'
   or exists (select 1 from public.biletler where plaka = 'ZZ70DD094')
   or (select cikis_bekliyor_at from public.biletler where id = v_bilet) is not null
   or not exists (select 1 from public.istisnalar
                   where islem_id = v_islem and tur::text = 'YON_BELIRSIZ') then
  raise exception 'FAIL 70d: yarım saat sonraki benzer okuma insana gitmedi (%)', v_json;
end if;

-- (e) Bir karakter benzeri KAPANMIŞ ziyaret (adım 4): kapanıştan bir dakika
--     sonraki yanlış okuma çıkan araçtır — bilet açılmamalı.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum,
                             iptal_sebep, iptal_at, created_at)
select gen_random_uuid(), 'ZZ70EE005', v_ts, t.id, 'IPTAL',
       'Test — kesintide elle kapandı', v_ts + interval '30 minutes', v_ts
  from public.tarifeler t order by t.id limit 1;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ70EE095', gen_random_uuid(), v_ts + interval '31 minutes') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY'
   or exists (select 1 from public.biletler where plaka = 'ZZ70EE095') then
  raise exception 'FAIL 70e: kapanmış ziyaretin benzer okuması bilet açtı (%)', v_json;
end if;

-- (f) Yok sayma OLAY saatinde de geçicidir: (b)'deki araç şimdi (kapanıştan
--     yarım saat sonra) gelirse yeni bir park süresidir, bilet açılmalı.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ70BB002', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS'
   or not exists (select 1 from public.biletler where plaka = 'ZZ70BB002' and durum = 'ACIK') then
  raise exception 'FAIL 70f: kapanıştan çok sonra gelen araca bilet açılmadı (%)', v_json;
end if;

raise notice 'PASS 70: tek kapı geç gelen olayı olayın saatiyle değerlendirir — birlikte gelen çıkış kaybolmaz, kapanmış ziyaret hayalet bilet açmaz, elle girilen araç sahte çıkış almaz';

-- =====================================================================
-- 71  Eski vardiyayı silme (049)
--     Yalnızca Yönetici, yalnızca KAPANMIŞ vardiya. Silme YUMUŞAKTIR: satır
--     kalır (silindi_at), RLS onu herkesten gizler, Çöp Kutusu'na bir kayıt
--     düşer. Para hiç değişmez: o vardiyanın bileti ve tahsilatı bağıyla ve
--     tutarıyla aynen kalır — kasa ve raporlar oynamaz. Geri al satırı geri
--     getirir; kalıcı sil gerçekten siler (bağlar null'a düşer, tutarlar
--     yine aynı kalır).
-- =====================================================================
perform pg_temp.logout();
if not exists (select 1 from public.profiles
                where id = u_yonetici and rol = 'YONETICI' and durum = 'ACTIVE')
   or not exists (select 1 from public.profiles
                   where id = u_personel and rol = 'PERSONEL' and durum = 'ACTIVE') then
  raise exception 'FAIL 71: fixture — u_yonetici Yönetici ya da u_personel Personel değil';
end if;

-- Kapanmış bir vardiya, ona bağlı kapanmış bir bilet ve onaylı tahsilatı.
insert into public.vardiyalar (personel_id, acilis_at, kapanis_at, acilis_nakit_kurus,
                               beklenen_nakit_kurus, sayilan_nakit_kurus, fark_kurus,
                               kapanis_kaynak)
values (u_personel, now() - interval '40 days', now() - interval '39 days 16 hours', 0,
        4000, 3500, -500, 'ELLE')
returning id into v_id;
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum,
                             ucret_kurus, tahsil_kurus, odeme_yontemi,
                             vardiya_id, kapatan_vardiya_id, created_at)
select gen_random_uuid(), 'ZZ71VRD01', now() - interval '40 days',
       now() - interval '39 days 20 hours', t.id, 'KAPALI', 4000, 4000, 'NAKIT',
       v_id, v_id, now() - interval '40 days'
  from public.tarifeler t order by t.id limit 1
returning id into v_bilet;
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, durum)
values ('BILET', v_bilet, 4000, 'NAKIT', v_id, 'ONAYLANDI')
returning id into v_id2;

-- (a) Personel silemez.
perform pg_temp.login(u_personel);
begin
  perform public.vardiya_sil(v_id);
  raise exception 'FAIL 71a: Personel vardiya sildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yalnızca Yönetici%' then
    raise exception 'FAIL 71a: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (b) Açık vardiya silinemez (kapatma isteği de yalnızca açık vardiyada durur).
select id into v_vardiya from public.vardiyalar where kapanis_at is null limit 1;
if v_vardiya is null then
  insert into public.vardiyalar (personel_id, acilis_at, acilis_nakit_kurus)
  values (u_personel, now() - interval '1 hour', 0)
  returning id into v_vardiya;
end if;
perform pg_temp.login(u_yonetici);
begin
  perform public.vardiya_sil(v_vardiya);
  raise exception 'FAIL 71b: açık vardiya silindi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Açık vardiya silinemez%' then
    raise exception 'FAIL 71b: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if exists (select 1 from public.vardiyalar where id = v_vardiya and silindi_at is not null) then
  raise exception 'FAIL 71b: açık vardiya silindi olarak işaretlendi';
end if;

-- (c) Yönetici siler: Yönetici bile artık görmez; satır durur, çöpe ve
--     denetim kaydına düşer.
perform pg_temp.login(u_yonetici);
perform public.vardiya_sil(v_id);
select count(*) into v_n from public.vardiyalar where id = v_id;
perform pg_temp.logout();
if v_n <> 0 then
  raise exception 'FAIL 71c: silinen vardiya Yöneticiye hâlâ görünüyor';
end if;
if not exists (select 1 from public.vardiyalar
                where id = v_id and silindi_at is not null and silen = u_yonetici) then
  raise exception 'FAIL 71c: vardiya satırı silindi olarak işaretlenmedi';
end if;
select id into v_id2 from public.cop where tablo = 'vardiyalar' and kayit_id = v_id;
if v_id2 is null then
  raise exception 'FAIL 71c: silinen vardiya Çöp Kutusu''na düşmedi';
end if;
if not exists (select 1 from public.audit_log
                where action = 'vardiya_sil' and row_id = v_id and actor = u_yonetici) then
  raise exception 'FAIL 71c: silme audit_log''a yazılmadı';
end if;

-- (d) Para değişmez: bilet ve tahsilat bağıyla, tutarıyla, durumuyla aynen.
if not exists (select 1 from public.biletler
                where id = v_bilet and vardiya_id = v_id and kapatan_vardiya_id = v_id
                  and tahsil_kurus = 4000 and durum = 'KAPALI')
   or not exists (select 1 from public.tahsilatlar
                   where bilet_id = v_bilet and vardiya_id = v_id
                     and tutar_kurus = 4000 and durum = 'ONAYLANDI') then
  raise exception 'FAIL 71d: vardiya silinince bilet ya da tahsilat değişti';
end if;

-- (e) İkinci kez silinemez.
perform pg_temp.login(u_yonetici);
begin
  perform public.vardiya_sil(v_id);
  raise exception 'FAIL 71e: silinmiş vardiya ikinci kez silindi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();

-- (f) Geri al: vardiya yeniden görünür, çöp kaydı kalkar, bağlar yerinde.
perform pg_temp.login(u_yonetici);
perform public.cop_geri_al(v_id2);
select count(*) into v_n from public.vardiyalar where id = v_id;
perform pg_temp.logout();
if v_n <> 1
   or exists (select 1 from public.vardiyalar where id = v_id and silindi_at is not null)
   or exists (select 1 from public.cop where id = v_id2) then
  raise exception 'FAIL 71f: Geri al vardiyayı geri getirmedi';
end if;
if not exists (select 1 from public.tahsilatlar
                where bilet_id = v_bilet and vardiya_id = v_id and tutar_kurus = 4000) then
  raise exception 'FAIL 71f: geri alınan vardiyanın tahsilat bağı kayboldu';
end if;

-- (g) Kalıcı sil: satır gider, bağlar null'a düşer, tutarlar aynı kalır.
perform pg_temp.login(u_yonetici);
perform public.vardiya_sil(v_id);
perform pg_temp.logout();
select id into v_id2 from public.cop where tablo = 'vardiyalar' and kayit_id = v_id;
perform pg_temp.login(u_yonetici);
perform public.cop_kalici_sil(v_id2);
perform pg_temp.logout();
if exists (select 1 from public.vardiyalar where id = v_id)
   or exists (select 1 from public.cop where id = v_id2) then
  raise exception 'FAIL 71g: kalıcı sil vardiyayı silmedi';
end if;
if not exists (select 1 from public.biletler
                where id = v_bilet and vardiya_id is null and kapatan_vardiya_id is null
                  and tahsil_kurus = 4000 and durum = 'KAPALI')
   or not exists (select 1 from public.tahsilatlar
                   where bilet_id = v_bilet and vardiya_id is null
                     and tutar_kurus = 4000 and durum = 'ONAYLANDI') then
  raise exception 'FAIL 71g: kalıcı silmede bilet ya da tahsilat tutarı değişti';
end if;

-- (h) Yetki: yalnızca giriş yapmış kullanıcı çağırabilir (rolü gövde denetler).
if has_function_privilege('anon', 'public.vardiya_sil(uuid)', 'execute')
   or has_function_privilege('service_role', 'public.vardiya_sil(uuid)', 'execute')
   or not has_function_privilege('authenticated', 'public.vardiya_sil(uuid)', 'execute') then
  raise exception 'FAIL 71h: vardiya_sil yetkileri yanlış';
end if;

raise notice 'PASS 71: eski vardiyayı yalnızca Yönetici siler, yalnızca kapanmışsa; silinen herkesten gizlenir ve çöpe düşer; para hiç değişmez; geri al ve kalıcı sil çalışır';

-- =====================================================================
-- 72  Personelin bilet iptali Yönetici onayına düşer (050)
--     Personel açık bileti artık İPTAL ETMEZ, iptal İSTER: bilet açık kalır,
--     istek bilette durur, Yöneticiye bildirim gider. Onay iptal eder (sebep
--     personelinki), ret isteği siler ve bileti açık bırakır; ikisi de
--     isteyene bildirilir ve audit_log'a yazılır (Onay ekranının geçmişi
--     oradan okunur). Araç bu arada çıkarsa istek düşer. Yönetici eskisi gibi
--     doğrudan iptal eder; personel kapanmış bileti hâlâ iptal edemez.
-- =====================================================================
perform pg_temp.logout();
if not exists (select 1 from public.profiles
                where id = u_yonetici and rol = 'YONETICI' and durum = 'ACTIVE')
   or not exists (select 1 from public.profiles
                   where id = u_personel and rol = 'PERSONEL' and durum = 'ACTIVE') then
  raise exception 'FAIL 72: fixture — u_yonetici Yönetici ya da u_personel Personel değil';
end if;
v_liste := array['ZZ72IPT01', 'ZZ72IPT02', 'ZZ72IPT03', 'ZZ72IPT04'];
if exists (select 1 from public.biletler b, unnest(v_liste) as p(plaka)
            where b.plaka = p.plaka and b.durum = 'ACIK') then
  raise exception 'FAIL 72: fixture — ZZ72 plakalarından birinin açık bileti var';
end if;
update public.profiles set notif_prefs = coalesce(notif_prefs, '{}'::jsonb) - 'BILET_IPTAL_TALEBI'
 where id = u_yonetici;
update public.profiles set notif_prefs = coalesce(notif_prefs, '{}'::jsonb) - 'BILET_IPTAL_KARAR'
 where id = u_personel;

insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
select gen_random_uuid(), 'ZZ72IPT01', now() - interval '1 hour', t.id, 'ACIK'
  from public.tarifeler t order by t.id limit 1
returning id into v_bilet;

-- (a) Personelin iptali bir İSTEKTİR: bilet açık kalır, istek bilette durur,
--     Yöneticiye bildirim ve iz düşer.
perform pg_temp.login(u_personel);
perform public.bilet_iptal(v_bilet, '  Yanlış plaka girildi  ');
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'ACIK'
                  and iptal_talebi_at is not null and iptal_talebi_by = u_personel
                  and iptal_talebi_sebep = 'Yanlış plaka girildi') then
  raise exception 'FAIL 72a: personelin iptali istek olarak yazılmadı ya da bilet kapandı';
end if;
if not exists (select 1 from public.audit_log
                where action = 'bilet_iptal_talebi' and row_id = v_bilet and actor = u_personel) then
  raise exception 'FAIL 72a: iptal isteği audit_log''a yazılmadı';
end if;
if not exists (select 1 from public.notifications
                where profile_id = u_yonetici and tur::text = 'BILET_IPTAL_TALEBI'
                  and link = '/finans/onay') then
  raise exception 'FAIL 72a: Yöneticiye iptal isteği bildirimi gitmedi';
end if;
-- Gişe listesi (acik_bilet_ara) bekleyen isteği personele de gösterir.
perform pg_temp.login(u_personel);
select a.iptal_talebi into v_bool from public.acik_bilet_ara('ZZ72IPT01') a where a.id = v_bilet;
perform pg_temp.logout();
if v_bool is distinct from true then
  raise exception 'FAIL 72a: Gişe listesi bekleyen iptal isteğini göstermiyor';
end if;

-- (b) Bekleyen isteğin üstüne ikinci istek yazılmaz.
perform pg_temp.login(u_personel);
begin
  perform public.bilet_iptal(v_bilet, 'ikinci istek');
  raise exception 'FAIL 72b: bekleyen isteğin üstüne ikinci istek yazıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%onay bekliyor%' then
    raise exception 'FAIL 72b: beklenmeyen hata: %', sqlerrm;
  end if;
end;

-- (c) Kararı personel veremez.
begin
  perform public.bilet_iptal_onayla(v_bilet);
  raise exception 'FAIL 72c: personel iptal isteğini onayladı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yalnızca Yönetici%' then
    raise exception 'FAIL 72c: beklenmeyen hata (onayla): %', sqlerrm;
  end if;
end;
begin
  perform public.bilet_iptal_reddet(v_bilet, null);
  raise exception 'FAIL 72c: personel iptal isteğini reddetti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yalnızca Yönetici%' then
    raise exception 'FAIL 72c: beklenmeyen hata (reddet): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (d) Ret: bilet açık kalır, istek silinir, iz ve isteyene bildirim.
perform pg_temp.login(u_yonetici);
perform public.bilet_iptal_reddet(v_bilet, '  Araç hâlâ içeride  ');
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'ACIK' and iptal_talebi_at is null
                  and iptal_talebi_by is null and iptal_talebi_sebep is null) then
  raise exception 'FAIL 72d: ret sonrası bilet açık değil ya da istek silinmedi';
end if;
if not exists (select 1 from public.audit_log
                where action = 'bilet_iptal_ret' and row_id = v_bilet and actor = u_yonetici
                  and (detay ->> 'talep_eden')::uuid = u_personel
                  and detay ->> 'sebep' = 'Yanlış plaka girildi'
                  and detay ->> 'ret_sebep' = 'Araç hâlâ içeride') then
  raise exception 'FAIL 72d: ret audit_log''a isteyen ve sebeplerle yazılmadı';
end if;
if not exists (select 1 from public.notifications
                where profile_id = u_personel and tur::text = 'BILET_IPTAL_KARAR'
                  and govde like '%Araç hâlâ içeride%') then
  raise exception 'FAIL 72d: isteyene ret bildirimi gitmedi';
end if;

-- (e) Onay: bilet iptal edilir, sebep personelinkidir; istek silinir; iz ve
--     isteyene bildirim.
perform pg_temp.login(u_personel);
perform public.bilet_iptal(v_bilet, 'Test girişi');
perform pg_temp.logout();
perform pg_temp.login(u_yonetici);
perform public.bilet_iptal_onayla(v_bilet);
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'IPTAL' and iptal_sebep = 'Test girişi'
                  and iptal_talebi_at is null) then
  raise exception 'FAIL 72e: onay bileti personelin sebebiyle iptal etmedi';
end if;
if not exists (select 1 from public.audit_log
                where action = 'bilet_iptal_onay' and row_id = v_bilet and actor = u_yonetici
                  and (detay ->> 'talep_eden')::uuid = u_personel
                  and detay ->> 'sebep' = 'Test girişi') then
  raise exception 'FAIL 72e: onay audit_log''a yazılmadı';
end if;
if exists (select 1 from public.audit_log
            where action = 'bilet_iptal_talebi_dustu' and row_id = v_bilet) then
  raise exception 'FAIL 72e: onaylanan istek "düştü" diye de yazıldı';
end if;
if (select count(*) from public.notifications
     where profile_id = u_personel and tur::text = 'BILET_IPTAL_KARAR') <> 2 then
  raise exception 'FAIL 72e: isteyene onay bildirimi gitmedi';
end if;

-- (f) İstek beklerken araç çıkarsa istek düşer; onaylanacak bir şey kalmaz.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
select gen_random_uuid(), 'ZZ72IPT02', now() - interval '1 hour', t.id, 'ACIK'
  from public.tarifeler t order by t.id limit 1
returning id into v_bilet2;
perform pg_temp.login(u_personel);
perform public.bilet_iptal(v_bilet2, 'Yanlış giriş');
perform pg_temp.logout();
update public.biletler set durum = 'KAPALI', cikis_at = now() where id = v_bilet2;
if not exists (select 1 from public.biletler
                where id = v_bilet2 and durum = 'KAPALI' and iptal_talebi_at is null
                  and iptal_talebi_by is null and iptal_talebi_sebep is null) then
  raise exception 'FAIL 72f: çıkan aracın iptal isteği düşmedi';
end if;
if not exists (select 1 from public.audit_log
                where action = 'bilet_iptal_talebi_dustu' and row_id = v_bilet2) then
  raise exception 'FAIL 72f: düşen istek audit_log''a yazılmadı';
end if;
perform pg_temp.login(u_yonetici);
begin
  perform public.bilet_iptal_onayla(v_bilet2);
  raise exception 'FAIL 72f: düşmüş istek onaylandı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%iptal isteği yok%' then
    raise exception 'FAIL 72f: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (g) Personel kapanmış bileti hâlâ iptal edemez (istek de yazamaz).
perform pg_temp.login(u_personel);
begin
  perform public.bilet_iptal(v_bilet2, 'Kapanmışı iptal');
  raise exception 'FAIL 72g: personel kapanmış bilet için iptal yazdı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%yalnızca Yönetici%' then
    raise exception 'FAIL 72g: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (h) Yönetici eskisi gibi DOĞRUDAN iptal eder — istek yazılmaz.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
select gen_random_uuid(), 'ZZ72IPT03', now() - interval '1 hour', t.id, 'ACIK'
  from public.tarifeler t order by t.id limit 1
returning id into v_bilet2;
perform pg_temp.login(u_yonetici);
perform public.bilet_iptal(v_bilet2, 'Yönetici iptali');
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet2 and durum = 'IPTAL' and iptal_talebi_at is null) then
  raise exception 'FAIL 72h: Yönetici iptali doğrudan iptal etmedi';
end if;

-- (i) Bildirim türleri ve yetkiler.
if not public.bildirim_yonetici_turu('BILET_IPTAL_TALEBI') then
  raise exception 'FAIL 72i: BILET_IPTAL_TALEBI Yönetici türü değil';
end if;
if public.bildirim_yonetici_turu('BILET_IPTAL_KARAR') then
  raise exception 'FAIL 72i: BILET_IPTAL_KARAR Yönetici türü sayıldı (isteyen personele gider)';
end if;
foreach v_txt in array array['public.bilet_iptal_onayla(uuid)',
                             'public.bilet_iptal_reddet(uuid, text)',
                             'public.bilet_iptal(uuid, text)',
                             -- 050 yeniden yarattı: Supabase'in yeni fonksiyona
                             -- verdiği varsayılan yetkiler geri alınmış olmalı.
                             'public.acik_bilet_ara(text)'] loop
  if has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('service_role', v_txt, 'execute')
     or not has_function_privilege('authenticated', v_txt, 'execute') then
    raise exception 'FAIL 72i: % yetkileri yanlış', v_txt;
  end if;
end loop;
if has_function_privilege('authenticated', 'public.bilet_iptal_talebi_temizle()', 'execute') then
  raise exception 'FAIL 72i: istek temizleme tetiği istemciye açık';
end if;

raise notice 'PASS 72: personelin bilet iptali Yönetici onayına düşer; onay iptal eder, ret açık bırakır, ikisi de iz ve bildirim bırakır; çıkan aracın isteği düşer; Yönetici doğrudan iptal eder';

-- =====================================================================
-- 73  Kademeli tarife (051)
--     Sahibin fiyat listesi: 0–2 sa 200 ₺, 2–4 sa 300 ₺, 4–8 sa 400 ₺,
--     8–24 sa 500 ₺. Sınır alttaki kademeye aittir (2:00 = 200, 2:01 = 300);
--     dakika yukarı yuvarlanır (bugünkü gibi). 24 saati aşınca her TAM gün
--     500 ₺ ve kalan süre yine kademelerle (30 sa = 900, 48 sa = 1000,
--     24 sa 1 dk = 700). Ücretsiz süre ve kayıp bilet bugünkü gibi. Süreli ve
--     sabit tarife hiç değişmez; içerideki aracın tarifesi değişmez.
-- =====================================================================
perform pg_temp.logout();
v_json := '[{"dakika":120,"kurus":20000},{"dakika":240,"kurus":30000},
            {"dakika":480,"kurus":40000},{"dakika":1440,"kurus":50000}]'::jsonb;

-- (a) Saf hesap — her örnek elle kontrol edildi.
foreach v_txt in array array[
    '0:0', '5:0', '6:20000', '120:20000', '121:30000', '240:30000', '241:40000',
    '480:40000', '481:50000', '1440:50000', '1441:70000', '1800:90000',
    '2880:100000', '2881:120000'] loop
  v_n  := split_part(v_txt, ':', 1)::integer;
  v_n2 := split_part(v_txt, ':', 2)::integer;
  if public.ucret_kademeli(v_n, 5, v_json) <> v_n2 then
    raise exception 'FAIL 73a: % dakika % kuruş olmalıydı, % çıktı',
      v_n, v_n2, public.ucret_kademeli(v_n, 5, v_json);
  end if;
end loop;

-- (b) Geçersiz kademe listeleri reddedilir (biri 24 saatte bitmiyor, biri
--     sırasız, biri boş, biri eksi, biri kesirli, biri pahalıdan ucuza).
foreach v_txt in array array[
    '[{"dakika":120,"kurus":20000},{"dakika":480,"kurus":40000}]',
    '[{"dakika":240,"kurus":30000},{"dakika":120,"kurus":20000},{"dakika":1440,"kurus":50000}]',
    '[]',
    '[{"dakika":120,"kurus":-1},{"dakika":1440,"kurus":50000}]',
    '[{"dakika":120.5,"kurus":20000},{"dakika":1440,"kurus":50000}]',
    '[{"dakika":120,"kurus":30000},{"dakika":1440,"kurus":20000}]',
    '{"dakika":1440,"kurus":50000}',
    '[{"dakika":1440}]'] loop
  if public.kademeler_gecerli(v_txt::jsonb) then
    raise exception 'FAIL 73b: geçersiz kademe listesi kabul edildi: %', v_txt;
  end if;
end loop;
if not public.kademeler_gecerli(v_json)
   or not public.kademeler_gecerli('[{"dakika":1440,"kurus":50000}]'::jsonb) then
  raise exception 'FAIL 73b: geçerli kademe listesi reddedildi';
end if;

-- (c) Personel tarife yazamaz.
perform pg_temp.login(u_personel);
begin
  perform public.tarife_guncelle(5, 0, 0, 0, 20000, 'KADEMELI', 0, v_json);
  raise exception 'FAIL 73c: Personel kademeli tarife yazdı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yalnızca Yönetici%' then
    raise exception 'FAIL 73c: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (d) Önce içeride bir araç (süreli tarifeyle), sonra Yönetici kademeli
--     tarifeye geçer: içerideki aracın ücreti DEĞİŞMEZ (sürümleme).
perform pg_temp.login(u_yonetici);
select public.tarife_guncelle(15, 6000, 3000, 25000, 40000, 'SURELI', 0) into v_tarife_eski;
v_ucret := public.ucret_hesapla(now() - interval '3 hours', now(), v_tarife_eski);
select public.tarife_guncelle(5, 0, 0, 0, 20000, 'KADEMELI', 0, v_json) into v_id;
perform pg_temp.logout();
if public.ucret_hesapla(now() - interval '3 hours', now(), v_tarife_eski) <> v_ucret then
  raise exception 'FAIL 73d: kademeli tarifeye geçmek eski tarifeyle fiyatlanan aracı etkiledi';
end if;
if not exists (select 1 from public.tarifeler
                where id = v_id and tur::text = 'KADEMELI' and kademeler = v_json
                  and ilk_saat_kurus = 0 and sonraki_saat_kurus = 0
                  and gunluk_tavan_kurus = 0 and sabit_kurus = 0
                  and ucretsiz_dakika = 5 and kayip_bilet_kurus = 20000
                  and gecerli_bitis is null) then
  raise exception 'FAIL 73d: kademeli tarife beklenen biçimde yazılmadı';
end if;

-- (e) Gerçek ücret yolu (ucret_hesapla) kademeli tarifeyi saf hesapla aynı fiyatlar.
foreach v_txt in array array['5:0', '6:20000', '120:20000', '121:30000',
                             '1441:70000', '1800:90000', '2880:100000'] loop
  v_n  := split_part(v_txt, ':', 1)::integer;
  v_n2 := split_part(v_txt, ':', 2)::integer;
  if public.ucret_hesapla(now() - make_interval(mins => v_n), now(), v_id) <> v_n2 then
    raise exception 'FAIL 73e: ucret_hesapla % dakikada % kuruş olmalıydı', v_n, v_n2;
  end if;
end loop;
-- Saniyeler yukarı yuvarlanır: 2 sa 0 dk 30 sn = 121. dakika → 300 ₺.
if public.ucret_hesapla(now() - interval '120 minutes 30 seconds', now(), v_id) <> 30000 then
  raise exception 'FAIL 73e: kademe sınırında saniye yukarı yuvarlanmadı';
end if;

-- (f) Sunucu geçersiz listeyi ve listesiz kademeli tarifeyi reddeder;
--     kademe listesi kademeli olmayan tarifeye yazılmaz.
perform pg_temp.login(u_yonetici);
begin
  perform public.tarife_guncelle(5, 0, 0, 0, 20000, 'KADEMELI', 0,
    '[{"dakika":120,"kurus":20000}]'::jsonb);
  raise exception 'FAIL 73f: 24 saatte bitmeyen liste kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Kademe listesi geçersiz%' then
    raise exception 'FAIL 73f: beklenmeyen hata: %', sqlerrm;
  end if;
end;
begin
  perform public.tarife_guncelle(5, 0, 0, 0, 20000, 'KADEMELI', 0, null);
  raise exception 'FAIL 73f: listesiz kademeli tarife kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Kademe listesi geçersiz%' then
    raise exception 'FAIL 73f: beklenmeyen hata (liste yok): %', sqlerrm;
  end if;
end;
select public.tarife_guncelle(15, 6000, 3000, 25000, 40000, 'SURELI', 0, v_json) into v_id2;
perform pg_temp.logout();
if exists (select 1 from public.tarifeler where id = v_id2 and kademeler is not null) then
  raise exception 'FAIL 73f: süreli tarifeye kademe listesi yazıldı';
end if;

-- (g) Süreli ve sabit tarife sonuçları değişmedi (PASS 42 ile aynı değerler).
perform pg_temp.login(u_yonetici);
select public.tarife_guncelle(15, 0, 0, 0, 40000, 'SABIT', 5000) into v_id2;
perform pg_temp.logout();
if public.ucret_hesapla(now() - interval '10 hours', now(), v_id2) <> 5000
   or public.ucret_hesapla(now() - interval '10 minutes', now(), v_id2) <> 0 then
  raise exception 'FAIL 73g: sabit tarife sonucu değişti';
end if;

-- (h) Yetkiler: yazma yolu yalnızca giriş yapmış kullanıcıya açık (rolü
--     gövde denetler); saf hesap ve doğrulayıcı istemciye açık değil.
-- 078: imza 9 argümanlı oldu (p_yikama_kurus); 8 argümanlı düşürüldü.
v_txt := 'public.tarife_guncelle(integer, integer, integer, integer, integer, public.tarife_tur, integer, jsonb, integer)';
if has_function_privilege('anon', v_txt, 'execute')
   or has_function_privilege('service_role', v_txt, 'execute')
   or not has_function_privilege('authenticated', v_txt, 'execute') then
  raise exception 'FAIL 73h: tarife_guncelle yetkileri yanlış';
end if;
if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'tarife_guncelle') <> 1 then
  raise exception 'FAIL 73h: tarife_guncelle birden çok imzayla duruyor';
end if;
foreach v_txt in array array['public.ucret_kademeli(bigint, integer, jsonb)',
                             'public.kademeler_gecerli(jsonb)'] loop
  if has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('authenticated', v_txt, 'execute')
     or has_function_privilege('service_role', v_txt, 'execute') then
    raise exception 'FAIL 73h: % istemciye açık', v_txt;
  end if;
end loop;

raise notice 'PASS 73: kademeli tarife sahibin listesini doğru fiyatlar (sınır alt kademede, 24 saat sonrası gün + kademe), geçersiz liste reddedilir, süreli/sabit ve içerideki araç etkilenmez';

-- =====================================================================
-- 74  "Kapıda" işareti uygulamadan kalktı (052)
--     Sahip (2026-11-10): Gişe'deki "Kapıda" rozeti, "N araç çıkış
--     kapısında bekliyor" şeridi ve "Araç çıkmadı" düğmesi kaldırıldı. Damga
--     görünmediği için açık bilet listesi onu sıralamada KULLANMAZ (görünmez
--     bir sebeple en üstte duran araç olmasın). 052'nin "her yeni çıkış anı
--     bildirim" kuralı 054 ile yerini kameranın bileti kapatmasına bıraktı:
--     bildirim artık kapanışın kendisinden gelir (PASS 75).
-- =====================================================================
perform pg_temp.logout();
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
select gen_random_uuid(), 'ZZ74KPA01', now() - interval '2 hours', t.id, 'ACIK'
  from public.tarifeler t where t.gecerli_bitis is null order by t.id limit 1
returning id into v_bilet;
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
select gen_random_uuid(), 'ZZ74KPA02', now() - interval '1 hour', t.id, 'ACIK'
  from public.tarifeler t where t.gecerli_bitis is null order by t.id limit 1
returning id into v_bilet2;
-- Damga doğrudan: 054'ten beri kameranın çıkışı bileti kapatır (PASS 75).
update public.biletler set cikis_bekliyor_at = now() - interval '2 minutes' where id = v_bilet;

-- (a) Liste: damgalı eski giriş, damgasız yeni girişin önüne GEÇMEZ.
perform pg_temp.login(u_personel);
select a.id into v_id from public.acik_bilet_ara('ZZ74KPA') a limit 1;
perform pg_temp.logout();
if v_id is distinct from v_bilet2 then
  raise exception 'FAIL 74a: açık bilet listesi hâlâ görünmeyen kapıda damgasıyla sıralıyor';
end if;

raise notice 'PASS 74: görünmeyen kapıda damgası açık bilet listesini sıralamaz';

-- =====================================================================
-- 75  Kamera bileti kapatır; ödeme "Ödeme topla" ile toplanır (053, 054)
--     Sahip (2026-11-10): çıkan araç "Çıktı" görünmeli. Kameranın çıkışı
--     bileti OLAYIN saatinde, o ana kadarki ücretle, ÖDEMESİZ kapatır (para
--     hareket etmez); borç, kapandığı kasa vardiyasında toplanır (bilet_tahsil,
--     yalnızca o vardiya — sahibin seçimi) ve tahsilat Onay'da Yöneticiyi
--     bekler. Herkes "Ödeme bekliyor" bildirimi alır. Kamera yanlış kapattıysa
--     "Araç çıkmadı" bileti geri açar — yalnızca kameranın kapattığı, parası
--     alınmamış bilette. Benzer plaka (son dört karakter) asla kapatmaz.
-- =====================================================================
perform pg_temp.logout();

-- Bilinen tarife: ilk 15 dakika ücretsiz, sonra sabit 50 ₺ (73g'nin aynısı).
perform pg_temp.login(u_yonetici);
select public.tarife_guncelle(15, 0, 0, 0, 40000, 'SABIT', 5000) into v_tarife_yeni;
perform pg_temp.logout();

-- Bilinen kasa vardiyası (PASS 52 deseni): açık olanlar kapanır, personel açar.
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE'
 where kapanis_at is null;
perform pg_temp.login(u_personel);
select public.vardiya_ac(0) into v_vardiya;
perform pg_temp.logout();

v_liste := array['ZZ75KMR01', 'ZZ75KMR02', 'ZZ75KMR04', 'ZZ75KMR05', 'ZZ75KMR06',
                 'ZZ75KMR07', 'ZZ75KMR08', 'ZZ75KMR09', 'ZZ75KMR10', 'ZZ75KMR11',
                 'ZZ75KMR12', 'ZZ75KMR13', 'ZZ75MOB03', 'ZZ75Q9T1'];
if exists (select 1 from public.park_yerleri where kod in ('ZZ75-P', 'ZZ75-R')) then
  raise exception 'FAIL 75: fixture — ZZ75-P / ZZ75-R park yeri zaten var';
end if;
if exists (select 1 from public.biletler b, unnest(v_liste) as p(plaka)
            where b.plaka = p.plaka or public.plaka_yakin(b.plaka, p.plaka)) then
  raise exception 'FAIL 75: fixture — ZZ75 plakalarından birine eşit ya da bir karakter yakın bilet var';
end if;
-- (i) son dört karakterle eşleşir: içeride aynı sonlu başka bilet olmamalı.
if exists (select 1 from public.biletler where durum = 'ACIK' and right(plaka, 4) = 'Q9T1') then
  raise exception 'FAIL 75: fixture — içeride sonu Q9T1 olan bilet var';
end if;

-- (a) İki saatlik park, kameranın çıkışı: olayın saatinde, 50 ₺, ödemesiz,
--     kaynak KAMERA, kapatan = açık kasa vardiyası; para hareket etmez.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ75KMR01', now() - interval '2 hours', v_tarife_yeni, 'ACIK')
returning id into v_bilet;
select count(*) into v_bigint from public.tahsilatlar;
v_ts := now() - interval '1 minute';
perform pg_temp.kamera();
select public.kamera_cikis_bildir('ZZ75KMR01', gen_random_uuid(), v_ts, null, null) into v_id;
perform pg_temp.logout();
if v_id is distinct from v_bilet then
  raise exception 'FAIL 75a: kameranın çıkışı bileti döndürmedi';
end if;
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'KAPALI' and cikis_at = v_ts
                  and cikis_bekliyor_at = v_ts and cikis_kaynak = 'KAMERA'
                  and cikis_by is null and ucret_kurus = 5000 and indirim_kurus = 0
                  and tahsil_kurus = 0 and odeme_yontemi is null
                  and kapatan_vardiya_id = v_vardiya) then
  raise exception 'FAIL 75a: kamera bileti olayın saatinde, doğru ücretle, ödemesiz, açık vardiyaya kapatmadı';
end if;
select count(*) into v_bigint2 from public.tahsilatlar;
if v_bigint2 <> v_bigint then
  raise exception 'FAIL 75a: kameranın kapatması tahsilat yazdı';
end if;
if not exists (select 1 from public.audit_log
                where action = 'bilet_kamera_kapatti' and row_id = v_bilet) then
  raise exception 'FAIL 75a: kameranın kapatması denetime yazılmadı';
end if;

-- (b) Borç var: Personel de Yönetici de "Ödeme bekliyor" bildirimi alır.
if not exists (select 1 from public.notifications
                where tur::text = 'ODEME_BEKLIYOR' and profile_id = u_personel
                  and link = '/gise/bilet/' || v_bilet)
   or not exists (select 1 from public.notifications
                   where tur::text = 'ODEME_BEKLIYOR' and profile_id = u_yonetici
                     and link = '/gise/bilet/' || v_bilet) then
  raise exception 'FAIL 75b: ödeme bekliyor bildirimi Personel''e ve Yönetici''ye gitmedi';
end if;
select count(*) into v_n from public.notifications
 where tur::text = 'ODEME_BEKLIYOR' and link = '/gise/bilet/' || v_bilet;

-- (c) Aynı çıkışın tekrarı (tek kapıdan, yeni kimlikle): yok sayılır — ikinci
--     kapanış, ikinci bildirim, yeni bilet yok.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ75KMR01', gen_random_uuid(), v_ts) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY'
   or (select count(*) from public.biletler where plaka = 'ZZ75KMR01') <> 1
   or (select count(*) from public.notifications
        where tur::text = 'ODEME_BEKLIYOR' and link = '/gise/bilet/' || v_bilet) <> v_n
   or (select cikis_at from public.biletler where id = v_bilet) is distinct from v_ts then
  raise exception 'FAIL 75c: aynı çıkışın tekrarı yok sayılmadı (%)', v_json;
end if;
-- İki şeritli CIKIS kapısından aynı çıkış yeniden (cevap kayboldu ve köprü
-- tekrar gönderdi, ya da aynı aracın ikinci karesi): bilet zaten kameranın
-- kapattığı — "açık bilet yok" kaydı da ikinci bildirim de yazılmaz.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_cikis_bildir('ZZ75KMR01', v_islem, v_ts + interval '30 seconds', null, null)
  into v_id;
perform pg_temp.logout();
if v_id is distinct from v_bilet
   or exists (select 1 from public.istisnalar where islem_id = v_islem)
   or (select count(*) from public.notifications
        where tur::text = 'ODEME_BEKLIYOR' and link = '/gise/bilet/' || v_bilet) <> v_n
   or (select cikis_at from public.biletler where id = v_bilet) is distinct from v_ts then
  raise exception 'FAIL 75c: iki şeritli kapıdan tekrar gelen çıkış kayıt ya da bildirim yazdı';
end if;

-- (d) O vardiyadaki Personel "Ödeme topla": tahsilat ONAY BEKLER, Yönetici
--     onaylar. Para kasaya, toplandığı vardiyaya yazılır.
perform pg_temp.login(u_personel);
select public.bilet_tahsil(v_bilet, 'NAKIT') into v_ucret;
perform pg_temp.logout();
select id into v_id2 from public.tahsilatlar
 where bilet_id = v_bilet and iptal_of is null and tutar_kurus = 5000
   and yontem = 'NAKIT' and vardiya_id = v_vardiya and durum::text = 'BEKLIYOR';
if v_ucret <> 5000 or v_id2 is null
   or not exists (select 1 from public.biletler
                   where id = v_bilet and tahsil_kurus = 5000 and odeme_yontemi = 'NAKIT') then
  raise exception 'FAIL 75d: Personel kameranın kapattığı borcu toplayamadı ya da tahsilat onay beklemiyor';
end if;
perform pg_temp.login(u_yonetici);
perform public.tahsilat_onayla(array[v_id2]);
perform pg_temp.logout();
if (select durum::text from public.tahsilatlar where id = v_id2) <> 'ONAYLANDI' then
  raise exception 'FAIL 75d: Yönetici toplanan ödemeyi onaylayamadı';
end if;

-- (e) Parası alınmış bilet geri açılamaz ("Araç çıkmadı" para yokken).
perform pg_temp.login(u_personel);
begin
  perform public.bilet_kamera_geri_ac(v_bilet);
  raise exception 'FAIL 75e: parası alınmış bilet geri açıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%ödemesi alınmış%' then
    raise exception 'FAIL 75e: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (f) "Araç çıkmadı": o vardiyadaki Personel, kameranın kapattığı parasız
--     bileti geri açar — bilet içeride, çıkış izleri temiz; iz ve Yönetici
--     bildirimi kalır; para hareket etmez.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ75KMR02', now() - interval '1 hour', v_tarife_yeni, 'ACIK')
returning id into v_bilet2;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR02', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
select count(*) into v_bigint from public.tahsilatlar;
perform pg_temp.login(u_personel);
select public.bilet_kamera_geri_ac(v_bilet2) into v_bool;
perform pg_temp.logout();
if v_bool is distinct from true
   or not exists (select 1 from public.biletler
                   where id = v_bilet2 and durum = 'ACIK' and cikis_at is null
                     and cikis_by is null and cikis_kaynak is null
                     and kapatan_vardiya_id is null and cikis_foto is null
                     and cikis_bekliyor_at is null and ucret_kurus = 0
                     and tahsil_kurus = 0 and odeme_yontemi is null) then
  raise exception 'FAIL 75f: kameranın kapattığı bilet temiz biçimde geri açılmadı';
end if;
if (select count(*) from public.tahsilatlar) <> v_bigint then
  raise exception 'FAIL 75f: geri açma tahsilat yazdı';
end if;
if not exists (select 1 from public.audit_log
                where action = 'bilet_kamera_geri_acildi' and row_id = v_bilet2
                  and actor = u_personel)
   or not exists (select 1 from public.notifications
                   where tur::text = 'KAMERA_GERI_ACILDI' and profile_id = u_yonetici
                     and link = '/gise/bilet/' || v_bilet2) then
  raise exception 'FAIL 75f: geri açma denetime ya da Yönetici bildirimine yazılmadı';
end if;
-- Açık bilet yeniden geri açılamaz.
perform pg_temp.login(u_personel);
begin
  perform public.bilet_kamera_geri_ac(v_bilet2);
  raise exception 'FAIL 75f: açık bilet "geri açıldı"';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%kameranın kapattığı%' then
    raise exception 'FAIL 75f: beklenmeyen hata (açık): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
-- Araç hâlâ kameranın önünde: hemen sonraki görülme bileti yeniden
-- KAPATMAZ — yalnızca damga ve Yönetici uyarısı, kararı insan verir.
select count(*) into v_n from public.notifications
 where tur::text = 'KAMERA_HAREKET' and profile_id = u_yonetici
   and link = '/gise/bilet/' || v_bilet2;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR02', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet2 and durum = 'ACIK' and cikis_bekliyor_at = now())
   or (select count(*) from public.notifications
        where tur::text = 'KAMERA_HAREKET' and profile_id = u_yonetici
          and link = '/gise/bilet/' || v_bilet2) <> v_n + 1 then
  raise exception 'FAIL 75f: geri açılan bilet hemen yeniden kapandı ya da Yönetici uyarılmadı';
end if;
-- Çıkış süresinden (tek_kapi_cikis_yoksay_dk) eski bir geri açma artık engel
-- değil: kamera yine kapatır. (Denetim satırının saati yalnızca bu geri
-- alınan testte geriye çekilir.)
update public.audit_log
   set created_at = now() - make_interval(mins => 1 + coalesce(
         (select o.tek_kapi_cikis_yoksay_dk from public.otopark_ayarlari o where o.id = 1), 5))
 where action = 'bilet_kamera_geri_acildi' and row_id = v_bilet2;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR02', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet2 and durum = 'KAPALI' and cikis_kaynak = 'KAMERA') then
  raise exception 'FAIL 75f: çıkış süresi geçince kamera geri açılan bileti kapatmadı';
end if;

-- (g) Elle (MOBIL) ödemesiz kapatılan bilet kameranın değildir: geri açılmaz.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ75MOB03', now() - interval '1 hour', v_tarife_yeni, 'ACIK')
returning id into v_id;
perform pg_temp.login(u_personel);
perform * from public.bilet_kapat(v_id, null, null, null, null, 'MOBIL', false);
begin
  perform public.bilet_kamera_geri_ac(v_id);
  raise exception 'FAIL 75g: elle kapatılan bilet kamera yoluyla geri açıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%kameranın kapattığı%' then
    raise exception 'FAIL 75g: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (h) Kamera yanlış kapattı, araç sonra yeniden görülüp YENİ bilet açıldı:
--     geri açma, içeride aynı plakalı bilet varken reddedilir (önce o iptal).
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ75KMR04', now() - interval '1 hour', v_tarife_yeni, 'ACIK')
returning id into v_id;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR04', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ75KMR04', now(), v_tarife_yeni, 'ACIK');
perform pg_temp.login(u_yonetici);
begin
  perform public.bilet_kamera_geri_ac(v_id);
  raise exception 'FAIL 75h: içeride aynı plakalı bilet varken geri açıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%önce onu iptal%' then
    raise exception 'FAIL 75h: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
-- Park yeri: boş kaldıysa geri açılan bilet yerini korur; yanlış kapanıştan
-- sonra yere başka araç girdiyse geri açma yine çalışır, bilet yersiz açılır
-- (yer yeni araçta kalır — tekil "açık bilet başına yer" indeksi).
insert into public.park_yerleri (kod, tip, rezerve) values ('ZZ75-R', 'NORMAL', false)
returning id into v_yer;
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum, park_yeri_id)
values (gen_random_uuid(), 'ZZ75KMR13', now() - interval '1 hour', v_tarife_yeni, 'ACIK', v_yer)
returning id into v_id;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR13', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
perform pg_temp.login(u_personel);
perform public.bilet_kamera_geri_ac(v_id);
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_id and durum = 'ACIK' and park_yeri_id = v_yer) then
  raise exception 'FAIL 75h: boş kalan park yeri geri açmada korunmadı';
end if;
insert into public.park_yerleri (kod, tip, rezerve) values ('ZZ75-P', 'NORMAL', false)
returning id into v_yer;
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum, park_yeri_id)
values (gen_random_uuid(), 'ZZ75KMR11', now() - interval '1 hour', v_tarife_yeni, 'ACIK', v_yer)
returning id into v_id;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR11', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum, park_yeri_id)
values (gen_random_uuid(), 'ZZ75KMR12', now(), v_tarife_yeni, 'ACIK', v_yer)
returning id into v_id2;
perform pg_temp.login(u_personel);
begin
  select public.bilet_kamera_geri_ac(v_id) into v_bool;
exception when others then
  raise exception 'FAIL 75h: yeri dolmuş bilet geri açılamadı: %', sqlerrm;
end;
perform pg_temp.logout();
if v_bool is distinct from true
   or not exists (select 1 from public.biletler
                   where id = v_id and durum = 'ACIK' and park_yeri_id is null)
   or not exists (select 1 from public.biletler
                   where id = v_id2 and durum = 'ACIK' and park_yeri_id = v_yer) then
  raise exception 'FAIL 75h: yeri dolmuş bilet yanlış geri açıldı (yer yeni araçta kalmalı)';
end if;

-- (i) Benzer plaka (son dört karakter) kapatmaz: insana gider, bilet açık
--     kalır, damgalanmaz (eskiden "kapıda" yapardı; artık kapatacaktı).
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ75Q9T1', now() - interval '1 hour', v_tarife_yeni, 'ACIK')
returning id into v_id;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_cikis_bildir('YY99Q9T1', v_islem, now(), null, null) into v_id2;
perform pg_temp.logout();
if v_id2 is not null
   or not exists (select 1 from public.biletler
                   where id = v_id and durum = 'ACIK' and cikis_bekliyor_at is null)
   or not exists (select 1 from public.istisnalar
                   where islem_id = v_islem and tur::text = 'COKLU_ESLESME' and yon = 'CIKIS'
                     and aday_bilet_ids = array[v_id]) then
  raise exception 'FAIL 75i: benzer plakalı çıkış bileti kapattı ya da insana gitmedi';
end if;

-- (j) Kapatılamayan çıkış (kullanılan puan ücretten fazla; olay girişten
--     önce): bilet AÇIK kalır, damgalanır, Yönetici uyarılır — tahmin yok.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum, indirim_kurus)
values (gen_random_uuid(), 'ZZ75KMR05', now() - interval '1 hour', v_tarife_yeni, 'ACIK', 9000)
returning id into v_id;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR05', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_id and durum = 'ACIK' and cikis_bekliyor_at = now())
   or not exists (select 1 from public.notifications
                   where tur::text = 'KAMERA_HAREKET' and profile_id = u_yonetici
                     and link = '/gise/bilet/' || v_id) then
  raise exception 'FAIL 75j: puanı ücretten fazla bilet kapandı ya da Yönetici uyarılmadı';
end if;
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ75KMR06', now(), v_tarife_yeni, 'ACIK')
returning id into v_id;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR06', gen_random_uuid(), now() - interval '5 minutes',
                                   null, null);
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_id and durum = 'ACIK'
                  and cikis_bekliyor_at = now() - interval '5 minutes') then
  raise exception 'FAIL 75j: girişten önceki çıkış olayı bileti kapattı';
end if;

-- (k) Ücretsiz süre (5 dakika): kapanır, borç yok — kimseye bildirim yok.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ75KMR07', now() - interval '5 minutes', v_tarife_yeni, 'ACIK')
returning id into v_id;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR07', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_id and durum = 'KAPALI' and ucret_kurus = 0 and tahsil_kurus = 0)
   or exists (select 1 from public.notifications
               where tur::text = 'ODEME_BEKLIYOR' and link = '/gise/bilet/' || v_id) then
  raise exception 'FAIL 75k: ücretsiz çıkış kapanmadı ya da gereksiz bildirim yazdı';
end if;

-- (l) Kameranın kapattığı biletin çıkış fotoğrafı bağlanır (yalnızca bu
--     olayınki); başka kapanmış bilete fotoğraf yazmak hâlâ yasak.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ75KMR08', now() - interval '1 hour', v_tarife_yeni, 'ACIK')
returning id into v_id;
v_islem := gen_random_uuid();
v_txt2 := 'kamera/' || v_islem::text || '.jpg';
v_ts := now() - interval '20 seconds';
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR08', v_islem, v_ts, null, null);
select public.kamera_foto_bagla(v_islem, v_id, v_ts, v_txt2) into v_n;
select public.kamera_foto_bagla(v_islem, v_id, v_ts, v_txt2) into v_n2;
perform pg_temp.logout();
if v_n <> 1 or v_n2 <> 0
   or not exists (select 1 from public.biletler
                   where id = v_id and durum = 'KAPALI' and cikis_foto = v_txt2) then
  raise exception 'FAIL 75l: kameranın kapattığı biletin fotoğrafı bağlanmadı (% / %)', v_n, v_n2;
end if;
begin
  update public.biletler set cikis_foto = 'kamera/baska.jpg' where id = v_bilet;
  raise exception 'FAIL 75l: kapanmış bilete fotoğraf yazılabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Kapanmış bilet değiştirilemez%' then
    raise exception 'FAIL 75l: beklenmeyen hata: %', sqlerrm;
  end if;
end;

-- (m) Başka vardiyanın borcu: kasa vardiyası değişti — Personel ne toplar
--     ne geri açar (sahibin seçimi); Yönetici ikisini de yapabilir.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ75KMR09', now() - interval '1 hour', v_tarife_yeni, 'ACIK')
returning id into v_id;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR09', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE'
 where kapanis_at is null;
perform pg_temp.login(u_personel);
perform public.vardiya_ac(0);
begin
  perform public.bilet_tahsil(v_id, 'NAKIT');
  raise exception 'FAIL 75m: Personel başka vardiyanın kamera borcunu topladı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%yetkiniz yok%' then
    raise exception 'FAIL 75m: beklenmeyen hata (tahsil): %', sqlerrm;
  end if;
end;
begin
  perform public.bilet_kamera_geri_ac(v_id);
  raise exception 'FAIL 75m: Personel başka vardiyanın kamera biletini geri açtı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%yetkiniz yok%' then
    raise exception 'FAIL 75m: beklenmeyen hata (geri aç): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
perform pg_temp.login(u_yonetici);
select public.bilet_kamera_geri_ac(v_id) into v_bool;
perform pg_temp.logout();
if v_bool is distinct from true then
  raise exception 'FAIL 75m: Yönetici başka vardiyanın kamera biletini geri açamadı';
end if;

-- (n) Açık vardiya yokken: kapanır (vardiyasız), bildirim yalnızca
--     Yönetici'ye — Personel o bileti göremez, toplayamaz.
-- Yeni bilet: (m)'nin bileti az önce geri açıldı (yeniden kapanmaz, 75f).
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ75KMR10', now() - interval '1 hour', v_tarife_yeni, 'ACIK')
returning id into v_id;
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE'
 where kapanis_at is null;
select count(*) into v_n from public.notifications
 where tur::text = 'ODEME_BEKLIYOR' and profile_id = u_personel and link = '/gise/bilet/' || v_id;
select count(*) into v_n2 from public.notifications
 where tur::text = 'ODEME_BEKLIYOR' and profile_id = u_yonetici and link = '/gise/bilet/' || v_id;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ75KMR10', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_id and durum = 'KAPALI' and kapatan_vardiya_id is null)
   or (select count(*) from public.notifications
        where tur::text = 'ODEME_BEKLIYOR' and profile_id = u_yonetici
          and link = '/gise/bilet/' || v_id) <> v_n2 + 1
   or (select count(*) from public.notifications
        where tur::text = 'ODEME_BEKLIYOR' and profile_id = u_personel
          and link = '/gise/bilet/' || v_id) <> v_n then
  raise exception 'FAIL 75n: vardiyasız kapanış ya da bildirimi yanlış';
end if;

-- (o) Yetkiler: geri açma yalnızca giriş yapmış kullanıcıya (rolü gövde
--     denetler); kamera fonksiyonu yalnızca kameraya; bir insan kamera
--     fonksiyonunu çağıramaz (geçmiş saatle ucuz çıkış yazamasın).
v_txt := 'public.bilet_kamera_geri_ac(uuid)';
if not has_function_privilege('authenticated', v_txt, 'execute')
   or has_function_privilege('anon', v_txt, 'execute')
   or has_function_privilege('service_role', v_txt, 'execute') then
  raise exception 'FAIL 75o: bilet_kamera_geri_ac yetkileri yanlış';
end if;
v_txt := 'public.kamera_cikis_bildir(text, uuid, timestamptz, text, jsonb)';
if not has_function_privilege('service_role', v_txt, 'execute')
   or has_function_privilege('anon', v_txt, 'execute')
   or has_function_privilege('authenticated', v_txt, 'execute') then
  raise exception 'FAIL 75o: kamera_cikis_bildir yetkileri yanlış';
end if;
perform pg_temp.login(u_yonetici);
begin
  perform public.kamera_cikis_bildir('ZZ75KMR02', gen_random_uuid(), now() - interval '50 minutes',
                                     null, null);
  raise exception 'FAIL 75o: bir insan kamera çıkışı yazabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();
if exists (select 1 from pg_trigger where tgname = 'kamera_cikis_bildirim_tg'
                                       and tgrelid = 'public.biletler'::regclass) then
  raise exception 'FAIL 75o: eski çıkış bildirim tetiği duruyor — iki bildirim gider';
end if;

raise notice 'PASS 75: kamera bileti olayın saatinde ödemesiz kapatır, herkes bildirim alır, borç kendi vardiyasında toplanıp Onay''a düşer, "Araç çıkmadı" yalnızca kameranın parasız kapattığını geri açar, benzer plaka kapatmaz';

-- =====================================================================
-- 76  Tek kapı: köprünün yön ipucu yalnızca YANLIŞ TAHMİNİ durdurur (055, 056)
--     Köprü aracı izler ve gördüğü yönü gönderir (p_hareket: GIRDI, CIKTI,
--     ICERIDE). Sunucu ipucuyla ASLA tek başına bilet açmaz ya da kapatmaz;
--     yalnızca bilet durumunun tahmini ipucuyla çelişince insana bırakır:
--       · çıkan araç, açık bileti yok   → ACIK_BILET_YOK (hayalet giriş yok —
--         sahada 11.11 11:35 / 13:46);
--       · giren araç, eski açık bileti var → GIRISTE_ACIK_BILET (yanlış
--         kapatma yok);
--       · içeride gezen araç: bileti varsa hiçbir şey (asla kapatma), yoksa
--         ICERIDE_BILETSIZ — personel "Giriş aç"la açabilir.
--     İpucu yok ya da tanınmıyor → bugünkü karar (eski köprü, kuyruktaki eski
--     olay). now() bu transaction'da sabit; "eski bilet" PASS 58 gibi
--     created_at geri çekilerek kurulur.
-- =====================================================================
perform pg_temp.logout();

-- (a) Tek imza (ipucu sonda, varsayılanı boş), yalnızca webhook çağırır.
v_txt := 'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)';
if to_regprocedure(v_txt) is null then
  raise exception 'FAIL 76a: kamera_tek_kapi ipucu parametresiyle yok — 056 çalıştırılmadı';
end if;
if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'kamera_tek_kapi') <> 1 then
  raise exception 'FAIL 76a: kamera_tek_kapi birden çok imzayla tanımlı';
end if;
if not has_function_privilege('service_role', v_txt, 'execute')
   or has_function_privilege('anon', v_txt, 'execute')
   or has_function_privilege('authenticated', v_txt, 'execute') then
  raise exception 'FAIL 76a: kamera_tek_kapi yetkileri yanlış';
end if;
select tek_kapi_giris_yoksay_dk, tek_kapi_cikis_yoksay_dk
  into v_n, v_n2 from public.otopark_ayarlari where id = 1;
v_n := coalesce(v_n, 3);

-- (b) Tanınmayan ipucu yok sayılır: yeni araç bugünkü gibi GİRER. İpucusuz
--     çağrı PASS 58'de (dört/üç argüman) aynen geçer.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76AA101', gen_random_uuid(), now(), null, null, 'XYZ') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' then
  raise exception 'FAIL 76b: tanınmayan ipucu kararı değiştirdi (%)', v_json;
end if;
-- GIRDI + bileti yok: ipucu kararla aynı yönde — giriş açılır.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76BB202', gen_random_uuid(), now(), null, null, 'GIRDI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS'
   or not exists (select 1 from public.biletler where plaka = 'ZZ76BB202' and durum = 'ACIK') then
  raise exception 'FAIL 76b: giren ve bileti olmayan araç girmedi (%)', v_json;
end if;

-- (c) ÇIKAN araç, açık bileti yok: hayalet giriş AÇILMAZ, insana gider.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76CC303', v_islem, now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'ISTISNA' or v_json ->> 'sebep' is distinct from 'CIKIS_BILETSIZ' then
  raise exception 'FAIL 76c: çıkan ve bileti olmayan araç insana gitmedi (%)', v_json;
end if;
if exists (select 1 from public.biletler where plaka = 'ZZ76CC303') then
  raise exception 'FAIL 76c: çıkan araca hayalet giriş bileti açıldı';
end if;
if (select count(*) from public.istisnalar
     where islem_id = v_islem and tur::text = 'ACIK_BILET_YOK' and yon = 'ORTAK'
       and plaka = 'ZZ76CC303' and cozuldu_at is null) <> 1 then
  raise exception 'FAIL 76c: ACIK_BILET_YOK kaydı (tek kapı) yazılmadı';
end if;
select id into v_id2 from public.istisnalar where islem_id = v_islem;

-- (h) Aynı olay yeniden gelir (köprü cevabı göremedi): ikinci kayıt yok.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76CC303', v_islem, now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'ISTISNA' or v_json ->> 'sebep' is distinct from 'TEKRAR'
   or (select count(*) from public.istisnalar where plaka = 'ZZ76CC303') <> 1 then
  raise exception 'FAIL 76h: tekrar oynatılan olay ikinci kayıt üretti (%)', v_json;
end if;

-- (e) GİREN araç, bileti az önce açılmış: aynı ziyaret — bugünkü gibi yok say.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76DD404', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
v_bilet := (v_json ->> 'bilet_id')::uuid;
if v_json ->> 'karar' is distinct from 'GIRIS' or v_bilet is null then
  raise exception 'FAIL 76e: hazırlık bileti açılmadı (%)', v_json;
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76DD404', gen_random_uuid(), now(), null, null, 'GIRDI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'YENI_GIRIS' then
  raise exception 'FAIL 76e: az önce giren araç yok sayılmadı (%)', v_json;
end if;

-- (d) GİREN araç ama ESKİ açık bileti var.
--     090 (sahibin kararı 28.11; 26–28.11'de 9 kart, bu biletlerin çıkışı
--     10–60 saat sonra kapandı): eski bilet çıkışı görülmeden kapanır —
--     ödemesiz, son içeride görüldüğü anda (görülmediyse kendi giriş
--     saatinde), notu "çıkışı görülmedi". Bu olayla YENİ bilet açılır;
--     kart yok. Ayrıntılar PASS 136-137.
update public.biletler
   set created_at = now() - make_interval(mins => v_n + 1) where id = v_bilet;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76DD404', v_islem, now(), null, null, 'GIRDI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' or v_json ->> 'sebep' is distinct from 'ESKI_BILET_KAPANDI' then
  raise exception 'FAIL 76d: giren aracın eski bileti kapanıp yenisi açılmadı (%)', v_json;
end if;
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'KAPALI' and cikis_kaynak::text = 'KAMERA'
                  and tahsil_kurus = 0 and notlar like '%çıkışı görülmedi%') then
  raise exception 'FAIL 76d: giren aracın eski bileti "çıkışı görülmedi" diye kapanmadı';
end if;
if exists (select 1 from public.istisnalar where islem_id = v_islem) then
  raise exception 'FAIL 76d: eski bileti olan girişte kart açıldı';
end if;
-- 090: (f) artık YENİ bileti kapatır; giriş penceresi geri çekilerek geçer.
v_bilet := (v_json ->> 'bilet_id')::uuid;
update public.biletler
   set created_at = now() - make_interval(mins => v_n + 1) where id = v_bilet;

-- (f) ÇIKAN araç, eski açık bileti var: bugünkü gibi ÇIKIŞ (bilet kapanır).
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76DD404', gen_random_uuid(), now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'CIKIS' or (v_json ->> 'bilet_id')::uuid is distinct from v_bilet
   or not exists (select 1 from public.biletler where id = v_bilet and durum = 'KAPALI') then
  raise exception 'FAIL 76f: çıkan aracın bileti kapanmadı (%)', v_json;
end if;

-- (g) İÇERİDE gezen araç. Bileti varsa hiçbir şey olmaz — ESKİ bilet de
--     kapanmaz (bugün aynı olay çıkış sayılırdı).
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76EE505', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
v_bilet2 := (v_json ->> 'bilet_id')::uuid;
if v_json ->> 'karar' is distinct from 'GIRIS' or v_bilet2 is null then
  raise exception 'FAIL 76g: hazırlık bileti açılmadı (%)', v_json;
end if;
update public.biletler
   set created_at = now() - make_interval(mins => v_n + 1) where id = v_bilet2;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76EE505', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'ICERIDE_ACIK'
   or not exists (select 1 from public.biletler
                   where id = v_bilet2 and durum = 'ACIK' and cikis_bekliyor_at is null) then
  raise exception 'FAIL 76g: içerideki biletli araç için bir şey yapıldı (%)', v_json;
end if;
-- Bir karakter uzak okunmuş hâli: içerideki o araçtır — kayıt da bilet de yok.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76EE506', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'ICERIDE_BENZER'
   or exists (select 1 from public.biletler where plaka = 'ZZ76EE506')
   or exists (select 1 from public.istisnalar where plaka = 'ZZ76EE506') then
  raise exception 'FAIL 76g: benzer plakalı içerideki araç iz bıraktı (%)', v_json;
end if;
-- Bileti az önce kapanmış (f): ödeyip çıkıyor — yok say.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76DD404', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'YENI_CIKIS' then
  raise exception 'FAIL 76g: bileti az önce kapanan araç yok sayılmadı (%)', v_json;
end if;
-- Bileti yok. 090 (sahibin kararı 28.11): bilet bu görülmeden AÇILIR,
-- notu "girişi görülmedi" (PASS 143); kart yok. Bu adım "yakında giriş
-- kartı YOK" hâlidir: testin önceki adımlarının now() damgalı plakasız
-- kartları (60, 63, 65 …) ve canlı kartlar önce kapatılır (transaction
-- sonunda geri alınır) — yoksa bilet o kartın saatinden açılırdı (PASS 142).
-- 2026-11-26 sahada: bu satır yokken FAIL 76g, sebep ICERIDE_GIRIS_KARTI.
update public.istisnalar set cozuldu_at = now()
 where tur::text = 'OKUNAMADI' and yon = 'ORTAK' and cozuldu_at is null
   and kaynak_zaman > now() - interval '30 minutes';
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76FF606', v_islem, now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' or v_json ->> 'sebep' is distinct from 'ICERIDE_GORULDU'
   or not exists (select 1 from public.biletler
                   where id = (v_json ->> 'bilet_id')::uuid and plaka = 'ZZ76FF606'
                     and durum = 'ACIK' and islem_id = v_islem)
   or exists (select 1 from public.istisnalar where plaka = 'ZZ76FF606') then
  raise exception 'FAIL 76g: içeride bileti olmayan araca bilet açılmadı (%)', v_json;
end if;
-- Aynı araç yeniden görüldü (başka iz, yeni olay): artık biletli — hiçbir şey.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76FF606', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'ICERIDE_ACIK'
   or (select count(*) from public.biletler where plaka = 'ZZ76FF606') <> 1 then
  raise exception 'FAIL 76g: içeride yeniden görülen araç ikinci bilet ya da kart açtı (%)', v_json;
end if;
-- 090: (i) için 1.4.6'dan kalan bir ICERIDE_BILETSIZ kartı elle kurulur
-- (sahada açık kartlar 090'dan sonra da "Giriş aç"la açılabilmeli).
v_islem := gen_random_uuid();
v_id := public.istisna_yaz('ICERIDE_BILETSIZ', 'ORTAK', 'ZZ76GH707', 'KAMERA', v_islem,
                           null, null, now());
-- Bileti az önce kapanan araca (f) BİR KARAKTER uzak okuma: ödeyip çıkan
-- aracın yanlış okunması — kart yok (048'in 4. adımı gibi).
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ76DD405', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'YENI_CIKIS_BENZER'
   or exists (select 1 from public.istisnalar where plaka = 'ZZ76DD405')
   or exists (select 1 from public.biletler where plaka = 'ZZ76DD405') then
  raise exception 'FAIL 76g: az önce çıkanın benzeri içeride kart açtı (%)', v_json;
end if;

-- (i) "Giriş aç": ICERIDE_BILETSIZ kaydından açılır (044'ün bütün
--     korumalarıyla), ACIK_BILET_YOK kaydından açılmaz.
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac(v_id, 'ZZ76GH707') into v_json;
perform pg_temp.logout();
if (v_json ->> 'zaten_vardi')::boolean is distinct from false
   or not exists (select 1 from public.biletler
                   where id = (v_json ->> 'bilet_id')::uuid and plaka = 'ZZ76GH707'
                     and durum = 'ACIK' and islem_id = v_islem)
   or not exists (select 1 from public.istisnalar
                   where id = v_id and cozuldu_by = u_personel and cozuldu_at is not null) then
  raise exception 'FAIL 76i: içeride bileti olmayan araç için giriş açılmadı (%)', v_json;
end if;
perform pg_temp.login(u_personel);
begin
  perform public.istisna_bilet_ac(v_id2, 'ZZ76CC303');
  raise exception 'FAIL 76i: çıkışta bileti olmayan araç kaydından giriş açıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Bu kayıttan giriş açılamaz%' then
    raise exception 'FAIL 76i: yanlış ret sebebi: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

raise notice 'PASS 76: tek kapıda köprünün yön ipucu — çıkan biletsiz araca hayalet giriş yok; girenin eski bileti çıkışı görülmedi diye kapanır, yenisi açılır (090); içerideki biletli araç asla kapatılmaz, biletsizine bilet açılır (090); eski ICERIDE_BILETSIZ kartından "Giriş aç"';

-- =====================================================================
-- 77  Kameranın günlük özeti Yönetici'ye (057, 058)
--     Gece işi (00:05) bir önceki İstanbul gününü sayar: kameranın açtığı
--     ve kapattığı biletler, personele düşen çözülmemiş kayıtlar (ve kaçı
--     hâlâ açık). Kamera açıkken her gün TEK bildirim — hiç araç yoksa da
--     (o da bir alarm). Sayım otoparkın boş olduğunu varsaymaz: önce/sonra
--     farkı. now() bu transaction'da sabit.
-- =====================================================================
perform pg_temp.logout();

-- (a) İki yardımcı var ve hiçbir role açık değil (yalnızca gece işi çağırır);
--     yeni bildirim türü Yönetici'ye özel.
foreach v_txt in array array['public.kamera_gunluk_sayim(date)', 'public.kamera_gunluk_rapor(date)'] loop
  if to_regprocedure(v_txt) is null then
    raise exception 'FAIL 77a: % yok — 058 çalıştırılmadı', v_txt;
  end if;
  if has_function_privilege('public', v_txt, 'execute')
     or has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('authenticated', v_txt, 'execute')
     or has_function_privilege('service_role', v_txt, 'execute') then
    raise exception 'FAIL 77a: % bir role açık', v_txt;
  end if;
end loop;
if not public.bildirim_yonetici_turu('KAMERA_GUNLUK') then
  raise exception 'FAIL 77a: KAMERA_GUNLUK Yönetici''ye özel değil';
end if;

-- (b) Sayım: bugün kameranın bir girişi (iki araç), bir çıkışı ve personele
--     düşen bir kaydı eklenince sayılar tam o kadar artar.
v_gun := (now() at time zone 'Europe/Istanbul')::date;
v_json := public.kamera_gunluk_sayim(v_gun);
perform pg_temp.kamera();
perform public.kamera_tek_kapi('ZZ77KG001', gen_random_uuid(), now());
perform pg_temp.logout();
perform pg_temp.kamera();
perform public.kamera_tek_kapi('ZZ77KG202', gen_random_uuid(), now());
perform pg_temp.logout();
select id into v_bilet from public.biletler where plaka = 'ZZ77KG202' and durum = 'ACIK';
update public.biletler set created_at = now() - interval '30 minutes' where id = v_bilet;
perform pg_temp.kamera();
perform public.kamera_tek_kapi('ZZ77KG202', gen_random_uuid(), now());
perform pg_temp.logout();
if not exists (select 1 from public.biletler where id = v_bilet and durum = 'KAPALI'
                                              and cikis_kaynak::text = 'KAMERA') then
  raise exception 'FAIL 77b: hazırlık — kamera çıkışı kapatmadı';
end if;
perform pg_temp.kamera();
perform public.kamera_okunamadi('ORTAK', gen_random_uuid(), now(), null, null, null);
perform pg_temp.logout();
v_json2 := public.kamera_gunluk_sayim(v_gun);
if (v_json2 ->> 'giris')::int - (v_json ->> 'giris')::int is distinct from 2
   or (v_json2 ->> 'cikis')::int - (v_json ->> 'cikis')::int is distinct from 1
   or (v_json2 ->> 'personele')::int - (v_json ->> 'personele')::int is distinct from 1
   or (v_json2 ->> 'acik')::int - (v_json ->> 'acik')::int is distinct from 1 then
  raise exception 'FAIL 77b: sayım farkı yanlış (önce %, sonra %)', v_json, v_json2;
end if;

-- (c) Kamera açıkken o gün için TEK bildirim, sayılarla; ikinci çağrı yazmaz.
select kamera_aktif into v_bool from public.otopark_ayarlari where id = 1;
update public.otopark_ayarlari set kamera_aktif = true where id = 1;
if public.kamera_gunluk_rapor(v_gun) is distinct from true then
  raise exception 'FAIL 77c: kamera açıkken günlük özet yazılmadı';
end if;
select count(*) into v_n from public.notifications
 where tur::text = 'KAMERA_GUNLUK' and profile_id = u_yonetici
   and link = '/yonetim/kameralar?gun=' || v_gun::text
   and govde like '%' || (v_json2 ->> 'giris') || ' giriş%'
   and govde like '%' || (v_json2 ->> 'cikis') || ' çıkış%'
   and govde like '%' || (v_json2 ->> 'personele') || ' personele%';
if v_n <> 1 then
  raise exception 'FAIL 77c: Yönetici''ye % özet (1 beklenirdi, sayılarla)', v_n;
end if;
if public.kamera_gunluk_rapor(v_gun) is distinct from false
   or (select count(*) from public.notifications
        where tur::text = 'KAMERA_GUNLUK' and profile_id = u_yonetici
          and link = '/yonetim/kameralar?gun=' || v_gun::text) <> 1 then
  raise exception 'FAIL 77c: aynı gün için ikinci özet yazıldı';
end if;

-- (d) Kamera kapalıyken özet yok (dedupe saklamasın diye başka bir gün).
--     Yalnızca BU testin Yönetici'si: canlı veritabanında gerçek gece işi o
--     gün için gerçek Yönetici'lere zaten yazmış olabilir (bağımsız inceleme).
update public.otopark_ayarlari set kamera_aktif = false where id = 1;
if public.kamera_gunluk_rapor(v_gun - 3) is distinct from false
   or exists (select 1 from public.notifications
               where tur::text = 'KAMERA_GUNLUK' and profile_id = u_yonetici
                 and link = '/yonetim/kameralar?gun=' || (v_gun - 3)::text) then
  raise exception 'FAIL 77d: kamera kapalıyken günlük özet yazıldı';
end if;
update public.otopark_ayarlari set kamera_aktif = v_bool where id = 1;

-- (e) Gece işi özeti çağırıyor (kendi alt bloğunda — sorun 1-8'i geri almaz).
v_txt := pg_get_functiondef('public.run_gunluk_bakim()'::regprocedure);
if position('kamera_gunluk_rapor(' in v_txt) = 0 then
  raise exception 'FAIL 77e: run_gunluk_bakim kameranın günlük özetini çağırmıyor';
end if;

raise notice 'PASS 77: kameranın günlük özeti — gece işi bir önceki günü sayar, kamera açıkken Yönetici''ye günde tek bildirim';

-- =====================================================================
-- 78  Araç Girişi'nde giriş saati (059)
--     Elle girişte tarih ve saat seçilebilir (sahip, 2026-11-15) — bilet
--     ekranındaki "Değiştir" ile AYNI kurallar, çünkü bu da para:
--       · bilet_ac_saatli = bilet_ac + bilet_giris_duzelt, TEK çağrıda;
--         biri reddederse hiçbir şey yazılmaz (bilet "şimdi"de açık kalmaz);
--       · ileri saat, bir yıldan eski saat, boş sebep reddedilir;
--       · iz ve Yönetici bildirimi bilet_giris_duzelt'ten gelir;
--       · aynı islem_id ikinci kez: aynı bilet, ikinci iz yok;
--       · rolü olmayan kullanıcı açamaz; anon ve service_role çağıramaz.
-- =====================================================================
perform pg_temp.logout();
if to_regprocedure('public.bilet_ac_saatli(text, uuid, text, uuid, text, text, text, text, timestamptz, text)') is null then
  raise exception 'FAIL 78: bilet_ac_saatli yok — 059 çalıştırılmadı';
end if;
if not exists (select 1 from public.profiles
                where id = u_personel and rol = 'PERSONEL' and durum = 'ACTIVE') then
  raise exception 'FAIL 78: fixture — u_personel aktif bir Personel değil';
end if;

-- (a) Yetki: yalnızca authenticated çağırabilir.
if has_function_privilege('anon',
     'public.bilet_ac_saatli(text, uuid, text, uuid, text, text, text, text, timestamptz, text)', 'execute')
   or has_function_privilege('service_role',
     'public.bilet_ac_saatli(text, uuid, text, uuid, text, text, text, text, timestamptz, text)', 'execute')
   or not has_function_privilege('authenticated',
     'public.bilet_ac_saatli(text, uuid, text, uuid, text, text, text, text, timestamptz, text)', 'execute') then
  raise exception 'FAIL 78a: bilet_ac_saatli yetkileri yanlış';
end if;

-- (b) Rolü olmayan kullanıcı açamaz, bilet de kalmaz.
perform pg_temp.login(u_pending);
begin
  perform public.bilet_ac_saatli('ZZ78SAAT1', gen_random_uuid(), null, null, null, null, null, null,
                                 now() - interval '3 hours', 'Test 78b');
  raise exception 'FAIL 78b: rolsüz kullanıcı saatli giriş açtı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yetkiniz yok%' then
    raise exception 'FAIL 78b: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (c) Geçersiz saat/sebep: her biri kendi sebebiyle reddedilir ve bilet
--     AÇILMAZ — bilet_ac'ın açtığı bilet de geri alınır (tek çağrı).
perform pg_temp.login(u_personel);
foreach v_txt in array array['ileri', 'eski', 'sebep_bos', 'saat_null'] loop
  begin
    case v_txt
      when 'ileri' then
        perform public.bilet_ac_saatli('ZZ78SAAT1', gen_random_uuid(), null, null, null, null, null, null,
                                       now() + interval '5 minutes', 'Test 78c');
      when 'eski' then
        perform public.bilet_ac_saatli('ZZ78SAAT1', gen_random_uuid(), null, null, null, null, null, null,
                                       now() - interval '1 year 1 day', 'Test 78c');
      when 'sebep_bos' then
        perform public.bilet_ac_saatli('ZZ78SAAT1', gen_random_uuid(), null, null, null, null, null, null,
                                       now() - interval '3 hours', '   ');
      else
        perform public.bilet_ac_saatli('ZZ78SAAT1', gen_random_uuid(), null, null, null, null, null, null,
                                       null, 'Test 78c');
    end case;
    raise exception 'FAIL 78c: % girdisi kabul edildi', v_txt;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    v_txt2 := case v_txt
                when 'ileri'     then '%ileri bir zaman%'
                when 'eski'      then '%bir yıldan eski%'
                when 'saat_null' then '%Giriş saati boş%'
                else '%Sebep zorunlu%' end;
    if sqlerrm not like v_txt2 then
      raise exception 'FAIL 78c: % için beklenmeyen hata: %', v_txt, sqlerrm;
    end if;
  end;
end loop;
perform pg_temp.logout();
if exists (select 1 from public.biletler where plaka = 'ZZ78SAAT1') then
  raise exception 'FAIL 78b-c: reddedilen saatli giriş bilet bıraktı';
end if;

-- (d) Personel 3 saat önceyle açar: bilet o saatte açık, bir iz, Yöneticiye
--     bir bildirim.
v_islem := gen_random_uuid();
v_ts2 := date_trunc('minute', now()) - interval '3 hours';
perform pg_temp.login(u_personel);
v_bilet := public.bilet_ac_saatli('ZZ78SAAT1', v_islem, null, null, null, null, null, null,
                                  v_ts2, '  Araç önceden girmiş  ');
perform pg_temp.logout();
if v_bilet is null
   or not exists (select 1 from public.biletler
                   where id = v_bilet and plaka = 'ZZ78SAAT1' and durum = 'ACIK'
                     and giris_at = v_ts2 and giris_by = u_personel) then
  raise exception 'FAIL 78d: bilet seçilen saatte açılmadı';
end if;
if (select count(*) from public.audit_log
     where action = 'bilet_giris_duzeltildi' and row_id = v_bilet and actor = u_personel
       and (detay ->> 'yeni')::timestamptz = v_ts2
       and detay ->> 'sebep' = 'Araç önceden girmiş') <> 1 then
  raise exception 'FAIL 78d: saatli giriş audit_log''a yazılmadı';
end if;
if (select count(*) from public.notifications
     where profile_id = u_yonetici and tur = 'UCRET_DEGISIKLIGI'
       and link = '/gise/bilet/' || v_bilet) <> 1 then
  raise exception 'FAIL 78d: Yöneticiye tek bir giriş saati bildirimi gitmedi';
end if;

-- (e) Aynı islem_id yeniden (bağlantı kopup yeniden denendi): aynı bilet,
--     ikinci iz ve bildirim yok.
perform pg_temp.login(u_personel);
v_bilet2 := public.bilet_ac_saatli('ZZ78SAAT1', v_islem, null, null, null, null, null, null,
                                   v_ts2, 'Araç önceden girmiş');
perform pg_temp.logout();
if v_bilet2 is distinct from v_bilet
   or (select count(*) from public.biletler where plaka = 'ZZ78SAAT1') <> 1
   or (select count(*) from public.audit_log
        where action = 'bilet_giris_duzeltildi' and row_id = v_bilet) <> 1
   or (select count(*) from public.notifications
        where profile_id = u_yonetici and link = '/gise/bilet/' || v_bilet) <> 1 then
  raise exception 'FAIL 78e: yeniden deneme ikinci bilet, iz ya da bildirim yazdı';
end if;

raise notice 'PASS 78: Araç Girişi''nde seçilen saat — tek çağrıda açılır ve düzeltilir, reddedilen hiçbir şey bırakmaz, iz ve Yönetici bildirimi yazılır, yeniden deneme aynı bileti döner';

-- =====================================================================
-- 79  Yanlışlıkla çıkış verilen araç geri içeri (060)
--     Sahip (2026-11-15): bir insanın yanlış araca verdiği çıkış geri
--     alınabilsin — parası alınmış olsa da. 054'ün "Araç çıkmadı"sı
--     (kamera, parasız, sebepsiz) AYNEN kalır; bu, onun sebepli kardeşi:
--       · Personel yalnızca kendi açık vardiyasında kapanan bileti,
--         Yönetici her bileti; sebep zorunlu; iz + Yönetici bildirimi;
--       · para DÜZENLENMEZ, karşı kayıtla geri alınır (bilet_iptal gibi):
--         onay bekleyen ödeme Onay'dan düşer, onaylanmış olana ters kayıt;
--       · bilet ilk giriş saatiyle yeniden ACIK, çıkış izleri temiz;
--       · içeride aynı plakalı başka bilet varken reddedilir;
--       · kameranın kapattığı bilet de (ödenmiş olsa da) açılır ve izi
--         054'ün adıyla yazılır — kamera aynı aracı hemen yeniden kapatmaz.
-- =====================================================================
perform pg_temp.logout();
if to_regprocedure('public.bilet_cikis_geri_al(uuid, text)') is null then
  raise exception 'FAIL 79: bilet_cikis_geri_al yok — 060 çalıştırılmadı';
end if;
if not exists (select 1 from public.profiles
                where id = u_personel and rol = 'PERSONEL' and durum = 'ACTIVE')
   or not exists (select 1 from public.profiles
                   where id = u_yonetici and rol = 'YONETICI' and durum = 'ACTIVE') then
  raise exception 'FAIL 79: fixture — u_personel / u_yonetici rolü beklenen gibi değil';
end if;

-- (a) Yetki: yalnızca authenticated çağırabilir; rolsüz kullanıcı reddedilir.
if has_function_privilege('anon', 'public.bilet_cikis_geri_al(uuid, text)', 'execute')
   or has_function_privilege('service_role', 'public.bilet_cikis_geri_al(uuid, text)', 'execute')
   or not has_function_privilege('authenticated', 'public.bilet_cikis_geri_al(uuid, text)', 'execute') then
  raise exception 'FAIL 79a: bilet_cikis_geri_al yetkileri yanlış';
end if;

-- Personel'in kendi açık kasa vardiyası (kasa başına tek: önce hepsi kapanır).
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE'
 where kapanis_at is null;
perform pg_temp.login(u_personel);
perform public.vardiya_ac(0);
perform pg_temp.logout();
select v.id into v_vardiya from public.vardiyalar v where v.kapanis_at is null;

-- (b) Elle, ödemesiz, ücreti değiştirilmiş çıkış → geri alınır: bilet ilk
--     giriş saatiyle açık, çıkış izleri ve ücret değişikliği temiz, para
--     satırı yok, bir iz (sebepli) ve Yönetici bildirimi.
v_ts2 := now() - interval '2 hours';
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ79GERI1', v_ts2, v_tarife_yeni, 'ACIK')
returning id into v_bilet;
perform pg_temp.login(u_personel);
perform * from public.bilet_kapat(v_bilet, null, 1234, 'Test 79b ücret', null, 'MOBIL', false);
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'KAPALI' and ucret_degistirildi
                  and kapatan_vardiya_id = v_vardiya) then
  raise exception 'FAIL 79b: fixture — bilet elle, ücreti değişmiş, vardiyada kapanmadı';
end if;
select count(*) into v_bigint from public.tahsilatlar;
perform pg_temp.login(u_pending);
begin
  perform public.bilet_cikis_geri_al(v_bilet, 'Test 79a');
  raise exception 'FAIL 79a: rolsüz kullanıcı çıkışı geri aldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yetkiniz yok%' then
    raise exception 'FAIL 79a: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
begin
  perform public.bilet_cikis_geri_al(v_bilet, '   ');
  raise exception 'FAIL 79b: boş sebeple geri alındı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Sebep zorunlu%' then
    raise exception 'FAIL 79b: beklenmeyen hata (sebep): %', sqlerrm;
  end if;
end;
if not exists (select 1 from public.biletler where id = v_bilet and durum = 'KAPALI') then
  raise exception 'FAIL 79b: reddedilen geri alma bileti açtı';
end if;
select public.bilet_cikis_geri_al(v_bilet, '  Yanlış araca çıkış verildi  ') into v_bool;
perform pg_temp.logout();
if v_bool is distinct from true
   or not exists (select 1 from public.biletler
                   where id = v_bilet and durum = 'ACIK' and giris_at = v_ts2
                     and cikis_at is null and cikis_by is null and cikis_kaynak is null
                     and kapatan_vardiya_id is null and cikis_foto is null
                     and cikis_bekliyor_at is null and ucret_kurus = 0
                     and tahsil_kurus = 0 and odeme_yontemi is null
                     and not ucret_degistirildi and ucret_sebep is null) then
  raise exception 'FAIL 79b: elle kapatılan bilet temiz biçimde geri açılmadı';
end if;
if (select count(*) from public.tahsilatlar) <> v_bigint then
  raise exception 'FAIL 79b: parasız geri alma tahsilat yazdı';
end if;
if (select count(*) from public.audit_log
     where action = 'bilet_cikis_geri_alindi' and row_id = v_bilet and actor = u_personel
       and detay ->> 'sebep' = 'Yanlış araca çıkış verildi') <> 1
   or (select count(*) from public.notifications
        where tur::text = 'KAMERA_GERI_ACILDI' and profile_id = u_yonetici
          and link = '/gise/bilet/' || v_bilet) <> 1 then
  raise exception 'FAIL 79b: geri alma denetime ya da Yönetici bildirimine yazılmadı';
end if;

-- (e) Açık bilet "geri alınamaz".
perform pg_temp.login(u_personel);
begin
  perform public.bilet_cikis_geri_al(v_bilet, 'Test 79e');
  raise exception 'FAIL 79e: açık bilet geri alındı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%çıkışı yapılmış%' then
    raise exception 'FAIL 79e: beklenmeyen hata (açık): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (c) Ödenmiş, ödeme ONAY BEKLİYOR: asıl ve ters kayıt ikisi de Onay'dan
--     düşer (REDDEDILDI, 017); ters kayıt geri alanın vardiyasında; bilet
--     borçsuz açık.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ79GERI2', now() - interval '2 hours', v_tarife_yeni, 'ACIK')
returning id into v_bilet2;
perform pg_temp.login(u_personel);
perform * from public.bilet_kapat(v_bilet2, 'NAKIT', null, null, null, 'MOBIL', true);
perform pg_temp.logout();
select id, tutar_kurus into v_id2, v_ucret from public.tahsilatlar
 where bilet_id = v_bilet2 and iptal_of is null and durum::text = 'BEKLIYOR';
if v_id2 is null or v_ucret <= 0 then
  raise exception 'FAIL 79c: fixture — ödenmiş çıkış onay bekleyen bir tahsilat yazmadı';
end if;
perform pg_temp.login(u_personel);
perform public.bilet_cikis_geri_al(v_bilet2, 'Yanlış araç seçildi');
perform pg_temp.logout();
if (select durum::text from public.tahsilatlar where id = v_id2) <> 'REDDEDILDI'
   or not exists (select 1 from public.tahsilatlar
                   where iptal_of = v_id2 and tutar_kurus = -v_ucret and yontem = 'NAKIT'
                     and vardiya_id = v_vardiya and durum::text = 'REDDEDILDI')
   or (select count(*) from public.tahsilatlar where iptal_of = v_id2) <> 1 then
  raise exception 'FAIL 79c: bekleyen ödeme karşı kayıtla Onay''dan düşmedi';
end if;
if not exists (select 1 from public.biletler
                where id = v_bilet2 and durum = 'ACIK' and tahsil_kurus = 0
                  and odeme_yontemi is null and ucret_kurus = 0) then
  raise exception 'FAIL 79c: ödenmiş bilet borçsuz açık hâle gelmedi';
end if;
if (select (detay ->> 'iade')::integer from public.audit_log
     where action = 'bilet_cikis_geri_alindi' and row_id = v_bilet2) is distinct from v_ucret then
  raise exception 'FAIL 79c: geri alınan tutar denetime yazılmadı';
end if;

-- (d) Ödenmiş ve ONAYLANMIŞ: ters kayıt defterde (ONAYLANDI), asıl yerinde;
--     ikinci kez kapatılıp geri alınınca eski ters kayıt tekrarlanmaz.
perform pg_temp.login(u_personel);
perform * from public.bilet_kapat(v_bilet2, 'KREDI_KARTI', null, null, null, 'MOBIL', true);
perform pg_temp.logout();
select id, tutar_kurus into v_id, v_ucret from public.tahsilatlar
 where bilet_id = v_bilet2 and iptal_of is null and durum::text = 'BEKLIYOR';
perform pg_temp.login(u_yonetici);
perform public.tahsilat_onayla(array[v_id]);
perform pg_temp.logout();
if v_id is null or (select durum::text from public.tahsilatlar where id = v_id) <> 'ONAYLANDI' then
  raise exception 'FAIL 79d: fixture — ödeme onaylanmadı';
end if;
perform pg_temp.login(u_personel);
perform public.bilet_cikis_geri_al(v_bilet2, 'Yine yanlış araç');
perform pg_temp.logout();
if (select durum::text from public.tahsilatlar where id = v_id) <> 'ONAYLANDI'
   or not exists (select 1 from public.tahsilatlar
                   where iptal_of = v_id and tutar_kurus = -v_ucret and yontem = 'KREDI_KARTI'
                     and durum::text = 'ONAYLANDI')
   or (select count(*) from public.tahsilatlar where iptal_of = v_id2) <> 1 then
  raise exception 'FAIL 79d: onaylanmış ödemeye tek ve doğru ters kayıt yazılmadı';
end if;
if not exists (select 1 from public.biletler
                where id = v_bilet2 and durum = 'ACIK' and tahsil_kurus = 0) then
  raise exception 'FAIL 79d: onaylanmış ödemeli bilet geri açılmadı';
end if;

-- (e) İçeride aynı plakalı başka bilet varken reddedilir (bilet kapalı kalır).
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ79GERI3', now() - interval '2 hours', v_tarife_yeni, 'ACIK')
returning id into v_id;
perform pg_temp.login(u_personel);
perform * from public.bilet_kapat(v_id, null, null, null, null, 'MOBIL', false);
perform pg_temp.logout();
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ79GERI3', now(), v_tarife_yeni, 'ACIK');
perform pg_temp.login(u_personel);
begin
  perform public.bilet_cikis_geri_al(v_id, 'Test 79e');
  raise exception 'FAIL 79e: içeride aynı plakalı bilet varken geri alındı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%önce onu iptal%' then
    raise exception 'FAIL 79e: beklenmeyen hata (aynı plaka): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if not exists (select 1 from public.biletler where id = v_id and durum = 'KAPALI') then
  raise exception 'FAIL 79e: reddedilen geri alma bileti açtı (aynı plaka)';
end if;

-- (e) İptal edilmiş bilet geri alınamaz.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ79GERI4', now() - interval '2 hours', v_tarife_yeni, 'ACIK')
returning id into v_id;
perform pg_temp.login(u_yonetici);
perform public.bilet_iptal(v_id, 'Test 79e iptal');
begin
  perform public.bilet_cikis_geri_al(v_id, 'Test 79e');
  raise exception 'FAIL 79e: iptal edilmiş bilet geri alındı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%çıkışı yapılmış%' then
    raise exception 'FAIL 79e: beklenmeyen hata (iptal): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (e) Başka vardiyanın bileti: Personel geri alamaz, Yönetici alır.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ79GERI5', now() - interval '2 hours', v_tarife_yeni, 'ACIK')
returning id into v_id;
perform pg_temp.login(u_personel);
perform * from public.bilet_kapat(v_id, null, null, null, null, 'MOBIL', false);
perform pg_temp.logout();
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE'
 where kapanis_at is null;
perform pg_temp.login(u_personel);
perform public.vardiya_ac(0);
begin
  perform public.bilet_cikis_geri_al(v_id, 'Test 79e');
  raise exception 'FAIL 79e: Personel başka vardiyanın biletini geri aldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%yetkiniz yok%' then
    raise exception 'FAIL 79e: beklenmeyen hata (vardiya): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
perform pg_temp.login(u_yonetici);
select public.bilet_cikis_geri_al(v_id, 'Yönetici düzeltti') into v_bool;
perform pg_temp.logout();
if v_bool is distinct from true
   or not exists (select 1 from public.biletler where id = v_id and durum = 'ACIK') then
  raise exception 'FAIL 79e: Yönetici başka vardiyanın biletini geri alamadı';
end if;
select v.id into v_vardiya from public.vardiyalar v where v.kapanis_at is null;

-- (f) Kameranın parasız kapattığı bilet de sebeple geri açılır; iz 054'ün
--     adıyla (bilet_kamera_geri_acildi) — 054'ün "Araç çıkmadı"sı aynen kalır.
-- (g) Kamera kapattı, sonra "Ödeme topla" ile ödendi: para geri alınır,
--     bilet açılır; araç hâlâ kameranın önündeyse kamera hemen yeniden
--     KAPATMAZ (054'ün çıkış süresi).
foreach v_txt in array array['ZZ79KMR01', 'ZZ79KMR02'] loop
  insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
  values (gen_random_uuid(), v_txt, now() - interval '2 hours', v_tarife_yeni, 'ACIK')
  returning id into v_id;
  perform pg_temp.kamera();
  perform public.kamera_cikis_bildir(v_txt, gen_random_uuid(), now(), null, null);
  perform pg_temp.logout();
  if not exists (select 1 from public.biletler
                  where id = v_id and durum = 'KAPALI' and cikis_kaynak = 'KAMERA'
                    and kapatan_vardiya_id = v_vardiya) then
    raise exception 'FAIL 79f-g: fixture — kamera % biletini vardiyada kapatmadı', v_txt;
  end if;
  v_n := 0;
  if v_txt = 'ZZ79KMR02' then
    perform pg_temp.login(u_personel);
    select public.bilet_tahsil(v_id, 'NAKIT') into v_n;
    perform pg_temp.logout();
  end if;
  perform pg_temp.login(u_personel);
  select public.bilet_cikis_geri_al(v_id, 'Araç kapıda bekledi') into v_bool;
  perform pg_temp.logout();
  if v_bool is distinct from true
     or not exists (select 1 from public.biletler
                     where id = v_id and durum = 'ACIK' and cikis_kaynak is null
                       and tahsil_kurus = 0)
     or (select count(*) from public.audit_log
          where action = 'bilet_kamera_geri_acildi' and row_id = v_id
            and detay ->> 'sebep' = 'Araç kapıda bekledi') <> 1
     or exists (select 1 from public.audit_log
                 where action = 'bilet_cikis_geri_alindi' and row_id = v_id) then
    raise exception 'FAIL 79f-g: kameranın kapattığı % bileti doğru geri açılmadı', v_txt;
  end if;
  if v_n > 0 and not exists (select 1 from public.tahsilatlar t
                              join public.tahsilatlar a on a.id = t.iptal_of
                             where a.bilet_id = v_id and t.tutar_kurus = -v_n) then
    raise exception 'FAIL 79g: kamera biletinin toplanan ödemesi geri alınmadı';
  end if;
  perform pg_temp.kamera();
  perform public.kamera_cikis_bildir(v_txt, gen_random_uuid(), now(), null, null);
  perform pg_temp.logout();
  if not exists (select 1 from public.biletler where id = v_id and durum = 'ACIK') then
    raise exception 'FAIL 79f-g: geri açılan % bileti kamera hemen yeniden kapattı', v_txt;
  end if;
end loop;

raise notice 'PASS 79: yanlışlıkla verilen çıkış geri alınır — sebepli, kendi vardiyası ya da Yönetici, para karşı kayıtla geri döner, bilet ilk giriş saatiyle açık, kamera hemen yeniden kapatmaz';

-- =====================================================================
-- 80  Abonman: ödeme günü, Personel ekler ve tahsil eder (061, 062)
--     Sahip (2026-11-15):
--       · başlangıç/bitiş seçilmez, ÖDEME GÜNÜ seçilir ("Ayın 13'ü");
--         29–31 kısa ayda ayın son günü olur;
--       · Personel abonmanları görür, ekler (ilk ödeme aynı formda) ve
--         tahsil eder; düzenleme / iptal / silme Yönetici'de kalır;
--       · Personel'in eklediği abonman Yönetici'ye adıyla bildirilir;
--       · ödeme açık vardiyaya yazılır, Onay bekler; uzatma aynı çağrıda.
-- =====================================================================
perform pg_temp.logout();
if to_regprocedure('public.abonman_ekle(text, text, text, integer, integer, uuid, text, integer, public.odeme_yontemi)') is null
   or to_regprocedure('public.abonman_tahsil(uuid, public.odeme_yontemi, integer, boolean)') is null
   or to_regprocedure('public.abonman_sonraki_yenileme(integer, date)') is null then
  raise exception 'FAIL 80: 062 çalıştırılmadı (abonman_ekle / abonman_tahsil / abonman_sonraki_yenileme yok)';
end if;
if not exists (select 1 from public.profiles
                where id = u_personel and rol = 'PERSONEL' and durum = 'ACTIVE')
   or not exists (select 1 from public.profiles
                   where id = u_yonetici and rol = 'YONETICI' and durum = 'ACTIVE') then
  raise exception 'FAIL 80: fixture — u_personel / u_yonetici rolü beklenen gibi değil';
end if;

-- (a) Yetkiler. Eski üç argümanlı abonman_tahsil yok; yardımcı kimseye açık değil.
if to_regprocedure('public.abonman_tahsil(uuid, public.odeme_yontemi, integer)') is not null then
  raise exception 'FAIL 80a: eski abonman_tahsil(uuid, odeme_yontemi, integer) duruyor';
end if;
foreach v_txt in array array[
    'public.abonman_ekle(text, text, text, integer, integer, uuid, text, integer, public.odeme_yontemi)',
    'public.abonman_tahsil(uuid, public.odeme_yontemi, integer, boolean)'] loop
  if not has_function_privilege('authenticated', v_txt, 'execute')
     or has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('service_role', v_txt, 'execute') then
    raise exception 'FAIL 80a: % yetkileri yanlış', v_txt;
  end if;
end loop;
foreach v_txt2 in array array['anon', 'authenticated', 'service_role'] loop
  if has_function_privilege(v_txt2, 'public.abonman_sonraki_yenileme(integer, date)', 'execute') then
    raise exception 'FAIL 80a: abonman_sonraki_yenileme % rolüne açık', v_txt2;
  end if;
end loop;
if not public.bildirim_yonetici_turu('YENI_ABONMAN') then
  raise exception 'FAIL 80a: YENI_ABONMAN Yönetici''ye özel bildirim değil';
end if;

-- (b) Sonraki ödeme günü: verilen günden SONRAKİ ilk tarih; kısa ayda ayın
--     son günü. tests/abonman.check.mjs aynı tabloyu istemci için sınar.
foreach v_txt in array array[
    '13|2026-11-13|2026-12-13', '13|2026-11-12|2026-11-13', '31|2027-02-15|2027-02-28',
    '31|2027-02-28|2027-03-31', '31|2028-02-15|2028-02-29', '30|2028-02-29|2028-03-30',
    '1|2026-12-01|2027-01-01',  '15|2026-12-20|2027-01-15', '31|2026-04-30|2026-05-31',
    '31|2026-03-31|2026-04-30', '29|2027-01-31|2027-02-28', '1|2026-11-30|2026-12-01'] loop
  if public.abonman_sonraki_yenileme(split_part(v_txt, '|', 1)::integer,
                                     split_part(v_txt, '|', 2)::date)
     is distinct from split_part(v_txt, '|', 3)::date then
    raise exception 'FAIL 80b: sonraki ödeme günü yanlış (gün|tarih|beklenen = %): %', v_txt,
      public.abonman_sonraki_yenileme(split_part(v_txt, '|', 1)::integer,
                                      split_part(v_txt, '|', 2)::date);
  end if;
end loop;

v_gun := (now() at time zone 'Europe/Istanbul')::date;

-- (c) Rolsüz kullanıcı ekleyemez.
perform pg_temp.login(u_pending);
begin
  perform public.abonman_ekle('ZZ80ABN1', 'X', null, 100000, 5, null, null, 100000, 'NAKIT');
  raise exception 'FAIL 80c: rolsüz kullanıcı abonman ekledi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yetkiniz yok%' then
    raise exception 'FAIL 80c: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (d) Açık vardiya yokken Personel ne ekler ne tahsil eder (para kasaya
--     yazılır). Yönetici ücretsiz (ilk ödemesiz) abonman ekleyebilir.
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE'
 where kapanis_at is null;
perform pg_temp.login(u_personel);
begin
  perform public.abonman_ekle('ZZ80ABN1', 'X', null, 100000, 5, null, null, 100000, 'NAKIT');
  raise exception 'FAIL 80d: vardiyasız Personel abonman ekledi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%vardiya%' then
    raise exception 'FAIL 80d: beklenmeyen hata (ekle): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if exists (select 1 from public.abonmanlar where plaka = 'ZZ80ABN1') then
  raise exception 'FAIL 80d: reddedilen ekleme abonman bıraktı';
end if;

select count(*) into v_bigint from public.tahsilatlar;
perform pg_temp.login(u_yonetici);
v_id := public.abonman_ekle('zz80 abn0', 'Ücretsiz Müşteri', null, 0, 13, null, null, 0, null);
perform pg_temp.logout();
if not exists (select 1 from public.abonmanlar
                where id = v_id and plaka = 'ZZ80ABN0' and durum = 'AKTIF' and yenileme_gunu = 13
                  and baslangic = v_gun
                  and bitis = public.abonman_sonraki_yenileme(13, v_gun)
                  and olusturan = u_yonetici) then
  raise exception 'FAIL 80d: Yönetici''nin ücretsiz abonmanı doğru eklenmedi';
end if;
if (select count(*) from public.tahsilatlar) <> v_bigint then
  raise exception 'FAIL 80d: ilk ödemesiz abonman tahsilat yazdı';
end if;

perform pg_temp.login(u_personel);
begin
  perform public.abonman_tahsil(v_id, 'NAKIT', 100000, true);
  raise exception 'FAIL 80d: vardiyasız Personel abonman tahsil etti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%vardiya%' then
    raise exception 'FAIL 80d: beklenmeyen hata (tahsil): %', sqlerrm;
  end if;
end;
perform public.vardiya_ac(0);
perform pg_temp.logout();
select v.id into v_vardiya from public.vardiyalar v where v.kapanis_at is null;

-- (e) Personel ilk ödemeyle ekler: abonman bugünden sonraki ödeme gününe
--     kadar geçerli; ödeme vardiyasına, Onay bekler; iz; Yönetici'ye adıyla
--     bildirim.
select ad_soyad into v_txt3 from public.profiles where id = u_personel;
perform pg_temp.login(u_personel);
v_abonman := public.abonman_ekle('ZZ80ABN1', '  Test Müşteri  ', '5321234567', 150000, 5, null,
                                 null, 150000, 'NAKIT');
perform pg_temp.logout();
if not exists (select 1 from public.abonmanlar
                where id = v_abonman and plaka = 'ZZ80ABN1' and musteri_ad = 'Test Müşteri'
                  and musteri_tel = '5321234567' and ucret_kurus = 150000 and yenileme_gunu = 5
                  and durum = 'AKTIF' and baslangic = v_gun
                  and bitis = public.abonman_sonraki_yenileme(5, v_gun)
                  and olusturan = u_personel) then
  raise exception 'FAIL 80e: Personel''in abonmanı doğru eklenmedi';
end if;
if (select count(*) from public.tahsilatlar
     where abonman_id = v_abonman and tur::text = 'ABONMAN' and tutar_kurus = 150000
       and yontem = 'NAKIT' and vardiya_id = v_vardiya and durum::text = 'BEKLIYOR'
       and created_by = u_personel and iptal_of is null) <> 1 then
  raise exception 'FAIL 80e: ilk ödeme vardiyaya, onay bekler hâlde yazılmadı';
end if;
if not exists (select 1 from public.audit_log
                where action = 'abonman_ekle' and row_id = v_abonman and actor = u_personel) then
  raise exception 'FAIL 80e: abonman ekleme denetime yazılmadı';
end if;
if (select count(*) from public.notifications
     where profile_id = u_yonetici and tur::text = 'YENI_ABONMAN'
       and link = '/abonman/' || v_abonman
       and govde like '%' || v_txt3 || '%' and govde like '%ZZ80ABN1%') <> 1 then
  raise exception 'FAIL 80e: Yönetici''ye Personel''in adıyla tek bildirim gitmedi';
end if;
-- Personel abonman_gecerli_mi ile de bulur (giriş ücretsiz).
perform pg_temp.login(u_personel);
select a.gecerli into v_bool from public.abonman_gecerli_mi('ZZ80ABN1') a;
perform pg_temp.logout();
if v_bool is distinct from true then
  raise exception 'FAIL 80e: yeni abonman girişte geçerli görünmüyor';
end if;

-- (f) Hiçbir şey yazmayan retler: Personel ilk ödemesiz; gün 0 / 32;
--     aynı plakada çakışan dönem (Türkçe mesaj, tahsilat yok).
select count(*) into v_bigint from public.tahsilatlar;
perform pg_temp.login(u_personel);
foreach v_txt in array array['tutar0', 'gun0', 'gun32', 'cakisma'] loop
  begin
    case v_txt
      when 'tutar0' then
        perform public.abonman_ekle('ZZ80ABN2', 'X', null, 100000, 5, null, null, 0, null);
      when 'gun0' then
        perform public.abonman_ekle('ZZ80ABN2', 'X', null, 100000, 0, null, null, 100000, 'NAKIT');
      when 'gun32' then
        perform public.abonman_ekle('ZZ80ABN2', 'X', null, 100000, 32, null, null, 100000, 'NAKIT');
      else
        perform public.abonman_ekle('ZZ80ABN1', 'X', null, 100000, 5, null, null, 100000, 'NAKIT');
    end case;
    raise exception 'FAIL 80f: % kabul edildi', v_txt;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    v_txt2 := case v_txt
                when 'tutar0' then '%sıfırdan büyük%'
                when 'cakisma' then '%başka bir abonmanı var%'
                else '%1 ile 31%' end;
    if sqlerrm not like v_txt2 then
      raise exception 'FAIL 80f: % için beklenmeyen hata: %', v_txt, sqlerrm;
    end if;
  end;
end loop;
perform pg_temp.logout();
if exists (select 1 from public.abonmanlar where plaka = 'ZZ80ABN2')
   or (select count(*) from public.abonmanlar where plaka = 'ZZ80ABN1') <> 1
   or (select count(*) from public.tahsilatlar) <> v_bigint then
  raise exception 'FAIL 80f: reddedilen ekleme abonman ya da tahsilat bıraktı';
end if;

-- (g) Personel tahsil eder. Süresi sürerken uzatma bitişi bir sonraki ödeme
--     gününe taşır; uzatmasız yalnızca ödeme; süresi dolmuşsa dönem bugünden
--     yeniden başlar; iptal edilmiş abonman tahsil edilmez.
select bitis, baslangic into v_ts2, v_ts from (select bitis::timestamptz, baslangic::timestamptz
  from public.abonmanlar where id = v_abonman) x;
perform pg_temp.login(u_personel);
select public.abonman_tahsil(v_abonman, 'KREDI_KARTI', 150000, true) into v_id2;
perform pg_temp.logout();
if not exists (select 1 from public.abonmanlar
                where id = v_abonman and baslangic = v_ts::date and durum = 'AKTIF'
                  and bitis = public.abonman_sonraki_yenileme(5, v_ts2::date))
   or not exists (select 1 from public.tahsilatlar
                   where id = v_id2 and abonman_id = v_abonman and tutar_kurus = 150000
                     and yontem = 'KREDI_KARTI' and vardiya_id = v_vardiya and durum::text = 'BEKLIYOR') then
  raise exception 'FAIL 80g: süren abonman bir sonraki ödeme gününe uzamadı ya da ödeme vardiyaya yazılmadı';
end if;
select bitis::timestamptz into v_ts2 from public.abonmanlar where id = v_abonman;
select count(*) into v_bigint from public.tahsilatlar where abonman_id = v_abonman;
perform pg_temp.login(u_personel);
perform public.abonman_tahsil(v_abonman, 'NAKIT', 50000, false);
perform pg_temp.logout();
if (select bitis from public.abonmanlar where id = v_abonman) <> v_ts2::date
   or (select count(*) from public.tahsilatlar where abonman_id = v_abonman) <> v_bigint + 1 then
  raise exception 'FAIL 80g: uzatmasız tahsilat bitişi değiştirdi ya da ödeme yazmadı';
end if;

update public.abonmanlar
   set baslangic = v_gun - 60, bitis = v_gun - 20, durum = 'DOLDU'
 where id = v_id;
perform pg_temp.login(u_personel);
perform public.abonman_tahsil(v_id, 'NAKIT', 100000, true);
perform pg_temp.logout();
if not exists (select 1 from public.abonmanlar
                where id = v_id and durum = 'AKTIF' and baslangic = v_gun
                  and bitis = public.abonman_sonraki_yenileme(13, v_gun)) then
  raise exception 'FAIL 80g: süresi dolan abonman bugünden yeniden başlamadı';
end if;

update public.abonmanlar set durum = 'IPTAL' where id = v_id;
select count(*) into v_bigint from public.tahsilatlar;
perform pg_temp.login(u_personel);
begin
  perform public.abonman_tahsil(v_id, 'NAKIT', 100000, true);
  raise exception 'FAIL 80g: iptal edilmiş abonman tahsil edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%İptal edilmiş%' then
    raise exception 'FAIL 80g: beklenmeyen hata (iptal): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if (select count(*) from public.tahsilatlar) <> v_bigint then
  raise exception 'FAIL 80g: reddedilen tahsilat satır bıraktı';
end if;

-- (h) Personel tabloya doğrudan yazamaz: düzenleme / silme 0 satır, ekleme
--     reddedilir. (Düzenle, İptal, Sil Yönetici'nin.)
perform pg_temp.login(u_personel);
update public.abonmanlar set ucret_kurus = 1 where id = v_abonman;
get diagnostics v_n = row_count;
delete from public.abonmanlar where id = v_abonman;
get diagnostics v_n2 = row_count;
if v_n <> 0 or v_n2 <> 0 then
  raise exception 'FAIL 80h: Personel abonmanı doğrudan değiştirdi/sildi (% / %)', v_n, v_n2;
end if;
begin
  insert into public.abonmanlar (plaka, baslangic, bitis, ucret_kurus)
  values ('ZZ80ABN3', v_gun, v_gun + 30, 1);
  raise exception 'FAIL 80h: Personel abonmanı doğrudan ekledi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%row-level security%' then
    raise exception 'FAIL 80h: beklenmeyen hata (ekleme): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if not exists (select 1 from public.abonmanlar where id = v_abonman and ucret_kurus = 150000) then
  raise exception 'FAIL 80h: Personel''in denemesi abonmanı değiştirdi';
end if;

raise notice 'PASS 80: abonman ödeme günüyle — Personel görür, ilk ödemeyle ekler (Yönetici adıyla bilgilenir) ve tahsil eder; uzatma aynı çağrıda; düzenleme Yönetici''de';

-- =====================================================================
-- 81  Kim yaptı: toplayan ve onaylayan (063)
--     Sahip (2026-11-15): Onay'da "Ödeme toplayan", karar verilince ve
--     Finans'ta "Ödeme toplayan" + "Onaylayan/Reddeden"; kasa kaydında
--     "Kaydeden". Adları yalnızca Yönetici görür.
--       · onay_listesi onaylayanın ADINI ve karar anını da döndürür;
--       · kasa_hareketleri.created_by artık hep dolar: oturum açan kişi
--         (gönderilen değer yok sayılır), gece işinde kuralı yazan kişi.
--     Aynı geri alınan transaction içinde PASS 80'den kalan açık vardiya
--     olabilir: vardiya yalnızca yoksa açılır, satırlar kimliğiyle bulunur.
-- =====================================================================
perform pg_temp.logout();
if to_regprocedure('public.kasa_hareketi_kaydeden()') is null then
  raise exception 'FAIL 81: 063 çalıştırılmadı (kasa_hareketi_kaydeden yok)';
end if;
if not exists (select 1 from public.profiles
                where id = u_personel and rol = 'PERSONEL' and durum = 'ACTIVE')
   or not exists (select 1 from public.profiles
                   where id = u_yonetici and rol = 'YONETICI' and durum = 'ACTIVE') then
  raise exception 'FAIL 81: fixture — u_personel / u_yonetici rolü beklenen gibi değil';
end if;
select ad_soyad into v_txt  from public.profiles where id = u_personel;
select ad_soyad into v_txt2 from public.profiles where id = u_yonetici;

-- (a) Yetkiler: onay_listesi yalnızca authenticated'e (içeride Yönetici
--     denetimi); tetik fonksiyonu kimseye açık değil; tetik takılı.
if not has_function_privilege('authenticated', 'public.onay_listesi(public.onay_durum)', 'execute')
   or has_function_privilege('anon', 'public.onay_listesi(public.onay_durum)', 'execute')
   or has_function_privilege('service_role', 'public.onay_listesi(public.onay_durum)', 'execute') then
  raise exception 'FAIL 81a: onay_listesi yetkileri yanlış';
end if;
foreach v_txt3 in array array['anon', 'authenticated', 'service_role'] loop
  if has_function_privilege(v_txt3, 'public.kasa_hareketi_kaydeden()', 'execute') then
    raise exception 'FAIL 81a: kasa_hareketi_kaydeden % rolüne açık', v_txt3;
  end if;
end loop;
if not exists (select 1 from pg_trigger
                where tgrelid = 'public.kasa_hareketleri'::regclass
                  and tgname = 'kasa_hareketi_kaydeden_tg' and not tgisinternal) then
  raise exception 'FAIL 81a: kasa_hareketi_kaydeden_tg tetiği yok';
end if;

-- (b) Personel iki abonman ekler (ilk ödemeyle): biri onaylanacak, biri
--     reddedilecek.
v_gun := (now() at time zone 'Europe/Istanbul')::date;
perform pg_temp.login(u_personel);
if public.acik_vardiyam() is null then
  perform public.vardiya_ac(0);
end if;
v_id  := public.abonman_ekle('ZZ81ABN1', 'zz81 bir', null, 90000, 7, null, null, 90000, 'NAKIT');
v_id2 := public.abonman_ekle('ZZ81ABN2', 'zz81 iki', null, 80000, 9, null, null, 80000, 'KREDI_KARTI');
perform pg_temp.logout();
select t.id into v_islem from public.tahsilatlar t where t.abonman_id = v_id  and t.iptal_of is null;
select t.id into v_hesap from public.tahsilatlar t where t.abonman_id = v_id2 and t.iptal_of is null;
if v_islem is null or v_hesap is null then
  raise exception 'FAIL 81b: fixture — abonman ödemeleri yazılmadı';
end if;

-- Bekleyen: toplayan adıyla, onaylayan boş.
perform pg_temp.login(u_yonetici);
select * into v_rec from public.onay_listesi('BEKLIYOR') o where o.id = v_islem;
if not found then
  raise exception 'FAIL 81b: bekleyen ödeme onay_listesi''nde yok';
end if;
if v_rec.personel is distinct from v_txt
   or v_rec.onaylayan is not null or v_rec.onay_at is not null then
  raise exception 'FAIL 81b: bekleyen satır yanlış (toplayan %, onaylayan %, an %)',
    v_rec.personel, v_rec.onaylayan, v_rec.onay_at;
end if;

-- (c) Onaylanan: toplayan + onaylayanın adı + an.
if public.tahsilat_onayla(array[v_islem]) <> 1 then
  raise exception 'FAIL 81c: tahsilat_onayla satırı onaylamadı';
end if;
select * into v_rec from public.onay_listesi('ONAYLANDI') o where o.id = v_islem;
if not found then
  raise exception 'FAIL 81c: onaylanan ödeme onay_listesi(ONAYLANDI)''nda yok';
end if;
if v_rec.personel is distinct from v_txt
   or v_rec.onaylayan is distinct from v_txt2
   or v_rec.onay_at is null then
  raise exception 'FAIL 81c: onaylanan satır yanlış (toplayan %, onaylayan %, an %)',
    v_rec.personel, v_rec.onaylayan, v_rec.onay_at;
end if;

-- (d) Reddedilen: reddedenin adı aynı sütunda.
if public.tahsilat_reddet(array[v_hesap], 'zz81 deneme') <> 1 then
  raise exception 'FAIL 81d: tahsilat_reddet satırı reddetmedi';
end if;
select * into v_rec from public.onay_listesi('REDDEDILDI') o where o.id = v_hesap;
if not found then
  raise exception 'FAIL 81d: reddedilen ödeme onay_listesi(REDDEDILDI)''nda yok';
end if;
if v_rec.personel is distinct from v_txt
   or v_rec.onaylayan is distinct from v_txt2
   or v_rec.onay_at is null
   or v_rec.onay_notu is distinct from 'zz81 deneme' then
  raise exception 'FAIL 81d: reddedilen satır yanlış (toplayan %, reddeden %, not %)',
    v_rec.personel, v_rec.onaylayan, v_rec.onay_notu;
end if;
perform pg_temp.logout();

-- (e) Personel listeyi hâlâ okuyamaz.
perform pg_temp.login(u_personel);
begin
  perform * from public.onay_listesi('ONAYLANDI');
  raise exception 'FAIL 81e: Personel onay_listesi''ni okudu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yetkiniz yok%' then
    raise exception 'FAIL 81e: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (f) Kasa kaydı: Yönetici elle girer → kaydeden Yönetici; başkasının
--     kimliğini gönderse de Yönetici yazılır (taklit edilemez).
perform pg_temp.login(u_yonetici);
insert into public.kasa_hareketleri (tur, tutar_kurus, aciklama, kategori, yontem)
values ('GIDER', 1234, 'zz81 elle', 'Diğer', 'NAKIT')
returning id into v_id;
insert into public.kasa_hareketleri (tur, tutar_kurus, aciklama, kategori, yontem, created_by)
values ('GELIR', 4321, 'zz81 taklit', 'Diğer', 'NAKIT', u_personel)
returning id into v_id2;
perform pg_temp.logout();
if (select created_by from public.kasa_hareketleri where id = v_id) is distinct from u_yonetici then
  raise exception 'FAIL 81f: elle girilen kasa kaydında kaydeden Yönetici değil';
end if;
if (select created_by from public.kasa_hareketleri where id = v_id2) is distinct from u_yonetici then
  raise exception 'FAIL 81f: kasa kaydında kaydeden taklit edilebildi';
end if;

-- (g) Gece işi (oturum yok): düzenli kaydın satırı kuralı yazanı alır.
insert into public.kasa_tekrar_kurallari (tur, tutar_kurus, kategori, aciklama, yontem,
                                         odeme_gunu, next_run, created_by)
values ('GIDER', 5555, 'Diğer', 'zz81 kural', 'HAVALE', 5, v_gun + 400, u_yonetici)
returning id into v_id;
insert into public.kasa_hareketleri (tur, tutar_kurus, aciklama, kategori, yontem,
                                     tekrar_kural_id, tarih)
values ('GIDER', 5555, 'zz81 kural', 'Diğer', 'HAVALE', v_id, v_gun + 400)
returning id into v_id2;
if (select created_by from public.kasa_hareketleri where id = v_id2) is distinct from u_yonetici then
  raise exception 'FAIL 81g: düzenli kayıt satırı kuralı yazanı almadı';
end if;

-- (h) Çöpten geri alınan kasa kaydı ilk kaydedenini korur (geri alan
--     Yönetici kaydeden olmaz).
insert into public.kasa_hareketleri (tur, tutar_kurus, aciklama, kategori, yontem, created_by)
values ('GELIR', 777, 'zz81 cop', 'Diğer', 'NAKIT', u_personel)
returning id into v_id;
if (select created_by from public.kasa_hareketleri where id = v_id) is distinct from u_personel then
  raise exception 'FAIL 81h: fixture — oturumsuz eklemede gönderilen kaydeden korunmadı';
end if;
delete from public.kasa_hareketleri where id = v_id;
select c.id into v_id2 from public.cop c
 where c.tablo = 'kasa_hareketleri' and c.kayit_id = v_id;
if v_id2 is null then
  raise exception 'FAIL 81h: fixture — silinen kasa kaydı çöpe düşmedi';
end if;
perform pg_temp.login(u_yonetici);
perform public.cop_geri_al(v_id2);
perform pg_temp.logout();
if (select created_by from public.kasa_hareketleri where id = v_id) is distinct from u_personel then
  raise exception 'FAIL 81h: çöpten geri alınan kasa kaydının kaydedeni değişti';
end if;

raise notice 'PASS 81: kim yaptı — onay_listesi toplayanı ve onaylayanı/reddedeni adıyla, anıyla verir; kasa kaydının kaydedeni hep dolar, taklit edilemez';

-- =====================================================================
-- 82  Ücretsiz çıkış: sebep + zorunlu not (064, 065)
--     Sahip (2026-11-15): fiyat soran, polis, ambulans, personel aracı…
--     Her rol çıkış ekranından ücretsiz çıkış verir: sebep seçer, not
--     yazar (zorunlu). Para yazılmaz (tahsilat yok, Onay'a düşmez);
--     Yönetici adıyla bilgilendirilir, onay beklenmez.
-- =====================================================================
perform pg_temp.logout();
if to_regprocedure('public.bilet_ucretsiz_cikis(uuid, public.ucretsiz_sebep, text)') is null then
  raise exception 'FAIL 82: 065 çalıştırılmadı (bilet_ucretsiz_cikis yok)';
end if;
if not exists (select 1 from public.profiles
                where id = u_personel and rol = 'PERSONEL' and durum = 'ACTIVE')
   or not exists (select 1 from public.profiles
                   where id = u_yonetici and rol = 'YONETICI' and durum = 'ACTIVE') then
  raise exception 'FAIL 82: fixture — u_personel / u_yonetici rolü beklenen gibi değil';
end if;
select ad_soyad into v_txt from public.profiles where id = u_personel;

-- (a) Tür, yetkiler, Yönetici'ye özel bildirim.
select string_agg(e.enumlabel, ',' order by e.enumsortorder) into v_txt2
  from pg_enum e where e.enumtypid = 'public.ucretsiz_sebep'::regtype;
if v_txt2 is distinct from 'FIYAT_SORDU,POLIS,ACIL,PERSONEL,DIGER' then
  raise exception 'FAIL 82a: ucretsiz_sebep değerleri beklenmedik: %', v_txt2;
end if;
v_txt3 := 'public.bilet_ucretsiz_cikis(uuid, public.ucretsiz_sebep, text)';
if not has_function_privilege('authenticated', v_txt3, 'execute')
   or has_function_privilege('anon', v_txt3, 'execute')
   or has_function_privilege('service_role', v_txt3, 'execute') then
  raise exception 'FAIL 82a: bilet_ucretsiz_cikis yetkileri yanlış';
end if;
if not public.bildirim_yonetici_turu('UCRETSIZ_CIKIS') then
  raise exception 'FAIL 82a: UCRETSIZ_CIKIS Yönetici''ye özel bildirim değil';
end if;

-- Ücreti olan açık bilet (3 saat önce girmiş).
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ82UCR1', now() - interval '3 hours', v_tarife_yeni, 'ACIK')
returning id into v_bilet;
v_ucret := public.ucret_hesapla(now() - interval '3 hours', now(), v_tarife_yeni);
if coalesce(v_ucret, 0) <= 0 then
  raise exception 'FAIL 82: fixture — 3 saatlik kalışın ücreti yok (%)', v_ucret;
end if;

-- (b) Rolsüz kullanıcı yapamaz.
perform pg_temp.login(u_pending);
begin
  perform public.bilet_ucretsiz_cikis(v_bilet, 'POLIS', 'Ekip aracı');
  raise exception 'FAIL 82b: rolsüz kullanıcı ücretsiz çıkış verdi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yetkiniz yok%' then
    raise exception 'FAIL 82b: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (c) Not zorunlu, en fazla 200 karakter; reddedilen deneme bileti açık bırakır.
perform pg_temp.login(u_personel);
if public.acik_vardiyam() is null then
  perform public.vardiya_ac(0);
end if;
foreach v_txt2 in array array['', '   ', repeat('x', 201)] loop
  begin
    perform public.bilet_ucretsiz_cikis(v_bilet, 'POLIS', v_txt2);
    raise exception 'FAIL 82c: geçersiz notla (% karakter) ücretsiz çıkış verildi', length(v_txt2);
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like '%Not%' then
      raise exception 'FAIL 82c: beklenmeyen hata (not): %', sqlerrm;
    end if;
  end;
end loop;
begin
  perform public.bilet_ucretsiz_cikis(v_bilet, 'POLIS', null);
  raise exception 'FAIL 82c: notsuz ücretsiz çıkış verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Not%' then
    raise exception 'FAIL 82c: beklenmeyen hata (null not): %', sqlerrm;
  end if;
end;
begin
  perform public.bilet_ucretsiz_cikis(v_bilet, null, 'Ekip aracı');
  raise exception 'FAIL 82c: sebepsiz ücretsiz çıkış verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Sebep%' then
    raise exception 'FAIL 82c: beklenmeyen hata (sebep): %', sqlerrm;
  end if;
end;
v_vardiya := public.acik_vardiyam();
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'ACIK' and ucretsiz_sebep is null) then
  raise exception 'FAIL 82c: reddedilen deneme bileti değiştirdi';
end if;

-- (d) Personel geçerli çağrı: bilet 0 ₺ kapanır, para yazılmaz, iz ve bildirim kalır.
select count(*) into v_bigint from public.tahsilatlar;
perform pg_temp.login(u_personel);
perform public.bilet_ucretsiz_cikis(v_bilet, 'POLIS', '  Ekip aracı  ');
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'KAPALI'
                  and ucret_kurus = 0 and tahsil_kurus = 0 and odeme_yontemi is null
                  and ucretsiz_sebep = 'POLIS' and ucretsiz_not = 'Ekip aracı'
                  and ucret_degistirildi and ucret_sebep like 'Ücretsiz çıkış%'
                  and cikis_by = u_personel and cikis_kaynak = 'MOBIL'
                  and kapatan_vardiya_id is not distinct from v_vardiya
                  and cikis_at is not null) then
  raise exception 'FAIL 82d: bilet ücretsiz çıkışla doğru kapanmadı';
end if;
if (select count(*) from public.tahsilatlar) <> v_bigint then
  raise exception 'FAIL 82d: ücretsiz çıkış tahsilat satırı yazdı';
end if;
if not exists (select 1 from public.audit_log
                where action = 'bilet_ucretsiz_cikis' and row_id = v_bilet
                  and actor = u_personel
                  and (detay ->> 'hesaplanan')::integer > 0
                  and detay ->> 'sebep' = 'POLIS') then
  raise exception 'FAIL 82d: denetim kaydı yok ya da eksik';
end if;
if (select count(*) from public.notifications
     where profile_id = u_yonetici and tur::text = 'UCRETSIZ_CIKIS'
       and link = '/gise/bilet/' || v_bilet
       and govde like '%' || v_txt || '%' and govde like '%ZZ82UCR1%'
       and govde like '%Polis%' and govde like '%Ekip aracı%') <> 1 then
  raise exception 'FAIL 82d: Yönetici''ye Personel''in adıyla tek bildirim gitmedi';
end if;

-- (e) Kapanmış bilet ikinci kez verilemez. 066'dan beri kapalı bilet kendi
--     dalına girer ("zaten ücretsiz çıkış verilmiş"); 065'te "zaten
--     kapatılmış" idi — ikisi de "zaten".
perform pg_temp.login(u_personel);
begin
  perform public.bilet_ucretsiz_cikis(v_bilet, 'DIGER', 'Tekrar');
  raise exception 'FAIL 82e: kapanmış bilete ikinci kez ücretsiz çıkış verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%zaten%' then
    raise exception 'FAIL 82e: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (f) Puan kullanılmış bilet: önce puan geri alınır; bilet açık kalır.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum,
                             indirim_kurus, puan_kullanilan)
values (gen_random_uuid(), 'ZZ82UCR2', now() - interval '3 hours', v_tarife_yeni, 'ACIK', 100, 10)
returning id into v_bilet2;
perform pg_temp.login(u_personel);
begin
  perform public.bilet_ucretsiz_cikis(v_bilet2, 'FIYAT_SORDU', 'Fiyat sordu, çıktı');
  raise exception 'FAIL 82f: puan kullanılmış bilete ücretsiz çıkış verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%puan%' then
    raise exception 'FAIL 82f: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if not exists (select 1 from public.biletler where id = v_bilet2 and durum = 'ACIK') then
  raise exception 'FAIL 82f: reddedilen deneme bileti kapattı';
end if;

-- (g) Yönetici kendisi verirse kendine bildirim gitmez; denetim yine yazılır.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ82UCR3', now() - interval '3 hours', v_tarife_yeni, 'ACIK')
returning id into v_id;
perform pg_temp.login(u_yonetici);
perform public.bilet_ucretsiz_cikis(v_id, 'ACIL', 'Ambulans');
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_id and durum = 'KAPALI' and ucretsiz_sebep = 'ACIL'
                  and cikis_by = u_yonetici) then
  raise exception 'FAIL 82g: Yönetici''nin ücretsiz çıkışı bileti kapatmadı';
end if;
if exists (select 1 from public.notifications
            where profile_id = u_yonetici and tur::text = 'UCRETSIZ_CIKIS'
              and link = '/gise/bilet/' || v_id) then
  raise exception 'FAIL 82g: Yönetici kendi ücretsiz çıkışı için bildirim aldı';
end if;
if not exists (select 1 from public.audit_log
                where action = 'bilet_ucretsiz_cikis' and row_id = v_id
                  and actor = u_yonetici) then
  raise exception 'FAIL 82g: Yönetici''nin ücretsiz çıkışı denetime yazılmadı';
end if;

-- (h) "Araç çıkmadı" (060) ücretsiz çıkışı geri açarsa sebep ve not da düşer —
-- yoksa bilet sonra parayla çıksa bile "Ücretsiz" görünürdü.
perform pg_temp.login(u_yonetici);
perform public.bilet_cikis_geri_al(v_id, 'Araç içeride');
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_id and durum = 'ACIK'
                  and ucretsiz_sebep is null and ucretsiz_not is null) then
  raise exception 'FAIL 82h: geri açılan ücretsiz çıkışın sebebi/notu kaldı';
end if;

raise notice 'PASS 82: ücretsiz çıkış — her rol, sebep ve zorunlu notla; para yazılmaz, bilet 0 ₺ kapanır, Yönetici adıyla bilgilenir; geri açılınca sebep düşer';

-- =====================================================================
-- 83  Sonradan ücretsiz (066): kameranın ya da "Çıkış Ver"in borçlu
--     kapattığı bilete ücretsiz çıkış; kimin verdiği yazılır
-- =====================================================================
-- Sahip (2026-11-15): kamera aracı ödemesiz kapatınca (054) bilet "Ödeme
-- topla" kutusuyla kalıyordu; polis aracını yalnızca "tahsil" edebiliyordu.
-- Aynı RPC kapalı + borçlu bilette ücreti 0 yapar; yetki bilet_tahsil'inki.
-- Test kullanıcılarının durumu o an okunur; plakalar ZZ83….

select ad_soyad into v_txt from public.profiles where id = u_personel;

-- (a) Fixture: Personel aracı borçlu çıkarır (027, "Çıkış Ver").
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ83SON1', now() - interval '3 hours', v_tarife_yeni, 'ACIK')
returning id into v_bilet;
perform pg_temp.login(u_personel);
if public.acik_vardiyam() is null then
  perform public.vardiya_ac(0);
end if;
v_vardiya := public.acik_vardiyam();
perform * from public.bilet_kapat(v_bilet, null, null, null, null, 'MOBIL', false);
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'KAPALI' and ucret_kurus = 5000
                  and tahsil_kurus = 0 and kapatan_vardiya_id = v_vardiya) then
  raise exception 'FAIL 83a: fixture — bilet 5000 kuruş borçlu kapanmadı';
end if;

-- (b) PENDING, boş not, sebepsiz: reddedilir, bilet değişmez.
perform pg_temp.login(u_pending);
begin
  perform public.bilet_ucretsiz_cikis(v_bilet, 'POLIS', 'Ekip aracı');
  raise exception 'FAIL 83b: PENDING kapalı bilete ücretsiz çıkış verdi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yetkiniz yok%' then
    raise exception 'FAIL 83b: beklenmeyen hata (PENDING): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
begin
  perform public.bilet_ucretsiz_cikis(v_bilet, 'POLIS', '   ');
  raise exception 'FAIL 83b: notsuz sonradan ücretsiz verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Not%' then
    raise exception 'FAIL 83b: beklenmeyen hata (not): %', sqlerrm;
  end if;
end;
begin
  perform public.bilet_ucretsiz_cikis(v_bilet, null, 'Ekip aracı');
  raise exception 'FAIL 83b: sebepsiz sonradan ücretsiz verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Sebep%' then
    raise exception 'FAIL 83b: beklenmeyen hata (sebep): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and ucret_kurus = 5000 and ucretsiz_sebep is null) then
  raise exception 'FAIL 83b: reddedilen deneme bileti değiştirdi';
end if;

-- (c) Personel kendi vardiyasının bileti: ücret 0, borç kalmaz, para yazılmaz;
--     çıkış bilgileri olduğu gibi kalır; veren ve zaman yazılır.
select count(*) into v_bigint from public.tahsilatlar;
select cikis_at into v_ts from public.biletler where id = v_bilet;
perform pg_temp.login(u_personel);
perform public.bilet_ucretsiz_cikis(v_bilet, 'POLIS', '  Ekip aracı, kamera çıkışı  ');
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'KAPALI'
                  and cikis_at = v_ts and cikis_by = u_personel and cikis_kaynak = 'MOBIL'
                  and ucret_kurus = 0 and tahsil_kurus = 0 and odeme_yontemi is null
                  and ucretsiz_sebep = 'POLIS' and ucretsiz_not = 'Ekip aracı, kamera çıkışı'
                  and ucretsiz_by = u_personel and ucretsiz_at is not null
                  and ucret_degistirildi and ucret_sebep like 'Ücretsiz çıkış%') then
  raise exception 'FAIL 83c: kapalı bilet sonradan ücretsize doğru dönmedi';
end if;
if (select count(*) from public.tahsilatlar) <> v_bigint then
  raise exception 'FAIL 83c: sonradan ücretsiz tahsilat satırı yazdı';
end if;
if not exists (select 1 from public.audit_log
                where action = 'bilet_ucretsiz_cikis' and row_id = v_bilet
                  and actor = u_personel
                  and (detay ->> 'hesaplanan')::integer = 5000
                  and (detay ->> 'sonradan')::boolean) then
  raise exception 'FAIL 83c: denetim kaydı yok ya da eksik (hesaplanan / sonradan)';
end if;
if (select count(*) from public.notifications
     where profile_id = u_yonetici and tur::text = 'UCRETSIZ_CIKIS'
       and link = '/gise/bilet/' || v_bilet
       and govde like '%' || v_txt || '%' and govde like '%ZZ83SON1%') <> 1 then
  raise exception 'FAIL 83c: Yönetici''ye Personel''in adıyla tek bildirim gitmedi';
end if;

-- (d) İkinci kez verilemez.
perform pg_temp.login(u_personel);
begin
  perform public.bilet_ucretsiz_cikis(v_bilet, 'DIGER', 'Tekrar');
  raise exception 'FAIL 83d: ikinci kez sonradan ücretsiz verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%zaten ücretsiz%' then
    raise exception 'FAIL 83d: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (e) Ödemesi alınmış kapalı bilet ücretsiz yapılamaz; ödeme yerinde kalır.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ83SON2', now() - interval '3 hours', v_tarife_yeni, 'ACIK')
returning id into v_bilet2;
perform pg_temp.login(u_personel);
perform * from public.bilet_kapat(v_bilet2, 'NAKIT');
begin
  perform public.bilet_ucretsiz_cikis(v_bilet2, 'FIYAT_SORDU', 'Fiyat sordu');
  raise exception 'FAIL 83e: ödenmiş bilete sonradan ücretsiz verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%ödeme%' then
    raise exception 'FAIL 83e: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet2 and ucret_kurus = 5000 and tahsil_kurus = 5000
                  and ucretsiz_sebep is null)
   or (select count(*) from public.tahsilatlar
        where bilet_id = v_bilet2 and iptal_of is null and tutar_kurus = 5000) <> 1 then
  raise exception 'FAIL 83e: reddedilen deneme ödenmiş bileti değiştirdi';
end if;

-- (f) Koruma dar kalır: bayraksız ücret değişmez; bayrakla bile tahsil değişmez.
begin
  update public.biletler set ucret_kurus = 0 where id = v_bilet2;
  raise exception 'FAIL 83f: kapanmış biletin ücreti bayraksız değişti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Kapanmış bilet değiştirilemez%' then
    raise exception 'FAIL 83f: beklenmeyen hata (bayraksız): %', sqlerrm;
  end if;
end;
begin
  perform set_config('app.bilet_ucretsiz', v_bilet2::text, true);
  update public.biletler set tahsil_kurus = 1 where id = v_bilet2;
  raise exception 'FAIL 83f: app.bilet_ucretsiz tahsil tutarını değiştirtti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Kapanmış bilet değiştirilemez%' then
    raise exception 'FAIL 83f: beklenmeyen hata (bayraklı): %', sqlerrm;
  end if;
end;
perform set_config('app.bilet_ucretsiz', '', true);

-- (g) Açık bilet yolu (065) da vereni ve zamanı yazar; geçmiş satırlar dolduruldu.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
values (gen_random_uuid(), 'ZZ83SON3', now() - interval '3 hours', v_tarife_yeni, 'ACIK')
returning id into v_id;
perform pg_temp.login(u_personel);
perform public.bilet_ucretsiz_cikis(v_id, 'ACIL', 'Ambulans');
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_id and durum = 'KAPALI'
                  and ucretsiz_by = u_personel and ucretsiz_at = cikis_at) then
  raise exception 'FAIL 83g: açık bilet yolu vereni/zamanı yazmadı';
end if;
-- Zaman hiç boşalmaz; veren, profili silinirse (on delete set null) boşalabilir.
if exists (select 1 from public.biletler
            where ucretsiz_sebep is not null and ucretsiz_at is null) then
  raise exception 'FAIL 83g: zamanı boş ücretsiz çıkış var (geçmiş doldurulmadı)';
end if;

-- (h) "Araç çıkmadı" dört sütunu da düşürür.
perform pg_temp.login(u_yonetici);
perform public.bilet_cikis_geri_al(v_bilet, 'Araç içeride');
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'ACIK'
                  and ucretsiz_sebep is null and ucretsiz_not is null
                  and ucretsiz_by is null and ucretsiz_at is null) then
  raise exception 'FAIL 83h: geri açılan sonradan ücretsizin izleri kaldı';
end if;

raise notice 'PASS 83: borçlu kapanmış bilete sonradan ücretsiz çıkış — tahsil yetkisiyle, para yazılmaz, koruma dar; veren ve zaman yazılır';

-- =====================================================================
-- 84  Personel'in Çıkanlar penceresi (067): son 3 İstanbul günü
-- =====================================================================
-- Sahip (2026-11-15): Personel "Bugün" ve "3 gün" görür, daha geriyi görmez.
-- Sınır Postgres'te (biletler_select). Yalnızca OKUMA genişler; tahsil,
-- ücretsiz çıkış, geri alma kendi vardiyasında kalır (75m, sahibin seçimi).
-- Pencere başı: bugünden 2 gün önce, 00:00 İstanbul.

v_ts := ((now() at time zone 'Europe/Istanbul')::date - 2)::timestamp
          at time zone 'Europe/Istanbul';

-- Vardiyasız kapanmış (kamera, açık vardiya yokken) biletler: pencere içi,
-- pencere dışı, pencere içi ama iptal.
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum, cikis_kaynak)
values (gen_random_uuid(), 'ZZ84PNC1', v_ts - interval '59 minutes', v_ts + interval '1 minute',
        v_tarife_yeni, 'KAPALI', 'KAMERA')
returning id into v_bilet;
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum, cikis_kaynak)
values (gen_random_uuid(), 'ZZ84PNC2', v_ts - interval '61 minutes', v_ts - interval '1 minute',
        v_tarife_yeni, 'KAPALI', 'KAMERA')
returning id into v_bilet2;
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum,
                             iptal_sebep, iptal_at)
values (gen_random_uuid(), 'ZZ84PNC3', v_ts - interval '59 minutes', v_ts + interval '1 minute',
        v_tarife_yeni, 'IPTAL', 'Deneme', v_ts + interval '1 minute')
returning id into v_id;

-- (a) Personel: pencere içindeki kapalı bileti görür; dışını ve iptali görmez.
perform pg_temp.login(u_personel);
if not exists (select 1 from public.biletler where id = v_bilet) then
  raise exception 'FAIL 84a: Personel 3 günlük penceredeki çıkışı göremiyor';
end if;
if exists (select 1 from public.biletler where id = v_bilet2) then
  raise exception 'FAIL 84a: Personel 3 günden eski çıkışı görüyor';
end if;
if exists (select 1 from public.biletler where id = v_id) then
  raise exception 'FAIL 84a: Personel başka vardiyanın iptal biletini görüyor';
end if;
perform pg_temp.logout();

-- (b) PENDING hiçbirini görmez; Yönetici üçünü de görür.
perform pg_temp.login(u_pending);
select count(*) into v_n from public.biletler where id in (v_bilet, v_bilet2, v_id);
perform pg_temp.logout();
if v_n <> 0 then
  raise exception 'FAIL 84b: PENDING penceredeki biletleri görüyor (%)', v_n;
end if;
perform pg_temp.login(u_yonetici);
select count(*) into v_n from public.biletler where id in (v_bilet, v_bilet2, v_id);
perform pg_temp.logout();
if v_n <> 3 then
  raise exception 'FAIL 84b: Yönetici tüm biletleri göremiyor (% / 3)', v_n;
end if;

-- (c) Yalnızca okuma genişler: başka vardiyanın (burada vardiyasız) biletini
--     Personel ne tahsil eder ne ücretsiz yapar. İki fonksiyonda da vardiya
--     denetimi borç denetiminden önce (034, 066): 0 ₺'lik bilet yeter.
perform pg_temp.login(u_personel);
if public.acik_vardiyam() is null then
  perform public.vardiya_ac(0);
end if;
v_vardiya := public.acik_vardiyam();
begin
  perform public.bilet_tahsil(v_bilet, 'NAKIT');
  raise exception 'FAIL 84c: Personel penceredeki başka vardiya biletini tahsil etti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%yetkiniz yok%' then
    raise exception 'FAIL 84c: beklenmeyen hata (tahsil): %', sqlerrm;
  end if;
end;
begin
  perform public.bilet_ucretsiz_cikis(v_bilet, 'DIGER', 'Deneme');
  raise exception 'FAIL 84c: Personel penceredeki başka vardiya biletine ücretsiz verdi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%yetkiniz yok%' then
    raise exception 'FAIL 84c: beklenmeyen hata (ücretsiz): %', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- (d) Kendi açık vardiyasının bileti, ne kadar eski olursa olsun, görünür kalır.
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum,
                             cikis_kaynak, kapatan_vardiya_id)
values (gen_random_uuid(), 'ZZ84PNC4', v_ts - interval '10 days 1 hour', v_ts - interval '10 days',
        v_tarife_yeni, 'KAPALI', 'MOBIL', v_vardiya)
returning id into v_id2;
perform pg_temp.login(u_personel);
if not exists (select 1 from public.biletler where id = v_id2) then
  raise exception 'FAIL 84d: Personel kendi vardiyasının eski biletini göremiyor';
end if;
perform pg_temp.logout();

raise notice 'PASS 84: Personel kapanmış çıkışları son 3 İstanbul gününde okur, daha eskisini görmez; işlem yine kendi vardiyasında';

-- =====================================================================
-- 85  Abonmanı kim ekledi (sahip 2026-11-15)
-- =====================================================================
-- Abonman listesi ve detayı "Ekleyen: Ad" gösterir. Veri 062'den beri var:
-- abonman_ekle `olusturan = auth.uid()` yazar. Burada sabitlenir: Personel
-- (ilk ödemeyle) ve Yönetici (0 ₺) eklediğinde ekleyen doğru kişi, ve
-- Personel o sütunu okuyabiliyor (ekran Personel'e de gösterir).

perform pg_temp.login(u_personel);
if public.acik_vardiyam() is null then
  perform public.vardiya_ac(0);
end if;
v_id := public.abonman_ekle('ZZ85ABN1', 'zz85 bir', null, 70000, 3, null, null, 70000, 'NAKIT');
perform pg_temp.logout();

perform pg_temp.login(u_yonetici);
v_id2 := public.abonman_ekle('ZZ85ABN2', 'zz85 iki', null, 60000, 4, null, null, 0, null);
perform pg_temp.logout();

-- (a) Ekleyen, ekleyen kişidir.
if not exists (select 1 from public.abonmanlar where id = v_id and olusturan = u_personel) then
  raise exception 'FAIL 85a: Personelin eklediği abonmanda ekleyen yazılmadı';
end if;
if not exists (select 1 from public.abonmanlar where id = v_id2 and olusturan = u_yonetici) then
  raise exception 'FAIL 85a: Yöneticinin eklediği abonmanda ekleyen yazılmadı';
end if;

-- (b) Personel ikisinin de ekleyenini okur (liste herkese açık, 062).
perform pg_temp.login(u_personel);
select count(*) into v_n from public.abonmanlar
 where (id = v_id and olusturan = u_personel)
    or (id = v_id2 and olusturan = u_yonetici);
perform pg_temp.logout();
if v_n <> 2 then
  raise exception 'FAIL 85b: Personel abonmanı ekleyeni okuyamıyor (% / 2)', v_n;
end if;

raise notice 'PASS 85: abonmanı ekleyen kişi yazılır (Personel ve Yönetici) ve listede okunur';

-- =====================================================================
-- 86  Tek kapı: giriş süresi 3 → 2 dakika, elle yazılan bilette de (068)
-- =====================================================================
-- Sahip (2026-11-15), sahada 35 KV 044: bilet personelce yazıldıktan 3 dakika
-- dolmadan araç çıktı, köprü "çıktı" dedi ama 1a "az önce girdi" diye yok
-- saydı. Kural: giriş süresi (Girişten sonra) alt sınırı ve varsayılanı 2;
-- kameranın açtığı ve elle yazılan bilet AYNI 2 dakikaya tabidir — elle
-- yazılan bilete istisna yok (sahibin kararı). kamera_tek_kapi değişmedi:
-- süreyi ayardan okur.

-- (a) Ayar: 2 kabul edilir, 1 reddedilir, varsayılan 2.
perform pg_temp.logout();
update public.otopark_ayarlari
   set tek_kapi_giris_yoksay_dk = 2, kamera_gecikme_limiti_dk = 720
 where id = 1;
begin
  update public.otopark_ayarlari set tek_kapi_giris_yoksay_dk = 1 where id = 1;
  raise exception 'FAIL 86a: giriş yok sayma süresi 1 dakikaya indi';
exception when check_violation then
  null;
end;
if (select column_default from information_schema.columns
     where table_schema = 'public' and table_name = 'otopark_ayarlari'
       and column_name = 'tek_kapi_giris_yoksay_dk') is distinct from '2' then
  raise exception 'FAIL 86a: giriş yok sayma süresinin varsayılanı 2 değil';
end if;

if exists (select 1 from public.biletler b,
                  unnest(array['ZZ86ELL01', 'ZZ86KAM02']) as p(plaka)
            where b.plaka = p.plaka or public.plaka_yakin(b.plaka, p.plaka)) then
  raise exception 'FAIL 86: fixture — ZZ86 plakalarından birine eşit ya da bir karakter yakın bilet var';
end if;

-- Ziyaretin başı: 10 dakika önce. Olaylar o ana göre saatli gelir (048).
v_ts := now() - interval '10 minutes';

-- (b) ELLE yazılmış bilet: 1 dk sonraki "çıktı" yok sayılır (istisna yok),
--     2,5 dk sonraki kapatır (3 dakikayken yok sayılırdı).
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum, giris_kaynak, created_at)
values (gen_random_uuid(), 'ZZ86ELL01', v_ts, v_tarife_yeni, 'ACIK', 'MOBIL', v_ts)
returning id into v_bilet;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ86ELL01', gen_random_uuid(), v_ts + interval '1 minute',
                              null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'YENI_GIRIS'
   or not exists (select 1 from public.biletler where id = v_bilet and durum = 'ACIK') then
  raise exception 'FAIL 86b: elle yazılan bilet 2 dakika dolmadan kapandı (%)', v_json;
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ86ELL01', gen_random_uuid(), v_ts + interval '150 seconds',
                              null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'CIKIS' or (v_json ->> 'bilet_id')::uuid is distinct from v_bilet then
  raise exception 'FAIL 86b: elle yazılan bilet 2,5 dakikada çıkışla kapanmadı (%)', v_json;
end if;
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'KAPALI' and cikis_kaynak = 'KAMERA'
                  and tahsil_kurus = 0) then
  raise exception 'FAIL 86b: elle yazılan bilet kamera çıkışıyla ödemesiz kapanmadı';
end if;

-- (c) KAMERANIN açtığı bilet, ipucusuz: aynı 2 dakika.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ86KAM02', gen_random_uuid(), v_ts) into v_json;
perform pg_temp.logout();
v_id := (v_json ->> 'bilet_id')::uuid;
if v_json ->> 'karar' is distinct from 'GIRIS' or v_id is null then
  raise exception 'FAIL 86c: hazırlık bileti açılmadı (%)', v_json;
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ86KAM02', gen_random_uuid(), v_ts + interval '1 minute') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'YENI_GIRIS'
   or not exists (select 1 from public.biletler where id = v_id and durum = 'ACIK') then
  raise exception 'FAIL 86c: kamera bileti 2 dakika dolmadan kapandı (%)', v_json;
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ86KAM02', gen_random_uuid(), v_ts + interval '150 seconds') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'CIKIS' or (v_json ->> 'bilet_id')::uuid is distinct from v_id
   or not exists (select 1 from public.biletler where id = v_id and durum = 'KAPALI') then
  raise exception 'FAIL 86c: kamera bileti 2,5 dakikada çıkışla kapanmadı (%)', v_json;
end if;

raise notice 'PASS 86: giriş süresi 2 dakika (alt sınır 2), elle yazılan ve kameranın açtığı bilette aynı';

-- 87  Tek kapı: tahmin kartı, aracı sonra okunup işlenince kendiliğinden kapanır (069)
-- =====================================================================
-- Sahada 17.11 (35 CJE 033): köprü aynı aracın bir parçasını emin olmadan
-- okudu (tahmin kartı), sonra aracı emin okudu. Köprü 1.4.3'te tahmin emin
-- plakayı artık engellemez; emin okuma bileti açar ya da kapatır. Kural
-- (069): o karar GIRIS ya da CIKIS ise, son giriş süresi (Girişten sonra)
-- içindeki, tahmini plakayla BİREBİR aynı, çözülmemiş, plakasız tek kapı
-- OKUNAMADI kartı sistemce kapanır (041'in notuyla, cozuldu_by boş).
-- Bir karakter uzak tahmin, eski kart, insanın çözdüğü kart DOKUNULMAZ.
perform pg_temp.logout();
update public.otopark_ayarlari
   set tek_kapi_giris_yoksay_dk = 2, kamera_gecikme_limiti_dk = 720
 where id = 1;
if exists (select 1 from public.biletler b,
                  unnest(array['ZZ87AA101', 'ZZ87BB102', 'ZZ87CC103', 'ZZ87DD104',
                               'ZZ87EE105', 'ZZ87FF106', 'ZZ87GG107']) as p(plaka)
            where b.plaka = p.plaka or public.plaka_yakin(b.plaka, p.plaka)) then
  raise exception 'FAIL 87: fixture — ZZ87 plakalarından birine eşit ya da bir karakter yakın bilet var';
end if;

-- (a) Birebir tahmin + emin okuma → GIRIS: kart kapanır.
perform pg_temp.kamera();
select public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '30 seconds',
                               'ZZ87AA101', 0.6, null) into v_id;
select public.kamera_tek_kapi('ZZ87AA101', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' then
  raise exception 'FAIL 87a: emin okuma bilet açmadı (%)', v_json;
end if;
if not exists (select 1 from public.istisnalar
                where id = v_id and cozuldu_at is not null and cozuldu_by is null
                  and cozum_notu = 'Kamera yeniden denedi ve okudu: ZZ87AA101 → GIRIS (YENI_ARAC)') then
  raise exception 'FAIL 87a: birebir tahmin kartı kendiliğinden kapanmadı';
end if;

-- (b) Bir karakter uzak tahmin: belki başka araç — kart AÇIK kalır.
perform pg_temp.kamera();
select public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '30 seconds',
                               'ZZ87BB1O2', 0.6, null) into v_id;
select public.kamera_tek_kapi('ZZ87BB102', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' then
  raise exception 'FAIL 87b: emin okuma bilet açmadı (%)', v_json;
end if;
if exists (select 1 from public.istisnalar where id = v_id and cozuldu_at is not null) then
  raise exception 'FAIL 87b: bir karakter uzak tahmin kartı kapandı';
end if;

-- (c) Eski kart (giriş süresinden önce): başka ziyaret — AÇIK kalır.
perform pg_temp.kamera();
select public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '10 minutes',
                               'ZZ87CC103', 0.6, null) into v_id;
select public.kamera_tek_kapi('ZZ87CC103', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' then
  raise exception 'FAIL 87c: emin okuma bilet açmadı (%)', v_json;
end if;
if exists (select 1 from public.istisnalar where id = v_id and cozuldu_at is not null) then
  raise exception 'FAIL 87c: 10 dakika önceki tahmin kartı kapandı';
end if;

-- (d) İnsanın çözdüğü kart: kararı ve notu ezilmez.
perform pg_temp.kamera();
select public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '30 seconds',
                               'ZZ87DD104', 0.6, null) into v_id;
perform pg_temp.logout();
v_ts := now() - interval '5 seconds';
update public.istisnalar
   set cozuldu_by = u_yonetici, cozuldu_at = v_ts, cozum_notu = 'ZZ87 elle'
 where id = v_id;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ87DD104', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if not exists (select 1 from public.istisnalar
                where id = v_id and cozuldu_by = u_yonetici and cozuldu_at = v_ts
                  and cozum_notu = 'ZZ87 elle') then
  raise exception 'FAIL 87d: insanın çözdüğü kart değişti';
end if;

-- (e) Çıkış da: açık bileti olan araç, tahmin kartı, sonra emin "çıktı".
v_ts := now() - interval '10 minutes';
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum, giris_kaynak, created_at)
values (gen_random_uuid(), 'ZZ87EE105', v_ts, v_tarife_yeni, 'ACIK', 'MOBIL', v_ts)
returning id into v_bilet;
perform pg_temp.kamera();
select public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '20 seconds',
                               'ZZ87EE105', 0.6, null) into v_id;
select public.kamera_tek_kapi('ZZ87EE105', gen_random_uuid(), now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'CIKIS' or (v_json ->> 'bilet_id')::uuid is distinct from v_bilet then
  raise exception 'FAIL 87e: emin "çıktı" bileti kapatmadı (%)', v_json;
end if;
if not exists (select 1 from public.istisnalar
                where id = v_id and cozuldu_at is not null and cozuldu_by is null
                  and cozum_notu = 'Kamera yeniden denedi ve okudu: ZZ87EE105 → CIKIS (ACIK_BILET)') then
  raise exception 'FAIL 87e: çıkışta birebir tahmin kartı kendiliğinden kapanmadı';
end if;

-- (f) 1c: "yön bilinmiyor" işaretli emin plaka bileti açarsa denetim kaydı
--     yazılır (karne sayar); işaretsiz olay yazmaz; karar değişmez.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ87FF106', gen_random_uuid(), now(), null,
                              '{"yon_bilinmiyor": true}'::jsonb) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' or v_json ->> 'sebep' is distinct from 'YENI_ARAC' then
  raise exception 'FAIL 87f: yönü bilinmeyen emin plaka bilet açmadı (%)', v_json;
end if;
if not exists (select 1 from public.audit_log
                where action = 'kamera_yon_bilinmiyor' and tablo = 'biletler'
                  and row_id = (v_json ->> 'bilet_id')::uuid
                  and detay ->> 'karar' = 'GIRIS') then
  raise exception 'FAIL 87f: yönü bilinmeyen olay denetim kaydına yazılmadı';
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ87GG107', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if exists (select 1 from public.audit_log
            where action = 'kamera_yon_bilinmiyor'
              and row_id = (v_json ->> 'bilet_id')::uuid) then
  raise exception 'FAIL 87f: işaretsiz olay da yön bilinmiyor diye yazıldı';
end if;

raise notice 'PASS 87: tahmin kartı, aynı plaka emin okunup bilet açılınca / kapanınca kendiliğinden kapanır; yönü bilinmeyen emin plaka denetim kaydında';


-- 88  Kamera sağlığı: kalpteki sayılar, personel şeridi, Yönetici karnesi (070)
-- =====================================================================
-- Plan 2026-11-17 adım 2 (sahibin onayı). Köprü 1.4.3 kalp atışına sayılar
-- koyar (sürüm, kare/sn, kuyruk, en eski bekleyen, izleme…); webhook bunları
-- kamera_kalp_bilgi ile yazar (yalnızca service_role — PASS 41 listesinde).
-- kamera_durum_ozet: yalnızca Yönetici okur (sahip 2026-11-18: şerit
-- Yöneticiye; önce bütün personeldi), yalnızca TAMAM / HABER_YOK /
-- REDDEDILIYOR / KUYRUK_TAKILDI / IZLEME_KAPANDI; Personel, PENDING ve anon
-- hiçbir şey.
-- kamera_karne:
-- yalnızca Yönetici, Istanbul günü başına. Testler canlı veritabanında koşar:
-- sağlık durumu test içinde kurulur (geri alınır), sayılar fark olarak okunur.

-- (a) Yetkiler.
foreach v_txt in array array['public.kamera_durum_ozet()', 'public.kamera_karne(integer)'] loop
  if has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('service_role', v_txt, 'execute')
     or not has_function_privilege('authenticated', v_txt, 'execute') then
    raise exception 'FAIL 88a: % yetkileri yanlış', v_txt;
  end if;
end loop;
if has_function_privilege('anon', 'public.kamera_kalp_bilgi(uuid, jsonb)', 'execute')
   or has_function_privilege('authenticated', 'public.kamera_kalp_bilgi(uuid, jsonb)', 'execute')
   or not has_function_privilege('service_role', 'public.kamera_kalp_bilgi(uuid, jsonb)', 'execute') then
  raise exception 'FAIL 88a: kamera_kalp_bilgi yalnızca service_role olmalı';
end if;

-- (b) Kalp bilgisi: tanınan anahtarlar, doğru türde, sınırlı uzunlukta
--     saklanır; gerisi atılır. JWT taşıyan çağıran reddedilir.
perform pg_temp.logout();
-- 073: kapalı kamera KAPALI döner ve uyarı üretmez; bu bölüm AÇIK kamerayı sınar.
update public.otopark_ayarlari set kamera_aktif = true, kamera_kalp_atisi = now(), kamera_kalp_esik_dk = 15 where id = 1;
update public.kamera_cihazlari set son_gorulme = now() where aktif and son_gorulme is not null;
-- Canlı eşleştirilmiş kameraların kalp bilgisi bu testin durumunu bozmasın
-- (taze bilgi yalnızca test kaynağından; geri alınır).
update public.kamera_saglik set zaman = now() - interval '1 day' where kaynak <> 'genel';
perform pg_temp.kamera();
perform public.kamera_kalp_bilgi(null, jsonb_build_object(
  'surum', '1.4.3', 'fps', 8.6, 'kuyruk', 0, 'kuyruk_en_eski_sn', 0, 'takip', 'acik',
  'bilinmeyen', 'x', 'kume', repeat('k', 500)));
perform pg_temp.logout();
select bilgi into v_json from public.kamera_saglik where kaynak = 'genel';
if v_json ->> 'surum' is distinct from '1.4.3' or (v_json ->> 'fps')::numeric <> 8.6
   or v_json ? 'bilinmeyen' or v_json ? 'kume' then
  raise exception 'FAIL 88b: kalp bilgisi süzülmeden saklandı (%)', v_json;
end if;
perform pg_temp.login(u_yonetici);
begin
  perform public.kamera_kalp_bilgi(null, '{}'::jsonb);
  raise exception 'FAIL 88b: oturumlu kullanıcı kalp bilgisi yazabildi';
exception when insufficient_privilege then null;
end;
perform pg_temp.logout();

-- (c) Yönetici şeridi: TAMAM; kuyruk 5 dakikadır takılı → KUYRUK_TAKILDI;
--     izleme kapandı → IZLEME_KAPANDI; haber yok en önce gelir.
perform pg_temp.login(u_yonetici);
select public.kamera_durum_ozet() into v_json;
perform pg_temp.logout();
if v_json ->> 'durum' is distinct from 'TAMAM' then
  raise exception 'FAIL 88c: sağlıklı kamera TAMAM değil (%)', v_json;
end if;
perform pg_temp.kamera();
perform public.kamera_kalp_bilgi(null, '{"kuyruk": 4, "kuyruk_en_eski_sn": 600, "takip": "acik"}');
perform pg_temp.logout();
-- Yönetici uyarısı (test Yöneticisi dahil herkese) bir kez; saat dolmadan
-- gelen ikinci kalp yenisini yazmaz.
if not exists (select 1 from public.notifications
                where tur = 'KAMERA' and link = '/yonetim/kameralar?saglik=kuyruk'
                  and profile_id = u_yonetici)
   and not exists (select 1 from public.notifications          -- canlı: son saatte zaten vardı
                    where tur = 'KAMERA' and link = '/yonetim/kameralar?saglik=kuyruk'
                      and created_at < now() and created_at > now() - interval '60 minutes') then
  raise exception 'FAIL 88c: takılı kuyruk Yöneticiye bildirilmedi';
end if;
select count(*) into v_n from public.notifications
 where tur = 'KAMERA' and link = '/yonetim/kameralar?saglik=kuyruk';
perform pg_temp.kamera();
perform public.kamera_kalp_bilgi(null, '{"kuyruk": 5, "kuyruk_en_eski_sn": 900, "takip": "acik"}');
perform pg_temp.logout();
if (select count(*) from public.notifications
     where tur = 'KAMERA' and link = '/yonetim/kameralar?saglik=kuyruk') <> v_n then
  raise exception 'FAIL 88c: takılı kuyruk uyarısı saat dolmadan tekrarlandı';
end if;
perform pg_temp.login(u_yonetici);
select public.kamera_durum_ozet() into v_json;
perform pg_temp.logout();
if v_json ->> 'durum' is distinct from 'KUYRUK_TAKILDI' then
  raise exception 'FAIL 88c: takılı kuyruk görünmedi (%)', v_json;
end if;
perform pg_temp.kamera();
perform public.kamera_kalp_bilgi(null, '{"kuyruk": 0, "kuyruk_en_eski_sn": 0, "takip": "kapandi"}');
perform pg_temp.logout();
perform pg_temp.login(u_yonetici);
select public.kamera_durum_ozet() into v_json;
perform pg_temp.logout();
if v_json ->> 'durum' is distinct from 'IZLEME_KAPANDI' then
  raise exception 'FAIL 88c: kapanan izleme görünmedi (%)', v_json;
end if;
-- Köprü son bir saatte araç attı (şerit uyuşmazlığı, bozuk gövde): kuyruktan
-- ve izlemeden önce gelir, Yönetici uyarılır.
perform pg_temp.kamera();
perform public.kamera_kalp_bilgi(null, '{"kuyruk": 4, "kuyruk_en_eski_sn": 600, "takip": "kapandi", "reddedilen": 2}');
perform pg_temp.logout();
perform pg_temp.login(u_yonetici);
select public.kamera_durum_ozet() into v_json;
perform pg_temp.logout();
if v_json ->> 'durum' is distinct from 'REDDEDILIYOR' then
  raise exception 'FAIL 88c: reddedilen araç görünmedi (%)', v_json;
end if;
if not exists (select 1 from public.notifications
                where tur = 'KAMERA' and link = '/yonetim/kameralar?saglik=ret'
                  and profile_id = u_yonetici)
   and not exists (select 1 from public.notifications
                    where tur = 'KAMERA' and link = '/yonetim/kameralar?saglik=ret'
                      and created_at < now() and created_at > now() - interval '60 minutes') then
  raise exception 'FAIL 88c: reddedilen araç Yöneticiye bildirilmedi';
end if;
update public.otopark_ayarlari set kamera_kalp_atisi = now() - interval '1 hour' where id = 1;
perform pg_temp.login(u_yonetici);
select public.kamera_durum_ozet() into v_json;
perform pg_temp.logout();
if v_json ->> 'durum' is distinct from 'HABER_YOK' then
  raise exception 'FAIL 88c: susan köprü HABER_YOK değil (%)', v_json;
end if;
update public.otopark_ayarlari set kamera_kalp_atisi = now() where id = 1;

-- (d) PENDING (rolsüz) kullanıcı hiçbir şey okuyamaz; karne yalnızca Yönetici.
perform pg_temp.login(u_pending);
begin
  perform public.kamera_durum_ozet();
  raise exception 'FAIL 88d: PENDING kullanıcı kamera durumunu okudu';
exception when insufficient_privilege then null;
end;
if exists (select 1 from public.kamera_saglik) then
  raise exception 'FAIL 88d: PENDING kullanıcı kamera_saglik satırı gördü';
end if;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
begin
  perform public.kamera_durum_ozet();
  raise exception 'FAIL 88d: Personel kamera durumunu okudu (şerit yalnızca Yöneticinin)';
exception when insufficient_privilege then null;
end;
begin
  perform public.kamera_karne(7);
  raise exception 'FAIL 88d: Personel karneyi okudu';
exception when insufficient_privilege then null;
end;
if exists (select 1 from public.kamera_saglik) then
  raise exception 'FAIL 88d: Personel kamera_saglik satırı gördü';
end if;
perform pg_temp.logout();

-- (e) Karne: bugünün kamera girişi ve kartı sayılır (fark olarak).
perform pg_temp.login(u_yonetici);
select public.kamera_karne(7) into v_json;
perform pg_temp.logout();
if jsonb_array_length(v_json) <> 7
   or v_json -> 0 ->> 'gun' is distinct from to_char(now() at time zone 'Europe/Istanbul', 'YYYY-MM-DD') then
  raise exception 'FAIL 88e: karne 7 gün, bugün başta değil (%)', v_json -> 0;
end if;
v_n := (v_json -> 0 ->> 'kamera_giris')::integer;
v_bilet := null;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ88KRN01', gen_random_uuid(), now()) into v_json;
perform public.kamera_okunamadi('ORTAK', gen_random_uuid(), now(), null, null, null);
perform pg_temp.logout();
perform pg_temp.login(u_yonetici);
select public.kamera_karne(7) into v_json2;
perform pg_temp.logout();
if (v_json2 -> 0 ->> 'kamera_giris')::integer <> v_n + 1 then
  raise exception 'FAIL 88e: kamera girişi karnede sayılmadı (%)', v_json2 -> 0;
end if;
if (v_json2 -> 0 ->> 'kart_plakasiz')::integer < 1 or (v_json2 -> 0 -> 'kart_tur' ->> 'OKUNAMADI')::integer < 1 then
  raise exception 'FAIL 88e: plakasız kart karnede yok (%)', v_json2 -> 0;
end if;
begin
  perform pg_temp.login(u_yonetici);
  perform public.kamera_karne(0);
  raise exception 'FAIL 88e: 0 günlük karne kabul edildi';
exception when raise_exception then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();

raise notice 'PASS 88: kalp sayıları süzülüp saklanır; Yönetici şeridi (Personel okuyamaz) TAMAM / HABER_YOK / REDDEDILIYOR / KUYRUK_TAKILDI / IZLEME_KAPANDI; karne yalnızca Yönetici';


-- 89  Sunucunun reddettiği kamera aracı kart olur (071)
-- =====================================================================
-- Plan 2026-11-17 adım 3 (sahibin cevabı: reddedilen araç personel kartı
-- olur). Eskiden bilet_ac / kamera_cikis_bildir / kamera_tek_kapi bir kamera
-- aracını reddedince webhook 409 dönüyor, köprü aracı siliyordu: geriye
-- yalnızca köprü günlüğünde bir satır kalıyordu. Artık webhook
-- kamera_reddedildi ile REDDEDILDI kartı yazar ve 200 döner. Yalnızca
-- service_role (PASS 41 listesinde). Aynı sebep saatte bir kez bildirilir:
-- eksik bir tarife her araçta telefonları çaldırmasın.

-- (a) Yetkiler.
if has_function_privilege('anon', 'public.kamera_reddedildi(text, uuid, timestamptz, text, text, jsonb)', 'execute')
   or has_function_privilege('authenticated', 'public.kamera_reddedildi(text, uuid, timestamptz, text, text, jsonb)', 'execute')
   or not has_function_privilege('service_role', 'public.kamera_reddedildi(text, uuid, timestamptz, text, text, jsonb)', 'execute') then
  raise exception 'FAIL 89a: kamera_reddedildi yalnızca service_role olmalı';
end if;

-- (b) Kart: tür, şerit, düzeltilmiş plaka, ret cümlesi, ham gövde korunur.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_reddedildi('GIRIS', v_islem, now(), 'zz89 aa101', 'PASS 89 deneme: sebep A',
                                '{"x": 1}'::jsonb) into v_bilet;
perform pg_temp.logout();
if not exists (select 1 from public.istisnalar i
                where i.id = v_bilet and i.tur::text = 'REDDEDILDI' and i.yon = 'GIRIS'
                  and i.plaka = 'ZZ89AA101' and i.kaynak = 'KAMERA' and i.islem_id = v_islem
                  and i.ham_yanit ->> 'ret_sebebi' = 'PASS 89 deneme: sebep A'
                  and i.ham_yanit ->> 'x' = '1' and i.cozuldu_at is null) then
  raise exception 'FAIL 89b: reddedilen araç kartı yanlış yazıldı';
end if;

-- (c) Aynı olay yeniden gelirse ikinci kart yok, aynı kimlik döner.
perform pg_temp.kamera();
select public.kamera_reddedildi('GIRIS', v_islem, now(), 'ZZ89AA101', 'PASS 89 deneme: sebep A', null) into v_txt;
perform pg_temp.logout();
if v_txt::uuid is distinct from v_bilet
   or (select count(*) from public.istisnalar where islem_id = v_islem) <> 1 then
  raise exception 'FAIL 89c: aynı olay ikinci kart yazdı';
end if;

-- (d) Bildirim: ilk araç herkese (ISTISNA personel türü); aynı sebeple saat
--     dolmadan gelen ikinci araç kart olur ama yeni bildirim yazmaz; başka
--     sebep yine bildirilir. Bildirim alacak kimse yoksa (canlıda tercih
--     kapalı) sayı kontrolü atlanır.
select count(*) into v_n from public.profiles p
 where p.rol is not null and p.durum = 'ACTIVE'
   and coalesce(p.notif_prefs ->> 'ISTISNA', 'true') <> 'false';
if v_n > 0 and not exists (select 1 from public.notifications
                            where tur = 'ISTISNA' and govde like '%ZZ89AA101%') then
  raise exception 'FAIL 89d: reddedilen araç bildirilmedi';
end if;
perform pg_temp.kamera();
perform public.kamera_reddedildi('CIKIS', gen_random_uuid(), now(), 'ZZ89BB102', 'PASS 89 deneme: sebep A', null);
perform public.kamera_reddedildi('ORTAK', gen_random_uuid(), now(), 'ZZ89CC103', 'PASS 89 deneme: sebep B', null);
perform pg_temp.logout();
if (select count(*) from public.istisnalar where plaka in ('ZZ89BB102', 'ZZ89CC103')
      and tur::text = 'REDDEDILDI') <> 2 then
  raise exception 'FAIL 89d: ikinci ve üçüncü reddedilen araç kart olmadı';
end if;
if exists (select 1 from public.notifications where tur = 'ISTISNA' and govde like '%ZZ89BB102%') then
  raise exception 'FAIL 89d: aynı sebep saat dolmadan yeniden bildirildi';
end if;
if v_n > 0 and not exists (select 1 from public.notifications
                            where tur = 'ISTISNA' and govde like '%ZZ89CC103%') then
  raise exception 'FAIL 89d: başka sebep bildirilmedi';
end if;

-- (e) Plakasız ret de kart olur; tanınmayan şerit ve islem_id'siz çağrı reddedilir.
perform pg_temp.kamera();
select public.kamera_reddedildi('GIRIS', gen_random_uuid(), now(), '', 'PASS 89 deneme: sebep C', null) into v_txt;
perform pg_temp.logout();
if not exists (select 1 from public.istisnalar where id = v_txt::uuid and plaka is null) then
  raise exception 'FAIL 89e: plakasız ret kart olmadı';
end if;
begin
  perform pg_temp.kamera();
  perform public.kamera_reddedildi('SAG', gen_random_uuid(), now(), 'ZZ89DD104', 'x', null);
  raise exception 'FAIL 89e: tanınmayan şerit kabul edildi';
exception when raise_exception then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform pg_temp.kamera();   -- üstteki blok geri alınınca rol de geri döndü
  perform public.kamera_reddedildi('GIRIS', null, now(), 'ZZ89DD104', 'x', null);
  raise exception 'FAIL 89e: islem_id olmadan kabul edildi';
exception when raise_exception then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();

-- (f) Oturumlu kullanıcı yazamaz; personel kartı görür, PENDING görmez.
perform pg_temp.login(u_yonetici);
begin
  perform public.kamera_reddedildi('GIRIS', gen_random_uuid(), now(), 'ZZ89EE105', 'x', null);
  raise exception 'FAIL 89f: oturumlu kullanıcı kart yazabildi';
exception when insufficient_privilege then null;
end;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
if not exists (select 1 from public.istisnalar where id = v_bilet) then
  raise exception 'FAIL 89f: personel reddedilen araç kartını görmüyor';
end if;
perform pg_temp.logout();
perform pg_temp.login(u_pending);
if exists (select 1 from public.istisnalar where id = v_bilet) then
  raise exception 'FAIL 89f: PENDING kullanıcı kartı gördü';
end if;
perform pg_temp.logout();

raise notice 'PASS 89: sunucunun reddettiği kamera aracı REDDEDILDI kartı olur; aynı sebep saatte bir bildirilir; yalnızca service_role';


-- =====================================================================
-- 90  Tek kapı: kameranın çıkış diye kapattığı araç içeride görülürse kart (072)
--     Sahip 2026-11-18: kamera bileti ÇIKIŞ diye kapattıktan sonra çıkış
--     süresi içinde (5 dk) aynı plaka (birebir) otoparkın İÇİNDE görülürse
--     CIKMAMIS_OLABILIR kartı yazılır; kart o bileti taşır (aday_bilet_ids)
--     ve personeli "Araç çıkmadı"ya götürür. Personelin kapattığı bilet,
--     kapanıştan önceki görülme, pencere dışı ve bir karakter uzak okuma
--     eskisi gibi. Bilet yeniden açılınca kart kendiliğinden kapanır.
--     now() bu transaction'da sabit: olay saatleri geri çekilerek kurulur.
-- =====================================================================
perform pg_temp.logout();

-- (a) Yeni tür ve kartı kapatan tetik; tetik işlevi hiçbir role açık değil.
if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                where t.typname = 'istisna_tur' and e.enumlabel = 'CIKMAMIS_OLABILIR') then
  raise exception 'FAIL 90a: istisna_tur CIKMAMIS_OLABILIR yok — 072 çalıştırılmadı';
end if;
if not exists (select 1 from pg_trigger
                where tgname = 'cikmamis_kart_kapat_tg' and tgrelid = 'public.biletler'::regclass) then
  raise exception 'FAIL 90a: cikmamis_kart_kapat_tg tetiği yok';
end if;
foreach v_txt in array array['anon', 'authenticated', 'service_role'] loop
  if has_function_privilege(v_txt, 'public.cikmamis_kart_kapat()', 'execute') then
    raise exception 'FAIL 90a: cikmamis_kart_kapat % rolüne açık', v_txt;
  end if;
end loop;

-- (b) Kamera girişi (30 dk önce) ve kamera çıkışı (2 dk önce).
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ90AA101', gen_random_uuid(), now() - interval '30 minutes') into v_json;
perform pg_temp.logout();
v_bilet := (v_json ->> 'bilet_id')::uuid;
if v_json ->> 'karar' is distinct from 'GIRIS' or v_bilet is null then
  raise exception 'FAIL 90b: hazırlık girişi açılmadı (%)', v_json;
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ90AA101', gen_random_uuid(), now() - interval '2 minutes',
                              null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'CIKIS'
   or not exists (select 1 from public.biletler where id = v_bilet and durum = 'KAPALI'
                                                 and cikis_kaynak::text = 'KAMERA') then
  raise exception 'FAIL 90b: hazırlık — kamera çıkışı kapatmadı (%)', v_json;
end if;

-- (c) Kapanıştan ÖNCE içeride görülmesi sinyal değil: eskisi gibi YENI_CIKIS.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ90AA101', gen_random_uuid(), now() - interval '3 minutes',
                              null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'YENI_CIKIS'
   or exists (select 1 from public.istisnalar where plaka = 'ZZ90AA101') then
  raise exception 'FAIL 90c: kapanıştan önceki görülme kart açtı (%)', v_json;
end if;

-- (d) Kapanıştan SONRA, pencere içinde içeride: kart, bileti taşır; bilet
--     kapalı kalır (kart yalnızca insana söyler).
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ90AA101', v_islem, now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'ISTISNA' or v_json ->> 'sebep' is distinct from 'CIKMAMIS_OLABILIR' then
  raise exception 'FAIL 90d: kameranın kapattığı araç içeride görülünce kart açılmadı (%)', v_json;
end if;
select id into v_id from public.istisnalar
 where islem_id = v_islem and tur::text = 'CIKMAMIS_OLABILIR' and yon = 'ORTAK'
   and kaynak::text = 'KAMERA' and plaka = 'ZZ90AA101' and aday_bilet_ids = array[v_bilet]
   and cozuldu_at is null;
if v_id is null then
  raise exception 'FAIL 90d: CIKMAMIS_OLABILIR kartı bileti taşımıyor';
end if;
if not exists (select 1 from public.biletler where id = v_bilet and durum = 'KAPALI') then
  raise exception 'FAIL 90d: kart bileti değiştirdi';
end if;

-- (e) Aynı araç yeniden görüldü: ikinci kart yok.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ90AA101', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'CIKMAMIS_KAYITLI'
   or (select count(*) from public.istisnalar where plaka = 'ZZ90AA101') <> 1 then
  raise exception 'FAIL 90e: ikinci CIKMAMIS_OLABILIR kartı açıldı (%)', v_json;
end if;

-- (f) Bir karakter uzak okuma: eskisi gibi YENI_CIKIS_BENZER, kart yok.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ90AA102', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'YENI_CIKIS_BENZER'
   or exists (select 1 from public.istisnalar where plaka = 'ZZ90AA102') then
  raise exception 'FAIL 90f: benzer okuma kart açtı (%)', v_json;
end if;

-- (g) Pencere dışı (kamera 10 dk önce kapattı): CIKMAMIS kartı yok; eskisi
--     gibi içeride bileti olmayan araç.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ90BB202', gen_random_uuid(), now() - interval '40 minutes') into v_json;
perform pg_temp.logout();
v_bilet2 := (v_json ->> 'bilet_id')::uuid;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ90BB202', gen_random_uuid(), now() - interval '10 minutes',
                              null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'CIKIS' then
  raise exception 'FAIL 90g: hazırlık — kamera çıkışı kapatmadı (%)', v_json;
end if;
-- 077 E2: yakındaki plakasız tek kapı kartları kapatılır (76g'deki gibi),
-- yoksa içeride okuma onlara bağlanır.
-- 090: içeride bileti olmayan araca bilet açılır (ICERIDE_GORULDU, PASS 143).
update public.istisnalar set cozuldu_at = now()
 where tur::text = 'OKUNAMADI' and yon = 'ORTAK' and cozuldu_at is null
   and kaynak_zaman > now() - interval '30 minutes';
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ90BB202', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'ICERIDE_GORULDU'
   or exists (select 1 from public.istisnalar
               where plaka = 'ZZ90BB202' and tur::text = 'CIKMAMIS_OLABILIR') then
  raise exception 'FAIL 90g: pencere dışında CIKMAMIS_OLABILIR kartı açıldı (%)', v_json;
end if;

-- (h) Personelin kapattığı bilet: ödeyip çıkan araç — eskisi gibi yok say.
perform pg_temp.login(u_yonetici);
if public.acik_vardiyam() is null then
  perform public.vardiya_ac(0);
end if;
select public.bilet_ac('ZZ90CC303', gen_random_uuid()) into v_id2;
perform public.bilet_kapat(v_id2, 'NAKIT', null, null, null, 'MOBIL');
perform pg_temp.logout();
if not exists (select 1 from public.biletler where id = v_id2 and durum = 'KAPALI'
                                              and cikis_kaynak::text = 'MOBIL') then
  raise exception 'FAIL 90h: hazırlık — personel kapanışı yapılamadı';
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ90CC303', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'YOKSAY' or v_json ->> 'sebep' is distinct from 'YENI_CIKIS'
   or exists (select 1 from public.istisnalar where plaka = 'ZZ90CC303') then
  raise exception 'FAIL 90h: personelin kapattığı bilet için kart açıldı (%)', v_json;
end if;

-- (i) Personel kartı görür, PENDING görmez.
perform pg_temp.login(u_personel);
if not exists (select 1 from public.istisnalar where id = v_id) then
  raise exception 'FAIL 90i: personel CIKMAMIS_OLABILIR kartını görmüyor';
end if;
perform pg_temp.logout();
perform pg_temp.login(u_pending);
if exists (select 1 from public.istisnalar where id = v_id) then
  raise exception 'FAIL 90i: PENDING kullanıcı kartı gördü';
end if;
perform pg_temp.logout();

-- (j) "Araç çıkmadı" (bilet_kamera_geri_ac): bilet açılır, kart kendiliğinden
--     kapanır — açanın adıyla.
perform pg_temp.login(u_yonetici);
perform public.bilet_kamera_geri_ac(v_bilet);
perform pg_temp.logout();
if not exists (select 1 from public.biletler where id = v_bilet and durum = 'ACIK') then
  raise exception 'FAIL 90j: hazırlık — bilet geri açılmadı';
end if;
if not exists (select 1 from public.istisnalar
                where id = v_id and cozuldu_at is not null and cozuldu_by = u_yonetici
                  and cozum_notu like '%Araç çıkmadı%') then
  raise exception 'FAIL 90j: bilet geri açılınca CIKMAMIS_OLABILIR kartı kapanmadı';
end if;

raise notice 'PASS 90: kameranın çıkış diye kapattığı araç 5 dk içinde içeride görülürse bileti taşıyan tek kart; personel kapanışı, önceki görülme, pencere dışı ve benzer okuma eskisi gibi; bilet geri açılınca kart kapanır';

-- =====================================================================
-- 91  Tek kapı "Çıkışta açık bilet bulunamadı" → Giriş aç, yazılan saatle (072)
--     Sahip 2026-11-17/18: tek kapıda açık bileti olmayan "çıkan" araç
--     aslında girmiş olabilir. Personel kamera kartından giriş açar; giriş
--     saatini YAZAR (kart saati ücreti yanlış hesaplar) ve sebep zorunlu —
--     bilet_giris_duzelt (046) gibi: ileri saat yok, bir yıldan eski yok,
--     denetim kaydı ve Yönetici bildirimi. Yalnızca tek kapı (ORTAK) kamera
--     kartı; çıkış şeridi, başka tür ve elle yazılmış kart reddedilir.
-- =====================================================================
perform pg_temp.logout();

-- (a) Yetkiler.
v_txt := 'public.istisna_bilet_ac_saatli(uuid, text, timestamptz, text)';
if to_regprocedure(v_txt) is null then
  raise exception 'FAIL 91a: istisna_bilet_ac_saatli yok — 072 çalıştırılmadı';
end if;
if has_function_privilege('anon', v_txt, 'execute')
   or has_function_privilege('service_role', v_txt, 'execute')
   or not has_function_privilege('authenticated', v_txt, 'execute') then
  raise exception 'FAIL 91a: istisna_bilet_ac_saatli yetkileri yanlış';
end if;

-- (b) Hazırlık: tek kapıda çıkan, açık bileti olmayan araç → kart.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ91KM101', v_islem, now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
select id into v_id from public.istisnalar
 where islem_id = v_islem and tur::text = 'ACIK_BILET_YOK' and yon = 'ORTAK' and cozuldu_at is null;
if v_id is null then
  raise exception 'FAIL 91b: hazırlık — ACIK_BILET_YOK (tek kapı) kartı yazılmadı (%)', v_json;
end if;

-- (c) Saat ya da sebep eksik / yanlış: reddedilir, bilet açılmaz, kart açık kalır.
foreach v_txt2 in array array['sebep', 'ileri', 'eski', 'bos'] loop
  perform pg_temp.login(u_personel);
  begin
    perform public.istisna_bilet_ac_saatli(
      v_id, 'ZZ91KM101',
      case v_txt2 when 'ileri' then now() + interval '1 hour'
                  when 'eski'  then now() - interval '2 years'
                  when 'bos'   then null
                  else now() - interval '2 hours' end,
      case v_txt2 when 'sebep' then '   ' else 'Araç girmiş, kamera çıkış sandı' end);
    raise exception 'FAIL 91c: % kabul edildi', v_txt2;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if (v_txt2 = 'sebep' and sqlerrm not like '%Sebep zorunludur%')
       or (v_txt2 = 'ileri' and sqlerrm not like '%ileri bir zaman%')
       or (v_txt2 = 'eski' and sqlerrm not like '%bir yıldan eski%')
       or (v_txt2 = 'bos' and sqlerrm not like '%Giriş saati boş%') then
      raise exception 'FAIL 91c: % için yanlış ret sebebi: %', v_txt2, sqlerrm;
    end if;
  end;
  perform pg_temp.logout();
end loop;
if exists (select 1 from public.biletler where plaka = 'ZZ91KM101')
   or not exists (select 1 from public.istisnalar where id = v_id and cozuldu_at is null) then
  raise exception 'FAIL 91c: reddedilen deneme iz bıraktı';
end if;

-- (d) PENDING kullanıcı açamaz.
perform pg_temp.login(u_pending);
begin
  perform public.istisna_bilet_ac_saatli(v_id, 'ZZ91KM101', now() - interval '2 hours', 'x');
  raise exception 'FAIL 91d: PENDING kullanıcı giriş açtı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();

-- (e) Personel: yazılan saatle bilet açılır, kart kapanır, sebep denetimde.
v_ts := date_trunc('minute', now()) - interval '2 hours';
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac_saatli(v_id, 'ZZ91KM101', v_ts, '  Araç girmiş, kamera çıkış sandı ')
  into v_json;
perform pg_temp.logout();
v_bilet := (v_json ->> 'bilet_id')::uuid;
if (v_json ->> 'zaten_vardi')::boolean is distinct from false
   or not exists (select 1 from public.biletler
                   where id = v_bilet and plaka = 'ZZ91KM101' and durum = 'ACIK'
                     and giris_at = v_ts and islem_id = v_islem
                     and giris_kaynak::text = 'MOBIL') then
  raise exception 'FAIL 91e: yazılan saatle giriş açılmadı (%)', v_json;
end if;
if not exists (select 1 from public.istisnalar
                where id = v_id and cozuldu_by = u_personel and cozuldu_at is not null) then
  raise exception 'FAIL 91e: kart kapanmadı';
end if;
if not exists (select 1 from public.audit_log
                where action = 'bilet_giris_duzeltildi' and row_id = v_bilet
                  and detay ->> 'sebep' = 'Araç girmiş, kamera çıkış sandı')
   or not exists (select 1 from public.audit_log
                   where action = 'istisna_bilet_acildi' and row_id = v_bilet) then
  raise exception 'FAIL 91e: denetim kaydı eksik';
end if;

-- (f) Aynı karta ikinci dokunuş: aynı bilet, ikinci bilet yok.
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac_saatli(v_id, 'ZZ91KM101', v_ts, 'x') into v_json;
perform pg_temp.logout();
if (v_json ->> 'zaten_vardi')::boolean is distinct from true
   or (v_json ->> 'bilet_id')::uuid is distinct from v_bilet
   or (select count(*) from public.biletler where plaka = 'ZZ91KM101') <> 1 then
  raise exception 'FAIL 91f: ikinci dokunuş ikinci bilet açtı (%)', v_json;
end if;

-- (g) Başka kartlardan açılmaz: çıkış şeridi, başka tür, elle yazılmış kart.
v_id2 := public.istisna_yaz('ACIK_BILET_YOK', 'CIKIS', 'ZZ91BB202', 'KAMERA', gen_random_uuid(),
                            null, null, now());
perform pg_temp.login(u_personel);
begin
  perform public.istisna_bilet_ac_saatli(v_id2, 'ZZ91BB202', now() - interval '1 hour', 'x');
  raise exception 'FAIL 91g: çıkış şeridi kartından giriş açıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Bu kayıttan giriş açılamaz%' then
    raise exception 'FAIL 91g: yanlış ret sebebi: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
v_id2 := public.istisna_yaz('ICERIDE_BILETSIZ', 'ORTAK', 'ZZ91CC303', 'KAMERA', gen_random_uuid(),
                            null, null, now());
perform pg_temp.login(u_personel);
begin
  perform public.istisna_bilet_ac_saatli(v_id2, 'ZZ91CC303', now() - interval '1 hour', 'x');
  raise exception 'FAIL 91g: başka türden kartla saatli giriş açıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Bu kayıttan giriş açılamaz%' then
    raise exception 'FAIL 91g: yanlış ret sebebi: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
v_id2 := public.istisna_yaz('ACIK_BILET_YOK', 'ORTAK', 'ZZ91DD404', 'MOBIL', gen_random_uuid(),
                            null, null, now());
perform pg_temp.login(u_personel);
begin
  perform public.istisna_bilet_ac_saatli(v_id2, 'ZZ91DD404', now() - interval '1 hour', 'x');
  raise exception 'FAIL 91g: elle yazılmış karttan giriş açıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Bu kayıttan giriş açılamaz%' then
    raise exception 'FAIL 91g: yanlış ret sebebi: %', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if exists (select 1 from public.biletler where plaka in ('ZZ91BB202', 'ZZ91CC303', 'ZZ91DD404')) then
  raise exception 'FAIL 91g: reddedilen kart bilet açtı';
end if;

raise notice 'PASS 91: tek kapı "açık bilet yok" kamera kartından giriş, personelin yazdığı saat ve zorunlu sebeple; ileri / çok eski / boş saat ve sebepsiz reddedilir; başka kartlardan açılmaz';

-- =====================================================================
-- 92  Kamera girişi kapalıyken sahte uyarı yok; cron geçmişi temizlenir;
--     iki dizin, bir kopya dizin gider (073)
--     Sahip 2026-11-20: kamera girişi Ayarlar'dan kapatıldığında kameranın
--     gördüğü araçlar ATILIR (webhook 410 döner; bu SQL'de değil,
--     tests/serit.check.mjs sınar). Kapalı kamera bilerek kapatılmıştır:
--     "haber yok", "kuyruk takıldı", "reddediyor" uyarıları ve şeritleri
--     yanlış alarmdır. Şerit KAPALI der. Durum test içinde kurulur ve
--     geri alınır; canlı ayar okunur, varsayılmaz.
-- =====================================================================
perform pg_temp.logout();
select kamera_aktif into v_bool from public.otopark_ayarlari where id = 1;

-- (a) Şerit: kapalıyken KAPALI ve HER ŞEYDEN önce (susan köprü dahil);
--     açılınca eski kural (burada HABER_YOK).
update public.otopark_ayarlari
   set kamera_aktif = false, kamera_kalp_atisi = now() - interval '1 hour', kamera_kalp_esik_dk = 15
 where id = 1;
perform pg_temp.login(u_yonetici);
select public.kamera_durum_ozet() into v_json;
perform pg_temp.logout();
if v_json ->> 'durum' is distinct from 'KAPALI' then
  raise exception 'FAIL 92a: kapalı kamera KAPALI değil (%)', v_json;
end if;
update public.otopark_ayarlari set kamera_aktif = true where id = 1;
perform pg_temp.login(u_yonetici);
select public.kamera_durum_ozet() into v_json;
perform pg_temp.logout();
if v_json ->> 'durum' is distinct from 'HABER_YOK' then
  raise exception 'FAIL 92a: açılan kamera eski kurala dönmedi (%)', v_json;
end if;

-- (b) Nöbetçi: susan köprü ve susan eşleştirilmiş kameralar; kapalıyken HİÇ
--     KAMERA uyarısı yok, açıkken genel uyarı gelir.
delete from public.notifications where tur = 'KAMERA';
update public.kamera_cihazlari
   set son_gorulme = now() - interval '1 day', durum_at = now() - interval '1 day'
 where aktif and son_gorulme is not null;
update public.otopark_ayarlari set kamera_aktif = false where id = 1;
perform public.run_kamera_kontrol();
if exists (select 1 from public.notifications where tur = 'KAMERA') then
  raise exception 'FAIL 92b: kapalı kamera için "haber yok" uyarısı yazıldı';
end if;
update public.otopark_ayarlari set kamera_aktif = true where id = 1;
perform public.run_kamera_kontrol();
if not exists (select 1 from public.notifications
                where tur = 'KAMERA' and link = '/yonetim/kameralar' and profile_id = u_yonetici) then
  raise exception 'FAIL 92b: açık ve susan köprü için uyarı yazılmadı';
end if;

-- (c) Kalp bilgisi kapalıyken saklanır ama uyarı üretmez (kuyruk, ret, izleme).
delete from public.notifications where tur = 'KAMERA';
update public.otopark_ayarlari set kamera_aktif = false, kamera_kalp_atisi = now() where id = 1;
perform pg_temp.kamera();
perform public.kamera_kalp_bilgi(null,
  '{"kuyruk": 4, "kuyruk_en_eski_sn": 600, "reddedilen": 2, "takip": "kapandi"}');
perform pg_temp.logout();
if exists (select 1 from public.notifications where tur = 'KAMERA') then
  raise exception 'FAIL 92c: kapalı kameranın kalbi uyarı üretti';
end if;
if (select (bilgi ->> 'kuyruk_en_eski_sn')::numeric from public.kamera_saglik where kaynak = 'genel')
     is distinct from 600 then
  raise exception 'FAIL 92c: kapalı kameranın kalp bilgisi saklanmadı';
end if;
update public.otopark_ayarlari set kamera_aktif = true where id = 1;
perform pg_temp.kamera();
perform public.kamera_kalp_bilgi(null,
  '{"kuyruk": 4, "kuyruk_en_eski_sn": 600, "reddedilen": 2, "takip": "kapandi"}');
perform pg_temp.logout();
if not exists (select 1 from public.notifications
                where tur = 'KAMERA' and link = '/yonetim/kameralar?saglik=kuyruk' and profile_id = u_yonetici) then
  raise exception 'FAIL 92c: açık kameranın takılı kuyruğu bildirilmedi';
end if;
update public.otopark_ayarlari set kamera_aktif = v_bool where id = 1;

-- (d) cron.job_run_details her gün temizlenir (7 günden eskisi). Supabase
--     bunu kendisi yapmaz; dakikalık iş günde ~1.440 satır ekler.
select command into v_txt from cron.job where jobname = 'otopark-cron-temizlik';
if v_txt is null then
  raise exception 'FAIL 92d: otopark-cron-temizlik işi yok — 073 çalıştırılmadı';
end if;
if position('delete from cron.job_run_details' in lower(v_txt)) = 0
   or position('7 days' in v_txt) = 0 then
  raise exception 'FAIL 92d: temizlik işinin komutu beklenen değil (%)', v_txt;
end if;

-- (e) En sık çalışan iki sorgunun dizini var; 067'nin kopya dizini gitti
--     (001'deki biletler_kapali_ix aynısıdır ve kalır).
if not exists (select 1 from pg_indexes where schemaname = 'public'
                and indexname = 'biletler_kamera_created_ix') then
  raise exception 'FAIL 92e: biletler_kamera_created_ix yok';
end if;
if not exists (select 1 from pg_indexes where schemaname = 'public'
                and indexname = 'notifications_tur_link_ix') then
  raise exception 'FAIL 92e: notifications_tur_link_ix yok';
end if;
if exists (select 1 from pg_indexes where schemaname = 'public'
            and indexname = 'biletler_kapali_cikis_ix') then
  raise exception 'FAIL 92e: kopya dizin biletler_kapali_cikis_ix duruyor';
end if;
if not exists (select 1 from pg_indexes where schemaname = 'public'
                and indexname = 'biletler_kapali_ix') then
  raise exception 'FAIL 92e: biletler_kapali_ix (asıl dizin) yok';
end if;

-- (f) Yetkiler değişmedi (create or replace yetkiyi korur; yine de sınanır).
if has_function_privilege('anon', 'public.kamera_durum_ozet()', 'execute')
   or has_function_privilege('service_role', 'public.kamera_durum_ozet()', 'execute')
   or not has_function_privilege('authenticated', 'public.kamera_durum_ozet()', 'execute') then
  raise exception 'FAIL 92f: kamera_durum_ozet yetkileri değişti';
end if;
if has_function_privilege('anon', 'public.kamera_kalp_bilgi(uuid, jsonb)', 'execute')
   or has_function_privilege('authenticated', 'public.kamera_kalp_bilgi(uuid, jsonb)', 'execute')
   or not has_function_privilege('service_role', 'public.kamera_kalp_bilgi(uuid, jsonb)', 'execute') then
  raise exception 'FAIL 92f: kamera_kalp_bilgi yetkileri değişti';
end if;
if has_function_privilege('anon', 'public.run_kamera_kontrol()', 'execute')
   or has_function_privilege('authenticated', 'public.run_kamera_kontrol()', 'execute') then
  raise exception 'FAIL 92f: run_kamera_kontrol dışarı açıldı';
end if;

raise notice 'PASS 92: kamera girişi kapalıyken şerit KAPALI, "haber yok" / kuyruk / ret uyarısı yok, kalp bilgisi saklanır; açılınca eski kural; cron geçmişi günlük temizlenir; iki dizin var, kopya dizin yok';

-- =====================================================================
-- 93  Aracın yakın planı (074)
--     Sahip 2026-11-20/21: kart fotoğrafında (bütün kırpıntı, 1280 px)
--     plaka personelce okunmuyor. Köprü 1.4.4 her olayda ikinci bir
--     fotoğraf da gönderir: aracın kutusu + %10, tam çözünürlükten
--     (`kamera/<islem_id>-yakin.jpg`). Sahne fotoğrafının yanına, aynı
--     kurallarla bağlanır:
--       · giris_yakin / cikis_yakin / istisnalar.yakin_path — her biri
--         eşinin (giris_foto / cikis_foto / foto_path) koşuluyla, yalnızca
--         boşken; yol yalnızca BU olayınki;
--       · kameranın kapattığı biletin cikis_yakin'i (054'teki bayrakla),
--         cikis_foto dolu olsa bile; başka kapanmış bilete yazılamaz;
--       · karttan açılan bilet (istisna_bilet_ac / _saatli) yakın planı da
--         taşır;
--       · gece işi üçünü de saklama süresi dolunca boşaltır, kapanmış
--         bilette hata vermeden.
--     Eski webhook (adlı 4 argüman) aynen çalışmalı: p_yakin varsayılan null.
--     GEÇİCİ (2026-11-23): 074 köprü 1.4.6 ile koşulur; o zamana kadar bu
--     blok atlanır (075 ondan önce koşulabilsin). 074 koşulunca bu "if"
--     kalkar.
-- =====================================================================
perform pg_temp.logout();

if to_regprocedure('public.kamera_foto_bagla(uuid, uuid, timestamptz, text, text)') is null then
  raise notice 'PASS 93 ATLANDI: 074 (yakın plan) henüz koşulmadı';
else

-- (a) Sütunlar ve imza.
if (select count(*) from information_schema.columns
     where table_schema = 'public'
       and ((table_name = 'biletler' and column_name in ('giris_yakin', 'cikis_yakin'))
         or (table_name = 'istisnalar' and column_name = 'yakin_path'))
       and data_type = 'text' and is_nullable = 'YES') <> 3 then
  raise exception 'FAIL 93a: yakın plan sütunları yok — 074 koşulmamış';
end if;
if to_regprocedure('public.kamera_foto_bagla(uuid, uuid, timestamptz, text)') is not null then
  raise exception 'FAIL 93a: eski 4 argümanlı kamera_foto_bagla duruyor (iki tanım)';
end if;
v_txt := 'public.kamera_foto_bagla(uuid, uuid, timestamptz, text, text)';
if to_regprocedure(v_txt) is null then
  raise exception 'FAIL 93a: 5 argümanlı kamera_foto_bagla yok';
end if;
if not has_function_privilege('service_role', v_txt, 'execute')
   or has_function_privilege('anon', v_txt, 'execute')
   or has_function_privilege('authenticated', v_txt, 'execute') then
  raise exception 'FAIL 93a: kamera_foto_bagla yetkileri yanlış';
end if;

v_liste := array['ZZ93GA101', 'ZZ93TM202', 'ZZ93CX303', 'ZZ93KP404', 'ZZ93IS505', 'ZZ93SA606'];
if exists (select 1 from public.biletler b, unnest(v_liste) as p(plaka)
            where b.plaka = p.plaka or public.plaka_yakin(b.plaka, p.plaka)) then
  raise exception 'FAIL 93: fixture — ZZ93 plakalarından birine eşit ya da bir karakter yakın bilet var';
end if;

-- (b) Yakın planın yolu yalnızca bu olayınki; yanlışsa çağrı hiçbir şey
--     yazmaz (sahne fotoğrafı da).
v_islem := gen_random_uuid();
v_txt2 := 'kamera/' || v_islem::text || '.jpg';
perform pg_temp.kamera();
select public.bilet_ac('ZZ93GA101', v_islem, 'KAMERA', now()) into v_bilet;
foreach v_txt in array array[
  'kamera/' || gen_random_uuid()::text || '-yakin.jpg',
  'kamera/' || upper(v_islem::text) || '-yakin.jpg',
  'kamera/' || v_islem::text || '-yakin.png',
  '../kamera/' || v_islem::text || '-yakin.jpg',
  'kamera/' || v_islem::text || '.jpg'
] loop
  begin
    perform public.kamera_foto_bagla(v_islem, v_bilet, now(), v_txt2, v_txt);
    raise exception 'FAIL 93b: olaya ait olmayan yakın plan yolu kabul edildi: %', v_txt;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end loop;
perform pg_temp.logout();
if (select giris_foto from public.biletler where id = v_bilet) is not null then
  raise exception 'FAIL 93b: reddedilen çağrı sahne fotoğrafını yazdı';
end if;

-- (c) Giriş: ikisi birlikte bağlanır; ikinci çağrı hiçbir şey değiştirmez.
v_txt3 := 'kamera/' || v_islem::text || '-yakin.jpg';
perform pg_temp.kamera();
select public.kamera_foto_bagla(v_islem, v_bilet, now(), v_txt2, v_txt3) into v_n;
select public.kamera_foto_bagla(v_islem, v_bilet, now(), v_txt2, v_txt3) into v_n2;
perform pg_temp.logout();
if v_n <> 2 or v_n2 <> 0
   or not exists (select 1 from public.biletler
                   where id = v_bilet and giris_foto = v_txt2 and giris_yakin = v_txt3
                     and cikis_foto is null and cikis_yakin is null) then
  raise exception 'FAIL 93c: girişte yakın plan bağlanmadı ya da ikinci çağrı değiştirdi (% / %)', v_n, v_n2;
end if;

-- (c2) Eski webhook (adlı 4 argüman, p_yakin yok) aynen çalışır; yakın plan
--      sonra gelirse yalnızca o boş sütuna yazılır.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.bilet_ac('ZZ93TM202', v_islem, 'KAMERA', now()) into v_id;
select public.kamera_foto_bagla(p_islem_id => v_islem, p_bilet_id => v_id, p_zaman => now(),
                                p_foto => 'kamera/' || v_islem::text || '.jpg') into v_n;
select public.kamera_foto_bagla(v_islem, v_id, now(), 'kamera/' || v_islem::text || '.jpg',
                                'kamera/' || v_islem::text || '-yakin.jpg') into v_n2;
perform pg_temp.logout();
if v_n <> 1 or v_n2 <> 1
   or not exists (select 1 from public.biletler
                   where id = v_id and giris_foto = 'kamera/' || v_islem::text || '.jpg'
                     and giris_yakin = 'kamera/' || v_islem::text || '-yakin.jpg') then
  raise exception 'FAIL 93c2: eski çağrı ya da sonradan gelen yakın plan yanlış (% / %)', v_n, v_n2;
end if;

-- (d) Çıkış: kameranın bu olayda kapattığı bilet ikisini birden alır. Bilet
--     açıkken 40 gün geriye tarihlenir: (h)'de gece işi boşaltacak.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.bilet_ac('ZZ93CX303', v_islem, 'KAMERA', now() - interval '1 hour') into v_bilet2;
perform pg_temp.logout();
update public.biletler set created_at = now() - interval '40 days' where id = v_bilet2;
v_islem := gen_random_uuid();
v_ts := now() - interval '10 seconds';
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ93CX303', v_islem, v_ts);
select public.kamera_foto_bagla(v_islem, v_bilet2, v_ts, 'kamera/' || v_islem::text || '.jpg',
                                'kamera/' || v_islem::text || '-yakin.jpg') into v_n;
select public.kamera_foto_bagla(v_islem, v_bilet2, v_ts, 'kamera/' || v_islem::text || '.jpg',
                                'kamera/' || v_islem::text || '-yakin.jpg') into v_n2;
perform pg_temp.logout();
if v_n <> 2 or v_n2 <> 0
   or not exists (select 1 from public.biletler
                   where id = v_bilet2 and durum = 'KAPALI' and cikis_kaynak = 'KAMERA'
                     and cikis_foto = 'kamera/' || v_islem::text || '.jpg'
                     and cikis_yakin = 'kamera/' || v_islem::text || '-yakin.jpg'
                     and giris_yakin is null) then
  raise exception 'FAIL 93d: kameranın kapattığı biletin yakın planı bağlanmadı (% / %)', v_n, v_n2;
end if;

-- (d2) Çıkış fotoğrafı önce (eski webhook), yakın plan sonra: kapanmış
--      bilette cikis_foto doluyken de cikis_yakin yazılır. Bayraksız
--      doğrudan yazma ise reddedilir.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.bilet_ac('ZZ93KP404', v_islem, 'KAMERA', now() - interval '1 hour') into v_id2;
v_islem := gen_random_uuid();
v_ts2 := now() - interval '20 seconds';
perform public.kamera_cikis_bildir('ZZ93KP404', v_islem, v_ts2);
select public.kamera_foto_bagla(v_islem, v_id2, v_ts2, 'kamera/' || v_islem::text || '.jpg') into v_n;
perform pg_temp.logout();
begin
  update public.biletler set cikis_yakin = 'kamera/' || v_islem::text || '-yakin.jpg' where id = v_id2;
  raise exception 'FAIL 93d2: kapanmış bilete bayraksız yakın plan yazılabildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Kapanmış bilet değiştirilemez%' then
    raise exception 'FAIL 93d2: beklenmeyen hata: %', sqlerrm;
  end if;
end;
perform pg_temp.kamera();
select public.kamera_foto_bagla(v_islem, v_id2, v_ts2, 'kamera/' || v_islem::text || '.jpg',
                                'kamera/' || v_islem::text || '-yakin.jpg') into v_n2;
perform pg_temp.logout();
if v_n <> 1 or v_n2 <> 1
   or not exists (select 1 from public.biletler
                   where id = v_id2 and durum = 'KAPALI'
                     and cikis_foto = 'kamera/' || v_islem::text || '.jpg'
                     and cikis_yakin = 'kamera/' || v_islem::text || '-yakin.jpg') then
  raise exception 'FAIL 93d2: cikis_foto doluyken yakın plan bağlanmadı (% / %)', v_n, v_n2;
end if;

-- (e) Dolu yakın plan kapanmış bilette değiştirilemez.
begin
  update public.biletler set cikis_yakin = 'kamera/baska-yakin.jpg' where id = v_bilet2;
  raise exception 'FAIL 93e: kapanmış biletin yakın planı değiştirilebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Kapanmış bilet değiştirilemez%' then
    raise exception 'FAIL 93e: beklenmeyen hata: %', sqlerrm;
  end if;
end;

-- (f) Kamera kaydı yakın planı alır; karttan açılan bilet onu taşır.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now() - interval '10 minutes',
                               'ZZ93IS5O5', 0.42, null) into v_id;
select public.kamera_foto_bagla(v_islem, null, null, 'kamera/' || v_islem::text || '.jpg',
                                'kamera/' || v_islem::text || '-yakin.jpg') into v_n;
perform pg_temp.logout();
if v_n <> 2 or not exists (select 1 from public.istisnalar
                            where id = v_id and foto_path = 'kamera/' || v_islem::text || '.jpg'
                              and yakin_path = 'kamera/' || v_islem::text || '-yakin.jpg') then
  raise exception 'FAIL 93f: kamera kaydı yakın planı almadı (%)', v_n;
end if;
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac(v_id, 'ZZ93IS505') into v_json;
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = (v_json ->> 'bilet_id')::uuid
                  and giris_foto = 'kamera/' || v_islem::text || '.jpg'
                  and giris_yakin = 'kamera/' || v_islem::text || '-yakin.jpg') then
  raise exception 'FAIL 93f: karttan açılan bilet yakın planı taşımıyor (%)', v_json;
end if;
-- (h) için: kart 40 gün geriye (istisnalar'da değişmezlik guard'ı yok).
update public.istisnalar set created_at = now() - interval '40 days' where id = v_id;

-- (g) Tek kapı "açık bilet yok" kartından saatli giriş de taşır.
v_islem := gen_random_uuid();
v_id2 := public.istisna_yaz('ACIK_BILET_YOK', 'ORTAK', 'ZZ93SA606', 'KAMERA', v_islem,
                            null, null, now());
perform pg_temp.kamera();
perform public.kamera_foto_bagla(v_islem, null, null, 'kamera/' || v_islem::text || '.jpg',
                                 'kamera/' || v_islem::text || '-yakin.jpg');
perform pg_temp.logout();
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac_saatli(v_id2, 'ZZ93SA606', date_trunc('minute', now()) - interval '2 hours',
                                      'PASS 93g deneme') into v_json;
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = (v_json ->> 'bilet_id')::uuid
                  and giris_foto = 'kamera/' || v_islem::text || '.jpg'
                  and giris_yakin = 'kamera/' || v_islem::text || '-yakin.jpg') then
  raise exception 'FAIL 93g: saatli girişle açılan bilet yakın planı taşımıyor (%)', v_json;
end if;

-- (h) Gece işi: süresi dolan yakın planlar boşalır — kapanmış bilette de,
--     hata vermeden; süresi dolmamışa dokunulmaz.
v_txt := pg_get_functiondef('public.run_gunluk_bakim()'::regprocedure);
if v_txt !~* 'set\s+giris_yakin\s*=\s*null' or v_txt !~* 'set\s+cikis_yakin\s*=\s*null'
   or v_txt !~* 'set\s+yakin_path\s*=\s*null' then
  raise exception 'FAIL 93h: run_gunluk_bakim yakın plan yollarını boşaltmıyor';
end if;
perform public.run_gunluk_bakim();
if not exists (select 1 from public.biletler
                where id = v_bilet2 and durum = 'KAPALI'
                  and cikis_foto is null and cikis_yakin is null) then
  raise exception 'FAIL 93h: süresi dolan kapanmış biletin fotoğrafları boşalmadı';
end if;
if not exists (select 1 from public.istisnalar
                where id = v_id and foto_path is null and yakin_path is null) then
  raise exception 'FAIL 93h: süresi dolan kaydın fotoğrafları boşalmadı';
end if;
if (select giris_yakin from public.biletler where id = v_bilet) is null then
  raise exception 'FAIL 93h: süresi dolmamış yakın plan boşaltıldı';
end if;

raise notice 'PASS 93: aracın yakın planı sahne fotoğrafının yanına aynı kurallarla bağlanır (girişte, kameranın kapattığı bilette, kayıtta); yol yalnızca bu olayınki; eski 4 argümanlı çağrı çalışır; karttan açılan bilet taşır; gece işi boşaltır';
end if;   -- 074 koşulmadıysa PASS 93 atlanır (geçici)

-- =====================================================================
-- 94  Çözülmemiş kayıtlar: Bekleyen / Çözülmüş / Kapatılan (075)
--     Sahip 2026-11-23: üç sekme; personel yalnızca Bekleyen'i görür;
--     Yönetici çözülmüş ve kapatılanda kimin ne yaptığını görür.
--       · "Kapat" (istisna_coz) kaydı kapatildi = true ile işaretler;
--       · bir eylemle (Giriş aç) ya da kameranın kendisiyle çözülen kayıt
--         işaretlenmez (Çözülmüş sekmesi);
--       · personel çözülmüş / kapatılmış satırı veritabanından okuyamaz
--         (RLS) — ekranda gizlemek yetmez; bekleyeni okur ve işler;
--       · sütun boş geçilebilir: Çöp Kutusu (049) eski bir kopyayı
--         jsonb_populate_record ile geri yükler, kopyada bu anahtar yok.
-- =====================================================================
perform pg_temp.logout();

-- (a) Sütun.
if not exists (select 1 from information_schema.columns
                where table_schema = 'public' and table_name = 'istisnalar'
                  and column_name = 'kapatildi' and data_type = 'boolean'
                  and is_nullable = 'YES') then
  raise exception 'FAIL 94a: istisnalar.kapatildi (boolean, boş geçilebilir) yok — 075 koşulmamış';
end if;

-- (b) Kapat: kapatıldı olarak işaretlenir, kapatan personel.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now() - interval '5 minutes',
                               null, null, null) into v_id;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
perform public.istisna_coz(v_id, null);
perform pg_temp.logout();
if not exists (select 1 from public.istisnalar
                where id = v_id and cozuldu_at is not null and cozuldu_by = u_personel
                  and kapatildi is true) then
  raise exception 'FAIL 94b: Kapat kaydı kapatıldı olarak işaretlemedi';
end if;

-- (c) Giriş aç ile çözülen kayıt kapatılmış sayılmaz.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now() - interval '5 minutes',
                               'ZZ94GR101', 0.40, null) into v_id2;
perform pg_temp.logout();
perform pg_temp.login(u_personel);
select public.istisna_bilet_ac(v_id2, 'ZZ94GR101') into v_json;
perform pg_temp.logout();
if (v_json ->> 'bilet_id') is null
   or not exists (select 1 from public.istisnalar
                   where id = v_id2 and cozuldu_at is not null and cozuldu_by = u_personel
                     and kapatildi is not true) then
  raise exception 'FAIL 94c: Giriş aç ile çözülen kayıt yanlış işaretlendi (%)', v_json;
end if;

-- (d) Bekleyen bir kayıt (islem_id = v_islem).
v_islem := gen_random_uuid();
perform pg_temp.kamera();
perform public.kamera_okunamadi('GIRIS', v_islem, now() - interval '5 minutes', null, null, null);
perform pg_temp.logout();

-- Personel: bekleyeni görür, çözülmüş ve kapatılmışı görmez.
perform pg_temp.login(u_personel);
select count(*) into v_n from public.istisnalar where islem_id = v_islem;
select count(*) into v_n2 from public.istisnalar where id in (v_id, v_id2);
perform pg_temp.logout();
if v_n <> 1 then
  raise exception 'FAIL 94d: personel bekleyen kaydı görmüyor';
end if;
if v_n2 <> 0 then
  raise exception 'FAIL 94d: personel çözülmüş / kapatılmış % kayıt görüyor', v_n2;
end if;

-- Yönetici: üçünü de görür.
perform pg_temp.login(u_yonetici);
select count(*) into v_n from public.istisnalar where islem_id = v_islem or id in (v_id, v_id2);
perform pg_temp.logout();
if v_n <> 3 then
  raise exception 'FAIL 94d: Yönetici % kayıt görüyor (3 beklenirdi)', v_n;
end if;

-- Onaysız: hiçbiri.
perform pg_temp.login(u_pending);
select count(*) into v_n from public.istisnalar where islem_id = v_islem or id in (v_id, v_id2);
perform pg_temp.logout();
if v_n <> 0 then
  raise exception 'FAIL 94d: onaysız kullanıcı % kayıt görüyor', v_n;
end if;

-- (e) Değişmezler: bekleyen kayıt kapatılmış olamaz; kameranın kendisi
--     kapattığı kayıt (cozuldu_by boş) kapatılmış sayılmaz.
if exists (select 1 from public.istisnalar
            where kapatildi is true and (cozuldu_at is null or cozuldu_by is null)) then
  raise exception 'FAIL 94e: bekleyen ya da kameranın çözdüğü kayıt kapatılmış görünüyor';
end if;

-- (f) istisna_coz yetkileri aynı: personel çağırır, anon çağıramaz.
if not has_function_privilege('authenticated', 'public.istisna_coz(uuid, text)', 'execute')
   or has_function_privilege('anon', 'public.istisna_coz(uuid, text)', 'execute') then
  raise exception 'FAIL 94f: istisna_coz yetkileri değişmiş';
end if;

raise notice 'PASS 94: Kapat kaydı kapatıldı olarak işaretler, Giriş aç çözülmüş bırakır; personel yalnızca bekleyeni görür, Yönetici hepsini, onaysız hiçbirini; bekleyen ya da kameranın çözdüğü kayıt kapatılmış sayılmaz';

-- =====================================================================
-- 95  İçeride listesi bütün açık biletleri getirir (076)
--     Sahip (2026-11-23): acik_bilet_ara (052) aramasız listeyi 50 ile
--     kesiyordu, en yeniden eskiye. İçeride 76 araç varken en ESKİ 26'sı —
--     terk edilmiş olabilecekler — Gişe'ye hiç gelmiyordu. Uygulama artık
--     25'er gösteriyor (iceride.ts); sunucu aramasız listede hepsini verir.
--     Yazılı aramada sınır kalır (50): uygulama aramayı hiç kesmez, tek harf
--     yüzlerce satır çizdirmesin.
--     Otopark boş varsayılmaz: sayım, kontrol anındaki açık bilet sayısıdır.
-- =====================================================================
perform pg_temp.logout();
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
select gen_random_uuid(), 'ZZ95A' || lpad(n::text, 3, '0'),
       -- 001 en eski: giriş saatleri 1-52 dakika aralıklı geriye yayılır.
       now() - interval '1 hour' - make_interval(mins => 52 - n), t.id, 'ACIK'
  from generate_series(1, 51) n,
       (select id from public.tarifeler where gecerli_bitis is null order by id limit 1) t;

-- (a) Aramasız liste = o anki bütün açık biletler (en az 51).
perform pg_temp.login(u_personel);
select count(*) into v_n from public.acik_bilet_ara(null);
select count(*) into v_n2 from public.acik_bilet_ara('');
perform pg_temp.logout();
select count(*) into v_bigint from public.biletler where durum = 'ACIK';
if v_n <> v_bigint or v_n2 <> v_bigint then
  raise exception 'FAIL 95a: İçeride listesi % / % açık bileti getiriyor, olması gereken % (076 koşuldu mu?)',
    v_n, v_n2, v_bigint;
end if;

-- (b) En eski eklenen bilet aramasız listede.
perform pg_temp.login(u_personel);
if not exists (select 1 from public.acik_bilet_ara(null) a where a.plaka = 'ZZ95A001') then
  perform pg_temp.logout();
  raise exception 'FAIL 95b: en eski açık bilet İçeride listesine gelmiyor';
end if;

-- (c) Yazılı arama hâlâ 50 ile sınırlı (51 eşleşme var).
select count(*) into v_n from public.acik_bilet_ara('ZZ95A');
perform pg_temp.logout();
if v_n <> 50 then
  raise exception 'FAIL 95c: yazılı arama 50 yerine % satır getirdi', v_n;
end if;

-- (d) Yetkiler aynı: personel çağırır; anon ve service_role çağıramaz.
if not has_function_privilege('authenticated', 'public.acik_bilet_ara(text)', 'execute')
   or has_function_privilege('anon', 'public.acik_bilet_ara(text)', 'execute')
   or has_function_privilege('service_role', 'public.acik_bilet_ara(text)', 'execute') then
  raise exception 'FAIL 95d: acik_bilet_ara yetkileri değişmiş';
end if;

raise notice 'PASS 95: İçeride listesi bütün açık biletleri getirir (en eskisi dahil); yazılı arama 50 ile sınırlı; yetkiler aynı';

-- =====================================================================
-- 96  Tek kapı: ÇIKTI kartının emin tahmini bileti kapatır — benzeri yoksa (077 D)
--     Sahip 2026-11-25 ("yalnızca benzeri yoksa"): köprü 1.4.6 plakasız /
--     belirsiz kartın yönünü de gönderir. Kapıdan ÇIKTI diye izlenen aracın
--     tahmini ≥ 0.90 ve TAM bir açık bileti varsa, başka hiçbir açık bilet
--     ona bir karakter uzak değilse ve giriş penceresi (yeni giriş) geçtiyse
--     kamera_tahmin_cikis bileti kamera_cikis_bildir ile kapatır (ödemesiz,
--     her kamera çıkışı gibi). Aksi her durumda null: webhook eski kart yolunu
--     izler. Tekrar gelen aynı olay aynı bileti döndürür, ikinci kez kapatmaz.
-- =====================================================================
perform pg_temp.logout();

-- (a) Yalnızca kamera (service_role) çağırır.
v_txt := 'public.kamera_tahmin_cikis(text, numeric, uuid, timestamptz, jsonb)';
if to_regprocedure(v_txt) is null then
  raise exception 'FAIL 96a: kamera_tahmin_cikis yok — 077 çalıştırılmadı';
end if;
if not has_function_privilege('service_role', v_txt, 'execute')
   or has_function_privilege('anon', v_txt, 'execute')
   or has_function_privilege('authenticated', v_txt, 'execute') then
  raise exception 'FAIL 96a: kamera_tahmin_cikis yetkileri yanlış';
end if;

-- (b) 090 (sahibin kararı 28.11): kural KAPANDI. 26–28.11'de iki kez
--     çalıştı, ikisi de yanlıştı (park etmiş aracın plakası; iki plakalı
--     iz). Tam eşleşme, 0.93, ÇIKTI, 30 dk önce girmiş: yine hiçbir şey —
--     bilet açık kalır, denetim kaydı yok; webhook kartı yazar.
perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ96KK101', gen_random_uuid(), 'KAMERA', now() - interval '30 minutes');
v_islem := gen_random_uuid();
v_id := public.kamera_tahmin_cikis('ZZ96KK101', 0.93, v_islem, now(),
                                   jsonb_build_object('hareket', 'CIKTI'));
perform pg_temp.logout();
if v_id is not null
   or not exists (select 1 from public.biletler where id = v_bilet and durum = 'ACIK') then
  raise exception 'FAIL 96b: çıkış tahmini bileti kapattı (090 kapattı) (%)', v_id;
end if;
if exists (select 1 from public.audit_log
            where action = 'kamera_tahmin_cikis' and row_id = v_bilet) then
  raise exception 'FAIL 96b: kapalı kural denetim kaydı yazdı';
end if;

-- (c) Bir karakter uzak başka açık bilet var: hiçbir şey (kart yolu).
perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ96KL201', gen_random_uuid(), 'KAMERA', now() - interval '30 minutes');
v_bilet2 := public.bilet_ac('ZZ96KL208', gen_random_uuid(), 'KAMERA', now() - interval '30 minutes');
v_id := public.kamera_tahmin_cikis('ZZ96KL201', 0.97, gen_random_uuid(), now(),
                                   jsonb_build_object('hareket', 'CIKTI'));
perform pg_temp.logout();
if v_id is not null or exists (select 1 from public.biletler
                                where id in (v_bilet, v_bilet2) and durum <> 'ACIK') then
  raise exception 'FAIL 96c: benzeri varken tahminle bilet kapandı';
end if;

-- (d) Güven 0.89, yön GİRDİ ya da yön yok: hiçbir şey.
perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ96KM301', gen_random_uuid(), 'KAMERA', now() - interval '30 minutes');
if public.kamera_tahmin_cikis('ZZ96KM301', 0.89, gen_random_uuid(), now(),
                              jsonb_build_object('hareket', 'CIKTI')) is not null
   or public.kamera_tahmin_cikis('ZZ96KM301', 0.95, gen_random_uuid(), now(),
                                 jsonb_build_object('hareket', 'GIRDI')) is not null
   or public.kamera_tahmin_cikis('ZZ96KM301', 0.95, gen_random_uuid(), now(), null) is not null then
  perform pg_temp.logout();
  raise exception 'FAIL 96d: düşük güven ya da ÇIKTI olmayan kart bileti kapattı';
end if;
perform pg_temp.logout();
if not exists (select 1 from public.biletler where id = v_bilet and durum = 'ACIK') then
  raise exception 'FAIL 96d: bilet kapandı';
end if;

-- (e) Bilet giriş penceresinde (1 dk önce açıldı): hiçbir şey; tam bileti
--     olmayan tahmin de hiçbir şey.
perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ96KN401', gen_random_uuid(), 'KAMERA', now() - interval '1 minute');
if public.kamera_tahmin_cikis('ZZ96KN401', 0.99, gen_random_uuid(), now(),
                              jsonb_build_object('hareket', 'CIKTI')) is not null
   or public.kamera_tahmin_cikis('ZZ96KP999', 0.99, gen_random_uuid(), now(),
                                 jsonb_build_object('hareket', 'CIKTI')) is not null then
  perform pg_temp.logout();
  raise exception 'FAIL 96e: pencere içinde ya da tam bileti olmayan tahmin bir şey kapattı';
end if;
perform pg_temp.logout();

raise notice 'PASS 96: ÇIKTI kartının tahmini hiçbir bileti kapatmaz (090); yalnızca kamera çağırır';

-- =====================================================================
-- 97  Tek kapı: içeride okunan plaka az önceki giriş kartına bağlanır (077 E2)
--     Sahip 2026-11-25 ("yalnızca E2"): kapıdan giren aracın plakası
--     okunamadı (kart), birkaç dakika sonra köprü onu otoparkın İÇİNDE emin
--     okudu. Eskiden ikinci bir "İçeride bileti olmayan araç" kartı açılırdı.
--     Artık son 15 dk içindeki çözülmemiş, plakasız, ÇIKTI olmayan tek kapı
--     kartı plakayı alır (en yenisi); kart açık kalır, bilet açılmaz —
--     kararı yine insan verir. Tahmini başka bir plakaysa bağlanmaz.
--     Canlı veritabanında az önceki gerçek kartlar testi şaşırtmasın diye
--     önce kapatılır (transaction sonunda geri alınır).
-- =====================================================================
perform pg_temp.logout();
update public.istisnalar set cozuldu_at = now()
 where tur::text = 'OKUNAMADI' and yon = 'ORTAK' and cozuldu_at is null
   and kaynak_zaman > now() - interval '30 minutes';

-- (a) Giriş kartı (yön GİRDİ) ve 3 dk sonra içeride emin okuma.
v_islem := gen_random_uuid();
perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', v_islem, now() - interval '3 minutes', null, null,
                                jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ97MM101', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
-- 090 (sahibin kararı 28.11): bağlanan kart artık BİLETE döner — bilet
-- kartın saatinden açılır, kart sistemce çözülür (PASS 139-142).
if v_json ->> 'karar' is distinct from 'GIRIS'
   or v_json ->> 'sebep' is distinct from 'GIRIS_KARTI' then
  raise exception 'FAIL 97a: içeride okuma giriş kartına bağlanmadı (%)', v_json;
end if;
if not exists (select 1 from public.istisnalar
                where id = v_id and cozuldu_at is not null and cozuldu_by is null)
   or exists (select 1 from public.istisnalar
               where plaka = 'ZZ97MM101' and tur::text = 'ICERIDE_BILETSIZ')
   or not exists (select 1 from public.biletler
                   where id = (v_json ->> 'bilet_id')::uuid and plaka = 'ZZ97MM101'
                     and durum = 'ACIK' and giris_at = now() - interval '3 minutes'
                     and islem_id = v_islem) then
  raise exception 'FAIL 97a: kart çözülmedi, bilet kartın saatinden açılmadı ya da ikinci kart açıldı';
end if;

-- (b) ÇIKTI kartı ve tahmini başka plaka olan kart bağlanmaz.
--     090: kartsız içerideki araca bilet açılır (ICERIDE_GORULDU).
v_islem := gen_random_uuid();
perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', v_islem, now() - interval '2 minutes', null, null,
                                jsonb_build_object('hareket', 'CIKTI'));
v_id2 := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '1 minute',
                                 'ZZ97MX999', 0.7, jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ97ML202', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'ICERIDE_GORULDU'
   or exists (select 1 from public.istisnalar where id in (v_id, v_id2) and plaka is not null) then
  raise exception 'FAIL 97b: çıkış kartı ya da başka tahminli kart plakayı aldı (%)', v_json;
end if;

-- (c) 15 dakikadan eski kart bağlanmaz.
perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '20 minutes',
                                null, null, jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ97MN303', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
-- 090: 15 dk'dan eski, tahminsiz kart bağlanmaz; bilet görülmeden açılır.
if v_json ->> 'sebep' is distinct from 'ICERIDE_GORULDU'
   or exists (select 1 from public.istisnalar where id = v_id and plaka is not null) then
  raise exception 'FAIL 97c: eski kart plakayı aldı (%)', v_json;
end if;

raise notice 'PASS 97: içeride emin okunan plaka son 15 dk içindeki plakasız giriş kartından bilet açar (090); çıkış kartı, başka tahmin ve eski tahminsiz kart bağlanmaz';

-- =====================================================================
-- 98  Tek kapı: aynı iz girip 2 dk içinde çıktı — bilet kapanır (077 K)
--     Sahada 24.11 09:32 / 09:34: köprü aynı aracı (aynı iz) kapıdan girerken
--     ve hemen geri çıkarken izledi; çıkış YENI_GIRIS diye yok sayıldı, bilet
--     açık kaldı. Köprü 1.4.6 böyle bir çıkışı `ayni_iz_dondu: true` ile
--     gönderir: giriş penceresinde ve ÇIKTI ipucuyla gelirse bilet her kamera
--     çıkışı gibi kapanır (ücret tarifeden: ücretsiz süre içindeyse 0).
--     İşaretsiz ya da ÇIKTI olmayan olay eskisi gibi YENI_GIRIS.
-- =====================================================================
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ98PP101', gen_random_uuid(), now() - interval '1 minute',
                              null, null, 'GIRDI') into v_json;
v_bilet := (v_json ->> 'bilet_id')::uuid;
select public.kamera_tek_kapi('ZZ98PP101', gen_random_uuid(), now(), null,
                              jsonb_build_object('ayni_iz_dondu', true), 'CIKTI') into v_json2;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS'
   or v_json2 ->> 'karar' is distinct from 'CIKIS'
   or v_json2 ->> 'sebep' is distinct from 'AYNI_IZ_DONDU'
   or not exists (select 1 from public.biletler b
                   where b.id = v_bilet and b.durum = 'KAPALI' and b.cikis_kaynak::text = 'KAMERA'
                     and b.ucret_kurus = public.ucret_hesapla(b.giris_at, b.cikis_at, b.tarife_id)) then
  raise exception 'FAIL 98a: aynı izin dönüşü bileti kapatmadı (% / %)', v_json, v_json2;
end if;

perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ98PL202', gen_random_uuid(), now() - interval '1 minute',
                              null, null, 'GIRDI') into v_json;
v_bilet := (v_json ->> 'bilet_id')::uuid;
select public.kamera_tek_kapi('ZZ98PL202', gen_random_uuid(), now(), null, null, 'CIKTI') into v_json;
select public.kamera_tek_kapi('ZZ98PL202', gen_random_uuid(), now(), null,
                              jsonb_build_object('ayni_iz_dondu', true), 'GIRDI') into v_json2;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'YENI_GIRIS' or v_json2 ->> 'sebep' is distinct from 'YENI_GIRIS'
   or not exists (select 1 from public.biletler where id = v_bilet and durum = 'ACIK') then
  raise exception 'FAIL 98b: işaretsiz ya da GİRDİ ipuçlu olay bileti kapattı (% / %)', v_json, v_json2;
end if;

raise notice 'PASS 98: aynı izin 2 dk içindeki dönüşü bileti kapatır; işaretsiz ya da ÇIKTI olmayan olay eskisi gibi yok sayılır';

-- =====================================================================
-- 99  İçeride görüldü saati (077 H)
--     Açık bileti olan araç otoparkın içinde görülünce (ICERIDE_ACIK) bilet
--     o anı taşır; İçeride listesi (acik_bilet_ara) onu gösterir. Saat geri
--     gitmez. Karar eskisi gibi YOKSAY; bilet başka hiçbir şekilde değişmez.
-- =====================================================================
perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ99TT101', gen_random_uuid(), 'KAMERA', now() - interval '40 minutes');
select public.kamera_tek_kapi('ZZ99TT101', gen_random_uuid(), now() - interval '5 minutes',
                              null, null, 'ICERIDE') into v_json;
select public.kamera_tek_kapi('ZZ99TT101', gen_random_uuid(), now() - interval '10 minutes',
                              null, null, 'ICERIDE') into v_json2;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'ICERIDE_ACIK' or v_json2 ->> 'sebep' is distinct from 'ICERIDE_ACIK'
   or not exists (select 1 from public.biletler
                   where id = v_bilet and durum = 'ACIK'
                     and iceride_goruldu_at = now() - interval '5 minutes') then
  raise exception 'FAIL 99a: içeride görüldü saati yazılmadı ya da geri gitti (% / %)', v_json, v_json2;
end if;

perform pg_temp.login(u_personel);
select a.iceride_goruldu_at into v_ts from public.acik_bilet_ara('ZZ99TT101') a where a.id = v_bilet;
perform pg_temp.logout();
if v_ts is distinct from now() - interval '5 minutes' then
  raise exception 'FAIL 99b: İçeride listesi içeride görüldü saatini getirmiyor (%)', v_ts;
end if;
if not has_function_privilege('authenticated', 'public.acik_bilet_ara(text)', 'execute')
   or has_function_privilege('anon', 'public.acik_bilet_ara(text)', 'execute')
   or has_function_privilege('service_role', 'public.acik_bilet_ara(text)', 'execute') then
  raise exception 'FAIL 99b: acik_bilet_ara yetkileri değişmiş';
end if;

raise notice 'PASS 99: açık biletli araç içeride görülünce bilet o saati taşır (geri gitmez), İçeride listesi gösterir';

-- =====================================================================
-- 100  Oto yıkama ücreti tarifede (078)
--      Yalnızca Yönetici girer; tarife_guncelle'nin son, varsayılanlı
--      parametresi. Ücretin geri kalanı olduğu gibi kalır (aynı değerler).
-- =====================================================================
select * into v_tr from public.tarifeler where gecerli_bitis is null;
perform pg_temp.login(u_personel);
begin
  perform public.tarife_guncelle(v_tr.ucretsiz_dakika, v_tr.ilk_saat_kurus, v_tr.sonraki_saat_kurus,
    v_tr.gunluk_tavan_kurus, v_tr.kayip_bilet_kurus, v_tr.tur, v_tr.sabit_kurus, v_tr.kademeler, 15000);
  raise exception 'FAIL 100a: Personel oto yıkama ücretini değiştirebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%Yönetici%' then
    raise exception 'FAIL 100a: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
perform pg_temp.logout();

perform pg_temp.login(u_yonetici);
perform public.tarife_guncelle(v_tr.ucretsiz_dakika, v_tr.ilk_saat_kurus, v_tr.sonraki_saat_kurus,
  v_tr.gunluk_tavan_kurus, v_tr.kayip_bilet_kurus, v_tr.tur, v_tr.sabit_kurus, v_tr.kademeler, 15000);
perform pg_temp.logout();
select yikama_kurus into v_n from public.tarifeler where gecerli_bitis is null;
if v_n is distinct from 15000 then
  raise exception 'FAIL 100b: Yönetici yıkama ücretini kaydedemedi (%)', v_n;
end if;

raise notice 'PASS 100: oto yıkama ücretini yalnızca Yönetici tarifeye girer';

-- =====================================================================
-- 101  Bilete yıkama ekle / kaldır (078 bilet_yikama, bilet_ucret_onizle)
--      Fiyat eklendiği anda bilete kilitlenir; sonraki tarife değişikliği
--      dokunmaz. Kaldırma puanı ücretin üstüne çıkaramaz. Fiyat yoksa ya da
--      kullanıcı personel değilse reddedilir.
-- =====================================================================
perform pg_temp.login(u_personel);
v_bilet := public.bilet_ac('ZZ100YK1', gen_random_uuid());
v_n := public.bilet_yikama(v_bilet, true);
perform pg_temp.logout();
if v_n is distinct from 15000
   or not exists (select 1 from public.biletler
                   where id = v_bilet and yikama_kurus = 15000 and yikama_at is not null) then
  raise exception 'FAIL 101a: yıkama bilete eklenmedi (%)', v_n;
end if;

perform pg_temp.login(u_yonetici);
perform public.tarife_guncelle(v_tr.ucretsiz_dakika, v_tr.ilk_saat_kurus, v_tr.sonraki_saat_kurus,
  v_tr.gunluk_tavan_kurus, v_tr.kayip_bilet_kurus, v_tr.tur, v_tr.sabit_kurus, v_tr.kademeler, 20000);
perform pg_temp.logout();
perform pg_temp.login(u_personel);
v_n := public.bilet_yikama(v_bilet, true);
v_ucret := public.bilet_ucret_onizle(v_bilet);
perform pg_temp.logout();
select public.ucret_hesapla(giris_at, now(), tarife_id) into v_ucret2
  from public.biletler where id = v_bilet;
if v_n is distinct from 15000
   or (select yikama_kurus from public.biletler where id = v_bilet) is distinct from 15000 then
  raise exception 'FAIL 101b: tarife değişince biletteki yıkama fiyatı değişti (%)', v_n;
end if;
if v_ucret is distinct from v_ucret2 + 15000 then
  raise exception 'FAIL 101c: önizleme otopark + yıkama değil (% / %)', v_ucret, v_ucret2;
end if;

perform pg_temp.login(u_personel);
v_n := public.bilet_yikama(v_bilet, false);
v_ucret := public.bilet_ucret_onizle(v_bilet);
perform pg_temp.logout();
if v_n is not null or v_ucret is distinct from v_ucret2
   or exists (select 1 from public.biletler
               where id = v_bilet and (yikama_kurus is not null or yikama_at is not null)) then
  raise exception 'FAIL 101d: yıkama kaldırılamadı (% / %)', v_n, v_ucret;
end if;

-- Puan ücretin üstüne çıkamaz: yıkamasız ücretten büyük indirim varken kaldırma reddedilir.
-- Yeniden ekleme o anki tarife fiyatını kilitler (şimdi 200 ₺).
perform pg_temp.login(u_personel);
v_n := public.bilet_yikama(v_bilet, true);
perform pg_temp.logout();
if v_n is distinct from 20000 then
  raise exception 'FAIL 101e: yeniden eklenen yıkama o anki tarife fiyatını almadı (%)', v_n;
end if;
update public.biletler set indirim_kurus = v_ucret2 + 1 where id = v_bilet;
perform pg_temp.login(u_personel);
begin
  perform public.bilet_yikama(v_bilet, false);
  raise exception 'FAIL 101e: puan ücretten fazlayken yıkama kaldırıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%puan%' then
    raise exception 'FAIL 101e: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
perform pg_temp.logout();
update public.biletler set indirim_kurus = 0 where id = v_bilet;

-- Tarifede fiyat yoksa eklenemez.
perform pg_temp.login(u_yonetici);
perform public.tarife_guncelle(v_tr.ucretsiz_dakika, v_tr.ilk_saat_kurus, v_tr.sonraki_saat_kurus,
  v_tr.gunluk_tavan_kurus, v_tr.kayip_bilet_kurus, v_tr.tur, v_tr.sabit_kurus, v_tr.kademeler, null);
perform pg_temp.logout();
perform pg_temp.login(u_personel);
v_bilet2 := public.bilet_ac('ZZ100YK2', gen_random_uuid());
begin
  perform public.bilet_yikama(v_bilet2, true);
  raise exception 'FAIL 101f: tarifede fiyat yokken yıkama eklendi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%tarifede tanımlı değil%' then
    raise exception 'FAIL 101f: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
perform pg_temp.logout();

perform pg_temp.login(u_pending);
begin
  perform public.bilet_yikama(v_bilet2, true);
  raise exception 'FAIL 101g: onaysız kullanıcı yıkama ekledi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();

-- Sonraki adımlar için fiyat yine 150 ₺.
perform pg_temp.login(u_yonetici);
perform public.tarife_guncelle(v_tr.ucretsiz_dakika, v_tr.ilk_saat_kurus, v_tr.sonraki_saat_kurus,
  v_tr.gunluk_tavan_kurus, v_tr.kayip_bilet_kurus, v_tr.tur, v_tr.sabit_kurus, v_tr.kademeler, 15000);
perform pg_temp.logout();

raise notice 'PASS 101: yıkama eklenir/kaldırılır, fiyatı kilitlenir, önizleme ekler; puan, fiyatsız tarife ve onaysız kullanıcı reddedilir';

-- =====================================================================
-- 102  Yıkamalı bilet kapanır (078 bilet_ucreti)
--      bilet_kapat, abonman ve kamera çıkışı aynı fiyatı kullanır:
--      otopark (abonmanda 0) + yıkama. Kapanmış bilete yıkama eklenmez.
-- =====================================================================
perform pg_temp.login(u_personel);
select b.ucret_kurus into v_n from public.bilet_kapat(v_bilet, 'NAKIT') b;
perform pg_temp.logout();
-- Bu biletin kilitli yıkama fiyatı 200 ₺ (101e).
if v_n is distinct from v_ucret2 + 20000
   or (select coalesce(sum(tutar_kurus), 0) from public.tahsilatlar
        where bilet_id = v_bilet) is distinct from v_n then
  raise exception 'FAIL 102a: bilet_kapat yıkamayı almadı (% / %)', v_n, v_ucret2;
end if;

perform pg_temp.login(u_personel);
begin
  perform public.bilet_yikama(v_bilet, true);
  raise exception 'FAIL 102b: kapanmış bilete yıkama eklendi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%açık değil%' then
    raise exception 'FAIL 102b: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
perform pg_temp.logout();

insert into public.abonmanlar (plaka, baslangic, bitis, ucret_kurus)
values ('ZZ100AB1', (now() at time zone 'Europe/Istanbul')::date - 1,
        (now() at time zone 'Europe/Istanbul')::date + 30, 100000);
perform pg_temp.login(u_personel);
v_bilet2 := public.bilet_ac('ZZ100AB1', gen_random_uuid());
perform public.bilet_yikama(v_bilet2, true);
select a.ucret_kurus, a.yikama_kurus into v_n, v_n2
  from public.acik_bilet_ara('ZZ100AB1') a where a.id = v_bilet2;
perform pg_temp.logout();
if (select abonman_id from public.biletler where id = v_bilet2) is null
   or v_n is distinct from 15000 or v_n2 is distinct from 15000 then
  raise exception 'FAIL 102c: abonmanlı yıkamalı araç listede yalnızca yıkama değil (% / %)', v_n, v_n2;
end if;
perform pg_temp.login(u_personel);
select b.ucret_kurus into v_n from public.bilet_kapat(v_bilet2, 'NAKIT') b;
perform pg_temp.logout();
if v_n is distinct from 15000 then
  raise exception 'FAIL 102d: abonmanlı araç yıkama ücretiyle kapanmadı (%)', v_n;
end if;

perform pg_temp.kamera();
v_id := public.bilet_ac('ZZ100KM1', gen_random_uuid(), 'KAMERA', now() - interval '40 minutes');
perform pg_temp.logout();
perform pg_temp.login(u_personel);
perform public.bilet_yikama(v_id, true);
perform pg_temp.logout();
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ100KM1', gen_random_uuid(), now());
perform pg_temp.logout();
if not exists (select 1 from public.biletler b
                where b.id = v_id and b.durum = 'KAPALI' and b.cikis_kaynak::text = 'KAMERA'
                  and b.tahsil_kurus = 0
                  and b.ucret_kurus = public.ucret_hesapla(b.giris_at, b.cikis_at, b.tarife_id) + 15000) then
  raise exception 'FAIL 102e: kamera yıkamalı bileti yıkamasız kapattı';
end if;

raise notice 'PASS 102: yıkama ücreti tahsilata, abonmana ve kamera çıkışının borcuna eklenir; kapanmış bilete eklenmez';

-- =====================================================================
-- 103  Ücretsiz çıkış yıkamayı da sıfırlar; yetkiler (078)
-- =====================================================================
perform pg_temp.login(u_personel);
v_bilet := public.bilet_ac('ZZ100UC1', gen_random_uuid());
perform public.bilet_yikama(v_bilet, true);
perform public.bilet_ucretsiz_cikis(v_bilet, 'DIGER', 'Deneme yıkama');
perform pg_temp.logout();
if not exists (select 1 from public.biletler where id = v_bilet and durum = 'KAPALI' and ucret_kurus = 0)
   or exists (select 1 from public.tahsilatlar where bilet_id = v_bilet) then
  raise exception 'FAIL 103a: ücretsiz çıkış yıkamayı sıfırlamadı';
end if;
-- Bağışlanan yıkama "ücret değişti" olarak yazılır (ücretsiz sürede bile:
-- otopark 0 olsa da 150 ₺ bağışlandı).
if not exists (select 1 from public.biletler where id = v_bilet and ucret_degistirildi) then
  raise exception 'FAIL 103c: bağışlanan yıkama ücret değişikliği olarak yazılmadı';
end if;

if not has_function_privilege('authenticated', 'public.bilet_yikama(uuid, boolean)', 'execute')
   or has_function_privilege('anon', 'public.bilet_yikama(uuid, boolean)', 'execute')
   or has_function_privilege('service_role', 'public.bilet_yikama(uuid, boolean)', 'execute')
   or not has_function_privilege('authenticated', 'public.bilet_ucret_onizle(uuid)', 'execute')
   or has_function_privilege('anon', 'public.bilet_ucret_onizle(uuid)', 'execute')
   or has_function_privilege('service_role', 'public.bilet_ucret_onizle(uuid)', 'execute')
   or has_function_privilege('authenticated', 'public.bilet_ucreti(public.biletler, timestamptz)', 'execute')
   or has_function_privilege('anon', 'public.bilet_ucreti(public.biletler, timestamptz)', 'execute')
   or has_function_privilege('service_role', 'public.bilet_ucreti(public.biletler, timestamptz)', 'execute') then
  raise exception 'FAIL 103b: yıkama fonksiyonlarının yetkileri yanlış';
end if;

raise notice 'PASS 103: ücretsiz çıkış yıkamayı da sıfırlar; yıkama fonksiyonları yalnızca giriş yapmış kullanıcıya, iç fiyat hiç kimseye açık değil';

-- =====================================================================
-- 104  Anlaşmalı fiyat: kur, değiştir, kaldır (080 bilet_anlasma)
--      Süre girişten sayılır; ücret anlaşma fiyatıdır (+ yıkama). Yönetici
--      haberdar edilir. Abonman, onaysız kullanıcı, 0 ₺ / 0 saat / 90 günden
--      uzun reddedilir. Kaldırınca tarife geri gelir.
-- =====================================================================
perform pg_temp.login(u_personel);
v_bilet := public.bilet_ac('ZZ104AN1', gen_random_uuid());
perform public.bilet_anlasma(v_bilet, 60000, 72);
v_ucret := public.bilet_ucret_onizle(v_bilet);
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_bilet and anlasma_kurus = 60000
                  and anlasma_bitis = giris_at + interval '72 hours'
                  and anlasma_fazla_at is null and anlasma_bildirim_at is null)
   or v_ucret is distinct from 60000 then
  raise exception 'FAIL 104a: anlaşma kurulmadı ya da önizleme anlaşma fiyatı değil (%)', v_ucret;
end if;
if not exists (select 1 from public.notifications
                where profile_id = u_yonetici and tur::text = 'ANLASMA' and govde like 'ZZ104AN1%') then
  raise exception 'FAIL 104b: Yönetici yeni anlaşmadan haberdar edilmedi';
end if;

-- Yıkama anlaşmanın üstüne eklenir.
perform pg_temp.login(u_personel);
v_n2 := public.bilet_yikama(v_bilet, true);
v_ucret := public.bilet_ucret_onizle(v_bilet);
perform public.bilet_yikama(v_bilet, false);
perform pg_temp.logout();
if v_ucret is distinct from 60000 + v_n2 then
  raise exception 'FAIL 104c: yıkama anlaşmanın üstüne eklenmedi (% / %)', v_ucret, v_n2;
end if;

perform pg_temp.login(u_personel);
begin
  perform public.bilet_anlasma(v_bilet, 0, 72);
  raise exception 'FAIL 104d: 0 ₺ anlaşma kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.bilet_anlasma(v_bilet, 60000, 0);
  raise exception 'FAIL 104d: 0 saatlik anlaşma kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.bilet_anlasma(v_bilet, 60000, 2161);
  raise exception 'FAIL 104d: 90 günden uzun anlaşma kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();

perform pg_temp.login(u_pending);
begin
  perform public.bilet_anlasma(v_bilet, 50000, 24);
  raise exception 'FAIL 104e: onaysız kullanıcı anlaşma kurdu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();

insert into public.abonmanlar (plaka, baslangic, bitis, ucret_kurus)
values ('ZZ104AB1', (now() at time zone 'Europe/Istanbul')::date - 1,
        (now() at time zone 'Europe/Istanbul')::date + 30, 100000);
perform pg_temp.login(u_personel);
v_bilet2 := public.bilet_ac('ZZ104AB1', gen_random_uuid());
begin
  perform public.bilet_anlasma(v_bilet2, 50000, 24);
  raise exception 'FAIL 104f: abonmanlı araca anlaşma kuruldu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%bonman%' then
    raise exception 'FAIL 104f: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- Kaldırma: dört sütun boşalır, ücret yine tarife.
perform pg_temp.login(u_personel);
perform public.bilet_anlasma(v_bilet, null, null);
v_ucret := public.bilet_ucret_onizle(v_bilet);
perform pg_temp.logout();
select public.ucret_hesapla(giris_at, now(), tarife_id) into v_ucret2
  from public.biletler where id = v_bilet;
if v_ucret is distinct from v_ucret2
   or exists (select 1 from public.biletler
               where id = v_bilet and (anlasma_kurus is not null or anlasma_bitis is not null
                                       or anlasma_fazla_at is not null or anlasma_bildirim_at is not null)) then
  raise exception 'FAIL 104g: anlaşma kaldırılamadı (% / %)', v_ucret, v_ucret2;
end if;

raise notice 'PASS 104: anlaşma girişten sayılır, ücret anlaşma fiyatı (+ yıkama), Yönetici haberdar; geçersiz değer, abonman ve onaysız kullanıcı reddedilir; kaldırınca tarife döner';

-- =====================================================================
-- 105  Süre dolunca: fazla süre kendiliğinden eklenmez (080)
--      Personel "Fazla süreyi ekle"ye basana kadar ücret anlaşma fiyatıdır.
--      Basınca tarife anlaşmanın bitişinden çıkışa kadar sayar. Süre
--      dolmadan eklenemez. Kamera, eklenmemiş fazla süreyi almaz.
-- =====================================================================
perform pg_temp.login(u_personel);
perform public.bilet_anlasma(v_bilet, 60000, 1);
perform pg_temp.logout();
update public.biletler
   set giris_at = now() - interval '3 hours 10 minutes',
       anlasma_bitis = now() - interval '2 hours 10 minutes'
 where id = v_bilet;

perform pg_temp.login(u_personel);
v_ucret := public.bilet_ucret_onizle(v_bilet);
v_n := public.bilet_fazla_onizle(v_bilet);
perform pg_temp.logout();
select public.ucret_hesapla(anlasma_bitis, now(), tarife_id) into v_ucret2
  from public.biletler where id = v_bilet;
if v_ucret is distinct from 60000 or v_n is distinct from v_ucret2 then
  raise exception 'FAIL 105a: süre dolunca fazla süre kendiliğinden eklendi ya da önizleme yanlış (% / % / %)',
    v_ucret, v_n, v_ucret2;
end if;

perform pg_temp.login(u_personel);
v_bilet2 := public.bilet_ac('ZZ104AN2', gen_random_uuid());
perform public.bilet_anlasma(v_bilet2, 60000, 72);
v_n := public.bilet_fazla_onizle(v_bilet2);
begin
  perform public.bilet_anlasma_fazla(v_bilet2);
  raise exception 'FAIL 105b: süre dolmadan fazla süre eklendi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%dolmadı%' then
    raise exception 'FAIL 105b: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
perform pg_temp.logout();
if v_n is distinct from 0 then
  raise exception 'FAIL 105b: süresi dolmamış anlaşmada fazla süre önizlemesi 0 değil (%)', v_n;
end if;

-- İki kez basmak bir kez sayılır.
perform pg_temp.login(u_personel);
perform public.bilet_anlasma_fazla(v_bilet);
perform public.bilet_anlasma_fazla(v_bilet);
v_ucret := public.bilet_ucret_onizle(v_bilet);
perform pg_temp.logout();
if v_ucret is distinct from 60000 + v_ucret2
   or not exists (select 1 from public.biletler where id = v_bilet and anlasma_fazla_at = now()) then
  raise exception 'FAIL 105c: fazla süre eklenmedi (% / %)', v_ucret, v_ucret2;
end if;

perform pg_temp.login(u_personel);
select b.ucret_kurus into v_n from public.bilet_kapat(v_bilet, 'NAKIT') b;
perform pg_temp.logout();
if v_n is distinct from 60000 + v_ucret2
   or (select coalesce(sum(tutar_kurus), 0) from public.tahsilatlar
        where bilet_id = v_bilet) is distinct from v_n then
  raise exception 'FAIL 105d: bilet_kapat anlaşma + fazla süreyi almadı (% / %)', v_n, v_ucret2;
end if;

perform pg_temp.login(u_personel);
begin
  perform public.bilet_anlasma(v_bilet, 50000, 24);
  raise exception 'FAIL 105e: kapanmış bilete anlaşma kuruldu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%açık değil%' then
    raise exception 'FAIL 105e: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
perform pg_temp.logout();

perform pg_temp.kamera();
v_id := public.bilet_ac('ZZ104KM1', gen_random_uuid(), 'KAMERA', now() - interval '3 hours');
perform pg_temp.logout();
perform pg_temp.login(u_personel);
perform public.bilet_anlasma(v_id, 50000, 1);
perform pg_temp.logout();
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ104KM1', gen_random_uuid(), now());
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_id and durum = 'KAPALI' and cikis_kaynak::text = 'KAMERA'
                  and tahsil_kurus = 0 and ucret_kurus = 50000) then
  raise exception 'FAIL 105f: kamera eklenmemiş fazla süreyi aldı ya da anlaşmayı yok saydı';
end if;

raise notice 'PASS 105: süre dolunca fazla süre kendiliğinden eklenmez; basınca bitişten sayar, bir kez; süre dolmadan eklenemez; kamera anlaşma fiyatıyla kapatır';

-- =====================================================================
-- 106  Süre doldu bildirimi: herkese, bir kez (080 anlasma_bildirim_gonder)
-- =====================================================================
perform pg_temp.login(u_personel);
v_id := public.bilet_ac('ZZ104BD1', gen_random_uuid());
perform public.bilet_anlasma(v_id, 40000, 1);
perform pg_temp.logout();
update public.biletler
   set giris_at = now() - interval '2 hours', anlasma_bitis = now() - interval '1 hour'
 where id = v_id;

perform public.anlasma_bildirim_gonder();
if not exists (select 1 from public.notifications
                where profile_id = u_personel and tur::text = 'ANLASMA'
                  and govde = 'ZZ104BD1: anlaşma süresi doldu')
   or not exists (select 1 from public.notifications
                   where profile_id = u_yonetici and tur::text = 'ANLASMA'
                     and govde = 'ZZ104BD1: anlaşma süresi doldu')
   or not exists (select 1 from public.biletler where id = v_id and anlasma_bildirim_at is not null) then
  raise exception 'FAIL 106a: süre doldu bildirimi Personel ve Yönetici''ye gitmedi';
end if;
select count(*) into v_n from public.notifications where govde = 'ZZ104BD1: anlaşma süresi doldu';
perform public.anlasma_bildirim_gonder();
select count(*) into v_n2 from public.notifications where govde = 'ZZ104BD1: anlaşma süresi doldu';
if v_n2 <> v_n then
  raise exception 'FAIL 106b: süre doldu bildirimi ikinci kez gitti (% → %)', v_n, v_n2;
end if;
if exists (select 1 from public.notifications where govde = 'ZZ104AN2: anlaşma süresi doldu') then
  raise exception 'FAIL 106c: süresi dolmamış anlaşma için bildirim gitti';
end if;
if public.bildirim_yonetici_turu('ANLASMA') then
  raise exception 'FAIL 106d: ANLASMA Yönetici''ye özel; Personel göremez';
end if;

raise notice 'PASS 106: süre dolunca herkese bir kez bildirim gider; süresi dolmamışa gitmez';

-- =====================================================================
-- 107  Puan anlaşma fiyatına göre sınırlı; yetkiler (080)
-- =====================================================================
select kurus_per_puan into v_n2 from public.puan_kurallari where gecerli_bitis is null;
if coalesce(v_n2, 0) = 0 then
  raise exception 'FAIL 107: aktif puan kuralı yok (PASS 25 kuralı bekler)';
end if;
insert into public.hesaplar (ad) values ('ZZ104 Puan') returning id into v_hesap;
insert into public.hesap_araclari (hesap_id, plaka) values (v_hesap, 'ZZ104PN1');
insert into public.puan_hareketleri (hesap_id, tur, puan, kural_id)
select v_hesap, 'DUZELTME', 60000 / v_n2 + 10, k.id from public.puan_kurallari k
 where k.gecerli_bitis is null;

perform pg_temp.login(u_personel);
v_bilet := public.bilet_ac('ZZ104PN1', gen_random_uuid());
perform public.bilet_anlasma(v_bilet, 60000, 24);
begin
  perform public.puan_kullan(v_bilet, 60000 / v_n2 + 1);
  raise exception 'FAIL 107a: puan anlaşma fiyatını aştı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%en fazla%' then
    raise exception 'FAIL 107a: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
-- Yeni girmiş araç tarifeyle ücretsiz sürede olurdu; anlaşmayla 600 ₺'ye puan kullanılır.
v_n := public.puan_kullan(v_bilet, 60000 / v_n2);
perform pg_temp.logout();
if v_n is distinct from (60000 / v_n2) * v_n2 then
  raise exception 'FAIL 107b: anlaşmalı bilette puan kullanılamadı (%)', v_n;
end if;

-- Puan kullanılmışken anlaşmayı kaldırmak ücreti puanın altına düşürür: reddedilir.
perform pg_temp.login(u_personel);
begin
  perform public.bilet_anlasma(v_bilet, null, null);
  raise exception 'FAIL 107c: puan ücretten fazlayken anlaşma kaldırıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%puan%' then
    raise exception 'FAIL 107c: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
perform pg_temp.logout();

foreach v_txt in array array['public.bilet_anlasma(uuid, integer, integer)',
                             'public.bilet_anlasma_fazla(uuid)',
                             'public.bilet_fazla_onizle(uuid)'] loop
  if not has_function_privilege('authenticated', v_txt, 'execute')
     or has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('service_role', v_txt, 'execute') then
    raise exception 'FAIL 107d: % yalnızca giriş yapmış kullanıcıya açık olmalı', v_txt;
  end if;
end loop;
if has_function_privilege('authenticated', 'public.anlasma_bildirim_gonder()', 'execute')
   or has_function_privilege('anon', 'public.anlasma_bildirim_gonder()', 'execute')
   or has_function_privilege('service_role', 'public.anlasma_bildirim_gonder()', 'execute') then
  raise exception 'FAIL 107d: anlasma_bildirim_gonder kimseye açık olmamalı';
end if;

raise notice 'PASS 107: puan anlaşma fiyatına göre sınırlı, kaldırma puanın altına düşüremez; anlaşma fonksiyonları yalnızca giriş yapmış kullanıcıya, bildirim işi kimseye açık değil';

-- =====================================================================
-- 108  Süre aşımı: normal bilet ilk kademede durur (082)
--      Sahip (27.11): kademeli tarifede normal bilet ilk kademenin fiyatını
--      geçmez; tarifenin tam fiyatı ancak bir kişi "Onayla"ya basınca
--      alınır. Süreli / sabit tarife ve abonman değişmez.
--      Bilinen kademeli tarife: 5 dk ücretsiz, ≤2 sa 200 ₺, ≤6 sa 450 ₺,
--      ≤24 sa 700 ₺. Biletler açıldıkları tarifeyle fiyatlanır, bu yüzden
--      tarife PASS 111 sonunda eskisine döner.
-- =====================================================================
select * into v_tr from public.tarifeler where gecerli_bitis is null;
if v_tr.tur::text = 'KADEMELI' then
  raise exception 'FAIL 108: fixture — PASS 75''ten sonra etkin tarife kademeli olmamalı';
end if;

-- Önce eski (kademeli olmayan) tarifeyle bir bilet: tavan ona uygulanmaz.
perform pg_temp.login(u_personel);
v_id2 := public.bilet_ac('ZZ108SB1', gen_random_uuid());
perform pg_temp.logout();
update public.biletler set giris_at = now() - interval '10 hours' where id = v_id2;

perform pg_temp.login(u_yonetici);
perform public.tarife_guncelle(5, 0, 0, 0, 20000, 'KADEMELI', 0,
  '[{"dakika":120,"kurus":20000},{"dakika":360,"kurus":45000},{"dakika":1440,"kurus":70000}]'::jsonb,
  null);
perform pg_temp.logout();

perform pg_temp.login(u_personel);
v_bilet  := public.bilet_ac('ZZ108AS1', gen_random_uuid());
v_bilet2 := public.bilet_ac('ZZ108AS2', gen_random_uuid());
v_id     := public.bilet_ac('ZZ108AS3', gen_random_uuid());
perform pg_temp.logout();
update public.biletler set giris_at = now() - interval '5 hours' where id in (v_bilet, v_id);
update public.biletler set giris_at = now() - interval '1 hour'  where id = v_bilet2;

-- (a) 5 saat: tarife 450 ₺ der, ücret 200 ₺'de durur; rapor ikisini de verir.
perform pg_temp.login(u_personel);
v_ucret := public.bilet_ucret_onizle(v_bilet);
select o.ilk_kurus, o.tam_kurus into v_n, v_n2 from public.bilet_asim_onizle(v_bilet) o;
select a.ucret_kurus, a.asim_bekliyor into v_ucret2, v_bool
  from public.acik_bilet_ara('ZZ108AS1') a where a.id = v_bilet;
perform pg_temp.logout();
if v_ucret is distinct from 20000 or v_n is distinct from 20000 or v_n2 is distinct from 45000
   or v_ucret2 is distinct from 20000 or v_bool is distinct from true then
  raise exception 'FAIL 108a: ilk kademede durmadı ya da rapor yanlış (% / % / % / % / %)',
    v_ucret, v_n, v_n2, v_ucret2, v_bool;
end if;

-- (b) 1 saat: ilk kademenin içinde — aşım yok, rapor boş.
perform pg_temp.login(u_personel);
v_ucret := public.bilet_ucret_onizle(v_bilet2);
select count(*) into v_n from public.bilet_asim_onizle(v_bilet2);
select a.asim_bekliyor into v_bool from public.acik_bilet_ara('ZZ108AS2') a where a.id = v_bilet2;
perform pg_temp.logout();
if v_ucret is distinct from 20000 or v_n <> 0 or v_bool is distinct from false then
  raise exception 'FAIL 108b: ilk kademe içindeki bilette aşım görüldü (% / % / %)', v_ucret, v_n, v_bool;
end if;

-- (c) Kademeli olmayan tarifeyle açılmış bilet: tarife ne diyorsa o.
perform pg_temp.login(u_personel);
v_ucret := public.bilet_ucret_onizle(v_id2);
select count(*) into v_n from public.bilet_asim_onizle(v_id2);
perform pg_temp.logout();
select public.ucret_hesapla(giris_at, now(), tarife_id) into v_ucret2 from public.biletler where id = v_id2;
if v_ucret is distinct from v_ucret2 or v_n <> 0 then
  raise exception 'FAIL 108c: kademeli olmayan tarifeye tavan uygulandı (% / % / %)', v_ucret, v_ucret2, v_n;
end if;

raise notice 'PASS 108: kademeli tarifede normal bilet ilk kademede durur, rapor tarifenin tam fiyatını verir; ilk kademe içi ve kademesiz tarife değişmez';

-- =====================================================================
-- 109  Karar: "Onayla" tam fiyat, "200 ₺ kalsın" ilk kademe (082)
--      Personel ve Yönetici verir; bir kez. Yönetici her iki kararda
--      haberdar. Aşım yoksa ya da kullanıcı onaysızsa reddedilir.
-- =====================================================================
perform pg_temp.login(u_personel);
perform public.bilet_asim_karar(v_bilet, true);
v_ucret := public.bilet_ucret_onizle(v_bilet);
perform public.bilet_asim_karar(v_id, false);
v_ucret2 := public.bilet_ucret_onizle(v_id);
select a.asim_bekliyor into v_bool from public.acik_bilet_ara('ZZ108AS3') a where a.id = v_id;
perform pg_temp.logout();
if v_ucret is distinct from 45000
   or not exists (select 1 from public.biletler
                   where id = v_bilet and asim_karar = 'TAM'
                     and asim_karar_by = u_personel and asim_karar_at = now()) then
  raise exception 'FAIL 109a: "Onayla" tam fiyatı getirmedi (%)', v_ucret;
end if;
if v_ucret2 is distinct from 20000 or v_bool is distinct from false
   or not exists (select 1 from public.biletler where id = v_id and asim_karar = 'ILK') then
  raise exception 'FAIL 109b: "ilk kademe kalsın" ücreti değiştirdi ya da bekliyor görünüyor (% / %)', v_ucret2, v_bool;
end if;
if (select count(*) from public.notifications
     where profile_id = u_yonetici and tur::text = 'SURE_ASIMI'
       and (govde like 'ZZ108AS1%' or govde like 'ZZ108AS3%')) <> 2 then
  raise exception 'FAIL 109c: Yönetici iki karardan da haberdar edilmedi';
end if;
if not public.bildirim_yonetici_turu('SURE_ASIMI') then
  raise exception 'FAIL 109c: SURE_ASIMI Yönetici''ye özel olmalı';
end if;

perform pg_temp.login(u_yonetici);
begin
  perform public.bilet_asim_karar(v_bilet, false);
  raise exception 'FAIL 109d: karar ikinci kez değişti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%zaten%' then
    raise exception 'FAIL 109d: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
begin
  perform public.bilet_asim_karar(v_bilet2, true);
  raise exception 'FAIL 109e: aşımı olmayan bilete karar verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%aşım%' then
    raise exception 'FAIL 109e: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
perform pg_temp.logout();

perform pg_temp.login(u_pending);
begin
  perform public.bilet_asim_karar(v_bilet2, true);
  raise exception 'FAIL 109f: onaysız kullanıcı karar verdi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();

raise notice 'PASS 109: "Onayla" tam fiyatı, "ilk kademe kalsın" 200 ₺''yi bırakır; bir kez, Yönetici haberdar; aşımsız bilet ve onaysız kullanıcı reddedilir';

-- =====================================================================
-- 110  Karar verilmeden çıkış yok (082 bilet_kapat)
--      Ödemeli ve ödemesiz çıkış, aşım bekleyen bilette reddedilir. Elle
--      ücret (sebepli) bir karardır. Karar verilmiş ya da aşımsız bilet
--      eskisi gibi çıkar.
-- =====================================================================
perform pg_temp.login(u_personel);
v_id2 := public.bilet_ac('ZZ108AS4', gen_random_uuid());
perform pg_temp.logout();
update public.biletler set giris_at = now() - interval '5 hours' where id = v_id2;

perform pg_temp.login(u_personel);
begin
  perform public.bilet_kapat(v_id2, 'NAKIT');
  raise exception 'FAIL 110a: aşım kararı verilmeden ödemeli çıkış yapıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%önce karar%' then
    raise exception 'FAIL 110a: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
begin
  perform public.bilet_kapat(v_id2, null, null, null, null, 'MOBIL', false);
  raise exception 'FAIL 110a: aşım kararı verilmeden ödemesiz çıkış yapıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%önce karar%' then
    raise exception 'FAIL 110a: beklenmeyen hata (ödemesiz) (%)', sqlerrm;
  end if;
end;

select b.ucret_kurus into v_n  from public.bilet_kapat(v_bilet, 'NAKIT') b;
select b.ucret_kurus into v_n2 from public.bilet_kapat(v_id, 'NAKIT') b;
select b.ucret_kurus into v_ucret from public.bilet_kapat(v_bilet2, 'NAKIT') b;
select b.ucret_kurus into v_ucret2 from public.bilet_kapat(v_id2, 'NAKIT', 30000, 'ZZ108 elle') b;
perform pg_temp.logout();
if v_n is distinct from 45000 or v_n2 is distinct from 20000 or v_ucret is distinct from 20000
   or v_ucret2 is distinct from 30000 then
  raise exception 'FAIL 110b: kararlı / aşımsız / elle ücretli çıkış yanlış (% / % / % / %)',
    v_n, v_n2, v_ucret, v_ucret2;
end if;

raise notice 'PASS 110: aşım kararı verilmeden ödemeli ya da ödemesiz çıkış yok; karar, elle ücret ve aşımsız bilet eskisi gibi çıkar';

-- =====================================================================
-- 111  Kameranın kapattığı bilet (082)
--      Kamera karar veremez: bileti ilk kademe fiyatıyla, ödemesiz kapatır.
--      Ödeme toplanmadan karar verilmeli (bilet_tahsil reddeder). Karar
--      kapanmış bilette yalnızca ücreti değiştirir (koruma istisnası);
--      kendi vardiyası ya da Yönetici. Yetkiler.
-- =====================================================================
perform pg_temp.kamera();
v_id := public.bilet_ac('ZZ108KMA', gen_random_uuid(), 'KAMERA', now() - interval '5 hours');
perform public.kamera_cikis_bildir('ZZ108KMA', gen_random_uuid(), now());
perform pg_temp.logout();
if not exists (select 1 from public.biletler
                where id = v_id and durum = 'KAPALI' and cikis_kaynak::text = 'KAMERA'
                  and tahsil_kurus = 0 and ucret_kurus = 20000 and asim_karar is null) then
  raise exception 'FAIL 111a: kamera bileti ilk kademe fiyatıyla ödemesiz kapatmadı';
end if;

perform pg_temp.login(u_personel);
begin
  perform public.bilet_tahsil(v_id, 'NAKIT');
  raise exception 'FAIL 111b: aşım kararı verilmeden ödeme toplandı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like '%önce karar%' then
    raise exception 'FAIL 111b: beklenmeyen hata (%)', sqlerrm;
  end if;
end;
perform pg_temp.logout();

-- Başka vardiyadaki Personel karar veremez (vardiyası yoksa sınanır).
perform pg_temp.login(u_personel2);
if public.acik_vardiyam() is null then
  begin
    perform public.bilet_asim_karar(v_id, true);
    raise exception 'FAIL 111c: başka vardiyadaki Personel kapanmış bilete karar verdi';
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
    if sqlerrm not like '%yetki%' then
      raise exception 'FAIL 111c: beklenmeyen hata (%)', sqlerrm;
    end if;
  end;
end if;
perform pg_temp.logout();

perform pg_temp.login(u_personel);
perform public.bilet_asim_karar(v_id, true);
v_n := public.bilet_tahsil(v_id, 'NAKIT');
perform pg_temp.logout();
if v_n is distinct from 45000
   or not exists (select 1 from public.biletler
                   where id = v_id and durum = 'KAPALI' and asim_karar = 'TAM'
                     and ucret_kurus = 45000 and tahsil_kurus = 45000
                     and cikis_at is not null and ucret_degistirildi = false) then
  raise exception 'FAIL 111d: kapanmış bilette "Onayla" tam fiyatı getirmedi (%)', v_n;
end if;

-- Koruma: istisna yalnızca kendi bileti için, yalnızca karar ve ücret.
begin
  update public.biletler set ucret_kurus = 1 where id = v_id;
  raise exception 'FAIL 111e: kapanmış bilet istisnasız değişti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

foreach v_txt in array array['public.bilet_asim_karar(uuid, boolean)',
                             'public.bilet_asim_onizle(uuid)',
                             'public.bilet_kapat(uuid, public.odeme_yontemi, integer, text, text, public.kaynak, boolean)',
                             'public.bilet_tahsil(uuid, public.odeme_yontemi)',
                             'public.acik_bilet_ara(text)'] loop
  if not has_function_privilege('authenticated', v_txt, 'execute')
     or has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('service_role', v_txt, 'execute') then
    raise exception 'FAIL 111f: % yalnızca giriş yapmış kullanıcıya açık olmalı', v_txt;
  end if;
end loop;
foreach v_txt in array array['public.ilk_kademe_kurus(uuid)',
                             'public.bilet_asim_bekliyor(public.biletler, timestamptz)'] loop
  if has_function_privilege('authenticated', v_txt, 'execute')
     or has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('service_role', v_txt, 'execute') then
    raise exception 'FAIL 111f: % kimseye açık olmamalı', v_txt;
  end if;
end loop;

-- Tarife eskisine döner (yukarıdaki biletler kendi tarifeleriyle kalır).
perform pg_temp.login(u_yonetici);
perform public.tarife_guncelle(v_tr.ucretsiz_dakika, v_tr.ilk_saat_kurus, v_tr.sonraki_saat_kurus,
  v_tr.gunluk_tavan_kurus, v_tr.kayip_bilet_kurus, v_tr.tur, v_tr.sabit_kurus, v_tr.kademeler,
  v_tr.yikama_kurus);
perform pg_temp.logout();

raise notice 'PASS 111: kamera ilk kademe fiyatıyla kapatır; karar verilmeden ödeme toplanmaz; kapanmış bilette karar yalnızca ücreti değiştirir, kendi vardiyası; yetkiler';

-- =====================================================================
-- 112-115  Abonman bitiş bildirimi (083, sahip 27.11)
--
--   Personel ve Yönetici ikisi de bilgilenir: bitişe 4 gün kala ve son gün.
--   Yenilemeden sonra (aynı satır, bitiş ileri gider) bildirim yeniden gelir —
--   eskiden bağlantıya bakan "bir kez, sonsuza dek" kontrolü bunu engelliyordu.
--   Alıcılar o an okunur: etkin, rolü olan ve tercihini kapatmamış ilk
--   Yönetici ve ilk Personel.
-- =====================================================================

perform pg_temp.logout();
v_gun := (now() at time zone 'Europe/Istanbul')::date;

-- 112: Personel'e de gider; fonksiyon kimseye açık değil.
if public.bildirim_yonetici_turu('ABONMAN_BITIYOR') then
  raise exception 'FAIL 112a: ABONMAN_BITIYOR hâlâ yalnızca Yönetici türü';
end if;
if to_regprocedure('public.abonman_bitis_bildirimleri(date)') is null then
  raise exception 'FAIL 112b: abonman_bitis_bildirimleri(date) yok';
end if;
if has_function_privilege('authenticated', 'public.abonman_bitis_bildirimleri(date)', 'execute')
   or has_function_privilege('anon', 'public.abonman_bitis_bildirimleri(date)', 'execute')
   or has_function_privilege('service_role', 'public.abonman_bitis_bildirimleri(date)', 'execute') then
  raise exception 'FAIL 112c: abonman_bitis_bildirimleri kimseye açık olmamalı';
end if;
raise notice 'PASS 112: ABONMAN_BITIYOR herkese; bildirim fonksiyonu kapalı';

-- 113: 3 gün kala — iki rol de bir kez.
select p.id into v_id from public.profiles p
 where p.rol = 'YONETICI' and p.durum = 'ACTIVE'
   and coalesce(p.notif_prefs ->> 'ABONMAN_BITIYOR', 'true') <> 'false'
 order by p.id limit 1;
select p.id into v_id2 from public.profiles p
 where p.rol = 'PERSONEL' and p.durum = 'ACTIVE'
   and coalesce(p.notif_prefs ->> 'ABONMAN_BITIYOR', 'true') <> 'false'
 order by p.id limit 1;
if v_id is null or v_id2 is null then
  raise exception 'FAIL 113: etkin bir Yönetici ve bir Personel bulunamadı (% / %)', v_id, v_id2;
end if;

insert into public.abonmanlar (plaka, musteri_ad, baslangic, bitis, ucret_kurus, yenileme_gunu)
values ('ZZ113AB1', 'Bitis Test', v_gun - 27, v_gun + 3, 100000,
        extract(day from v_gun + 3)::int)
returning id into v_abonman;

perform public.abonman_bitis_bildirimleri(v_gun);
select count(*) into v_n from public.notifications n
 where n.tur = 'ABONMAN_BITIYOR' and n.link = '/abonman/' || v_abonman
   and n.baslik = 'Abonman bitiyor' and n.profile_id = v_id;
select count(*) into v_n2 from public.notifications n
 where n.tur = 'ABONMAN_BITIYOR' and n.link = '/abonman/' || v_abonman
   and n.baslik = 'Abonman bitiyor' and n.profile_id = v_id2;
if v_n <> 1 or v_n2 <> 1 then
  raise exception 'FAIL 113a: 3 gün kala Yönetici % / Personel % bildirim (1 / 1 beklenir)', v_n, v_n2;
end if;
select n.govde into v_txt from public.notifications n
 where n.link = '/abonman/' || v_abonman and n.profile_id = v_id;
if v_txt not like 'ZZ113AB1%' || to_char(v_gun + 3, 'DD.MM.YYYY') || '%' then
  raise exception 'FAIL 113b: bildirim metni beklenmedik: %', v_txt;
end if;

perform public.abonman_bitis_bildirimleri(v_gun);
select count(*) into v_n from public.notifications n
 where n.tur = 'ABONMAN_BITIYOR' and n.link = '/abonman/' || v_abonman and n.profile_id = v_id;
if v_n <> 1 then
  raise exception 'FAIL 113c: ikinci çalıştırma bildirimi tekrarladı (%)', v_n;
end if;
raise notice 'PASS 113: bitişe 3 gün kala Yönetici ve Personel bir kez bilgilenir';

-- 114: son gün bir kez; 6 gün kala hiç.
update public.abonmanlar set bitis = v_gun where id = v_abonman;
perform public.abonman_bitis_bildirimleri(v_gun);
perform public.abonman_bitis_bildirimleri(v_gun);
select count(*) into v_n from public.notifications n
 where n.tur = 'ABONMAN_BITIYOR' and n.link = '/abonman/' || v_abonman
   and n.baslik = 'Abonman bugün bitiyor' and n.profile_id = v_id2;
if v_n <> 1 then
  raise exception 'FAIL 114a: son gün Personel % bildirim aldı (1 beklenir)', v_n;
end if;

insert into public.abonmanlar (plaka, musteri_ad, baslangic, bitis, ucret_kurus, yenileme_gunu)
values ('ZZ114AB2', 'Bitis Test 2', v_gun - 24, v_gun + 6, 100000,
        extract(day from v_gun + 6)::int)
returning id into v_id;
perform public.abonman_bitis_bildirimleri(v_gun);
if exists (select 1 from public.notifications n where n.link = '/abonman/' || v_id) then
  raise exception 'FAIL 114b: 6 gün kala bildirim gitti (pencere 4 gün)';
end if;
raise notice 'PASS 114: son gün "bugün bitiyor" bir kez; 4 günden uzakta bildirim yok';

-- 115: yenilemeden sonra bildirim yeniden gelir (eski hata).
update public.abonmanlar set bitis = v_gun + 33 where id = v_abonman;
select count(*) into v_n2 from public.notifications n
 where n.link = '/abonman/' || v_abonman and n.baslik = 'Abonman bitiyor' and n.profile_id = v_id2;
perform public.abonman_bitis_bildirimleri(v_gun + 30);
select count(*) into v_n from public.notifications n
 where n.link = '/abonman/' || v_abonman and n.baslik = 'Abonman bitiyor' and n.profile_id = v_id2;
if v_n <> v_n2 + 1 then
  raise exception 'FAIL 115a: yenilenen abonman için bildirim gelmedi (% → %)', v_n2, v_n;
end if;

v_txt := pg_get_functiondef('public.run_gunluk_bakim()'::regprocedure);
if position('abonman_bitis_bildirimleri' in v_txt) = 0 then
  raise exception 'FAIL 115b: run_gunluk_bakim abonman_bitis_bildirimleri''ni çağırmıyor';
end if;
if position('notify_yonetici(''ABONMAN_BITIYOR''' in v_txt) > 0 then
  raise exception 'FAIL 115c: run_gunluk_bakim eski 7 günlük Yönetici bildirimini hâlâ gönderiyor';
end if;
raise notice 'PASS 115: yenilemeden sonra bildirim yeniden gelir; gece işi yeni fonksiyonu çağırır';

-- =====================================================================
-- 116-120  Ortak terminal: isim + PIN ile devir (084, sahip 28.11)
--
--   Gündüz ve gece personeli TEK el terminalini kullanır. Terminal bir kez
--   Yönetici tarafından kaydedilir (64 hex gizli anahtar, yalnızca sha256'sı
--   saklanır — 036 kamera deseni). Personel adını seçip 4 haneli PIN girer;
--   PIN'i terminal-giris Edge Function'ı service_role ile doğrular ve o an
--   kasa vardiyası yeni kişiye DEVREDİLİR: eski vardiya sayımsız 'DEVIR' ile
--   kapanır, yenisi kasadaki beklenen nakitle açılır.
--   Testler canlı veriye dayanmaz: rolleri ve açık vardiyayı kendisi kurar.
-- =====================================================================

perform pg_temp.logout();
update public.profiles set rol = 'YONETICI', durum = 'ACTIVE' where id = u_yonetici;
update public.profiles set rol = 'PERSONEL', durum = 'ACTIVE' where id = u_personel;

-- 116: tablolar ve fonksiyonlar yalnızca kendi kapısından açık.
if to_regclass('public.terminaller') is null or to_regclass('public.personel_pin') is null then
  raise exception 'FAIL 116a: terminaller / personel_pin tablosu yok (084 çalıştı mı?)';
end if;
if has_table_privilege('anon', 'public.personel_pin', 'SELECT')
   or has_table_privilege('authenticated', 'public.personel_pin', 'SELECT')
   or has_table_privilege('service_role', 'public.personel_pin', 'SELECT')
   or has_table_privilege('authenticated', 'public.personel_pin', 'UPDATE') then
  raise exception 'FAIL 116b: personel_pin bir istemci rolüne açık';
end if;
if has_table_privilege('anon', 'public.terminaller', 'SELECT')
   or has_column_privilege('authenticated', 'public.terminaller', 'gizli_hash', 'SELECT')
   or has_table_privilege('authenticated', 'public.terminaller', 'INSERT')
   or has_table_privilege('authenticated', 'public.terminaller', 'UPDATE') then
  raise exception 'FAIL 116c: terminaller gizli_hash''i ya da yazmayı istemciye açıyor';
end if;
foreach v_txt in array array[
  'public.terminal_personel_listesi(text)',
  'public.terminal_pin_dogrula(text, uuid, text)',
  'public.personel_pin_olustur(uuid, text, uuid)'
] loop
  if has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('authenticated', v_txt, 'execute')
     or not has_function_privilege('service_role', v_txt, 'execute') then
    raise exception 'FAIL 116d: % yalnızca service_role''e açık olmalı', v_txt;
  end if;
end loop;
foreach v_txt in array array[
  'public.terminal_kaydet(text)', 'public.terminal_kaldir(uuid)',
  'public.pin_ayarla(uuid, text)'
] loop
  if has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('service_role', v_txt, 'execute')
     or not has_function_privilege('authenticated', v_txt, 'execute') then
    raise exception 'FAIL 116e: % yalnızca authenticated''a açık olmalı', v_txt;
  end if;
end loop;
if has_function_privilege('authenticated', 'public.vardiya_devret(uuid)', 'execute')
   or has_function_privilege('service_role', 'public.vardiya_devret(uuid)', 'execute') then
  raise exception 'FAIL 116f: vardiya_devret istemciye açık';
end if;
raise notice 'PASS 116: terminal ve PIN tabloları kapalı; her fonksiyon yalnızca kendi rolüne açık';

-- 117: terminali yalnızca Yönetici kaydeder; anahtarın kendisi saklanmaz.
perform pg_temp.login(u_personel);
begin
  perform public.terminal_kaydet('Personel terminali');
  raise exception 'FAIL 117a: Personel terminal kaydetti';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

perform pg_temp.login(u_yonetici);
v_json := public.terminal_kaydet('Gişe terminali');
v_txt  := v_json ->> 'gizli';
v_id   := (v_json ->> 'id')::uuid;
if v_txt !~ '^[0-9a-f]{64}$' then
  raise exception 'FAIL 117b: gizli anahtar 64 hex değil: %', v_txt;
end if;
perform pg_temp.logout();
v_txt2 := encode(sha256(convert_to(v_txt, 'UTF8')), 'hex');
if not exists (select 1 from public.terminaller where id = v_id and gizli_hash = v_txt2 and aktif) then
  raise exception 'FAIL 117c: terminal sha256 ile saklanmamış';
end if;
if exists (select 1 from public.terminaller where gizli_hash = v_txt) then
  raise exception 'FAIL 117d: gizli anahtarın kendisi saklanmış';
end if;
raise notice 'PASS 117: terminali yalnızca Yönetici kaydeder; yalnızca sha256 saklanır';

-- 120 (önce, çünkü 118-119 PIN'e dayanıyor): PIN'i yalnızca Yönetici koyar.
perform pg_temp.login(u_personel);
begin
  perform public.pin_ayarla(u_personel, '1234');
  raise exception 'FAIL 120a: Personel PIN koydu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.login(u_yonetici);
foreach v_txt3 in array array['123', '12345', '12a4', ''] loop
  begin
    perform public.pin_ayarla(u_personel, v_txt3);
    raise exception 'FAIL 120b: geçersiz PIN kabul edildi: "%"', v_txt3;
  exception when others then
    if sqlerrm like 'FAIL%' then raise; end if;
  end;
end loop;
begin
  perform public.pin_ayarla(u_yonetici, '1234');
  raise exception 'FAIL 120c: Yönetici hesabına terminal PIN''i kondu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform public.pin_ayarla(u_personel, '4321');
perform pg_temp.logout();
select pin_hash into v_txt3 from public.personel_pin where profile_id = u_personel;
if v_txt3 is null or v_txt3 = '4321' or v_txt3 not like '$2%' then
  raise exception 'FAIL 120d: PIN bcrypt ile saklanmamış';
end if;
raise notice 'PASS 120: PIN''i yalnızca Yönetici koyar; tam 4 rakam; bcrypt ile saklanır';

-- 118: doğrulama — doğru PIN e-postayı verir, yanlış sayılır, 5'te kilit.
perform pg_temp.kamera();   -- service_role, JWT yok: Edge Function'ın kendisi
select count(*) into v_n from public.terminal_personel_listesi(v_txt2) l where l.id = u_personel;
if v_n <> 1 then
  raise exception 'FAIL 118a: PIN''li personel terminal listesinde yok';
end if;
begin
  perform * from public.terminal_personel_listesi(repeat('0', 64));
  raise exception 'FAIL 118b: tanınmayan terminal listeyi aldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;

v_json := public.terminal_pin_dogrula(v_txt2, u_personel, '0000');
if (v_json ->> 'ok')::boolean then
  raise exception 'FAIL 118c: yanlış PIN kabul edildi';
end if;
perform pg_temp.logout();
if (select hatali from public.personel_pin where profile_id = u_personel) <> 1 then
  raise exception 'FAIL 118d: yanlış PIN sayılmadı (dönüş exception ile geri alınmış olabilir)';
end if;

select count(*) into v_n2 from public.notifications
 where tur = 'PIN_KILIT' and profile_id = u_yonetici;
perform pg_temp.kamera();
for v_n in 1..4 loop
  v_json := public.terminal_pin_dogrula(v_txt2, u_personel, '0000');
end loop;
-- Kilitliyken DOĞRU PIN de reddedilir.
v_json := public.terminal_pin_dogrula(v_txt2, u_personel, '4321');
if (v_json ->> 'ok')::boolean then
  raise exception 'FAIL 118e: kilitli kişi doğru PIN ile girdi';
end if;
perform pg_temp.logout();
if (select kilit_bitis from public.personel_pin where profile_id = u_personel)
     not between now() + interval '14 minutes' and now() + interval '16 minutes' then
  raise exception 'FAIL 118f: 5 hatalı denemede 15 dakikalık kilit yok';
end if;
select count(*) into v_n from public.notifications
 where tur = 'PIN_KILIT' and profile_id = u_yonetici;
if v_n <> v_n2 + 1 then
  raise exception 'FAIL 118g: kilit Yöneticiye bildirilmedi (% → %)', v_n2, v_n;
end if;

-- Kilit kalkınca doğru PIN e-postayı döner ve sayaç sıfırlanır.
update public.personel_pin set kilit_bitis = now() - interval '1 minute' where profile_id = u_personel;
perform pg_temp.kamera();
v_json := public.terminal_pin_dogrula(v_txt2, u_personel, '4321');
if not coalesce((v_json ->> 'ok')::boolean, false)
   or v_json ->> 'email' <> 'test_personel@otopark.local' then
  raise exception 'FAIL 118h: doğru PIN e-postayı vermedi: %', v_json;
end if;
perform pg_temp.logout();
if (select hatali from public.personel_pin where profile_id = u_personel) <> 0 then
  raise exception 'FAIL 118i: başarılı girişte sayaç sıfırlanmadı';
end if;

-- Kaldırılan terminal artık hiçbir şey yapamaz.
perform pg_temp.login(u_yonetici);
v_json2 := public.terminal_kaydet('Geçici terminal');
perform public.terminal_kaldir((v_json2 ->> 'id')::uuid);
perform pg_temp.kamera();
v_json2 := public.terminal_pin_dogrula(
  encode(sha256(convert_to(v_json2 ->> 'gizli', 'UTF8')), 'hex'), u_personel, '4321');
if coalesce((v_json2 ->> 'ok')::boolean, false) then
  raise exception 'FAIL 118j: kaldırılan terminal PIN doğruladı';
end if;
perform pg_temp.logout();
raise notice 'PASS 118: doğru PIN girer; yanlış sayılır; 5 hatada 15 dk kilit + Yönetici uyarısı; kaldırılan terminal ölü';

-- 119: devir — başka kişiye geçiş eski vardiyayı sayımsız kapatır, yenisini
--      kasadaki beklenen nakitle açar. Aynı kişi hiçbir şeyi değiştirmez.
perform pg_temp.logout();
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE' where kapanis_at is null;
insert into public.vardiyalar (personel_id, acilis_nakit_kurus, otomatik_acildi)
values (u_yonetici, 5000, false) returning id into v_eski_vardiya;
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id)
values ('BILET', null, 2500, 'NAKIT', v_eski_vardiya);
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id)
values ('BILET', null, 9900, 'KREDI_KARTI', v_eski_vardiya);

perform pg_temp.kamera();
v_json := public.terminal_pin_dogrula(v_txt2, u_personel, '4321');
perform pg_temp.logout();
if not coalesce((v_json ->> 'ok')::boolean, false) then
  raise exception 'FAIL 119a: devir girişi reddedildi: %', v_json;
end if;
select * into v_rec from public.vardiyalar where id = v_eski_vardiya;
if v_rec.kapanis_at is null or v_rec.kapanis_kaynak <> 'DEVIR'
   or v_rec.sayilan_nakit_kurus is not null or v_rec.fark_kurus is not null
   or v_rec.beklenen_nakit_kurus <> 7500 then
  raise exception 'FAIL 119b: eski vardiya DEVIR/sayımsız/7500 ile kapanmadı: % % % %',
    v_rec.kapanis_kaynak, v_rec.sayilan_nakit_kurus, v_rec.fark_kurus, v_rec.beklenen_nakit_kurus;
end if;
select * into v_rec from public.vardiyalar where kapanis_at is null;
if v_rec.personel_id is distinct from u_personel or v_rec.acilis_nakit_kurus <> 7500
   or v_rec.otomatik_acildi then
  raise exception 'FAIL 119c: yeni vardiya personel/7500 ile açılmadı: % %',
    v_rec.personel_id, v_rec.acilis_nakit_kurus;
end if;
v_vardiya := v_rec.id;
if not exists (select 1 from public.audit_log
                where action = 'vardiya_devir' and row_id = v_vardiya and actor = u_personel) then
  raise exception 'FAIL 119d: devir audit satırı kişiyle yazılmadı';
end if;

perform pg_temp.kamera();
v_json := public.terminal_pin_dogrula(v_txt2, u_personel, '4321');
perform pg_temp.logout();
if (select id from public.vardiyalar where kapanis_at is null) <> v_vardiya then
  raise exception 'FAIL 119e: aynı kişinin tekrar girişi vardiyayı değiştirdi';
end if;

-- Devirden sonra yeni kişi kendi vardiyasında çalışır (own-shift kapısı).
perform pg_temp.login(u_personel);
if public.acik_vardiyam() <> v_vardiya then
  raise exception 'FAIL 119f: acik_vardiyam yeni vardiyayı göstermiyor';
end if;
perform pg_temp.logout();
raise notice 'PASS 119: PIN ile devir — eski vardiya DEVIR (sayımsız, beklenen yazılı), yenisi kasadaki nakitle açılır';

-- =====================================================================
-- 121-124  Vardiya kendi kendine döner (085, sahip 28.11)
--
--   Kasada HER ZAMAN açık bir vardiya olur: vardiyasız tahsilat hiçbir
--   sayıma girmiyordu. Devirde ve otomatik kapanışta kesedeki para (beklenen)
--   sonraki vardiyaya taşınır; Yönetici sayıp kapattığında sonraki vardiya
--   onun kesede bıraktığı tutarla hemen açılır. Her personelin vardiya
--   saatleri hesabında durur; bitişten 15 dk sonra devir olmamışsa o
--   personele bir kez hatırlatma gider.
-- =====================================================================

perform pg_temp.logout();
update public.profiles set rol = 'YONETICI', durum = 'ACTIVE' where id = u_yonetici;
update public.profiles set rol = 'PERSONEL', durum = 'ACTIVE' where id = u_personel;

-- 121: açık vardiya yoksa gece işi hemen açar (günde bir kez kuralı yok);
--      sayımsız kapanmış vardiyanın beklenen nakdi taşınır.
--      run_vardiya_otomatik_ac son kapanan vardiyaya bakar (kapanis_at,
--      sonra acilis_at). Bu dosyada now() sabit: canlı vardiya ve önceki
--      test vardiyaları da now()'da kapanır. Sınanan satır bu yüzden birer
--      saniye ileri kapanır (121b, 121d, 123b) — eşitlikte başkası seçilmesin.
update public.otopark_ayarlari set vardiya_otomatik_saat = null, vardiya_acilis_nakit_kurus = 1111 where id = 1;
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE' where kapanis_at is null;
insert into public.vardiyalar (personel_id, acilis_nakit_kurus, otomatik_acildi, acilis_at)
values (u_personel, 4000, false, now() - interval '3 hours') returning id into v_eski_vardiya;
update public.vardiyalar
   set kapanis_at = now() + interval '1 second', kapanis_kaynak = 'DEVIR',
       beklenen_nakit_kurus = 4200
 where id = v_eski_vardiya;

perform public.run_vardiya_otomatik_ac();
select count(*) into v_n from public.vardiyalar where kapanis_at is null;
if v_n <> 1 then
  raise exception 'FAIL 121a: açık vardiya yokken otomatik açılmadı (açık: %)', v_n;
end if;
select * into v_rec from public.vardiyalar where kapanis_at is null;
if v_rec.acilis_nakit_kurus <> 4200 or v_rec.personel_id is distinct from u_personel then
  raise exception 'FAIL 121b: devirden sonra açılış 4200 / aynı kişi değil: % %',
    v_rec.acilis_nakit_kurus, v_rec.personel_id;
end if;
perform public.run_vardiya_otomatik_ac();
select count(*) into v_n from public.vardiyalar where kapanis_at is null;
if v_n <> 1 then
  raise exception 'FAIL 121c: ikinci çalıştırma ikinci vardiya açtı';
end if;

-- Sayılmış (ELLE) kapanıştan sonra: ayardaki açılış nakdi.
update public.vardiyalar set kapanis_at = now() + interval '2 seconds', kapanis_kaynak = 'ELLE',
       sayilan_nakit_kurus = 0, beklenen_nakit_kurus = 0, fark_kurus = 0
 where kapanis_at is null;
perform public.run_vardiya_otomatik_ac();
if (select acilis_nakit_kurus from public.vardiyalar where kapanis_at is null) <> 1111 then
  raise exception 'FAIL 121d: sayılmış kapanıştan sonra ayardaki açılış nakdi kullanılmadı';
end if;
raise notice 'PASS 121: vardiya yoksa hemen açılır; sayımsız kapanışta keseden taşınır, sayılmışta ayardaki tutar';

-- 122: Yönetici sayıp kapatınca sonraki vardiya hemen, bıraktığı tutarla açılır.
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE' where kapanis_at is null;
insert into public.vardiyalar (personel_id, acilis_nakit_kurus, otomatik_acildi)
values (u_personel, 1000, false) returning id into v_vardiya;
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id)
values ('BILET', null, 500, 'NAKIT', v_vardiya);

perform pg_temp.login(u_yonetici);
select v.kapandi, v.fark_kurus into v_bool, v_ucret from public.vardiya_kapat(1500, 'kese boşaltıldı', 300) v;
perform pg_temp.logout();
if not v_bool or v_ucret <> 0 then
  raise exception 'FAIL 122a: Yönetici kapanışı kapanmadı ya da fark 0 değil (% %)', v_bool, v_ucret;
end if;
select * into v_rec from public.vardiyalar where kapanis_at is null;
if not found or v_rec.id = v_vardiya then
  raise exception 'FAIL 122b: Yönetici kapanışından sonra yeni vardiya hemen açılmadı';
end if;
if v_rec.acilis_nakit_kurus <> 300 or v_rec.personel_id is distinct from u_personel then
  raise exception 'FAIL 122c: yeni vardiya bırakılan 300 / aynı kişiyle açılmadı: % %',
    v_rec.acilis_nakit_kurus, v_rec.personel_id;
end if;

-- Bırakılan tutar verilmezse ayardaki açılış nakdi.
perform pg_temp.login(u_yonetici);
perform * from public.vardiya_kapat(300, null);
perform pg_temp.logout();
if (select acilis_nakit_kurus from public.vardiyalar where kapanis_at is null) <> 1111 then
  raise exception 'FAIL 122d: bırakılan tutar yokken ayardaki açılış nakdi kullanılmadı';
end if;
raise notice 'PASS 122: Yönetici sayıp kapatınca sonraki vardiya hemen, kesede bıraktığıyla açılır';

-- 123: bayat vardiya OTOMATIK kapanır; sonraki çalıştırma beklenenle yeniden açar.
update public.vardiyalar set acilis_at = now() - interval '40 hours' where kapanis_at is null
returning id into v_vardiya;
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id)
values ('BILET', null, 2000, 'NAKIT', v_vardiya);
perform public.run_vardiya_kurtarma();
if (select kapanis_kaynak from public.vardiyalar where id = v_vardiya) is distinct from 'OTOMATIK' then
  raise exception 'FAIL 123a: bayat vardiya OTOMATIK kapanmadı';
end if;
update public.vardiyalar set kapanis_at = now() + interval '3 seconds' where id = v_vardiya;
perform public.run_vardiya_otomatik_ac();
select * into v_rec from public.vardiyalar where kapanis_at is null;
if not found or v_rec.acilis_nakit_kurus <> 1111 + 2000 then
  raise exception 'FAIL 123b: otomatik kapanıştan sonra kese (3111) taşınmadı: %', v_rec.acilis_nakit_kurus;
end if;
raise notice 'PASS 123: bayat vardiya kapanır ve hemen kesedeki tutarla yeniden açılır';

-- 124: her personelin vardiya saatleri; bitişten sonra bir kez hatırlatma.
perform pg_temp.login(u_personel);
begin
  perform public.personel_vardiya_saati(u_personel, '09:00', '21:00');
  raise exception 'FAIL 124a: Personel vardiya saatini değiştirdi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  update public.profiles set vardiya_bitis = '23:00' where id = u_personel;
  raise exception 'FAIL 124b: Personel vardiya saatini doğrudan yazdı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.login(u_yonetici);
begin
  perform public.personel_vardiya_saati(u_personel, '09:00', null);
  raise exception 'FAIL 124c: yalnızca başlangıç kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform public.personel_vardiya_saati(u_personel, '09:00', '21:00');
perform pg_temp.login(u_personel);
select vardiya_baslangic, vardiya_bitis into v_rec from public.profiles where id = u_personel;
if v_rec.vardiya_baslangic <> '09:00'::time or v_rec.vardiya_bitis <> '21:00'::time then
  raise exception 'FAIL 124d: Personel kendi vardiya saatlerini okuyamıyor';
end if;
perform pg_temp.logout();

-- Bitiş 20 dk önceydi, vardiya ondan önce açıldı → bir kez hatırlatma.
update public.profiles
   set vardiya_baslangic = ((now() at time zone 'Europe/Istanbul') - interval '12 hours 20 minutes')::time,
       vardiya_bitis     = ((now() at time zone 'Europe/Istanbul') - interval '20 minutes')::time
 where id = u_personel;
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE' where kapanis_at is null;
insert into public.vardiyalar (personel_id, acilis_nakit_kurus, otomatik_acildi, acilis_at)
values (u_personel, 0, false, now() - interval '5 hours') returning id into v_vardiya;

select count(*) into v_n2 from public.notifications where tur = 'VARDIYA_DEGISIM' and profile_id = u_personel;
perform public.run_vardiya_degisim_hatirlat();
perform public.run_vardiya_degisim_hatirlat();
select count(*) into v_n from public.notifications where tur = 'VARDIYA_DEGISIM' and profile_id = u_personel;
if v_n <> v_n2 + 1 then
  raise exception 'FAIL 124e: bitişten 20 dk sonra tek hatırlatma beklenirdi (% → %)', v_n2, v_n;
end if;
if exists (select 1 from public.notifications
            where tur = 'VARDIYA_DEGISIM' and profile_id = u_yonetici and created_at >= now()) then
  raise exception 'FAIL 124f: hatırlatma Yöneticiye de gitti';
end if;

-- Devir olmuşsa (yeni vardiya bitişten SONRA açıldı) hatırlatma yok.
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'DEVIR', beklenen_nakit_kurus = 0
 where id = v_vardiya;
insert into public.vardiyalar (personel_id, acilis_nakit_kurus, otomatik_acildi, acilis_at)
values (u_personel, 0, false, now() - interval '10 minutes');
perform public.run_vardiya_degisim_hatirlat();
select count(*) into v_n2 from public.notifications where tur = 'VARDIYA_DEGISIM' and profile_id = u_personel;
if v_n2 <> v_n then
  raise exception 'FAIL 124g: devirden sonra yine hatırlatma gitti';
end if;

-- Bitişten yalnızca 5 dk geçtiyse henüz yok (15 dk payı).
update public.profiles
   set vardiya_bitis = ((now() at time zone 'Europe/Istanbul') - interval '5 minutes')::time
 where id = u_personel;
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE' where kapanis_at is null;
insert into public.vardiyalar (personel_id, acilis_nakit_kurus, otomatik_acildi, acilis_at)
values (u_personel, 0, false, now() - interval '5 hours');
perform public.run_vardiya_degisim_hatirlat();
select count(*) into v_n from public.notifications where tur = 'VARDIYA_DEGISIM' and profile_id = u_personel;
if v_n <> v_n2 then
  raise exception 'FAIL 124h: 15 dk dolmadan hatırlatma gitti';
end if;

if has_function_privilege('authenticated', 'public.run_vardiya_degisim_hatirlat()', 'execute')
   or has_function_privilege('service_role', 'public.run_vardiya_degisim_hatirlat()', 'execute') then
  raise exception 'FAIL 124i: run_vardiya_degisim_hatirlat istemciye açık';
end if;
raise notice 'PASS 124: vardiya saatlerini yalnızca Yönetici yazar; bitişten 15 dk sonra bir kez, yalnızca o personele hatırlatma';

-- =====================================================================
-- PASS 125-126 (086): Vardiya raporu — Yöneticinin vardiya ekranı.
-- Tek vardiyanın toplamları (yönteme göre, ters kayıtlar düşülmüş), o
-- vardiyada kapanan biletler, pencere içindeki girişler, istisnai işlemler,
-- içeride kalanlar ve Onay bekleyenler. Liste için çoklu toplam.
-- =====================================================================
update public.vardiyalar set kapanis_at = now(), kapanis_kaynak = 'ELLE' where kapanis_at is null;
insert into public.vardiyalar (personel_id, acilis_nakit_kurus, otomatik_acildi, acilis_at)
values (u_personel, 500, false, now() - interval '2 hours') returning id into v_vardiya;
select id into v_id2 from public.tarifeler where gecerli_bitis is null order by id limit 1;

-- Bu vardiyada kapanan bilet (nakit 40 ₺) ve kamerayla girip içeride kalan.
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum,
                             ucret_kurus, tahsil_kurus, odeme_yontemi, vardiya_id,
                             kapatan_vardiya_id, giris_kaynak, cikis_kaynak, cikis_by)
values (gen_random_uuid(), 'ZZ125A', now() - interval '90 minutes', now() - interval '30 minutes',
        v_id2, 'KAPALI', 4000, 4000, 'NAKIT', v_vardiya, v_vardiya, 'MOBIL', 'MOBIL', u_personel)
returning id into v_bilet;
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum, giris_kaynak)
values (gen_random_uuid(), 'ZZ125B', now() - interval '20 minutes', v_id2, 'ACIK', 'KAMERA')
returning id into v_bilet2;

-- Tahsilatlar: nakit 40, kart 25 + ters kaydı (net 0), onaylı havale 10;
-- vardiyasız bir kayıt rapora girmemeli.
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, created_by)
values ('BILET', v_bilet, 4000, 'NAKIT', v_vardiya, u_personel);
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, created_by)
values ('BILET', null, 2500, 'KREDI_KARTI', v_vardiya, u_personel) returning id into v_id;
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, iptal_of, created_by)
values ('BILET', null, -2500, 'KREDI_KARTI', v_vardiya, v_id, u_personel);
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, durum, created_by)
values ('BILET', null, 1000, 'HAVALE', v_vardiya, 'ONAYLANDI', u_personel);
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id)
values ('BILET', null, 7777, 'NAKIT', null);

-- İşlem kaydı: pencere içinde bir ücretsiz çıkış; pencereden önce bir iptal.
insert into public.audit_log (actor, action, tablo, row_id, detay, created_at)
values (u_personel, 'bilet_ucretsiz_cikis', 'biletler', v_bilet, null, now() - interval '40 minutes');
insert into public.audit_log (actor, action, tablo, row_id, detay, created_at)
values (u_personel, 'bilet_iptal', 'biletler', v_bilet2, null, now() - interval '3 hours');

-- 125: yalnızca Yönetici.
perform pg_temp.login(u_personel);
begin
  perform public.vardiya_raporu(v_vardiya);
  raise exception 'FAIL 125a: Personel vardiya raporunu okudu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform * from public.vardiya_toplamlari(array[v_vardiya]);
  raise exception 'FAIL 125b: Personel vardiya toplamlarını okudu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.login(u_yonetici);
v_json := public.vardiya_raporu(v_vardiya);
if (v_json->'vardiya'->>'id')::uuid is distinct from v_vardiya then
  raise exception 'FAIL 125c: rapor başka vardiyayı döndü';
end if;
begin
  perform public.vardiya_raporu(gen_random_uuid());
  raise exception 'FAIL 125d: olmayan vardiya için rapor döndü';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 125: vardiya raporu ve toplamları yalnızca Yöneticiye açık';

-- 126: toplamlar tahsilatlarla, bilet listesi kapatan_vardiya_id ile tutar.
v_json2 := v_json->'toplam';
if (v_json2->>'nakit')::int <> 4000 or (v_json2->>'kart')::int <> 0
   or (v_json2->>'havale')::int <> 1000 or (v_json2->>'toplam')::int <> 5000 then
  raise exception 'FAIL 126a: yönteme göre toplamlar yanlış: %', v_json2;
end if;
if (v_json2->>'toplam')::bigint <>
   (select sum(tutar_kurus) from public.tahsilatlar where vardiya_id = v_vardiya) then
  raise exception 'FAIL 126b: toplam tahsilatlarla tutmuyor';
end if;
if (v_json2->>'arac')::int <> 1 then
  raise exception 'FAIL 126c: kapanan araç sayısı 1 beklenirdi: %', v_json2->>'arac';
end if;
if jsonb_array_length(v_json->'biletler') <> 1
   or (v_json->'biletler'->0->>'id')::uuid <> v_bilet
   or v_json->'biletler'->0->>'plaka' <> 'ZZ125A' then
  raise exception 'FAIL 126d: bilet listesi kapatan_vardiya_id ile tutmuyor: %', v_json->'biletler';
end if;
if (v_json->'giris'->>'toplam')::int <>
   (select count(*) from public.biletler
     where giris_at >= now() - interval '2 hours' and giris_at <= now())
   or (v_json->'giris'->>'kamera')::int < 1 then
  raise exception 'FAIL 126e: pencere içindeki girişler yanlış: %', v_json->'giris';
end if;
if not exists (select 1 from jsonb_array_elements(v_json->'islemler') e
                where e->>'action' = 'bilet_ucretsiz_cikis'
                  and (e->>'row_id')::uuid = v_bilet and e->>'plaka' = 'ZZ125A') then
  raise exception 'FAIL 126f: pencere içindeki ücretsiz çıkış raporda yok';
end if;
if exists (select 1 from jsonb_array_elements(v_json->'islemler') e
            where e->>'action' = 'bilet_iptal' and (e->>'row_id')::uuid = v_bilet2) then
  raise exception 'FAIL 126g: vardiyadan önceki işlem rapora girdi';
end if;
if (v_json->>'iceride')::int <>
   (select count(*) from public.biletler where durum = 'ACIK') then
  raise exception 'FAIL 126h: açık vardiyada içeride kalan sayısı yanlış';
end if;
if (v_json->'onay'->>'adet')::int <>
   (select count(*) from public.tahsilatlar where vardiya_id = v_vardiya and durum = 'BEKLIYOR')
   or (v_json->'onay'->>'adet')::int < 1 then
  raise exception 'FAIL 126i: Onay bekleyen sayısı yanlış: %', v_json->'onay';
end if;
select * into v_rec from public.vardiya_toplamlari(array[v_vardiya]);
if not found or v_rec.toplam_kurus <> 5000 or v_rec.arac_sayisi <> 1 then
  raise exception 'FAIL 126j: liste toplamı raporla tutmuyor';
end if;
perform pg_temp.logout();
raise notice 'PASS 126: rapor toplamları tahsilatlarla, bilet listesi vardiyayla tutuyor';

-- =====================================================================
-- PASS 127-128 (087): Günlük rapor — takvim günü, 00:00-24:00 İstanbul.
-- O gün yapılan bütün tahsilatlar (ters kayıtlar düşer), o gün kapanan
-- biletler, güne değen vardiyalar; liste için gün başına toplam ve geçen
-- haftanın aynı günü (bugün için aynı saate kadar).
-- =====================================================================
v_gun := (now() at time zone 'Europe/Istanbul')::date;
v_ts  := v_gun::timestamp at time zone 'Europe/Istanbul';      -- bugünün 00:00'ı

-- Bugün kapanan bilet + 30 ₺ nakit; dün 23:30'da kapanan bilet + tahsilatı;
-- geçen haftanın aynı gününün tam başında 20 ₺ kart (önceki pencereye girer).
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum,
                             ucret_kurus, tahsil_kurus, odeme_yontemi, vardiya_id,
                             kapatan_vardiya_id, giris_kaynak, cikis_kaynak, cikis_by)
values (gen_random_uuid(), 'ZZ127A', now() - interval '50 minutes', now() - interval '1 minute',
        v_id2, 'KAPALI', 3000, 3000, 'NAKIT', v_vardiya, v_vardiya, 'MOBIL', 'MOBIL', u_personel)
returning id into v_bilet;
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, created_by)
values ('BILET', v_bilet, 3000, 'NAKIT', v_vardiya, u_personel);
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum,
                             ucret_kurus, tahsil_kurus, odeme_yontemi,
                             giris_kaynak, cikis_kaynak, cikis_by)
values (gen_random_uuid(), 'ZZ127B', v_ts - interval '3 hours', v_ts - interval '30 minutes',
        v_id2, 'KAPALI', 1500, 1500, 'NAKIT', 'MOBIL', 'MOBIL', u_personel)
returning id into v_bilet2;
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, created_by, created_at)
values ('BILET', v_bilet2, 1500, 'NAKIT', null, u_personel, v_ts - interval '30 minutes');
insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, created_by, created_at)
values ('BILET', null, 2000, 'KREDI_KARTI', null, u_personel, v_ts - interval '7 days');

-- 127: yalnızca Yönetici; aralık denetimleri.
perform pg_temp.login(u_personel);
begin
  perform public.gun_raporu(v_gun);
  raise exception 'FAIL 127a: Personel günlük raporu okudu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform * from public.gun_toplamlari(v_gun, v_gun);
  raise exception 'FAIL 127b: Personel gün toplamlarını okudu';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.login(u_yonetici);
v_json := public.gun_raporu(v_gun);
if v_json is null or v_json->'toplam' is null then
  raise exception 'FAIL 127c: Yönetici günlük raporu okuyamadı';
end if;
begin
  perform * from public.gun_toplamlari(v_gun, v_gun - 1);
  raise exception 'FAIL 127d: ters aralık kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform * from public.gun_toplamlari(v_gun - 62, v_gun);
  raise exception 'FAIL 127e: 63 günlük aralık kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 127: günlük rapor ve gün toplamları yalnızca Yöneticiye açık; aralık sınırlı';

-- 128: gün penceresi tahsilatlarla, biletlerle ve vardiyalarla tutar.
v_json2 := v_json->'toplam';
select coalesce(sum(tutar_kurus), 0) into v_bigint
  from public.tahsilatlar
 where created_at >= v_ts and created_at < v_ts + interval '1 day';
if (v_json2->>'toplam')::bigint <> v_bigint then
  raise exception 'FAIL 128a: gün toplamı tahsilatlarla tutmuyor: % <> %', v_json2->>'toplam', v_bigint;
end if;
if (v_json2->>'nakit')::bigint + (v_json2->>'kart')::bigint + (v_json2->>'havale')::bigint
   <> (v_json2->>'toplam')::bigint then
  raise exception 'FAIL 128b: yönteme göre toplamlar toplamı vermiyor: %', v_json2;
end if;
if not exists (select 1 from jsonb_array_elements(v_json->'biletler') e
                where (e->>'id')::uuid = v_bilet) then
  raise exception 'FAIL 128c: bugün kapanan bilet raporda yok';
end if;
if exists (select 1 from jsonb_array_elements(v_json->'biletler') e
            where (e->>'id')::uuid = v_bilet2) then
  raise exception 'FAIL 128d: dün kapanan bilet bugünün raporuna girdi';
end if;
if (v_json2->>'arac')::bigint <>
   (select count(*) from public.biletler
     where durum = 'KAPALI' and cikis_at >= v_ts and cikis_at < v_ts + interval '1 day') then
  raise exception 'FAIL 128e: günün araç sayısı yanlış: %', v_json2->>'arac';
end if;
if not exists (select 1 from jsonb_array_elements(v_json->'vardiyalar') e
                where (e->>'id')::uuid = v_vardiya
                  and (e->>'toplam')::bigint =
                      (select sum(tutar_kurus) from public.tahsilatlar where vardiya_id = v_vardiya)) then
  raise exception 'FAIL 128f: güne değen vardiya ya da toplamı raporda yok: %', v_json->'vardiyalar';
end if;
if (v_json->'onay'->>'adet')::bigint <>
   (select count(*) from public.tahsilatlar
     where durum = 'BEKLIYOR' and created_at >= v_ts and created_at < v_ts + interval '1 day') then
  raise exception 'FAIL 128g: Onay bekleyen sayısı yanlış: %', v_json->'onay';
end if;
select * into v_rec from public.gun_toplamlari(v_gun, v_gun);
if not found or v_rec.gun <> v_gun or v_rec.toplam_kurus <> v_bigint
   or v_rec.arac_sayisi <> (v_json2->>'arac')::bigint then
  raise exception 'FAIL 128h: gün toplamı raporla tutmuyor';
end if;
select coalesce(sum(tutar_kurus), 0) into v_bigint2
  from public.tahsilatlar
 where created_at >= v_ts - interval '7 days' and created_at < now() - interval '7 days';
if v_rec.onceki_kurus <> v_bigint2 or v_bigint2 < 2000 then
  raise exception 'FAIL 128i: geçen haftanın aynı saate kadarki toplamı yanlış: % <> %',
    v_rec.onceki_kurus, v_bigint2;
end if;
-- Dünün satırı: tam gün, dün 23:30'daki tahsilat dahil.
select * into v_rec from public.gun_toplamlari(v_gun - 1, v_gun - 1);
if v_rec.toplam_kurus <>
   (select coalesce(sum(tutar_kurus), 0) from public.tahsilatlar
     where created_at >= v_ts - interval '1 day' and created_at < v_ts) then
  raise exception 'FAIL 128j: dünün toplamı tam günü kapsamıyor';
end if;
perform pg_temp.logout();
raise notice 'PASS 128: günlük rapor gün penceresiyle tutuyor; geçen hafta aynı saate kadar';

-- =====================================================================
-- PASS 129-131 (088): Fiş — giriş ve çıkış fişi basımları.
-- Her basım kayıtlıdır (sıra no = "TEKRAR BASIM"); çıkış fişi yalnızca borç
-- kalmamışsa; tahmini ücret sunucuda, tarifenin tam fiyatıyla.
-- =====================================================================
-- Açık bilet (fişi basılacak), borçlu kapalı bilet, ödenmiş kapalı bilet,
-- ve Personelin göremeyeceği 5 gün önce kapanmış ödenmiş bilet.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum, giris_kaynak)
values (gen_random_uuid(), 'ZZ129A', now() - interval '25 minutes', v_id2, 'ACIK', 'KAMERA')
returning id into v_bilet;
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum,
                             ucret_kurus, tahsil_kurus, giris_kaynak, cikis_kaynak,
                             kapatan_vardiya_id)
values (gen_random_uuid(), 'ZZ129B', now() - interval '3 hours', now() - interval '10 minutes',
        v_id2, 'KAPALI', 4000, 0, 'KAMERA', 'KAMERA', v_vardiya)
returning id into v_bilet2;
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum,
                             ucret_kurus, tahsil_kurus, odeme_yontemi, giris_kaynak,
                             cikis_kaynak, cikis_by, kapatan_vardiya_id)
values (gen_random_uuid(), 'ZZ129C', now() - interval '2 hours', now() - interval '5 minutes',
        v_id2, 'KAPALI', 3000, 3000, 'NAKIT', 'MOBIL', 'MOBIL', u_personel, v_vardiya)
returning id into v_id;
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum,
                             ucret_kurus, tahsil_kurus, odeme_yontemi, giris_kaynak,
                             cikis_kaynak, cikis_by)
values (gen_random_uuid(), 'ZZ129D', now() - interval '5 days 2 hours', now() - interval '5 days',
        v_id2, 'KAPALI', 3000, 3000, 'NAKIT', 'MOBIL', 'MOBIL', u_personel)
returning id into v_islem;

-- 129: kimin neyi gördüğü; tabloya doğrudan yazılmaz.
perform pg_temp.login(u_pending);
begin
  perform public.fis_basildi(v_bilet, 'GIRIS', null);
  raise exception 'FAIL 129a: onaysız kullanıcı fiş bastı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
if (select count(*) from public.fis_basimlari) <> 0 then
  raise exception 'FAIL 129b: onaysız kullanıcı fiş kayıtlarını görüyor';
end if;
perform pg_temp.login(u_personel);
begin
  insert into public.fis_basimlari (bilet_id, tur) values (v_bilet, 'GIRIS');
  raise exception 'FAIL 129c: fiş kaydı doğrudan yazıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.fis_basildi(v_islem, 'CIKIS', null);
  raise exception 'FAIL 129d: Personel göremediği eski biletin fişini bastı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.login(u_yonetici);
if public.fis_basildi(v_islem, 'CIKIS', null) <> 1 then
  raise exception 'FAIL 129e: Yönetici eski biletin çıkış fişini basamadı';
end if;
perform pg_temp.login(u_personel);
if exists (select 1 from public.fis_basimlari where bilet_id = v_islem) then
  raise exception 'FAIL 129f: Personel göremediği biletin fiş kaydını görüyor';
end if;
raise notice 'PASS 129: fişi yalnızca bileti görebilen basar; kayıt yalnızca fonksiyonla yazılır';

-- 130: sıra numarası; çıkış fişi yalnızca borç kalmamışsa.
if public.fis_basildi(v_bilet, 'GIRIS', 120) <> 1
   or public.fis_basildi(v_bilet, 'GIRIS', null) <> 2 then
  raise exception 'FAIL 130a: giriş fişi sıra numarası 1, 2 olmalıydı';
end if;
if (select tahmin_dk from public.fis_basimlari where bilet_id = v_bilet order by created_at, id limit 1)
   is distinct from 120 then
  raise exception 'FAIL 130b: tahmini kalış kaydedilmedi';
end if;
begin
  perform public.fis_basildi(v_bilet, 'CIKIS', null);
  raise exception 'FAIL 130c: açık bilete çıkış fişi basıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform public.fis_basildi(v_bilet2, 'CIKIS', null);
  raise exception 'FAIL 130d: borçlu bilete çıkış fişi basıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm not like 'Önce%' then
    raise exception 'FAIL 130e: borçlu çıkış fişinin sebebi yanlış: %', sqlerrm;
  end if;
end;
begin
  perform public.fis_basildi(v_id, 'GIRIS', null);
  raise exception 'FAIL 130f: kapanmış bilete giriş fişi basıldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
if public.fis_basildi(v_id, 'CIKIS', null) <> 1 then
  raise exception 'FAIL 130g: ödenmiş biletin çıkış fişi basılamadı';
end if;
begin
  perform public.fis_basildi(v_bilet, 'BASKA', null);
  raise exception 'FAIL 130h: bilinmeyen fiş türü kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
if (select count(*) from public.fis_basimlari where bilet_id = v_bilet and basan = u_personel) <> 2 then
  raise exception 'FAIL 130i: basan kişi kaydedilmedi';
end if;
raise notice 'PASS 130: fiş basımları sıralı; çıkış fişi yalnızca borç kalmamış kapalı bilete';

-- 131: tahmini ücret sunucuda, tarifenin tam fiyatıyla (aşım kararı beklemeden).
select count(*), min(t.kurus) filter (where t.dakika = 120) into v_n, v_n2
  from public.fis_tahmini(v_bilet, array[60, 120]) t;
select giris_at into v_ts from public.biletler where id = v_bilet;
if v_n <> 2 or v_n2 is distinct from
   public.ucret_hesapla(v_ts, v_ts + interval '120 minutes', v_id2) then
  raise exception 'FAIL 131a: 2 saatlik tahmin tarifeyle tutmuyor: %', v_n2;
end if;
begin
  perform * from public.fis_tahmini(v_id, array[60]);
  raise exception 'FAIL 131b: kapanmış bilete tahmin verildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
begin
  perform * from public.fis_tahmini(v_bilet, array[60, 120, 180, 240, 360, 480, 600]);
  raise exception 'FAIL 131c: 6''dan çok tahmin kabul edildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.login(u_pending);
begin
  perform * from public.fis_tahmini(v_bilet, array[60]);
  raise exception 'FAIL 131d: onaysız kullanıcı tahmin aldı';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
perform pg_temp.logout();
raise notice 'PASS 131: tahmini ücret sunucuda, tam tarifeyle; yalnızca açık bilet ve personel';

-- =====================================================================
-- PASS 132-134 (089): Ödeyip sonra çıkan araç.
-- Personel ödemeyi alıp bileti kapattı, müşteri arabasına yürüdü ve
-- dakikalar sonra çıktı. Kamera onu o bilete bağlar: yeni bilet açılmaz,
-- "açık bilet yok" kaydı yazılmaz. Gecikme uyarı süresini aşarsa Dikkat'e
-- bir satır (audit). Köprü "GIRDI" dediyse yeni giriştir. Süreler canlı
-- ayardan okunur.
-- =====================================================================
select o.tek_kapi_cikis_yoksay_dk, o.odeme_sonrasi_cikis_dk, o.gec_cikis_uyari_dk
  into v_n, v_n2, v_ucret
  from public.otopark_ayarlari o where o.id = 1;
-- v_n = aynı çıkışın penceresi, v_n2 = ödemeden sonra çıkış penceresi,
-- v_ucret = Dikkat eşiği (dakika). Geç: ikisinin de üstünde, pencerenin içinde.
v_ucret2 := greatest(v_n, v_ucret) + 10;
if v_ucret2 >= v_n2 then
  raise exception 'FAIL 132-: ayarlar test edilemez: çıkış %, pencere %, uyarı %', v_n, v_n2, v_ucret;
end if;

-- Personelin ödeyip kapattığı biletler (MOBIL).
insert into public.biletler (islem_id, plaka, giris_at, cikis_at, tarife_id, durum,
                             ucret_kurus, tahsil_kurus, odeme_yontemi, giris_kaynak,
                             cikis_kaynak, cikis_by)
select gen_random_uuid(), x.p, now() - interval '3 hours', now() - make_interval(mins => x.dk),
       v_id2, 'KAPALI', 3000, 3000, 'NAKIT', 'MOBIL', 'MOBIL', u_personel
  from (values ('AA1320', v_ucret2), ('BB1321', 2), ('CC1322', v_ucret2),
               ('DD1323', v_n2 + 10), ('EE1324', v_ucret2), ('FF1330', v_ucret2)) x(p, dk);

-- 132: tek kapı.
perform pg_temp.kamera();
v_json := public.kamera_tek_kapi('AA1320', gen_random_uuid(), now(), null, null, 'CIKTI');
if v_json ->> 'sebep' is distinct from 'ODENMIS_CIKIS'
   or (v_json ->> 'bilet_id')::uuid is distinct from
      (select id from public.biletler where plaka = 'AA1320' and durum = 'KAPALI') then
  raise exception 'FAIL 132a: ödeyip geç çıkan araç bilete bağlanmadı: %', v_json;
end if;
v_json2 := public.kamera_tek_kapi('AA1320', gen_random_uuid(), now() + interval '1 minute', null, null, null);
if v_json2 ->> 'sebep' is distinct from 'ODENMIS_CIKIS' then
  raise exception 'FAIL 132b: aynı çıkışın ikinci karesi yeniden değerlendirildi: %', v_json2;
end if;
v_json := public.kamera_tek_kapi('BB1321', gen_random_uuid(), now(), null, null, null);
if v_json ->> 'sebep' is distinct from 'ODENMIS_CIKIS' then
  raise exception 'FAIL 132c: ödeyip hemen çıkan araç bilete bağlanmadı: %', v_json;
end if;
v_json := public.kamera_tek_kapi('CC1322', gen_random_uuid(), now(), null, null, 'GIRDI');
if v_json ->> 'sebep' = 'ODENMIS_CIKIS'
   or not exists (select 1 from public.biletler where plaka = 'CC1322' and durum = 'ACIK') then
  raise exception 'FAIL 132d: köprü GIRDI dediği halde yeni giriş açılmadı: %', v_json;
end if;
v_json := public.kamera_tek_kapi('DD1323', gen_random_uuid(), now(), null, null, null);
if v_json ->> 'sebep' = 'ODENMIS_CIKIS' then
  raise exception 'FAIL 132e: pencereden sonra görülen araç ödenmiş bilete bağlandı';
end if;
v_json := public.kamera_tek_kapi('EE1324', gen_random_uuid(), now(), null, null, 'ICERIDE');
if v_json ->> 'sebep' is distinct from 'ODENMIS_ICERIDE'
   or exists (select 1 from public.istisnalar where plaka = 'EE1324') then
  raise exception 'FAIL 132f: ödemiş, arabasına giden araç kart açtı: %', v_json;
end if;
perform pg_temp.logout();
if (select count(*) from public.biletler where plaka in ('AA1320', 'BB1321') and durum = 'ACIK') <> 0 then
  raise exception 'FAIL 132g: ödenmiş araca yeni bilet açıldı';
end if;
if (select count(*) from public.audit_log a join public.biletler b on b.id = a.row_id
     where a.action = 'odeme_sonrasi_gec_cikis' and b.plaka = 'AA1320') <> 1
   or exists (select 1 from public.audit_log a join public.biletler b on b.id = a.row_id
               where a.action = 'odeme_sonrasi_gec_cikis' and b.plaka in ('BB1321', 'EE1324')) then
  raise exception 'FAIL 132h: Dikkat satırı yalnızca eşiği aşan çıkışa, bir kez yazılmalı';
end if;
if (select gecikme_dk from public.odenmis_kapi_cikislari k join public.biletler b on b.id = k.bilet_id
     where b.plaka = 'AA1320') is distinct from v_ucret2
   or exists (select 1 from public.odenmis_kapi_cikislari k join public.biletler b on b.id = k.bilet_id
               where b.plaka = 'EE1324') then
  raise exception 'FAIL 132i: çıkış kaydı yanlış (gecikme ya da içeride görülen araç)';
end if;
raise notice 'PASS 132: tek kapı — ödeyip sonra çıkan araç bilete bağlanır; geç çıkış Dikkat''e bir kez; GIRDI yeni giriş';

-- 133: iki kapı (CIKIS kapısı) — "açık bilet yok" kaydı yerine ödenmiş bilet.
perform pg_temp.kamera();
v_id := public.kamera_cikis_bildir('FF1330', gen_random_uuid(), now(), null, null);
v_bilet := public.kamera_cikis_bildir('GG1339', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
if v_id is distinct from (select id from public.biletler where plaka = 'FF1330')
   or exists (select 1 from public.istisnalar where plaka = 'FF1330') then
  raise exception 'FAIL 133a: CIKIS kapısında ödenmiş bilet bulunmadı';
end if;
if (select count(*) from public.audit_log where action = 'odeme_sonrasi_gec_cikis' and row_id = v_id) <> 1 then
  raise exception 'FAIL 133b: CIKIS kapısında geç çıkış Dikkat''e yazılmadı';
end if;
if v_bilet is not null
   or not exists (select 1 from public.istisnalar where plaka = 'GG1339' and tur::text = 'ACIK_BILET_YOK') then
  raise exception 'FAIL 133c: bileti hiç olmayan araç eskisi gibi kayda düşmedi';
end if;
raise notice 'PASS 133: iki kapı — ödeyip sonra çıkan araç bilete bağlanır, biletsiz araç eskisi gibi';

-- 134: yardımcı fonksiyon kimseye açık değil; tablo yalnızca Yöneticiye.
if has_function_privilege('authenticated', 'public.odenmis_cikis(text, timestamptz, uuid, boolean)', 'execute')
   or has_function_privilege('anon', 'public.odenmis_cikis(text, timestamptz, uuid, boolean)', 'execute')
   or has_function_privilege('service_role', 'public.odenmis_cikis(text, timestamptz, uuid, boolean)', 'execute') then
  raise exception 'FAIL 134a: odenmis_cikis istemciye açık';
end if;
perform pg_temp.login(u_personel);
if exists (select 1 from public.odenmis_kapi_cikislari) then
  raise exception 'FAIL 134b: Personel ödenmiş çıkış kayıtlarını görüyor';
end if;
perform pg_temp.login(u_yonetici);
if not exists (select 1 from public.odenmis_kapi_cikislari where bilet_id = v_id) then
  raise exception 'FAIL 134c: Yönetici ödenmiş çıkış kaydını göremiyor';
end if;
perform pg_temp.logout();
raise notice 'PASS 134: ödenmiş çıkış yardımcısı kapalı; kayıtlar yalnızca Yöneticiye';

-- =====================================================================
-- 135-145  Köprü 1.4.7 + 090: geç okunan plaka biletlenir (28.11 teşhisi)
--   Sahada 26-28.11 (köprü 1.4.6): iki yanlış kamera çıkışı (tahmin
--   kuralı), 10-60 saatlik altı bilet (çıkışı görülmeyen eski bilet),
--   içeri giren araçlara "İçeride, bileti yok" kartı, 32 saatte 73 kart.
--   Sahibin kararları (28.11): çıkış tahmini hiçbir bileti kapatmaz; emin
--   girişte eski bilet son içeride görüldüğü saatte (yoksa kendi giriş
--   saatinde) kapanır ve Yönetici bilgilenir; geç okunan plaka kartın
--   saatinden (ya da içeride görüldüğü andan) işaretli bilet açar.
--   Canlı veritabanında son 11 saatin çözülmemiş tek kapı kartları testi
--   şaşırtmasın diye bloklar önce onları kapatır (sonunda geri alınır).
-- =====================================================================
perform pg_temp.logout();
if to_regprocedure('public.plaka_harf_karisir(text, text)') is null
   or to_regprocedure('public.kamera_eski_bileti_kapat(uuid, timestamptz)') is null
   or to_regprocedure('public.kamera_giris_karti(text, timestamptz, uuid, jsonb, text)') is null
   or to_regprocedure('public.kamera_yeniden_giris(uuid, text, uuid, timestamptz, text, jsonb)') is null then
  raise exception 'FAIL 135: 090 çalıştırılmadı (yardımcı fonksiyonlar yok)';
end if;
update public.otopark_ayarlari
   set tek_kapi_giris_yoksay_dk = 2, tek_kapi_cikis_yoksay_dk = 5, kamera_gecikme_limiti_dk = 720
 where id = 1;
if exists (select 1 from public.biletler b,
                  unnest(array['ZZ135TA01', 'ZZ136AB01', 'ZZ137CD02', 'ZZ137EF03',
                               'ZZ138CO11', 'ZZ138CD11', 'ZZ138KA22', 'ZZ138XA22',
                               'ZZ138DA33', 'ZZ1380A33', 'ZZ138OA33', 'ZZ138CO44', 'ZZ138CD44',
                               'ZZ139KI01', 'ZZ139LM02', 'ZZ140LA01', 'ZZ140LA07', 'ZZ140NP03',
                               'ZZ140QR04', 'ZZ141GA01', 'ZZ141GB02', 'ZZ141GC03', 'ZZ141GD04',
                               'ZZ141GE05', 'ZZ141GF06', 'ZZ142EA01', 'ZZ143IG11', 'ZZ143JH22',
                               'ZZ144MF01', 'ZZ144NG02', 'ZZ141HK21', 'ZZ141HK27']) as p(plaka)
            where b.plaka = p.plaka or public.plaka_yakin(b.plaka, p.plaka)) then
  raise exception 'FAIL 135: fixture — ZZ135-144 plakalarından birine eşit ya da bir karakter yakın bilet var';
end if;

-- 135 (F1): çıkış tahmini — 1.00 güvenle, tam ve tek eşleşmede bile —
--     bileti kapatmaz; köprü 1.4.7 iki plakalı izde güven göndermez (null).
--     Fonksiyon ve yetkisi kalır: webhook onu çağırır, null alır, kartı yazar.
update public.istisnalar set cozuldu_at = now()
 where tur::text = 'OKUNAMADI' and yon = 'ORTAK' and cozuldu_at is null
   and kaynak_zaman > now() - interval '11 hours';
perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ135TA01', gen_random_uuid(), 'KAMERA', now() - interval '1 hour');
v_id := public.kamera_tahmin_cikis('ZZ135TA01', 1.00, gen_random_uuid(), now(),
                                   jsonb_build_object('hareket', 'CIKTI'));
v_id2 := public.kamera_tahmin_cikis('ZZ135TA01', null, gen_random_uuid(), now(),
                                    jsonb_build_object('hareket', 'CIKTI'));
perform pg_temp.logout();
if v_id is not null or v_id2 is not null
   or not exists (select 1 from public.biletler where id = v_bilet and durum = 'ACIK')
   or exists (select 1 from public.audit_log
               where action = 'kamera_tahmin_cikis' and row_id = v_bilet) then
  raise exception 'FAIL 135: çıkış tahmini bileti kapattı (% / %)', v_id, v_id2;
end if;
v_txt := 'public.kamera_tahmin_cikis(text, numeric, uuid, timestamptz, jsonb)';
if not has_function_privilege('service_role', v_txt, 'execute')
   or has_function_privilege('authenticated', v_txt, 'execute')
   or has_function_privilege('anon', v_txt, 'execute') then
  raise exception 'FAIL 135: kamera_tahmin_cikis yetkileri değişti (webhook çağırabilmeli)';
end if;

raise notice 'PASS 135: çıkış tahmini hiçbir bileti kapatmaz, güveni ne olursa olsun (090)';

-- 136 (F2): giren aracın eski açık bileti var; araç içeride en son 3 saat
--     önce görüldü. Eski bilet o saatte ödemesiz kapanır (ücret o saate
--     kadar), not ve denetim kaydı alır, Yönetici bilgilenir; yeni bilet
--     açılır. Kart yok. Aynı olay yeniden gelirse aynı yeni bilet döner.
perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ136AB01', gen_random_uuid(), 'KAMERA', now() - interval '5 hours');
select public.kamera_tek_kapi('ZZ136AB01', gen_random_uuid(), now() - interval '3 hours',
                              null, null, 'ICERIDE') into v_json;
v_islem := gen_random_uuid();
select public.kamera_tek_kapi('ZZ136AB01', v_islem, now(), null, null, 'GIRDI') into v_json2;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'ICERIDE_ACIK'
   or v_json2 ->> 'karar' is distinct from 'GIRIS'
   or v_json2 ->> 'sebep' is distinct from 'ESKI_BILET_KAPANDI' then
  raise exception 'FAIL 136a: eski bilet kapanıp yeni giriş açılmadı (% / %)', v_json, v_json2;
end if;
if not exists (select 1 from public.biletler b
                where b.id = v_bilet and b.durum = 'KAPALI' and b.cikis_kaynak::text = 'KAMERA'
                  and b.cikis_at = now() - interval '3 hours' and b.tahsil_kurus = 0
                  and b.odeme_yontemi is null
                  and b.ucret_kurus = public.bilet_ucreti(b, b.cikis_at)
                  and b.notlar like '%Kamera: çıkışı görülmedi%') then
  raise exception 'FAIL 136a: eski bilet son içeride görüldüğü saatte, ödemesiz ve notla kapanmadı';
end if;
if not exists (select 1 from public.biletler b
                where b.id = (v_json2 ->> 'bilet_id')::uuid and b.plaka = 'ZZ136AB01'
                  and b.durum = 'ACIK' and b.islem_id = v_islem and b.giris_at = now()
                  and b.notlar = 'Kamera: önceki bilet çıkışı görülmeden kapandı')
   or (select count(*) from public.biletler where plaka = 'ZZ136AB01' and durum = 'ACIK') <> 1 then
  raise exception 'FAIL 136a: yeni bilet açılmadı ya da işaretli değil';
end if;
if (select count(*) from public.audit_log
     where action = 'kamera_cikis_gorulmedi' and tablo = 'biletler' and row_id = v_bilet) <> 1 then
  raise exception 'FAIL 136a: kamera_cikis_gorulmedi denetim kaydı tek değil';
end if;
if not exists (select 1 from public.notifications
                where tur::text = 'KAMERA_HAREKET' and baslik = 'Çıkışı görülmedi'
                  and link = '/gise/bilet/' || v_bilet)
   or exists (select 1 from public.istisnalar where plaka = 'ZZ136AB01') then
  raise exception 'FAIL 136a: Yönetici bilgilenmedi ya da kart açıldı';
end if;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ136AB01', v_islem, now(), null, null, 'GIRDI') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'TEKRAR'
   or v_json ->> 'bilet_id' is distinct from v_json2 ->> 'bilet_id'
   or (select count(*) from public.audit_log
        where action = 'kamera_cikis_gorulmedi' and row_id = v_bilet) <> 1 then
  raise exception 'FAIL 136b: tekrar gelen giriş aynı bileti döndürmedi (%)', v_json;
end if;

raise notice 'PASS 136: emin girişte eski açık bilet son içeride görüldüğü saatte kapanır, Yönetici bilgilenir, yeni bilet açılır (090)';

-- 137 (F2): araç içeride hiç görülmediyse eski bilet kendi giriş saatinde
--     kapanır (ücret o saate kadar). Kapanamıyorsa (kullanılan puan
--     ücretten fazla) eskisi gibi GIRISTE_ACIK_BILET kartı.
perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ137CD02', gen_random_uuid(), 'KAMERA', now() - interval '6 hours');
select public.kamera_tek_kapi('ZZ137CD02', gen_random_uuid(), now(), null, null, 'GIRDI') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'ESKI_BILET_KAPANDI'
   or not exists (select 1 from public.biletler b
                   where b.id = v_bilet and b.durum = 'KAPALI'
                     and b.giris_at = now() - interval '6 hours' and b.cikis_at = b.giris_at
                     and b.ucret_kurus = public.bilet_ucreti(b, b.cikis_at)) then
  raise exception 'FAIL 137a: görülmeyen eski bilet kendi giriş saatinde kapanmadı (%)', v_json;
end if;

perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ137EF03', gen_random_uuid(), 'KAMERA', now() - interval '4 hours');
perform pg_temp.logout();
update public.biletler set indirim_kurus = 100000000 where id = v_bilet;
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ137EF03', v_islem, now(), null, null, 'GIRDI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'ISTISNA' or v_json ->> 'sebep' is distinct from 'GIRIS_ACIK_BILET'
   or not exists (select 1 from public.biletler where id = v_bilet and durum = 'ACIK')
   or not exists (select 1 from public.istisnalar
                   where islem_id = v_islem and tur::text = 'GIRISTE_ACIK_BILET'
                     and aday_bilet_ids = array[v_bilet])
   or (select count(*) from public.biletler where plaka = 'ZZ137EF03') <> 1 then
  raise exception 'FAIL 137b: kapanamayan eski bilet eskisi gibi karta gitmedi (%)', v_json;
end if;

raise notice 'PASS 137: içeride görülmeyen eski bilet kendi giriş saatinde kapanır; kapanamayan eskisi gibi karta (090)';

-- 138 (F3): ÇIKTI ipuçlu okuma tek harfte, sık karışan bir çiftle
--     (O/D/0, M/N, B/8, I/1, S/5, Z/2, G/6) yanlış ve içeride tek benzeri
--     var: o bilet her kamera çıkışı gibi kapanır (ödemesiz), denetim kaydı
--     okunanı taşır. Karışmayan harf, iki benzer ya da ipuçsuz okuma
--     eskisi gibi insana (BENZER_ACIK).
perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ138CO11', gen_random_uuid(), 'KAMERA', now() - interval '1 hour');
v_islem := gen_random_uuid();
select public.kamera_tek_kapi('ZZ138CD11', v_islem, now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'CIKIS' or v_json ->> 'sebep' is distinct from 'BENZER_HARF'
   or (v_json ->> 'bilet_id')::uuid is distinct from v_bilet
   or not exists (select 1 from public.biletler
                   where id = v_bilet and durum = 'KAPALI' and cikis_kaynak::text = 'KAMERA'
                     and cikis_at = now() and tahsil_kurus = 0)
   or exists (select 1 from public.biletler where plaka = 'ZZ138CD11')
   or exists (select 1 from public.istisnalar where islem_id = v_islem) then
  raise exception 'FAIL 138a: O/D karışan çıkış benzer bileti kapatmadı (%)', v_json;
end if;
if (select count(*) from public.audit_log
     where action = 'kamera_benzer_harf' and row_id = v_bilet
       and detay ->> 'okunan' = 'ZZ138CD11' and detay ->> 'bilet_plaka' = 'ZZ138CO11') <> 1 then
  raise exception 'FAIL 138a: kamera_benzer_harf denetim kaydı yok ya da okunanı taşımıyor';
end if;

perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ138KA22', gen_random_uuid(), 'KAMERA', now() - interval '1 hour');
select public.kamera_tek_kapi('ZZ138XA22', gen_random_uuid(), now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'BENZER_ACIK'
   or not exists (select 1 from public.biletler where id = v_bilet and durum = 'ACIK') then
  raise exception 'FAIL 138b: karışmayan harf (K/X) bileti kapattı (%)', v_json;
end if;

perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ138DA33', gen_random_uuid(), 'KAMERA', now() - interval '1 hour');
v_bilet2 := public.bilet_ac('ZZ1380A33', gen_random_uuid(), 'KAMERA', now() - interval '1 hour');
select public.kamera_tek_kapi('ZZ138OA33', gen_random_uuid(), now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'BENZER_ACIK'
   or (select count(*) from public.biletler where id in (v_bilet, v_bilet2) and durum = 'ACIK') <> 2 then
  raise exception 'FAIL 138c: iki benzerden biri kapatıldı (%)', v_json;
end if;

perform pg_temp.kamera();
v_bilet := public.bilet_ac('ZZ138CO44', gen_random_uuid(), 'KAMERA', now() - interval '1 hour');
select public.kamera_tek_kapi('ZZ138CD44', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'BENZER_ACIK'
   or not exists (select 1 from public.biletler where id = v_bilet and durum = 'ACIK') then
  raise exception 'FAIL 138d: ipuçsuz benzer okuma bileti kapattı (%)', v_json;
end if;

if not (public.plaka_harf_karisir('ZZ138CO11', 'ZZ138CD11') and public.plaka_harf_karisir('AB0', 'ABO')
        and public.plaka_harf_karisir('34MA1', '34NA1') and public.plaka_harf_karisir('B1', '81')
        and public.plaka_harf_karisir('AI2', 'A12') and public.plaka_harf_karisir('S9', '59')
        and public.plaka_harf_karisir('Z9', '29') and public.plaka_harf_karisir('G7', '67'))
   or public.plaka_harf_karisir('ABC', 'ABX') is not false
   or public.plaka_harf_karisir('ABC', 'ABC') is not false
   or public.plaka_harf_karisir('ABC', 'ABCD') is not false
   or public.plaka_harf_karisir('OD1', 'DO1') is not false
   or public.plaka_harf_karisir(null, 'ABC') is not false then
  raise exception 'FAIL 138e: plaka_harf_karisir yanlış';
end if;

raise notice 'PASS 138: çıkışta sık karışan tek harf ve tek benzer bilet — bilet kapanır; başka her durum insana (090)';

-- 139 (F4): köprü 1.4.7 aynı izin sonraki gönderimlerine plakasız giriş
--     kartının kimliğini koyar (giris_islem_id). Giriş kartı + 2 saat sonra
--     içeride emin okuma: bilet kartın saatinden ve kimliğiyle açılır, kart
--     sistemce çözülür. Bileti olan araçta: bilet karttan en çok 15 dk önce
--     açıldıysa aynı ziyarettir, kart yalnızca çözülür; daha eskiyse araç
--     çıkışı görülmeden yeniden girmiştir — F2 kartın saatiyle uygulanır.
update public.istisnalar set cozuldu_at = now()
 where tur::text = 'OKUNAMADI' and yon = 'ORTAK' and cozuldu_at is null
   and kaynak_zaman > now() - interval '11 hours';
v_islem := gen_random_uuid();
perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', v_islem, now() - interval '2 hours', null, null,
                                jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ139KI01', gen_random_uuid(), now(), null,
                              jsonb_build_object('giris_islem_id', v_islem::text), 'ICERIDE') into v_json;
perform pg_temp.logout();
v_bilet := (v_json ->> 'bilet_id')::uuid;
if v_json ->> 'karar' is distinct from 'GIRIS' or v_json ->> 'sebep' is distinct from 'GIRIS_KARTI'
   or not exists (select 1 from public.biletler
                   where id = v_bilet and plaka = 'ZZ139KI01' and durum = 'ACIK'
                     and islem_id = v_islem and giris_at = now() - interval '2 hours'
                     and giris_kaynak::text = 'KAMERA' and notlar = 'Kamera: giriş kartından açıldı') then
  raise exception 'FAIL 139a: giriş kartından bilet açılmadı (%)', v_json;
end if;
if not exists (select 1 from public.istisnalar
                where id = v_id and cozuldu_at is not null and cozuldu_by is null
                  and plaka = 'ZZ139KI01' and cozum_notu like 'Kamera: plaka içeride okundu%') then
  raise exception 'FAIL 139a: giriş kartı sistemce çözülmedi';
end if;

v_islem := gen_random_uuid();
perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', v_islem, now() - interval '115 minutes', null, null,
                                jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ139KI01', gen_random_uuid(), now(), null,
                              jsonb_build_object('giris_islem_id', v_islem::text), 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'ICERIDE_ACIK'
   or not exists (select 1 from public.istisnalar
                   where id = v_id and cozuldu_at is not null and cozuldu_by is null
                     and cozum_notu like 'Kamera: aynı araç içeride okundu, bileti var%')
   or (select count(*) from public.biletler where plaka = 'ZZ139KI01') <> 1
   or not exists (select 1 from public.biletler where id = v_bilet and durum = 'ACIK') then
  raise exception 'FAIL 139b: bileti olan aracın giriş kartı çözülmedi ya da bilet değişti (%)', v_json;
end if;

-- (c) Bilet 5 saat önce açılmış, araç en son 4 saat önce içeride görülmüş;
--     1 saat önce aynı izin plakasız giriş kartı: araç çıkışı görülmeden
--     yeniden girdi. Eski bilet 4 saat önce kapanır, yenisi kartın saatinden
--     ve kimliğiyle açılır, kart çözülür, Yönetici bilgilenir.
perform pg_temp.kamera();
v_bilet2 := public.bilet_ac('ZZ139LM02', gen_random_uuid(), 'KAMERA', now() - interval '5 hours');
perform public.kamera_tek_kapi('ZZ139LM02', gen_random_uuid(), now() - interval '4 hours',
                               null, null, 'ICERIDE');
v_islem := gen_random_uuid();
v_id := public.kamera_okunamadi('ORTAK', v_islem, now() - interval '1 hour', null, null,
                                jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ139LM02', gen_random_uuid(), now(), null,
                              jsonb_build_object('giris_islem_id', v_islem::text), 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'GIRIS' or v_json ->> 'sebep' is distinct from 'ESKI_BILET_KAPANDI'
   or not exists (select 1 from public.biletler b
                   where b.id = v_bilet2 and b.durum = 'KAPALI' and b.cikis_kaynak::text = 'KAMERA'
                     and b.cikis_at = now() - interval '4 hours' and b.tahsil_kurus = 0
                     and b.notlar like 'Kamera: çıkışı görülmedi%')
   or not exists (select 1 from public.biletler b
                   where b.id = (v_json ->> 'bilet_id')::uuid and b.durum = 'ACIK'
                     and b.islem_id = v_islem and b.giris_at = now() - interval '1 hour'
                     and b.iceride_goruldu_at = now()
                     and b.notlar = 'Kamera: önceki bilet çıkışı görülmeden kapandı')
   or not exists (select 1 from public.istisnalar
                   where id = v_id and cozuldu_at is not null and cozuldu_by is null
                     and plaka = 'ZZ139LM02' and cozum_notu like 'Kamera: plaka içeride okundu%')
   or not exists (select 1 from public.notifications
                   where tur::text = 'KAMERA_HAREKET' and baslik = 'Çıkışı görülmedi'
                     and link = '/gise/bilet/' || v_bilet2) then
  raise exception 'FAIL 139c: giriş kartıyla dönen aracın eski bileti kapanıp yenisi açılmadı (%)', v_json;
end if;

raise notice 'PASS 139: giriş kartının kimliğiyle içeride okunan plaka kartın saatinden bilet açar, kart çözülür; eski açık bilet varsa F2 kartın saatiyle (090)';

-- 140 (F4): aynı izin çıkışı, giriş kartının kimliğiyle emin okundu ve
--     aracın bileti yok: bilet kartın saatinden açılır ve hemen kamera
--     çıkışı gibi kapanır (ödemesiz). İçerideki bir karakter uzak bilete
--     dokunulmaz (bu karar benzer aramasından önce verilir).
update public.istisnalar set cozuldu_at = now()
 where tur::text = 'OKUNAMADI' and yon = 'ORTAK' and cozuldu_at is null
   and kaynak_zaman > now() - interval '11 hours';
perform pg_temp.kamera();
v_bilet2 := public.bilet_ac('ZZ140LA01', gen_random_uuid(), 'KAMERA', now() - interval '1 hour');
v_islem := gen_random_uuid();
v_id := public.kamera_okunamadi('ORTAK', v_islem, now() - interval '40 minutes', null, null,
                                jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ140LA07', gen_random_uuid(), now(), null,
                              jsonb_build_object('giris_islem_id', v_islem::text), 'CIKTI') into v_json;
perform pg_temp.logout();
v_bilet := (v_json ->> 'bilet_id')::uuid;
if v_json ->> 'karar' is distinct from 'CIKIS' or v_json ->> 'sebep' is distinct from 'GIRIS_KARTI'
   or not exists (select 1 from public.biletler b
                   where b.id = v_bilet and b.plaka = 'ZZ140LA07' and b.islem_id = v_islem
                     and b.giris_at = now() - interval '40 minutes' and b.durum = 'KAPALI'
                     and b.cikis_kaynak::text = 'KAMERA' and b.cikis_at = now()
                     and b.tahsil_kurus = 0 and b.ucret_kurus = public.bilet_ucreti(b, b.cikis_at)) then
  raise exception 'FAIL 140: giriş kartlı çıkış bileti açıp kapatmadı (%)', v_json;
end if;
if not exists (select 1 from public.biletler where id = v_bilet2 and durum = 'ACIK')
   or not exists (select 1 from public.istisnalar
                   where id = v_id and cozuldu_at is not null and cozuldu_by is null
                     and plaka = 'ZZ140LA07' and cozum_notu like 'Kamera: plaka çıkışta okundu%')
   or exists (select 1 from public.istisnalar where plaka = 'ZZ140LA07' and id <> v_id) then
  raise exception 'FAIL 140: benzer bilet değişti, kart çözülmedi ya da ikinci kart yazıldı';
end if;

-- (b) Eski açık bilet (8 saat, içeride görülmedi) + aynı izin 50 dk önceki
--     plakasız giriş kartı + emin çıkış: eski bilet kendi giriş saatinde
--     kapanır, yenisi kartın saatinden açılıp bu çıkışla kapanır.
perform pg_temp.kamera();
v_bilet2 := public.bilet_ac('ZZ140NP03', gen_random_uuid(), 'KAMERA', now() - interval '8 hours');
v_islem := gen_random_uuid();
v_id := public.kamera_okunamadi('ORTAK', v_islem, now() - interval '50 minutes', null, null,
                                jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ140NP03', gen_random_uuid(), now(), null,
                              jsonb_build_object('giris_islem_id', v_islem::text), 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' is distinct from 'CIKIS' or v_json ->> 'sebep' is distinct from 'GIRIS_KARTI'
   or not exists (select 1 from public.biletler b
                   where b.id = v_bilet2 and b.durum = 'KAPALI' and b.cikis_at = b.giris_at
                     and b.notlar like 'Kamera: çıkışı görülmedi%')
   or not exists (select 1 from public.biletler b
                   where b.id = (v_json ->> 'bilet_id')::uuid and b.islem_id = v_islem
                     and b.giris_at = now() - interval '50 minutes' and b.durum = 'KAPALI'
                     and b.cikis_at = now() and b.ucret_kurus = public.bilet_ucreti(b, b.cikis_at))
   or not exists (select 1 from public.istisnalar
                   where id = v_id and cozuldu_at is not null
                     and cozum_notu like 'Kamera: plaka çıkışta okundu%') then
  raise exception 'FAIL 140b: eski bilet kapanıp karttan açılan bilet çıkışta kapanmadı (%)', v_json;
end if;

-- (c) Bilet karttan 5 dk önce açılmış (aynı ziyaret): bilet her zamanki
--     gibi kapanır, kart yalnızca çözülür.
perform pg_temp.kamera();
v_bilet2 := public.bilet_ac('ZZ140QR04', gen_random_uuid(), 'KAMERA', now() - interval '40 minutes');
v_islem := gen_random_uuid();
v_id := public.kamera_okunamadi('ORTAK', v_islem, now() - interval '35 minutes', null, null,
                                jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ140QR04', gen_random_uuid(), now(), null,
                              jsonb_build_object('giris_islem_id', v_islem::text), 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'ACIK_BILET'
   or (v_json ->> 'bilet_id')::uuid is distinct from v_bilet2
   or (select count(*) from public.biletler where plaka = 'ZZ140QR04') <> 1
   or not exists (select 1 from public.istisnalar
                   where id = v_id and cozuldu_at is not null
                     and cozum_notu like 'Kamera: aynı araç çıktı, bileti var%') then
  raise exception 'FAIL 140c: aynı ziyaretin kartı çözülmedi ya da ikinci bilet açıldı (%)', v_json;
end if;

raise notice 'PASS 140: giriş kartının kimliğiyle çıkışta okunan plaka bileti kartın saatinden açıp kapatır; eski açık bilet varsa önce o kapanır (090)';

-- 141 (F4): kimlik yoksa tahmin: son 10 saatte tahmini (ya da plakası) bu
--     plakayla birebir aynı TEK çözülmemiş giriş kartı bağlanır — çıkışta
--     da içeride de. İki eşleşen kart, ÇIKTI ipuçlu kart ve 10 saatten eski
--     kart bağlanmaz.
update public.istisnalar set cozuldu_at = now()
 where tur::text = 'OKUNAMADI' and yon = 'ORTAK' and cozuldu_at is null
   and kaynak_zaman > now() - interval '11 hours';
perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '3 hours', 'ZZ141GA01', 0.62,
                                jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ141GA01', gen_random_uuid(), now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'GIRIS_KARTI'
   or not exists (select 1 from public.biletler
                   where id = (v_json ->> 'bilet_id')::uuid and giris_at = now() - interval '3 hours'
                     and durum = 'KAPALI')
   or not exists (select 1 from public.istisnalar where id = v_id and cozuldu_at is not null) then
  raise exception 'FAIL 141a: tahmini aynı kart çıkışta bilete dönmedi (%)', v_json;
end if;

perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '1 hour', 'ZZ141GB02', 0.55, null);
select public.kamera_tek_kapi('ZZ141GB02', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'GIRIS_KARTI'
   or not exists (select 1 from public.biletler
                   where id = (v_json ->> 'bilet_id')::uuid and giris_at = now() - interval '1 hour'
                     and durum = 'ACIK')
   or not exists (select 1 from public.istisnalar where id = v_id and cozuldu_at is not null) then
  raise exception 'FAIL 141b: tahmini aynı kart içeride bilete dönmedi (%)', v_json;
end if;

perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '2 hours', 'ZZ141GC03', 0.5,
                                jsonb_build_object('hareket', 'GIRDI'));
v_id2 := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '1 hour', 'ZZ141GC03', 0.5,
                                 jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ141GC03', gen_random_uuid(), now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'CIKIS_BILETSIZ'
   or exists (select 1 from public.istisnalar where id in (v_id, v_id2) and cozuldu_at is not null)
   or exists (select 1 from public.biletler where plaka = 'ZZ141GC03') then
  raise exception 'FAIL 141c: iki eşleşen karttan biri bağlandı (%)', v_json;
end if;

perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '1 hour', 'ZZ141GD04', 0.5,
                                jsonb_build_object('hareket', 'CIKTI'));
v_id2 := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '11 hours', 'ZZ141GE05', 0.5,
                                 jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ141GD04', gen_random_uuid(), now(), null, null, 'CIKTI') into v_json;
select public.kamera_tek_kapi('ZZ141GE05', gen_random_uuid(), now(), null, null, 'CIKTI') into v_json2;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'CIKIS_BILETSIZ' or v_json2 ->> 'sebep' is distinct from 'CIKIS_BILETSIZ'
   or exists (select 1 from public.istisnalar where id in (v_id, v_id2) and cozuldu_at is not null) then
  raise exception 'FAIL 141d: çıkış kartı ya da 10 saatten eski kart bağlandı (% / %)', v_json, v_json2;
end if;

-- (e) Başka bir plakayı almış kart (041 yeniden denemesi) tahminiyle bağlanmaz.
perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '1 hour', 'ZZ141GF06', 0.5,
                                jsonb_build_object('hareket', 'GIRDI'));
perform pg_temp.logout();
update public.istisnalar set plaka = 'ZZ141XX99' where id = v_id;
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ141GF06', gen_random_uuid(), now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'CIKIS_BILETSIZ'
   or exists (select 1 from public.istisnalar where id = v_id and cozuldu_at is not null) then
  raise exception 'FAIL 141e: başka plakalı kart tahminiyle bağlandı (%)', v_json;
end if;

-- (f) Yalnızca tahmine dayanan bağ benzer aramasından (adım 3) SONRA:
--     içeride bir karakter uzak açık bilet varken çıkıştaki okuma hayalet
--     bilet açmaz, eskisi gibi insana gider (BENZER_ACIK); kart açık kalır.
perform pg_temp.kamera();
v_bilet2 := public.bilet_ac('ZZ141HK27', gen_random_uuid(), 'KAMERA', now() - interval '2 hours');
v_id := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '1 hour', 'ZZ141HK21', 0.5,
                                jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ141HK21', gen_random_uuid(), now(), null, null, 'CIKTI') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'BENZER_ACIK'
   or exists (select 1 from public.biletler where plaka = 'ZZ141HK21')
   or not exists (select 1 from public.biletler where id = v_bilet2 and durum = 'ACIK')
   or exists (select 1 from public.istisnalar where id = v_id and cozuldu_at is not null) then
  raise exception 'FAIL 141f: tahmin bağı benzer aramasından önce çalıştı (%)', v_json;
end if;

raise notice 'PASS 141: tahmini birebir aynı tek giriş kartı (10 saat) çıkışta ve içeride bilete döner; iki eşleşen, ÇIKTI ipuçlu, eski kart ve benzer açık bilet varken bağlanmaz (090)';

-- 142 (077 E2, 090 sırası): içeride okunan plaka için son 15 dk'nın
--     kartları — tahmini birebir aynı, sonra bir karakter uzak, sonra boş;
--     eşitse en yenisi. Bir karakter uzak tahminli 10 dk'lık kart, daha
--     yeni (2 dk) boş karttan önce seçilir; boş kart dokunulmaz kalır.
update public.istisnalar set cozuldu_at = now()
 where tur::text = 'OKUNAMADI' and yon = 'ORTAK' and cozuldu_at is null
   and kaynak_zaman > now() - interval '11 hours';
perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now() - interval '2 minutes', null, null,
                                jsonb_build_object('hareket', 'GIRDI'));
v_islem := gen_random_uuid();
v_id2 := public.kamera_okunamadi('ORTAK', v_islem, now() - interval '10 minutes', 'ZZ142EA0I', 0.4,
                                 jsonb_build_object('hareket', 'GIRDI'));
select public.kamera_tek_kapi('ZZ142EA01', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'GIRIS_KARTI'
   or not exists (select 1 from public.biletler
                   where id = (v_json ->> 'bilet_id')::uuid and islem_id = v_islem
                     and giris_at = now() - interval '10 minutes')
   or not exists (select 1 from public.istisnalar where id = v_id2 and cozuldu_at is not null)
   or exists (select 1 from public.istisnalar
               where id = v_id and (cozuldu_at is not null or plaka is not null)) then
  raise exception 'FAIL 142: bir karakter uzak tahminli kart, daha yeni boş karttan önce seçilmedi (%)', v_json;
end if;

raise notice 'PASS 142: içeride okunan plaka önce tahmini benzeyen giriş kartını seçer, sonra boşu (090)';

-- 143 (F6): içeride görülen, bileti ve giriş kartı olmayan araç: bilet o
--     an açılır, işaretlenir, Yönetici bilgilenir — kart yok. 1.4.6'dan
--     kalan açık "İçeride, bileti yok" kartı varsa bilet kartın saatinden
--     açılır ve kart çözülür. Bileti olan araç yeniden görülürse bir şey
--     olmaz. (Kameranın az önce kapattığı araç eskisi gibi
--     CIKMAMIS_OLABILIR: PASS 90d; ödemiş araç ODENMIS_ICERIDE: PASS 132f.)
update public.istisnalar set cozuldu_at = now()
 where tur::text = 'OKUNAMADI' and yon = 'ORTAK' and cozuldu_at is null
   and kaynak_zaman > now() - interval '11 hours';
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ143IG11', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
v_bilet := (v_json ->> 'bilet_id')::uuid;
if v_json ->> 'karar' is distinct from 'GIRIS' or v_json ->> 'sebep' is distinct from 'ICERIDE_GORULDU'
   or not exists (select 1 from public.biletler
                   where id = v_bilet and plaka = 'ZZ143IG11' and durum = 'ACIK' and giris_at = now()
                     and notlar = 'Kamera: girişi görülmedi, içeride görüldü')
   or exists (select 1 from public.istisnalar where plaka = 'ZZ143IG11') then
  raise exception 'FAIL 143a: içeride görülen biletsiz araca bilet açılmadı (%)', v_json;
end if;
if not exists (select 1 from public.notifications
                where tur::text = 'KAMERA_HAREKET' and baslik = 'Girişi görülmedi'
                  and link = '/gise/bilet/' || v_bilet) then
  raise exception 'FAIL 143a: Yönetici bilgilenmedi';
end if;

v_id := public.istisna_yaz('ICERIDE_BILETSIZ', 'ORTAK', 'ZZ143JH22', 'KAMERA', gen_random_uuid(),
                           null, null, now() - interval '1 hour');
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ143JH22', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'ICERIDE_GORULDU'
   or not exists (select 1 from public.biletler
                   where id = (v_json ->> 'bilet_id')::uuid and plaka = 'ZZ143JH22'
                     and giris_at = now() - interval '1 hour')
   or not exists (select 1 from public.istisnalar
                   where id = v_id and cozuldu_at is not null and cozuldu_by is null
                     and cozum_notu like 'Kamera: içeride yeniden görüldü%') then
  raise exception 'FAIL 143b: eski kartın saatinden bilet açılmadı ya da kart çözülmedi (%)', v_json;
end if;

perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ143IG11', gen_random_uuid(), now(), null, null, 'ICERIDE') into v_json;
perform pg_temp.logout();
if v_json ->> 'sebep' is distinct from 'ICERIDE_ACIK'
   or (select count(*) from public.biletler where plaka = 'ZZ143IG11') <> 1 then
  raise exception 'FAIL 143c: bileti olan araç yeniden görülünce ikinci bilet açıldı (%)', v_json;
end if;

raise notice 'PASS 143: içeride görülen biletsiz araca işaretli bilet açılır (eski kart varsa onun saatinden), Yönetici bilgilenir (090)';

-- 144 (F4): kısa ziyaret — aynı iz plakasız girdi, plakasız çıktı: çıkış
--     kartı giriş kartının kimliğini taşır; giriş kartı sistemce çözülür,
--     tek kart kalır. Bozuk kimlik hata vermez, yok sayılır (22P02 webhook'ta
--     REDDEDILDI kartı olurdu).
update public.istisnalar set cozuldu_at = now()
 where tur::text = 'OKUNAMADI' and yon = 'ORTAK' and cozuldu_at is null
   and kaynak_zaman > now() - interval '11 hours';
v_islem := gen_random_uuid();
perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', v_islem, now() - interval '20 minutes', null, null,
                                jsonb_build_object('hareket', 'GIRDI'));
v_id2 := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now(), null, null,
                                 jsonb_build_object('hareket', 'CIKTI', 'giris_islem_id', v_islem::text));
perform pg_temp.logout();
if v_id2 is null
   or not exists (select 1 from public.istisnalar
                   where id = v_id and cozuldu_at is not null and cozuldu_by is null
                     and cozum_notu = 'Kamera: aynı araç çıktı, plaka okunamadı')
   or not exists (select 1 from public.istisnalar where id = v_id2 and cozuldu_at is null) then
  raise exception 'FAIL 144a: kısa ziyaretin giriş kartı çözülmedi ya da çıkış kartı yazılmadı';
end if;

perform pg_temp.kamera();
v_id := public.kamera_okunamadi('ORTAK', gen_random_uuid(), now(), null, null,
                                jsonb_build_object('hareket', 'CIKTI', 'giris_islem_id', 'bozuk'));
select public.kamera_tek_kapi('ZZ144MF01', gen_random_uuid(), now(), null,
                              jsonb_build_object('giris_islem_id', 'bozuk'), 'ICERIDE') into v_json;
select public.kamera_tek_kapi('ZZ144NG02', gen_random_uuid(), now(), null,
                              jsonb_build_object('giris_islem_id', 42), 'CIKTI') into v_json2;
perform pg_temp.logout();
if v_id is null or v_json ->> 'sebep' is distinct from 'ICERIDE_GORULDU'
   or v_json2 ->> 'sebep' is distinct from 'CIKIS_BILETSIZ' then
  raise exception 'FAIL 144b: bozuk giris_islem_id yanlış işlendi (% / % / %)', v_id, v_json, v_json2;
end if;

raise notice 'PASS 144: kısa ziyaretin çıkış kartı giriş kartını çözer; bozuk kimlik yok sayılır (090)';

-- 145: yardımcılar kimseye açık değil; yeniden yazılan kamera
--      fonksiyonlarının tek imzası var (eski imza kalmadı).
foreach v_txt in array array['public.kamera_eski_bileti_kapat(uuid, timestamptz)',
                             'public.plaka_harf_karisir(text, text)',
                             'public.kamera_giris_karti(text, timestamptz, uuid, jsonb, text)',
                             'public.kamera_yeniden_giris(uuid, text, uuid, timestamptz, text, jsonb)'] loop
  if has_function_privilege('anon', v_txt, 'execute')
     or has_function_privilege('authenticated', v_txt, 'execute')
     or has_function_privilege('service_role', v_txt, 'execute') then
    raise exception 'FAIL 145: % bir role açık', v_txt;
  end if;
end loop;
foreach v_txt in array array['kamera_tek_kapi', 'kamera_okunamadi', 'kamera_tahmin_cikis'] loop
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = v_txt) <> 1 then
    raise exception 'FAIL 145: % tek imzayla durmuyor', v_txt;
  end if;
end loop;

raise notice 'PASS 145: 090 yardımcıları kimseye açık değil; kamera fonksiyonlarının tek imzası var';

perform pg_temp.logout();
raise notice '';
raise notice 'ALL TESTS PASSED (rolled back)';

end $$;

rollback;
