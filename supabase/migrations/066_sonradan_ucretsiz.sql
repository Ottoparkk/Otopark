-- ============================================================================
-- 066  Sonradan ücretsiz çıkış + kim verdi
-- ============================================================================

begin;

-- Sahip (2026-11-15): kamera aracın çıkışını görünce bileti ödemesiz kapatır
-- (054) ve bilet "Ödeme topla" kutusuyla kalır. 065'in "Ücretsiz" düğmesi
-- yalnızca çıkış ekranındaydı (araç içerideyken); kameranın çıkardığı polis
-- aracı yalnızca "tahsil" edilebiliyordu. Aynısı "Çıkış Ver"in (027) borçlu
-- bıraktığı bilet için de geçerli.
--
-- Kararlar:
--   · Aynı RPC (`bilet_ucretsiz_cikis`): bilet KAPALI ve borçluysa ücreti 0
--     yapar. Yetki `bilet_tahsil`'inki (034): Yönetici ya da bileti KENDİ açık
--     vardiyasında kapatan Personel.
--   · Para yazılmaz, Onay'a düşmez; Yönetici adıyla bilgilenir (065 gibi).
--   · Kim ve ne zaman: `ucretsiz_by`, `ucretsiz_at` (her iki yolda). Kapalı
--     yolda çıkışı yapan (kamera / başka biri) ile ücretsizi veren ayrı kişi.
--   · Değişmezlik guard'ına TEK dar bayrak: `app.bilet_ucretsiz` — yalnızca
--     ücret ve ücretsiz çıkış izi değişebilir; tahsil, yöntem, çıkış zamanı
--     ve geri kalan her şey kilitli kalır.
-- PASS 83 sınar.

-- --------------------------------------------------------------- şema -----

alter table public.biletler
  add column if not exists ucretsiz_by uuid references public.profiles(id) on delete set null,
  add column if not exists ucretsiz_at timestamptz;

-- ------------------------------------------------- değişmezlik guard'ı -----
-- 054'ün gövdesi BİREBİR; eklenenler (066):
--   · v_detach'e 'ucretsiz_by' (profil silinince null'a düşebilsin — giris_by
--     / cikis_by gibi);
--   · app.bilet_ucretsiz = bilet id → yalnızca ücret + ücretsiz çıkış izi.
-- `create or replace` yetkileri korur; 029'daki hâli PASS 41'in listesinde.

