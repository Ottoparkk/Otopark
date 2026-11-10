-- ============================================================================
-- 054  Kamera çıkan aracın biletini kapatır; ödeme sonra toplanır
-- ============================================================================

begin;

-- Sahibin isteği (2026-11-10): kameranın gördüğü çıkan araç uygulamada
-- "Çıktı" görünmeli. Bugüne kadar kamera bileti KAPATMIYORDU (002:
-- `kamera_cikis_bildir` yalnızca `cikis_bekliyor_at` damgalardı) ve 052'den
-- beri o damga Gişe'de görünmüyordu.
--
-- Yeni akış — paraya dokunmadan, var olan parçalarla:
--   1. Kameranın çıkışı (tek kapı 1b ya da iki şeritli CIKIS kapısı) TAM plaka
--      eşleşmesinde bileti KAPATIR: olayın saatinde, o ana kadarki ücretle
--      (`ucret_hesapla(giris_at, p_zaman)`; abonman 0), ÖDEMESİZ — 027'nin
--      "ödemesiz çıkış" hâli (tahsil 0, tahsilat satırı YOK). Kapatan vardiya
--      = o an açık olan kasa vardiyası (tekil indeks en fazla bir tane
--      garanti eder; yoksa boş).
--   2. Borç varsa HERKES "Ödeme bekliyor" bildirimi alır (vardiya yoksa
--      yalnızca Yönetici — Personel vardiyasız bileti göremez).
--   3. Borç, uygulamada "Çıktı" kayıtlarında "Ödeme topla" ile toplanır:
--      `bilet_tahsil` (034) — yalnızca biletin kapandığı vardiyadaki Personel
--      (sahibin seçimi) ya da Yönetici. Tahsilat ONAY BEKLER (017) ve
--      Onay → "Bilet ve abonman"da Yönetici onaylar ya da reddeder.
--   4. Kamera yanlış kapattıysa (araç kapıda bekleyip çıkmadı) "Araç çıkmadı":
--      `bilet_kamera_geri_ac` bileti geri açar — yalnızca KAMERANIN kapattığı,
--      PARASI ALINMAMIŞ bilet. Kapanmış bilet değişmez kuralına BİLİNÇLİ, dar
--      bir istisna (sahibin kararı): para hiç hareket etmemiştir, iz kalır,
--      Yönetici bilgilenir.
--
-- Güvenlik sınırları:
--   · Benzer plaka (son dört karakter, iki şeritli CIKIS kapısının yedeği)
--     ARTIK HİÇBİR ŞEY YAPMAZ, insana gider (COKLU_ESLESME + adaylar): kamera
--     artık bileti kapatıyor; yanlış biletin kapanması bir aracın çıkışını
--     başka araca yazmak olurdu. Tek aday da olsa.
--   · Kapatılamayan çıkış (kullanılan puan ücretten fazla; olay girişten önce
--     — biletler_cikis_ck; bilet çıkış süresi içinde "Araç çıkmadı" ile geri
--     açılmış) eskisi gibi YALNIZCA damgalanır ve Yönetici uyarılır.
--   · Aynı çıkışın tekrarı (iki şeritli kapı) bileti kameranın az önce
--     kapattığını görür ve hiçbir şey yazmaz — tek kapının 2. adımı gibi.
--   · `kamera_cikis_bildir` artık yalnızca kameranın (auth.uid() boş) —
--     003'ten beri zaten yalnızca service_role'e açık; gövde de aynı şeyi
--     söyler: bir insan geçmiş bir saatle "ucuz çıkış" yazamaz.
--   · Para hiç hareket etmez: kapanış ve geri açma tahsilat yazmaz; gelir
--     raporları yalnızca ONAYLANDI tahsilatları sayar (017).
--
-- 052'nin çıkış bildirimi tetiği (`kamera_cikis_bildirim_tg`) kaldırılır:
-- bildirim artık kapanışın kendisinden gelir, tetik kalsaydı iki bildirim
-- giderdi. Tetik fonksiyonu (019) yerinde kalır.

-- ------------------------------------------------- kamera_cikis_bildir -----
-- 002'nin gövdesi: saat kuralları ve eşleşme sırası BİREBİR; değişenler
-- işaretli (054).

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
    if v_b.abonman_id is not null then
      v_ucret := 0;
    else
      v_ucret := public.ucret_hesapla(v_b.giris_at, p_zaman, v_b.tarife_id);
    end if;
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

