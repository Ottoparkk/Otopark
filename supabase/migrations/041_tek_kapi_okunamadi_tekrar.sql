-- ============================================================================
-- 041  Tek kapı: kaybolan 422'den sonraki yeniden deneme aracı yine işler
-- ============================================================================

begin;

-- Model fotoğrafta aracı gördü ama plakasını okuyamadı: webhook OKUNAMADI
-- kaydını İLK denemede yazar ve 422 döner (039). 039'un yorumu "köprü 422'yi
-- YENİDEN DENEMEZ, bu çağrı bir olay için bir kez gelir" diyor — ALDIĞI
-- 422'yi denemez, doğru; ama cevap köprüye hiç ulaşmazsa (okuma köprünün
-- 30 sn'sini aştı — okuma çağrısında zaman aşımı yok, sınırdaki okuma ikinci
-- görüşü de çalıştırır — ya da Wi-Fi koptu) köprü bir ağ hatası görür ve
-- AYNI islem_id ile yeniden dener. Sınırdaki okumalar tam da ikinci seferde
-- okunanlardır. 037'deki kamera_tek_kapi o islem_id'de kayıt görünce
-- "ISTISNA TEKRAR" diye kısa kesiyordu: kameranın OKUDUĞU araç için ne giriş
-- ne çıkış yazılıyordu, personel onu elle işlemek zorundaydı.
--
-- İşletme sahibinin kararı (2026-10-28): yalnızca tek kapı (ORTAK); yeniden
-- deneme aracı işlerse önceki OKUNAMADI kaydı kendiliğinden kapanır
-- (cozuldu_by boş = sistem), insan gerektirirse açık kalır ve okunan plakayı
-- taşır. 039
-- değiştirilmedi (uygulanmış migration'a dokunulmaz); yanlış yorumun
-- düzeltmesi burasıdır. Enum değişmiyor: 'OKUNAMADI' 039'da commit edildi ve
-- burada yalnızca plpgsql gövdelerinde geçiyor.

-- ----------------------------------------------------------- tek kapı -----

-- Gövde 037'den BİREBİR; yalnızca üç yer değişti:
--   · 0. adım: çözülmemiş bir OKUNAMADI kaydı kararı ENGELLEMEZ, kimliği
--     tutulur ve karar verilir. İnsanın çözdüğü OKUNAMADI ve olayın başka
--     türden kendi kaydı eskisi gibi "ISTISNA TEKRAR".
--   · 1-5. adımlar etiketli bir bloğun içinde: her `return X` artık
--     `v_sonuc := X; exit karar;` — mantık aynı, yalnızca karardan sonra
--     kayda bakabilmek için.
--   · Bloktan sonra o kayıt kapatılır ya da plakayla zenginleştirilir.
-- Kayıt güncellemesi de mevcut danışma kilidinin altındadır. İçerideki
-- istisna_yaz çağrıları (YON_BELIRSIZ, BAYAT, GELECEK) islem_id'nin tekil
-- indeksine çarpar, hiçbir şey yazmaz ve bildirim göndermez: olay başına yine
-- tek kayıt, tek bildirim.
-- İmza aynı olduğu için create or replace ACL'i koruyor (doğrulama aşağıda).
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
  -- 041
  v_okunamadi uuid;
  v_sonuc     jsonb;
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
  -- 041: İlk deneme plakayı okuyamadıysa (039) kaydı bu olayın kimliğini
  --    taşır, ama o kayıt bir KARAR değildir — "okuyamadım" demektir. Bu
  --    deneme okuduysa karar verilir; kayıt aşağıda kapanır ya da plakayı
  --    alır. Yalnızca ÇÖZÜLMEMİŞ ve tek kapıya ait OKUNAMADI: bir insan onu
  --    çözdüyse karar onundur; başka türden kayıt bu olayın kendi kararıdır.
  select i.id into v_okunamadi from public.istisnalar i
   where i.islem_id = p_islem_id and i.tur = 'OKUNAMADI'
     and i.yon = 'ORTAK' and i.cozuldu_at is null;
  if v_okunamadi is null
     and exists (select 1 from public.istisnalar i where i.islem_id = p_islem_id) then
    return jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'TEKRAR');
  end if;

  select o.tek_kapi_giris_yoksay_dk, o.tek_kapi_cikis_yoksay_dk
    into v_giris_dk, v_cikis_dk
    from public.otopark_ayarlari o where o.id = 1;
  v_giris_dk := coalesce(v_giris_dk, 3);
  v_cikis_dk := coalesce(v_cikis_dk, 5);

  <<karar>>
  begin
    -- 1. Bu plakanın AÇIK bileti var.
    select * into v_b from public.biletler b
     where b.durum = 'ACIK' and b.plaka = v_plaka;
    if found then
      -- 1a. Az önce açıldı: araç hâlâ kameranın önünde.
      if v_b.created_at > now() - make_interval(mins => v_giris_dk) then
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', v_b.id, 'sebep', 'YENI_GIRIS');
        exit karar;
      end if;
      -- 1b. İçerideydi, şimdi kapıda: yalnızca "kapıda" damgası.
      v_id := public.kamera_cikis_bildir(v_plaka, p_islem_id, p_zaman, p_foto, p_ham);
      if v_id is null then
        -- Saati bayat ya da ileri tarihli; kamera_cikis_bildir kaydını yazdı.
        v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'ZAMAN');
        exit karar;
      end if;
      v_sonuc := jsonb_build_object('karar', 'CIKIS', 'bilet_id', v_id, 'sebep', 'ACIK_BILET');
      exit karar;
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
      v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null, 'sebep', 'YENI_CIKIS');
      exit karar;
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
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null,
                                      'sebep', 'YENI_GIRIS_BENZER');
        exit karar;
      end if;
      -- 3b. Çıkan aracın yanlış okunması da olabilir, benzer plakalı yeni bir
      --     araç da. İkisi de makul; hangisi olduğuna insan karar verir.
      perform public.istisna_yaz('YON_BELIRSIZ', 'ORTAK', v_plaka, 'KAMERA', p_islem_id,
                                 p_ham, p_foto, p_zaman, v_adaylar);
      v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'BENZER_ACIK');
      exit karar;
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
      v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null,
                                    'sebep', 'YENI_CIKIS_BENZER');
      exit karar;
    end if;

    -- 5. Hiçbiri değil: yeni gelen araç.
    v_id := public.bilet_ac(v_plaka, p_islem_id, 'KAMERA', p_zaman, p_foto, null, p_ham);
    if v_id is null then
      -- Saati bayat ya da ileri tarihli; bilet_ac kaydını yazdı.
      v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'ZAMAN');
      exit karar;
    end if;
    v_sonuc := jsonb_build_object('karar', 'GIRIS', 'bilet_id', v_id, 'sebep', 'YENI_ARAC');
  end karar;

  -- 041: Önceki "okunamadı" kaydı. Karar insan gerektirmiyorsa (giriş, çıkış,
  --    yok sayma) araç işlendi: kayıt sistemce kapanır — cozuldu_by BOŞ
  --    kalır (bunu bir insan yapmadı; ekran yalnızca cozuldu_at'e ve nota
  --    bakar), notta okunan plaka ve karar durur. Karar yine insanınsa
  --    (benzer plaka, bayat saat) kayıt AÇIK kalır ve okunan plakayı alır:
  --    personel "plaka okunamadı" yerine plakayı görür. İkinci kayıt yok
  --    (yukarıdaki istisna_yaz tekil indekse çarptı), ikinci bildirim yok.
  --    `cozuldu_at is null` koşulu iki koldan da: kilit altında olsak da
  --    bir insanın kararını asla ezmesin.
  if v_okunamadi is not null then
    if v_sonuc ->> 'karar' = 'ISTISNA' then
      update public.istisnalar
         set plaka = coalesce(plaka, v_plaka),
             ham_yanit = coalesce(ham_yanit, '{}'::jsonb)
               || jsonb_build_object('sonradan_okunan', v_plaka,
                                     'sonradan_sebep', v_sonuc ->> 'sebep')
       where id = v_okunamadi and cozuldu_at is null;
    else
      update public.istisnalar
         set cozuldu_at = now(),
             cozum_notu = 'Kamera yeniden denedi ve okudu: ' || v_plaka || ' → '
               || (v_sonuc ->> 'karar') || ' (' || (v_sonuc ->> 'sebep') || ')'
       where id = v_okunamadi and cozuldu_at is null;
    end if;
  end if;

  return v_sonuc;
