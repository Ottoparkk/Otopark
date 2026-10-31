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
  v_gun          date;
  v_ts           timestamptz;
  v_ts2          timestamptz;
  v_txt          text;
  v_txt2         text;
  v_txt3         text;
  v_bool         boolean;
  v_json         jsonb;
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

select count(*) into v_n from public.abonmanlar;
if v_n <> 0 then raise exception 'FAIL 06a: Personel abonman (fiyat) görüyor'; end if;
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
raise notice 'PASS 06: Personel abonman fiyatı, kasa, audit, puan ve okuma logunu göremiyor; tarifeyi görüyor';

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
select b.tahsil_kurus into v_ucret from public.bilet_kapat(v_id, 'NAKIT') b;

-- ...must equal the charge. One function prices a stay, so these cannot differ.
if v_ucret <> v_ucret2 then
  raise exception 'FAIL 18d: gösterilen ücret (%) tahsil edilenden (%) farklı', v_ucret2, v_ucret;
end if;
select t.tur, t.sabit_kurus, t.ucretsiz_dakika, t.ilk_saat_kurus,
       t.sonraki_saat_kurus, t.gunluk_tavan_kurus
  into v_rec
  from public.tarifeler t
  join public.biletler b on b.tarife_id = t.id
 where b.id = v_id;

if v_rec.ucretsiz_dakika >= 180 then
  v_n2 := 0;                                   -- ücretsiz süre 3 saati yutuyor
elsif v_rec.tur = 'SABIT' then
  v_n2 := v_rec.sabit_kurus;                   -- giriş başına tek fiyat
else
  v_n2 := v_rec.ilk_saat_kurus + 2 * v_rec.sonraki_saat_kurus;
  if v_rec.gunluk_tavan_kurus > 0 then
    v_n2 := least(v_n2, v_rec.gunluk_tavan_kurus);
  end if;
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
raise notice 'PASS 18: gösterilen ücret = tahsil edilen ücret (3 saat = 12000 kuruş), tahsilat yazılıyor';

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

-- Personel no longer sees the tickets they closed once the shift is shut.
perform pg_temp.login(u_personel);
select count(*) into v_n from public.biletler where id = v_bilet2;
if v_n <> 0 then raise exception 'FAIL 30: kapanmış vardiyanın biletleri hâlâ görünüyor'; end if;
raise notice 'PASS 30: vardiya kapanınca geçmiş biletler Personel görüşünden çıkıyor';

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

-- (b) service_role: kamera webhook'u ve send-push. Kameranın kasaya tek
--     kapısı bilet AÇMAKTIR — kapatamaz, para toplayamaz, tarifeye
--     dokunamaz. Bu listenin uzaması, kameranın yapabileceklerinin
--     sessizce artması demektir.
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
--     şeyler aynı kalır: bilet açmak ve "kapıda" damgası vurmak.
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
--     dokunmaz, para görmez, hiçbir şeyi silmez ya da ezmez (PASS 64).
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
  'kamera_kalp', 'kamera_kalp_cihaz', 'kamera_okuma_bagla', 'kamera_okuma_hatasi',
  'kamera_okuma_siniri', 'kamera_okunamadi', 'kamera_tek_kapi'];

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
  'public.foto_temizlik_tetikle()'
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
     'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)', 'execute')
   or has_function_privilege('authenticated',
     'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)', 'execute') then
  raise exception 'FAIL 58a: kamera_tek_kapi istemciye açık';
end if;
if not has_function_privilege('service_role',
     'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)', 'execute') then
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

-- (c) İki süre ayardan okunur. Giriş süresi 3 dakikanın altına inememeli:
--     köprü, kadrajda bir şey kıpırdayıp durulunca aynı aracı yeniden
--     gönderebilir; süre kısa olursa kapıda oyalanan, az önce girmiş araç
--     "çıkıyor" diye işaretlenir.
select tek_kapi_giris_yoksay_dk, tek_kapi_cikis_yoksay_dk
  into v_n, v_n2 from public.otopark_ayarlari where id = 1;
if v_n is null or v_n2 is null then
  raise exception 'FAIL 58c: tek kapı süreleri tanımlı değil';
end if;
begin
  update public.otopark_ayarlari set tek_kapi_giris_yoksay_dk = 2 where id = 1;
  raise exception 'FAIL 58c: giriş yok sayma süresi 3 dakikanın altına indi';
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

-- (i) Açık bileti olan plaka ÇIKIYORDUR: yalnızca "kapıda" damgası. Bilet
--     AÇIK kalır, tek kuruş hareket etmez — tahsilatı insan yapar.
perform pg_temp.kamera();
select public.kamera_tek_kapi('ZZ58TK001', gen_random_uuid(), now()) into v_json;
perform pg_temp.logout();
if v_json ->> 'karar' <> 'CIKIS' or (v_json ->> 'bilet_id')::uuid is distinct from v_bilet then
  raise exception 'FAIL 58i: içerideki araç için karar CIKIS değil (%)', v_json;
end if;
if not exists (select 1 from public.biletler
                where id = v_bilet and durum = 'ACIK' and cikis_at is null
                  and cikis_bekliyor_at is not null and tahsil_kurus = 0) then
  raise exception 'FAIL 58i: çıkış olayı bileti kapattı ya da damgalamadı';
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

