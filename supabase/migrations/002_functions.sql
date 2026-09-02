-- =====================================================================
--  Otopark — 002_functions.sql
--  Helpers, fee math, and every RPC that moves money or state.
--
--  Rule for this whole file: biletler / tahsilatlar / puan_hareketleri have
--  NO client INSERT or UPDATE policy at all (see 003). Every write to them
--  goes through a SECURITY DEFINER function here. That is what makes "the
--  client cannot write a fee" structural rather than a convention.
--
--  All EXECUTE grants and revokes live in 003_rls.sql, so the security
--  surface can be audited in one place.
-- =====================================================================

-- ============================================================ helpers ====

-- Both require durum = 'ACTIVE': a disabled account loses access at its very
-- next request, without needing its rows touched.
create or replace function public.is_yonetici() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and rol = 'YONETICI' and durum = 'ACTIVE'
  );
$$;

create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and rol is not null and durum = 'ACTIVE'
  );
$$;

/**
 * Turkish plate normalisation. Folds Turkish letters BEFORE upper(), because
 * upper('ı') is locale-dependent and would otherwise survive as 'ı' and fail
 * the [A-Z0-9] check. Strips every separator: "34 abc 12" and "34-ABC-12"
 * are the same car.
 */
create or replace function public.normalize_plaka(p_plaka text) returns text
language sql immutable as $$
  select regexp_replace(
           upper(translate(coalesce(p_plaka, ''),
                           'ıİçÇğĞöÖşŞüÜ',
                           'IIcCgGoOsSuU')),
           '[^A-Z0-9]', '', 'g');
$$;

create or replace function public.audit(
  p_action text, p_tablo text, p_row_id uuid, p_detay jsonb default null
) returns void
language sql security definer set search_path = public as $$
  insert into public.audit_log (actor, action, tablo, row_id, detay)
  values (auth.uid(), p_action, p_tablo, p_row_id, p_detay);
$$;

/**
 * Notifies every active Yönetici, minus whoever triggered it, honouring their
 * per-type preference. The preference is compared as text on purpose: a
 * malformed notif_prefs value must not be able to raise inside a money RPC.
 */
create or replace function public.notify_yonetici(
  p_tur public.bildirim_tur, p_baslik text, p_govde text, p_link text default null
) returns void
language sql security definer set search_path = public as $$
  insert into public.notifications (profile_id, tur, baslik, govde, link)
  select p.id, p_tur, p_baslik, p_govde, p_link
  from public.profiles p
  where p.rol = 'YONETICI'
    and p.durum = 'ACTIVE'
    and (auth.uid() is null or p.id <> auth.uid())
    and coalesce(p.notif_prefs ->> p_tur::text, 'true') <> 'false';
$$;

-- New signups land PENDING with rol = NULL, which RLS reads as "zero rows".
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, ad_soyad)
  values (new.id, coalesce(nullif(btrim(new.raw_user_meta_data ->> 'ad_soyad'), ''), ''))
  on conflict (id) do nothing;

  perform public.notify_yonetici(
    'YENI_UYELIK',
    'Yeni kayıt isteği',
    coalesce(nullif(btrim(new.raw_user_meta_data ->> 'ad_soyad'), ''), new.email, 'Yeni kullanıcı')
      || ' onay bekliyor.',
    '/yonetim/personel');
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ========================================================== fee math ====

/**
 * The pure core. IMMUTABLE and takes tariff VALUES, not a tariff id, so it
 * touches no table and can be hand-checked in the smoke test with literals.
 *
 *   • Duration rounds UP to the minute, then up to the hour: 61 minutes is
 *     two hours, because that is how a car park is actually priced.
 *   • The grace period is all-or-nothing. Past it, billing starts at minute 0
 *     and the first full hour is charged.
 *   • gunluk_tavan_kurus = 0 means "no cap". nullif() turns that into NULL and
 *     least() ignores NULLs, so one expression covers capped and uncapped.
 *   • Arithmetic runs in bigint and only narrows at the end, so a long stay
 *     cannot silently wrap an int4.
 */
create or replace function public.ucret_hesapla_core(
  p_giris              timestamptz,
  p_cikis              timestamptz,
  p_ucretsiz_dakika    integer,
  p_ilk_saat_kurus     integer,
  p_sonraki_saat_kurus integer,
  p_gunluk_tavan_kurus integer
) returns integer
language plpgsql immutable as $$
declare
  v_dakika  bigint;
  v_gun     bigint;
  v_kalan   bigint;
  v_saat    bigint;
  v_tavan   bigint;
  v_tam_gun bigint;
  v_kismi   bigint;
begin
  if p_cikis < p_giris then
    raise exception 'Çıkış zamanı girişten önce olamaz.';
  end if;

  v_dakika := ceil(extract(epoch from (p_cikis - p_giris)) / 60.0)::bigint;

  if v_dakika <= p_ucretsiz_dakika then
    return 0;
  end if;

  v_tavan := nullif(p_gunluk_tavan_kurus, 0)::bigint;

  v_gun   := v_dakika / 1440;
  v_kalan := v_dakika % 1440;

  -- A whole 24 h block: first hour plus 23 more, then capped.
  v_tam_gun := least(p_ilk_saat_kurus::bigint + 23 * p_sonraki_saat_kurus::bigint, v_tavan);

  if v_kalan = 0 then
    return (v_gun * v_tam_gun)::integer;
  end if;

  v_saat  := ceil(v_kalan / 60.0)::bigint;
  v_kismi := least(p_ilk_saat_kurus::bigint + (v_saat - 1) * p_sonraki_saat_kurus::bigint, v_tavan);

  return (v_gun * v_tam_gun + v_kismi)::integer;
end $$;

-- The wrapper that loads the snapshotted tariff. STABLE, not IMMUTABLE — it
-- reads a table. This is the ONE function that prices a stay, so the live
-- preview on the exit screen and the actual charge cannot diverge.
create or replace function public.ucret_hesapla(
  p_giris timestamptz, p_cikis timestamptz, p_tarife_id uuid
) returns integer
language plpgsql stable security definer set search_path = public as $$
declare v_t public.tarifeler;
begin
  select * into v_t from public.tarifeler where id = p_tarife_id;
  if not found then
    raise exception 'Tarife bulunamadı.';
  end if;
  return public.ucret_hesapla_core(
    p_giris, p_cikis, v_t.ucretsiz_dakika,
    v_t.ilk_saat_kurus, v_t.sonraki_saat_kurus, v_t.gunluk_tavan_kurus);
end $$;

create or replace function public.aktif_tarife(p_arac_tipi public.arac_tipi)
returns uuid
language sql stable security definer set search_path = public as $$
  select t.id from public.tarifeler t
  where t.arac_tipi = p_arac_tipi and t.gecerli_bitis is null
  limit 1;
$$;

-- ================================================= immutability guard ====

/**
 * Closed and cancelled tickets are immutable; corrections are counter-entries.
 *
 * Two escape hatches, both deliberate:
 *  1. Something a ticket POINTS AT goes away, leaving the ticket itself
 *     untouched. Two real cases: a parent row being deleted fires
 *     ON DELETE SET NULL, which arrives here as an UPDATE (deleting a spot
 *     must not be blocked by last year's tickets); and the nightly KVKK purge
 *     nulls photo paths once the retention window closes. Both are "a
 *     reference became NULL, everything else byte-identical", which is
 *     permitted. Comparing via jsonb rather than column by column means a
 *     column added later is covered automatically instead of silently falling
 *     out of the check.
 *  2. bilet_iptal announces itself with a transaction-local flag naming the
 *     exact row it may touch.
 */
