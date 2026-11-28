-- =====================================================================
-- 083  Abonman bitiş bildirimi
-- =====================================================================
-- Sahibin isteği (27.11.2026): abonmanın bitişi Personel'e de, Yönetici'ye
-- de bildirilir — bitişe 4 gün kala ve son gün.
--
-- Düzeltilen hata: gece işi (058) bildirimi bağlantıya bakarak "abonman
-- başına bir kez, sonsuza dek" gönderiyordu. Yenileme aynı satırı uzattığı
-- (bitiş ileri gider) için ilk aydan sonra kimse bilgilenmiyordu. Yeni
-- kontrol yalnızca bu dönemin bildirimlerine bakar (bitiş − 5 günden beri).
--
--   * abonman_bitis_bildirimleri(p_bugun): yeni, gece işinden çağrılır.
--     Tarih parametre — smoke test "30 gün sonrası"nı böyle sınar.
--   * run_gunluk_bakim: gövde 058'den BİREBİR; yalnızca 2. adım (7 gün
--     kala, yalnızca Yönetici) yeni fonksiyona yapılan çağrıyla değişti.
--     074 hiç çalıştırılmadı — canlı gövde 058'inki.
--   * bildirim_yonetici_turu: gövde 082'den BİREBİR; 'ABONMAN_BITIYOR'
--     çıkarıldı, böylece notify_herkes Personel'e de yazar. Personel
--     Ayarlar'da bu bildirimi kapatabilir.
--
-- Önce 078 → 082 çalışmış olmalı. Sonra tüm smoke test (PASS 112-115).
-- =====================================================================

begin;

do $do$
begin
  if to_regprocedure('public.bilet_asim_karar(uuid, boolean)') is null then
    raise exception '083: önce 082''yi çalıştırın (bilet_asim_karar yok)';
  end if;
end
$do$;

-- --------------------------------------------- abonman_bitis_bildirimleri --
create or replace function public.abonman_bitis_bildirimleri(p_bugun date)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_r      record;
  v_baslik text;
  v_govde  text;
  v_link   text;
begin
  for v_r in
    select a.id, a.plaka, a.bitis
      from public.abonmanlar a
     where a.durum = 'AKTIF'
       and a.bitis between p_bugun and p_bugun + 4
  loop
    if v_r.bitis = p_bugun then
      v_baslik := 'Abonman bugün bitiyor';
      v_govde  := v_r.plaka || ' — bugün doluyor.';
    else
      v_baslik := 'Abonman bitiyor';
      v_govde  := v_r.plaka || ' — ' || to_char(v_r.bitis, 'DD.MM.YYYY') || ' tarihinde doluyor.';
    end if;
    v_link := '/abonman/' || v_r.id::text;

    -- Bu dönem için aynı bildirim gittiyse tekrar yok. Eski bağlantı
    -- (/yonetim/abonman/…, 058) de sayılır ki çalıştırıldığı gece çift
    -- bildirim gitmesin. Pencere bitiş − 5 gün: yenilemeden sonra (bitiş
    -- bir ay ileri) önceki ayın bildirimleri artık saymaz.
    if not exists (
         select 1 from public.notifications n
          where n.tur = 'ABONMAN_BITIYOR'
            and n.link in (v_link, '/yonetim/abonman/' || v_r.id::text)
            -- 058'in bildirimi de "Abonman bitiyor" başlıklıydı.
            and n.baslik = v_baslik
            and n.created_at >= ((v_r.bitis - 5)::timestamp at time zone 'Europe/Istanbul'))
    then
      perform public.notify_herkes('ABONMAN_BITIYOR', v_baslik, v_govde, v_link);
    end if;
  end loop;
end
$fn$;

