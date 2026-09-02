-- ============================================================================
-- 025  Kendini toparlama: açık kalan vardiya + unutulan kuyruklar
-- ============================================================================

begin;

-- ---------------------------------------------------------------- enum ----
-- 55P04 tuzağı: eklenen değer AYNI işlem içinde KULLANILAMAZ. Aşağıdaki
-- plpgsql gövdeleri sorun değildir (ifadeler ilk çalıştırmada çözülür), ama
-- SQL gövdesi ve verify bloğu enum literali göremez — orada ::text ve pg_enum
-- kullanılır.
alter type public.bildirim_tur add value if not exists 'VARDIYA_ACIK';
alter type public.bildirim_tur add value if not exists 'ONAY_BEKLIYOR';

-- RLS (003) ve send-push rol eşleşmesi bu listeden okur: eksik kalan tür
-- yanlış kişiye açılır.
create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $fn$
  select p_tur::text in (
    'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA','ISTISNA',
    'KAMERA_HAREKET','VARDIYA_ACIK','ONAY_BEKLIYOR'
  );
$fn$;

-- ---------------------------------------------------------------- şema ----

alter table public.otopark_ayarlari
  add column if not exists vardiya_esik_saat integer not null default 16
    check (vardiya_esik_saat between 4 and 72);

alter table public.vardiyalar
  add column if not exists kapanis_kaynak text;

-- Bu migration'dan önce kapanan her vardiya elle kapatılmıştır. Boş bırakılsa
-- ekran "eski satır" ile "kim kapattı bilinmiyor"u ayırt edemezdi.
update public.vardiyalar
   set kapanis_kaynak = 'ELLE'
 where kapanis_at is not null and kapanis_kaynak is null;

do $do$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.vardiyalar'::regclass
                    and conname = 'vardiyalar_kapanis_kaynak_ck') then
    alter table public.vardiyalar add constraint vardiyalar_kapanis_kaynak_ck
      check (kapanis_kaynak is null or kapanis_kaynak in ('ELLE','YONETICI','OTOMATIK'));
  end if;

  -- Kapanış ile kaynak birlikte var olur: kaynağı yazmayı unutan bir kapatma
  -- yolu buradan geri döner, sessizce eksik satır bırakmaz.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.vardiyalar'::regclass
                    and conname = 'vardiyalar_kaynak_kapanis_ck') then
    alter table public.vardiyalar add constraint vardiyalar_kaynak_kapanis_ck
      check ((kapanis_at is null) = (kapanis_kaynak is null));
  end if;

  -- EN ÖNEMLİ KISIT. Otomatik kapatma nakit SAYMAZ; sayamaz da. `sayılan =
  -- beklenen` yazsaydı fark her seferinde sıfır çıkar, eksik kalan bir kasa
  -- kendiliğinden "tutuyor" görünürdü — kaybı gizleyen bir onarım, onarım
  -- değildir. Sayım boş kalır, soru görünür kalır.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.vardiyalar'::regclass
                    and conname = 'vardiyalar_otomatik_sayim_ck') then
    alter table public.vardiyalar add constraint vardiyalar_otomatik_sayim_ck
      check (kapanis_kaynak is distinct from 'OTOMATIK'
             or (sayilan_nakit_kurus is null and fark_kurus is null));
  end if;
end
$do$;

-- ------------------------------------------------------------- vardiya ----

