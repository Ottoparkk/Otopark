-- ============================================================================
-- 065  Ücretsiz çıkış: sebep + zorunlu not
-- ============================================================================

begin;

-- Sahip (2026-11-15): bazı araçlar yalnızca fiyat sormak için girer, bazen
-- polis, ambulans ya da personelin aracı gelir — bunlardan para alınmaz.
-- Bugünkü iki yol da uymuyordu: ücreti elle 0 yapmak (Değiştir → sebep →
-- Çıkışı Kaydet) çok adımlı ve sebep TÜRÜ yok; "Çıkış Ver" ise aracı BORÇLU
-- çıkarır.
--
-- Kararlar:
--   · Her rol verir (Personel de); sebep seçilir, NOT ZORUNLU.
--   · Para yazılmaz: tahsilat satırı yok, Onay'a düşmez, ciroya girmez.
--   · Onay beklenmez: Yönetici adıyla, plakayla, sebep ve notla bilgilenir.
--   · Ücretsiz dakika içindeki kalış zaten 0 ₺; ekran düğmeyi yalnızca ücret
--     varken gösterir, sunucu yine de 0 ₺'lik bileti de kabul eder.
-- PASS 82 sınar.

-- ------------------------------------------------------------------- tür ---
-- Yeni bir TÜR aynı transaction içinde kullanılabilir; yalnızca var olan bir
-- türe `add value` kullanılamaz (55P04). Etiketler src/lib/ucretsiz.ts ile
-- aynı olmalı (ucretsiz_etiket aşağıda).

do $$
begin
  if to_regtype('public.ucretsiz_sebep') is null then
    create type public.ucretsiz_sebep as enum
      ('FIYAT_SORDU', 'POLIS', 'ACIL', 'PERSONEL', 'DIGER');
  end if;
end $$;

alter table public.biletler
  add column if not exists ucretsiz_sebep public.ucretsiz_sebep,
  add column if not exists ucretsiz_not   text;

alter table public.biletler drop constraint if exists biletler_ucretsiz_ck;
alter table public.biletler add constraint biletler_ucretsiz_ck check (
  (ucretsiz_sebep is null and ucretsiz_not is null)
  or (ucretsiz_sebep is not null and ucretsiz_not is not null
      and char_length(btrim(ucretsiz_not)) between 1 and 200)
);

-- --------------------------------------------------------- ucretsiz_etiket --

create or replace function public.ucretsiz_etiket(p_sebep public.ucretsiz_sebep)
returns text
language sql immutable as $fn$
  select case p_sebep
    when 'FIYAT_SORDU' then 'Fiyat sordu'
    when 'POLIS'       then 'Polis / resmi araç'
    when 'ACIL'        then 'Ambulans / itfaiye'
    when 'PERSONEL'    then 'Personel / sahip aracı'
    when 'DIGER'       then 'Diğer'
  end;
$fn$;

-- ---------------------------------------------------- bilet_ucretsiz_cikis --
-- bilet_kapat'ın (030) para dalları olmadan kopyası: bilet AÇIKKEN tek
-- UPDATE ile kapanır (immutable guard ACIK satıra dokunmaz). Ücret 0, tahsil
-- 0, yöntem yok. ucret_degistirildi + ucret_sebep doldurulur ki mevcut
-- "Ücret elle değiştirilmiş" uyarısı ve Raporlar'daki Denetim sayısı bunu da
-- görsün.

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
  if v_b.durum <> 'ACIK' then
    raise exception 'Bu bilet zaten kapatılmış veya iptal edilmiş.';
  end if;
  -- Puanla düşülmüş bir ücret "ücretsiz" olamaz: önce puan geri alınır
  -- (müşterinin puanı geri döner), sonra ücretsiz çıkış.
  if v_b.indirim_kurus > 0 then
    raise exception 'Önce kullanılan puanı geri alın.';
  end if;

  v_etiket := public.ucretsiz_etiket(p_sebep);
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
    ucret_degistirildi = v_hesaplanan > 0,
    ucret_sebep        = case when v_hesaplanan > 0
                              then 'Ücretsiz çıkış — ' || v_etiket || ': ' || v_not
                              else v_b.ucret_sebep end
  where id = p_bilet_id;

  -- Ücretsiz kalışa puan kazandırılmaz (030'un abonman kuralıyla aynı
  -- gerekçe): girişte kazanılan puan, bilet_iptal (050) gibi karşı kayıtla
  -- geri alınır — silinmez.
  insert into public.puan_hareketleri (hesap_id, tur, puan, bilet_id, kural_id, created_by, aciklama)
  select ph.hesap_id, 'IPTAL', -ph.puan, ph.bilet_id, ph.kural_id, auth.uid(), 'Ücretsiz çıkış'
    from public.puan_hareketleri ph
   where ph.bilet_id = p_bilet_id and ph.tur = 'KAZANIM';

  perform public.audit('bilet_ucretsiz_cikis', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'sebep', p_sebep, 'not', v_not,
                       'hesaplanan', v_hesaplanan));

  -- Yönetici'ye adıyla (notify_yonetici çağıranı atlar: Yönetici kendine
  -- bildirim almaz).
  select ad_soyad into v_ad from public.profiles where id = auth.uid();
  perform public.notify_yonetici('UCRETSIZ_CIKIS', 'Ücretsiz çıkış',
    coalesce(v_ad, 'Bilinmeyen kullanıcı') || ' ücretsiz çıkış verdi: '
      || v_b.plaka || ' · ' || v_etiket || ' — ' || v_not,
    '/gise/bilet/' || p_bilet_id);
