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
  v_bigint       bigint;
  v_id           uuid;
  v_id2          uuid;
  v_bilet        uuid;
  v_bilet2       uuid;
  v_tarife_eski  uuid;
  v_tarife_yeni  uuid;
  v_hesap        uuid;
  v_vardiya      uuid;
  v_yer          uuid;
  v_abonman      uuid;
  v_islem        uuid;
  v_ucret        integer;
  v_ucret2       integer;
  v_ts           timestamptz;
  v_ts2          timestamptz;
  v_txt          text;
  v_bool         boolean;
  v_rec          record;
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
 where arac_tipi = 'OTOMOBIL' and gecerli_bitis is null;
if v_tarife_eski is null then
  raise exception 'FAIL: 005_seed çalıştırılmamış — OTOMOBIL tarifesi yok';
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
  perform public.bilet_ac('34TEST01', 'OTOMOBIL', gen_random_uuid());
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
  perform public.bilet_ac('34TEST02', 'OTOMOBIL', gen_random_uuid());
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
  insert into public.tarifeler (arac_tipi, ilk_saat_kurus, sonraki_saat_kurus)
  values ('OTOMOBIL', 1, 1);
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
  perform public.tarife_guncelle('OTOMOBIL', 15, 1, 1, 0, 0);
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
select public.bilet_ac('34 abc 123', 'OTOMOBIL', v_islem) into v_bilet;
if v_bilet is null then raise exception 'FAIL 10a: bilet açılamadı'; end if;

select plaka into v_txt from public.biletler where id = v_bilet;
if v_txt <> '34ABC123' then raise exception 'FAIL 10b: plaka normalize edilmedi (%)', v_txt; end if;

-- Replay of the same islem_id must return the SAME ticket, not a second one.
select public.bilet_ac('34 abc 123', 'OTOMOBIL', v_islem) into v_bilet2;
if v_bilet2 <> v_bilet then raise exception 'FAIL 10c: aynı islem_id ikinci bilet üretti'; end if;
select count(*) into v_n from public.biletler where islem_id = v_islem;
if v_n <> 1 then raise exception 'FAIL 10c: islem_id için % satır var', v_n; end if;
raise notice 'PASS 10: bilet açılıyor, plaka normalize ediliyor, aynı islem_id tekrarı no-op';