-- --------------------------------------- 052'nin çıkış bildirimi tetiği ----

drop trigger if exists kamera_cikis_bildirim_tg on public.biletler;

-- ------------------------------------------------- değişmezlik guard'ı -----
-- 029'un gövdesi BİREBİR; eklenen iki dar bayrak (054):
--   · app.kamera_foto  = bilet id → yalnızca boş `cikis_foto` dolabilir
--     (kameranın BU olayda kapattığı biletin çıkış fotoğrafı, 042 deseni);
--   · app.bilet_geri_ac = bilet id → "Araç çıkmadı" geri açması (koşulları
--     `bilet_kamera_geri_ac` denetler — app.bilet_iptal gibi).

create or replace function public.biletler_immutable_guard() returns trigger
language plpgsql as $fn$
declare
  v_detach text[] := array[
    'park_yeri_id','vardiya_id','kapatan_vardiya_id','abonman_id',
    'giris_by','cikis_by','iptal_by',
    -- photo paths: nulled by the nightly retention purge, never money
    'giris_foto','cikis_foto',
    -- okuma kaydı silinirse referans düşer; para değil
    'plaka_okuma_id'
  ];
  v_old jsonb := to_jsonb(old);
  v_new jsonb := to_jsonb(new);
  v_key text;
begin
  if old.durum = 'ACIK' then
    return new;
  end if;

  if coalesce(current_setting('app.bilet_iptal', true), '') = old.id::text then
    return new;
  end if;

  -- 054: "Araç çıkmadı" — kameranın kapattığı, parası alınmamış bilet.
  if coalesce(current_setting('app.bilet_geri_ac', true), '') = old.id::text then
    return new;
  end if;

  if coalesce(current_setting('app.bilet_tahsil', true), '') = old.id::text then
    v_old := v_old - 'tahsil_kurus' - 'odeme_yontemi';
    v_new := v_new - 'tahsil_kurus' - 'odeme_yontemi';
  end if;

  -- 054: kameranın kapattığı biletin çıkış fotoğrafı — yalnızca boşken.
  if coalesce(current_setting('app.kamera_foto', true), '') = old.id::text
     and old.cikis_foto is null then
    v_old := v_old - 'cikis_foto';
    v_new := v_new - 'cikis_foto';
  end if;

  foreach v_key in array v_detach loop
    if v_new -> v_key <> 'null'::jsonb and v_new -> v_key is distinct from v_old -> v_key then
      raise exception
        'Kapanmış bilet değiştirilemez (bilet %). Düzeltme için karşı kayıt girin.', old.id;
    end if;
    v_old := v_old - v_key;
    v_new := v_new - v_key;
  end loop;

  if v_old = v_new then
    return new;
  end if;

  raise exception
    'Kapanmış bilet değiştirilemez (bilet %). Düzeltme için karşı kayıt girin.', old.id;
end
$fn$;

-- ---------------------------------------------------- kamera_foto_bagla ----
-- 042'nin gövdesi BİREBİR; eklenen tek yol (054): kameranın BU olayda
-- kapattığı bilet (aynı bilet, `cikis_at` = olayın saati, kaynak KAMERA,
-- fotoğraf boş). Eski "kapıda" damgası yolu kalır: kapatılamayan çıkış hâlâ
-- yalnızca damgalanır.

create or replace function public.kamera_foto_bagla(
  p_islem_id uuid,
  p_bilet_id uuid,
  p_zaman    timestamptz,
  p_foto     text
) returns integer
language plpgsql security definer set search_path = public as $fn$
declare
  v_n integer := 0;
  v_k integer;
