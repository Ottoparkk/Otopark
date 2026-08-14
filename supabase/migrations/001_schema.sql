-- =====================================================================
--  Otopark — 001_schema.sql
--  Tables, enums, constraints, indexes. No functions, no RLS (see 002/003).
--  Run the migrations in numeric order in the Supabase SQL editor.
--
--  Money convention: integer kuruş everywhere. There is no NUMERIC and no
--  float in this schema — a fee is a count of kuruş, and counts are exact.
-- =====================================================================

create extension if not exists pgcrypto;
-- btree_gist lets an EXCLUDE constraint mix `=` on a scalar with `&&` on a
-- range. Both the reservation and the subscription overlap guards need it.
create extension if not exists btree_gist;

-- ------------------------------------------------------------------ enums

create type public.rol              as enum ('YONETICI','PERSONEL');
create type public.kullanici_durum  as enum ('PENDING','ACTIVE','DISABLED');
create type public.arac_tipi        as enum ('MOTOSIKLET','OTOMOBIL','MINIBUS','KAMYONET');
create type public.bilet_durum      as enum ('ACIK','KAPALI','IPTAL');
create type public.odeme_yontemi    as enum ('NAKIT','KREDI_KARTI','HAVALE');
create type public.kaynak           as enum ('MOBIL','KAMERA','MANUEL');
create type public.park_yeri_tip    as enum ('NORMAL','ENGELLI','SARJ');
create type public.abonman_durum    as enum ('AKTIF','DOLDU','IPTAL');
create type public.istisna_tur      as enum ('GELECEK','BAYAT','ACIK_BILET_YOK','COKLU_ESLESME');
create type public.hesap_durum      as enum ('AKTIF','PASIF');
create type public.puan_hareket_tur as enum ('KAZANIM','KULLANIM','IPTAL','DUZELTME');
create type public.kasa_tur         as enum ('GELIR','GIDER');
create type public.tahsilat_tur     as enum ('BILET','ABONMAN');
create type public.bildirim_tur     as enum (
  'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
  'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA','ISTISNA'
);

-- --------------------------------------------------------------- profiles

create table public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  ad_soyad    text not null default '',
  -- NULL until a Yönetici assigns one. RLS keys off this: no role, no rows.
  rol         public.rol,
  durum       public.kullanici_durum not null default 'PENDING',
  notif_prefs jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

comment on column public.profiles.rol is
  'NULL = not yet approved. Every RLS policy requires a non-null rol AND durum = ACTIVE.';

-- ------------------------------------------------------ otopark_ayarlari

-- Single lot (owner decision): one settings row, enforced by the id check.
create table public.otopark_ayarlari (
  id                       smallint primary key default 1 check (id = 1),
  ad                       text not null default 'Otopark',
  adres                    text,
  telefon                  text,
  kapasite                 integer not null default 100 check (kapasite > 0),
  -- 'KAPALI' ships the app with zero external dependency and zero cost.
  plaka_saglayici          text not null default 'KAPALI'
                             check (plaka_saglayici in ('KAPALI','VLM','ALPR')),
  -- The concrete vendor/model, deliberately NOT check-constrained: the OCR
  -- provider is the one decision we have called provisional, so swapping it
  -- must never need an ALTER TABLE. The Edge Function validates this against
  -- its own hardcoded allowlist — request hosts are never taken from the DB
  -- (OWASP SSRF), so an unexpected value fails closed instead of dialling out.
  plaka_model              text,
  -- KVKK: a plate photo is personal data with a short life (nightly purge).
  foto_saklama_gun         integer not null default 30
                             check (foto_saklama_gun between 0 and 3650),
  -- A buffered camera event older than this is not turned into a ticket.
  kamera_gecikme_limiti_dk integer not null default 720
                             check (kamera_gecikme_limiti_dk between 1 and 10080),
  puan_aktif               boolean not null default false,
  -- Separate from plaka_saglayici on purpose: a camera that sends plate TEXT
  -- needs no OCR at all, so gating hardware behind the OCR switch would force
  -- the owner to enable (and pay for) a model they do not use.
  kamera_aktif             boolean not null default false,
  -- A camera cannot tell a Clio from a Transit. Entries it creates get this
  -- tariff, and an operator can correct the type at exit while the ticket is
  -- still open (bilet_arac_tipi_duzelt), which re-snapshots the tariff.
  kamera_varsayilan_arac_tipi public.arac_tipi not null default 'OTOMOBIL',
  terk_esik_saat           integer not null default 48
                             check (terk_esik_saat between 1 and 720),
  doluluk_uyari_yuzde      integer not null default 90
                             check (doluluk_uyari_yuzde between 1 and 100),
  kamera_kalp_atisi        timestamptz,
  kamera_kalp_esik_dk      integer not null default 15
                             check (kamera_kalp_esik_dk between 1 and 1440),
  guncelleyen              uuid references public.profiles(id) on delete set null,
  updated_at               timestamptz not null default now()
);

