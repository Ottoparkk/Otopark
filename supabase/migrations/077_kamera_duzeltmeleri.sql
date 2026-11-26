-- ============================================================================
-- 077  Tek kapı kamera düzeltmeleri: çıkış tahmini, içeride okunan giriş kartı, aynı iz dönüşü, içeride görüldü saati
-- ============================================================================
begin;

-- 24.11 teşhisinde (105 çözülmemiş kamera kartı) sahibin seçtiği düzeltmelerin
-- sunucu yarısı (2026-11-24/25). Köprü yarısı 1.4.6'da; eski köprüyle de
-- çalışır (yeni alanlar yoksa her şey 076'daki gibi).
--
-- D  "yalnızca benzeri yoksa": köprü kapıdan ÇIKTI diye izlediği aracın
--    kartına yönünü de koyar (`hareket`). Tahmini ≥ 0.90 ve TAM bir açık
--    bileti varsa, başka açık bilet ona bir karakter uzak değilse ve giriş
--    penceresi geçtiyse webhook kart yerine kamera_tahmin_cikis'i çağırır:
--    bilet her kamera çıkışı gibi (kamera_cikis_bildir) ödemesiz kapanır.
--    Aksi her durumda null → eski kart yolu. Yalnızca service_role (PASS 41b).
-- E2 "yalnızca E2": içeride emin okunan plaka, son 15 dk içindeki plakasız
--    giriş kartına bağlanır; ikinci "İçeride bileti olmayan araç" kartı
--    yazılmaz, bilet açılmaz (kamera_tek_kapi ICERIDE kolu).
-- K  aynı iz girip 2 dk içinde çıktı (`ayni_iz_dondu`): giriş penceresinde
--    gelen ÇIKTI bileti kapatır (kamera_tek_kapi 1a). Ücret tarifeden; 2 dk
--    ücretsiz süre (ucretsiz_dakika ≥ 2) içindeyse 0.
-- H  bilet aracın içeride en son görüldüğü anı taşır (iceride_goruldu_at);
--    İçeride listesi (acik_bilet_ara) gösterir.
--
-- kamera_tek_kapi'nin imzası ve gövdesi 072'den BİREBİR; değişenler "077"
-- işaretli. acik_bilet_ara'nın dönüş tipi değiştiği için düşürülüp yeniden
-- yazılır (gövde 076'dan birebir + bir kolon). Sıra: 074, 075, 076, sonra
-- 077; ardından webhook, sonra uygulama. Smoke test: PASS 96–99 (+ 41b).

-- ------------------------------------------------------------ kolon (H) ---

alter table public.biletler add column if not exists iceride_goruldu_at timestamptz;
comment on column public.biletler.iceride_goruldu_at is
  '077: tek kapı köprüsünün aracı otoparkın içinde en son gördüğü an (yalnızca bilgi; para değil).';

-- ------------------------------------------------- çıkış tahmini (D) -----

create or replace function public.kamera_tahmin_cikis(
  p_tahmin   text,
  p_guven    numeric,
  p_islem_id uuid,
  p_zaman    timestamptz,
  p_ham      jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_plaka    text;
  v_giris_dk integer;
  v_limit_dk integer;
  v_b        public.biletler;
  v_id       uuid;
begin
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_islem_id is null or p_zaman is null then
    return null;
  end if;

  -- Yalnızca kapıdan ÇIKTI diye izlenen kart, ≥ 0.90 tahmin.
  if coalesce(p_guven, 0) < 0.90
     or jsonb_typeof(p_ham) is distinct from 'object'
     or p_ham ->> 'hareket' is distinct from 'CIKTI' then
    return null;
  end if;
  v_plaka := public.normalize_plaka(p_tahmin);
  if v_plaka is null or v_plaka !~ '^[A-Z0-9]{2,15}$' then
    return null;
  end if;

  -- kamera_tek_kapi ve kamera_okunamadi ile aynı kilit: kart yolu ve
  -- plakalı olaylarla yarışmasın.
  perform pg_advisory_xact_lock(hashtext('kamera_tek_kapi'));

  -- Tekrar: aynı olay bileti zaten kapattıysa aynı bilet; kart yazıldıysa
  -- kart yolu (istisna_yaz islem_id'de tekildir).
  select a.row_id into v_id from public.audit_log a
   where a.action = 'kamera_tahmin_cikis' and a.created_at > now() - interval '1 day'
     and a.detay ->> 'islem_id' = p_islem_id::text
   limit 1;
  if v_id is not null then
    return v_id;
  end if;
  if exists (select 1 from public.istisnalar i where i.islem_id = p_islem_id) then
    return null;
  end if;

  select o.tek_kapi_giris_yoksay_dk, o.kamera_gecikme_limiti_dk
    into v_giris_dk, v_limit_dk
    from public.otopark_ayarlari o where o.id = 1;
  v_giris_dk := coalesce(v_giris_dk, 3);
  v_limit_dk := coalesce(v_limit_dk, 720);
  -- Bayat / ileri saat: kamera_cikis_bildir kendi kaydını yazardı; kart
  -- yolu karar versin.
  if p_zaman > now() + interval '5 minutes'
     or p_zaman < now() - make_interval(mins => v_limit_dk) then
    return null;
  end if;

  select * into v_b from public.biletler b
   where b.durum = 'ACIK' and b.plaka = v_plaka;
  if not found then
    return null;
  end if;
  -- Benzeri varsa (bir karakter uzak başka açık bilet) tahmin edilmez.
  if exists (select 1 from public.biletler b
              where b.durum = 'ACIK' and b.id <> v_b.id
                and public.plaka_yakin(b.plaka, v_plaka)) then
    return null;
  end if;
  -- Giriş penceresi: aynı ziyaretin girişi olabilir (kamera_tek_kapi 1a).
  if p_zaman <= least(v_b.kaynak_zaman, v_b.created_at) + make_interval(mins => v_giris_dk) then
    return null;
  end if;

  v_id := public.kamera_cikis_bildir(v_plaka, p_islem_id, p_zaman, null, p_ham);
  if v_id is null then
    return null;
  end if;
  perform public.audit('kamera_tahmin_cikis', 'biletler', v_id,
    jsonb_build_object('islem_id', p_islem_id, 'guven', p_guven, 'zaman', p_zaman));
  return v_id;
end
$fn$;

-- ------------------------------------------------ tek kapı (E2, K, H) ----

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
  -- 077
  v_kart      uuid;
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
        -- 077 H: bilet aracın içeride en son görüldüğü anı taşır (İçeride
        --    listesi gösterir). Saat geri gitmez; açık bilette guard yok.
        update public.biletler
           set iceride_goruldu_at = greatest(coalesce(iceride_goruldu_at, p_zaman), p_zaman)
         where durum = 'ACIK' and plaka = v_plaka;
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null, 'sebep', 'ICERIDE_ACIK');
        exit karar;
      end if;
      -- Bir karakter uzak plakalı açık bilet: aynı aracın yanlış okunması.
      if exists (select 1 from public.biletler b
                  where b.durum = 'ACIK' and public.plaka_yakin(b.plaka, v_plaka)) then
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null, 'sebep', 'ICERIDE_BENZER');
        exit karar;
      end if;
      -- 072: KAMERA bu plakanın biletini çıkış diye kapattı ve araç kapanıştan
      --    SONRA, çıkış süresi içinde içeride görüldü: araç çıkmamış olabilir.
      --    Bilet değişmez; o bileti taşıyan tek kart insana gider ("Araç
      --    çıkmadı" bilette). Personelin kapattığı bilet aşağıdaki gibi yok
      --    sayılır (ödeyip kapıya giden araç olağandır). Birebir plaka; bir
      --    karakter uzak okuma aşağıda YENI_CIKIS_BENZER kalır.
      select * into v_b from public.biletler b
       where b.plaka = v_plaka and b.durum = 'KAPALI' and b.cikis_kaynak::text = 'KAMERA'
         and p_zaman > b.cikis_at
         and p_zaman <= b.cikis_at + make_interval(mins => v_cikis_dk)
       order by b.cikis_at desc
       limit 1;
      if found then
        if exists (select 1 from public.istisnalar i
                    where i.tur::text = 'CIKMAMIS_OLABILIR' and i.cozuldu_at is null
                      and v_b.id = any(i.aday_bilet_ids)) then
          v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null,
                                        'sebep', 'CIKMAMIS_KAYITLI');
          exit karar;
        end if;
        perform public.istisna_yaz('CIKMAMIS_OLABILIR', 'ORTAK', v_plaka, 'KAMERA', p_islem_id,
                                   p_ham, p_foto, p_zaman, array[v_b.id]);
        v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null,
                                      'sebep', 'CIKMAMIS_OLABILIR');
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
      -- 077 E2 (sahibin kararı 2026-11-25, "yalnızca E2"): az önce kapıdan
      --    giren aracın plakası okunamadı (kart), şimdi içeride emin okundu.
      --    Son 15 dk içindeki çözülmemiş, plakasız, ÇIKTI olmayan tek kapı
      --    kartı plakayı alır (en yenisi; tahmini boş, aynı ya da bir
      --    karakter uzaksa). Kart AÇIK kalır, bilet açılmaz: kararı insan
      --    verir, kart artık plakayı gösterir. İkinci kart yazılmaz.
      select i.id into v_kart from public.istisnalar i
       where i.tur::text = 'OKUNAMADI' and i.yon = 'ORTAK' and i.kaynak::text = 'KAMERA'
         and i.cozuldu_at is null and i.plaka is null
         and i.kaynak_zaman between p_zaman - interval '15 minutes' and p_zaman
         and coalesce(i.ham_yanit ->> 'hareket', 'GIRDI') = 'GIRDI'
         and (nullif(btrim(coalesce(i.ham_yanit ->> 'tahmin', '')), '') is null
              or public.normalize_plaka(i.ham_yanit ->> 'tahmin') = v_plaka
              or public.plaka_yakin(public.normalize_plaka(i.ham_yanit ->> 'tahmin'), v_plaka))
       order by i.kaynak_zaman desc, i.created_at desc
       limit 1;
      if v_kart is not null then
        update public.istisnalar
           set plaka = coalesce(plaka, v_plaka),
               ham_yanit = coalesce(ham_yanit, '{}'::jsonb)
                 || jsonb_build_object('sonradan_okunan', v_plaka, 'sonradan_sebep', 'ICERIDE')
         where id = v_kart and cozuldu_at is null;
        v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null,
                                      'sebep', 'ICERIDE_GIRIS_KARTI');
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
        -- 077 K (sahada 24.11 09:32/09:34): köprü AYNI izi kapıdan girerken
        --    ve şimdi ÇIKARKEN izledi (`ayni_iz_dondu`, köprü 1.4.6): araç
        --    gerçekten döndü. Bilet her kamera çıkışı gibi kapanır (ödemesiz;
        --    ücret tarifeden — ücretsiz süre içindeyse 0). İşaretsiz olay
        --    eskisi gibi aynı ziyaretin tekrarı.
        if v_hareket = 'CIKTI' and jsonb_typeof(p_ham) = 'object'
           and p_ham -> 'ayni_iz_dondu' = 'true'::jsonb then
          v_id := public.kamera_cikis_bildir(v_plaka, p_islem_id, p_zaman, p_foto, p_ham);
          if v_id is null then
            v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'ZAMAN');
            exit karar;
          end if;
          v_sonuc := jsonb_build_object('karar', 'CIKIS', 'bilet_id', v_id, 'sebep', 'AYNI_IZ_DONDU');
          exit karar;
        end if;
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