begin
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;
  if p_foto is distinct from ('kamera/' || p_islem_id::text || '.jpg') then
    raise exception 'Fotoğraf yolu bu kamera olayına ait değil.';
  end if;

  update public.biletler
     set giris_foto = p_foto
   where islem_id = p_islem_id and giris_kaynak = 'KAMERA'
     and durum = 'ACIK' and giris_foto is null;
  get diagnostics v_k = row_count;
  v_n := v_n + v_k;

  update public.istisnalar
     set foto_path = p_foto
   where islem_id = p_islem_id and kaynak = 'KAMERA' and foto_path is null;
  get diagnostics v_k = row_count;
  v_n := v_n + v_k;

  if p_bilet_id is not null and p_zaman is not null then
    update public.biletler
       set cikis_foto = p_foto
     where id = p_bilet_id and durum = 'ACIK'
       and cikis_bekliyor_at = p_zaman and cikis_foto is null;
    get diagnostics v_k = row_count;
    v_n := v_n + v_k;

    -- 054: kameranın bu olayda kapattığı bilet.
    perform set_config('app.kamera_foto', p_bilet_id::text, true);
    update public.biletler
       set cikis_foto = p_foto
     where id = p_bilet_id and durum = 'KAPALI' and cikis_kaynak = 'KAMERA'
       and cikis_at = p_zaman and cikis_foto is null;
    get diagnostics v_k = row_count;
    perform set_config('app.kamera_foto', '', true);
    v_n := v_n + v_k;
  end if;

  return v_n;
end
$fn$;

-- ------------------------------------------------ bilet_kamera_geri_ac -----
-- "Araç çıkmadı". Dönüş: true. Koşulların hepsi gövdede; guard'ı yalnızca
-- app.bilet_geri_ac bayrağıyla, yalnızca bu bilet için geçer.

create or replace function public.bilet_kamera_geri_ac(p_bilet_id uuid)
returns boolean
language plpgsql security definer set search_path = public as $fn$
declare
  v_b public.biletler;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;

  if v_b.durum <> 'KAPALI' or v_b.cikis_kaynak is distinct from 'KAMERA' then
    raise exception 'Yalnızca kameranın kapattığı bir bilet geri açılabilir.';
  end if;

  -- bilet_tahsil (034) ile aynı sınır: göremediği bileti açamaz.
  if not (public.is_yonetici()
          or coalesce(v_b.kapatan_vardiya_id = public.acik_vardiyam(), false)) then
    raise exception 'Bu bileti geri açma yetkiniz yok.';
  end if;

  if v_b.tahsil_kurus <> 0
     or exists (select 1 from public.tahsilatlar t
                 where t.bilet_id = p_bilet_id and t.iptal_of is null
                   and t.durum <> 'REDDEDILDI') then
    raise exception 'Bu biletin ödemesi alınmış; geri açılamaz.';
  end if;

  -- Araç kameraya yeniden göründüyse yeni bir açık bilet olabilir (tekil
  -- indeks ikinciye izin vermez). Hangisinin doğru olduğuna insan karar verir.
  if exists (select 1 from public.biletler b
              where b.plaka = v_b.plaka and b.durum = 'ACIK') then
    raise exception 'Bu plakayla içeride başka bir bilet var; önce onu iptal edin.';
  end if;

  perform set_config('app.bilet_geri_ac', p_bilet_id::text, true);
  update public.biletler set
    -- Yanlış kapanıştan sonra yere başka araç girdiyse yer onda kalır, bu
    -- bilet yersiz açılır (biletler_acik_yer_ux: açık bilet başına bir yer).
    park_yeri_id       = case
                           when exists (select 1 from public.biletler o
                                         where o.durum = 'ACIK' and o.id <> p_bilet_id
                                           and o.park_yeri_id = v_b.park_yeri_id)
                           then null else v_b.park_yeri_id
                         end,
    durum              = 'ACIK',
    cikis_at           = null,
    ucret_kurus        = 0,
    tahsil_kurus       = 0,
    odeme_yontemi      = null,
    cikis_by           = null,
    cikis_kaynak       = null,
    kapatan_vardiya_id = null,
    cikis_foto         = null,
    cikis_bekliyor_at  = null
  where id = p_bilet_id;
  perform set_config('app.bilet_geri_ac', '', true);

  perform public.audit('bilet_kamera_geri_acildi', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'cikis_at', v_b.cikis_at,
                       'ucret', v_b.ucret_kurus, 'vardiya', v_b.kapatan_vardiya_id,
                       'park_yeri', v_b.park_yeri_id));
  perform public.notify_yonetici('KAMERA_GERI_ACILDI', 'Kamera çıkışı geri alındı',
    v_b.plaka || ' — araç çıkmamış, bilet yeniden açık.',
    '/gise/bilet/' || p_bilet_id);

  return true;
end
$fn$;

-- --------------------------------------------- bildirim_yonetici_turu -----
-- 050'nin listesi BİREBİR + KAMERA_GERI_ACILDI (Yönetici'ye özel).
-- ODEME_BEKLIYOR BİLEREK listede yok: herkese gider.

