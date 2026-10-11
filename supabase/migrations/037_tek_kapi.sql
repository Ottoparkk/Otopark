-- ============================================================================
-- 037  Tek kapı: giriş ve çıkış aynı kapıdan — yönü bilet durumu söyler
-- ============================================================================

alter type public.istisna_tur add value if not exists 'YON_BELIRSIZ';

begin;

-- ---------------------------------------------------------------- şema ----

-- 019 dersi: yukarıda eklenen enum değeri bu dosyada HİÇBİR YERDE enum
-- literali olarak çalıştırılmıyor. Yalnızca plpgsql gövdesinde geçiyor (o da
-- ilk çağrıda, yani commit'ten sonra çözülür); doğrulama pg_enum'dan okuyor.

-- Üç tablodaki `yon` kısıtı üçüncü şeridi de tanımalı. Kısıtlar 001 ve 036'da
-- satır içi yazıldığı için adlarını Postgres üretti; ada güvenmek yerine
-- TANIMDAN bulunuyor. Yeniden çalıştırılabilir: kendi koyduğunu da bulup
-- yeniler.
do $do$
declare
  t text;
  c text;
begin
  foreach t in array array['kamera_cihazlari', 'kamera_eslestirme', 'istisnalar'] loop
    for c in
      select con.conname::text
        from pg_constraint con
       where con.conrelid = ('public.' || t)::regclass
         and con.contype = 'c'
         and pg_get_constraintdef(con.oid) like '%yon%GIRIS%'
    loop
      execute format('alter table public.%I drop constraint %I', t, c);
    end loop;
    execute format(
      'alter table public.%I add constraint %I '
      || 'check (yon in (''GIRIS'',''CIKIS'',''ORTAK''))',
      t, t || '_yon_ck');
  end loop;
end
$do$;

-- Giriş süresi 3'ün ALTINA İNEMEZ. Köprü, fotoğrafını gönderdiği araç hâlâ
-- oradayken kadrajda bir şey kıpırdayıp yeniden durulursa (önünden geçen biri,
-- biraz ilerleyen araç) aynı aracı YENİDEN gönderir. Kapıda bir-iki dakika
-- oyalanan, az önce girmiş araç bu süreden kısa bir ayarda "çıkıyor" diye
-- işaretlenirdi.
alter table public.otopark_ayarlari
  add column if not exists tek_kapi_giris_yoksay_dk integer not null default 3
    constraint otopark_ayarlari_tek_kapi_giris_ck
      check (tek_kapi_giris_yoksay_dk between 3 and 60),
  add column if not exists tek_kapi_cikis_yoksay_dk integer not null default 5
    constraint otopark_ayarlari_tek_kapi_cikis_ck
      check (tek_kapi_cikis_yoksay_dk between 1 and 60);

-- ------------------------------------------------------- bir karakter fark --

-- Düzenleme uzaklığı TAM 1: tek karakter değişmiş, ya da tek karakter düşmüş
-- / eklenmiş. Eklenti yok — fuzzystrmatch Supabase'de `extensions` şemasında
-- ve aşağıdaki fonksiyon search_path = public'e sabitli.
--
-- Beş karakterden kısa plakada kural ÇALIŞMAZ: dört karakterde bir fark
-- plakanın dörtte biridir ve "yakın" demek, ilgisiz iki aracı eşleştirirdi.
create or replace function public.plaka_yakin(a text, b text)
returns boolean
language sql immutable as $fn$
  select case
    when a is null or b is null then false
    when length(a) < 5 or length(b) < 5 then false
    when a = b then false
    when length(a) = length(b) then
      (select count(*)
         from generate_series(1, length(a)) as i
        where substr(a, i, 1) <> substr(b, i, 1)) = 1
    when abs(length(a) - length(b)) = 1 then
      exists (
        select 1
          from generate_series(1, greatest(length(a), length(b))) as i
         where overlay(case when length(a) > length(b) then a else b end
                       placing '' from i for 1)
               = case when length(a) > length(b) then b else a end)
    else false
  end
$fn$;

-- ----------------------------------------------------------- tek kapı -----

-- Tek kapıdaki kameranın TEK giriş noktası. Şerit yönü söylemediği için karar
-- bilet durumundan verilir; emin olunamayan olay tahmin edilmez.
--
-- Kendi başına hiçbir şey yazmaz: ya bilet_ac'ı, ya kamera_cikis_bildir'i
-- çağırır, ya istisna_yaz ile insana bırakır, ya da yok sayar. Kameranın
-- yapabildikleri bu yüzden 036'daki ile AYNI — bilet kapatmak ve para almak
-- yine yok.
--
-- Bütün süreler SUNUCU saatiyledir (created_at, cikis_at, iptal_at hepsi
-- now()). Köprü bilgisayarının saati dakikalarca kaymış olabilir; onunla
-- "az önce" hesabı yapmak, kararı o kaymaya bağlardı.
--
-- is_staff() guard'ı YOK ve olamaz (webhook'ta auth.uid() null). Tersi var:
-- JWT taşıyan çağıran reddedilir. Asıl sınır yine grant'tır.
create or replace function public.kamera_tek_kapi(
  p_plaka    text,
  p_islem_id uuid,
  p_zaman    timestamptz,
  p_foto     text default null,
  p_ham      jsonb default null
) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_plaka    text;
  v_giris_dk integer;
  v_cikis_dk integer;
  v_b        public.biletler;
  v_id       uuid;
  v_adaylar  uuid[];
  v_yeni     boolean;
