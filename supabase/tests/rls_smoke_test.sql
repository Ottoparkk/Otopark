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

select v.fark_kurus into v_ucret from public.vardiya_kapat(0, 'test kapanış') v;
perform pg_temp.logout();
select beklenen_nakit_kurus, sayilan_nakit_kurus, fark_kurus
  into v_rec from public.vardiyalar where id = v_vardiya;
if v_rec.fark_kurus <> 0 - v_rec.beklenen_nakit_kurus then
  raise exception 'FAIL 29: vardiya farkı yanlış hesaplandı';
end if;
select count(*) into v_n from public.notifications
 where tur = 'VARDIYA_FARK' and profile_id = u_yonetici;
if v_n = 0 then raise exception 'FAIL 29: vardiya farkı Yöneticiye bildirilmedi'; end if;
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
select v.id into v_vardiya from public.vardiyalar v
 where v.personel_id = u_personel and v.kapanis_at is null;
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
if not exists (select 1 from public.vardiyalar
                where personel_id = u_personel and kapanis_at is null) then
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
select coalesce(array_agg(distinct p.proname order by p.proname), '{}'::text[])
  into v_liste
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f'
   and has_function_privilege('service_role', p.oid, 'execute');

v_beklenen := array[
  'bildirim_yonetici_turu', 'bilet_ac', 'biletler_immutable_guard',
  'handle_new_user', 'kamera_cikis_bildir', 'kamera_kalp'];

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
  'public.run_vardiya_kurtarma()'
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
-- Temiz başlangıç: u_personel2'nin açık vardiyası varsa tekil indeks insert'i
-- reddederdi.
update public.vardiyalar
   set kapanis_at = now(), kapanis_kaynak = 'ELLE'
 where personel_id = u_personel2 and kapanis_at is null;

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

perform pg_temp.logout();
raise notice '';
raise notice 'ALL TESTS PASSED (rolled back)';

end $$;

rollback;
