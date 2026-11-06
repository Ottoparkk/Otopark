-- ============================================================================
-- 048  Tek kapı: pencereler OLAYIN saatiyle (geç gelen olay kaybolmasın)
-- ============================================================================

begin;

-- Köprü 1.3.0 internet kesilince her aracı diske yazar ve bağlantı dönünce
-- SIRAYLA gönderir (önceden 4 denemeden sonra araç kayboluyordu). 041'deki
-- kamera_tek_kapi pencerelerini SUNUCU saatiyle ölçüyordu (037:95-97):
-- biletin created_at'i ve kapanışı (cikis_at / iptal_at) now() karşısında.
-- Canlı olayda bu doğruydu; toplu gelen olayda üç hata çıkıyor:
--   (1) giriş 10:00 ve çıkış 10:30 birlikte 11:00'de gelir: bilet 11:00'de
--       açıldığı için çıkış "az önce girdi" sayılıp YOK SAYILIR — araç çıktı,
--       bilet açık kalır;
--   (2) personel aracı 10:30'da kapattı, kameranın 10:30 olayı 11:00'de gelir:
--       kapanış now()'a göre "eski", HAYALET bilet açılır;
--   (3) personel aracı 10:01'de elle girdi, kameranın 10:00 girişi sonradan
--       gelir: bilet "eski" sayılır, SAHTE "kapıda" damgası basılır.
-- Düzeltme: olayın zamanı (p_zaman) ziyaretin başladığı an ve kapandığı anla
-- kıyaslanır.
--   · Başlangıç = least(kaynak_zaman, created_at). Kamera biletinde
--     kaynak_zaman kameranın saatidir (030:451; 044 de yazar) ve 046'nın giriş
--     düzeltmesi ona DOKUNMAZ (046:30); personel biletinde boştur, least boşu
--     atlar ve created_at (sunucu saati) kalır. Canlı olayda ikisi eşittir.
--     giris_at BİLEREK kullanılmıyor: personel onu 046 ile geri çekebilir ve
--     kapıda hâlâ duran araç "çıkıyor" sayılırdı.
--   · Kapanış = coalesce(cikis_at, iptal_at), 041'deki sırayla.
--   · Açık bilet (adım 1, 3): olay ≤ başlangıç + giriş süresi → aynı ziyaret
--     (başlangıçtan ÖNCEKİ olay da: personelin elle girdiği aracın geç gelen
--     kendi girişi).
--   · Kapanmış bilet (adım 2, 4): başlangıç − giriş süresi ≤ olay ≤ kapanış +
--     çıkış süresi → aynı ziyaret, yok say.
-- Canlı olayda p_zaman ≈ now() ve her koşul 041'deki ile aynı sonucu verir
-- (PASS 58, 63, 64 değişmeden geçer; onların created_at'i geri çekmesi
-- başlangıcı da geri çeker çünkü least). İki saat (köprü ve sunucu) yalnızca
-- personel biletinde karşılaşır; köprü saati 60 sn'den fazla kayarsa zaten
-- uyarır (gunluk.SAAT_TOLERANS_SN) ve süreler en az 1–3 dakikadır.
-- Bilinen sınır: yalnızca GIRIS şeridi (bilet_ac) değişmedi — orada "az önce
-- kapandı" kuralı hiç yok; sahada tek kapı (ORTAK) kullanılıyor.

-- ----------------------------------------------------------- tek kapı -----

-- Gövde 041'den BİREBİR; yalnızca dört zaman koşulu (1a, 2, 3, 4) değişti.
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
      -- 1a. Olay ziyaretin başından en çok giriş süresi sonra (ya da ÖNCE):
      --     araç hâlâ kameranın önünde / aynı ziyaretin geç gelen girişi. 048
      if p_zaman <= least(v_b.kaynak_zaman, v_b.created_at)
                    + make_interval(mins => v_giris_dk) then
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

-- create or replace ACL'i korur; yine de yetki burada açıkça yeniden yazılır
-- (proje kuralı) ve aşağıda doğrulanır: yalnızca webhook (service_role).
revoke all on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)
  from public;
revoke all on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)
  from anon, authenticated, service_role;
grant execute on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)
  to service_role;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  f constant text := 'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb)';
  r text;
begin
  if not has_function_privilege('service_role', f, 'execute') then
    raise exception '048: % service_role rolüne kapalı — webhook çağıramaz', f;
  end if;
  foreach r in array array['anon', 'authenticated'] loop
    if has_function_privilege(r, f, 'execute') then
      raise exception '048: % % rolüne açık', f, r;
    end if;
  end loop;

  if not exists (select 1 from pg_proc p
                   join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'kamera_tek_kapi'
                    and p.prosecdef
                    and p.proconfig @> array['search_path=public']) then
    raise exception '048: kamera_tek_kapi SECURITY DEFINER + search_path=public değil';
  end if;
  -- Aynı adla ikinci bir tanım (farklı imza) bırakılmadı.
  if (select count(*) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'kamera_tek_kapi') <> 1 then
    raise exception '048: kamera_tek_kapi birden çok imzayla tanımlı';
  end if;
end
$do$;

commit;
