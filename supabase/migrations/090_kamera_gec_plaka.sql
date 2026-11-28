-- =====================================================================
-- 090  Kamera: geç okunan plaka biletlenir, çıkış tahmini kapanır
-- =====================================================================
begin;

-- Sahada 26-28.11 (köprü 1.4.6, teşhis raporu 28.11):
--   * 077 D'nin çıkış tahmini iki kez çalıştı, ikisi de yanlıştı (park
--     etmiş aracın plakası; iki plakalı iz) — bilet kapanıp araç içeride
--     kaldı;
--   * altı bilet 10-60 saat açık kaldı: çıkışı görülmedi, araç ertesi gün
--     yeniden girince 056 kartı (GIRISTE_ACIK_BILET) yazıldı, bilet açık
--     kaldı;
--   * içeri giren araçlar "İçeride, bileti yok" kartı oldu (giriş kartı
--     plakasız, plaka içeride okundu) — 32 saatte 73 kart.
-- Sahibin kararları (28.11, "Go"):
--   F1  Çıkış tahmini hiçbir bileti kapatmaz.
--   F2  Emin girişte (GIRDI) eski açık bilet, aracın içeride en son
--       görüldüğü saatte (yoksa kendi giriş saatinde) ödemesiz kapanır;
--       not ve denetim kaydı alır, Yönetici bilgilenir; yeni bilet açılır.
--   F3  Çıkışta (ÇIKTI) sık karışan tek harf (O/D/0, M/N, B/8, I/1, S/5,
--       Z/2, G/6) ve içeride TEK benzer bilet: o bilet kapanır.
--   F4  Plakasız giriş kartı, aynı aracın sonradan okunan plakasına
--       bağlanırsa bilet KARTIN saatinden açılır (içeride okunduysa açık
--       kalır, çıkışta okunduysa hemen kamera çıkışı gibi kapanır), kart
--       sistemce çözülür. Bağ: köprü 1.4.7'nin `giris_islem_id`'si, yoksa
--       son 10 saatte tahmini birebir bu plaka olan TEK kart, içeride ise
--       077 E2'nin 15 dakikalık kartı. Kimlikle bağlanan kart, aracın eski
--       açık biletinden 15 dakikadan fazla sonraysa F2 kuralı işler (eski
--       bilet kapanır, yenisi kartın saatinden açılır). Yalnızca tahmine
--       dayanan bağ çıkışta benzer aramasından SONRA denenir.
--   F6  İçeride görülen, bileti ve kartı olmayan araca bilet açılır —
--       işaretli, Yönetici bilgilenir (artık ICERIDE_BILETSIZ kartı yok).
-- İşaretler biletler.notlar'da ("not var" rozeti) ve KAMERA_HAREKET
-- bildiriminde: ön yüzde değişiklik gerekmez. Para kuralı aynı: kamera
-- bileti yalnızca ÖDEMESİZ kapatır, tahsilat hep insanda (054).
--
-- Webhook gövdeyi (fotoğrafsız) p_ham olarak geçirir: `giris_islem_id`
-- için Edge Function değişmez. Bozuk kimlik `::uuid`'de 22P02 olurdu ve
-- webhook onu REDDEDILDI kartına çevirirdi — o yüzden önce biçimi sınanır.
--
-- kamera_tek_kapi 089'daki, kamera_okunamadi 041'deki son haliyle yeniden
-- yazılır; değişen yerler "090" yorumlu.

do $$
begin
  if to_regprocedure('public.odenmis_cikis(text, timestamptz, uuid, boolean)') is null then
    raise exception '090: önce 089 çalıştırılmalı.';
  end if;
end $$;

-- ------------------------------------------------ plaka_harf_karisir --
-- Aynı uzunluk, tam bir konumda fark ve o iki karakter aynı karışma
-- grubunda. Plakalar normalize_plaka'dan geçmiş gelir (büyük harf, yalnızca
-- harf ve rakam). NULL ya da boşta false.
create or replace function public.plaka_harf_karisir(a text, b text)
returns boolean
language sql immutable set search_path = public as $$
  select coalesce(
    length(a) = length(b)
    and (select count(*) from generate_series(1, length(a)) as g(i)
          where substr(a, g.i, 1) <> substr(b, g.i, 1)) = 1
    and exists (select 1
                  from generate_series(1, length(a)) as g(i),
                       unnest(array['OD0', 'MN', 'B8', 'I1', 'S5', 'Z2', 'G6']) as k(grup)
                 where substr(a, g.i, 1) <> substr(b, g.i, 1)
                   and strpos(k.grup, substr(a, g.i, 1)) > 0
                   and strpos(k.grup, substr(b, g.i, 1)) > 0),
    false);
