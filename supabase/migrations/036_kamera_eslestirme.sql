-- ============================================================================
-- 036  Kamera eşleştirme: her kameraya kendi kimliği, her şeride kendi nöbeti
-- ============================================================================

begin;

-- ---------------------------------------------------------------- şema ----

-- Bir köprü = bir satır. Gizli anahtarın KENDİSİ hiçbir yerde saklanmıyor,
-- yalnızca sha256'sı: veritabanını okuyan biri çalışan bir kimlik elde edemez.
create table if not exists public.kamera_cihazlari (
  id          uuid primary key default gen_random_uuid(),
  ad          text not null check (length(btrim(ad)) between 1 and 60),
  -- Şerit enum DEĞİL: projede bir `yon` enum'u yok ve kamera-webhook düz
  -- 'GIRIS'/'CIKIS' metinleriyle karşılaştırıyor.
  yon         text not null check (yon in ('GIRIS','CIKIS')),
  gizli_hash  text not null unique,
  aktif       boolean not null default true,
  son_gorulme timestamptz,
  -- Devre dışı bırakma / etkinleştirme anı. Nöbetçi bunu da sayar: yeniden
  -- etkinleştirilen kamera, günler öncesinde kalmış son_gorulme yüzünden
  -- anında uyarı üretmesin. son_gorulme'nin kendisi ekran için doğru kalır.
  durum_at    timestamptz,
  olusturan   uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

-- Kısa ömürlü eşleştirme kodu. Tek kullanımlık ve 15 dakikalık: sızan bir kod
-- neredeyse değersiz olmalı, çünkü telefonda okunuyor ve dosyayla gönderiliyor.
create table if not exists public.kamera_eslestirme (
  id            uuid primary key default gen_random_uuid(),
  kod           text not null unique,
  ad            text not null,
  yon           text not null check (yon in ('GIRIS','CIKIS')),
  bitis         timestamptz not null,
  kullanildi_at timestamptz,
  cihaz_id      uuid references public.kamera_cihazlari(id) on delete set null,
  olusturan     uuid references public.profiles(id) on delete set null,
  created_at    timestamptz not null default now()
);

-- ------------------------------------------------------------- erişim -----

alter table public.kamera_cihazlari  enable row level security;
alter table public.kamera_eslestirme enable row level security;

-- Cihaz listesi Yöneticinindir. Personel SIFIR satır görür: kamera kurulumu
-- onun işi değil ve gördüğü her ekran, görmesi gerekmeyen bir ekran olabilir.
drop policy if exists kamera_cihaz_select on public.kamera_cihazlari;
create policy kamera_cihaz_select on public.kamera_cihazlari for select to authenticated
  using (public.is_yonetici());

-- Yazma politikası YOK: ekleme/silme yalnızca aşağıdaki RPC'lerden.
-- service_role DA geri alınıyor ve aşağıda AÇIKÇA veriliyor: Supabase'in yeni
-- tablolara verdiği varsayılan yetkiye yaslanmak, o varsayılan kalktığında
-- (2026-10-30) eşleştirilen her kameranın 401 almasıyla biterdi; kalkmadığı
-- sürece de webhook'a hiç ihtiyacı olmayan bir yazma yetkisi bırakırdı.
revoke all on public.kamera_cihazlari from anon, authenticated, service_role;

-- `gizli_hash` KOLON LİSTESİNDE YOK. Hash kırılabilir değil ama istemciye
-- vermenin de hiçbir faydası yok; vermemek bedava.
grant select (id, ad, yon, aktif, son_gorulme, durum_at, olusturan, created_at)
  on public.kamera_cihazlari to authenticated;

-- Webhook gizli_hash üzerinden SORGU yapıyor: okuma şart, yazma değil.
grant select on public.kamera_cihazlari to service_role;

-- Politika YOK ve grant YOK (023 push_ayar deseni): bu satırda CANLI bir
-- eşleştirme kodu duruyor ve onu okuyabilen herkes kamera bağlayabilir.
-- Kod bir kez, üretildiği anda gösterilir; bir daha okunamaz.
--
-- service_role DA listede: 023'ten farklı olarak buraya PostgREST üzerinden
-- erişen hiç kimse yok — kodu yalnızca SECURITY DEFINER olan kamera_eslestir
-- okuyor ve o, sahibinin yetkisiyle çalıştığı için tablo grant'ına ihtiyaç
-- duymuyor. kamera_cihazlari'nda durum farklı: webhook gizli_hash üzerinden
-- SORGU yapıyor, o yüzden orada service_role'ün okuması KALMALI.
revoke all on public.kamera_eslestirme from anon, authenticated, service_role;

-- ----------------------------------------------------------------- kod ----

create or replace function public.kamera_kod_uret(p_ad text, p_yon text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  -- Crockford base32 eksi I, L, O, U — telefonda okunurken 1/I ve 0/O
  -- karışmasın. 32 karakter: bir baytın 32 moduğu ÖNYARGISIZ (256 = 8 x 32).
  c_alfabe constant text := '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  v_ad     text := btrim(coalesce(p_ad, ''));
  v_yon    text := upper(btrim(coalesce(p_yon, '')));
  v_bitis  timestamptz := now() + interval '15 minutes';
  v_ham    bytea;
  v_kod    text;
  v_id     uuid;
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  if v_ad = '' or length(v_ad) > 60 then
    raise exception 'Kamera adı 1-60 karakter olmalı.';
  end if;
  if v_yon not in ('GIRIS','CIKIS') then
    raise exception 'Şerit GIRIS ya da CIKIS olmalı.';
  end if;

  -- Süresi geçmiş ve kullanılmamış kodlar birikmesin. Kullanılmışlar duruyor:
  -- hangi kodun hangi cihaza dönüştüğü denetim izinin parçası.
  delete from public.kamera_eslestirme
   where kullanildi_at is null and bitis < now() - interval '1 day';

  if (select count(*) from public.kamera_eslestirme
       where kullanildi_at is null and bitis > now()) >= 10 then
    raise exception 'Çok fazla bekleyen kurulum kodu var. Önce birini iptal edin.';
  end if;

  for v_tur in 1..5 loop
    -- v4 UUID'de 6. bayt sürüm, 8. bayt variant bitleri taşır ve oralarda
    -- 32 moduğu önyargılı olur (6. baytın 4. biti HEP 0). Yalnızca tamamen
    -- rastgele baytlar kullanılıyor: 0-4 ve 9-13.
    v_ham := decode(replace(gen_random_uuid()::text, '-', ''), 'hex');
    v_kod := '';
    for i in 0..4 loop
      v_kod := v_kod || substr(c_alfabe, 1 + (get_byte(v_ham, i) % 32), 1);
    end loop;
    for i in 9..13 loop
      v_kod := v_kod || substr(c_alfabe, 1 + (get_byte(v_ham, i) % 32), 1);
    end loop;

    begin
      insert into public.kamera_eslestirme (kod, ad, yon, bitis, olusturan)
      values (v_kod, v_ad, v_yon, v_bitis, auth.uid())
      returning id into v_id;

      -- Satır kimliği denetim izine giriyor: hangi kodun hangi cihaza
      -- dönüştüğü `kamera_eslestirme.cihaz_id` ile birlikte okunabilsin.
      perform public.audit('kamera_kod_uretildi', 'kamera_eslestirme', v_id,
        jsonb_build_object('ad', v_ad, 'yon', v_yon));

      -- Gösterim biçimi tire taşır, saklanan biçim taşımaz: eşleştirme
      -- tarafı zaten harf/rakam dışını atıyor.
      -- `id` kodun kendisi değil, satırın kimliği: ekran kurulumun nereye
      -- vardığını onunla sorar (kamera_kod_durum) ve kodu bir daha okumaz.
      return jsonb_build_object(
        'id',    v_id,
        'kod',   substr(v_kod, 1, 5) || '-' || substr(v_kod, 6, 5),
        'bitis', v_bitis);
    exception when unique_violation then
      null;  -- 50 bitte neredeyse imkânsız, yine de tekrar dene
    end;
  end loop;

  raise exception 'Kurulum kodu üretilemedi, tekrar deneyin.';
end
$fn$;

-- Kodun KENDİSİ dönmüyor — yalnızca "bir kod bekliyor" bilgisi. Kodu tekrar
-- okunabilir yapmak, tek kullanımlık olmasının anlamını azaltırdı.
create or replace function public.kamera_bekleyen_kodlar()
returns table (id uuid, ad text, yon text, bitis timestamptz)
language plpgsql security definer set search_path = public as $fn$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  -- Her sütun e. ile nitelenmiş: OUT parametreleri tablo sütunlarıyla aynı
  -- adı taşıyor ve nitelenmemiş bir başvuru "column reference is ambiguous"
  -- ile patlardı.
  return query
    select e.id, e.ad, e.yon, e.bitis
      from public.kamera_eslestirme e
     where e.kullanildi_at is null and e.bitis > now()
     order by e.bitis;
end
$fn$;

-- Tek bir kodun akıbeti: bekliyor mu, kullanıldı mı (hangi cihaza), süresi mi
-- doldu. Kodun KENDİSİ burada da dönmüyor. Kurulum ekranı bunu birkaç saniyede
-- bir sorar ki yönetici, otoparktaki kişi kodu girdiği anda bunu görsün —
-- telefonda "oldu mu?" diye sormak zorunda kalmasın.
create or replace function public.kamera_kod_durum(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_e public.kamera_eslestirme;
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_e from public.kamera_eslestirme where id = p_id;
  if not found then
    -- İptal edilmiş ya da hiç var olmamış: ekran ikisini ayırmak zorunda değil.
    return jsonb_build_object('durum', 'YOK');
  end if;
  if v_e.kullanildi_at is not null then
    return jsonb_build_object('durum', 'KULLANILDI', 'cihaz_id', v_e.cihaz_id);
  end if;
  if v_e.bitis < now() then
    return jsonb_build_object('durum', 'DOLDU');
  end if;
  return jsonb_build_object('durum', 'BEKLIYOR');
end
$fn$;

create or replace function public.kamera_kod_iptal(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_e public.kamera_eslestirme;
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_e from public.kamera_eslestirme where id = p_id;
  if not found then
    raise exception 'Kurulum kodu bulunamadı.';
  end if;
  if v_e.kullanildi_at is not null then
    raise exception 'Kullanılmış bir kod iptal edilemez.';
  end if;

  delete from public.kamera_eslestirme where id = p_id;
  perform public.audit('kamera_kod_iptal', 'kamera_eslestirme', p_id,
    jsonb_build_object('ad', v_e.ad, 'yon', v_e.yon));
end
$fn$;

-- ---------------------------------------------------------- eşleştirme ----

-- Yalnızca service_role çağırır (kamera-eslestir Edge Function'ı). İstemciye
-- açık olsaydı kodu gören herkes kamera bağlayabilirdi; auth.uid() burada
-- NULL olduğu için is_yonetici() guard'ı KONULAMAZ, tek sınır grant'tır.
create or replace function public.kamera_eslestir(p_kod text)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_kod   text;
  v_e     public.kamera_eslestirme;
  v_c     public.kamera_cihazlari;
  v_gizli text;
  v_hash  text;
  v_cihaz uuid;
begin
  v_kod := upper(regexp_replace(coalesce(p_kod, ''), '[^0-9A-Za-z]', '', 'g'));
  -- Yanlış uzunluk ve bulunamayan kod AYNI mesajı veriyor: aradaki farkı
  -- söylemek, kod deneyen birine bilgi vermek olurdu.
  --
  -- Dört ret de KE001 taşıyor: Edge Function "kod reddedildi" ile "bir şey
  -- bozuldu"yu buradan ayırıyor ve yalnızca ilkinin mesajını dışarı veriyor.
  if length(v_kod) <> 10 then
    raise exception 'Kurulum kodu geçersiz.' using errcode = 'KE001';
  end if;

  select * into v_e from public.kamera_eslestirme where kod = v_kod for update;
  if not found then
    raise exception 'Kurulum kodu geçersiz.' using errcode = 'KE001';
  end if;

  -- Kullanılmış bir kod YALNIZCA kamerası hiç bağlanmadıysa yeniden denenir.
  -- Cevabı yolda kaybolan (ya da yarıda bırakılan) bir kurulum, yoksa hem
  -- kodu harcar hem de anahtarını kimsenin bilmediği ölü bir cihaz bırakırdı.
  -- Kamera bir kez bağlandıysa ya da yönetici onu kapattıysa kod ölüdür:
  -- çalışan bir kameranın anahtarı eski bir kodla değiştirilememeli.
  if v_e.kullanildi_at is not null then
    select * into v_c from public.kamera_cihazlari
     where id = v_e.cihaz_id for update;
    if not found or v_c.son_gorulme is not null or not v_c.aktif then
      raise exception 'Bu kurulum kodu zaten kullanılmış.' using errcode = 'KE001';
    end if;
  end if;
  if v_e.bitis < now() then
    raise exception 'Kurulum kodunun süresi dolmuş.' using errcode = 'KE001';
  end if;

  -- 244 bit: iki v4 UUID'nin rastgele kısmı. pgcrypto'ya BİLEREK
  -- dokunulmuyor — Supabase onu extensions şemasına kurar ve bu fonksiyon
  -- search_path = public'e sabitli, yani gen_random_bytes ve digest
  -- BULUNAMAZDI. gen_random_uuid ve sha256 pg_catalog'da.
  -- Onaltılık: başlıkta, URL'de ve Basic auth'ta kaçış gerektirmiyor.
  v_gizli := replace(gen_random_uuid()::text, '-', '')
          || replace(gen_random_uuid()::text, '-', '');
  v_hash  := encode(sha256(convert_to(v_gizli, 'UTF8')), 'hex');

  if v_e.kullanildi_at is not null then
    -- Yeniden deneme: YENİ cihaz açılmaz. Aynı satırın anahtarı değişir ve
    -- eskisi o anda ölür — ilk cevabı biri ele geçirdiyse elinde kalan
    -- anahtar artık hiçbir işe yaramaz.
    v_cihaz := v_c.id;
    update public.kamera_cihazlari set gizli_hash = v_hash where id = v_cihaz;

    perform public.audit('kamera_yeniden_eslestirildi', 'kamera_cihazlari', v_cihaz,
      jsonb_build_object('ad', v_e.ad, 'yon', v_e.yon, 'kod_id', v_e.id));
  else
    insert into public.kamera_cihazlari (ad, yon, gizli_hash, olusturan)
    values (v_e.ad, v_e.yon, v_hash, v_e.olusturan)
    returning id into v_cihaz;

    update public.kamera_eslestirme
       set kullanildi_at = now(), cihaz_id = v_cihaz
     where id = v_e.id;

    perform public.audit('kamera_eslestirildi', 'kamera_cihazlari', v_cihaz,
      jsonb_build_object('ad', v_e.ad, 'yon', v_e.yon, 'kod_id', v_e.id));
  end if;

  -- Gizli anahtar yalnızca burada dönüyor; saklanan şey hash'i.
  return jsonb_build_object(
    'cihaz', v_cihaz, 'gizli', v_gizli, 'yon', v_e.yon, 'ad', v_e.ad);
end
$fn$;

-- ---------------------------------------------------------------- cihaz ---

create or replace function public.kamera_cihaz_kaldir(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_c public.kamera_cihazlari;
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_c from public.kamera_cihazlari where id = p_id;
  if not found then
    raise exception 'Kamera bulunamadı.';
  end if;

  -- Kalıcı silme, pasifleştirme değil: hiçbir tablo bu satıra FK ile bağlı
  -- değil ve silmek, anahtarın gerçekten öldüğü konusunda şüphe bırakmıyor.
  delete from public.kamera_cihazlari where id = p_id;

  perform public.audit('kamera_kaldirildi', 'kamera_cihazlari', p_id,
    jsonb_build_object('ad', v_c.ad, 'yon', v_c.yon,
                       'son_gorulme', v_c.son_gorulme));
end
$fn$;

-- Geçici olarak devre dışı bırakma. `aktif = false` İKİ ŞEY birden yapar:
-- kimlik reddedilir ve o kamera için uyarı üretilmez.
--
-- Bunsuz tek çıkış yolu silmekti ve bu kötü bir tuzak: tamire giden kamera
-- için saatte bir uyarı almamanın tek yolu onu SİLMEK olurdu, silince de
-- geri takıldığında biri otoparka gidip yeniden eşleştirmek zorunda kalırdı.
-- Susturulan kamera zaten çalışmıyor, dolayısıyla kimliği reddetmek de doğru.
create or replace function public.kamera_cihaz_durum(p_id uuid, p_aktif boolean)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_c public.kamera_cihazlari;
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_aktif is null then
    raise exception 'Durum belirtilmeli.';
  end if;

  select * into v_c from public.kamera_cihazlari where id = p_id;
  if not found then
    raise exception 'Kamera bulunamadı.';
  end if;

  -- durum_at: nöbetçi, yeniden etkinleştirilen kameraya bir eşik süresi
  -- tanısın. Onsuz, tamirden dönen kamera daha prize takılmadan "haber yok"
  -- uyarısı üretirdi — son_gorulme günler öncesinde kaldığı için.
  update public.kamera_cihazlari
     set aktif = p_aktif, durum_at = now()
   where id = p_id;

  perform public.audit('kamera_durum', 'kamera_cihazlari', p_id,
    jsonb_build_object('ad', v_c.ad, 'yon', v_c.yon, 'aktif', p_aktif));
end
$fn$;

-- Cihaz kalp atışı. GENEL damgaya BİLEREK dokunmuyor: o damga yalnızca elle
-- (env anahtarıyla) kurulmuş köprülerindir. Burada da vurulsaydı, canlı bir
-- eşleştirilmiş kamera ölü bir elle kurulmuş köprüyü taze gösterirdi — yani
-- 036'nın kapattığı açık, karma kurulumda öbür şeritte geri gelirdi.
create or replace function public.kamera_kalp_cihaz(p_cihaz_id uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
begin
  update public.kamera_cihazlari set son_gorulme = now() where id = p_cihaz_id;
end
$fn$;

-- Elle kurulmuş köprünün nöbetini kapatır. Tamamen eşleştirmeye geçen bir
-- otoparkta genel damga bir daha tazelenmez ve bayatladığı için saatte bir
-- uyarı üretirdi; NULL "hiç bildirmedi, uyarma" demektir (004'ten beri).
-- Elle kurulmuş bir köprü yeniden bağlanırsa damga kendiliğinden geri gelir.
create or replace function public.kamera_eski_kopru_unut()
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_eski timestamptz;
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;

  select kamera_kalp_atisi into v_eski from public.otopark_ayarlari where id = 1;
  update public.otopark_ayarlari set kamera_kalp_atisi = null where id = 1;

  perform public.audit('kamera_eski_kopru_unutuldu', 'otopark_ayarlari', null,
    jsonb_build_object('son_kayit', v_eski));
end
$fn$;

-- ------------------------------------------------------------- nöbetçi ----

-- ESKİ HÂLİNDEKİ AÇIK: tek bir genel kamera_kalp_atisi vardı ve iki şeritli
-- bir otoparkta giriş köprüsü onu taze tutuyordu — yani ÇIKIŞ kamerası
-- ölünce hiçbir uyarı çıkmıyordu. Araçlar çıkışta ücretlendirilmeyi bırakır
-- ve bunu söyleyen hiçbir şey olmaz.
--
-- Gövde 004'ten; doluluk dalı BİREBİR korundu, yalnızca kamera dalı ikiye
-- ayrıldı. İmza değişmediği için create or replace ACL'i koruyor (004:173
-- dört rolden de geri almıştı, öyle kalmalı).
create or replace function public.run_kamera_kontrol() returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_o     public.otopark_ayarlari;
  v_c     record;
  v_link  text;
  v_dolu  integer;
  v_yuzde integer;
begin
  select * into v_o from public.otopark_ayarlari where id = 1;
  if not found then
    return;
  end if;

  -- 1. A camera that stopped reporting looks EXACTLY like a car park with no
  --    cars — entries silently stop being recorded and nobody finds out until
  --    the numbers look wrong. Only alert once a camera has ever reported,
  --    otherwise a lot with no hardware would alarm forever.
  -- 1a. Eşleştirilmiş kameralar: her biri KENDİ satırından izlenir.
  for v_c in
    select * from public.kamera_cihazlari
     where aktif and son_gorulme is not null
     order by ad
  loop
    -- Tekilleştirme cihaz başına, link üzerinden. Genel "son bir saatte
    -- KAMERA bildirimi var mı" kontrolü burada YANLIŞ olurdu: ilk ölen
    -- kamera ikincisinin uyarısını susturur ve düzeltilen hata geri gelirdi.
    v_link := '/yonetim/kameralar?c=' || v_c.id::text;
    -- greatest NULL'ı yok sayar: durum_at hiç yazılmadıysa son_gorulme kalır.
    -- Yeni etkinleştirilen kamera böylece bir eşik süresi kadar tanınır.
    if greatest(v_c.son_gorulme, v_c.durum_at)
         < now() - make_interval(mins => v_o.kamera_kalp_esik_dk)
       and not exists (
         select 1 from public.notifications n
          where n.tur = 'KAMERA' and n.link = v_link
            and n.created_at > now() - interval '60 minutes')
    then
      perform public.notify_yonetici('KAMERA',
        v_c.ad || ' kamerasından haber yok',
        'Son kayıt: ' || to_char(v_c.son_gorulme at time zone 'Europe/Istanbul',
                                 'DD.MM.YYYY HH24:MI')
        || '. ' || case when v_c.yon = 'CIKIS' then 'Çıkışlar' else 'Girişler' end
        || ' kaydedilmiyor olabilir.',
        v_link);
    end if;
  end loop;

  -- 1b. Elle (env anahtarıyla) kurulmuş köprü: genel damgadan izlenir ve
  --     yukarıdakinden BAĞIMSIZDIR — `elsif` DEĞİL. Bir şeridi eşleştirilmiş,
  --     öbürü hâlâ ortak anahtarla çalışan otoparkta bu dal atlanırsa, ölen
  --     elle kurulmuş köprü hiç uyarı üretmez. Eşleştirilmiş kameralar bu
  --     damgaya dokunmuyor (kamera_kalp_cihaz), dolayısıyla onu canlı da
  --     gösteremezler. Artık elle kurulmuş köprüsü olmayan otopark damgayı
  --     kamera_eski_kopru_unut ile NULL yapar.
  --     Tekilleştirme TAM link üzerinden: cihaz uyarıları (?c=...) bunu,
  --     bu da onları susturmamalı.
  if v_o.kamera_kalp_atisi is not null
     and v_o.kamera_kalp_atisi < now() - make_interval(mins => v_o.kamera_kalp_esik_dk)
     and not exists (
       select 1 from public.notifications n
        where n.tur = 'KAMERA' and n.link = '/yonetim/kameralar'
          and n.created_at > now() - interval '60 minutes')
  then
    perform public.notify_yonetici('KAMERA', 'Elle kurulmuş kamera köprüsünden haber yok',
      'Son kayıt: ' || to_char(v_o.kamera_kalp_atisi at time zone 'Europe/Istanbul',
                               'DD.MM.YYYY HH24:MI')
      || '. Girişler kaydedilmiyor olabilir.',
      '/yonetim/kameralar');
  end if;

  -- 2. Occupancy. Rate-limited to one alert an hour so a lot hovering at the
  --    threshold does not page the owner every ten minutes.
  select count(*)::integer into v_dolu from public.biletler where durum = 'ACIK';
  v_yuzde := case when v_o.kapasite > 0 then (v_dolu * 100) / v_o.kapasite else 0 end;

  if v_yuzde >= v_o.doluluk_uyari_yuzde
     and not exists (
       select 1 from public.notifications n
        where n.tur = 'DOLULUK' and n.created_at > now() - interval '60 minutes')
  then
    perform public.notify_yonetici('DOLULUK', 'Otopark doluyor',
      '%' || v_yuzde || ' dolu (' || v_dolu || '/' || v_o.kapasite || ').', '/');
  end if;
end
$fn$;

-- -------------------------------------------------------------- yetki -----

-- from public OLMADAN bu satırların hiçbiri bir şey kapatmaz (012 olayı);
-- service_role OLMADAN da kapatmaz (033 olayı). Dördü birden yazılıyor.
revoke all on function public.kamera_kod_uret(text, text) from public;
revoke all on function public.kamera_kod_uret(text, text) from anon, service_role;
grant execute on function public.kamera_kod_uret(text, text) to authenticated;

revoke all on function public.kamera_bekleyen_kodlar() from public;
revoke all on function public.kamera_bekleyen_kodlar() from anon, service_role;
grant execute on function public.kamera_bekleyen_kodlar() to authenticated;

revoke all on function public.kamera_kod_durum(uuid) from public;
revoke all on function public.kamera_kod_durum(uuid) from anon, service_role;
grant execute on function public.kamera_kod_durum(uuid) to authenticated;

revoke all on function public.kamera_kod_iptal(uuid) from public;
revoke all on function public.kamera_kod_iptal(uuid) from anon, service_role;
grant execute on function public.kamera_kod_iptal(uuid) to authenticated;

revoke all on function public.kamera_cihaz_kaldir(uuid) from public;
revoke all on function public.kamera_cihaz_kaldir(uuid) from anon, service_role;
grant execute on function public.kamera_cihaz_kaldir(uuid) to authenticated;

revoke all on function public.kamera_cihaz_durum(uuid, boolean) from public;
revoke all on function public.kamera_cihaz_durum(uuid, boolean) from anon, service_role;
grant execute on function public.kamera_cihaz_durum(uuid, boolean) to authenticated;

revoke all on function public.kamera_eski_kopru_unut() from public;
revoke all on function public.kamera_eski_kopru_unut() from anon, service_role;
grant execute on function public.kamera_eski_kopru_unut() to authenticated;

-- Bu ikisi İSTEMCİYE KAPALI. kamera_eslestir kimlik basar; kamera_kalp_cihaz
-- kalp atışı uydurur ve ölü bir kamerayı canlı gösterirdi.
revoke all on function public.kamera_eslestir(text) from public;
revoke all on function public.kamera_eslestir(text) from anon, authenticated;
grant execute on function public.kamera_eslestir(text) to service_role;

revoke all on function public.kamera_kalp_cihaz(uuid) from public;
revoke all on function public.kamera_kalp_cihaz(uuid) from anon, authenticated;
grant execute on function public.kamera_kalp_cihaz(uuid) to service_role;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
  f text;
  v_istemci text[] := array['public.kamera_kod_uret(text, text)',
                            'public.kamera_bekleyen_kodlar()',
                            'public.kamera_kod_durum(uuid)',
                            'public.kamera_kod_iptal(uuid)',
                            'public.kamera_cihaz_kaldir(uuid)',
                            'public.kamera_cihaz_durum(uuid, boolean)',
                            'public.kamera_eski_kopru_unut()'];
  v_sunucu  text[] := array['public.kamera_eslestir(text)',
                            'public.kamera_kalp_cihaz(uuid)'];
begin
  -- Hash istemciye sızmamalı, ama ekranın okuduğu kolonlar açık kalmalı.
  if has_column_privilege('authenticated', 'public.kamera_cihazlari',
                          'gizli_hash', 'SELECT') then
    raise exception '036: kamera_cihazlari.gizli_hash istemciye açık';
  end if;
  if not has_column_privilege('authenticated', 'public.kamera_cihazlari',
                              'ad', 'SELECT') then
    raise exception '036: kamera_cihazlari okunamıyor — ekran boş kalır';
  end if;

  -- Canlı kodlar hiçbir role açık olmamalı — service_role dâhil, çünkü oraya
  -- PostgREST üzerinden erişen hiç kimse yok.
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_table_privilege(r, 'public.kamera_eslestirme', 'SELECT') then
      raise exception '036: kamera_eslestirme % rolüne açık', r;
    end if;
  end loop;

  -- Buna KARŞILIK webhook, gizli_hash üzerinden sorgu yapabilmek için
  -- kamera_cihazlari'nı okumak ZORUNDA. Kapanırsa cihaz kimlikleri sessizce
  -- reddedilir ve eşleştirilen her kamera 401 alır.
  if not has_column_privilege('service_role', 'public.kamera_cihazlari',
                              'gizli_hash', 'SELECT') then
    raise exception '036: webhook gizli_hash okuyamıyor — cihaz kimlikleri çalışmaz';
  end if;
  -- Okuma var, YAZMA yok: cihazı yalnızca kamera_eslestir oluşturur.
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_table_privilege(r, 'public.kamera_cihazlari', 'INSERT')
       or has_table_privilege(r, 'public.kamera_cihazlari', 'UPDATE')
       or has_table_privilege(r, 'public.kamera_cihazlari', 'DELETE') then
      raise exception '036: % kamera_cihazlari tablosuna yazabiliyor', r;
    end if;
  end loop;

  -- Yönetici RPC'leri: istemciye açık, sunucuya kapalı.
  foreach f in array v_istemci loop
    if not has_function_privilege('authenticated', f, 'execute') then
      raise exception '036: % authenticated rolüne kapalı kalmış', f;
    end if;
    foreach r in array array['anon', 'service_role'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception '036: % istemci dışı % rolüne açık', f, r;
      end if;
    end loop;
  end loop;

  -- Kimlik basan RPC'ler: yalnızca service_role.
  foreach f in array v_sunucu loop
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception '036: % service_role rolüne kapalı — eşleştirme çalışmaz', f;
    end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception '036: % istemciye açık (%)', f, r;
      end if;
    end loop;
  end loop;

  -- 004'ün kapattığı nöbetçi kapalı kalmalı: create or replace ACL'i korur,
  -- ama bu satır onu kanıtlıyor.
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(r, 'public.run_kamera_kontrol()', 'execute') then
      raise exception '036: run_kamera_kontrol % rolüne açıldı', r;
    end if;
  end loop;
end
$do$;

commit;
