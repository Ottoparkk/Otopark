-- ============================================================================
-- 062  Abonman: ödeme günü; Personel görür, ekler ve tahsil eder
-- ============================================================================

begin;

-- Sahip (2026-11-15):
--   · Başlangıç/bitiş tarihi seçilmez; ÖDEME GÜNÜ seçilir ("Ayın 13'ü",
--     "Ayın 1'i"). 29–31 kısa ayda ayın son günü olur.
--   · Personel abonmanları takip eder ve tahsil eder: Abonman sekmesini
--     görür, yeni abonman ekler (ilk ödeme aynı formda) ve ödeme alır.
--     Düzenleme, İptal ve Sil Yönetici'de KALIR.
--   · Personel'in eklediği abonman Yönetici'ye, ekleyenin adıyla bildirilir.
--
-- Bugüne kadar (003) abonman tablosu tümüyle Yönetici'nindi ve Personel
-- fiyatı göremezdi (PASS 06a bunu sınıyordu); geçerliliği yalnızca
-- abonman_gecerli_mi ile öğrenirdi. Bu, sahibin bilinçli kararıyla değişir:
-- Personel satırı (fiyat dahil) OKUR, ama tabloya YAZAMAZ — ekleme ve tahsil
-- yalnızca aşağıdaki iki RPC ile, kendi kurallarıyla.
--
-- Dönem kuralları (istemcide src/lib/abonman.ts aynısı; PASS 80b ile
-- tests/abonman.check.mjs aynı tabloyu sınar):
--   · sonraki(gün, tarih) = tarihten SONRAKİ ilk tarih ki günü
--     min(gün, o ayın son günü).
--   · Bitiş günü DAHİL geçerlidir (abonman_gecerli_mi 002'den beri böyle):
--     araç ödeme gününde ücretsiz girer, ödeme o gün beklenir; ödenmezse o
--     gecenin işi (025) abonmanı DOLDU yapar.
--   · Yeni abonman: bugünden sonraki(gün, bugün)'e kadar. Gün varsayılan
--     olarak bugünün günüdür, yani ilk dönem tam bir ay.
--   · Tahsil + uzat: süren abonmanda bitiş sonraki(gün, bitiş); süresi
--     dolmuşta dönem bugünden sonraki(gün, bugün)'e — geçmiş günler satılmaz.
--     Uzatma ödemeyle AYNI çağrıda (eskiden istemcinin iki ayrı adımıydı:
--     ödeme yazılıp uzatma düşebiliyordu).
--   · Para: tahsilat açık kasa vardiyasına yazılır (kasa sayımı onu sayar,
--     035) ve Onay bekler (017). Personel'in açık vardiyası yoksa reddedilir —
--     sayılmayan nakit olmasın.

-- --------------------------------------------------------------- kolon ----

alter table public.abonmanlar
  add column if not exists yenileme_gunu smallint;
alter table public.abonmanlar
  drop constraint if exists abonmanlar_yenileme_gunu_ck;
alter table public.abonmanlar
  add constraint abonmanlar_yenileme_gunu_ck
  check (yenileme_gunu is null or yenileme_gunu between 1 and 31);

-- Var olan abonmanların ödeme günü = bitişlerinin günü. Kolon BOŞ
-- bırakılabilir kalır: bu dosya koşulduğu ile yeni ön yüz yayınlandığı an
-- arasında eski ön yüz tabloya doğrudan (yalnızca Yönetici) ekleyebilir;
-- her fonksiyon boşu `bitis`in günüyle okur.
update public.abonmanlar
   set yenileme_gunu = extract(day from bitis)::smallint
 where yenileme_gunu is null;

-- ---------------------------------------------------------------- RLS -----

-- 003'ün tek "for all" politikası ikiye ayrılır: OKUMA bütün personele,
-- YAZMA yalnızca Yönetici'ye (Düzenle / İptal; Sil zaten abonman_sil RPC'si).
-- Rolsüz (PENDING) kullanıcı is_staff() değildir: hâlâ sıfır satır (PASS 02).
drop policy if exists abonmanlar_all    on public.abonmanlar;
drop policy if exists abonmanlar_select on public.abonmanlar;
drop policy if exists abonmanlar_insert on public.abonmanlar;
drop policy if exists abonmanlar_update on public.abonmanlar;
drop policy if exists abonmanlar_delete on public.abonmanlar;

create policy abonmanlar_select on public.abonmanlar for select to authenticated
  using (public.is_staff());
create policy abonmanlar_insert on public.abonmanlar for insert to authenticated
  with check (public.is_yonetici());