create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $fn$
  select p_tur::text in (
    'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA',
    'KAMERA_HAREKET','VARDIYA_ACIK','ONAY_BEKLIYOR','PLAKA_SUPHE',
    'VARDIYA_KAPATMA','BILET_IPTAL_TALEBI','KAMERA_GERI_ACILDI'
  );
$fn$;

-- ---------------------------------------------------------------- yetki ----

revoke all on function public.kamera_cikis_bildir(text, uuid, timestamptz, text, jsonb) from public;
revoke all on function public.kamera_cikis_bildir(text, uuid, timestamptz, text, jsonb)
  from anon, authenticated, service_role;
grant execute on function public.kamera_cikis_bildir(text, uuid, timestamptz, text, jsonb)
  to service_role;

revoke all on function public.kamera_foto_bagla(uuid, uuid, timestamptz, text) from public;
revoke all on function public.kamera_foto_bagla(uuid, uuid, timestamptz, text)
  from anon, authenticated, service_role;
grant execute on function public.kamera_foto_bagla(uuid, uuid, timestamptz, text)
  to service_role;

revoke all on function public.bilet_kamera_geri_ac(uuid) from public;
revoke all on function public.bilet_kamera_geri_ac(uuid) from anon, authenticated, service_role;
grant execute on function public.bilet_kamera_geri_ac(uuid) to authenticated;

-- biletler_immutable_guard: `create or replace` yetkilerini korur; 029'daki
-- hâli PASS 41'in listesinde, bilerek DOKUNULMAZ.

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
  f text;
begin
  f := 'public.kamera_cikis_bildir(text, uuid, timestamptz, text, jsonb)';
  if not has_function_privilege('service_role', f, 'execute') then
    raise exception '054: kamera_cikis_bildir service_role rolüne kapalı — webhook çağıramaz';
  end if;
  foreach r in array array['anon', 'authenticated'] loop
    if has_function_privilege(r, f, 'execute') then
      raise exception '054: kamera_cikis_bildir % rolüne açık', r;
    end if;
  end loop;

  f := 'public.kamera_foto_bagla(uuid, uuid, timestamptz, text)';
  if not has_function_privilege('service_role', f, 'execute') then
    raise exception '054: kamera_foto_bagla service_role rolüne kapalı';
  end if;
  foreach r in array array['anon', 'authenticated'] loop
    if has_function_privilege(r, f, 'execute') then
      raise exception '054: kamera_foto_bagla % rolüne açık', r;
    end if;
  end loop;

  f := 'public.bilet_kamera_geri_ac(uuid)';
  if not has_function_privilege('authenticated', f, 'execute') then
    raise exception '054: bilet_kamera_geri_ac authenticated rolüne kapalı';
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, f, 'execute') then
      raise exception '054: bilet_kamera_geri_ac % rolüne açık', r;
    end if;
  end loop;

  foreach f in array array['public.kamera_cikis_bildir(text, uuid, timestamptz, text, jsonb)',
                           'public.kamera_foto_bagla(uuid, uuid, timestamptz, text)',
                           'public.bilet_kamera_geri_ac(uuid)'] loop
    if not exists (select 1 from pg_proc where oid = f::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
      raise exception '054: % SECURITY DEFINER + search_path=public değil', f;
    end if;
  end loop;

  if exists (select 1 from pg_trigger
              where tgname = 'kamera_cikis_bildirim_tg'
                and tgrelid = 'public.biletler'::regclass) then
    raise exception '054: eski çıkış bildirim tetiği hâlâ duruyor — iki bildirim gider';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgname like '%immutable%' and tgrelid = 'public.biletler'::regclass
                    and not tgisinternal) then
    raise exception '054: biletler değişmezlik tetiği yok';
  end if;

  -- 053 koşulmuş olmalı (enum değerleri metin olarak okunur — 55P04).
  if (select count(*) from pg_enum e join pg_type t on t.oid = e.enumtypid
       where t.typname = 'bildirim_tur'
         and e.enumlabel in ('ODEME_BEKLIYOR', 'KAMERA_GERI_ACILDI')) <> 2 then
    raise exception '054: 053 koşulmamış — ODEME_BEKLIYOR / KAMERA_GERI_ACILDI yok';
  end if;
end
$do$;

commit;
