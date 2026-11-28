-- =====================================================================
-- 089  Ödeyip sonra çıkan araç
-- =====================================================================
begin;

-- Sahip 28.11 (çıkış fişi): "Personel çıkış fişini müşteri arabasına
-- binmeden verir." Ödeme alınır, bilet kapanır, araç 10-40 dk sonra çıkar.
-- Bugüne kadar:
--   * tek kapı (077, adım 2): kapanıştan sonraki `tek_kapi_cikis_yoksay_dk`
--     (varsayılan 5) geçince aynı araca YENİ GİRİŞ bileti açılıyordu;
--   * iki kapı (078, kamera_cikis_bildir): "açık bilet yok" kaydı yazılıyordu.
-- Artık Personelin kapattığı (kamera değil) bilet, kapanıştan sonraki
-- `odeme_sonrasi_cikis_dk` (varsayılan 120) boyunca "ödendi, çıkışı
-- bekliyor" sayılır. Kamera onu görünce o bilete bağlar ve çıkış anını
-- `odenmis_kapi_cikislari`na yazar; gecikme `gec_cikis_uyari_dk`'yı
-- (varsayılan 15) aşarsa Dikkat'e bir satır (audit `odeme_sonrasi_gec_cikis`).
-- Fişe süre yazılmaz (sahip: "No grace on the fiş but a dikkat note is ok").
-- Para hiçbir yerde değişmez.
--
-- İki kamera fonksiyonu 077 / 078'deki son halleriyle BİREBİR yeniden
-- yazılır; tek fark "089" yorumlu bloklar.

do $$
begin
  if to_regprocedure('public.fis_basildi(uuid, text, integer)') is null then
    raise exception '089: önce 088 çalıştırılmalı.';
  end if;
end $$;

-- ------------------------------------------------------------- ayarlar --
alter table public.otopark_ayarlari
  add column if not exists odeme_sonrasi_cikis_dk integer not null default 120
    constraint otopark_ayarlari_odeme_sonrasi_cikis_ck check (odeme_sonrasi_cikis_dk between 15 and 360),
  add column if not exists gec_cikis_uyari_dk integer not null default 15
    constraint otopark_ayarlari_gec_cikis_uyari_ck check (gec_cikis_uyari_dk between 5 and 120);

-- ------------------------------------------------ odenmis_kapi_cikislari --
create table public.odenmis_kapi_cikislari (
  bilet_id   uuid primary key references public.biletler(id) on delete cascade,
  gorulme_at timestamptz not null,
  gecikme_dk integer not null,
  islem_id   uuid,
  created_at timestamptz not null default now()
);
revoke all on public.odenmis_kapi_cikislari from public, anon, authenticated, service_role;
grant select on public.odenmis_kapi_cikislari to authenticated;
alter table public.odenmis_kapi_cikislari enable row level security;
create policy odenmis_kapi_cikislari_select on public.odenmis_kapi_cikislari
  for select to authenticated using (public.is_yonetici());

