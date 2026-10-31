-- ============================================================================
-- 040  Kamera okuma sınırı: ücretli plaka okumaları sayılır ve sınırlanır
-- ============================================================================

begin;

-- ------------------------------------------------------------- etiket -----

-- Kameradan gelen her fotoğraf parayla okunur (Claude; sınırdaki okumada bir
-- ikinci görüş daha). kamera-webhook'un eski sınırı yalnızca BİLETLERİ
-- sayıyordu ve okumaların çoğu bilet açmaz: boş şerit, okunamayan plaka,
-- okuma hatası, her çıkış, her yeniden deneme. Yani okumalar sınırsızdı;
-- bozulmuş bir köprü ya da sızmış bir kamera anahtarı faturayı istediği kadar
-- büyütebilirdi.
--
-- Artık webhook her kamera okumasını bu kolonla `KAMERA` diye yazar ve
-- okumadan ÖNCE son 1 dakikanın ve 24 saatin bu satırlarını sayar (sınır
-- sayıları webhook'ta: _shared/serit.ts — dakikada 20, günde 1500, bütün
-- şeritler birlikte). Sınırın üstünde 429 döner.
--
-- VARSAYILAN YOK, bilerek: telefon okuması (plaka-oku) kaynak yazmaz ve
-- kameranın sınırına sayılmamalı. Eski satırlar boş kalır (geri doldurma
-- yok); 24 saatlik pencere yayın günü boş başlar.
--
-- İstemci bu satırları ne yazabilir ne değiştirebilir ne silebilir: günlükte
-- yalnızca SELECT politikası var (003). Sahte bir KAMERA satırı sınırı
-- doldurup kamerayı kilitlerdi, silmek sınırı sıfırlardı (smoke test 62d).
alter table public.plaka_okuma_log
  add column if not exists kaynak public.kaynak;

-- Sayım her okumadan önce iki kez koşar; yalnızca kamera satırlarını tutan
-- kısmi indeks onu günün okuma sayısıyla sınırlı tutar.
create index if not exists plaka_okuma_log_kamera_ix
  on public.plaka_okuma_log (created_at desc)
  where kaynak = 'KAMERA';

-- ------------------------------------------------------------- uyarı ------

-- Sınır aşıldı: webhook 429 döner, köprü birkaç kez yeniden dener ve sonra
-- aracı bırakır ("araç elle girilmeli"). Araç başına kayıt YAZILMAZ: sızmış
-- bir anahtarla gelen sel, çözülmemiş kayıtlar listesini sahte araçlarla
-- doldururdu. Tek iz bu uyarıdır — saatte EN FAZLA bir kez (039 deseni).
--
-- Sayılar çağırandan alınmaz, burada sayılır: mesaj, webhook ne derse desin
-- günlükte olanı söyler. Sınırın kendisi webhook'ta olduğu için mesaj onu
-- yazmaz.
--
-- Link bilerek '/yonetim/kameralar' DEĞİL: kamera nöbetçisi (037) uyarılarını
-- tam link üzerinden tekilleştirir ('/yonetim/kameralar' elle kurulmuş köprü,
-- '?c=<id>' eşleştirilmiş kamera). Aynı link "kameradan haber yok" uyarısını
-- bir saat susturabilirdi. Kameralar ekranı yalnızca `c` parametresini okur,
-- buradaki parametre yok sayılır.
create or replace function public.kamera_okuma_siniri()
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_dakika integer;
  v_gun    integer;
begin
  -- is_staff() guard'ı YOK ve olamaz (webhook'ta auth.uid() null). Tersi var:
  -- JWT taşıyan çağıran reddedilir. Tekilleştirmeden ÖNCE: sonra olsaydı saat
  -- içindeki bir çağrı sessizce dönerdi. Asıl sınır grant'tır.
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.';
  end if;

  -- Aynı anda gelen iki 429'un ikisinin de "henüz uyarılmadı" okuması.
  perform pg_advisory_xact_lock(hashtext('kamera_okuma_siniri'));

  if exists (
    select 1 from public.notifications n
     where n.tur = 'KAMERA' and n.baslik = 'Kamera okuma sınırı aşıldı'
       and n.created_at > now() - interval '60 minutes'
  ) then
    return;
  end if;

  select count(*) filter (where l.created_at >= now() - interval '60 seconds'),
         count(*)
    into v_dakika, v_gun
    from public.plaka_okuma_log l
   where l.kaynak = 'KAMERA'
     and l.created_at >= now() - interval '24 hours';

  perform public.notify_yonetici(
    'KAMERA', 'Kamera okuma sınırı aşıldı',
    'Kameradan beklenenden çok fotoğraf geliyor (son 1 dakikada ' || v_dakika
      || ', son 24 saatte ' || v_gun || ' okuma). Sayı düşene kadar yeni '
      || 'fotoğraflar okunmuyor; bu sürede kameradan gelen araçları elle girin. '
      || 'Kamera köprüsünün düzgün çalıştığını ve kamera anahtarının başkasının '
      || 'eline geçmediğini kontrol edin.',
    '/yonetim/kameralar?okuma=sinir');
end
$fn$;

-- -------------------------------------------------------------- yetki -----

-- from public OLMADAN hiçbir şey kapanmaz (012); service_role'e AÇIKÇA verilir
-- (033). İstemciye açık olsaydı herkes sahte "sınır aşıldı" uyarısı
-- üretebilirdi.
revoke all on function public.kamera_okuma_siniri() from public;
revoke all on function public.kamera_okuma_siniri() from anon, authenticated, service_role;
grant execute on function public.kamera_okuma_siniri() to service_role;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
begin
  if not exists (
    select 1 from information_schema.columns c
     where c.table_schema = 'public' and c.table_name = 'plaka_okuma_log'
       and c.column_name = 'kaynak'
       and c.udt_schema = 'public' and c.udt_name = 'kaynak'
       and c.is_nullable = 'YES' and c.column_default is null
  ) then
    raise exception '040: plaka_okuma_log.kaynak yok ya da biçimi yanlış (kaynak enum, boş olabilir, varsayılansız)';
  end if;

  if not exists (
    select 1 from pg_indexes i
     where i.schemaname = 'public' and i.tablename = 'plaka_okuma_log'
       and i.indexname = 'plaka_okuma_log_kamera_ix'
       and i.indexdef like '%WHERE%kaynak%KAMERA%'
  ) then
    raise exception '040: plaka_okuma_log_kamera_ix kısmi indeksi yok';
  end if;

  if not has_function_privilege('service_role', 'public.kamera_okuma_siniri()', 'execute') then
    raise exception '040: kamera_okuma_siniri service_role rolüne kapalı — webhook çağıramaz';
  end if;
  foreach r in array array['anon', 'authenticated'] loop
    if has_function_privilege(r, 'public.kamera_okuma_siniri()', 'execute') then
      raise exception '040: kamera_okuma_siniri % rolüne açık', r;
    end if;
  end loop;

  if not exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'kamera_okuma_siniri'
       and p.prosecdef
       and p.proconfig @> array['search_path=public']
  ) then
    raise exception '040: kamera_okuma_siniri SECURITY DEFINER + search_path=public değil';
  end if;
end
$do$;

commit;