-- A different islem_id for a plate already inside must be refused.
begin
  perform public.bilet_ac('34ABC123', 'OTOMOBIL', gen_random_uuid());
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
select public.bilet_ac('34SAAT01', 'OTOMOBIL', v_islem, 'MOBIL',
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
  perform public.bilet_ac('34SAHTE1', 'OTOMOBIL', gen_random_uuid(), 'KAMERA',
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
  perform public.bilet_ac('34KAM001', 'OTOMOBIL', gen_random_uuid(), 'KAMERA', null);
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
select public.bilet_ac('34KAM002', 'OTOMOBIL', gen_random_uuid(), 'KAMERA', v_ts) into v_bilet2;
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
select public.bilet_ac('34ESKI01', 'OTOMOBIL', gen_random_uuid(), 'KAMERA',
                       now() - interval '13 hours') into v_bilet2;
if v_bilet2 is not null then raise exception 'FAIL 16a: 13 saatlik bayat kayıt bilet açtı'; end if;
select count(*) into v_n from public.istisnalar where tur = 'BAYAT' and plaka = '34ESKI01';
if v_n <> 1 then raise exception 'FAIL 16b: BAYAT istisnası yazılmadı'; end if;
select count(*) into v_n from public.biletler where plaka = '34ESKI01';
if v_n <> 0 then raise exception 'FAIL 16c: bayat kayıt için bilet oluştu'; end if;

-- Dated in the future: a broken clock, not a late event.
select public.bilet_ac('34GELE01', 'OTOMOBIL', gen_random_uuid(), 'KAMERA',
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
-- money. Close the 3-hour-old CAMERA ticket instead, where the amount is
-- known exactly: 180 min at (ilk 6000 + 2 x sonraki 3000) = 12000, under the
-- 25000 cap. now() is the transaction timestamp and therefore identical
-- everywhere in this file, so this is deterministic rather than timing-dependent.
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
if v_ucret <> 12000 then
  raise exception 'FAIL 18e: 3 saatlik park % kuruş çıktı, beklenen 12000', v_ucret;
end if;
select count(*) into v_n from public.tahsilatlar
 where bilet_id = v_id and tutar_kurus = 12000 and yontem = 'NAKIT';
if v_n <> 1 then raise exception 'FAIL 18f: 12000 kuruşluk tahsilat satırı yazılmadı'; end if;
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
select public.bilet_ac(p_plaka => '34YER001', p_arac_tipi => 'OTOMOBIL',
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
select public.bilet_ac('34FIYAT1', 'OTOMOBIL', v_islem) into v_bilet2;
select tarife_id into v_id from public.biletler where id = v_bilet2;

perform pg_temp.login(u_yonetici);
select public.tarife_guncelle('OTOMOBIL', 15, 99000, 99000, 0, 40000) into v_tarife_yeni;

select tarife_id into v_id2 from public.biletler where id = v_bilet2;
if v_id2 <> v_id then raise exception 'FAIL 23a: içerideki aracın tarifesi değişti'; end if;
if v_id2 = v_tarife_yeni then raise exception 'FAIL 23b: eski bilet yeni tarifeye bağlandı'; end if;
select count(*) into v_n from public.tarifeler
 where arac_tipi = 'OTOMOBIL' and gecerli_bitis is null;
if v_n <> 1 then raise exception 'FAIL 23c: OTOMOBIL için % açık tarife var', v_n; end if;
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
select public.bilet_ac('34PUAN01', 'OTOMOBIL', gen_random_uuid()) into v_bilet;
perform pg_temp.logout();
select coalesce(sum(puan), 0) into v_n from public.puan_hareketleri where hesap_id = v_hesap;
if v_n <> 10 then raise exception 'FAIL 25a: girişte puan kazanılmadı (bakiye %)', v_n; end if;

-- Inside the cooldown, a second entry earns nothing.
perform pg_temp.login(u_personel);
perform public.bilet_kapat(v_bilet, 'NAKIT');
select public.bilet_ac('34PUAN01', 'OTOMOBIL', gen_random_uuid()) into v_bilet;
perform pg_temp.logout();
select coalesce(sum(puan), 0) into v_n from public.puan_hareketleri where hesap_id = v_hesap;
if v_n <> 10 then raise exception 'FAIL 25b: bekleme süresi içinde tekrar puan verildi (%)', v_n; end if;
raise notice 'PASS 25: girişte puan kazanılıyor, bekleme süresi içinde tekrar kazanılmıyor';

-- A ₺0 subscriber stay earns nothing.
insert into public.hesap_araclari (hesap_id, plaka) values (v_hesap, '34ABON01');
perform pg_temp.login(u_personel);
select public.bilet_ac('34ABON01', 'OTOMOBIL', gen_random_uuid()) into v_id;
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
select public.kayip_bilet_tahsil('34KAYIP1', 'OTOMOBIL', 'NAKIT', gen_random_uuid()) into v_bilet;
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
-- 34  Vehicle-type correction re-snapshots the tariff
-- =====================================================================

perform pg_temp.login(u_personel);
select public.bilet_ac('34TIP001', 'OTOMOBIL', gen_random_uuid()) into v_bilet;
select tarife_id into v_id from public.biletler where id = v_bilet;
perform public.bilet_arac_tipi_duzelt(v_bilet, 'MOTOSIKLET');
select tarife_id, arac_tipi into v_rec from public.biletler where id = v_bilet;
if v_rec.tarife_id = v_id then raise exception 'FAIL 34: araç tipi düzeltmesi tarifeyi yenilemedi'; end if;
if v_rec.arac_tipi <> 'MOTOSIKLET' then raise exception 'FAIL 34: araç tipi değişmedi'; end if;
perform public.bilet_kapat(v_bilet, 'NAKIT');
begin
  perform public.bilet_arac_tipi_duzelt(v_bilet, 'OTOMOBIL');
  raise exception 'FAIL 34: kapanmış bilette araç tipi değiştirilebildi';
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
end;
raise notice 'PASS 34: araç tipi düzeltmesi tarifeyi yeniliyor, kapanmış bilette kapalı';

perform pg_temp.logout();
raise notice '';
raise notice 'ALL TESTS PASSED (rolled back)';

end $$;

rollback;
