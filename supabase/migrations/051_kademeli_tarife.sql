-- ============================================================================
-- 051  Kademeli tarife: "N saate kadar X ₺" kademeleri
-- ============================================================================

begin;

-- Sahibin isteği (2026-11-07): otoparkın gerçek fiyat listesi saatlik değil,
-- KADEMELİ — 0–2 sa 200 ₺, 2–4 sa 300 ₺, 4–8 sa 400 ₺, 8–24 sa 500 ₺. Ne
-- "ilk saat + sonraki saat + tavan" (SURELI) ne tek fiyat (SABIT) bunu
-- yazabiliyor. Üçüncü tür eklenir; ikisi aynen kalır.
--
-- Sahibin kararları:
--   1. Sınır ALTTAKİ kademeye aittir: tam 2:00 = 200 ₺, 2:01 = 300 ₺.
--      Dakika bugünkü gibi yukarı yuvarlanır (2:00:30 = 121. dakika = 300 ₺).
--   2. 24 saati aşınca her TAM 24 saat son kademenin (24 sa) fiyatıdır,
--      kalan süre yine kademelerle fiyatlanır: 30 sa = 500 + 400 = 900 ₺,
--      48 sa = 1000 ₺, 24 sa 1 dk = 500 + 200 = 700 ₺.
--   3. Ücretsiz süre ve kayıp bilet ücreti bugünkü gibi (013, kural 3):
--      ücretsiz süre yalnızca TOPLAM süreye bakar.
--
-- Değişmeyenler (013'ün kuralları): ücreti YİNE SUNUCU hesaplar (tek fonksiyon
-- `ucret_hesapla`, hem önizleme hem tahsilat), `ucret_hesapla_core` hiç
-- değişmez, tarife SÜRÜMLÜDÜR (bilet girişte tarife_id'sini saklar —
-- kademeliye geçmek içerideki aracın fiyatını değiştirmez).
--
-- Yeni enum değeri bu işlemde YALNIZCA tanımlanır: literal'i yalnızca
-- PL/pgSQL gövdelerinde geçer (çalışma anında çözülür, 035 deseni); kısıtlar
-- `tur::text` ile karşılaştırır, enum değerini kullanmaz.
alter type public.tarife_tur add value if not exists 'KADEMELI';

-- ---------------------------------------------------------------- şema ----

-- Kademeler: artan sırada [{dakika, kurus}], dakika = o kademenin ÜST sınırı
-- (dahil). Son kademe 1440 dakikada (24 saat) bitmek ZORUNDA: 24 saatten
-- sonrası "tam gün + kalan" diye hesaplanır ve gün fiyatı son kademedir.
--
-- Doğrulayıcı tek yerde; hem CHECK hem tarife_guncelle onu kullanır.
create or replace function public.kademeler_gecerli(p jsonb)
returns boolean
language plpgsql immutable set search_path = public as $$
declare
  v_n       integer;
  v_e       jsonb;
  v_dk      numeric;
  v_kr      numeric;
  v_onceki_dk numeric := 0;
  v_onceki_kr numeric := 0;
begin
  if p is null or jsonb_typeof(p) <> 'array' then
    return false;
  end if;
  v_n := jsonb_array_length(p);
  if v_n < 1 or v_n > 12 then
    return false;
  end if;
  for v_e in select value from jsonb_array_elements(p) loop
    if jsonb_typeof(v_e) <> 'object'
       or jsonb_typeof(v_e -> 'dakika') is distinct from 'number'
       or jsonb_typeof(v_e -> 'kurus') is distinct from 'number' then
      return false;
    end if;
    v_dk := (v_e ->> 'dakika')::numeric;
    v_kr := (v_e ->> 'kurus')::numeric;
    -- Tamsayı; dakika sıkı artan; kuruş eksi değil ve azalmıyor (uzun kalan
    -- araç daha az ödemez — azalan liste bir yazım hatasıdır).
    if v_dk <> trunc(v_dk) or v_kr <> trunc(v_kr)
       or v_dk <= v_onceki_dk or v_dk > 1440
       or v_kr < 0 or v_kr < v_onceki_kr or v_kr > 100000000 then
      return false;
    end if;
    v_onceki_dk := v_dk;
    v_onceki_kr := v_kr;
  end loop;
  return v_onceki_dk = 1440;
end $$;

alter table public.tarifeler
  add column if not exists kademeler jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'tarifeler_kademe_ck') then
    alter table public.tarifeler
      add constraint tarifeler_kademe_ck
      check ((kademeler is null or public.kademeler_gecerli(kademeler))
             and ((tur::text = 'KADEMELI') = (kademeler is not null)));
  end if;