create policy abonmanlar_update on public.abonmanlar for update to authenticated
  using (public.is_yonetici()) with check (public.is_yonetici());
create policy abonmanlar_delete on public.abonmanlar for delete to authenticated
  using (public.is_yonetici());

-- --------------------------------------------- abonman_sonraki_yenileme ----

-- Saf tarih aritmetiği (saat dilimi yok). Gün boşsa boş döner: least() boşu
-- yok sayardı ve sessizce "ayın son günü" çıkardı.
create or replace function public.abonman_sonraki_yenileme(p_gun integer, p_from date)
returns date
language sql immutable set search_path = public as $fn$
  with a as (
    select (p_from - (extract(day from p_from)::integer - 1)) as m1
  ), b as (
    select m1, (m1 + interval '1 month')::date as m2 from a
  ), c as (
    select
      m1 + (least(p_gun, ((m1 + interval '1 month')::date - m1)) - 1) as c1,
      m2 + (least(p_gun, ((m2 + interval '1 month')::date - m2)) - 1) as c2
    from b
  )
  select case when c1 > p_from then c1 else c2 end
    from c
   where p_gun is not null and p_from is not null;
$fn$;

-- ------------------------------------------------------- abonman_ekle -----

create or replace function public.abonman_ekle(
  p_plaka          text,
  p_musteri_ad     text,
  p_musteri_tel    text,
  p_ucret_kurus    integer,
  p_yenileme_gunu  integer,
  p_park_yeri_id   uuid,
  p_notlar         text,
  p_tutar_kurus    integer,
  p_yontem         public.odeme_yontemi
) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_plaka   text := public.normalize_plaka(p_plaka);
  v_tel     text := nullif(btrim(coalesce(p_musteri_tel, '')), '');
  v_tutar   integer := coalesce(p_tutar_kurus, 0);
  v_bugun   date := (now() at time zone 'Europe/Istanbul')::date;
  v_bitis   date;
  v_vardiya uuid;
  v_id      uuid;
  v_ekleyen text;
  v_ek      text;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  v_vardiya := public.acik_vardiyam();
  if not public.is_yonetici() and v_vardiya is null then
    raise exception 'Önce vardiya açın — ödeme kasaya yazılır.';
  end if;

  if v_plaka !~ '^[A-Z0-9]{2,15}$' then
    raise exception 'Geçerli bir plaka girin.';
  end if;
  if p_yenileme_gunu is null or p_yenileme_gunu not between 1 and 31 then
    raise exception 'Ödeme günü 1 ile 31 arasında olmalı.';
  end if;
  if p_ucret_kurus is null or p_ucret_kurus < 0 then
    raise exception 'Geçerli bir aylık ücret girin.';
  end if;
  if v_tel is not null and v_tel !~ '^[1-9][0-9]{9}$' then
    raise exception 'Telefon 10 haneli olmalı (5XXXXXXXXX).';
  end if;
  if v_tutar < 0 then
    raise exception 'Tutar negatif olamaz.';
  end if;
  -- Personel ilk ödemeyi almadan abonman açamaz (sahip: ilk ay aynı formda).
  -- Yönetici ücretsiz abonman açabilir.
  if v_tutar = 0 and not public.is_yonetici() then
    raise exception 'İlk ödeme tutarı sıfırdan büyük olmalı.';
  end if;
  if v_tutar > 0 and p_yontem is null then
    raise exception 'Ödeme yöntemi zorunludur.';
  end if;

  v_bitis := public.abonman_sonraki_yenileme(p_yenileme_gunu, v_bugun);

  begin
    insert into public.abonmanlar (
      plaka, musteri_ad, musteri_tel, baslangic, bitis, ucret_kurus,
      park_yeri_id, notlar, yenileme_gunu, durum, olusturan)
    values (
      v_plaka, coalesce(btrim(p_musteri_ad), ''), v_tel, v_bugun, v_bitis, p_ucret_kurus,
      p_park_yeri_id, nullif(btrim(coalesce(p_notlar, '')), ''), p_yenileme_gunu, 'AKTIF',
      auth.uid())
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'Bu plakanın bu dönemde başka bir abonmanı var.';
  end;

  -- İlk ay. Tutar sıfırsa (yalnızca Yönetici) satır yok: tahsilatlar > 0 ister.
  if v_tutar > 0 then
    insert into public.tahsilatlar (tur, abonman_id, tutar_kurus, yontem, vardiya_id, created_by, aciklama)
    values ('ABONMAN', v_id, v_tutar, p_yontem, v_vardiya, auth.uid(), v_plaka);
  end if;

  perform public.audit('abonman_ekle', 'abonmanlar', v_id,
    jsonb_build_object('plaka', v_plaka, 'ucret', p_ucret_kurus, 'gun', p_yenileme_gunu,
                       'bitis', v_bitis, 'ilk_odeme', v_tutar,
                       'yontem', case when v_tutar > 0 then p_yontem end,
                       'vardiya', v_vardiya));

  -- "Ayın 13'ü": Türkçe iyelik eki sayının okunuşuna göre.
  v_ek := case
            when p_yenileme_gunu % 10 = 0 then case p_yenileme_gunu when 20 then 'si' else 'u' end
            else (array['i','si','ü','ü','i','sı','si','i','u'])[p_yenileme_gunu % 10]
          end;
  select coalesce(nullif(btrim(p.ad_soyad), ''), 'Bir personel') into v_ekleyen
    from public.profiles p where p.id = auth.uid();

  -- notify_yonetici ekleyenin kendisine göndermez (Yönetici eklediyse
  -- yalnızca diğer Yöneticiler alır).
  perform public.notify_yonetici('YENI_ABONMAN', 'Yeni abonman',
    coalesce(v_ekleyen, 'Bir personel') || ' yeni abonman ekledi: ' || v_plaka
      || ' · ' || (p_ucret_kurus / 100.0)::numeric(12,2) || ' ₺ · ayın '
      || p_yenileme_gunu || '''' || v_ek
      || case when v_tutar > 0 then '' else ' · ödeme alınmadı' end,
    '/abonman/' || v_id);

  return v_id;
end
$fn$;

-- ------------------------------------------------------ abonman_tahsil -----

-- 002'nin üç argümanlı hâli Yönetici'ye özeldi ve dönemi uzatmıyordu.
-- Kaldırılır; yenisinde `p_yenile` VARSAYILAN false: bu dosya ile yeni ön yüz
-- arasındaki kısa sürede eski ön yüzün adlı üç argümanlı çağrısı eskisi gibi
-- yalnızca ödemeyi yazar (dönemi kendisi ayrıca günceller).
drop function if exists public.abonman_tahsil(uuid, public.odeme_yontemi, integer);

create or replace function public.abonman_tahsil(
  p_abonman_id  uuid,
  p_yontem      public.odeme_yontemi,
  p_tutar_kurus integer default null,
  p_yenile      boolean default false
) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_a       public.abonmanlar;
  v_tutar   integer;
  v_vardiya uuid;
  v_id      uuid;
  v_bugun   date := (now() at time zone 'Europe/Istanbul')::date;
  v_gun     integer;
  v_bas     date;
  v_bit     date;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  v_vardiya := public.acik_vardiyam();
  if not public.is_yonetici() and v_vardiya is null then
    raise exception 'Önce vardiya açın — ödeme kasaya yazılır.';
  end if;

  select * into v_a from public.abonmanlar where id = p_abonman_id for update;
  if not found then
    raise exception 'Abonman bulunamadı.';
  end if;
  if v_a.durum = 'IPTAL' then
    raise exception 'İptal edilmiş abonman tahsil edilemez.';
  end if;

  v_tutar := coalesce(p_tutar_kurus, v_a.ucret_kurus);
  if v_tutar is null or v_tutar <= 0 then
    raise exception 'Tahsilat tutarı sıfırdan büyük olmalı.';
  end if;
  if p_yontem is null then
    raise exception 'Ödeme yöntemi zorunludur.';
  end if;

  insert into public.tahsilatlar (tur, abonman_id, tutar_kurus, yontem, vardiya_id, created_by, aciklama)
  values ('ABONMAN', p_abonman_id, v_tutar, p_yontem, v_vardiya, auth.uid(), v_a.plaka)
  returning id into v_id;

  if p_yenile then
    v_gun := coalesce(v_a.yenileme_gunu, extract(day from v_a.bitis)::integer);
    if v_a.durum = 'AKTIF' and v_a.bitis >= v_bugun then
      v_bas := v_a.baslangic;
      v_bit := public.abonman_sonraki_yenileme(v_gun, v_a.bitis);
    else
      v_bas := v_bugun;
      v_bit := public.abonman_sonraki_yenileme(v_gun, v_bugun);
    end if;
    begin
      update public.abonmanlar
         set baslangic = v_bas, bitis = v_bit, durum = 'AKTIF', yenileme_gunu = v_gun
       where id = p_abonman_id;
    exception when exclusion_violation then
      -- Ödeme de geri alınır: hata tüm çağrıyı düşürür.
      raise exception 'Bu plakanın bu dönemde başka bir abonmanı var.';
    end;
  end if;

  perform public.audit('abonman_tahsil', 'abonmanlar', p_abonman_id,
    jsonb_build_object('tutar', v_tutar, 'yontem', p_yontem, 'vardiya', v_vardiya,
                       'yenile', p_yenile, 'eski_bitis', v_a.bitis,
                       'yeni_bitis', coalesce(v_bit, v_a.bitis)));
  return v_id;
end
$fn$;

-- --------------------------------------------- bildirim_yonetici_turu -----

-- Gövde 058'den BİREBİR; listeye 'YENI_ABONMAN' eklendi (Yönetici'ye özel).
create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $fn$
  select p_tur::text in (
    'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA',
    'KAMERA_HAREKET','VARDIYA_ACIK','ONAY_BEKLIYOR','PLAKA_SUPHE',
    'VARDIYA_KAPATMA','BILET_IPTAL_TALEBI','KAMERA_GERI_ACILDI',
    'KAMERA_GUNLUK','YENI_ABONMAN'
  );
$fn$;

-- ---------------------------------------------------------------- yetki ----

-- from public OLMADAN hiçbir şey kapanmaz (012); service_role OLMADAN da (033).
revoke all on function public.abonman_sonraki_yenileme(integer, date)
  from public, anon, authenticated, service_role;

revoke all on function public.abonman_ekle(text, text, text, integer, integer, uuid, text, integer, public.odeme_yontemi)
  from public;
revoke all on function public.abonman_ekle(text, text, text, integer, integer, uuid, text, integer, public.odeme_yontemi)
  from anon, authenticated, service_role;
grant execute on function public.abonman_ekle(text, text, text, integer, integer, uuid, text, integer, public.odeme_yontemi)
  to authenticated;

revoke all on function public.abonman_tahsil(uuid, public.odeme_yontemi, integer, boolean) from public;
revoke all on function public.abonman_tahsil(uuid, public.odeme_yontemi, integer, boolean)
  from anon, authenticated, service_role;
grant execute on function public.abonman_tahsil(uuid, public.odeme_yontemi, integer, boolean)
  to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
  f text;
begin
  foreach f in array array[
      'public.abonman_ekle(text, text, text, integer, integer, uuid, text, integer, public.odeme_yontemi)',
      'public.abonman_tahsil(uuid, public.odeme_yontemi, integer, boolean)'] loop
    if not has_function_privilege('authenticated', f, 'execute') then
      raise exception '062: % authenticated rolüne kapalı — ekran çalışmaz', f;
    end if;
    foreach r in array array['anon', 'service_role'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception '062: % % rolüne açık', f, r;
      end if;
    end loop;
    if not exists (select 1 from pg_proc where oid = f::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
      raise exception '062: % SECURITY DEFINER + search_path=public değil', f;
    end if;
  end loop;

  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(r, 'public.abonman_sonraki_yenileme(integer, date)', 'execute') then
      raise exception '062: abonman_sonraki_yenileme % rolüne açık', r;
    end if;
  end loop;

  if to_regprocedure('public.abonman_tahsil(uuid, public.odeme_yontemi, integer)') is not null then
    raise exception '062: eski abonman_tahsil hâlâ duruyor';
  end if;

  if exists (select 1 from public.abonmanlar where yenileme_gunu is null) then
    raise exception '062: ödeme günü boş abonman kaldı';
  end if;

  if (select count(*) from pg_policies
       where schemaname = 'public' and tablename = 'abonmanlar') <> 4
     or exists (select 1 from pg_policies
                 where schemaname = 'public' and tablename = 'abonmanlar'
                   and policyname = 'abonmanlar_all') then
    raise exception '062: abonmanlar politikaları beklenen dört politika değil';
  end if;

  -- Gün hesabının birkaç ucu (tam tablo PASS 80b'de).
  if public.abonman_sonraki_yenileme(31, date '2027-02-15') <> date '2027-02-28'
     or public.abonman_sonraki_yenileme(31, date '2027-02-28') <> date '2027-03-31'
     or public.abonman_sonraki_yenileme(13, date '2026-11-13') <> date '2026-12-13'
     or public.abonman_sonraki_yenileme(1, date '2026-12-01') <> date '2027-01-01' then
    raise exception '062: abonman_sonraki_yenileme yanlış hesaplıyor';
  end if;

  -- 061 koşulmuş olmalı (enum değeri metin olarak okunur — 55P04).
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'bildirim_tur' and e.enumlabel = 'YENI_ABONMAN') then
    raise exception '062: 061 koşulmamış — YENI_ABONMAN yok';
  end if;
end
$do$;

commit;
