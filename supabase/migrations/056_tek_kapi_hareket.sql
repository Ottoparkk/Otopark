-- ============================================================================
-- 056  Tek kapı: köprünün yön ipucu yalnızca YANLIŞ TAHMİNİ durdurur
-- ============================================================================

begin;

-- Sahada 11.11 (tek kapı, ORTAK): sunucu girişi çıkıştan YALNIZCA bilet
-- durumuyla ayırıyor. İki yanlış:
--   · çıkan araç, açık bileti yok (wipe öncesinden içerideydi)  → HAYALET
--     giriş açılıyor (11:35, 13:46); hayalet iptal edilmezse aracın sonraki
--     GERÇEK girişi "çıkış" sayılıp hayaleti kapatıyor;
--   · giren araç, eski (hayalet) açık bileti var → "çıkış" sayılıp kapanıyor.
-- Köprü 1.4.2 aracı İZLİYOR ve yönünü biliyor; olayla birlikte gönderiyor
-- (`hareket`: GIRDI, CIKTI, ICERIDE). Sahibin kuralı (2026-11-14): ipucu
-- YALNIZCA yanlış tahmini durdurur — tek başına asla bilet açmaz ya da
-- kapatmaz; çelişkide karar insana kalır:
--   · CIKTI  + açık bilet yok        → ACIK_BILET_YOK (yon ORTAK), bilet yok;
--   · GIRDI  + eski açık bilet       → GIRISTE_ACIK_BILET (055), bilet açık
--                                       kalır, adayı o bilet;
--   · ICERIDE (içeride gezen araç)    → bileti varsa (ya da bir karakter uzak
--     plakalı bilet varsa, ya da kendisinin / bir karakter uzağının bileti az
--     önce kapandıysa, ya da bu plaka için çözülmemiş ICERIDE_BILETSIZ kaydı
--     zaten varsa) HİÇBİR ŞEY — asla çıkış sayılmaz; yoksa ICERIDE_BILETSIZ (055).
-- İpucu yok ya da tanınmayan değer → 048'in kararı AYNEN (eski köprü, kutuda
-- bekleyen eski olay, 1.3.4 geçiş kuralı, tek kare / kapıda kaybolan araç).
--
-- İmza değişiyor (sona `p_hareket text default null`): önce eski imza DÜŞÜRÜLÜR
-- ki tek tanım kalsın (048'in doğrulaması ve PostgREST'in adlı çağrısı). Canlı
-- webhook'un beş adlı argümanlı çağrısı yeni tanımla da çalışır (varsayılan) —
-- bu migration webhook'tan ÖNCE koşulabilir. Yeni webhook p_hareket gönderir:
-- o yüzden webhook bu migration'dan SONRA yayınlanır.
--
-- 055'in değerleri bu dosyada hiçbir yerde enum literali olarak ÇALIŞTIRILMAZ
-- (039 dersi: SQL editörü dosyayı tek transaction'da koşar): yalnızca
-- plpgsql gövdelerinde geçer (ilk çağrıda çözülür), doğrulama pg_enum'u okur.

-- ----------------------------------------------------------- tek kapı -----

drop function if exists public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb);

-- Gövde 048'den BİREBİR; değişenler "056" ile işaretli: ipucunun okunması,
-- ICERIDE adımı, 1b'deki GIRDI dalı, 5'teki CIKTI dalı.
create function public.kamera_tek_kapi(
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

  return v_sonuc;
end
$fn$;

-- Yeni tanım (create function, drop sonrası) PUBLIC'e EXECUTE ile doğar:
-- açıkça kapatılır ve yalnızca webhook'a (service_role) verilir.
revoke all on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)
  from public;
revoke all on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)
  from anon, authenticated, service_role;
grant execute on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)
  to service_role;

-- ------------------------------------------------- giriş aç (personel) -----