$$;

-- ------------------------------------------- kamera_eski_bileti_kapat --
-- F2: eski açık bileti kapatır. Saat: aracın içeride en son görüldüğü an
-- (077 H, iceride_goruldu_at), görülmediyse kendi giriş saati; hiçbir
-- zaman yeni girişten sonra değil. Kapanış sütunları 089'un
-- kamera_cikis_bildir'iyle aynı (ödemesiz, ücret bilet_ucreti ile, açık
-- kasa vardiyası). Kullanılan puan ücretten fazlaysa kapatmaz (null):
-- çağıran eskisi gibi karta gider. kamera_cikis_bildir kullanılamaz: 720
-- dakikadan eski saati reddeder, 10-60 saatlik bilet tam da odur.
create or replace function public.kamera_eski_bileti_kapat(p_bilet uuid, p_zaman timestamptz)
returns timestamptz
language plpgsql security definer set search_path = public as $fn$
declare
  v_b       public.biletler;
  v_cikis   timestamptz;
  v_ucret   integer;
  v_vardiya uuid;
begin
  select * into v_b from public.biletler where id = p_bilet for update;
  if not found or v_b.durum <> 'ACIK' or p_zaman is null then
    return null;
  end if;

  v_cikis := greatest(v_b.giris_at,
                      least(coalesce(v_b.iceride_goruldu_at, v_b.giris_at), p_zaman));
  v_ucret := public.bilet_ucreti(v_b, v_cikis);
  if v_b.indirim_kurus > v_ucret then
    return null;
  end if;

  select v.id into v_vardiya from public.vardiyalar v
   where v.kapanis_at is null
   limit 1;

  -- İşaret notun BAŞINA: 500 karakterlik bir not onu kesmesin.
  update public.biletler set
    cikis_at           = v_cikis,
    ucret_kurus        = v_ucret,
    tahsil_kurus       = 0,
    odeme_yontemi      = null,
    durum              = 'KAPALI',
    cikis_by           = null,
    cikis_kaynak       = 'KAMERA',
    cikis_bekliyor_at  = v_cikis,
    kapatan_vardiya_id = v_vardiya,
    notlar             = left(concat_ws(' · ', 'Kamera: çıkışı görülmedi',
                                        nullif(btrim(coalesce(v_b.notlar, '')), '')), 500)
  where id = p_bilet and durum = 'ACIK';

  perform public.audit('kamera_cikis_gorulmedi', 'biletler', p_bilet,
    jsonb_build_object('plaka', v_b.plaka, 'cikis_at', v_cikis, 'ucret', v_ucret,
                       'borc', v_ucret - v_b.indirim_kurus, 'yeni_giris', p_zaman,
                       'vardiya', v_vardiya));
  return v_cikis;
end
$fn$;