-- Açık bilet, damgayı GERÇEK yoldan alır: kameranın çıkış kapısı.
insert into public.biletler (islem_id, plaka, giris_at, tarife_id, durum)
select gen_random_uuid(), 'ZZ59KPD01', now() - interval '1 hour', t.id, 'ACIK'
  from public.tarifeler t where t.gecerli_bitis is null order by t.id limit 1
returning id into v_bilet;
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ59KPD01', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
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
perform pg_temp.kamera();
perform public.kamera_cikis_bildir('ZZ59KPD01', gen_random_uuid(), now(), null, null);
perform pg_temp.logout();
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

-- (b) Giriş şeridinde okunamayan araç: TEK kayıt, TEK bildirim. Fotoğraf
--     ham yanıtta SAKLANMAZ (her satırı yüzlerce KB yapıyordu).
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
     where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n + 1 then
  raise exception 'FAIL 60b: Yöneticiye tam bir bildirim gitmedi';
end if;

-- (c) Aynı olay yeniden gelirse ikinci kayıt ve ikinci bildirim olmaz.
perform pg_temp.kamera();
select public.kamera_okunamadi('GIRIS', v_islem, now(), null, null, null) into v_id2;
perform pg_temp.logout();
if v_id2 is distinct from v_id
   or (select count(*) from public.istisnalar where islem_id = v_islem) <> 1
   or (select count(*) from public.notifications
        where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n + 1 then
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

-- (a) Asıl kural. İlk deneme okuyamadı (kayıt + tek bildirim), cevap
--     kayboldu, yeniden deneme okudu: araç YENİ — bilet bu olayın kimliğiyle
--     açılır, önceki kayıt sistemce kapanır, ikinci bildirim gitmez.
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
     where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n + 1 then
  raise exception 'FAIL 63a: tek bildirim beklenirdi (okunamadı) — yeniden deneme bildirim üretmemeli';
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
--     ikinci bildirim yok, benzer bilet "kapıda" yapılmaz.
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
     where tur = 'ISTISNA' and profile_id = u_yonetici) <> v_n + 1 then
  raise exception 'FAIL 63d: yeniden deneme ikinci bildirim gönderdi';
end if;
if exists (select 1 from public.biletler where plaka = 'ZZ63BN308')
   or (select cikis_bekliyor_at from public.biletler where id = v_bilet) is not null then
  raise exception 'FAIL 63d: belirsiz okuma bilet açtı ya da benzer bileti "kapıda" yaptı';
end if;

-- (e) Yeniden deneme içerideki eski aracın (CK404) plakasını okudu: araç
--     çıkıyor. Bilet "kapıda" damgalanır (AÇIK kalır, para insanda), önceki
--     kayıt sistemce kapanır.
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
                where id = v_bilet2 and durum = 'ACIK' and cikis_at is null
                  and cikis_bekliyor_at is not null) then
  raise exception 'FAIL 63e: çıkan araç "kapıda" damgalanmadı ya da bileti kapandı';
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
  'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)',
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
if to_regprocedure('public.kamera_foto_bagla(uuid, uuid, timestamptz, text)') is null then
  raise exception 'FAIL 64a: kamera_foto_bagla yok — 042 koşulmamış';
end if;
if not has_function_privilege('service_role',
     'public.kamera_foto_bagla(uuid, uuid, timestamptz, text)', 'execute') then
  raise exception 'FAIL 64a: kamera_foto_bagla service_role rolüne kapalı — webhook bağlayamaz';
end if;
foreach v_txt in array array['anon', 'authenticated'] loop
  if has_function_privilege(v_txt,
       'public.kamera_foto_bagla(uuid, uuid, timestamptz, text)', 'execute') then
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

-- (d) Çıkış kapısı: "kapıda" damgası fotoğrafını alır — ama yalnızca bu
--     olayın vurduğu damga (aynı zaman). Başka zamanla çağrı 0 döner; giriş
--     fotoğrafına dokunulmaz (biletin islem_id'si girişin kimliğidir).
v_islem := gen_random_uuid();
perform pg_temp.kamera();
select public.bilet_ac('ZZ64CX222', v_islem, 'KAMERA', now()) into v_bilet2;
v_islem := gen_random_uuid();
v_txt2 := 'kamera/' || v_islem::text || '.jpg';
v_ts := now() - interval '10 seconds';
select public.kamera_cikis_bildir('ZZ64CX222', v_islem, v_ts) into v_id;
select public.kamera_foto_bagla(v_islem, v_bilet2, v_ts + interval '1 second', v_txt2) into v_n;
select public.kamera_foto_bagla(v_islem, v_bilet2, v_ts, v_txt2) into v_n2;
perform pg_temp.logout();
if v_id is distinct from v_bilet2 or v_n <> 0 or v_n2 <> 1
   or not exists (select 1 from public.biletler
                   where id = v_bilet2 and durum = 'ACIK' and cikis_foto = v_txt2
                     and giris_foto is null and cikis_bekliyor_at = v_ts) then
  raise exception 'FAIL 64d: çıkış damgasının fotoğrafı yanlış bağlandı (% / %)', v_n, v_n2;
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

perform pg_temp.logout();
raise notice '';
raise notice 'ALL TESTS PASSED (rolled back)';

end $$;

rollback;
