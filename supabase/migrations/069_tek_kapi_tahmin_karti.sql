-- ============================================================================
-- 069  Tek kapı: tahmin kartı, aracı sonra emin okunup işlenince kapanır
-- ============================================================================

begin;

-- Sahada 17.11 (35 CJE 033): köprü aynı aracın kenardaki bir parçasını emin
-- olmadan okudu ve tahminle OKUNAMADI kartı yazdırdı; az sonra aracı emin
-- okudu. Köprü 1.4.3'te tahmin emin plakayı artık 60 sn engellemez (yalnızca
-- emin plaka engeller), emin okuma bileti açar ya da kapatır — ama tahmin
-- kartı AÇIK kalır ve personel onu ayrıca kapatmak zorunda kalır.
--
-- Kural (sahibin onayladığı plan, 2026-11-17): kamera_tek_kapi'nin kararı
-- GIRIS ya da CIKIS ise (bilet açıldı ya da kapandı), şu tahmin kartları
-- sistemce kapanır — 041'in notuyla, cozuldu_by BOŞ (bunu insan yapmadı):
--   · tür OKUNAMADI, tek kapı (ORTAK), kaynak KAMERA, çözülmemiş;
--   · plakasız (041'de plakayı sonradan almış kart insan bekler: dokunulmaz);
--   · ham_yanit.tahmin bu plakayla BİREBİR aynı (bir karakter uzak tahmin
--     başka bir araç olabilir: dokunulmaz);
--   · kartın saati bu olaydan en çok giriş süresi (Ayarlar → Tek kapı →
--     Girişten sonra) uzakta: aynı geçiş. Daha eskisi başka ziyarettir.
-- 045'in bildirimi 3 dk bekler ve kapanmış kart için gitmez: bu kartlar için
-- kimse uyarılmaz.
--
-- İkinci ek (1c, sahibin kararı 17.11): köprü 1.4.3 tek kapıda yönü
-- bilinmeyen olayın EMİN plakasını kart yerine plaka olarak gönderir ve
-- gövdeye `yon_bilinmiyor: true` yazar. Bu olay bilet açar ya da kapatırsa
-- denetim kaydına `kamera_yon_bilinmiyor` (bilet, karar) yazılır — karne bunu
-- sayar. Kararı DEĞİŞTİRMEZ. PASS 87 (f) sınar.
--
-- İmza ve gövde 056'dan BİREBİR; tek ek sondaki "069" bloğu. Aynı imza →
-- create or replace grant'ları korur (yalnızca service_role); doğrulama
-- aşağıda yine de sınar. PASS 87 sınar.

-- ----------------------------------------------------------- tek kapı -----

create or replace function public.kamera_tek_kapi(
  p_plaka    text,
  p_islem_id uuid,
  p_zaman    timestamptz,
  p_foto     text default null,
  p_ham      jsonb default null,
  p_hareket  text default null      -- 056: köprünün gördüğü yön (ipucu)
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
  -- 056
  v_hareket   text;
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

  -- 056: tanınan üç değerden biri değilse ipucu YOK sayılır (048'in kararı).
  v_hareket := case when p_hareket in ('GIRDI', 'CIKTI', 'ICERIDE') then p_hareket end;

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
    -- 056 — İ. Köprü aracı otoparkın İÇİNDE gezerken gördü (giriş de çıkış da
    --    değil). Hiçbir koşulda bilet açılmaz ya da kapatılmaz; yalnızca
    --    bileti olmayan araç insana bildirilir.
    if v_hareket = 'ICERIDE' then
      -- Açık bileti var: içerideki biletli araç — hiçbir şey.
      if exists (select 1 from public.biletler b
                  where b.durum = 'ACIK' and b.plaka = v_plaka) then
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null, 'sebep', 'ICERIDE_ACIK');
        exit karar;
      end if;
      -- Bir karakter uzak plakalı açık bilet: aynı aracın yanlış okunması.
      if exists (select 1 from public.biletler b
                  where b.durum = 'ACIK' and public.plaka_yakin(b.plaka, v_plaka)) then
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null, 'sebep', 'ICERIDE_BENZER');
        exit karar;
      end if;
      -- Bileti az önce kapandı (adım 2'nin penceresi): ödeyip çıkmak üzere.
      if exists (
        select 1 from public.biletler b
         where b.plaka = v_plaka and b.durum in ('KAPALI', 'IPTAL')
           and p_zaman <= coalesce(b.cikis_at, b.iptal_at) + make_interval(mins => v_cikis_dk)
           and p_zaman >= least(b.kaynak_zaman, b.created_at) - make_interval(mins => v_giris_dk)
      ) then
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null, 'sebep', 'YENI_CIKIS');
        exit karar;
      end if;
      -- Az önce kapanan bir bilete BİR KARAKTER uzak: ödeyip çıkan aracın
      -- yanlış okunması (adım 4'ün sorgusu, aynı pencere).
      if exists (
        select 1
          from (select b.plaka from public.biletler b
                 where b.durum in ('KAPALI', 'IPTAL')
                   and p_zaman <= coalesce(b.cikis_at, b.iptal_at) + make_interval(mins => v_cikis_dk)
                   and p_zaman >= least(b.kaynak_zaman, b.created_at) - make_interval(mins => v_giris_dk)
                offset 0) y
         where public.plaka_yakin(y.plaka, v_plaka)
      ) then
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null,
                                      'sebep', 'YENI_CIKIS_BENZER');
        exit karar;
      end if;
      -- Bu plaka için çözülmemiş bir "içeride bileti yok" kaydı zaten var:
      -- aynı aracın yeniden görülmesi — ikinci kart ve ikinci bildirim yok.
      if exists (select 1 from public.istisnalar i
                  where i.plaka = v_plaka and i.tur::text = 'ICERIDE_BILETSIZ'
                    and i.cozuldu_at is null) then
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null, 'sebep', 'ICERIDE_KAYITLI');
        exit karar;
      end if;
      -- İçeride, bileti yok: insana.
      perform public.istisna_yaz('ICERIDE_BILETSIZ', 'ORTAK', v_plaka, 'KAMERA', p_islem_id,
                                 p_ham, p_foto, p_zaman);
      v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'ICERIDE_BILETSIZ');
      exit karar;
    end if;

    -- 1. Bu plakanın AÇIK bileti var.
    select * into v_b from public.biletler b
     where b.durum = 'ACIK' and b.plaka = v_plaka;
    if found then
      -- 1a. Olay ziyaretin başından en çok giriş süresi sonra (ya da ÖNCE):
      --     araç hâlâ kameranın önünde / aynı ziyaretin geç gelen girişi. 048
      if p_zaman <= least(v_b.kaynak_zaman, v_b.created_at)
                    + make_interval(mins => v_giris_dk) then
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', v_b.id, 'sebep', 'YENI_GIRIS');
        exit karar;
      end if;
      -- 056: köprü aracı GİRERKEN gördü ama eski açık bileti var — bugünkü
      --      kural onu çıkış sayıp kapatırdı. Bilet KAPANMAZ; insana.
      if v_hareket = 'GIRDI' then
        perform public.istisna_yaz('GIRISTE_ACIK_BILET', 'ORTAK', v_plaka, 'KAMERA', p_islem_id,
                                   p_ham, p_foto, p_zaman, array[v_b.id]);
        v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'GIRIS_ACIK_BILET');
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
    --    048: olay o ziyaretin içinde (başından giriş süresi önceden kapanışından
    --    çıkış süresi sonrasına kadar) ise aynı ziyarettir.
    if exists (
      select 1 from public.biletler b
       where b.plaka = v_plaka and b.durum in ('KAPALI', 'IPTAL')
         and p_zaman <= coalesce(b.cikis_at, b.iptal_at) + make_interval(mins => v_cikis_dk)
         and p_zaman >= least(b.kaynak_zaman, b.created_at) - make_interval(mins => v_giris_dk)
    ) then
      v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null, 'sebep', 'YENI_CIKIS');
      exit karar;
    end if;

    -- 3. Tam eşleşme yok ama içerideki bir araca BİR KARAKTER uzak.
    select array_agg(b.id order by b.created_at),
           bool_or(p_zaman <= least(b.kaynak_zaman, b.created_at)
                              + make_interval(mins => v_giris_dk))   -- 048
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
    --    yalnızca olayın çevresindeki birkaç dakikanın satırlarında çalışsın.
    --    048: pencere adım 2'deki gibi olayın saatine göre.
    if exists (
      select 1
        from (select b.plaka from public.biletler b
               where b.durum in ('KAPALI', 'IPTAL')
                 and p_zaman <= coalesce(b.cikis_at, b.iptal_at) + make_interval(mins => v_cikis_dk)
                 and p_zaman >= least(b.kaynak_zaman, b.created_at) - make_interval(mins => v_giris_dk)
              offset 0) y
       where public.plaka_yakin(y.plaka, v_plaka)
    ) then
      v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null,
                                    'sebep', 'YENI_CIKIS_BENZER');
      exit karar;
    end if;

    -- 056: köprü aracı ÇIKARKEN gördü ve açık bileti yok — bugünkü kural ona
    --      HAYALET giriş açardı (sahada 11.11 11:35 / 13:46). Bilet açılmaz;
    --      mevcut ACIK_BILET_YOK türüyle insana.
    if v_hareket = 'CIKTI' then
      perform public.istisna_yaz('ACIK_BILET_YOK', 'ORTAK', v_plaka, 'KAMERA', p_islem_id,
                                 p_ham, p_foto, p_zaman);
      v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'CIKIS_BILETSIZ');
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

  -- 069: Bilet açıldı ya da kapandı: aynı aracın az önceki tahmin kartı da
  --    işlendi. Kapanış koşulları yukarıdaki başlıkta; `cozuldu_at is null`
  --    kilit altında olsak da bir insanın kararını asla ezmesin diye.
  if v_sonuc ->> 'karar' in ('GIRIS', 'CIKIS') then
    update public.istisnalar i
       set cozuldu_at = now(),
           cozum_notu = 'Kamera yeniden denedi ve okudu: ' || v_plaka || ' → '
             || (v_sonuc ->> 'karar') || ' (' || (v_sonuc ->> 'sebep') || ')'
     where i.tur::text = 'OKUNAMADI'
       and i.yon = 'ORTAK'
       and i.kaynak = 'KAMERA'
       and i.cozuldu_at is null
       and i.plaka is null
       and public.normalize_plaka(i.ham_yanit ->> 'tahmin') = v_plaka
       and i.kaynak_zaman between p_zaman - make_interval(mins => v_giris_dk)
                              and p_zaman + make_interval(mins => v_giris_dk);
  end if;

  -- 069 (1c): yönü bilinmeden gönderilen emin plaka bilet açtı / kapattı.
  if v_sonuc ->> 'karar' in ('GIRIS', 'CIKIS')
     and jsonb_typeof(p_ham) = 'object' and p_ham -> 'yon_bilinmiyor' = 'true'::jsonb then
    perform public.audit('kamera_yon_bilinmiyor', 'biletler', (v_sonuc ->> 'bilet_id')::uuid,
                         jsonb_build_object('karar', v_sonuc ->> 'karar',
                                            'sebep', v_sonuc ->> 'sebep'));
  end if;

  return v_sonuc;
end
$fn$;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  f constant text := 'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)';
  r text;
begin
  if (select count(*) from pg_proc
       where proname = 'kamera_tek_kapi'
         and pronamespace = 'public'::regnamespace) <> 1 then
    raise exception '069: kamera_tek_kapi tek tanım değil';
  end if;
  if not exists (select 1 from pg_proc where oid = f::regprocedure
                  and prosecdef and proconfig @> array['search_path=public']) then
    raise exception '069: kamera_tek_kapi SECURITY DEFINER + search_path=public değil';
  end if;
  if position('069: Bilet açıldı' in pg_get_functiondef(f::regprocedure)) = 0
     or position('kamera_yon_bilinmiyor' in pg_get_functiondef(f::regprocedure)) = 0 then
    raise exception '069: kamera_tek_kapi yeni gövdede değil';
  end if;
  foreach r in array array['anon', 'authenticated'] loop
    if has_function_privilege(r, f, 'execute') then
      raise exception '069: kamera_tek_kapi % rolüne açık', r;
    end if;
  end loop;
  if not has_function_privilege('service_role', f, 'execute') then
    raise exception '069: kamera_tek_kapi service_role''e kapalı (webhook çağıramaz)';
  end if;
end
$do$;

commit;