begin
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;
  if p_zaman is null then
    raise exception 'Kamera kaydı zaman damgası olmadan kabul edilmez.';
  end if;

  v_plaka := public.normalize_plaka(p_plaka);
  if v_plaka is null or v_plaka !~ '^[A-Z0-9]{2,15}$' then
    raise exception 'Geçersiz plaka: %', coalesce(p_plaka, '(boş)');
  end if;

  -- Oku-karar ver-yaz, birden çok ifadede: iki olay aynı anda gelirse ikisi
  -- de "bilet yok" okuyup ikisi de giriş açmaya kalkmasın. bilet_ac kendi
  -- kilidini (bilet_ac_yer) BUNDAN SONRA alır ve kimse ikisini ters sırada
  -- almaz, dolayısıyla kilitlenme olmaz.
  perform pg_advisory_xact_lock(hashtext('kamera_tek_kapi'));

  -- 0. Tekrar oynatma. Köprü cevabı göremediyse aynı islem_id ile yeniden
  --    dener; ilk seferde açılan bilet "az önce giren araç" diye yok
  --    sayılmamalı, aynı cevap dönmeli.
  select b.id into v_id from public.biletler b where b.islem_id = p_islem_id;
  if v_id is not null then
    return jsonb_build_object('karar', 'GIRIS', 'bilet_id', v_id, 'sebep', 'TEKRAR');
  end if;
  if exists (select 1 from public.istisnalar i where i.islem_id = p_islem_id) then
    return jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'TEKRAR');
  end if;

  select o.tek_kapi_giris_yoksay_dk, o.tek_kapi_cikis_yoksay_dk
    into v_giris_dk, v_cikis_dk
    from public.otopark_ayarlari o where o.id = 1;
  v_giris_dk := coalesce(v_giris_dk, 3);
  v_cikis_dk := coalesce(v_cikis_dk, 5);

  -- 1. Bu plakanın AÇIK bileti var.
  select * into v_b from public.biletler b
   where b.durum = 'ACIK' and b.plaka = v_plaka;
  if found then
    -- 1a. Az önce açıldı: araç hâlâ kameranın önünde.
    if v_b.created_at > now() - make_interval(mins => v_giris_dk) then
      return jsonb_build_object('karar', 'YOKSAY', 'bilet_id', v_b.id, 'sebep', 'YENI_GIRIS');
    end if;
    -- 1b. İçerideydi, şimdi kapıda: yalnızca "kapıda" damgası.
    v_id := public.kamera_cikis_bildir(v_plaka, p_islem_id, p_zaman, p_foto, p_ham);
    if v_id is null then
      -- Saati bayat ya da ileri tarihli; kamera_cikis_bildir kaydını yazdı.
      return jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'ZAMAN');
    end if;
    return jsonb_build_object('karar', 'CIKIS', 'bilet_id', v_id, 'sebep', 'ACIK_BILET');
  end if;

  -- 2. Bu plakanın bileti az önce kapandı: ödeyip çıkan araç. Bu modun var
  --    olma sebebi bu satır — onsuz çıkan araca yeniden bilet açılırdı.
  --    coalesce sırası bilerek: kapanmış bir bilet sonradan iptal edilirse
  --    aracın çıktığı an cikis_at'tir, iptalin yapıldığı an değil.
  if exists (
    select 1 from public.biletler b
     where b.plaka = v_plaka and b.durum in ('KAPALI', 'IPTAL')
       and coalesce(b.cikis_at, b.iptal_at) > now() - make_interval(mins => v_cikis_dk)
  ) then
    return jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null, 'sebep', 'YENI_CIKIS');
  end if;

  -- 3. Tam eşleşme yok ama içerideki bir araca BİR KARAKTER uzak.
  select array_agg(b.id order by b.created_at),
         bool_or(b.created_at > now() - make_interval(mins => v_giris_dk))
    into v_adaylar, v_yeni
    from public.biletler b
   where b.durum = 'ACIK' and public.plaka_yakin(b.plaka, v_plaka);

  if v_adaylar is not null then
    -- 3a. Benzeri az önce girdi: aynı aracın ikinci, farklı okunmuş karesi.
    if v_yeni then
      return jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null,
                                'sebep', 'YENI_GIRIS_BENZER');
    end if;
    -- 3b. Çıkan aracın yanlış okunması da olabilir, benzer plakalı yeni bir
    --     araç da. İkisi de makul; hangisi olduğuna insan karar verir.
    perform public.istisna_yaz('YON_BELIRSIZ', 'ORTAK', v_plaka, 'KAMERA', p_islem_id,
                               p_ham, p_foto, p_zaman, v_adaylar);
    return jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'BENZER_ACIK');
  end if;

  -- 4. Az önce kapanan bir bilete bir karakter uzak: ödeyip çıkan araç,
  --    çıkarken yanlış okunmuş. Bilet açmak hayalet bilet olurdu. İç sorgu
  --    `offset 0` ile ayrı tutuluyor ki önce zaman süzülsün, plaka_yakin
  --    yalnızca son birkaç dakikanın satırlarında çalışsın.
  if exists (
    select 1
      from (select b.plaka from public.biletler b
             where b.durum in ('KAPALI', 'IPTAL')
               and coalesce(b.cikis_at, b.iptal_at) > now() - make_interval(mins => v_cikis_dk)
            offset 0) y
     where public.plaka_yakin(y.plaka, v_plaka)
  ) then
    return jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null,
                              'sebep', 'YENI_CIKIS_BENZER');
  end if;

  -- 5. Hiçbiri değil: yeni gelen araç.
  v_id := public.bilet_ac(v_plaka, p_islem_id, 'KAMERA', p_zaman, p_foto, null, p_ham);
  if v_id is null then
    -- Saati bayat ya da ileri tarihli; bilet_ac kaydını yazdı.
    return jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'ZAMAN');
  end if;
  return jsonb_build_object('karar', 'GIRIS', 'bilet_id', v_id, 'sebep', 'YENI_ARAC');
