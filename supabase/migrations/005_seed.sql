-- =====================================================================
--  Otopark — 005_seed.sql
--  The minimum rows the app needs to start. Safe to re-run.
--
--  Everything here is PLACEHOLDER DATA meant to be edited from the app:
--  prices especially. Change them in Yönetim → Tarifeler, which versions the
--  change properly — do not UPDATE these rows by hand, or a car that entered
--  this morning gets re-priced at tonight's rate.
-- =====================================================================

-- ---------------------------------------------------- settings singleton

insert into public.otopark_ayarlari (id, ad, kapasite)
values (1, 'Otopark', 100)
on conflict (id) do nothing;

-- ------------------------------------------------------------- tarifeler

-- One open-ended tariff per vehicle type; the partial unique index enforces
-- "exactly one current price" from here on.
--
-- Rates below are illustrative Istanbul-ish figures in KURUŞ:
--   ilk_saat 6000 = 60,00 ₺ · gunluk_tavan 25000 = 250,00 ₺
-- gunluk_tavan_kurus = 0 would mean "no daily cap".
insert into public.tarifeler (
  arac_tipi, ucretsiz_dakika, ilk_saat_kurus, sonraki_saat_kurus,
  gunluk_tavan_kurus, kayip_bilet_kurus)
select v.arac_tipi, v.ucretsiz, v.ilk, v.sonraki, v.tavan, v.kayip
  from (values
    ('MOTOSIKLET'::public.arac_tipi, 15,  3000, 1500, 10000, 15000),
    ('OTOMOBIL'::public.arac_tipi,   15,  6000, 3000, 25000, 40000),
    ('MINIBUS'::public.arac_tipi,    15,  8000, 4000, 35000, 50000),
    ('KAMYONET'::public.arac_tipi,   15, 10000, 5000, 45000, 60000)
  ) as v(arac_tipi, ucretsiz, ilk, sonraki, tavan, kayip)
 where not exists (
   select 1 from public.tarifeler t
    where t.arac_tipi = v.arac_tipi and t.gecerli_bitis is null);

-- ---------------------------------------------------------- puan kuralı

-- Points ship OFF (otopark_ayarlari.puan_aktif = false) and this rule is
-- deliberately ZEROED. A rule row must exist so the Yönetici has something to
-- edit, but seeding real values would mean one careless toggle starts issuing
-- a lira-denominated liability at a rate nobody chose. Set the numbers in
-- Yönetim → Puan before enabling the feature.
insert into public.puan_kurallari (kazanim_puan, kurus_per_puan, bekleme_saat, puan_gecerlilik_gun)
select 0, 0, 6, 0
 where not exists (select 1 from public.puan_kurallari where gecerli_bitis is null);

-- --------------------------------------------------------- park yerleri

-- Sample layout so the spot map is not an empty screen on day one. Delete
-- these and enter the real ones — reserved parking is the only feature that
-- depends on them; ordinary tickets never need a spot.
insert into public.park_yerleri (kod, tip, rezerve)
select v.kod, v.tip::public.park_yeri_tip, v.rezerve
  from (values
    ('A-01','NORMAL',false), ('A-02','NORMAL',false), ('A-03','NORMAL',false),
    ('A-04','NORMAL',false), ('A-05','NORMAL',false), ('A-06','NORMAL',false),
    ('A-07','NORMAL',false), ('A-08','NORMAL',false),
    ('B-01','NORMAL',true),  ('B-02','NORMAL',true),
    ('E-01','ENGELLI',false),
    ('S-01','SARJ',false)
  ) as v(kod, tip, rezerve)
 where not exists (select 1 from public.park_yerleri p where p.kod = v.kod);

-- =====================================================================
--  BOOTSTRAP THE FIRST YÖNETİCİ
--
--  Signup is open but gated: every new account lands PENDING with rol = NULL,
--  which RLS reads as "zero rows on every table". That is correct behaviour
--  and it also means the very first account has nobody to approve it.
--
--  Do NOT create this one account by signing up in the app: Supabase requires
--  e-mail confirmation by default and its built-in sender is unreliable, so
--  you can end up locked out of an account you cannot confirm.
--
--  Instead: Authentication → Users → Add user, with "Auto Confirm User"
--  ticked. That insert fires on_auth_user_created, so the profiles row appears
--  by itself. Then run the two statements below with your own e-mail. This is
--  the ONLY time a role is set outside set_role() / approve_signup().
--
--    update public.profiles
--       set rol = 'YONETICI', durum = 'ACTIVE'
--     where id = (select id from auth.users where email = 'siz@ornek.com');
--
--    -- confirm it took:
--    select p.id, u.email, p.rol, p.durum
--      from public.profiles p join auth.users u on u.id = p.id;
--
--  From then on, every further account is approved in Yönetim → Personel.
-- =====================================================================