-- -------------------------------------------- İçeride listesi (H) --------
-- 076'nın gövdesi birebir + `iceride_goruldu_at`. Dönüş tipi değiştiği için
-- `create or replace` yetmez: düşürülür, yeniden yazılır, yetkiler yeniden.

drop function if exists public.acik_bilet_ara(text);

create function public.acik_bilet_ara(p_q text default null)
returns table (
  id uuid, plaka text, giris_at timestamptz,
  abonman_id uuid, park_yeri_id uuid, cikis_bekliyor_at timestamptz,
  indirim_kurus integer, puan_kullanilan integer, tarife_id uuid,
  gecikmeli_kayit boolean,
  notu_var boolean, ucret_kurus integer,
  plaka_supheli boolean,
  giris_by uuid, giris_kaynak public.kaynak,
  iptal_talebi boolean,
  iceride_goruldu_at timestamptz                                   -- 077
)
language plpgsql stable security definer set search_path = public as $fn$
declare v_q text := public.normalize_plaka(p_q);
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  return query
  select b.id, b.plaka, b.giris_at,
         b.abonman_id, b.park_yeri_id, b.cikis_bekliyor_at,
         b.indirim_kurus, b.puan_kullanilan, b.tarife_id, b.gecikmeli_kayit,
         (b.notlar is not null),
         case when b.abonman_id is not null then 0
              else public.ucret_hesapla(b.giris_at, now(), b.tarife_id) end,
         b.plaka_supheli,
         b.giris_by, b.giris_kaynak,
         (b.iptal_talebi_at is not null),
         b.iceride_goruldu_at
    from public.biletler b
   where b.durum = 'ACIK'
     and (v_q = '' or b.plaka like '%' || v_q || '%'
                   or (length(v_q) >= 3 and right(b.plaka, length(v_q)) = v_q))
   order by
     case when v_q = '' then 2
          when b.plaka = v_q then 0
          when b.plaka like v_q || '%' then 1
          else 2 end,
     b.giris_at desc
   -- Aramasız: hepsi. Yazılı arama: en çok 50.
   limit case when v_q = '' then null else 50 end;