create or replace function public.biletler_immutable_guard() returns trigger
language plpgsql as $$
declare
  v_detach text[] := array[
    'park_yeri_id','vardiya_id','kapatan_vardiya_id','abonman_id',
    'giris_by','cikis_by','iptal_by',
    -- photo paths: nulled by the nightly retention purge, never money
    'giris_foto','cikis_foto'
  ];
  v_old jsonb := to_jsonb(old);
  v_new jsonb := to_jsonb(new);
  v_key text;
begin
  if old.durum = 'ACIK' then
    return new;
  end if;

  if coalesce(current_setting('app.bilet_iptal', true), '') = old.id::text then
    return new;
  end if;

  foreach v_key in array v_detach loop
    -- Anything other than "this reference became NULL" is a real edit.
    if v_new -> v_key <> 'null'::jsonb and v_new -> v_key is distinct from v_old -> v_key then
      raise exception
        'Kapanmış bilet değiştirilemez (bilet %). Düzeltme için karşı kayıt girin.', old.id;
    end if;
    v_old := v_old - v_key;
    v_new := v_new - v_key;
  end loop;

  if v_old = v_new then
    return new;
  end if;

  raise exception
    'Kapanmış bilet değiştirilemez (bilet %). Düzeltme için karşı kayıt girin.', old.id;
end $$;

drop trigger if exists biletler_immutable on public.biletler;
create trigger biletler_immutable
  before update on public.biletler
  for each row execute function public.biletler_immutable_guard();

-- ========================================================= exceptions ====

/**
 * Records an event we refused to turn into a ticket. Idempotent on islem_id,
 * because a retrying camera must log one exception, not fifty — and the
 * Yönetici notification only fires for a genuinely new row.
 */