end
$fn$;

-- ----------------------------------------------------------- okunamadı ----

-- Gövde 039'dan BİREBİR; yalnızca argüman kontrollerinden sonra iki satır
-- eklendi. Ters sıra: yavaş ilk istek hâlâ okurken yeniden deneme plakayı
-- okudu ve bileti AÇTI; ilk istek sonra "okunamadı" ile biter. Bu olayın
-- bileti zaten varsa kayıt yazılmaz — yazılsaydı bileti olan bir araç için
-- açık kayıt ve bildirim kalırdı (personel tahminle elle ikinci bir bilet
-- açabilirdi). Kontrol şeritten bağımsız ve zararsız; kilit yalnızca tek
-- kapıda: kamera_tek_kapi ile AYNI anahtar, yani iki istek tam aynı anda
-- gelse de biri öbürünün sonucunu görür (bilet → kayıt yazılmaz; kayıt →
-- karar onu kapatır). Kilit sırası tek yönlü: burada yalnızca bu kilit
-- alınır, bilet_ac_yer hiç alınmaz — kilitlenme olmaz.
create or replace function public.kamera_okunamadi(
  p_yon      text,
  p_islem_id uuid,
  p_zaman    timestamptz,
  p_tahmin   text    default null,
  p_guven    numeric default null,
  p_ham      jsonb   default null
) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_yon text := upper(btrim(coalesce(p_yon, '')));
  v_ham jsonb;
