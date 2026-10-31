-- ============================================================================
-- 043  Fotoğraf temizliği: dosyalar Storage API ile silinir (SQL ile değil)
-- ============================================================================

begin;

-- 025'in gece işi (run_gunluk_bakim) saklama süresini aşan fotoğrafları
-- storage.objects tablosundan SQL ile siliyordu. Supabase'e göre bu yalnızca
-- KAYIT satırını siler: dosya kovada YETİM kalır, ücretsiz 1 GB'a sayılmaya
-- devam eder ve saklama süresinden sonra da durur (KVKK). Bazı projelerde bu
-- silme tamamen engellidir; o zaman bütün gece işi (abonman bitişi, terk
-- edilmiş araç uyarısı …) her gece hata verir.
--
-- Artık: gece işi yalnızca yolları boşaltır (eskisi gibi) ve sonunda
-- foto_temizlik_tetikle() ile Edge Function foto-temizle'ye istek atar.
-- O, silinecek dosyaların adlarını foto_temizlik_listesi() ile alır ve
-- Storage API'si ile siler (her çağrıda en fazla 1000). Hangi fotoğrafın
-- eski olduğuna eskisi gibi uygulamadaki ayar karar verir:
-- otopark_ayarlari.foto_saklama_gun (1–30 gün).
--
-- Sessiz kalmaz: kurulum eksikse ("Fotoğraf temizliği kurulmamış") ya da
-- silme başarısızsa ("Fotoğraf temizliği başarısız") Yöneticiye günde en
-- fazla bir KAMERA uyarısı gider (040'ın uyarı deseni). Yeni bildirim türü
-- eklenmedi: o, bildirim_yonetici_turu'nu, ayar düğmelerini ve send-push
-- eşlemesini de değiştirmeyi gerektirirdi.
--
-- Bu migration'dan ÖNCE yetim kalmış dosyalar (kaydı silinmiş) API ile
-- bulunamaz; onlar için SETUP.md'deki kontrol ve gerekirse Supabase desteği.

-- ------------------------------------------------------------------ ayar ---

-- 023 push_ayar deseni: tek satır, istemciye tamamen kapalı. Satır elle
-- eklenir (SETUP.md); yoksa temizlik çalışmaz ve Yönetici uyarılır.
create table if not exists public.foto_temizlik_ayar (
  id         smallint primary key default 1 check (id = 1),
  url        text not null check (url ~ '^https://'),
  gizli      text not null check (length(gizli) >= 16),
  updated_at timestamptz not null default now()
);
alter table public.foto_temizlik_ayar enable row level security;
revoke all on public.foto_temizlik_ayar from anon, authenticated;

-- ---------------------------------------------------------------- liste ---

-- Saklama süresini aşan plaka-foto dosyalarının ADLARI, en eski önce, en
-- fazla 1000 (Storage API'nin tek çağrıda sildiği sayı). Yalnızca OKUR;
-- kaydı okumak doğrudur, yanlış olan SQL ile silmekti. Ayar 025 ile aynı
-- okunur (coalesce 30, 0 ya da altı = silme yok — 024 artık 1–30'a zorlar).
create or replace function public.foto_temizlik_listesi(p_limit integer default 1000)
returns setof text
language sql stable security definer set search_path = public as $fn$
  with ayar as (
    select coalesce((select a.foto_saklama_gun
                       from public.otopark_ayarlari a where a.id = 1), 30) as gun
  )
  select o.name
    from storage.objects o, ayar
   where o.bucket_id = 'plaka-foto'
     and ayar.gun > 0
     and o.created_at < now() - make_interval(days => ayar.gun)
   order by o.created_at, o.name
   limit greatest(0, least(coalesce(p_limit, 1000), 1000));
$fn$;

-- ----------------------------------------------------------------- uyarı ---

create or replace function public.foto_temizlik_hata(p_mesaj text) returns void
language plpgsql security definer set search_path = public as $fn$
begin
  -- Gece işi günde bir koşar; 20 saat 025'in günlük uyarılarıyla aynı pencere.
  if exists (select 1 from public.notifications n
              where n.tur = 'KAMERA' and n.baslik = 'Fotoğraf temizliği başarısız'
                and n.created_at > now() - interval '20 hours') then
    return;
  end if;
  perform public.notify_yonetici('KAMERA', 'Fotoğraf temizliği başarısız',
    'Saklama süresi dolan fotoğraflar silinemedi: '
      || left(coalesce(nullif(btrim(p_mesaj), ''), 'bilinmeyen hata'), 300),
    '/yonetim/ayarlar');
end
$fn$;

-- -------------------------------------------------------------- tetikle ---

create or replace function public.foto_temizlik_tetikle() returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_ayar public.foto_temizlik_ayar;
begin
  select * into v_ayar from public.foto_temizlik_ayar where id = 1;
  if not found then
    if not exists (select 1 from public.notifications n
                    where n.tur = 'KAMERA' and n.baslik = 'Fotoğraf temizliği kurulmamış'
                      and n.created_at > now() - interval '20 hours') then
      perform public.notify_yonetici('KAMERA', 'Fotoğraf temizliği kurulmamış',
        'Saklama süresi dolan fotoğraflar silinmiyor: temizlik kurulumu eksik '
          || '(SETUP.md, fotoğraf temizliği adımı).',
        '/yonetim/ayarlar');
    end if;
    return;
  end if;
  -- pg_net'in varsayılan bekleme süresi 5 sn; temizlik binlerce dosyada daha
  -- uzun sürebilir. İstek bu işlem commit olunca gönderilir.
  perform net.http_post(
    url                  := v_ayar.url,
    body                 := '{}'::jsonb,
    headers              := jsonb_build_object(
                              'Content-Type', 'application/json',
                              'x-temizlik-secret', v_ayar.gizli),
    timeout_milliseconds := 120000
  );
end
$fn$;

-- --------------------------------------------------------- gece işi -----

-- 025'in gövdesi birebir; yalnızca 3. adımdaki SQL silme kaldırıldı ve
-- sonuna 8. adım (temizliği tetikle) eklendi. 025'ten sonra bu fonksiyonu
-- yeniden tanımlayan migration yok (004 → 025 → 043).
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
end
$fn$;

-- ------------------------------------------------------------- grants ----

-- `from public` şart: anon/authenticated yetkiyi PUBLIC'ten miras alır.
revoke all on function public.foto_temizlik_listesi(integer)
  from public, anon, authenticated;
grant execute on function public.foto_temizlik_listesi(integer) to service_role;

revoke all on function public.foto_temizlik_hata(text)
  from public, anon, authenticated;
grant execute on function public.foto_temizlik_hata(text) to service_role;

revoke all on function public.foto_temizlik_tetikle()
  from public, anon, authenticated, service_role;

-- Aynı imza, yani mevcut yetkiler zaten korunur; yine de açıkça.
revoke all on function public.run_gunluk_bakim()
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------- doğrulama ---

do $do$
declare
  r      text;
  v_def  text;
begin
  -- timeout_milliseconds parametreli imza: yoksa her gece tetikleme hata
  -- verir (alt blok onu yutar) ve hiçbir dosya silinmezdi.
  if to_regprocedure('net.http_post(text, jsonb, jsonb, jsonb, integer)') is null then
    raise exception '043: pg_net net.http_post(url, body, params, headers, timeout_milliseconds) yok';
  end if;

  v_def := pg_get_functiondef('public.run_gunluk_bakim()'::regprocedure);
  if v_def ~* 'delete\s+from\s+storage\.objects' then
    raise exception '043: run_gunluk_bakim hâlâ storage tablosundan SQL ile siliyor';
  end if;
  if position('foto_temizlik_tetikle' in v_def) = 0 then
    raise exception '043: run_gunluk_bakim temizliği tetiklemiyor';
  end if;

  foreach r in array array['public.foto_temizlik_listesi(integer)',
                           'public.foto_temizlik_hata(text)'] loop
    if not has_function_privilege('service_role', r, 'execute') then
      raise exception '043: % service_role rolüne kapalı — foto-temizle çağıramaz', r;
    end if;
    if has_function_privilege('anon', r, 'execute')
       or has_function_privilege('authenticated', r, 'execute') then
      raise exception '043: % istemciye açık', r;
    end if;
  end loop;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(r, 'public.foto_temizlik_tetikle()', 'execute') then
      raise exception '043: foto_temizlik_tetikle % rolüne açık', r;
    end if;
  end loop;
  if has_table_privilege('anon', 'public.foto_temizlik_ayar', 'select')
     or has_table_privilege('authenticated', 'public.foto_temizlik_ayar', 'select') then
    raise exception '043: temizliğin gizli anahtarı istemciye açık';
  end if;

  if (select count(*) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('foto_temizlik_listesi', 'foto_temizlik_hata',
                           'foto_temizlik_tetikle')
         and p.prosecdef and p.proconfig @> array['search_path=public']) <> 3 then
    raise exception '043: temizlik fonksiyonları SECURITY DEFINER + search_path=public değil';
  end if;
end
$do$;

commit;