-- ---------------------------------------------------------- odenmis_cikis --
-- Bu plakanın Personelce kapatılmış, kapanıştan bu yana pencere içindeki
-- son bileti. Çıkışı zaten kaydedildiyse yalnızca aynı çıkışın tekrar
-- kareleri (aynı çıkış penceresi) ona bağlanır; sonrası yeni ziyarettir.
-- p_kaydet: kapıda görüldü (çıkış yaz) / içeride görüldü (yalnızca bak).
-- Kimseye açık değil: yalnızca kamera fonksiyonları çağırır.
create or replace function public.odenmis_cikis(
  p_plaka text, p_zaman timestamptz, p_islem_id uuid, p_kaydet boolean
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_pencere integer;
  v_cikis_dk integer;
  v_uyari   integer;
  v_b       public.biletler;
  v_gorulme timestamptz;
  v_gecikme integer;
begin
  select o.odeme_sonrasi_cikis_dk, o.tek_kapi_cikis_yoksay_dk, o.gec_cikis_uyari_dk
    into v_pencere, v_cikis_dk, v_uyari
    from public.otopark_ayarlari o where o.id = 1;
  v_cikis_dk := coalesce(v_cikis_dk, 5);
  v_pencere  := greatest(coalesce(v_pencere, 120), v_cikis_dk);
  v_uyari    := coalesce(v_uyari, 15);

  select * into v_b from public.biletler b
   where b.plaka = p_plaka and b.durum = 'KAPALI'
     and b.cikis_kaynak::text <> 'KAMERA'
     and p_zaman >= b.cikis_at
     and p_zaman <= b.cikis_at + make_interval(mins => v_pencere)
   order by b.cikis_at desc
   limit 1;
  if not found then
    return null;
  end if;

  select k.gorulme_at into v_gorulme
    from public.odenmis_kapi_cikislari k where k.bilet_id = v_b.id;
  if found then
    return case when p_zaman <= v_gorulme + make_interval(mins => v_cikis_dk) then v_b.id end;
  end if;

  if not p_kaydet then
    return v_b.id;
  end if;

  v_gecikme := floor(extract(epoch from (p_zaman - v_b.cikis_at)) / 60)::integer;
  insert into public.odenmis_kapi_cikislari (bilet_id, gorulme_at, gecikme_dk, islem_id)
  values (v_b.id, p_zaman, v_gecikme, p_islem_id)
  on conflict (bilet_id) do nothing;
  if found and v_gecikme > v_uyari then
    perform public.audit('odeme_sonrasi_gec_cikis', 'biletler', v_b.id,
                         jsonb_build_object('dk', v_gecikme, 'odeme_at', v_b.cikis_at,
                                            'cikis_at', p_zaman));
  end if;
  return v_b.id;
end $$;

revoke all on function public.odenmis_cikis(text, timestamptz, uuid, boolean)
  from public, anon, authenticated, service_role;

-- ------------------------------------------------- kamera_cikis_bildir --
-- 078'deki gövde; tek fark "089" bloğu ("açık bilet yok"tan önce).
create or replace function public.kamera_cikis_bildir(
  p_plaka    text,
  p_islem_id uuid,
  p_zaman    timestamptz,
  p_foto     text default null,
  p_ham      jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plaka    text;
  v_limit_dk integer;
  v_id       uuid;
  v_adaylar  uuid[];
  v_kuyruk   text;
  v_b        public.biletler;
  v_ucret    integer;
  v_net      integer;
  v_vardiya  uuid;
  v_sebep    text;
  v_cikis_dk integer;
begin
  -- 054: yalnızca kamera (eskiden `is_staff() or auth.uid() is null`).
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_zaman is null then
    raise exception 'Kamera kaydı zaman damgası olmadan kabul edilmez.';
  end if;

  v_plaka := public.normalize_plaka(p_plaka);

  -- 054: tek kapının "çıkıştan sonra" süresi (048) burada da aynı çıkışın
  -- penceresidir: tekrar gelen çıkış ve az önce geri açılan bilet.
  select o.kamera_gecikme_limiti_dk, o.tek_kapi_cikis_yoksay_dk
    into v_limit_dk, v_cikis_dk
    from public.otopark_ayarlari o where o.id = 1;
  v_limit_dk := coalesce(v_limit_dk, 720);
  v_cikis_dk := coalesce(v_cikis_dk, 5);

  if p_zaman > now() + interval '5 minutes' then
    perform public.istisna_yaz('GELECEK', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                               p_ham, p_foto, p_zaman);
    return null;
  end if;
  if p_zaman < now() - make_interval(mins => v_limit_dk) then
    perform public.istisna_yaz('BAYAT', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                               p_ham, p_foto, p_zaman);
    return null;
  end if;

  select b.id into v_id from public.biletler b
   where b.durum = 'ACIK' and b.plaka = v_plaka;

  if v_id is null then
    -- 054: aynı çıkış yeniden geldi (iki şeritli CIKIS kapısı: cevap kayboldu
    -- ve köprü tekrar gönderdi, ya da aynı aracın ikinci karesi). Bilet zaten
    -- kameranın kapattığı; "açık bilet yok" kaydı ve uyarısı yanlış olurdu.
    -- Tek kapı bunu 2. adımında zaten yok sayar (048) — aynı pencere.
    select b.id into v_id from public.biletler b
     where b.plaka = v_plaka and b.durum = 'KAPALI' and b.cikis_kaynak = 'KAMERA'
       and p_zaman between b.cikis_at - make_interval(mins => v_cikis_dk)
                       and b.cikis_at + make_interval(mins => v_cikis_dk)
     order by b.cikis_at desc
     limit 1;
    if v_id is not null then
      return v_id;
    end if;

    -- 089: Personelin ödemesini alıp kapattığı bilet; araç şimdi çıkıyor.
    v_id := public.odenmis_cikis(v_plaka, p_zaman, p_islem_id, true);
    if v_id is not null then
      return v_id;
    end if;

    v_kuyruk := right(v_plaka, 4);
    if length(v_kuyruk) = 4 then
      select array_agg(b.id) into v_adaylar from public.biletler b
       where b.durum = 'ACIK' and right(b.plaka, 4) = v_kuyruk;
    end if;

    if v_adaylar is null or array_length(v_adaylar, 1) is null then
      perform public.istisna_yaz('ACIK_BILET_YOK', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                                 p_ham, p_foto, p_zaman);
      return null;
    end if;
    -- 054: benzer plaka tahmin edilmez — tek aday da olsa insana gider.
    perform public.istisna_yaz('COKLU_ESLESME', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                               p_ham, p_foto, p_zaman, v_adaylar);
    return null;
  end if;

  -- 054: bileti kapat (ödemesiz). Ücret 030'un `bilet_kapat` kuralıyla aynı,
  -- yalnızca saat OLAYIN saati.
  select * into v_b from public.biletler where id = v_id for update;
  -- Kilidi beklerken biri bileti kapattı ya da iptal etti: 002'deki gibi
  -- hiçbir şey yazılmaz (ne denetim ne "ödeme bekliyor" bildirimi).
  if v_b.durum <> 'ACIK' then
    return v_id;
  end if;

  -- Kapatılamayan çıkışlar ÖNCE: ucret_hesapla girişten önceki bir çıkışta
  -- hata verir ("Çıkış zamanı girişten önce olamaz") ve tüm olayı düşürürdü.
  if p_zaman < v_b.giris_at then
    v_sebep := 'çıkış saati girişten önce';
  elsif exists (select 1 from public.audit_log a
                 where a.tablo = 'biletler' and a.row_id = v_id
                   and a.action = 'bilet_kamera_geri_acildi'
                   and a.created_at >= p_zaman - make_interval(mins => v_cikis_dk)) then
    -- Personel az önce "Araç çıkmadı" dedi; araç hâlâ kameranın önünde
    -- olabilir. Kamera aynı anda tersini söyleyemez: insan karar verir.
    v_sebep := 'az önce "Araç çıkmadı" denildi';
  else
    -- 078: otopark (abonmanda 0) + oto yıkama, tek yerden.
    v_ucret := public.bilet_ucreti(v_b, p_zaman);
    if v_b.indirim_kurus > v_ucret then
      v_sebep := 'kullanılan puan ücretten fazla';
    end if;
  end if;

  if v_sebep is not null then
    -- Kapatılamaz: eskisi gibi yalnızca damga; insan karar verir.
    update public.biletler
       set cikis_bekliyor_at = p_zaman, cikis_foto = coalesce(cikis_foto, p_foto)
     where id = v_id and durum = 'ACIK';
    perform public.notify_yonetici('KAMERA_HAREKET', 'Araç çıkış yaptı',
      v_b.plaka || ' — bilet kendiliğinden kapatılamadı (' || v_sebep
        || '); çıkışı elle yapın.',
      '/gise/bilet/' || v_id);
    return v_id;
  end if;

  v_net := v_ucret - v_b.indirim_kurus;

  -- Açık kasa vardiyası (030: kasa başına tek). `acik_vardiyam()` burada
  -- kullanılamaz: is_staff() ister, kamerada auth.uid() boştur.
  select v.id into v_vardiya from public.vardiyalar v
   where v.kapanis_at is null
   limit 1;

  update public.biletler set
    cikis_at           = p_zaman,
    ucret_kurus        = v_ucret,
    tahsil_kurus       = 0,
    odeme_yontemi      = null,
    durum              = 'KAPALI',
    cikis_by           = null,
    cikis_kaynak       = 'KAMERA',
    cikis_foto         = coalesce(p_foto, v_b.cikis_foto),
    cikis_bekliyor_at  = p_zaman,
    kapatan_vardiya_id = v_vardiya
  where id = v_id and durum = 'ACIK';

  perform public.audit('bilet_kamera_kapatti', 'biletler', v_id,
    jsonb_build_object('plaka', v_b.plaka, 'ucret', v_ucret, 'borc', v_net,
                       'zaman', p_zaman, 'vardiya', v_vardiya));

  if v_net > 0 then
    if v_vardiya is not null then
      perform public.notify_herkes('ODEME_BEKLIYOR', 'Araç çıktı — ödeme bekliyor',
        v_b.plaka || ' · ' || (v_net / 100.0)::numeric(12,2) || ' ₺',
        '/gise/bilet/' || v_id);
    else
      perform public.notify_yonetici('ODEME_BEKLIYOR', 'Araç çıktı — ödeme bekliyor',
        v_b.plaka || ' · ' || (v_net / 100.0)::numeric(12,2)
          || ' ₺ (açık vardiya yoktu)',
        '/gise/bilet/' || v_id);
    end if;
  end if;

  return v_id;
end $$;

-- ----------------------------------------------------- kamera_tek_kapi --
-- 077'deki gövde; tek fark iki "089" bloğu (içeride bekleyen, adım 2a).
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

do $do$
begin
  if has_function_privilege('anon', 'public.odenmis_cikis(text, timestamptz, uuid, boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.odenmis_cikis(text, timestamptz, uuid, boolean)', 'execute')
     or has_function_privilege('service_role', 'public.odenmis_cikis(text, timestamptz, uuid, boolean)', 'execute') then
    raise exception 'DOĞRULAMA: odenmis_cikis kimseye açık olmamalı.';
  end if;
  if has_table_privilege('authenticated', 'public.odenmis_kapi_cikislari', 'insert')
     or has_table_privilege('anon', 'public.odenmis_kapi_cikislari', 'select') then
    raise exception 'DOĞRULAMA: odenmis_kapi_cikislari yetkileri fazla.';
  end if;
end
$do$;

commit;