create or replace function public.istisna_yaz(
  p_tur          public.istisna_tur,
  p_yon          text,
  p_plaka        text,
  p_kaynak       public.kaynak,
  p_islem_id     uuid,
  p_ham          jsonb,
  p_foto         text,
  p_kaynak_zaman timestamptz,
  p_adaylar      uuid[] default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  insert into public.istisnalar (
    tur, yon, plaka, kaynak, islem_id, ham_yanit, foto_path, kaynak_zaman, aday_bilet_ids)
  values (p_tur, p_yon, p_plaka, p_kaynak, p_islem_id, p_ham, p_foto, p_kaynak_zaman, p_adaylar)
  on conflict (islem_id) where islem_id is not null do nothing
  returning id into v_id;

  if v_id is null then
    select i.id into v_id from public.istisnalar i where i.islem_id = p_islem_id;
    return v_id;   -- already logged; stay quiet
  end if;

  perform public.notify_yonetici(
    'ISTISNA', 'Çözülmemiş kayıt',
    p_tur::text || ' — ' || coalesce(p_plaka, 'plaka okunamadı'),
    -- Not under /yonetim: istisnalar is staff-readable by design (an orphan
    -- exit is a problem at the gate) and the screen lives at /istisnalar.
    '/istisnalar');
  return v_id;
end $$;

create or replace function public.istisna_coz(p_id uuid, p_not text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  update public.istisnalar
     set cozuldu_by = auth.uid(), cozuldu_at = now(), cozum_notu = nullif(btrim(p_not), '')
   where id = p_id and cozuldu_at is null;
end $$;

-- =============================================================== puan ====

/**
 * Credits the entry, if a rule is active, the plate belongs to an account,
 * and the anti-farming cooldown has passed.
 *
 * The advisory lock is not decoration: read-balance-then-write with no lock is
 * how the same plate earns twice when two devices open a ticket at once, and
 * the resulting extra points are a real lira liability.
 */
create or replace function public.puan_kazandir(p_bilet_id uuid, p_plaka text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_kural public.puan_kurallari;
  v_hesap uuid;
  v_son   timestamptz;
begin
  select * into v_kural from public.puan_kurallari where gecerli_bitis is null;
  if not found or v_kural.kazanim_puan = 0 then
    return;
  end if;

  select h.id into v_hesap
    from public.hesaplar h
    join public.hesap_araclari ha on ha.hesap_id = h.id
   where ha.plaka = p_plaka and h.durum = 'AKTIF';
  if not found then
    return;
  end if;

  perform pg_advisory_xact_lock(hashtext('puan:' || p_plaka));

  if v_kural.bekleme_saat > 0 then
    -- Cooldown is per PLATE, not per account: a family with two cars entering
    -- together should earn for both.
    select max(ph.created_at) into v_son
      from public.puan_hareketleri ph
      join public.biletler b on b.id = ph.bilet_id
     where ph.hesap_id = v_hesap and ph.tur = 'KAZANIM' and b.plaka = p_plaka;

    if v_son is not null and v_son > now() - make_interval(hours => v_kural.bekleme_saat) then
      return;
    end if;
  end if;

  insert into public.puan_hareketleri (hesap_id, tur, puan, bilet_id, kural_id, aciklama)
  values (v_hesap, 'KAZANIM', v_kural.kazanim_puan, p_bilet_id, v_kural.id, 'Giriş kazanımı');
end $$;

/**
 * Personel-safe: answers for THE ONE VEHICLE AT THE GATE and nothing else.
 * They must see a balance in order to redeem it, so the boolean trick used for
 * subscription prices does not work here — the control is scope, not
 * concealment. No account list, no history, no cross-account totals.
 */
create or replace function public.hesap_puan_durumu(p_plaka text)
returns table (hesap_var boolean, hesap_adi text, bakiye integer, karsiligi_kurus integer)
language plpgsql stable security definer set search_path = public as $$
declare
  v_plaka  text := public.normalize_plaka(p_plaka);
  v_aktif  boolean;
  v_hesap  public.hesaplar;
  v_bakiye integer := 0;
  v_kurus  integer := 0;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  select o.puan_aktif into v_aktif from public.otopark_ayarlari o where o.id = 1;
  if not coalesce(v_aktif, false) then
    return query select false, null::text, 0, 0;
    return;
  end if;

  select h.* into v_hesap
    from public.hesaplar h
    join public.hesap_araclari ha on ha.hesap_id = h.id
   where ha.plaka = v_plaka and h.durum = 'AKTIF';
  if not found then
    return query select false, null::text, 0, 0;
    return;
  end if;

  select coalesce(sum(ph.puan), 0)::integer into v_bakiye
    from public.puan_hareketleri ph where ph.hesap_id = v_hesap.id;

  select coalesce(k.kurus_per_puan, 0) into v_kurus
    from public.puan_kurallari k where k.gecerli_bitis is null;

  return query select true, v_hesap.ad, v_bakiye, (v_bakiye * coalesce(v_kurus, 0))::integer;
end $$;

/**
 * Spends points against an open ticket. Enforced server-side: redemption can
 * never exceed the balance and never exceed the fee — no negative fee, no cash
 * back. Every redemption is audited and notified, because the operator
 * override is both the point of the feature and its fraud surface.
 */
create or replace function public.puan_kullan(p_bilet_id uuid, p_puan integer)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_b        public.biletler;
  v_kural    public.puan_kurallari;
  v_hesap    uuid;
  v_bakiye   integer;
  v_ucret    integer;
  v_max_puan integer;
  v_indirim  integer;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_puan is null or p_puan <= 0 then
    raise exception 'Kullanılacak puan sıfırdan büyük olmalı.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception 'Kapanmış bilette puan kullanılamaz.';
  end if;
  if v_b.abonman_id is not null then
    raise exception 'Abonman girişinde puan kullanılamaz.';
  end if;
  if v_b.indirim_kurus > 0 then
    raise exception 'Bu bilette zaten puan kullanılmış.';
  end if;

  select * into v_kural from public.puan_kurallari where gecerli_bitis is null;
  if not found or v_kural.kurus_per_puan = 0 then
    raise exception 'Aktif puan kuralı tanımlı değil.';
  end if;

  select h.id into v_hesap
    from public.hesaplar h
    join public.hesap_araclari ha on ha.hesap_id = h.id
   where ha.plaka = v_b.plaka and h.durum = 'AKTIF';
  if not found then
    raise exception 'Bu plakaya bağlı aktif puan hesabı yok.';
  end if;

  perform pg_advisory_xact_lock(hashtext('puan:' || v_b.plaka));

  select coalesce(sum(ph.puan), 0)::integer into v_bakiye
    from public.puan_hareketleri ph where ph.hesap_id = v_hesap;
  if p_puan > v_bakiye then
    raise exception 'Yetersiz puan. Bakiye: %', v_bakiye;
  end if;

  v_ucret := public.ucret_hesapla(v_b.giris_at, now(), v_b.tarife_id);
  if v_ucret <= 0 then
    raise exception 'Ücretsiz çıkışta puan kullanılamaz.';
  end if;

  -- Integer division floors, so the discount can never round above the fee.
  v_max_puan := v_ucret / v_kural.kurus_per_puan;
  if p_puan > v_max_puan then
    raise exception 'Bu bilet için en fazla % puan kullanılabilir.', v_max_puan;
  end if;

  v_indirim := p_puan * v_kural.kurus_per_puan;

  insert into public.puan_hareketleri (hesap_id, tur, puan, bilet_id, kural_id, created_by, aciklama)
  values (v_hesap, 'KULLANIM', -p_puan, p_bilet_id, v_kural.id, auth.uid(), 'Çıkışta kullanıldı');

  update public.biletler
     set indirim_kurus = v_indirim, puan_kullanilan = p_puan
   where id = p_bilet_id;

  perform public.audit('puan_kullan', 'biletler', p_bilet_id,
    jsonb_build_object('puan', p_puan, 'kurus', v_indirim, 'plaka', v_b.plaka));
  perform public.notify_yonetici('PUAN_KULLANIM', 'Puan kullanıldı',
    v_b.plaka || ' — ' || p_puan || ' puan', '/yonetim/hesaplar');

  return v_indirim;
end $$;

-- Undoes a redemption on a still-open ticket (counter-entry, never a delete).
create or replace function public.puan_kullanim_geri_al(p_bilet_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_b public.biletler;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception 'Kapanmış bilette puan kullanımı geri alınamaz.';
  end if;
  if v_b.indirim_kurus = 0 then
    return;
  end if;

  insert into public.puan_hareketleri (hesap_id, tur, puan, bilet_id, kural_id, created_by, aciklama)
  select ph.hesap_id, 'IPTAL', -ph.puan, ph.bilet_id, ph.kural_id, auth.uid(), 'Kullanım geri alındı'
    from public.puan_hareketleri ph
   where ph.bilet_id = p_bilet_id and ph.tur = 'KULLANIM';

  update public.biletler set indirim_kurus = 0, puan_kullanilan = 0 where id = p_bilet_id;

  perform public.audit('puan_kullanim_geri_al', 'biletler', p_bilet_id, null);
end $$;

-- ====================================================== abonman lookup ====

/**
 * Personel-safe subscription check: valid until when, and whose car it is —
 * but never the negotiated monthly price. Always returns exactly one row,
 * courtesy of the LEFT JOIN against a one-row source.
 */
create or replace function public.abonman_gecerli_mi(p_plaka text)
returns table (gecerli boolean, bitis_tarihi date, musteri_ad text)
language plpgsql stable security definer set search_path = public as $$
declare v_plaka text := public.normalize_plaka(p_plaka);
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  return query
  select (a.id is not null), a.bitis, a.musteri_ad
    from (select 1) d
    left join public.abonmanlar a
      on a.plaka = v_plaka
     and a.durum = 'AKTIF'
     and (now() at time zone 'Europe/Istanbul')::date between a.baslangic and a.bitis
   limit 1;
end $$;

-- ============================================================ biletler ====

/**
 * Opens a ticket. Called identically by the phone, the camera webhook and a
 * manual back-office entry — one implementation, so the money logic cannot
 * drift between paths.
 *
 * THE CLOCK RULE (per source, never a blanket default):
 *   A camera event may have sat in an SD-card buffer for hours, so it MUST
 *   carry its own timestamp or a 14:00 arrival replayed at 16:30 gets billed
 *   from 16:30 — a 3-hour stay charged as 30 minutes, with nothing looking
 *   broken because the arithmetic is correct on a wrong input.
 *   A phone must NOT supply one. Requiring it everywhere would import client
 *   clock skew into the one path that never had it, which is exactly the
 *   hazard that ruled out an offline queue.
 */
create or replace function public.bilet_ac(
  p_plaka        text,
  p_arac_tipi    public.arac_tipi,
  p_islem_id     uuid,
  p_kaynak       public.kaynak default 'MOBIL',
  p_zaman        timestamptz default null,
  p_foto         text default null,
  p_park_yeri_id uuid default null,
  p_ham_yanit    jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plaka      text;
  v_zaman      timestamptz;
  v_limit_dk   integer;
  v_puan_aktif boolean;
  v_tarife     uuid;
  v_abonman    uuid;
  v_vardiya    uuid;
  v_gecikmeli  boolean := false;
  v_id         uuid;
  v_con        text;
begin
  -- Two disjoint callers, and keeping them disjoint is load-bearing:
  --   • staff (a JWT is present)                  → MOBIL/MANUEL, and the time
  --                                                 is ALWAYS the server's
  --   • the webhook (service_role, auth.uid() IS NULL) → KAMERA, the only
  --                                                 caller allowed to supply
  --                                                 p_zaman
  --
  -- `is_staff() OR (uid IS NULL AND KAMERA)` was NOT enough: staff satisfy the
  -- first branch, so they could pass p_kaynak = 'KAMERA' themselves — and that
  -- hands them p_zaman. It is a silent mis-billing tool: record an 08:00
  -- arrival as 13:00 and five billable hours vanish, leaving a ticket that
  -- looks completely ordinary. The source must match WHO is calling, not
  -- merely what the caller claims to be.
  if p_kaynak = 'KAMERA' then
    if auth.uid() is not null then
      raise exception 'Kamera kaynağı istemciden kullanılamaz.';
    end if;
  elsif not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;

  v_plaka := public.normalize_plaka(p_plaka);
  if v_plaka !~ '^[A-Z0-9]{2,15}$' then
    raise exception 'Geçersiz plaka: %', coalesce(p_plaka, '(boş)');
  end if;

  if p_kaynak = 'KAMERA' then
    if p_zaman is null then
      raise exception 'Kamera kaydı zaman damgası olmadan kabul edilmez.';
    end if;
    v_zaman := p_zaman;
  else
    v_zaman := now();   -- a client-supplied timestamp is ignored, by design
  end if;

  select o.kamera_gecikme_limiti_dk, o.puan_aktif
    into v_limit_dk, v_puan_aktif
    from public.otopark_ayarlari o where o.id = 1;
  v_limit_dk := coalesce(v_limit_dk, 720);

  -- A clock ahead of ours is not a late event, it is a broken camera.
  if v_zaman > now() + interval '5 minutes' then
    perform public.istisna_yaz('GELECEK', 'GIRIS', v_plaka, p_kaynak, p_islem_id,
                               p_ham_yanit, p_foto, v_zaman);
    return null;
  end if;

  -- Too old to be honest: the car has almost certainly already left, and a
  -- ticket opened now would be fiction that bills someone at exit.
  if v_zaman < now() - make_interval(mins => v_limit_dk) then
    perform public.istisna_yaz('BAYAT', 'GIRIS', v_plaka, p_kaynak, p_islem_id,
                               p_ham_yanit, p_foto, v_zaman);
    return null;
  end if;

  v_gecikmeli := (p_kaynak = 'KAMERA' and v_zaman < now() - interval '2 minutes');

  v_tarife := public.aktif_tarife(p_arac_tipi);
  if v_tarife is null then
    raise exception 'Bu araç tipi için aktif tarife tanımlı değil: %', p_arac_tipi;
  end if;

  -- A valid subscriber enters free; the ticket exists purely as a record.
  select a.id into v_abonman
    from public.abonmanlar a
   where a.plaka = v_plaka and a.durum = 'AKTIF'
     and (now() at time zone 'Europe/Istanbul')::date between a.baslangic and a.bitis
   limit 1;

  if auth.uid() is not null then
    select v.id into v_vardiya from public.vardiyalar v
     where v.personel_id = auth.uid() and v.kapanis_at is null limit 1;
  end if;

  begin
    insert into public.biletler (
      islem_id, plaka, arac_tipi, giris_at, tarife_id, abonman_id, park_yeri_id,
      vardiya_id, giris_by, giris_kaynak, giris_foto,
      gecikmeli_kayit, kaynak_zaman, alindi_zaman
    ) values (
      p_islem_id, v_plaka, p_arac_tipi, v_zaman, v_tarife, v_abonman, p_park_yeri_id,
      v_vardiya, auth.uid(), p_kaynak, p_foto,
      v_gecikmeli, case when p_kaynak = 'KAMERA' then p_zaman end, now()
    ) returning id into v_id;
  exception when unique_violation then
    -- Which index fired is decided by LOOKING, not by trusting the diagnostic
    -- string: a row already carrying this islem_id is the definitive proof of
    -- a replay, and it stays correct if an index is ever renamed.
    select b.id into v_id from public.biletler b where b.islem_id = p_islem_id;
    if v_id is not null then
      -- Replay. Every ANPR camera retries a failed POST, and retry-on-blip
      -- retries from the phone: return the original, never a second ticket.
      return v_id;
    end if;

    get stacked diagnostics v_con = constraint_name;
    if v_con = 'biletler_acik_plaka_ux'
       or exists (select 1 from public.biletler b
                   where b.plaka = v_plaka and b.durum = 'ACIK') then
      raise exception 'Bu plaka için zaten açık bir bilet var: %', v_plaka;
    end if;
    raise;
  end;

  -- No points on a ₺0 stay: subscribers would otherwise farm rewards for
  -- parking they did not pay for.
  if coalesce(v_puan_aktif, false) and v_abonman is null then
    perform public.puan_kazandir(v_id, v_plaka);
  end if;

  return v_id;
end $$;

/**
 * Closes a ticket and takes the money. Deliberately has NO service-role path:
 * a camera can report, but it can never collect. Letting a webhook mark a
 * ticket KAPALI would book revenue that nobody actually handed over.
 */
create or replace function public.bilet_kapat(
  p_bilet_id             uuid,
  p_odeme_yontemi        public.odeme_yontemi default null,
  p_ucret_override_kurus integer default null,
  p_sebep                text default null,
  p_foto                 text default null,
  p_kaynak               public.kaynak default 'MOBIL'
) returns table (ucret_kurus integer, indirim_kurus integer, tahsil_kurus integer)
language plpgsql security definer set search_path = public as $$
declare
  v_b            public.biletler;
  v_cikis        timestamptz := now();
  v_hesaplanan   integer;
  v_ucret        integer;
  v_net          integer;
  v_vardiya      uuid;
  v_degistirildi boolean := false;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  -- A camera can never close a ticket, so it can never be the source of one
  -- either. There is no service_role grant on this function, which means the
  -- only way 'KAMERA' could appear here is a staff member mislabelling their
  -- own collection — cosmetic for the money, but it would put a "Kamera" chip
  -- on a row a person actually handled and quietly corrupt the audit trail.
  if p_kaynak = 'KAMERA' then
    raise exception 'Çıkış kaynağı KAMERA olamaz.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception 'Bu bilet zaten kapatılmış veya iptal edilmiş.';
  end if;

  if v_b.abonman_id is not null then
    v_hesaplanan := 0;
  else
    v_hesaplanan := public.ucret_hesapla(v_b.giris_at, v_cikis, v_b.tarife_id);
  end if;
  v_ucret := v_hesaplanan;

  if p_ucret_override_kurus is not null and p_ucret_override_kurus <> v_hesaplanan then
    if p_ucret_override_kurus < 0 then
      raise exception 'Ücret negatif olamaz.';
    end if;
    if coalesce(btrim(p_sebep), '') = '' then
      raise exception 'Ücret değişikliği için sebep zorunludur.';
    end if;
    v_ucret        := p_ucret_override_kurus;
    v_degistirildi := true;
  end if;

  if v_b.indirim_kurus > v_ucret then
    raise exception 'Kullanılan puan ücretten fazla. Önce puan kullanımını geri alın.';
  end if;

  v_net := v_ucret - v_b.indirim_kurus;

  if v_net > 0 and p_odeme_yontemi is null then
    raise exception 'Ödeme yöntemi zorunludur.';
  end if;

  select v.id into v_vardiya from public.vardiyalar v
   where v.personel_id = auth.uid() and v.kapanis_at is null limit 1;

  update public.biletler set
    cikis_at           = v_cikis,
    ucret_kurus        = v_ucret,
    tahsil_kurus       = v_net,
    odeme_yontemi      = p_odeme_yontemi,
    durum              = 'KAPALI',
    cikis_by           = auth.uid(),
    cikis_kaynak       = p_kaynak,
    cikis_foto         = coalesce(p_foto, v_b.cikis_foto),
    kapatan_vardiya_id = v_vardiya,
    ucret_degistirildi = v_degistirildi,
    ucret_sebep        = case when v_degistirildi then btrim(p_sebep) else v_b.ucret_sebep end
  where id = p_bilet_id;

  -- The cash belongs to whoever was on the till at exit, not at entry.
  if v_net > 0 then
    insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, created_by)
    values ('BILET', p_bilet_id, v_net, p_odeme_yontemi, v_vardiya, auth.uid());
  end if;

  -- A fee override in a cash business is the fraud signal that matters most.
  if v_degistirildi then
    perform public.audit('bilet_ucret_degisikligi', 'biletler', p_bilet_id,
      jsonb_build_object('hesaplanan', v_hesaplanan, 'uygulanan', v_ucret,
                         'sebep', btrim(p_sebep), 'plaka', v_b.plaka));
    perform public.notify_yonetici('UCRET_DEGISIKLIGI', 'Ücret değiştirildi',
      v_b.plaka || ' — hesaplanan ' || (v_hesaplanan / 100.0)::numeric(12,2)
        || ' ₺, uygulanan ' || (v_ucret / 100.0)::numeric(12,2) || ' ₺',
      -- The ticket-detail route is /gise/bilet/:id; /finans/biletler is the
      -- list and has no :id child, so linking there would dead-end the tap.
      '/gise/bilet/' || p_bilet_id);
  end if;

  return query select v_ucret, v_b.indirim_kurus, v_net;
end $$;

/**
 * Corrects the vehicle type on a STILL-OPEN ticket, re-snapshotting the
 * tariff so the fee is computed from the right price list.
 *
 * Needed because a camera cannot tell a motorcycle from a van, and a thumb at
 * a busy gate picks the wrong chip too. Restricted to open tickets: once the
 * money is taken, a correction is a counter-entry like everything else.
 */
create or replace function public.bilet_arac_tipi_duzelt(
  p_bilet_id uuid, p_arac_tipi public.arac_tipi
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_b      public.biletler;
  v_tarife uuid;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception 'Yalnızca açık bilette araç tipi düzeltilebilir.';
  end if;
  if v_b.arac_tipi = p_arac_tipi then
    return;
  end if;

  v_tarife := public.aktif_tarife(p_arac_tipi);
  if v_tarife is null then
    raise exception 'Bu araç tipi için aktif tarife tanımlı değil: %', p_arac_tipi;
  end if;

  update public.biletler
     set arac_tipi = p_arac_tipi, tarife_id = v_tarife
   where id = p_bilet_id;

  perform public.audit('bilet_arac_tipi_duzelt', 'biletler', p_bilet_id,
    jsonb_build_object('eski', v_b.arac_tipi, 'yeni', p_arac_tipi, 'plaka', v_b.plaka));
end $$;

/**
 * Cancels a ticket. An open one may be cancelled by any staff member with a
 * mandatory reason; a CLOSED one is Yönetici-only and writes a negative
 * counter-entry against the original collection rather than deleting it.
 */
create or replace function public.bilet_iptal(p_bilet_id uuid, p_sebep text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_b       public.biletler;
  v_vardiya uuid;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if coalesce(btrim(p_sebep), '') = '' then
    raise exception 'İptal sebebi zorunludur.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum = 'IPTAL' then
    raise exception 'Bu bilet zaten iptal edilmiş.';
  end if;
  if v_b.durum = 'KAPALI' and not public.is_yonetici() then
    raise exception 'Kapanmış bileti yalnızca Yönetici iptal edebilir.';
  end if;

  select v.id into v_vardiya from public.vardiyalar v
   where v.personel_id = auth.uid() and v.kapanis_at is null limit 1;

  if v_b.durum = 'KAPALI' then
    -- Reverse the money first, while the row is still KAPALI.
    insert into public.tahsilatlar (
      tur, bilet_id, tutar_kurus, yontem, vardiya_id, iptal_of, created_by, aciklama)
    select t.tur, t.bilet_id, -t.tutar_kurus, t.yontem, v_vardiya, t.id, auth.uid(), 'Bilet iptali'
      from public.tahsilatlar t
     where t.bilet_id = p_bilet_id and t.iptal_of is null and t.tutar_kurus > 0;

    -- Name the exact row the immutability guard may let through.
    perform set_config('app.bilet_iptal', p_bilet_id::text, true);
  end if;

  update public.biletler
     set durum = 'IPTAL', iptal_sebep = btrim(p_sebep), iptal_by = auth.uid(), iptal_at = now()
   where id = p_bilet_id;

  -- Points earned or spent on a cancelled stay are reversed, never deleted.
  insert into public.puan_hareketleri (hesap_id, tur, puan, bilet_id, kural_id, created_by, aciklama)
  select ph.hesap_id, 'IPTAL', -ph.puan, ph.bilet_id, ph.kural_id, auth.uid(), 'Bilet iptali'
    from public.puan_hareketleri ph
   where ph.bilet_id = p_bilet_id and ph.tur in ('KAZANIM', 'KULLANIM');

  perform public.audit('bilet_iptal', 'biletler', p_bilet_id,
    jsonb_build_object('sebep', btrim(p_sebep), 'plaka', v_b.plaka,
                       'onceki_durum', v_b.durum, 'tahsil', v_b.tahsil_kurus));
  perform public.notify_yonetici('BILET_IPTAL', 'Bilet iptal edildi',
    v_b.plaka || ' — ' || btrim(p_sebep), '/finans/biletler');
end $$;

/**
 * A car reaches the exit with no entry record — the everyday case, camera or
 * not. Charges the tariff's lost-ticket fee and writes a closed ticket, so the
 * money and the vehicle both leave a trace.
 */
create or replace function public.kayip_bilet_tahsil(
  p_plaka         text,
  p_arac_tipi     public.arac_tipi,
  p_odeme_yontemi public.odeme_yontemi,
  p_islem_id      uuid
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plaka   text;
  v_t       public.tarifeler;
  v_now     timestamptz := now();
  v_vardiya uuid;
  v_id      uuid;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;

  v_plaka := public.normalize_plaka(p_plaka);
  if v_plaka !~ '^[A-Z0-9]{2,15}$' then
    raise exception 'Geçersiz plaka: %', coalesce(p_plaka, '(boş)');
  end if;

  select * into v_t from public.tarifeler
   where arac_tipi = p_arac_tipi and gecerli_bitis is null;
  if not found then
    raise exception 'Bu araç tipi için aktif tarife tanımlı değil: %', p_arac_tipi;
  end if;
  if v_t.kayip_bilet_kurus <= 0 then
    raise exception 'Kayıp bilet ücreti tanımlı değil. Tarifeden belirleyin.';
  end if;

  select v.id into v_vardiya from public.vardiyalar v
   where v.personel_id = auth.uid() and v.kapanis_at is null limit 1;

  begin
    insert into public.biletler (
      islem_id, plaka, arac_tipi, giris_at, cikis_at, tarife_id,
      ucret_kurus, tahsil_kurus, odeme_yontemi, durum,
      vardiya_id, kapatan_vardiya_id, giris_by, cikis_by,
      giris_kaynak, cikis_kaynak, kayip_bilet, alindi_zaman
    ) values (
      p_islem_id, v_plaka, p_arac_tipi, v_now, v_now, v_t.id,
      v_t.kayip_bilet_kurus, v_t.kayip_bilet_kurus, p_odeme_yontemi, 'KAPALI',
      v_vardiya, v_vardiya, auth.uid(), auth.uid(),
      'MANUEL', 'MANUEL', true, v_now
    ) returning id into v_id;
  exception when unique_violation then
    select b.id into v_id from public.biletler b where b.islem_id = p_islem_id;
    if v_id is not null then
      return v_id;   -- replay
    end if;
    raise;
  end;

  insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, created_by, aciklama)
  values ('BILET', v_id, v_t.kayip_bilet_kurus, p_odeme_yontemi, v_vardiya, auth.uid(), 'Kayıp bilet');

  perform public.audit('kayip_bilet', 'biletler', v_id,
    jsonb_build_object('plaka', v_plaka, 'tutar', v_t.kayip_bilet_kurus));

  return v_id;
end $$;

/**
 * The camera's exit event. It only stamps cikis_bekliyor_at so the fee is
 * already on screen when the car reaches the barrier — it moves no money and
 * closes nothing. Resolution is exact-plate first, then a trailing-digit fuzzy
 * fallback; 0 or several candidates become an exception instead of a guess.
 */
create or replace function public.kamera_cikis_bildir(
  p_plaka    text,
  p_islem_id uuid,
  p_zaman    timestamptz,
  p_foto     text default null,
  p_ham      jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plaka    text;
  v_limit_dk integer;
  v_id       uuid;
  v_adaylar  uuid[];
  v_kuyruk   text;
begin
  if not (public.is_staff() or auth.uid() is null) then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_zaman is null then
    raise exception 'Kamera kaydı zaman damgası olmadan kabul edilmez.';
  end if;

  v_plaka := public.normalize_plaka(p_plaka);

  select o.kamera_gecikme_limiti_dk into v_limit_dk from public.otopark_ayarlari o where o.id = 1;
  v_limit_dk := coalesce(v_limit_dk, 720);

  if p_zaman > now() + interval '5 minutes' then
    perform public.istisna_yaz('GELECEK', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                               p_ham, p_foto, p_zaman);
    return null;
  end if;
  if p_zaman < now() - make_interval(mins => v_limit_dk) then
    perform public.istisna_yaz('BAYAT', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                               p_ham, p_foto, p_zaman);
    return null;
  end if;

  select b.id into v_id from public.biletler b
   where b.durum = 'ACIK' and b.plaka = v_plaka;

  if v_id is null then
    -- A misread plate is the common case, so fall back to the trailing four
    -- characters rather than declaring the car unknown straight away.
    v_kuyruk := right(v_plaka, 4);
    if length(v_kuyruk) = 4 then
      select array_agg(b.id) into v_adaylar from public.biletler b
       where b.durum = 'ACIK' and right(b.plaka, 4) = v_kuyruk;
    end if;

    if v_adaylar is null or array_length(v_adaylar, 1) is null then
      -- Exit before entry, or a car that never had a ticket. Flagging beats
      -- inventing a phantom open ticket for a vehicle that is not here.
      perform public.istisna_yaz('ACIK_BILET_YOK', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                                 p_ham, p_foto, p_zaman);
      return null;
    elsif array_length(v_adaylar, 1) > 1 then
      perform public.istisna_yaz('COKLU_ESLESME', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                                 p_ham, p_foto, p_zaman, v_adaylar);
      return null;
    else
      v_id := v_adaylar[1];
    end if;
  end if;

  update public.biletler
     set cikis_bekliyor_at = p_zaman, cikis_foto = coalesce(cikis_foto, p_foto)
   where id = v_id and durum = 'ACIK';

  return v_id;
end $$;

-- Bumped by the webhook on every event. A stale value is how we learn the
-- camera died — otherwise a dead camera looks exactly like an empty car park.
create or replace function public.kamera_kalp() returns void
language sql security definer set search_path = public as $$
  update public.otopark_ayarlari set kamera_kalp_atisi = now() where id = 1;
$$;

-- ============================================================ vardiya ====

create or replace function public.vardiya_ac(p_acilis_nakit_kurus integer default 0)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_acilis_nakit_kurus < 0 then
    raise exception 'Açılış nakdi negatif olamaz.';
  end if;

  begin
    insert into public.vardiyalar (personel_id, acilis_nakit_kurus)
    values (auth.uid(), coalesce(p_acilis_nakit_kurus, 0))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Zaten açık bir vardiyanız var. Önce onu kapatın.';
  end;

  perform public.audit('vardiya_ac', 'vardiyalar', v_id, null);
  return v_id;
end $$;

create or replace function public.vardiya_kapat(
  p_sayilan_nakit_kurus integer, p_notlar text default null
) returns table (beklenen_kurus integer, sayilan_kurus integer, fark_kurus integer)
language plpgsql security definer set search_path = public as $$
declare
  v_v        public.vardiyalar;
  v_nakit    integer;
  v_beklenen integer;
  v_fark     integer;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_sayilan_nakit_kurus is null or p_sayilan_nakit_kurus < 0 then
    raise exception 'Sayılan nakit negatif olamaz.';
  end if;

  select * into v_v from public.vardiyalar
   where personel_id = auth.uid() and kapanis_at is null for update;
  if not found then
    raise exception 'Açık vardiyanız yok.';
  end if;

  -- Only cash is counted in the drawer; card and transfer never sat in it.
  select coalesce(sum(t.tutar_kurus), 0)::integer into v_nakit
    from public.tahsilatlar t
   where t.vardiya_id = v_v.id and t.yontem = 'NAKIT';

  v_beklenen := v_v.acilis_nakit_kurus + v_nakit;
  v_fark     := p_sayilan_nakit_kurus - v_beklenen;

  update public.vardiyalar
     set kapanis_at           = now(),
         sayilan_nakit_kurus  = p_sayilan_nakit_kurus,
         beklenen_nakit_kurus = v_beklenen,
         fark_kurus           = v_fark,
         notlar               = nullif(btrim(p_notlar), '')
   where id = v_v.id;

  if v_fark <> 0 then
    perform public.audit('vardiya_fark', 'vardiyalar', v_v.id,
      jsonb_build_object('beklenen', v_beklenen, 'sayilan', p_sayilan_nakit_kurus, 'fark', v_fark));
    perform public.notify_yonetici('VARDIYA_FARK', 'Vardiya farkı',
      (select p.ad_soyad from public.profiles p where p.id = v_v.personel_id)
        || ' — fark ' || (v_fark / 100.0)::numeric(12,2) || ' ₺',
      '/finans/vardiyalar');
  end if;

  return query select v_beklenen, p_sayilan_nakit_kurus, v_fark;
end $$;

-- ================================================ aggregates for Personel ==

/**
 * Today's lot total WITHOUT row access. If Personel could SELECT today's
 * tickets to sum them client-side, they would also have per-ticket revenue
 * history — this returns the number and nothing else.
 */
create or replace function public.gunluk_ozet()
returns table (toplam_kurus bigint, arac_sayisi bigint, doluluk integer, kapasite integer)
language plpgsql stable security definer set search_path = public as $$
declare v_gun date := (now() at time zone 'Europe/Istanbul')::date;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  return query
  select
    (select coalesce(sum(t.tutar_kurus), 0)::bigint from public.tahsilatlar t
      where (t.created_at at time zone 'Europe/Istanbul')::date = v_gun),
    (select count(*)::bigint from public.biletler b
      where (b.giris_at at time zone 'Europe/Istanbul')::date = v_gun
        and b.durum <> 'IPTAL'),
    (select count(*)::integer from public.biletler b where b.durum = 'ACIK'),
    (select o.kapasite from public.otopark_ayarlari o where o.id = 1);
end $$;

create or replace function public.vardiya_ozetim()
returns table (
  vardiya_id uuid, acilis_at timestamptz, acilis_nakit_kurus integer,
  nakit_kurus bigint, kart_kurus bigint, havale_kurus bigint,
  toplam_kurus bigint, bilet_sayisi bigint
)
language plpgsql stable security definer set search_path = public as $$
declare v_v public.vardiyalar;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_v from public.vardiyalar
   where personel_id = auth.uid() and kapanis_at is null;
  if not found then
    return;   -- no open shift: an empty result, not an error
  end if;

  return query
  select v_v.id, v_v.acilis_at, v_v.acilis_nakit_kurus,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'NAKIT'), 0)::bigint,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'KREDI_KARTI'), 0)::bigint,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'HAVALE'), 0)::bigint,
         coalesce(sum(t.tutar_kurus), 0)::bigint,
         count(*) filter (where t.tutar_kurus > 0)::bigint
    from public.tahsilatlar t
   where t.vardiya_id = v_v.id;
end $$;

/**
 * Fuzzy open-ticket search — the mitigation for a misread or mistyped plate,
 * which has the same failure mode whether a camera or a thumb produced it.
 * Exact match ranks first, then prefix, then "contains", then trailing digits.
 * Only ACIK rows are ever returned, which is exactly what RLS grants Personel
 * anyway — this adds ranking, not reach.
 */
create or replace function public.acik_bilet_ara(p_q text default null)
returns table (
  id uuid, plaka text, arac_tipi public.arac_tipi, giris_at timestamptz,
  abonman_id uuid, park_yeri_id uuid, cikis_bekliyor_at timestamptz,
  indirim_kurus integer, puan_kullanilan integer, tarife_id uuid,
  gecikmeli_kayit boolean
)
language plpgsql stable security definer set search_path = public as $$
declare v_q text := public.normalize_plaka(p_q);
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  return query
  select b.id, b.plaka, b.arac_tipi, b.giris_at,
         b.abonman_id, b.park_yeri_id, b.cikis_bekliyor_at,
         b.indirim_kurus, b.puan_kullanilan, b.tarife_id, b.gecikmeli_kayit
    from public.biletler b
   where b.durum = 'ACIK'
     and (v_q = '' or b.plaka like '%' || v_q || '%'
                   or (length(v_q) >= 3 and right(b.plaka, length(v_q)) = v_q))
   order by
     case when v_q = '' then 2
          when b.plaka = v_q then 0
          when b.plaka like v_q || '%' then 1
          else 2 end,
     b.cikis_bekliyor_at desc nulls last,
     b.giris_at desc
   limit 50;
end $$;

-- ====================================================== admin (Yönetici) ==

create or replace function public.approve_signup(p_id uuid, p_rol public.rol)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici kayıt onaylayabilir.';
  end if;
  if p_rol is null then
    raise exception 'Rol seçilmelidir.';
  end if;

  update public.profiles set rol = p_rol, durum = 'ACTIVE'
   where id = p_id and durum = 'PENDING';
  if not found then
    raise exception 'Onay bekleyen kullanıcı bulunamadı.';
  end if;

  perform public.audit('approve_signup', 'profiles', p_id, jsonb_build_object('rol', p_rol));
end $$;

create or replace function public.set_role(p_id uuid, p_rol public.rol)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici rol değiştirebilir.';
  end if;
  if p_id = auth.uid() then
    raise exception 'Kendi rolünüzü değiştiremezsiniz.';
  end if;

  -- Serialise the count-then-decide. Without this, two concurrent demotions
  -- each read "there are 2 Yöneticis", both proceed, and the system is left
  -- with none — locked out of its own role management. An advisory lock is
  -- enough because every path that can reduce the count takes it, and unlike
  -- LOCK TABLE it does not block ordinary reads of profiles.
  perform pg_advisory_xact_lock(hashtext('yonetici_sayisi'));

  if p_rol is distinct from 'YONETICI'
     and exists (select 1 from public.profiles p
                  where p.id = p_id and p.rol = 'YONETICI' and p.durum = 'ACTIVE')
     and (select count(*) from public.profiles p
           where p.rol = 'YONETICI' and p.durum = 'ACTIVE') <= 1 then
    raise exception 'Son aktif Yönetici görevden alınamaz.';
  end if;

  update public.profiles set rol = p_rol where id = p_id;
  perform public.audit('set_role', 'profiles', p_id, jsonb_build_object('rol', p_rol));
end $$;

create or replace function public.set_status(p_id uuid, p_durum public.kullanici_durum)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici hesap durumunu değiştirebilir.';
  end if;
  if p_id = auth.uid() then
    raise exception 'Kendi hesabınızı devre dışı bırakamazsınız.';
  end if;

  lock table public.profiles in share row exclusive mode;

  if p_durum is distinct from 'ACTIVE'
     and exists (select 1 from public.profiles p
                  where p.id = p_id and p.rol = 'YONETICI' and p.durum = 'ACTIVE')
     and (select count(*) from public.profiles p
           where p.rol = 'YONETICI' and p.durum = 'ACTIVE') <= 1 then
    raise exception 'Son aktif Yönetici devre dışı bırakılamaz.';
  end if;

  update public.profiles set durum = p_durum where id = p_id;
  perform public.audit('set_status', 'profiles', p_id, jsonb_build_object('durum', p_durum));
end $$;

-- ====================================================== abonman tahsilat ==

-- Yönetici-only: Personel must never see or handle the negotiated price.
create or replace function public.abonman_tahsil(
  p_abonman_id uuid, p_yontem public.odeme_yontemi, p_tutar_kurus integer default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_a     public.abonmanlar;
  v_tutar integer;
  v_id    uuid;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici abonman tahsilatı yapabilir.';
  end if;

  select * into v_a from public.abonmanlar where id = p_abonman_id;
  if not found then
    raise exception 'Abonman bulunamadı.';
  end if;

  v_tutar := coalesce(p_tutar_kurus, v_a.ucret_kurus);
  if v_tutar <= 0 then
    raise exception 'Tahsilat tutarı sıfırdan büyük olmalı.';
  end if;

  insert into public.tahsilatlar (tur, abonman_id, tutar_kurus, yontem, created_by, aciklama)
  values ('ABONMAN', p_abonman_id, v_tutar, p_yontem, auth.uid(), v_a.plaka)
  returning id into v_id;

  perform public.audit('abonman_tahsil', 'abonmanlar', p_abonman_id,
    jsonb_build_object('tutar', v_tutar, 'yontem', p_yontem));
  return v_id;
end $$;

-- ====================================================== plate OCR log ====

/**
 * Records what the operator actually confirmed against what the model
 * suggested. This one column is the whole accuracy measurement: after a month,
 * onerilen vs kabul_edilen is a real hit rate per provider, which is how the
 * OCR decision gets re-made with data instead of re-argued.
 */
create or replace function public.plaka_okuma_kabul(p_log_id uuid, p_kabul text)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  update public.plaka_okuma_log
     set kabul_edilen = public.normalize_plaka(p_kabul), operator_id = auth.uid()
   where id = p_log_id and kabul_edilen is null;
end $$;

-- ==================================================== notification scope ==

/**
 * Which notification types are Yönetici-only. Used by the notifications RLS
 * policy to re-check the CURRENT role on every read, so a demoted user stops
 * seeing rows that were generated while they still had the role.
 *
 * Every type is Yönetici-only today. It is a function rather than an inline
 * `is_yonetici()` so that adding a Personel-facing type later is a one-line
 * change here, instead of a policy that quietly keeps hiding it.
 */
create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $$
  select p_tur in (
    'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA','ISTISNA'
  );
$$;

-- ================================================================ push ====

create or replace function public.save_push_subscription(
  p_endpoint text, p_p256dh text, p_auth text
) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'Oturum gerekli.';
  end if;
  -- Reassigns the endpoint if another account on this device registered it
  -- first; own-rows RLS would refuse a plain upsert.
  insert into public.push_subscriptions (endpoint, profile_id, p256dh, auth)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update
    set profile_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

-- ============================================== reports (Yönetici only) ===

create or replace function public.rapor_gunluk(p_bas date, p_bit date)
returns table (
  gun date, ciro_kurus bigint, bilet_sayisi bigint,
  nakit_kurus bigint, kart_kurus bigint, havale_kurus bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_bit < p_bas then
    raise exception 'Bitiş tarihi başlangıçtan önce olamaz.';
  end if;

  -- generate_series over dates yields TIMESTAMPS, which would not match the
  -- `date` result column — hence the explicit cast in the subquery.
  return query
  select g.gun,
         coalesce(sum(t.tutar_kurus), 0)::bigint,
         count(t.id) filter (where t.tutar_kurus > 0)::bigint,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'NAKIT'), 0)::bigint,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'KREDI_KARTI'), 0)::bigint,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'HAVALE'), 0)::bigint
    from (select generate_series(p_bas, p_bit, interval '1 day')::date as gun) g
    left join public.tahsilatlar t
      on (t.created_at at time zone 'Europe/Istanbul')::date = g.gun
   group by g.gun
   order by g.gun;