create or replace function public.biletler_immutable_guard() returns trigger
language plpgsql as $fn$
declare
  v_detach text[] := array[
    'park_yeri_id','vardiya_id','kapatan_vardiya_id','abonman_id',
    'giris_by','cikis_by','iptal_by',
    -- 066: ücretsiz çıkışı veren; profil silinirse `on delete set null`
    'ucretsiz_by',
    -- photo paths: nulled by the nightly retention purge, never money
    'giris_foto','cikis_foto',
    -- okuma kaydı silinirse referans düşer; para değil
    'plaka_okuma_id'
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

  -- 054: "Araç çıkmadı" — kameranın kapattığı, parası alınmamış bilet.
  if coalesce(current_setting('app.bilet_geri_ac', true), '') = old.id::text then
    return new;
  end if;

  if coalesce(current_setting('app.bilet_tahsil', true), '') = old.id::text then
    v_old := v_old - 'tahsil_kurus' - 'odeme_yontemi';
    v_new := v_new - 'tahsil_kurus' - 'odeme_yontemi';
  end if;

  -- 066: sonradan ücretsiz çıkış — yalnızca ücret ve ücretsiz çıkış izi
  -- değişebilir (koşulları `bilet_ucretsiz_cikis` denetler, app.bilet_tahsil
  -- gibi). Tahsil, yöntem, çıkış bilgileri ve geri kalan her şey değişmez.
  if coalesce(current_setting('app.bilet_ucretsiz', true), '') = old.id::text then
    v_old := v_old - 'ucret_kurus' - 'ucret_degistirildi' - 'ucret_sebep'
                   - 'ucretsiz_sebep' - 'ucretsiz_not' - 'ucretsiz_by' - 'ucretsiz_at';
    v_new := v_new - 'ucret_kurus' - 'ucret_degistirildi' - 'ucret_sebep'
                   - 'ucretsiz_sebep' - 'ucretsiz_not' - 'ucretsiz_by' - 'ucretsiz_at';
  end if;

  -- 054: kameranın kapattığı biletin çıkış fotoğrafı — yalnızca boşken.
  if coalesce(current_setting('app.kamera_foto', true), '') = old.id::text
     and old.cikis_foto is null then
    v_old := v_old - 'cikis_foto';
    v_new := v_new - 'cikis_foto';
  end if;

  foreach v_key in array v_detach loop
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
end
$fn$;

-- ------------------------------------------------ geçmişi doldur ----------
-- 065'ten beri verilmiş ücretsiz çıkışlar o yolda yalnızca açık biletten
-- verilebildi: veren = çıkışı yapan, zaman = çıkış zamanı. Satırlar kapalı;
-- güncelleme yeni bayrakla, satır satır geçer (guard bayrağı bilet id'siyle
-- eşler).

do $do$
declare
  r record;
begin
  for r in select id from public.biletler
            where ucretsiz_sebep is not null
              and (ucretsiz_by is null or ucretsiz_at is null)
  loop
    perform set_config('app.bilet_ucretsiz', r.id::text, true);
    update public.biletler
       set ucretsiz_by = coalesce(ucretsiz_by, cikis_by),
           ucretsiz_at = coalesce(ucretsiz_at, cikis_at)
     where id = r.id;
  end loop;
  perform set_config('app.bilet_ucretsiz', '', true);
end
$do$;

-- ------------------------------------------- bilet_ucretsiz_temizle -------
-- 065'teki gibi; "Araç çıkmadı" yeni iki sütunu da düşürür.

create or replace function public.bilet_ucretsiz_temizle()
returns trigger
language plpgsql set search_path = public as $$
begin
  new.ucretsiz_sebep := null;
  new.ucretsiz_not   := null;
  new.ucretsiz_by    := null;
  new.ucretsiz_at    := null;
  return new;
end $$;

-- ---------------------------------------------------- bilet_ucretsiz_cikis --
-- AÇIK dal: 065'in gövdesi BİREBİR + ucretsiz_by / ucretsiz_at.
-- KAPALI dal (066): bilet_tahsil'in (034) denetimleri; ücret tek UPDATE ile
-- app.bilet_ucretsiz bayrağı altında 0 olur.

create or replace function public.bilet_ucretsiz_cikis(
  p_bilet_id uuid,
  p_sebep    public.ucretsiz_sebep,
  p_not      text
) returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_b          public.biletler;
  v_not        text := btrim(coalesce(p_not, ''));
  v_etiket     text;
  v_hesaplanan integer;
  v_ad         text;
  v_sonradan   boolean := false;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_sebep is null then
    raise exception 'Sebep seçin.';
  end if;
  if v_not = '' then
    raise exception 'Not zorunludur.';
  end if;
  if char_length(v_not) > 200 then
    raise exception 'Not en fazla 200 karakter olabilir.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;

  v_etiket := public.ucretsiz_etiket(p_sebep);

  if v_b.durum = 'ACIK' then
    -- Puanla düşülmüş bir ücret "ücretsiz" olamaz: önce puan geri alınır
    -- (müşterinin puanı geri döner), sonra ücretsiz çıkış.
    if v_b.indirim_kurus > 0 then
      raise exception 'Önce kullanılan puanı geri alın.';
    end if;

    -- Bağışlanan ücret: denetime ve "ücret değişti" bayrağına yazılır.
    if v_b.abonman_id is not null then
      v_hesaplanan := 0;
    else
      v_hesaplanan := public.ucret_hesapla(v_b.giris_at, now(), v_b.tarife_id);
    end if;

    update public.biletler set
      cikis_at           = now(),
      ucret_kurus        = 0,
      tahsil_kurus       = 0,
      odeme_yontemi      = null,
      durum              = 'KAPALI',
      cikis_by           = auth.uid(),
      cikis_kaynak       = 'MOBIL',
      kapatan_vardiya_id = public.acik_vardiyam(),
      ucretsiz_sebep     = p_sebep,
      ucretsiz_not       = v_not,
      ucretsiz_by        = auth.uid(),
      ucretsiz_at        = now(),
      ucret_degistirildi = v_hesaplanan > 0,
      ucret_sebep        = case when v_hesaplanan > 0
                                then 'Ücretsiz çıkış — ' || v_etiket || ': ' || v_not
                                else v_b.ucret_sebep end
    where id = p_bilet_id;

  elsif v_b.durum = 'KAPALI' then
    -- 066: araç çıkmış, ücret borç olarak duruyor. Okuma/tahsil yolundaki
    -- yetkinin aynısı (034): Yönetici ya da bileti kendi açık vardiyasında
    -- kapatan Personel.
    if not (public.is_yonetici()
            or coalesce(v_b.kapatan_vardiya_id = public.acik_vardiyam(), false)) then
      raise exception 'Bu bileti ücretsiz yapma yetkiniz yok.';
    end if;
    if v_b.ucretsiz_sebep is not null then
      raise exception 'Bu bilete zaten ücretsiz çıkış verilmiş.';
    end if;
    -- Kapalı bilette puan geri alınamaz; kısmen puanla ödenmiş bir ücret
    -- "ücretsiz" sayılmaz.
    if v_b.indirim_kurus > 0 then
      raise exception 'Puan kullanılmış bir bilet ücretsiz yapılamaz.';
    end if;
    -- Reddedilen satır sayılmaz (028): red "para gelmedi" demek.
    if v_b.tahsil_kurus <> 0
       or exists (select 1 from public.tahsilatlar t
                   where t.bilet_id = p_bilet_id
                     and t.iptal_of is null
                     and t.durum <> 'REDDEDILDI') then
      raise exception 'Bu biletin ödemesi zaten alınmış.';
    end if;
    if v_b.ucret_kurus - v_b.indirim_kurus <= 0 then
      raise exception 'Bu bilette alınacak ücret yok.';
    end if;

    v_hesaplanan := v_b.ucret_kurus;
    v_sonradan   := true;

    perform set_config('app.bilet_ucretsiz', p_bilet_id::text, true);
    update public.biletler set
      ucret_kurus        = 0,
      ucret_degistirildi = true,
      ucret_sebep        = 'Ücretsiz çıkış — ' || v_etiket || ': ' || v_not,
      ucretsiz_sebep     = p_sebep,
      ucretsiz_not       = v_not,
      ucretsiz_by        = auth.uid(),
      ucretsiz_at        = now()
    where id = p_bilet_id;
    perform set_config('app.bilet_ucretsiz', '', true);

  else
    raise exception 'Bu bilet zaten kapatılmış veya iptal edilmiş.';
  end if;

  -- Ücretsiz kalışa puan kazandırılmaz (030'un abonman kuralıyla aynı
  -- gerekçe): girişte kazanılan puan, bilet_iptal (050) gibi karşı kayıtla
  -- geri alınır — silinmez.
  insert into public.puan_hareketleri (hesap_id, tur, puan, bilet_id, kural_id, created_by, aciklama)
  select ph.hesap_id, 'IPTAL', -ph.puan, ph.bilet_id, ph.kural_id, auth.uid(), 'Ücretsiz çıkış'
    from public.puan_hareketleri ph
   where ph.bilet_id = p_bilet_id and ph.tur = 'KAZANIM';

  perform public.audit('bilet_ucretsiz_cikis', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'sebep', p_sebep, 'not', v_not,
                       'hesaplanan', v_hesaplanan, 'sonradan', v_sonradan));

  -- Yönetici'ye adıyla (notify_yonetici çağıranı atlar: Yönetici kendine
  -- bildirim almaz).
  select ad_soyad into v_ad from public.profiles where id = auth.uid();
  perform public.notify_yonetici('UCRETSIZ_CIKIS', 'Ücretsiz çıkış',
    coalesce(v_ad, 'Bilinmeyen kullanıcı') || ' ücretsiz çıkış verdi: '
      || v_b.plaka || ' · ' || v_etiket || ' — ' || v_not,
    '/gise/bilet/' || p_bilet_id);