-- Gövde 044'ten BİREBİR; tek değişiklik (056 ile işaretli): ICERIDE_BILETSIZ
-- kaydından da giriş açılır. Plakayı personel yazar (alan kaydın plakasıyla
-- başlar), giriş saati kaydın kaynak_zaman'ı — aracın içeride GÖRÜLDÜĞÜ an:
-- kanıtlanmış en erken varlığı. 044'ün bütün korumaları aynen.
create or replace function public.istisna_bilet_ac(p_id uuid, p_plaka text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ist      public.istisnalar%rowtype;
  v_bilet    uuid;
  v_b        record;
  v_limit_dk integer;
  v_giris    timestamptz;
  v_yer      uuid;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  -- Row lock: two staff tapping the same card at once are serialised; the
  -- second one then finds the ticket and is answered like a repeated tap.
  select * into v_ist from public.istisnalar where id = p_id for update;
  if not found then
    raise exception 'Kayıt bulunamadı.';
  end if;
  -- 056: ICERIDE_BILETSIZ de (içeride gezen, bileti olmayan araç).
  if v_ist.tur::text not in ('OKUNAMADI', 'ICERIDE_BILETSIZ') or v_ist.islem_id is null then
    raise exception 'Bu kayıttan giriş açılamaz.';
  end if;

  -- A ticket already carries this event: a camera retry opened it (041 /
  -- bilet_ac replay), or this is a repeated tap whose answer was lost. That
  -- ticket is never touched; an open card is closed with a note saying so.
  select b.id, b.plaka into v_b from public.biletler b where b.islem_id = v_ist.islem_id;
  if found then
    if v_ist.cozuldu_at is null then
      update public.istisnalar
         set cozuldu_by = auth.uid(), cozuldu_at = now(),
             cozum_notu = 'Kamera bileti zaten açmış: ' || v_b.plaka
       where id = p_id;
    end if;
    return jsonb_build_object(
      'bilet_id', v_b.id, 'plaka', v_b.plaka, 'zaten_vardi', true,
      'yer_kod', (select p.kod from public.park_yerleri p
                    join public.biletler b on b.park_yeri_id = p.id
                   where b.id = v_b.id));
  end if;

  if v_ist.cozuldu_at is not null then
    raise exception 'Bu kayıt zaten kapatılmış.';
  end if;

  -- Entry time: the camera's, when it can be trusted (read the limit exactly
  -- as bilet_ac does).
  select o.kamera_gecikme_limiti_dk into v_limit_dk
    from public.otopark_ayarlari o where o.id = 1;
  v_limit_dk := coalesce(v_limit_dk, 720);

  if v_ist.kaynak_zaman is not null
     and v_ist.kaynak_zaman >= v_ist.alindi_zaman - make_interval(mins => v_limit_dk)
     and v_ist.kaynak_zaman <= v_ist.alindi_zaman + interval '5 minutes' then
    v_giris := v_ist.kaynak_zaman;
  else
    v_giris := v_ist.alindi_zaman;
  end if;
  v_giris := least(v_giris, now());

  if v_giris < now() - make_interval(mins => v_limit_dk) then
    raise exception 'Bu kayıt çok eski; araç büyük olasılıkla çıktı. Gerekirse girişi Giriş ekranından açın.';
  end if;

  -- Spot: the first free one, as a camera ticket gets — staff are not asked
  -- to choose. Same lock key as bilet_ac (030), so the spot read here cannot
  -- be taken before bilet_ac writes it (the lock is re-entrant in this
  -- transaction). Full lot / no layout → NULL, the ticket still opens.
  perform pg_advisory_xact_lock(hashtext('bilet_ac_yer'));
  v_yer := public.bos_park_yeri();

  v_bilet := public.bilet_ac(p_plaka, v_ist.islem_id, 'MOBIL', null, v_ist.foto_path, v_yer);
  if v_bilet is null then
    raise exception 'Bilet açılamadı.';
  end if;

  -- Was it really opened by THIS call? A camera retry of the same event that
  -- committed between the check above and bilet_ac's insert makes bilet_ac
  -- hand back the camera's ticket (unique islem_id). That one must not be
  -- re-dated or claimed.
  select b.plaka, b.giris_by, b.giris_kaynak, b.alindi_zaman into v_b
    from public.biletler b where b.id = v_bilet;
  if v_b.giris_by is distinct from auth.uid()
     or v_b.giris_kaynak::text <> 'MOBIL'
     or v_b.alindi_zaman <> now() then
    update public.istisnalar
       set cozuldu_by = auth.uid(), cozuldu_at = now(),
           cozum_notu = 'Kamera bileti zaten açmış: ' || v_b.plaka
     where id = p_id;
    return jsonb_build_object(
      'bilet_id', v_bilet, 'plaka', v_b.plaka, 'zaten_vardi', true,
      'yer_kod', (select p.kod from public.park_yerleri p
                    join public.biletler b on b.park_yeri_id = p.id
                   where b.id = v_bilet));
  end if;

  -- Re-date the ticket just opened (still ACIK → the immutable guard lets it
  -- through, 029). kaynak_zaman = the time billed from, so the ticket's
  -- "Kameradan gelme … sonradan işlendi" line names it.
  update public.biletler
     set giris_at        = v_giris,
         kaynak_zaman    = v_giris,
         gecikmeli_kayit = (v_giris < now() - interval '2 minutes')
   where id = v_bilet;

  update public.istisnalar
     set cozuldu_by = auth.uid(), cozuldu_at = now(),
         cozum_notu = 'Bilet açıldı: ' || v_b.plaka
   where id = p_id;

  perform public.audit('istisna_bilet_acildi', 'biletler', v_bilet,
    jsonb_build_object('istisna_id', p_id, 'plaka', v_b.plaka, 'giris_at', v_giris));

  return jsonb_build_object(
    'bilet_id', v_bilet, 'plaka', v_b.plaka, 'zaten_vardi', false,
    'yer_kod', (select p.kod from public.park_yerleri p
                  join public.biletler b on b.park_yeri_id = p.id
                 where b.id = v_bilet));
