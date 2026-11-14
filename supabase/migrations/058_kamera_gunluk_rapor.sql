-- ============================================================================
-- 058  Kameranın günlük özeti Yönetici'ye
-- ============================================================================

begin;

-- Sahibin kararı (2026-11-14, 1.4.2 E13): kamera her gün ne yaptı, Yönetici
-- bir bakışta görsün. Gece işi (00:05 İstanbul, 004) bir önceki günü sayar
-- ve kamera açıkken TEK bildirim yazar:
--   "14.11: 34 giriş, 30 çıkış, 3 personele (1 çözülmedi)"
--   · giriş     — kameranın açtığı biletler (giris_kaynak = KAMERA);
--   · çıkış     — kameranın kapattığı biletler (cikis_kaynak = KAMERA, 054);
--   · personele — kameranın çözülmemiş kayıtları (istisnalar.kaynak =
--                 KAMERA), kaçının hâlâ açık olduğu da.
-- Hiç araç kaydedilmeyen gün de bildirilir — o bir alarmdır (kamera ya da
-- köprü durmuş olabilir). Köprünün yalnızca kendi kaydında duran sayıları
-- (kararsız biten iz, otopark içi hareket) burada YOK: `--durum` gösterir.
--
-- Sayım ve yazma iki ayrı yardımcıda: smoke test onları gece işinin
-- tamamını (fotoğraf temizliği ağ isteği atar) çalıştırmadan sınar. İkisi
-- de hiçbir role açık değildir — yalnızca gece işi (sahibi) çağırır.
--
-- 057'nin değeri ('KAMERA_GUNLUK') bu dosyada enum literali olarak
-- ÇALIŞTIRILMAZ (039 dersi): yalnızca fonksiyon gövdelerinde geçer,
-- doğrulama pg_enum'u ve tanımları okur.

-- ------------------------------------------------------------- sayım -----

create or replace function public.kamera_gunluk_sayim(p_gun date) returns jsonb
language sql stable security definer set search_path = public as $fn$
  select jsonb_build_object(
    'giris', (select count(*) from public.biletler b
               where b.giris_kaynak::text = 'KAMERA'
                 and (b.giris_at at time zone 'Europe/Istanbul')::date = p_gun),
    'cikis', (select count(*) from public.biletler b
               where b.cikis_kaynak::text = 'KAMERA'
                 and (b.cikis_at at time zone 'Europe/Istanbul')::date = p_gun),
    'personele', (select count(*) from public.istisnalar i
                   where i.kaynak::text = 'KAMERA'
                     and (i.alindi_zaman at time zone 'Europe/Istanbul')::date = p_gun),
    'acik', (select count(*) from public.istisnalar i
              where i.kaynak::text = 'KAMERA' and i.cozuldu_at is null
                and (i.alindi_zaman at time zone 'Europe/Istanbul')::date = p_gun));
$fn$;

-- ------------------------------------------------------------- özet ------

-- p_gun boşsa dün (İstanbul). Bildirim yazdıysa true. Aynı gün için ikinci
-- kez yazmaz (bağlantı günün tarihini taşır, tekrar anahtarı odur).
create or replace function public.kamera_gunluk_rapor(p_gun date default null) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare
  v_gun   date := coalesce(p_gun, (now() at time zone 'Europe/Istanbul')::date - 1);
  v_aktif boolean;
  v_s     jsonb;
  v_link  text;
  v_govde text;
begin
  select o.kamera_aktif into v_aktif from public.otopark_ayarlari o where o.id = 1;
  if not coalesce(v_aktif, false) then
    return false;
  end if;
  v_link := '/yonetim/kameralar?gun=' || v_gun::text;
  if exists (select 1 from public.notifications n
              where n.tur::text = 'KAMERA_GUNLUK' and n.link = v_link) then
    return false;
  end if;
  v_s := public.kamera_gunluk_sayim(v_gun);
  if (v_s ->> 'giris')::int + (v_s ->> 'cikis')::int + (v_s ->> 'personele')::int = 0 then
    v_govde := to_char(v_gun, 'DD.MM')
      || ': kamera hiç araç kaydetmedi — kamera ve köprü çalışıyor mu?';
  else
    v_govde := to_char(v_gun, 'DD.MM') || ': '
      || (v_s ->> 'giris') || ' giriş, ' || (v_s ->> 'cikis') || ' çıkış, '
      || (v_s ->> 'personele') || ' personele'
      || case when (v_s ->> 'acik')::int > 0
              then ' (' || (v_s ->> 'acik') || ' çözülmedi)' else '' end;
  end if;
  perform public.notify_yonetici('KAMERA_GUNLUK', 'Kamera günlük özeti', v_govde, v_link);
  return true;