begin
  -- is_staff() guard'ı YOK ve olamaz (webhook'ta auth.uid() null). Tersi var:
  -- JWT taşıyan çağıran reddedilir. Asıl sınır grant'tır (037 deseni).
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.';
  end if;
  if v_yon not in ('GIRIS', 'ORTAK') then
    raise exception 'Okunamayan plaka kaydı yalnızca giriş ve tek kapı şeridinde yazılır.';
  end if;
  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;
  if p_zaman is null then
    raise exception 'Kamera kaydı zaman damgası olmadan kabul edilmez.';
  end if;

  -- 041
  if v_yon = 'ORTAK' then
    perform pg_advisory_xact_lock(hashtext('kamera_tek_kapi'));
  end if;
  if exists (select 1 from public.biletler b where b.islem_id = p_islem_id) then
    return null;
  end if;

  v_ham := case when jsonb_typeof(p_ham) = 'object'
                then p_ham - 'foto_base64' else '{}'::jsonb end
        || jsonb_build_object('tahmin', left(nullif(btrim(p_tahmin), ''), 32),
                              'guven', p_guven);

  return public.istisna_yaz('OKUNAMADI', v_yon, null, 'KAMERA', p_islem_id,
                            v_ham, null, p_zaman);
end
$fn$;

-- ---------------------------------------------------------- doğrulama -----

-- create or replace ACL'i korur (037/039 deseni); bu blok onu kanıtlıyor.
-- İkisi de yalnızca webhook'a (service_role) açık olmalı: kamera_tek_kapi
-- bilet açar ve artık kayıt kapatır, kamera_okunamadi kayıt ve bildirim
-- üretir.
do $do$
declare
  f text;
  r text;
begin
  foreach f in array array[
    'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)',
    'public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)'
  ] loop
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception '041: % service_role rolüne kapalı — webhook çağıramaz', f;
    end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception '041: % % rolüne açık', f, r;
      end if;
    end loop;
  end loop;

  if (select count(*) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('kamera_tek_kapi', 'kamera_okunamadi')
         and p.prosecdef
         and p.proconfig @> array['search_path=public']) <> 2 then
    raise exception '041: fonksiyonlar SECURITY DEFINER + search_path=public değil';
  end if;
end
$do$;

commit;