end $$;

-- ------------------------------------------------------------- fiyatlama --

-- Saf hesap: süre (yukarı yuvarlanmış dakika) → kuruş. Sınır alttaki
-- kademeye aittir (`dakika <= üst sınır`). Liste kademeler_gecerli'den
-- geçmiş olmalı; geçmemişse bir sayı uydurmaz, hata verir.
create or replace function public.ucret_kademeli(
  p_dakika bigint, p_ucretsiz integer, p_kademeler jsonb
) returns integer
language plpgsql immutable set search_path = public as $$
declare
  v_gun    bigint;
  v_kalan  bigint;
  v_gunluk bigint;
  v_parca  bigint := 0;
begin
  if not public.kademeler_gecerli(p_kademeler) then
    raise exception 'Kademe listesi geçersiz.';
  end if;
  if p_dakika <= coalesce(p_ucretsiz, 0) then
    return 0;
  end if;

  v_gun   := p_dakika / 1440;
  v_kalan := p_dakika % 1440;
  -- Gün fiyatı = son (24 saatlik) kademe.
  v_gunluk := (p_kademeler -> (jsonb_array_length(p_kademeler) - 1) ->> 'kurus')::bigint;

  if v_kalan > 0 then
    select (e ->> 'kurus')::bigint into v_parca
      from jsonb_array_elements(p_kademeler) with ordinality as k(e, sira)
     where (e ->> 'dakika')::bigint >= v_kalan
     order by sira
     limit 1;
    -- Doğrulanmış listede olamaz (son kademe 1440, kalan < 1440); olursa ücret
    -- uydurulmaz — boş bir ücret, sıfır ücret demek olurdu.
    if v_parca is null then
      raise exception 'Kademe bulunamadı (% dakika).', v_kalan;
    end if;
  end if;

  return (v_gun * v_gunluk + v_parca)::integer;
end $$;

-- 013'ün gövdesi BİREBİR + KADEMELI dalı. İmza aynı; yetkiler korunur.
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

  -- 051: kademeli. Aynı yuvarlama, aynı ücretsiz süre kuralı.
  if v_t.tur::text = 'KADEMELI' then
    if p_cikis < p_giris then
      raise exception 'Çıkış zamanı girişten önce olamaz.';
    end if;
    v_dakika := ceil(extract(epoch from (p_cikis - p_giris)) / 60.0)::bigint;
    return public.ucret_kademeli(v_dakika, v_t.ucretsiz_dakika, v_t.kademeler);
  end if;

  return public.ucret_hesapla_core(
    p_giris, p_cikis, v_t.ucretsiz_dakika,
    v_t.ilk_saat_kurus, v_t.sonraki_saat_kurus, v_t.gunluk_tavan_kurus);
end $$;

-- ---------------------------------------------------------- güncelle -----
-- Parametre listesi değiştiği için `create or replace` YETMEZ: yanına ikinci
-- bir aşırı yükleme ekler ve PostgREST hangisini çağıracağını bilemez. Eski
-- imza açıkça düşürülür (013 aynı deseni izledi). Yeni parametre EN SONDA ve
-- varsayılanlı: mevcut 5 ve 7 argümanlı çağrılar aynen çalışır.
drop function if exists public.tarife_guncelle(integer, integer, integer, integer, integer,
                                               public.tarife_tur, integer);