end
$fn$;

-- ---------------------------------------------------------------- yetki ----
-- İmzalar değişmedi; `create or replace` yetkileri korur. Yine de aynı
-- kalıp yeniden yazılır ve aşağıda doğrulanır.

revoke all on function public.bilet_ucretsiz_cikis(uuid, public.ucretsiz_sebep, text) from public;
revoke all on function public.bilet_ucretsiz_cikis(uuid, public.ucretsiz_sebep, text)
  from anon, authenticated, service_role;
grant execute on function public.bilet_ucretsiz_cikis(uuid, public.ucretsiz_sebep, text)
  to authenticated;

revoke all on function public.bilet_ucretsiz_temizle()
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r   text;
  f   text := 'public.bilet_ucretsiz_cikis(uuid, public.ucretsiz_sebep, text)';
  src text;
begin
  if not has_function_privilege('authenticated', f, 'execute') then
    raise exception '066: % authenticated rolüne kapalı — ekran çalışmaz', f;
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, f, 'execute') then
      raise exception '066: % % rolüne açık', f, r;
    end if;
  end loop;
  if not exists (select 1 from pg_proc where oid = f::regprocedure
                  and prosecdef and proconfig @> array['search_path=public']) then
    raise exception '066: % SECURITY DEFINER + search_path=public değil', f;
  end if;

  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(r, 'public.bilet_ucretsiz_temizle()', 'execute') then
      raise exception '066: bilet_ucretsiz_temizle % rolüne açık', r;
    end if;
  end loop;

  select pg_get_functiondef('public.biletler_immutable_guard()'::regprocedure) into src;
  if src not like '%app.bilet_ucretsiz%' or src not like '%''ucretsiz_by''%' then
    raise exception '066: değişmezlik guard''ı güncellenmedi';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.biletler'::regclass
                    and tgname = 'biletler_immutable' and not tgisinternal) then
    raise exception '066: biletler_immutable tetiği yok';
  end if;

  if exists (select 1 from public.biletler
              where ucretsiz_sebep is not null and ucretsiz_at is null) then
    raise exception '066: zamanı boş ücretsiz çıkış kaldı (doldurma çalışmadı)';
  end if;
end
$do$;

commit;
