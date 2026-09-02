-- ============================================================================
-- 013  Sabit ücretli tarife
-- ============================================================================
--
-- Owner request (2026-08-31): bir otopark saate göre değil, giriş başına TEK
-- fiyat alabilmeli. Tarife formunun en üstüne "Süreli / Sabit" seçimi gelir;
-- Sabit seçilince tek bir ücret alanı kalır.
--
-- DÖRT KURAL:
--
-- 1. ÜCRETİ YİNE SUNUCU HESAPLAR. Tek bir sayı yazmak, fiyatı istemciye
--    taşımak için bahane değil: `ucret_hesapla` hem çıkış ekranındaki canlı
--    önizlemeyi hem gerçek tahsilatı besler, ve ikisi ayrışırsa müşteriye
--    söylenen fiyatla kasaya giren fiyat farklı olur. Sabit tarife bu yüzden
--    yeni bir yol değil, aynı fonksiyonun yeni bir dalıdır.
--
-- 2. `ucret_hesapla_core` HİÇ DEĞİŞMEZ. O fonksiyon saf ve IMMUTABLE bir
--    ZAMAN formülüdür; sabit ücretin zamanla işi yoktur. Dal, satırı zaten
--    okuyan sarmalayıcıya (`ucret_hesapla`) konur. Yan fayda: imza sabit
--    kalır, dolayısıyla drop/grant zinciri ve istemci tarafı hiç etkilenmez
--    (istemci yalnızca sarmalayıcıyı çağırır — repo tarandı).
--
-- 3. ÜCRETSİZ SÜRE SABİT TARİFEDE DE GEÇERLİDİR. Girip hemen çıkan araçtan
--    tam ücret almak, bariyerde tartışma üretir; 15 dakikalık tolerans
--    tarifenin türüyle değil, otoparkın nezaketiyle ilgilidir. Sabit tarifede
--    anlamı olmayan alanlar — sonraki saat, günlük tavan — hesaba hiç
--    girmez; kayıp bilet ücreti ise aynen işler.
--
-- 4. GEÇMİŞ FİYATLANDIRMA KORUNUR. Tarife hâlâ sürümlüdür: bilet girişte
--    `tarife_id`'yi saklar, bu yüzden süreliden sabite geçmek içerideki bir
--    aracın fiyatını değiştirmez. Var olan bütün satırlar 'SURELI' doğar.
-- ============================================================================

begin;

-- `create type` ile YENİ bir enum yaratmak, `alter type ... add value`den
-- farklı olarak aynı işlem içinde kullanılabilir — "unsafe use of new value"
-- hatası yalnızca ikincisinde çıkar.
do $$
begin
  if not exists (select 1 from pg_type where typname = 'tarife_tur') then
    create type public.tarife_tur as enum ('SURELI', 'SABIT');
  end if;
end $$;

alter table public.tarifeler
  add column if not exists tur         public.tarife_tur not null default 'SURELI',
  add column if not exists sabit_kurus integer not null default 0;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'tarifeler_sabit_ck') then
    alter table public.tarifeler
      add constraint tarifeler_sabit_ck
      check (sabit_kurus >= 0 and (tur <> 'SABIT' or sabit_kurus > 0));
  end if;
end $$;

-- ------------------------------------------------------------ fiyatlama ----
-- Kural 2: dal burada, `ucret_hesapla_core` el değmeden duruyor.
create or replace function public.ucret_hesapla(
  p_giris timestamptz, p_cikis timestamptz, p_tarife_id uuid
) returns integer
language plpgsql stable security definer set search_path = public as $$
declare
  v_t      public.tarifeler;
  v_dakika bigint;
begin
  select * into v_t from public.tarifeler where id = p_tarife_id;
  if not found then
    raise exception 'Tarife bulunamadı.';
  end if;

  if v_t.tur = 'SABIT' then
    if p_cikis < p_giris then
      raise exception 'Çıkış zamanı girişten önce olamaz.';
    end if;
    -- Kural 3. Yuvarlama `ucret_hesapla_core` ile birebir aynı (yukarı,
    -- dakikaya) — iki yerde iki türlü yuvarlamak, 15. dakikada çıkan aracın
    -- hangi daldan geçtiğine göre farklı ücret ödemesi demek olurdu.
    v_dakika := ceil(extract(epoch from (p_cikis - p_giris)) / 60.0)::bigint;
    if v_dakika <= v_t.ucretsiz_dakika then
      return 0;
    end if;
    return v_t.sabit_kurus;
  end if;

  return public.ucret_hesapla_core(
    p_giris, p_cikis, v_t.ucretsiz_dakika,
    v_t.ilk_saat_kurus, v_t.sonraki_saat_kurus, v_t.gunluk_tavan_kurus);
end $$;

-- --------------------------------------------------------------- güncelle --
-- Parametre listesi değiştiği için `create or replace` YETMEZ: yanına ikinci
-- bir aşırı yükleme ekler ve PostgREST hangisini çağıracağını bilemez. Eski
-- imza açıkça düşürülür (006/008 aynı deseni izliyor).
drop function if exists public.tarife_guncelle(integer, integer, integer, integer, integer);