-- --------------------------------------------------------- gece işi -----
-- Gövde 058'den BİREBİR; yalnızca 2. adım değişti (yukarıya bakın).
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

  -- 2. 083: ending soon — Personel and Yönetici, 4 days before and on the
  --    last day, again every month after a renewal (abonman_bitis_bildirimleri).
  perform public.abonman_bitis_bildirimleri(v_bugun);

  -- 3. KVKK retention. A plate is personal data; the ticket is kept as an
  --    accounting record, the photo is evidence with a short life.
  --    024 forbids 0, so this guard is a backstop now, not a setting.
  if v_saklama > 0 then
    -- 043: the FILES are removed by the Edge Function foto-temizle through
    -- the Storage API (step 8). A SQL delete on the storage table removed
    -- only the metadata row: the file stayed in the bucket, orphaned,
    -- still counted against the 1 GB and kept past this retention (KVKK).

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

  -- 8. 043: delete the expired photo FILES through the Storage API (the
  --    request is sent after this transaction commits; foto-temizle lists
  --    with foto_temizlik_listesi, which uses the same retention). Own
  --    sub-block: a cleanup problem must never undo steps 1–7.
  begin
    perform public.foto_temizlik_tetikle();
  exception when others then
    raise warning 'fotoğraf temizliği tetiklenemedi: %', sqlerrm;
  end;

  -- 9. 058: kameranın dünkü özeti Yönetici'ye (kamera açıkken, günde bir).
  --    Kendi alt bloğu: özetteki bir sorun 1–8'i asla geri almaz.
  begin
    perform public.kamera_gunluk_rapor();
  exception when others then
    raise warning 'kamera günlük özeti yazılamadı: %', sqlerrm;
  end;
end
$fn$;

-- --------------------------------------------- bildirim_yonetici_turu -----
-- Gövde 082'den BİREBİR; 'ABONMAN_BITIYOR' listeden çıkarıldı (herkese).
create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $fn$
  select p_tur::text in (
    'YENI_UYELIK','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA',
    'KAMERA_HAREKET','VARDIYA_ACIK','ONAY_BEKLIYOR','PLAKA_SUPHE',
    'VARDIYA_KAPATMA','BILET_IPTAL_TALEBI','KAMERA_GERI_ACILDI',
    'KAMERA_GUNLUK','YENI_ABONMAN','UCRETSIZ_CIKIS','SURE_ASIMI'
  );
$fn$;

-- ---------------------------------------------------------------- yetki ---
-- Yalnızca gece işi (SECURITY DEFINER, sahibin yetkisiyle) çağırır.
revoke all on function public.abonman_bitis_bildirimleri(date) from public;
revoke all on function public.abonman_bitis_bildirimleri(date)
  from anon, authenticated, service_role;
-- run_gunluk_bakim ve bildirim_yonetici_turu: `create or replace` mevcut
-- yetkileri korur; PASS 41'in listelerine bilerek DOKUNULMAZ.

-- ---------------------------------------------------------- doğrulama -----
do $do$
declare
  v_def text;
begin
  if not exists (select 1 from pg_proc
                  where oid = 'public.abonman_bitis_bildirimleri(date)'::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
    raise exception '083: abonman_bitis_bildirimleri SECURITY DEFINER + search_path=public değil';
  end if;
  if has_function_privilege('public', 'public.abonman_bitis_bildirimleri(date)', 'execute')
     or has_function_privilege('anon', 'public.abonman_bitis_bildirimleri(date)', 'execute')
     or has_function_privilege('authenticated', 'public.abonman_bitis_bildirimleri(date)', 'execute')
     or has_function_privilege('service_role', 'public.abonman_bitis_bildirimleri(date)', 'execute') then
    raise exception '083: abonman_bitis_bildirimleri bir role açık';
  end if;

  v_def := pg_get_functiondef('public.run_gunluk_bakim()'::regprocedure);
  if position('abonman_bitis_bildirimleri' in v_def) = 0 then
    raise exception '083: run_gunluk_bakim yeni bildirimi çağırmıyor';
  end if;
  if position('foto_temizlik_tetikle' in v_def) = 0
     or position('kamera_gunluk_rapor(' in v_def) = 0 then
    raise exception '083: run_gunluk_bakim 058''in adımlarını kaybetti';
  end if;
  if public.bildirim_yonetici_turu('ABONMAN_BITIYOR') then
    raise exception '083: ABONMAN_BITIYOR hâlâ yalnızca Yönetici türü';
  end if;
  if not public.bildirim_yonetici_turu('SURE_ASIMI') then
    raise exception '083: bildirim_yonetici_turu 082''nin listesini kaybetti';
  end if;
end
$do$;

commit;