end
$$;

-- create or replace ACL'i korur; yine de proje kuralı gereği açıkça yeniden
-- yazılır (044 ile aynı): yalnızca giriş yapmış kullanıcı (rolü gövde denetler).
revoke all on function public.istisna_bilet_ac(uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.istisna_bilet_ac(uuid, text) to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  f constant text := 'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)';
  g constant text := 'public.istisna_bilet_ac(uuid, text)';
  r text;
begin
  -- 055 koşulmuş olmalı: iki yeni tür (pg_enum'dan — literal cast YOK, 039 dersi).
  if (select count(*) from pg_enum e join pg_type t on t.oid = e.enumtypid
       where t.typname = 'istisna_tur'
         and e.enumlabel in ('GIRISTE_ACIK_BILET', 'ICERIDE_BILETSIZ')) <> 2 then
    raise exception '056: istisna_tur''de GIRISTE_ACIK_BILET / ICERIDE_BILETSIZ yok — önce 055''i çalıştırın';
  end if;

  if to_regprocedure(f) is null then
    raise exception '056: % oluşmadı', f;
  end if;
  if not has_function_privilege('service_role', f, 'execute') then
    raise exception '056: % service_role rolüne kapalı — webhook çağıramaz', f;
  end if;
  foreach r in array array['public', 'anon', 'authenticated'] loop
    if has_function_privilege(r, f, 'execute') then
      raise exception '056: % % rolüne açık', f, r;
    end if;
  end loop;
  if not exists (select 1 from pg_proc
                  where oid = f::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
    raise exception '056: kamera_tek_kapi SECURITY DEFINER + search_path=public değil';
  end if;
  -- Aynı adla ikinci bir tanım (eski beş argümanlı imza) bırakılmadı.
  if (select count(*) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'kamera_tek_kapi') <> 1 then
    raise exception '056: kamera_tek_kapi birden çok imzayla tanımlı';
  end if;

  if not exists (select 1 from pg_proc
                  where oid = g::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
    raise exception '056: istisna_bilet_ac SECURITY DEFINER + search_path=public değil';
  end if;
  if not has_function_privilege('authenticated', g, 'execute') then
    raise exception '056: istisna_bilet_ac personele kapalı';
  end if;
  foreach r in array array['public', 'anon', 'service_role'] loop
    if has_function_privilege(r, g, 'execute') then
      raise exception '056: istisna_bilet_ac % rolüne açık', r;
    end if;
  end loop;
  -- bilet_ac must still be the one 11-arg function (no overload crept in).
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'bilet_ac') <> 1 then
    raise exception '056: bilet_ac aşırı yüklenmiş — tek imza bekleniyordu';
  end if;
end
$do$;

commit;