end $$;

create or replace function public.rapor_ozet(p_bas date, p_bit date)
returns table (
  ciro_kurus bigint, bilet_sayisi bigint, ortalama_dakika numeric,
  abonman_giris bigint, saatlik_giris bigint, iptal_sayisi bigint,
  ucret_degisiklik_sayisi bigint, puan_borcu_kurus bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;

  return query
  select
    (select coalesce(sum(t.tutar_kurus), 0)::bigint from public.tahsilatlar t
      where (t.created_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    (select count(*)::bigint from public.biletler b
      where b.durum = 'KAPALI'
        and (b.cikis_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    (select round(avg(extract(epoch from (b.cikis_at - b.giris_at)) / 60.0)::numeric, 1)
       from public.biletler b
      where b.durum = 'KAPALI'
        and (b.cikis_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    (select count(*)::bigint from public.biletler b
      where b.abonman_id is not null and b.durum <> 'IPTAL'
        and (b.giris_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    (select count(*)::bigint from public.biletler b
      where b.abonman_id is null and b.durum <> 'IPTAL'
        and (b.giris_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    (select count(*)::bigint from public.biletler b
      where b.durum = 'IPTAL'
        and (b.iptal_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    (select count(*)::bigint from public.biletler b
      where b.ucret_degistirildi
        and (b.cikis_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    -- What the business owes its customers in points, in lira. Invisible
    -- unless a screen shows it, which is why it is in the summary.
    (select coalesce(sum(ph.puan), 0)::bigint
       * coalesce((select k.kurus_per_puan from public.puan_kurallari k
                    where k.gecerli_bitis is null), 0)
       from public.puan_hareketleri ph);
end $$;

-- ================================================ versioned rule edits ===

/**
 * Changing a price NEVER edits a row. The current tariff is closed and a new
 * one opened at the same instant, so a car that entered this morning keeps the
 * price it entered under — the ticket snapshotted tarife_id.
 *
 * The cut-over instant is computed rather than assumed: if the current row was
 * created in this same transaction (a seed being corrected, say), now() would
 * equal its gecerli_baslangic and violate the period check. Nudging past it by
 * a millisecond keeps the timeline gapless AND legal.
 */
create or replace function public.tarife_guncelle(
  p_arac_tipi          public.arac_tipi,
  p_ucretsiz_dakika    integer,
  p_ilk_saat_kurus     integer,
  p_sonraki_saat_kurus integer,
  p_gunluk_tavan_kurus integer,
  p_kayip_bilet_kurus  integer
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_kesim timestamptz;
  v_id    uuid;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici tarife değiştirebilir.';
  end if;

  -- Two concurrent edits must not both close the current row and race to
  -- insert; the partial unique index would refuse the loser with a confusing
  -- error instead of simply serialising.
  perform pg_advisory_xact_lock(hashtext('tarife:' || p_arac_tipi::text));

  select greatest(now(), t.gecerli_baslangic + interval '1 millisecond')
    into v_kesim
    from public.tarifeler t
   where t.arac_tipi = p_arac_tipi and t.gecerli_bitis is null;
  v_kesim := coalesce(v_kesim, now());

  update public.tarifeler set gecerli_bitis = v_kesim
   where arac_tipi = p_arac_tipi and gecerli_bitis is null;

  insert into public.tarifeler (
    arac_tipi, ucretsiz_dakika, ilk_saat_kurus, sonraki_saat_kurus,
    gunluk_tavan_kurus, kayip_bilet_kurus, gecerli_baslangic, olusturan)
  values (
    p_arac_tipi, p_ucretsiz_dakika, p_ilk_saat_kurus, p_sonraki_saat_kurus,
    p_gunluk_tavan_kurus, p_kayip_bilet_kurus, v_kesim, auth.uid())
  returning id into v_id;

  perform public.audit('tarife_guncelle', 'tarifeler', v_id,
    jsonb_build_object('arac_tipi', p_arac_tipi, 'ilk_saat', p_ilk_saat_kurus,
                       'sonraki_saat', p_sonraki_saat_kurus,
                       'gunluk_tavan', p_gunluk_tavan_kurus));
  return v_id;
end $$;

-- Same versioning discipline for the points rule: raising the earn rate must
-- never re-value points already granted, because tickets snapshot kural_id.
create or replace function public.puan_kural_guncelle(
  p_kazanim_puan        integer,
  p_kurus_per_puan      integer,
  p_bekleme_saat        integer default 6,
  p_puan_gecerlilik_gun integer default 0
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_kesim timestamptz;
  v_id    uuid;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici puan kuralını değiştirebilir.';
  end if;

  perform pg_advisory_xact_lock(hashtext('puan_kural'));

  select greatest(now(), k.gecerli_baslangic + interval '1 millisecond')
    into v_kesim
    from public.puan_kurallari k where k.gecerli_bitis is null;
  v_kesim := coalesce(v_kesim, now());

  update public.puan_kurallari set gecerli_bitis = v_kesim where gecerli_bitis is null;

  insert into public.puan_kurallari (
    kazanim_puan, kurus_per_puan, bekleme_saat, puan_gecerlilik_gun,
    gecerli_baslangic, olusturan)
  values (
    p_kazanim_puan, p_kurus_per_puan, p_bekleme_saat, p_puan_gecerlilik_gun,
    v_kesim, auth.uid())
  returning id into v_id;

  perform public.audit('puan_kural_guncelle', 'puan_kurallari', v_id,
    jsonb_build_object('kazanim', p_kazanim_puan, 'kurus_per_puan', p_kurus_per_puan,
                       'bekleme_saat', p_bekleme_saat));
  return v_id;
end $$;

-- A points balance is a view over the ledger, never a stored counter.
-- security_invoker: without it the view would run as its owner and hand
-- Personel the whole points table straight past RLS.
create or replace view public.v_hesap_puan with (security_invoker = true) as
  select h.id as hesap_id, h.ad, h.durum,
         coalesce(sum(ph.puan), 0)::integer as bakiye
    from public.hesaplar h
    left join public.puan_hareketleri ph on ph.hesap_id = h.id
   group by h.id, h.ad, h.durum;