comment on column public.otopark_ayarlari.kamera_kalp_atisi is
  'Bumped by kamera-webhook. A stale value means the camera or the bridge died — '
  'a dead camera looks exactly like an empty car park, so cron raises an alert.';

-- ----------------------------------------------------------- park_yerleri

create table public.park_yerleri (
  id         uuid primary key default gen_random_uuid(),
  kod        text not null,
  tip        public.park_yeri_tip not null default 'NORMAL',
  rezerve    boolean not null default false,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index park_yerleri_kod_ux on public.park_yerleri (kod);

-- -------------------------------------------------------------- tarifeler

-- Versioned, never edited in place: a ticket snapshots tarife_id at entry, so
-- raising the rate at noon cannot re-price a car that came in at 09:00.
create table public.tarifeler (
  id                 uuid primary key default gen_random_uuid(),
  arac_tipi          public.arac_tipi not null,
  ucretsiz_dakika    integer not null default 15 check (ucretsiz_dakika between 0 and 1440),
  ilk_saat_kurus     integer not null check (ilk_saat_kurus >= 0),
  sonraki_saat_kurus integer not null check (sonraki_saat_kurus >= 0),
  -- 0 = no daily cap.
  gunluk_tavan_kurus integer not null default 0 check (gunluk_tavan_kurus >= 0),
  kayip_bilet_kurus  integer not null default 0 check (kayip_bilet_kurus >= 0),
  gecerli_baslangic  timestamptz not null default now(),
  gecerli_bitis      timestamptz,
  olusturan          uuid references public.profiles(id) on delete set null,
  created_at         timestamptz not null default now(),
  constraint tarifeler_donem_ck
    check (gecerli_bitis is null or gecerli_bitis > gecerli_baslangic)
);
-- Exactly one open-ended tariff per vehicle type — "the current price" can
-- never be ambiguous.
create unique index tarifeler_aktif_ux
  on public.tarifeler (arac_tipi) where gecerli_bitis is null;

-- ------------------------------------------------------------- vardiyalar

create table public.vardiyalar (
  id                   uuid primary key default gen_random_uuid(),
  personel_id          uuid not null references public.profiles(id) on delete restrict,
  acilis_at            timestamptz not null default now(),
  kapanis_at           timestamptz,
  acilis_nakit_kurus   integer not null default 0 check (acilis_nakit_kurus >= 0),
  beklenen_nakit_kurus integer,
  sayilan_nakit_kurus  integer check (sayilan_nakit_kurus is null or sayilan_nakit_kurus >= 0),
  fark_kurus           integer,
  notlar               text,
  constraint vardiyalar_kapanis_ck check (kapanis_at is null or kapanis_at >= acilis_at)
);
create unique index vardiyalar_acik_ux
  on public.vardiyalar (personel_id) where kapanis_at is null;

-- ------------------------------------------------------------- abonmanlar

create table public.abonmanlar (
  id           uuid primary key default gen_random_uuid(),
  plaka        text not null check (plaka ~ '^[A-Z0-9]{2,15}$'),
  musteri_ad   text not null default '',
  musteri_tel  text check (musteri_tel is null or musteri_tel ~ '^[1-9][0-9]{9}$'),
  baslangic    date not null,
  bitis        date not null,
  ucret_kurus  integer not null default 0 check (ucret_kurus >= 0),
  park_yeri_id uuid references public.park_yerleri(id) on delete set null,
  durum        public.abonman_durum not null default 'AKTIF',
  notlar       text,
  olusturan    uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  constraint abonmanlar_donem_ck check (bitis >= baslangic)
);
-- Two live subscriptions for one plate must not overlap in time, or
-- abonman_gecerli_mi() would have to pick between them.
alter table public.abonmanlar
  add constraint abonmanlar_plaka_donem_ex
  exclude using gist (plaka with =, daterange(baslangic, bitis, '[]') with &&)
  where (durum <> 'IPTAL');
create index abonmanlar_plaka_ix on public.abonmanlar (plaka);

-- --------------------------------------------------------- rezervasyonlar

create table public.rezervasyonlar (
  id           uuid primary key default gen_random_uuid(),
  park_yeri_id uuid not null references public.park_yerleri(id) on delete cascade,
  abonman_id   uuid references public.abonmanlar(id) on delete cascade,
  plaka        text check (plaka is null or plaka ~ '^[A-Z0-9]{2,15}$'),
  gecerlilik   tstzrange not null,
  notlar       text,
  olusturan    uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  constraint rezervasyonlar_bos_ck  check (not isempty(gecerlilik)),
  constraint rezervasyonlar_hedef_ck check (abonman_id is not null or plaka is not null),
  -- The database refuses a double-booked spot. Never filter for this on the
  -- client — two operators can always race.
  constraint rezervasyonlar_cakisma_ex
    exclude using gist (park_yeri_id with =, gecerlilik with &&)
);

-- ------------------------------------------------------- puan (loyalty) --

create table public.hesaplar (
  id         uuid primary key default gen_random_uuid(),
  ad         text not null check (length(btrim(ad)) > 0),
  telefon    text check (telefon is null or telefon ~ '^[1-9][0-9]{9}$'),
  durum      public.hesap_durum not null default 'AKTIF',
  notlar     text,
  olusturan  uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.hesap_araclari (
  id         uuid primary key default gen_random_uuid(),
  hesap_id   uuid not null references public.hesaplar(id) on delete cascade,
  plaka      text not null check (plaka ~ '^[A-Z0-9]{2,15}$'),
  created_at timestamptz not null default now()
);
-- One plate belongs to exactly one account, or entry could not decide who earns.
create unique index hesap_araclari_plaka_ux on public.hesap_araclari (plaka);

create table public.puan_kurallari (
  id                  uuid primary key default gen_random_uuid(),
  -- `tekil` exists only to give the partial unique index a column to key on:
  -- at most one rule may be open-ended at a time.
  tekil               boolean not null default true check (tekil),
  kazanim_puan        integer not null check (kazanim_puan >= 0),
  kurus_per_puan      integer not null check (kurus_per_puan >= 0),
  bekleme_saat        integer not null default 6 check (bekleme_saat between 0 and 720),
  puan_gecerlilik_gun integer not null default 0 check (puan_gecerlilik_gun >= 0),
  gecerli_baslangic   timestamptz not null default now(),
  gecerli_bitis       timestamptz,
  olusturan           uuid references public.profiles(id) on delete set null,
  created_at          timestamptz not null default now(),
  constraint puan_kurallari_donem_ck
    check (gecerli_bitis is null or gecerli_bitis > gecerli_baslangic)
);
create unique index puan_kurallari_aktif_ux
  on public.puan_kurallari (tekil) where gecerli_bitis is null;

-- --------------------------------------------------------------- biletler

create table public.biletler (
  id                 uuid primary key default gen_random_uuid(),
  -- Idempotency key. Every ANPR camera retries a failed POST; without this
  -- one retry is one duplicate ticket. Also makes client retry-on-blip safe.
  islem_id           uuid not null,
  plaka              text not null check (plaka ~ '^[A-Z0-9]{2,15}$'),
  arac_tipi          public.arac_tipi not null,
  giris_at           timestamptz not null,
  cikis_at           timestamptz,
  tarife_id          uuid not null references public.tarifeler(id) on delete restrict,
  ucret_kurus        integer not null default 0 check (ucret_kurus >= 0),
  indirim_kurus      integer not null default 0 check (indirim_kurus >= 0),
  puan_kullanilan    integer not null default 0 check (puan_kullanilan >= 0),
  tahsil_kurus       integer not null default 0 check (tahsil_kurus >= 0),
  odeme_yontemi      public.odeme_yontemi,
  durum              public.bilet_durum not null default 'ACIK',
  abonman_id         uuid references public.abonmanlar(id) on delete set null,
  park_yeri_id       uuid references public.park_yerleri(id) on delete set null,
  -- Entry shift and exit shift are different columns on purpose: the cash
  -- belongs to whoever was on the till at exit, not at entry.
  vardiya_id         uuid references public.vardiyalar(id) on delete set null,
  kapatan_vardiya_id uuid references public.vardiyalar(id) on delete set null,
  giris_by           uuid references public.profiles(id) on delete set null,
  cikis_by           uuid references public.profiles(id) on delete set null,
  giris_kaynak       public.kaynak not null default 'MOBIL',
  cikis_kaynak       public.kaynak,
  giris_foto         text,
  cikis_foto         text,
  -- Replay awareness: kaynak_zaman is when it happened, alindi_zaman is when
  -- we heard about it. Keeping both is what makes buffering lag visible.
  gecikmeli_kayit    boolean not null default false,
  kaynak_zaman       timestamptz,
  alindi_zaman       timestamptz,
  kayip_bilet        boolean not null default false,
  ucret_degistirildi boolean not null default false,
  ucret_sebep        text,
  -- Set by the camera when a car reaches the exit lane. Informational only:
  -- a camera can report, but it can never collect money.
  cikis_bekliyor_at  timestamptz,
  iptal_sebep        text,
  iptal_by           uuid references public.profiles(id) on delete set null,
  iptal_at           timestamptz,
  created_at         timestamptz not null default now(),

  constraint biletler_cikis_ck  check (cikis_at is null or cikis_at >= giris_at),
  constraint biletler_kapali_ck check (durum <> 'KAPALI' or cikis_at is not null),
  -- The money identity, enforced by the database on every closed ticket:
  -- collected = charged - discount, and a discount can never exceed the fee.
  constraint biletler_indirim_ck
    check (durum <> 'KAPALI' or indirim_kurus <= ucret_kurus),
  constraint biletler_tahsil_ck
    check (durum <> 'KAPALI' or tahsil_kurus = ucret_kurus - indirim_kurus),
  constraint biletler_yontem_ck
    check (durum <> 'KAPALI' or tahsil_kurus = 0 or odeme_yontemi is not null),
  constraint biletler_iptal_ck
    check (durum <> 'IPTAL' or iptal_sebep is not null)
);

create unique index biletler_islem_id_ux  on public.biletler (islem_id);
-- Two operators tapping "Giriş" for the same car cannot both succeed.
create unique index biletler_acik_plaka_ux on public.biletler (plaka) where durum = 'ACIK';
create index biletler_acik_ix   on public.biletler (giris_at desc) where durum = 'ACIK';
create index biletler_plaka_ix  on public.biletler (plaka);
create index biletler_kapali_ix on public.biletler (cikis_at desc) where durum = 'KAPALI';
create index biletler_vardiya_ix on public.biletler (kapatan_vardiya_id);

-- -------------------------------------------------------- puan_hareketleri

-- Append-only ledger. UPDATE/DELETE are revoked from every client role in
-- 003 — outstanding points are a real lira liability, so they get the same
-- treatment as cash: corrections are counter-entries, never edits.
create table public.puan_hareketleri (
  id         uuid primary key default gen_random_uuid(),
  hesap_id   uuid not null references public.hesaplar(id) on delete cascade,
  tur        public.puan_hareket_tur not null,
  puan       integer not null check (puan <> 0),
  bilet_id   uuid references public.biletler(id) on delete set null,
  kural_id   uuid references public.puan_kurallari(id) on delete restrict,
  aciklama   text,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint puan_hareketleri_yon_ck check (
    (tur = 'KAZANIM'  and puan > 0) or
    (tur = 'KULLANIM' and puan < 0) or
    tur in ('IPTAL','DUZELTME')      -- counter-entries go either way
  )
);
create index puan_hareketleri_hesap_ix on public.puan_hareketleri (hesap_id, created_at desc);
create index puan_hareketleri_bilet_ix on public.puan_hareketleri (bilet_id);

-- ------------------------------------------------------------ tahsilatlar

-- What was actually collected, and by which shift. Negative rows are
-- counter-entries for cancellations — nothing is ever deleted.
create table public.tahsilatlar (
  id          uuid primary key default gen_random_uuid(),
  tur         public.tahsilat_tur not null,
  bilet_id    uuid references public.biletler(id) on delete set null,
  abonman_id  uuid references public.abonmanlar(id) on delete set null,
  tutar_kurus integer not null check (tutar_kurus <> 0),
  yontem      public.odeme_yontemi not null,
  vardiya_id  uuid references public.vardiyalar(id) on delete set null,
  iptal_of    uuid references public.tahsilatlar(id) on delete set null,
  aciklama    text,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index tahsilatlar_vardiya_ix on public.tahsilatlar (vardiya_id);
create index tahsilatlar_tarih_ix   on public.tahsilatlar (created_at desc);
create index tahsilatlar_bilet_ix   on public.tahsilatlar (bilet_id);
-- One cancellation may reverse a collection exactly once.
create unique index tahsilatlar_iptal_ux
  on public.tahsilatlar (iptal_of) where iptal_of is not null;

-- ------------------------------------------------------- kasa_hareketleri

create table public.kasa_hareketleri (
  id          uuid primary key default gen_random_uuid(),
  tur         public.kasa_tur not null,
  tutar_kurus integer not null check (tutar_kurus > 0),
  kategori    text,
  aciklama    text not null default '',
  yontem      public.odeme_yontemi,
  tarih       date not null default ((now() at time zone 'Europe/Istanbul')::date),
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index kasa_hareketleri_tarih_ix on public.kasa_hareketleri (tarih desc);

-- -------------------------------------------------------------- istisnalar

-- Deliberately NOT named kamera_istisnalari: two of its four cases (orphan
-- exit, multiple match) are everyday phone-typo problems, so this table earns
-- its keep from day one rather than waiting for hardware.
create table public.istisnalar (
  id             uuid primary key default gen_random_uuid(),
  tur            public.istisna_tur not null,
  yon            text not null check (yon in ('GIRIS','CIKIS')),
  plaka          text,
  kaynak         public.kaynak not null default 'KAMERA',
  islem_id       uuid,
  ham_yanit      jsonb,
  foto_path      text,
  kaynak_zaman   timestamptz,
  alindi_zaman   timestamptz not null default now(),
  aday_bilet_ids uuid[],
  cozuldu_by     uuid references public.profiles(id) on delete set null,
  cozuldu_at     timestamptz,
  cozum_notu     text,
  created_at     timestamptz not null default now()
);
create index istisnalar_acik_ix on public.istisnalar (created_at desc) where cozuldu_at is null;
-- A retrying camera logs one exception, not fifty.
create unique index istisnalar_islem_ux
  on public.istisnalar (islem_id) where islem_id is not null;

-- --------------------------------------------------------- plaka_okuma_log

-- The evidence trail that answers "is OCR actually earning its keep?".
-- Comparing onerilen vs kabul_edilen gives a real accuracy rate after a
-- month, so the provider decision gets re-made with data, not re-argued.
create table public.plaka_okuma_log (
  id            uuid primary key default gen_random_uuid(),
  saglayici     text not null,
  ham_yanit     jsonb,
  guven         numeric(5,4) check (guven is null or (guven >= 0 and guven <= 1)),
  onerilen      text,
  kabul_edilen  text,
  operator_id   uuid references public.profiles(id) on delete set null,
  gecen_ms      integer,
  created_at    timestamptz not null default now()
);
create index plaka_okuma_log_tarih_ix on public.plaka_okuma_log (created_at desc);

-- ----------------------------------------------------------- notifications

create table public.notifications (
  id         uuid primary key default gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  tur        public.bildirim_tur not null,
  baslik     text not null,
  govde      text not null default '',
  link       text,
  read_at    timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_kisi_ix on public.notifications (profile_id, created_at desc);
create index notifications_okunmamis_ix
  on public.notifications (profile_id) where read_at is null;

create table public.push_subscriptions (
  endpoint   text primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
create index push_subscriptions_kisi_ix on public.push_subscriptions (profile_id);

-- --------------------------------------------------------------- audit_log

create table public.audit_log (
  id         bigint generated always as identity primary key,
  actor      uuid references public.profiles(id) on delete set null,
  action     text not null,
  tablo      text,
  row_id     uuid,
  detay      jsonb,
  created_at timestamptz not null default now()
);
create index audit_log_tarih_ix on public.audit_log (created_at desc);
create index audit_log_satir_ix on public.audit_log (tablo, row_id);