create or replace function public.tarife_guncelle(
  p_ucretsiz_dakika    integer,
  p_ilk_saat_kurus     integer,
  p_sonraki_saat_kurus integer,
  p_gunluk_tavan_kurus integer,
  p_kayip_bilet_kurus  integer,
  p_tur                public.tarife_tur default 'SURELI',
  p_sabit_kurus        integer default 0
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_kesim timestamptz;
  v_id    uuid;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici tarife değiştirebilir.';
  end if;

  -- Sunucu tarafı sınır: istemcideki doğrulama yalnızca mesaj içindir.
  if p_tur = 'SABIT' and coalesce(p_sabit_kurus, 0) <= 0 then
    raise exception 'Sabit tarifede ücret sıfırdan büyük olmalı.';
  end if;

  -- Two concurrent edits must not both close the current row and race to
  -- insert; the partial unique index would refuse the loser with a confusing
  -- error instead of simply serialising.
  perform pg_advisory_xact_lock(hashtext('tarife'));

  select greatest(now(), t.gecerli_baslangic + interval '1 millisecond')
    into v_kesim
    from public.tarifeler t
   where t.gecerli_bitis is null;
  v_kesim := coalesce(v_kesim, now());

  update public.tarifeler set gecerli_bitis = v_kesim
   where gecerli_bitis is null;

  -- Sabit tarifede saatlik alanlar sıfırlanır: kullanılmayan bir sayıyı
  -- saklamak, ileride "acaba bu mu geçerliydi" sorusunu doğurur.
  insert into public.tarifeler (
    ucretsiz_dakika, ilk_saat_kurus, sonraki_saat_kurus,
    gunluk_tavan_kurus, kayip_bilet_kurus, tur, sabit_kurus,
    gecerli_baslangic, olusturan)
  values (
    p_ucretsiz_dakika,
    case when p_tur = 'SABIT' then 0 else p_ilk_saat_kurus end,
    case when p_tur = 'SABIT' then 0 else p_sonraki_saat_kurus end,
    case when p_tur = 'SABIT' then 0 else p_gunluk_tavan_kurus end,
    p_kayip_bilet_kurus,
    p_tur,
    case when p_tur = 'SABIT' then p_sabit_kurus else 0 end,
    v_kesim, auth.uid())
  returning id into v_id;

  perform public.audit('tarife_guncelle', 'tarifeler', v_id,
    jsonb_build_object('tur', p_tur,
                       'sabit', p_sabit_kurus,
                       'ilk_saat', p_ilk_saat_kurus,
                       'sonraki_saat', p_sonraki_saat_kurus,
                       'gunluk_tavan', p_gunluk_tavan_kurus));
  return v_id;
end $$;

-- -------------------------------------------------------------- grants -----
-- 012'nin dersi: `from public` tek başına hiçbir şey kapatmaz — Supabase
-- `anon`, `authenticated` ve `service_role` rollerine DOĞRUDAN da verir.
revoke all on function
  public.tarife_guncelle(integer, integer, integer, integer, integer,
                         public.tarife_tur, integer)
  from public, anon, authenticated, service_role;
grant execute on function
  public.tarife_guncelle(integer, integer, integer, integer, integer,
                         public.tarife_tur, integer)
  to authenticated;

-- ------------------------------------------------------------- verify ------
do $$
declare
  v_sig text := 'public.tarife_guncelle(integer, integer, integer, integer, integer,'
                ' public.tarife_tur, integer)';
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'tarife_guncelle') <> 1 then
    raise exception '013: tarife_guncelle birden fazla imzayla duruyor';
  end if;
  if has_function_privilege('anon', v_sig, 'execute')
     or has_function_privilege('service_role', v_sig, 'execute') then
    raise exception '013: tarife_guncelle yanlış role açık';
  end if;
  if not has_function_privilege('authenticated', v_sig, 'execute') then
    raise exception '013: tarife_guncelle yöneticiye kapalı kaldı';
  end if;

  -- Mevcut satırlar süreli doğmalı, yoksa içerideki araçlar bir anda sabit
  -- fiyatlanır.
  if exists (select 1 from public.tarifeler where tur <> 'SURELI') then
    raise exception '013: mevcut tarife satırları SURELI değil';
  end if;

  -- Ücretsiz bir SABİT tarifeyi yasaklayan kısıt gerçekten yerinde mi.
  -- Deneme INSERT'i ile sınamak cazip ama kırılgan: `gecerli_bitis is null`
  -- üzerindeki kısmi tekil indeks önce patlayabilir ve test yanlış sebepten
  -- geçerdi. Kısıtın varlığı burada, davranışı smoke test'te sınanır.
  if not exists (select 1 from pg_constraint where conname = 'tarifeler_sabit_ck') then
    raise exception '013: tarifeler_sabit_ck kısıtı yok';
  end if;
end $$;

commit;
