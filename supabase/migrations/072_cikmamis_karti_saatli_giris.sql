-- ============================================================================
-- 072  Tek kapı: çıkmamış olabilir kartı, açık bileti olmayan kartta saatli giriş
-- ============================================================================

begin;

-- Sahibin kararları (2026-11-18):
--
-- 1. Kameranın çıkış diye kapattığı araç içeride görülürse kart. Bugün tek
--    kapıda ICERIDE ipuçlu bir olay, plakanın bileti çıkış süresi (5 dk)
--    içinde kapandıysa YENI_CIKIS diye yok sayılıyordu. Bileti KAMERA
--    kapattıysa ve araç kapanıştan SONRA içeride görüldüyse yeni
--    CIKMAMIS_OLABILIR kartı yazılır; kart o bileti aday_bilet_ids'te taşır,
--    ekran "Bilete git" ile "Araç çıkmadı"ya götürür. Bilet değişmez (yalnızca
--    insan geri açar: 054 / 060). Personelin kapattığı bilet, kapanıştan önceki
--    görülme ve bir karakter uzak okuma eskisi gibi yok sayılır. Bilet yeniden
--    açılınca (KAPALI → ACIK, hangi işlev açarsa açsın) kart kendiliğinden
--    kapanır — cikmamis_kart_kapat tetiği; personel ikinci kez kapatmasın.
--    kamera_tek_kapi'nin imzası ve gövdesi 069'dan BİREBİR; tek ek ICERIDE
--    kolundaki "072" bloğu. PASS 90 sınar.
--
-- 2. Tek kapı "Çıkışta açık bilet bulunamadı" (ACIK_BILET_YOK, ORTAK, KAMERA)
--    kartından Giriş aç: araç aslında girmiş olabilir. Giriş saatini personel
--    YAZAR (kart saati de şimdi de ücreti yanlış hesaplar) ve sebep zorunlu.
--    istisna_bilet_ac_saatli, istisna_bilet_ac'ın (056) korumalarını aynen
--    taşır, saati bilet_giris_duzelt (046) ile yazar: ileri saat yok, bir
--    yıldan eski yok, sebep zorunlu, denetim kaydı, Yönetici bildirimi.
--    Yalnızca authenticated (rolü gövde denetler): PASS 41 listesi değişmez.
--    PASS 91 sınar.

alter type public.istisna_tur add value if not exists 'CIKMAMIS_OLABILIR';

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

-- ------------------------------------------- bilet geri açılınca kart -----

create or replace function public.cikmamis_kart_kapat() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  update public.istisnalar
     set cozuldu_by = auth.uid(),
         cozuldu_at = now(),
         cozum_notu = 'Bilet yeniden açıldı (Araç çıkmadı).'
   where tur::text = 'CIKMAMIS_OLABILIR'
     and cozuldu_at is null
     and new.id = any(aday_bilet_ids);
  return null;
end
$fn$;

drop trigger if exists cikmamis_kart_kapat_tg on public.biletler;
create trigger cikmamis_kart_kapat_tg
  after update of durum on public.biletler
  for each row
  when (old.durum = 'KAPALI' and new.durum = 'ACIK')
  execute function public.cikmamis_kart_kapat();

-- ------------------------------------------- saatli giriş aç (personel) ---