end
$fn$;

-- ----------------------------------------------------------------- kod ----

-- Gövde 036'dan BİREBİR; yalnızca şerit kontrolü ve mesajı değişti. İmza aynı
-- olduğu için create or replace ACL'i koruyor (doğrulama aşağıda kanıtlıyor).
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
  if v_yon not in ('GIRIS','CIKIS','ORTAK') then
    raise exception 'Şerit GIRIS, CIKIS ya da ORTAK olmalı.';
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

-- ------------------------------------------------------------- nöbetçi ----

-- Gövde 036'dan BİREBİR (en son tanım odur); yalnızca cihaz uyarısındaki
-- `case` değişti: tek kapı kamerası ölünce HEM girişler HEM çıkışlar durur,
-- "Girişler" demek yarısını saklamak olurdu.
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
        || '. ' || case v_c.yon
                     when 'CIKIS' then 'Çıkışlar'
                     when 'ORTAK' then 'Girişler ve çıkışlar'
                     else 'Girişler'
                   end
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

-- from public OLMADAN hiçbir şey kapanmaz (012); service_role OLMADAN da (033).
revoke all on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb) from public;
revoke all on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)
  from anon, authenticated, service_role;
grant execute on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)
  to service_role;

-- Yalnızca kamera_tek_kapi'nin içinden çağrılır (SECURITY DEFINER sahibi
-- yetkisini grant'tan bağımsız korur).
revoke all on function public.plaka_yakin(text, text) from public;
revoke all on function public.plaka_yakin(text, text) from anon, authenticated, service_role;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
  t text;