end
$fn$;

-- --------------------------------------------- bildirim_yonetici_turu -----
-- Gövde 062'den BİREBİR; listeye 'UCRETSIZ_CIKIS' eklendi (Yönetici'ye özel).

create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $fn$
  select p_tur::text in (
    'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA',
    'KAMERA_HAREKET','VARDIYA_ACIK','ONAY_BEKLIYOR','PLAKA_SUPHE',
    'VARDIYA_KAPATMA','BILET_IPTAL_TALEBI','KAMERA_GERI_ACILDI',
    'KAMERA_GUNLUK','YENI_ABONMAN','UCRETSIZ_CIKIS'
  );
$fn$;

-- ------------------------------------------- bilet_ucretsiz_temizle -------
-- "Araç çıkmadı" (054 / 060) bileti yeniden AÇIK yapar ve ücret izini
-- (`ucret_sebep`, `ucret_degistirildi`) siler, ama bu iki yeni sütunu
-- bilmez: sebep kalsaydı bilet sonra parayla çıksa bile "Ücretsiz"
-- görünürdü. 050'deki gibi tek tetik — her geri açma yolunu tek tek
-- değiştirmek yerine; denetimde ücretsiz çıkışın izi kalır. PASS 82h sınar.

create or replace function public.bilet_ucretsiz_temizle()
returns trigger
language plpgsql set search_path = public as $$
begin
  new.ucretsiz_sebep := null;
  new.ucretsiz_not   := null;
  return new;
end $$;

drop trigger if exists bilet_ucretsiz_temizle_tg on public.biletler;
create trigger bilet_ucretsiz_temizle_tg
  before update on public.biletler
  for each row
  when (old.durum <> 'ACIK' and new.durum = 'ACIK')
  execute function public.bilet_ucretsiz_temizle();

-- ---------------------------------------------------------------- yetki ----

revoke all on function public.bilet_ucretsiz_temizle()
  from public, anon, authenticated, service_role;

revoke all on function public.ucretsiz_etiket(public.ucretsiz_sebep)
  from public, anon, authenticated, service_role;

revoke all on function public.bilet_ucretsiz_cikis(uuid, public.ucretsiz_sebep, text) from public;
revoke all on function public.bilet_ucretsiz_cikis(uuid, public.ucretsiz_sebep, text)
  from anon, authenticated, service_role;
grant execute on function public.bilet_ucretsiz_cikis(uuid, public.ucretsiz_sebep, text)
  to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
  f text := 'public.bilet_ucretsiz_cikis(uuid, public.ucretsiz_sebep, text)';
begin
  if not has_function_privilege('authenticated', f, 'execute') then
    raise exception '065: % authenticated rolüne kapalı — ekran çalışmaz', f;
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, f, 'execute') then
      raise exception '065: % % rolüne açık', f, r;
    end if;
  end loop;
  if not exists (select 1 from pg_proc where oid = f::regprocedure
                  and prosecdef and proconfig @> array['search_path=public']) then
    raise exception '065: % SECURITY DEFINER + search_path=public değil', f;
  end if;

  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(r, 'public.ucretsiz_etiket(public.ucretsiz_sebep)', 'execute') then
      raise exception '065: ucretsiz_etiket % rolüne açık', r;
    end if;
  end loop;

  if (select string_agg(e.enumlabel, ',' order by e.enumsortorder)
        from pg_enum e where e.enumtypid = 'public.ucretsiz_sebep'::regtype)
     is distinct from 'FIYAT_SORDU,POLIS,ACIL,PERSONEL,DIGER' then
    raise exception '065: ucretsiz_sebep değerleri beklenmedik';
  end if;

  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(r, 'public.bilet_ucretsiz_temizle()', 'execute') then
      raise exception '065: bilet_ucretsiz_temizle % rolüne açık', r;
    end if;
  end loop;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.biletler'::regclass
                    and tgname = 'bilet_ucretsiz_temizle_tg' and not tgisinternal) then
    raise exception '065: bilet_ucretsiz_temizle_tg tetiği yok';
  end if;

  if public.ucretsiz_etiket('POLIS') <> 'Polis / resmi araç' then
    raise exception '065: ucretsiz_etiket yanlış';
  end if;

  -- 064 koşulmuş olmalı (enum değeri metin olarak okunur — 55P04).
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'bildirim_tur' and e.enumlabel = 'UCRETSIZ_CIKIS') then
    raise exception '065: 064 koşulmamış — UCRETSIZ_CIKIS yok';
  end if;
end
$do$;

commit;