create or replace function public.istisna_bilet_ac_saatli(
  p_id       uuid,
  p_plaka    text,
  p_giris_at timestamptz,
  p_sebep    text
) returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare
  v_ist   public.istisnalar%rowtype;
  v_bilet uuid;
  v_b     record;
  v_yer   uuid;
  v_sebep text := left(btrim(coalesce(p_sebep, '')), 200);
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  -- Satır kilidi: aynı karta iki dokunuş sıraya girer; ikincisi bileti bulur.
  select * into v_ist from public.istisnalar where id = p_id for update;
  if not found then
    raise exception 'Kayıt bulunamadı.';
  end if;
  if v_ist.tur::text <> 'ACIK_BILET_YOK' or v_ist.yon <> 'ORTAK'
     or v_ist.kaynak::text <> 'KAMERA' or v_ist.islem_id is null then
    raise exception 'Bu kayıttan giriş açılamaz.';
  end if;

  -- Bu olayı taşıyan bilet zaten var (tekrarlanan dokunuş): ona dokunulmaz.
  select b.id, b.plaka into v_b from public.biletler b where b.islem_id = v_ist.islem_id;
  if found then
    if v_ist.cozuldu_at is null then
      update public.istisnalar
         set cozuldu_by = auth.uid(), cozuldu_at = now(),
             cozum_notu = 'Bilet zaten açık: ' || v_b.plaka
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
  -- Kalan saat ve sebep sınırları bilet_giris_duzelt'te (046); hata olursa
  -- açılan bilet de geri alınır (tek transaction).
  if p_giris_at is null then
    raise exception 'Giriş saati boş olamaz.';
  end if;

  -- Yer: kamera biletindeki gibi ilk boş yer (056 ile aynı kilit).
  perform pg_advisory_xact_lock(hashtext('bilet_ac_yer'));
  v_yer := public.bos_park_yeri();

  v_bilet := public.bilet_ac(p_plaka, v_ist.islem_id, 'MOBIL', null, v_ist.foto_path, v_yer);
  if v_bilet is null then
    raise exception 'Bilet açılamadı.';
  end if;

  -- Gerçekten bu çağrı mı açtı? (056 ile aynı denetim.)
  select b.plaka, b.giris_by, b.giris_kaynak, b.alindi_zaman into v_b
    from public.biletler b where b.id = v_bilet;
  if v_b.giris_by is distinct from auth.uid()
     or v_b.giris_kaynak::text <> 'MOBIL'
     or v_b.alindi_zaman <> now() then
    update public.istisnalar
       set cozuldu_by = auth.uid(), cozuldu_at = now(),
           cozum_notu = 'Bilet zaten açık: ' || v_b.plaka
     where id = p_id;
    return jsonb_build_object(
      'bilet_id', v_bilet, 'plaka', v_b.plaka, 'zaten_vardi', true,
      'yer_kod', (select p.kod from public.park_yerleri p
                    join public.biletler b on b.park_yeri_id = p.id
                   where b.id = v_bilet));
  end if;

  -- Yazılan saat: denetim kaydı ve Yönetici bildirimiyle (046).
  perform public.bilet_giris_duzelt(v_bilet, p_giris_at, v_sebep);

  update public.istisnalar
     set cozuldu_by = auth.uid(), cozuldu_at = now(),
         cozum_notu = 'Bilet açıldı, giriş saati yazıldı: ' || v_b.plaka
   where id = p_id;

  perform public.audit('istisna_bilet_acildi', 'biletler', v_bilet,
    jsonb_build_object('istisna_id', p_id, 'plaka', v_b.plaka,
                       'giris_at', p_giris_at, 'sebep', v_sebep));

  return jsonb_build_object(
    'bilet_id', v_bilet, 'plaka', v_b.plaka, 'zaten_vardi', false,
    'yer_kod', (select p.kod from public.park_yerleri p
                  join public.biletler b on b.park_yeri_id = p.id
                 where b.id = v_bilet));
end
$fn$;

-- -------------------------------------------------------------- yetki -----

revoke all on function public.cikmamis_kart_kapat()
  from public, anon, authenticated, service_role;

revoke all on function public.istisna_bilet_ac_saatli(uuid, text, timestamptz, text) from public;
revoke all on function public.istisna_bilet_ac_saatli(uuid, text, timestamptz, text)
  from anon, authenticated, service_role;
grant execute on function public.istisna_bilet_ac_saatli(uuid, text, timestamptz, text)
  to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  f_tek    constant text := 'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)';
  f_saat   constant text := 'public.istisna_bilet_ac_saatli(uuid, text, timestamptz, text)';
  f_tetik  constant text := 'public.cikmamis_kart_kapat()';
  f        text;
  r        text;
begin
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'istisna_tur' and e.enumlabel = 'CIKMAMIS_OLABILIR') then
    raise exception '072: istisna_tur CIKMAMIS_OLABILIR eklenmedi';
  end if;
  foreach f in array array[f_tek, f_saat, f_tetik] loop
    if not exists (select 1 from pg_proc where oid = f::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
      raise exception '072: % SECURITY DEFINER + search_path=public değil', f;
    end if;
  end loop;
  if (select count(*) from pg_proc
       where proname = 'kamera_tek_kapi' and pronamespace = 'public'::regnamespace) <> 1 then
    raise exception '072: kamera_tek_kapi tek tanım değil';
  end if;
  if position('072: KAMERA bu plakanın' in pg_get_functiondef(f_tek::regprocedure)) = 0
     or position('069: Bilet açıldı' in pg_get_functiondef(f_tek::regprocedure)) = 0 then
    raise exception '072: kamera_tek_kapi yeni gövdede değil';
  end if;
  foreach r in array array['anon', 'authenticated'] loop
    if has_function_privilege(r, f_tek, 'execute') then
      raise exception '072: kamera_tek_kapi % rolüne açık', r;
    end if;
  end loop;
  if not has_function_privilege('service_role', f_tek, 'execute') then
    raise exception '072: kamera_tek_kapi service_role''e kapalı (webhook çağıramaz)';
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, f_saat, 'execute') then
      raise exception '072: istisna_bilet_ac_saatli % rolüne açık', r;
    end if;
  end loop;
  if not has_function_privilege('authenticated', f_saat, 'execute') then
    raise exception '072: istisna_bilet_ac_saatli authenticated''a kapalı';
  end if;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(r, f_tetik, 'execute') then
      raise exception '072: cikmamis_kart_kapat % rolüne açık', r;
    end if;
  end loop;
  if not exists (select 1 from pg_trigger
                  where tgname = 'cikmamis_kart_kapat_tg'
                    and tgrelid = 'public.biletler'::regclass) then
    raise exception '072: cikmamis_kart_kapat_tg tetiği yok';
  end if;
end
$do$;

commit;