end
$fn$;

-- --------------------------------------------------------- gece işi -----

-- Gövde 043'ten BİREBİR; yalnızca sonuna 9. adım (kameranın günlük özeti,
-- kendi alt bloğunda) eklendi. 043'ten sonra bu fonksiyonu yeniden tanımlayan
-- migration yok (004 → 025 → 043 → 058).
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

-- Gövde 054'ten BİREBİR; listeye 'KAMERA_GUNLUK' eklendi (Yönetici'ye özel).
create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $fn$
  select p_tur::text in (
    'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA',
    'KAMERA_HAREKET','VARDIYA_ACIK','ONAY_BEKLIYOR','PLAKA_SUPHE',
    'VARDIYA_KAPATMA','BILET_IPTAL_TALEBI','KAMERA_GERI_ACILDI',
    'KAMERA_GUNLUK'
  );
$fn$;

-- ---------------------------------------------------------------- yetki ----

-- Yeni iki yardımcı: hiçbir role açık değil (PUBLIC dahil — Supabase yeni
-- fonksiyonu PUBLIC'e ve üç role ayrı ayrı verir).
revoke all on function public.kamera_gunluk_sayim(date)
  from public, anon, authenticated, service_role;
revoke all on function public.kamera_gunluk_rapor(date)
  from public, anon, authenticated, service_role;
-- Aynı imza, yani mevcut yetkiler zaten korunur; yine de açıkça (043 gibi).
revoke all on function public.run_gunluk_bakim()
  from public, anon, authenticated, service_role;
-- bildirim_yonetici_turu: `create or replace` yetkilerini korur; PASS 41'in
-- listelerinde (anon / service_role), bilerek DOKUNULMAZ.

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r      text;
  v_def  text;
begin
  -- 057 koşulmuş olmalı (pg_enum'dan — literal cast YOK, 039 dersi).
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'bildirim_tur' and e.enumlabel = 'KAMERA_GUNLUK') then
    raise exception '058: bildirim_tur''de KAMERA_GUNLUK yok — önce 057''yi çalıştırın';
  end if;

  foreach r in array array['public.kamera_gunluk_sayim(date)',
                           'public.kamera_gunluk_rapor(date)'] loop
    if to_regprocedure(r) is null then
      raise exception '058: % oluşmadı', r;
    end if;
    if not exists (select 1 from pg_proc
                    where oid = r::regprocedure
                      and prosecdef and proconfig @> array['search_path=public']) then
      raise exception '058: % SECURITY DEFINER + search_path=public değil', r;
    end if;
    if has_function_privilege('public', r, 'execute')
       or has_function_privilege('anon', r, 'execute')
       or has_function_privilege('authenticated', r, 'execute')
       or has_function_privilege('service_role', r, 'execute') then
      raise exception '058: % bir role açık', r;
    end if;
  end loop;

  v_def := pg_get_functiondef('public.run_gunluk_bakim()'::regprocedure);
  if position('foto_temizlik_tetikle' in v_def) = 0 then
    raise exception '058: run_gunluk_bakim fotoğraf temizliğini tetiklemiyor';
  end if;
  if position('kamera_gunluk_rapor(' in v_def) = 0 then
    raise exception '058: run_gunluk_bakim kameranın günlük özetini çağırmıyor';
  end if;
  if position('KAMERA_GUNLUK' in
              pg_get_functiondef('public.bildirim_yonetici_turu(public.bildirim_tur)'::regprocedure)) = 0 then
    raise exception '058: KAMERA_GUNLUK Yönetici listesinde değil';
  end if;
end
$do$;

commit;