create or replace function public.tarife_guncelle(
  p_ucretsiz_dakika    integer,
  p_ilk_saat_kurus     integer,
  p_sonraki_saat_kurus integer,
  p_gunluk_tavan_kurus integer,
  p_kayip_bilet_kurus  integer,
  p_tur                public.tarife_tur default 'SURELI',
  p_sabit_kurus        integer default 0,
  p_kademeler          jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_kesim    timestamptz;
  v_id       uuid;
  v_kademeli boolean := (p_tur::text = 'KADEMELI');
  v_sabit    boolean := (p_tur::text = 'SABIT');
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici tarife değiştirebilir.';
  end if;

  -- Sunucu tarafı sınır: istemcideki doğrulama yalnızca mesaj içindir.
  if v_sabit and coalesce(p_sabit_kurus, 0) <= 0 then
    raise exception 'Sabit tarifede ücret sıfırdan büyük olmalı.';
  end if;
  if v_kademeli and not public.kademeler_gecerli(p_kademeler) then
    raise exception 'Kademe listesi geçersiz: kademeler artan sırada, son kademe 24 saatte bitmeli ve ücretler azalmamalı.';
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

  -- Kullanılmayan alanlar sıfırlanır: saklanan ama kullanılmayan bir sayı
  -- ileride "acaba bu mu geçerliydi" sorusunu doğurur (013). Kademe listesi
  -- yalnızca kademeli tarifede yazılır.
  insert into public.tarifeler (
    ucretsiz_dakika, ilk_saat_kurus, sonraki_saat_kurus,
    gunluk_tavan_kurus, kayip_bilet_kurus, tur, sabit_kurus, kademeler,
    gecerli_baslangic, olusturan)
  values (
    p_ucretsiz_dakika,
    case when v_sabit or v_kademeli then 0 else p_ilk_saat_kurus end,
    case when v_sabit or v_kademeli then 0 else p_sonraki_saat_kurus end,
    case when v_sabit or v_kademeli then 0 else p_gunluk_tavan_kurus end,
    p_kayip_bilet_kurus,
    p_tur,
    case when v_sabit then p_sabit_kurus else 0 end,
    case when v_kademeli then p_kademeler else null end,
    v_kesim, auth.uid())
  returning id into v_id;

  perform public.audit('tarife_guncelle', 'tarifeler', v_id,
    jsonb_build_object('tur', p_tur,
                       'sabit', p_sabit_kurus,
                       'ilk_saat', p_ilk_saat_kurus,
                       'sonraki_saat', p_sonraki_saat_kurus,
                       'gunluk_tavan', p_gunluk_tavan_kurus,
                       'kademeler', case when v_kademeli then p_kademeler end));
  return v_id;
end $$;

-- ---------------------------------------------------------------- yetki ----
-- 012'nin dersi: `from public` tek başına hiçbir şey kapatmaz — Supabase
-- `anon`, `authenticated` ve `service_role` rollerine DOĞRUDAN da verir.
revoke all on function
  public.tarife_guncelle(integer, integer, integer, integer, integer,
                         public.tarife_tur, integer, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function
  public.tarife_guncelle(integer, integer, integer, integer, integer,
                         public.tarife_tur, integer, jsonb)
  to authenticated;

-- Saf hesap ve doğrulayıcı yalnızca içeriden (ucret_hesapla, tarife_guncelle,
-- CHECK) çağrılır; ikisi de SECURITY DEFINER içinde ya da sahip olarak çalışır.
revoke all on function public.ucret_kademeli(bigint, integer, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.kademeler_gecerli(jsonb)
  from public, anon, authenticated, service_role;

-- ------------------------------------------------------------ doğrulama ---
do $$
declare
  v_sig text := 'public.tarife_guncelle(integer, integer, integer, integer, integer,'
                ' public.tarife_tur, integer, jsonb)';
  v_k   jsonb := '[{"dakika":120,"kurus":20000},{"dakika":240,"kurus":30000},'
                 '{"dakika":480,"kurus":40000},{"dakika":1440,"kurus":50000}]';
  f     text;
  r     text;
begin
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'tarife_guncelle') <> 1 then
    raise exception '051: tarife_guncelle birden fazla imzayla duruyor';
  end if;
  if has_function_privilege('anon', v_sig, 'execute')
     or has_function_privilege('service_role', v_sig, 'execute') then
    raise exception '051: tarife_guncelle yanlış role açık';
  end if;
  if not has_function_privilege('authenticated', v_sig, 'execute') then
    raise exception '051: tarife_guncelle yöneticiye kapalı kaldı';
  end if;
  foreach f in array array['public.ucret_kademeli(bigint, integer, jsonb)',
                           'public.kademeler_gecerli(jsonb)'] loop
    foreach r in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception '051: % % rolüne açık', f, r;
      end if;
    end loop;
  end loop;

  -- Mevcut satırların hiçbiri kademeli değil ve hiçbiri liste taşımıyor.
  if exists (select 1 from public.tarifeler where kademeler is not null) then
    raise exception '051: mevcut tarife satırına kademe listesi yazılmış';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'tarifeler_kademe_ck') then
    raise exception '051: tarifeler_kademe_ck kısıtı yok';
  end if;

  -- Sahibin örnekleri, migration içinde de (smoke test PASS 73 tam liste).
  if public.ucret_kademeli(120, 5, v_k) <> 20000
     or public.ucret_kademeli(121, 5, v_k) <> 30000
     or public.ucret_kademeli(1800, 5, v_k) <> 90000
     or public.ucret_kademeli(1441, 5, v_k) <> 70000 then
    raise exception '051: ucret_kademeli sahibin örneklerini tutmuyor';
  end if;
end $$;

commit;