-- ----------------------------------------------- kamera_yeniden_giris --
-- F2'nin tamamı: araç çıkışı görülmeden yeniden girdi (p_zaman). Eski bilet
-- kamera_eski_bileti_kapat ile kapanır, yenisi p_zaman'dan p_islem_id ile
-- açılır, Yönetici bilgilenir. İki çağıran: emin GIRDI (olayın kendisi) ve
-- köprünün kimliğiyle bağlanan plakasız giriş kartı (kartın saati ve
-- kimliği). p_zaman geçersizse (bilet_ac'ın bayat / ileri sınırı) ya da
-- eski bilet kapanamıyorsa hiçbir şey yapmaz, null döner: çağıran eskisi
-- gibi devam eder.
create or replace function public.kamera_yeniden_giris(
  p_eski     uuid,
  p_plaka    text,
  p_islem_id uuid,
  p_zaman    timestamptz,
  p_foto     text,
  p_ham      jsonb
) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_limit_dk integer;
  v_eski     timestamptz;
  v_id       uuid;
begin
  select o.kamera_gecikme_limiti_dk into v_limit_dk
    from public.otopark_ayarlari o where o.id = 1;
  if p_zaman is null
     or p_zaman < now() - make_interval(mins => coalesce(v_limit_dk, 720))
     or p_zaman > now() + interval '5 minutes' then
    return null;
  end if;

  v_eski := public.kamera_eski_bileti_kapat(p_eski, p_zaman);
  if v_eski is null then
    return null;
  end if;

  v_id := public.bilet_ac(p_plaka, p_islem_id, 'KAMERA', p_zaman, p_foto, null, p_ham,
                          null, null, null, 'Kamera: önceki bilet çıkışı görülmeden kapandı');
  perform public.notify_yonetici('KAMERA_HAREKET', 'Çıkışı görülmedi',
    p_plaka || ' yeniden girdi; önceki bileti '
      || to_char(v_eski at time zone 'Europe/Istanbul', 'DD.MM HH24:MI')
      || ' saatinde ödemesiz kapandı (çıkışı görülmedi). Ücreti bilette.',
    '/gise/bilet/' || p_eski);
  return v_id;
end
$fn$;

-- ------------------------------------------------- kamera_giris_karti --
-- F4: bu plakaya bağlanacak, çözülmemiş, plakasız tek kapı giriş kartı.
--   'KIMLIK'  : yalnızca (a)
--   'CIKTI'   : (a), sonra (b)
--   'ICERIDE' : (a), (b), sonra (c)
-- (a) köprünün verdiği kimlik (p_ham.giris_islem_id) — aynı iz;
-- (b) son 10 saatte tahmini (plakasız kartta) ya da plakası birebir bu
--     plaka olan TEK kart; iki kart eşleşirse hangisi olduğu bilinmez,
--     bağlanmaz; başka bir plakayı almış kart tahminiyle bağlanmaz;
-- (c) 077 E2: son 15 dk'nın kartı — tahmini birebir aynı, sonra bir
--     karakter uzak, sonra boş; eşitse en yenisi.
-- ÇIKTI ipuçlu kart giriş kartı değildir. 10 saat sınırı bilet_ac'ın
-- kamera_gecikme_limiti_dk (720) sınırının altında kalsın diye; ayrıca
-- now()'a göre 11 saat. Bulamazsa boş satır (id null).
create or replace function public.kamera_giris_karti(
  p_plaka    text,
  p_zaman    timestamptz,
  p_islem_id uuid,
  p_ham      jsonb,
  p_mod      text
) returns public.istisnalar
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_k      public.istisnalar;
  v_kimlik uuid;
  v_n      integer;
begin
  -- Bozuk kimlik yok sayılır; CASE sırayı garanti eder (önce biçim, sonra cast).
  v_kimlik := case
    when jsonb_typeof(p_ham) = 'object'
         and (p_ham ->> 'giris_islem_id')
             ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then (p_ham ->> 'giris_islem_id')::uuid
  end;

  -- (a)
  if v_kimlik is not null and v_kimlik is distinct from p_islem_id then
    select * into v_k from public.istisnalar i
     where i.islem_id = v_kimlik
       and i.tur::text = 'OKUNAMADI' and i.yon = 'ORTAK' and i.kaynak::text = 'KAMERA'
       and i.cozuldu_at is null
       and (i.plaka is null or i.plaka = p_plaka)
       and coalesce(i.ham_yanit ->> 'hareket', 'GIRDI') = 'GIRDI'
       and i.kaynak_zaman between p_zaman - interval '10 hours' and p_zaman
       and i.kaynak_zaman > now() - interval '11 hours';
    if found then
      return v_k;
    end if;
  end if;
  if p_mod = 'KIMLIK' then
    return v_k;
  end if;

  -- (b)
  select count(*) into v_n from public.istisnalar i
   where i.tur::text = 'OKUNAMADI' and i.yon = 'ORTAK' and i.kaynak::text = 'KAMERA'
     and i.cozuldu_at is null
     and i.islem_id is distinct from p_islem_id
     and coalesce(i.ham_yanit ->> 'hareket', 'GIRDI') = 'GIRDI'
     and i.kaynak_zaman between p_zaman - interval '10 hours' and p_zaman
     and i.kaynak_zaman > now() - interval '11 hours'
     and ((i.plaka is null and public.normalize_plaka(i.ham_yanit ->> 'tahmin') = p_plaka)
          or i.plaka = p_plaka);
  if v_n = 1 then
    select * into v_k from public.istisnalar i
     where i.tur::text = 'OKUNAMADI' and i.yon = 'ORTAK' and i.kaynak::text = 'KAMERA'
       and i.cozuldu_at is null
       and i.islem_id is distinct from p_islem_id
       and coalesce(i.ham_yanit ->> 'hareket', 'GIRDI') = 'GIRDI'
       and i.kaynak_zaman between p_zaman - interval '10 hours' and p_zaman
       and i.kaynak_zaman > now() - interval '11 hours'
       and ((i.plaka is null and public.normalize_plaka(i.ham_yanit ->> 'tahmin') = p_plaka)
            or i.plaka = p_plaka);
    return v_k;
  end if;
  if v_n > 1 or p_mod is distinct from 'ICERIDE' then
    return v_k;
  end if;

  -- (c)
  select * into v_k from public.istisnalar i
   where i.tur::text = 'OKUNAMADI' and i.yon = 'ORTAK' and i.kaynak::text = 'KAMERA'
     and i.cozuldu_at is null and i.plaka is null
     and i.islem_id is distinct from p_islem_id
     and i.kaynak_zaman between p_zaman - interval '15 minutes' and p_zaman
     and coalesce(i.ham_yanit ->> 'hareket', 'GIRDI') = 'GIRDI'
     and (nullif(btrim(coalesce(i.ham_yanit ->> 'tahmin', '')), '') is null
          or public.normalize_plaka(i.ham_yanit ->> 'tahmin') = p_plaka
          or public.plaka_yakin(public.normalize_plaka(i.ham_yanit ->> 'tahmin'), p_plaka))
   order by case
              when public.normalize_plaka(i.ham_yanit ->> 'tahmin') = p_plaka then 0
              when nullif(btrim(coalesce(i.ham_yanit ->> 'tahmin', '')), '') is null then 2
              else 1
            end,
            i.kaynak_zaman desc, i.created_at desc
   limit 1;
  return v_k;
end
$fn$;

-- ------------------------------------------------ kamera_tahmin_cikis --
-- F1: kural kapandı. İmza ve service_role yetkisi kalır: webhook onu
-- çağırır (index.ts, 077 D), null alır ve kartı her zamanki gibi yazar —
-- Edge Function değişmez.
create or replace function public.kamera_tahmin_cikis(
  p_tahmin   text,
  p_guven    numeric,
  p_islem_id uuid,
  p_zaman    timestamptz,
  p_ham      jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $fn$
begin
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.';
  end if;
  return null;
end
$fn$;

-- ---------------------------------------------------- kamera_tek_kapi --
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
  -- 090
  v_limit_dk  integer;
  v_k         public.istisnalar;
  v_bilet     uuid;
  v_aday      public.biletler;
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

  select o.tek_kapi_giris_yoksay_dk, o.tek_kapi_cikis_yoksay_dk, o.kamera_gecikme_limiti_dk
    into v_giris_dk, v_cikis_dk, v_limit_dk
    from public.otopark_ayarlari o where o.id = 1;
  v_giris_dk := coalesce(v_giris_dk, 3);
  v_cikis_dk := coalesce(v_cikis_dk, 5);
  v_limit_dk := coalesce(v_limit_dk, 720);

  <<karar>>
  begin
    -- 056 — İ. Köprü aracı otoparkın İÇİNDE gezerken gördü (giriş de çıkış da
    --    değil). Biletli araç asla kapatılmaz. 090: bileti olmayana bilet
    --    açılır (giriş kartından ya da görüldüğü andan, F4 / F6).
    if v_hareket = 'ICERIDE' then
      -- Açık bileti var: içerideki biletli araç — hiçbir şey.
      select * into v_b from public.biletler b
       where b.durum = 'ACIK' and b.plaka = v_plaka;
      if found then
        -- 090 F4: aynı izin plakasız giriş kartı (yalnızca köprünün verdiği
        --    kimlikle). Bilet karttan en çok 15 dk önce açıldıysa aynı
        --    ziyaret: kart çözülür. Daha eskiyse araç çıkışı görülmeden
        --    yeniden girmiştir: F2 kartın saati ve kimliğiyle (eski bilet
        --    içeride en son görüldüğü anda kapanır — o saat aşağıda
        --    güncellenmeden önce). Kapanamazsa kart insana açık kalır.
        v_k := public.kamera_giris_karti(v_plaka, p_zaman, p_islem_id, p_ham, 'KIMLIK');
        if v_k.id is not null and v_b.giris_at < v_k.kaynak_zaman - interval '15 minutes' then
          v_id := public.kamera_yeniden_giris(v_b.id, v_plaka, v_k.islem_id, v_k.kaynak_zaman,
                                              v_k.foto_path, p_ham);
          if v_id is not null then
            update public.biletler set iceride_goruldu_at = p_zaman
             where id = v_id and durum = 'ACIK';
            update public.istisnalar
               set plaka = coalesce(plaka, v_plaka),
                   cozuldu_at = now(),
                   cozum_notu = 'Kamera: plaka içeride okundu, bilet açıldı: ' || v_plaka
             where id = v_k.id and cozuldu_at is null;
            v_sonuc := jsonb_build_object('karar', 'GIRIS', 'bilet_id', v_id,
                                          'sebep', 'ESKI_BILET_KAPANDI');
            exit karar;
          end if;
        elsif v_k.id is not null then
          update public.istisnalar
             set plaka = coalesce(plaka, v_plaka),
                 cozuldu_at = now(),
                 cozum_notu = 'Kamera: aynı araç içeride okundu, bileti var: ' || v_plaka
           where id = v_k.id and cozuldu_at is null;
        end if;
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
      -- 089: Personel ödemeyi aldı, bileti kapattı; müşteri arabasına
      --      yürüyor, araç hâlâ içeride. Ödenmiş bilet bekliyor: kart yok.
      --      Çıkış kaydı yazılmaz (araç henüz çıkmadı).
      v_id := public.odenmis_cikis(v_plaka, p_zaman, p_islem_id, false);
      if v_id is not null then
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', v_id, 'sebep', 'ODENMIS_ICERIDE');
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
      -- 090 F4 (sahibin kararı 28.11; 077 E2'nin yerine): plakası okunamayan
      --    giriş kartı bu araca bağlanırsa bilet KARTIN saatinden ve
      --    kimliğiyle açılır (kartın fotoğrafı giriş fotoğrafı olur), kart
      --    sistemce çözülür. 077'de kart yalnızca plakayı alıp açık kalırdı.
      v_k := public.kamera_giris_karti(v_plaka, p_zaman, p_islem_id, p_ham, 'ICERIDE');
      if v_k.id is not null then
        v_id := public.bilet_ac(v_plaka, v_k.islem_id, 'KAMERA', v_k.kaynak_zaman, v_k.foto_path,
                                null, p_ham, null, null, null, 'Kamera: giriş kartından açıldı');
        if v_id is not null then
          update public.istisnalar
             set plaka = coalesce(plaka, v_plaka),
                 cozuldu_at = now(),
                 cozum_notu = 'Kamera: plaka içeride okundu, bilet açıldı: ' || v_plaka
           where id = v_k.id and cozuldu_at is null;
          v_sonuc := jsonb_build_object('karar', 'GIRIS', 'bilet_id', v_id, 'sebep', 'GIRIS_KARTI');
          exit karar;
        end if;
        -- Kartın saati bayat çıktı: bilet_ac kaydını yazamadı (kartın
        -- islem_id'si zaten var). Aşağıda görüldüğü andan açılır.
      end if;
      -- 090 F6 (sahibin kararı 28.11; ICERIDE_BILETSIZ kartının yerine):
      --    içeride görülen, bileti ve giriş kartı olmayan araç — bilet
      --    açılır, işaretlenir, Yönetici bilgilenir. Saat: 1.4.6'dan kalan
      --    açık "İçeride, bileti yok" kartı varsa onun saati (kart çözülür),
      --    yoksa bu görülme.
      select * into v_k from public.istisnalar i
       where i.plaka = v_plaka and i.tur::text = 'ICERIDE_BILETSIZ' and i.cozuldu_at is null
         and i.kaynak_zaman between p_zaman - interval '10 hours' and p_zaman
         and i.kaynak_zaman > now() - interval '11 hours'
         and i.kaynak_zaman >= now() - make_interval(mins => v_limit_dk)   -- bilet_ac'ın sınırı
       order by i.kaynak_zaman
       limit 1;
      v_id := public.bilet_ac(v_plaka, p_islem_id, 'KAMERA', coalesce(v_k.kaynak_zaman, p_zaman),
                              coalesce(v_k.foto_path, p_foto), null, p_ham, null, null, null,
                              'Kamera: girişi görülmedi, içeride görüldü');
      if v_id is null then
        -- Saati bayat ya da ileri tarihli; bilet_ac kaydını yazdı.
        v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'ZAMAN');
        exit karar;
      end if;
      if v_k.id is not null then
        update public.istisnalar
           set cozuldu_at = now(),
               cozum_notu = 'Kamera: içeride yeniden görüldü, bilet açıldı'
         where id = v_k.id and cozuldu_at is null;
      end if;
      perform public.notify_yonetici('KAMERA_HAREKET', 'Girişi görülmedi',
        v_plaka || ' — kamera girişini görmedi, araç içeride görüldü; bilet '
          || to_char(coalesce(v_k.kaynak_zaman, p_zaman) at time zone 'Europe/Istanbul',
                     'DD.MM HH24:MI')
          || ' saatinden açıldı.',
        '/gise/bilet/' || v_id);
      v_sonuc := jsonb_build_object('karar', 'GIRIS', 'bilet_id', v_id, 'sebep', 'ICERIDE_GORULDU');
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
      -- 090 F4: çıkan (ya da yönü bilinmeyen) aracın, köprünün kimliğiyle
      --    bağlanan plakasız giriş kartı var. Bilet karttan en çok 15 dk önce
      --    açıldıysa aynı ziyaret: kart çözülür, bilet aşağıda (1b) kapanır.
      --    Daha eskiyse araç çıkışı görülmeden yeniden girmişti: eski bilet
      --    kapanır, yenisi kartın saatinden açılıp bu çıkışla kapanır.
      --    İleri tarihli olayda yapılmaz (açılan bilet kapanamazdı).
      if v_hareket is distinct from 'GIRDI' and p_zaman <= now() + interval '5 minutes' then
        v_k := public.kamera_giris_karti(v_plaka, p_zaman, p_islem_id, p_ham, 'KIMLIK');
        if v_k.id is not null and v_b.giris_at < v_k.kaynak_zaman - interval '15 minutes' then
          v_bilet := public.kamera_yeniden_giris(v_b.id, v_plaka, v_k.islem_id, v_k.kaynak_zaman,
                                                 v_k.foto_path, p_ham);
          if v_bilet is not null then
            v_id := public.kamera_cikis_bildir(v_plaka, p_islem_id, p_zaman, p_foto, p_ham);
            update public.istisnalar
               set plaka = coalesce(plaka, v_plaka),
                   cozuldu_at = now(),
                   cozum_notu = 'Kamera: plaka çıkışta okundu, bilet açılıp kapandı: ' || v_plaka
             where id = v_k.id and cozuldu_at is null;
            if v_id is null then
              v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'ZAMAN');
              exit karar;
            end if;
            v_sonuc := jsonb_build_object('karar', 'CIKIS', 'bilet_id', v_id, 'sebep', 'GIRIS_KARTI');
            exit karar;
          end if;
        elsif v_k.id is not null then
          update public.istisnalar
             set plaka = coalesce(plaka, v_plaka),
                 cozuldu_at = now(),
                 cozum_notu = 'Kamera: aynı araç çıktı, bileti var: ' || v_plaka
           where id = v_k.id and cozuldu_at is null;
        end if;
      end if;
      -- 056: köprü aracı GİRERKEN gördü ama eski açık bileti var.
      if v_hareket = 'GIRDI' then
        -- 090 F2 (sahibin kararı 28.11): araç çıkmış, çıkışı görülmemiş,
        --    şimdi yeniden giriyor. Eski bilet içeride en son görüldüğü
        --    saatte (yoksa kendi giriş saatinde) ödemesiz kapanır, Yönetici
        --    bilgilenir, yeni bilet açılır (kamera_yeniden_giris). Olayın
        --    saati geçersizse ya da eski bilet kapanamazsa 056 gibi insana.
        v_id := public.kamera_yeniden_giris(v_b.id, v_plaka, p_islem_id, p_zaman, p_foto, p_ham);
        if v_id is not null then
          v_sonuc := jsonb_build_object('karar', 'GIRIS', 'bilet_id', v_id,
                                        'sebep', 'ESKI_BILET_KAPANDI');
          exit karar;
        end if;
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

    -- 2a. 089 (sahip 28.11, çıkış fişi): Personel ödemeyi aldı ve bileti
    --     kapattı; araç dakikalar sonra kapıdan çıkıyor. Ödenmiş bilete
    --     bağlanır (yeni bilet açılmaz); uyarı süresini aşan gecikme Dikkat'e
    --     yazılır. Köprü aracı GİRERKEN gördüyse bu yeni bir ziyarettir.
    if v_hareket is distinct from 'GIRDI' then
      v_id := public.odenmis_cikis(v_plaka, p_zaman, p_islem_id, true);
      if v_id is not null then
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', v_id, 'sebep', 'ODENMIS_CIKIS');
        exit karar;
      end if;
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

    -- 090 F4: ÇIKAN, bileti olmayan aracın köprünün kimliğiyle bağlanan
    --    plakasız giriş kartı (aynı iz). Bu bağ benzer aramasından (adım 3,
    --    4) güçlüdür: bulunursa o adımlar atlanır ve bilet aşağıda karttan
    --    açılır. Yalnızca tahmine dayanan bağ (b) ise adım 4'ten SONRA
    --    denenir — elle açılmış gerçek bilete benzer bir yanlış okuma
    --    hayalet bilet açmasın. İleri tarihli olayda hiçbiri.
    v_k := null;
    if v_hareket = 'CIKTI' and p_zaman <= now() + interval '5 minutes' then
      v_k := public.kamera_giris_karti(v_plaka, p_zaman, p_islem_id, p_ham, 'KIMLIK');
    end if;

    -- 3. Tam eşleşme yok ama içerideki bir araca BİR KARAKTER uzak.
    select array_agg(b.id order by b.created_at),
           bool_or(p_zaman <= least(b.kaynak_zaman, b.created_at)
                              + make_interval(mins => v_giris_dk))   -- 048
      into v_adaylar, v_yeni
      from public.biletler b
     where b.durum = 'ACIK' and public.plaka_yakin(b.plaka, v_plaka);

    if v_adaylar is not null and v_k.id is null then
      -- 3a. Benzeri az önce girdi: aynı aracın ikinci, farklı okunmuş karesi.
      if v_yeni then
        v_sonuc := jsonb_build_object('karar', 'YOKSAY', 'bilet_id', null,
                                      'sebep', 'YENI_GIRIS_BENZER');
        exit karar;
      end if;
      -- 090 F3 (sahibin kararı 28.11): köprü aracı ÇIKARKEN gördü, içeride
      --    TEK benzer bilet var ve fark sık karışan bir harf çifti: o araç.
      --    Bilet her kamera çıkışı gibi kapanır; denetim kaydı okunanı taşır.
      if v_hareket = 'CIKTI' and cardinality(v_adaylar) = 1 then
        select * into v_aday from public.biletler b where b.id = v_adaylar[1];
        if public.plaka_harf_karisir(v_plaka, v_aday.plaka) then
          v_id := public.kamera_cikis_bildir(v_aday.plaka, p_islem_id, p_zaman, p_foto, p_ham);
          if v_id is null then
            v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'ZAMAN');
            exit karar;
          end if;
          perform public.audit('kamera_benzer_harf', 'biletler', v_id,
            jsonb_build_object('okunan', v_plaka, 'bilet_plaka', v_aday.plaka,
                               'islem_id', p_islem_id, 'zaman', p_zaman));
          v_sonuc := jsonb_build_object('karar', 'CIKIS', 'bilet_id', v_id, 'sebep', 'BENZER_HARF');
          exit karar;
        end if;
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
    --    090: köprünün kimliğiyle bağlanan kart varsa atlanır (yukarıda).
    if v_k.id is null and exists (
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

    -- 090 F4: bilet kartın saatinden ve kimliğiyle açılır, hemen kamera
    --    çıkışı gibi kapanır (ödemesiz), kart çözülür. Kart: yukarıdaki
    --    kimlik bağı ya da şimdi tahmin bağı (son 10 saatte tahmini
    --    birebir bu plaka olan TEK plakasız kart).
    if v_hareket = 'CIKTI' and p_zaman <= now() + interval '5 minutes' then
      if v_k.id is null then
        v_k := public.kamera_giris_karti(v_plaka, p_zaman, p_islem_id, p_ham, 'CIKTI');
      end if;
      if v_k.id is not null then
        v_bilet := public.bilet_ac(v_plaka, v_k.islem_id, 'KAMERA', v_k.kaynak_zaman, v_k.foto_path,
                                   null, p_ham, null, null, null, 'Kamera: giriş kartından açıldı');
        if v_bilet is not null then
          v_id := public.kamera_cikis_bildir(v_plaka, p_islem_id, p_zaman, p_foto, p_ham);
          update public.istisnalar
             set plaka = coalesce(plaka, v_plaka),
                 cozuldu_at = now(),
                 cozum_notu = 'Kamera: plaka çıkışta okundu, bilet açılıp kapandı: ' || v_plaka
           where id = v_k.id and cozuldu_at is null;
          if v_id is null then
            v_sonuc := jsonb_build_object('karar', 'ISTISNA', 'bilet_id', null, 'sebep', 'ZAMAN');
            exit karar;
          end if;
          v_sonuc := jsonb_build_object('karar', 'CIKIS', 'bilet_id', v_id, 'sebep', 'GIRIS_KARTI');
          exit karar;
        end if;
      end if;
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

-- --------------------------------------------------- kamera_okunamadi --
-- 041'deki gövde; tek fark "090" bloğu.
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
  -- 090
  v_kimlik uuid;
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

  -- 090 F4: kısa ziyaret — aynı iz (köprü 1.4.7'nin giris_islem_id'si)
  --    plakasız girdi, şimdi yine plakasız: giriş kartı sistemce çözülür,
  --    personelin önünde tek kart (bu) kalır. Bozuk kimlik yok sayılır.
  v_kimlik := case
    when v_yon = 'ORTAK' and jsonb_typeof(p_ham) = 'object'
         and (p_ham ->> 'giris_islem_id')
             ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then (p_ham ->> 'giris_islem_id')::uuid
  end;
  if v_kimlik is not null and v_kimlik <> p_islem_id then
    update public.istisnalar i
       set cozuldu_at = now(),
           cozum_notu = 'Kamera: aynı araç çıktı, plaka okunamadı'
     where i.islem_id = v_kimlik
       and i.tur::text = 'OKUNAMADI' and i.yon = 'ORTAK' and i.kaynak::text = 'KAMERA'
       and i.cozuldu_at is null and i.plaka is null
       and i.kaynak_zaman between p_zaman - interval '10 hours' and p_zaman;
  end if;

  v_ham := case when jsonb_typeof(p_ham) = 'object'
                then p_ham - 'foto_base64' else '{}'::jsonb end
        || jsonb_build_object('tahmin', left(nullif(btrim(p_tahmin), ''), 32),
                              'guven', p_guven);

  return public.istisna_yaz('OKUNAMADI', v_yon, null, 'KAMERA', p_islem_id,
                            v_ham, null, p_zaman);
end
$fn$;

-- ---------------------------------------------------------------- yetki --
-- Yeni yardımcılar kimseye açık değil (yalnızca yukarıdaki SECURITY DEFINER
-- fonksiyonlar çağırır). Yeniden yazılan üç kamera fonksiyonu yalnızca
-- webhook'a (service_role) — create or replace yetkiyi korur, yine de
-- yeniden verilir ve aşağıda denetlenir.
revoke all on function public.plaka_harf_karisir(text, text) from public;
revoke all on function public.plaka_harf_karisir(text, text) from anon, authenticated, service_role;
revoke all on function public.kamera_eski_bileti_kapat(uuid, timestamptz) from public;
revoke all on function public.kamera_eski_bileti_kapat(uuid, timestamptz)
  from anon, authenticated, service_role;
revoke all on function public.kamera_giris_karti(text, timestamptz, uuid, jsonb, text) from public;
revoke all on function public.kamera_giris_karti(text, timestamptz, uuid, jsonb, text)
  from anon, authenticated, service_role;
revoke all on function public.kamera_yeniden_giris(uuid, text, uuid, timestamptz, text, jsonb) from public;
revoke all on function public.kamera_yeniden_giris(uuid, text, uuid, timestamptz, text, jsonb)
  from anon, authenticated, service_role;

revoke all on function public.kamera_tahmin_cikis(text, numeric, uuid, timestamptz, jsonb) from public;
revoke all on function public.kamera_tahmin_cikis(text, numeric, uuid, timestamptz, jsonb)
  from anon, authenticated, service_role;
grant execute on function public.kamera_tahmin_cikis(text, numeric, uuid, timestamptz, jsonb)
  to service_role;
revoke all on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text) from public;
revoke all on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)
  from anon, authenticated, service_role;