end $fn$;

-- ---------------------------------------------------------------- yetki ---

revoke all on function public.kamera_tahmin_cikis(text, numeric, uuid, timestamptz, jsonb)
  from public;
revoke all on function public.kamera_tahmin_cikis(text, numeric, uuid, timestamptz, jsonb)
  from anon, authenticated, service_role;
grant execute on function public.kamera_tahmin_cikis(text, numeric, uuid, timestamptz, jsonb)
  to service_role;

-- kamera_tek_kapi: `create or replace` yetkilerini korur (yalnızca
-- service_role, 037); aşağıda yine denetlenir.

revoke all on function public.acik_bilet_ara(text) from public;
revoke all on function public.acik_bilet_ara(text) from anon, authenticated, service_role;
grant execute on function public.acik_bilet_ara(text) to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r      text;
  f      text;
  v_def  text;
  f_tah  constant text := 'public.kamera_tahmin_cikis(text, numeric, uuid, timestamptz, jsonb)';
  f_tek  constant text := 'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)';
  f_ara  constant text := 'public.acik_bilet_ara(text)';
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'biletler'
                    and column_name = 'iceride_goruldu_at') then
    raise exception '077: biletler.iceride_goruldu_at yok';
  end if;

  foreach f in array array[f_tah, f_tek, f_ara] loop
    if not exists (select 1 from pg_proc where oid = f::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
      raise exception '077: % SECURITY DEFINER + search_path=public değil', f;
    end if;
  end loop;

  foreach f in array array[f_tah, f_tek] loop
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception '077: % service_role rolüne kapalı — webhook çağıramaz', f;
    end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception '077: % % rolüne açık', f, r;
      end if;
    end loop;
  end loop;

  if not has_function_privilege('authenticated', f_ara, 'execute') then
    raise exception '077: acik_bilet_ara authenticated rolüne kapalı';
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, f_ara, 'execute') then
      raise exception '077: acik_bilet_ara % rolüne açık', r;
    end if;
  end loop;

  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in ('acik_bilet_ara', 'kamera_tek_kapi',
                                                     'kamera_tahmin_cikis')) <> 3 then
    raise exception '077: acik_bilet_ara / kamera_tek_kapi / kamera_tahmin_cikis birden çok imzayla tanımlı';
  end if;

  v_def := pg_get_functiondef(f_tek::regprocedure);
  if position('ICERIDE_GIRIS_KARTI' in v_def) = 0 or position('AYNI_IZ_DONDU' in v_def) = 0
     or position('iceride_goruldu_at' in v_def) = 0 or position('CIKMAMIS_OLABILIR' in v_def) = 0 then
    raise exception '077: kamera_tek_kapi yeni gövdede değil';
  end if;
end
$do$;

commit;