begin
  -- Üç kısıt da üçüncü şeridi tanıyor mu — ve eski, dar kısıt gerçekten gitti mi.
  foreach t in array array['kamera_cihazlari', 'kamera_eslestirme', 'istisnalar'] loop
    if (select count(*) from pg_constraint con
         where con.conrelid = ('public.' || t)::regclass and con.contype = 'c'
           and pg_get_constraintdef(con.oid) like '%yon%GIRIS%') <> 1 then
      raise exception '037: %.yon üzerinde tam olarak bir kısıt olmalı', t;
    end if;
    if not exists (select 1 from pg_constraint con
                    where con.conrelid = ('public.' || t)::regclass and con.contype = 'c'
                      and pg_get_constraintdef(con.oid) like '%yon%ORTAK%') then
      raise exception '037: %.yon kısıtı ORTAK şeridini tanımıyor', t;
    end if;
  end loop;

  -- Enum değeri KATALOGDAN okunur (019): bu transaction'da değerin kendisini
  -- üretmek 55P04 verir.
  if not exists (
    select 1 from pg_enum e
      join pg_type ty on ty.oid = e.enumtypid
     where ty.typname = 'istisna_tur' and e.enumlabel = 'YON_BELIRSIZ'
  ) then
    raise exception '037: YON_BELIRSIZ enum değeri eklenmedi';
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'otopark_ayarlari'
                    and column_name = 'tek_kapi_giris_yoksay_dk')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'otopark_ayarlari'
                       and column_name = 'tek_kapi_cikis_yoksay_dk') then
    raise exception '037: tek kapı süre kolonları eklenmedi';
  end if;

  -- Bilet açabilen fonksiyon: yalnızca webhook.
  if not has_function_privilege('service_role',
       'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)', 'execute') then
    raise exception '037: kamera_tek_kapi service_role rolüne kapalı — tek kapı çalışmaz';
  end if;
  foreach r in array array['anon', 'authenticated'] loop
    if has_function_privilege(r,
         'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)', 'execute') then
      raise exception '037: kamera_tek_kapi istemciye açık (%)', r;
    end if;
  end loop;

  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(r, 'public.plaka_yakin(text, text)', 'execute') then
      raise exception '037: plaka_yakin % rolüne açık', r;
    end if;
    -- create or replace ACL'i korur; bu satırlar onu kanıtlıyor.
    if has_function_privilege(r, 'public.run_kamera_kontrol()', 'execute') then
      raise exception '037: run_kamera_kontrol % rolüne açıldı', r;
    end if;
  end loop;

  if not has_function_privilege('authenticated',
       'public.kamera_kod_uret(text, text)', 'execute') then
    raise exception '037: kamera_kod_uret authenticated rolüne kapalı kalmış';
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, 'public.kamera_kod_uret(text, text)', 'execute') then
      raise exception '037: kamera_kod_uret istemci dışı % rolüne açık', r;
    end if;
  end loop;

  -- Webhook'un kullandığı iki eski kapı yerinde durmalı: kamera_tek_kapi
  -- onları sahibinin yetkisiyle çağırır, ama iki şeritli kurulumlar
  -- doğrudan çağırmaya devam ediyor.
  if not has_function_privilege('service_role',
       'public.kamera_cikis_bildir(text, uuid, timestamptz, text, jsonb)', 'execute') then
    raise exception '037: kamera_cikis_bildir service_role rolüne kapanmış';
  end if;
end
$do$;

commit;