grant execute on function public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)
  to service_role;
revoke all on function public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb) from public;
revoke all on function public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)
  from anon, authenticated, service_role;
grant execute on function public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)
  to service_role;

-- ------------------------------------------------------------ doğrulama --
do $do$
declare
  f text;
  r text;
begin
  foreach f in array array[
    'public.plaka_harf_karisir(text, text)',
    'public.kamera_eski_bileti_kapat(uuid, timestamptz)',
    'public.kamera_giris_karti(text, timestamptz, uuid, jsonb, text)',
    'public.kamera_yeniden_giris(uuid, text, uuid, timestamptz, text, jsonb)'
  ] loop
    foreach r in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception 'DOĞRULAMA: % % rolüne açık — kimseye açık olmamalı.', f, r;
      end if;
    end loop;
  end loop;

  foreach f in array array[
    'public.kamera_tahmin_cikis(text, numeric, uuid, timestamptz, jsonb)',
    'public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)',
    'public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)'
  ] loop
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception 'DOĞRULAMA: % service_role rolüne kapalı — webhook çağıramaz.', f;
    end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception 'DOĞRULAMA: % % rolüne açık.', f, r;
      end if;
    end loop;
  end loop;

  -- Eski imza kalmasın (yanlış imzayla create, ikinci bir fonksiyon olurdu).
  foreach f in array array['kamera_tek_kapi', 'kamera_okunamadi', 'kamera_tahmin_cikis'] loop
    if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = f) <> 1 then
      raise exception 'DOĞRULAMA: % tek imzayla durmuyor.', f;
    end if;
  end loop;

  -- 041 / 059: iki fonksiyon aynı tek kapı kilidini alır (smoke PASS 63g).
  if position('pg_advisory_xact_lock(hashtext(''kamera_tek_kapi''))' in
              pg_get_functiondef('public.kamera_tek_kapi(text, uuid, timestamptz, text, jsonb, text)'::regprocedure)) = 0
     or position('pg_advisory_xact_lock(hashtext(''kamera_tek_kapi''))' in
              pg_get_functiondef('public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)'::regprocedure)) = 0 then
    raise exception 'DOĞRULAMA: tek kapı kilidi kayıp.';
  end if;

  if not public.plaka_harf_karisir('34ACO11', '34ACD11')
     or public.plaka_harf_karisir('34ACK11', '34ACX11') then
    raise exception 'DOĞRULAMA: plaka_harf_karisir yanlış.';
  end if;
end
$do$;

commit;