-- Gövde 002'den birebir; tek fark kapanış kaynağının yazılması (yukarıdaki
-- kısıt artık bunu zorunlu kılıyor).
create or replace function public.vardiya_kapat(
  p_sayilan_nakit_kurus integer, p_notlar text default null
) returns table (beklenen_kurus integer, sayilan_kurus integer, fark_kurus integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_v        public.vardiyalar;
  v_nakit    integer;
  v_beklenen integer;
  v_fark     integer;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_sayilan_nakit_kurus is null or p_sayilan_nakit_kurus < 0 then
    raise exception 'Sayılan nakit negatif olamaz.';
  end if;

  select * into v_v from public.vardiyalar
   where personel_id = auth.uid() and kapanis_at is null for update;
  if not found then
    raise exception 'Açık vardiyanız yok.';
  end if;

  select coalesce(sum(t.tutar_kurus), 0)::integer into v_nakit
    from public.tahsilatlar t
   where t.vardiya_id = v_v.id and t.yontem = 'NAKIT';

  v_beklenen := v_v.acilis_nakit_kurus + v_nakit;
  v_fark     := p_sayilan_nakit_kurus - v_beklenen;

  update public.vardiyalar
     set kapanis_at           = now(),
         sayilan_nakit_kurus  = p_sayilan_nakit_kurus,
         beklenen_nakit_kurus = v_beklenen,
         fark_kurus           = v_fark,
         kapanis_kaynak       = 'ELLE',
         notlar               = nullif(btrim(p_notlar), '')
   where id = v_v.id;

  if v_fark <> 0 then
    perform public.audit('vardiya_fark', 'vardiyalar', v_v.id,
      jsonb_build_object('beklenen', v_beklenen, 'sayilan', p_sayilan_nakit_kurus,
                         'fark', v_fark));
    perform public.notify_yonetici('VARDIYA_FARK', 'Vardiya farkı',
      (select p.ad_soyad from public.profiles p where p.id = v_v.personel_id)
        || ' — fark ' || (v_fark / 100.0)::numeric(12,2) || ' ₺',
      '/finans/vardiyalar');
  end if;

  return query select v_beklenen, p_sayilan_nakit_kurus, v_fark;
end
$fn$;

-- Vardiyayı yalnızca sahibi kapatabiliyordu (`auth.uid()`), ve `vardiya_ac`
-- ikinci bir açık vardiyayı reddediyor. Kapatmayı unutan — ya da hesabı
-- kapatılan, işten ayrılan — personel bir daha ASLA vardiya açamıyordu, kimse
-- de onun yerine kapatamıyordu. Yöneticiye o yol açılıyor.
--
-- Sayım İSTEĞE BAĞLI: gerçekten sayıldıysa fark hesaplanır ve normal kapanış
-- gibi bildirim gider; sayılmadıysa boş kalır. Uydurulan bir sayı, kasadan
-- eksik çıkan parayı sonsuza kadar görünmez yapardı.
create or replace function public.vardiya_zorla_kapat(
  p_vardiya_id uuid,
  p_sayilan_nakit_kurus integer default null,
  p_notlar text default null
) returns table (beklenen_kurus integer, sayilan_kurus integer, fark_kurus integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_v        public.vardiyalar;
  v_nakit    integer;
  v_beklenen integer;
  v_fark     integer;
  v_ad       text;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici başka bir vardiyayı kapatabilir.';
  end if;
  if p_sayilan_nakit_kurus is not null and p_sayilan_nakit_kurus < 0 then
    raise exception 'Sayılan nakit negatif olamaz.';
  end if;

  -- `for update`: personelin kendi kapatması da aynı satırı kilitler, ikisi
  -- birden kapatamaz.
  select * into v_v from public.vardiyalar where id = p_vardiya_id for update;
  if not found then
    raise exception 'Vardiya bulunamadı.';
  end if;
  if v_v.kapanis_at is not null then
    raise exception 'Bu vardiya zaten kapalı.';
  end if;

  select coalesce(sum(t.tutar_kurus), 0)::integer into v_nakit
    from public.tahsilatlar t
   where t.vardiya_id = v_v.id and t.yontem = 'NAKIT';

  v_beklenen := v_v.acilis_nakit_kurus + v_nakit;
  v_fark := case when p_sayilan_nakit_kurus is null
                 then null else p_sayilan_nakit_kurus - v_beklenen end;

  update public.vardiyalar
     set kapanis_at           = now(),
         beklenen_nakit_kurus = v_beklenen,
         sayilan_nakit_kurus  = p_sayilan_nakit_kurus,
         fark_kurus           = v_fark,
         kapanis_kaynak       = 'YONETICI',
         -- coalesce: not verilmediyse mevcut not silinmez.
         notlar               = coalesce(nullif(btrim(p_notlar), ''), notlar)
   where id = v_v.id;

  select p.ad_soyad into v_ad from public.profiles p where p.id = v_v.personel_id;

  perform public.audit('vardiya_zorla_kapat', 'vardiyalar', v_v.id,
    jsonb_build_object('personel', v_v.personel_id, 'beklenen', v_beklenen,
                       'sayilan', p_sayilan_nakit_kurus, 'fark', v_fark));

  if v_fark is not null and v_fark <> 0 then
    perform public.notify_yonetici('VARDIYA_FARK', 'Vardiya farkı',
      coalesce(v_ad, 'Personel') || ' — fark ' || (v_fark / 100.0)::numeric(12,2) || ' ₺',
      '/finans/vardiyalar');
  end if;

  return query select v_beklenen, p_sayilan_nakit_kurus, v_fark;
end
$fn$;

-- 007'nin yeniden hesabı `coalesce(sayilan, 0) - beklenen` diyordu. O güne
-- kadar sorun değildi: `vardiya_kapat` sayımı zorunlu tuttuğu için kapalı bir
-- vardiyada sayilan ASLA null olmazdı. Otomatik kapanış bunu değiştiriyor —
-- ve NULL'ı 0 saymak, kimsenin saymadığı bir kasada "beklenen kadar eksik"
-- diye uydurma bir fark üretirdi. Üstelik yeni kısıt bunu reddeder, yani
-- otomatik kapanmış bir vardiyaya ait bilet SİLİNEMEZ hâle gelirdi
-- (`bilet_sil` -> `vardiya_yeniden_hesapla` -> check_violation).
--
-- NULL sayım artık NULL fark üretir; gövdenin geri kalanı 007'den birebir.
create or replace function public.vardiya_yeniden_hesapla(p_vardiya_id uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_v        public.vardiyalar;
  v_nakit    integer;
  v_beklenen integer;
  v_fark     integer;
begin
  if p_vardiya_id is null then
    return;
  end if;
  select * into v_v from public.vardiyalar where id = p_vardiya_id;
  if not found or v_v.kapanis_at is null then
    return;   -- still open: vardiya_kapat will compute it correctly later
  end if;

  select coalesce(sum(t.tutar_kurus), 0)::integer into v_nakit
    from public.tahsilatlar t
   where t.vardiya_id = v_v.id and t.yontem = 'NAKIT';

  v_beklenen := v_v.acilis_nakit_kurus + v_nakit;
  v_fark     := case when v_v.sayilan_nakit_kurus is null then null
                     else v_v.sayilan_nakit_kurus - v_beklenen end;

  if v_beklenen is distinct from v_v.beklenen_nakit_kurus
     or v_fark is distinct from v_v.fark_kurus then
    update public.vardiyalar
       set beklenen_nakit_kurus = v_beklenen, fark_kurus = v_fark
     where id = v_v.id;

    perform public.audit('vardiya_yeniden_hesap', 'vardiyalar', v_v.id,
      jsonb_build_object('eski_beklenen', v_v.beklenen_nakit_kurus,
                         'yeni_beklenen', v_beklenen,
                         'eski_fark', v_v.fark_kurus, 'yeni_fark', v_fark));
  end if;
end
$fn$;

-- -------------------------------------------------------- kurtarma işi ----

-- Gece işine DEĞİL, 15 dakikada bire bağlanır: eşiği aşan personel ertesi
-- sabah vardiya açamadığında 00:05'i bekleyemez.
create or replace function public.run_vardiya_kurtarma() returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_esik integer;
  v_r    record;
  v_bek  integer;
begin
  -- Üst üste binen iki tik aynı satırı görüp iki kez kapatmaya kalkmasın.
  -- `try_`: sıra biriktirmek yerine tik atlanır, 15 dakika sonra zaten koşar.
  if not pg_try_advisory_xact_lock(hashtext('vardiya_kurtarma')) then
    return;
  end if;

  select o.vardiya_esik_saat into v_esik
    from public.otopark_ayarlari o where o.id = 1;
  v_esik := coalesce(v_esik, 16);

  for v_r in
    select v.id, v.personel_id, v.acilis_at, v.acilis_nakit_kurus
      from public.vardiyalar v
     where v.kapanis_at is null
       and v.acilis_at < now() - make_interval(hours => v_esik)
     order by v.acilis_at
  loop
    select v_r.acilis_nakit_kurus + coalesce(sum(t.tutar_kurus), 0)::integer
      into v_bek
      from public.tahsilatlar t
     where t.vardiya_id = v_r.id and t.yontem = 'NAKIT';

    -- Beklenen YAZILIR (tahsilat toplamı, bir olgu); sayılan ve fark boş kalır
    -- (kimse saymadı). Yukarıdaki kısıt da bunu zorunlu tutuyor.
    update public.vardiyalar
       set kapanis_at           = now(),
           beklenen_nakit_kurus = v_bek,
           kapanis_kaynak       = 'OTOMATIK',
           notlar = coalesce(nullif(btrim(notlar), '') || ' · ', '')
                    || 'Otomatik kapatıldı (' || v_esik || ' saat).'
     where id = v_r.id and kapanis_at is null;

    if found then
      perform public.audit('vardiya_otomatik_kapat', 'vardiyalar', v_r.id,
        jsonb_build_object('personel', v_r.personel_id, 'esik_saat', v_esik,
                           'beklenen', v_bek));
      perform public.notify_yonetici('VARDIYA_ACIK', 'Vardiya otomatik kapatıldı',
        coalesce((select p.ad_soyad from public.profiles p where p.id = v_r.personel_id),
                 'Personel')
          || ' — ' || v_esik || ' saattir açıktı, nakit sayılmadı.',
        '/finans/vardiyalar');
    end if;
  end loop;
end
$fn$;

-- ------------------------------------------------------------ gece işi ----

-- 1-4 004'ten birebir; 5-7 yeni. Bu üç kuyruk tek bir bildirimle duyuruluyor
-- ve o bildirim kaçarsa bir daha hatırlatılmıyordu.
create or replace function public.run_gunluk_bakim() returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_bugun    date := (now() at time zone 'Europe/Istanbul')::date;
  v_saklama  integer;
  v_terk     integer;
  v_sayi     integer;
  v_r        record;
begin
  select o.foto_saklama_gun, o.terk_esik_saat
    into v_saklama, v_terk
    from public.otopark_ayarlari o where o.id = 1;
  v_saklama := coalesce(v_saklama, 30);
  v_terk    := coalesce(v_terk, 48);

  -- 1. Subscriptions that ran out yesterday stop being AKTIF. The ticket
  --    flow reads durum, so this is what makes a lapsed car start paying.
  update public.abonmanlar
     set durum = 'DOLDU'
   where durum = 'AKTIF' and bitis < v_bugun;

  -- 2. Expiring within a week — one notice per subscription, ever.
  for v_r in
    select a.id, a.plaka, a.musteri_ad, a.bitis
      from public.abonmanlar a
     where a.durum = 'AKTIF'
       and a.bitis between v_bugun and v_bugun + 7
       and not exists (
         select 1 from public.notifications n
          where n.tur = 'ABONMAN_BITIYOR'
            and n.link = '/yonetim/abonman/' || a.id::text)
  loop
    perform public.notify_yonetici('ABONMAN_BITIYOR', 'Abonman bitiyor',
      v_r.plaka || ' — ' || to_char(v_r.bitis, 'DD.MM.YYYY') || ' tarihinde doluyor.',
      '/yonetim/abonman/' || v_r.id::text);
  end loop;

  -- 3. KVKK retention. A plate is personal data; the ticket is kept as an
  --    accounting record, the photo is evidence with a short life.
  --    024 forbids 0, so this guard is a backstop now, not a setting.
  if v_saklama > 0 then
    delete from storage.objects
     where bucket_id = 'plaka-foto'
       and created_at < now() - make_interval(days => v_saklama);

    -- Drop the now-dangling paths so the UI shows "no photo" instead of a
    -- broken image. Permitted on closed tickets by the immutability guard,
    -- which treats a reference going NULL as a detach, not an edit.
    update public.biletler
       set giris_foto = null
     where giris_foto is not null
       and created_at < now() - make_interval(days => v_saklama);
    update public.biletler
       set cikis_foto = null
     where cikis_foto is not null
       and created_at < now() - make_interval(days => v_saklama);
    update public.istisnalar
       set foto_path = null
     where foto_path is not null
       and created_at < now() - make_interval(days => v_saklama);
  end if;

  -- 4. Abandoned vehicles: still open long past any plausible stay. One
  --    notice per ticket — the link doubles as the dedupe key.
  for v_r in
    select b.id, b.plaka, b.giris_at
      from public.biletler b
     where b.durum = 'ACIK'
       and b.giris_at < now() - make_interval(hours => v_terk)
       and not exists (
         select 1 from public.notifications n
          where n.tur = 'TERK_EDILMIS'
            and n.link = '/gise/bilet/' || b.id::text)
  loop
    perform public.notify_yonetici('TERK_EDILMIS', 'Terk edilmiş olabilir',
      v_r.plaka || ' — ' || round(extract(epoch from (now() - v_r.giris_at)) / 3600.0)
        || ' saattir içeride.',
      '/gise/bilet/' || v_r.id::text);
  end loop;

  -- 5. Onay kuyruğunda unutulan tahsilat. Ciro yalnızca ONAYLANDI satırlarını
  --    sayar, yani bekleyen para kasayı sessizce eksik gösterir.
  select count(*)::integer into v_sayi
    from public.tahsilatlar t
   where t.durum = 'BEKLIYOR' and t.created_at < now() - interval '48 hours';
  if v_sayi > 0 and not exists (
       select 1 from public.notifications n
        where n.tur = 'ONAY_BEKLIYOR' and n.created_at > now() - interval '20 hours')
  then
    perform public.notify_yonetici('ONAY_BEKLIYOR', 'Onay bekleyen tahsilat',
      v_sayi || ' tahsilat 48 saatten uzun süredir onay bekliyor.', '/finans/onay');
  end if;

  -- 6. Çözülmemiş istisna. Son 20 saatte aynı türden bildirim gittiyse
  --    tekrarlanmaz — tek tek bildirilen yeni kayıtlar da bu kapsamdadır,
  --    ve bu bilinçli: zaten haber verilmiş bir şey iki kez duyurulmaz.
  select count(*)::integer into v_sayi
    from public.istisnalar i
   where i.cozuldu_at is null and i.alindi_zaman < now() - interval '48 hours';
  if v_sayi > 0 and not exists (
       select 1 from public.notifications n
        where n.tur = 'ISTISNA' and n.created_at > now() - interval '20 hours')
  then
    perform public.notify_yonetici('ISTISNA', 'Çözülmemiş kayıt',
      v_sayi || ' kayıt 48 saatten uzun süredir bekliyor.', '/istisnalar');
  end if;

  -- 7. Onay bekleyen üyelik. Kayıt anında bir bildirim gider; kaçarsa kişi
  --    uygulamayı hiç kullanamaz ve kimse bunu bir daha duymazdı.
  select count(*)::integer into v_sayi
    from public.profiles p
   where p.durum = 'PENDING' and p.created_at < now() - interval '48 hours';
  if v_sayi > 0 and not exists (
       select 1 from public.notifications n
        where n.tur = 'YENI_UYELIK' and n.created_at > now() - interval '20 hours')
  then
    perform public.notify_yonetici('YENI_UYELIK', 'Onay bekleyen kayıt',
      v_sayi || ' kişi 48 saatten uzun süredir onay bekliyor.', '/yonetim/personel');
  end if;
end
$fn$;

-- --------------------------------------------------------- zamanlama -----

do $do$
begin
  perform cron.unschedule('otopark-vardiya');
exception when others then null;
end
$do$;

select cron.schedule('otopark-vardiya', '*/15 * * * *',
                     $job$select public.run_vardiya_kurtarma()$job$);

-- ------------------------------------------------------------- grants ----

-- `from public` yarısı taşıyıcıdır: onsuz `authenticated` yetkiyi PUBLIC
-- üzerinden miras alır ve personel bakım işini elle tetikleyebilir.
revoke all on function public.run_vardiya_kurtarma()
  from public, anon, authenticated, service_role;

revoke all on function public.vardiya_zorla_kapat(uuid, integer, text)
  from public, anon, service_role;
grant execute on function public.vardiya_zorla_kapat(uuid, integer, text) to authenticated;

-- -------------------------------------------------------------- verify ---
do $do$
declare v_def text;
begin
  -- Enum literali kullanılamaz (55P04): katalogdan okunur.
  if (select count(*) from pg_enum e
        join pg_type t on t.oid = e.enumtypid
       where t.typname = 'bildirim_tur'
         and e.enumlabel in ('VARDIYA_ACIK','ONAY_BEKLIYOR')) <> 2 then
    raise exception '025: yeni bildirim türleri eklenmedi';
  end if;

  v_def := pg_get_functiondef(
             'public.bildirim_yonetici_turu(public.bildirim_tur)'::regprocedure);
  if position('VARDIYA_ACIK' in v_def) = 0 or position('ONAY_BEKLIYOR' in v_def) = 0 then
    raise exception '025: yeni türler Yönetici listesine girmedi — yanlış role açılır';
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'vardiyalar'
                    and column_name = 'kapanis_kaynak')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'otopark_ayarlari'
                       and column_name = 'vardiya_esik_saat') then
    raise exception '025: kolonlar eklenmedi';
  end if;

  if (select count(*) from pg_constraint
       where conrelid = 'public.vardiyalar'::regclass
         and conname in ('vardiyalar_kapanis_kaynak_ck','vardiyalar_kaynak_kapanis_ck',
                         'vardiyalar_otomatik_sayim_ck')) <> 3 then
    raise exception '025: vardiya kısıtları kurulmadı';
  end if;

  if not exists (select 1 from cron.job where jobname = 'otopark-vardiya') then
    raise exception '025: kurtarma işi zamanlanmadı';
  end if;

  if has_function_privilege('authenticated', 'public.run_vardiya_kurtarma()', 'execute') then
    raise exception '025: kurtarma işi istemciye açık';
  end if;
  if not has_function_privilege('authenticated',
        'public.vardiya_zorla_kapat(uuid, integer, text)', 'execute') then
    raise exception '025: Yönetici zorla kapatmayı çağıramıyor';
  end if;
  if has_function_privilege('anon',
        'public.vardiya_zorla_kapat(uuid, integer, text)', 'execute') then
    raise exception '025: zorla kapatma anon rolüne açık';
  end if;

  -- 007 bunu her istemci rolünden geri almıştı; aynı imzayla replace ACL'i
  -- korur ama fonksiyonun içinde HİÇ rol kontrolü yok, tek koruması bu.
  if has_function_privilege('authenticated', 'public.vardiya_yeniden_hesapla(uuid)', 'execute')
     or has_function_privilege('anon', 'public.vardiya_yeniden_hesapla(uuid)', 'execute') then
    raise exception '025: vardiya_yeniden_hesapla istemciye açıldı';
  end if;
end
$do$;

commit;
