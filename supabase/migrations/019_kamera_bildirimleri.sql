-- ============================================================================
-- 019  Kamera giriş/çıkış bildirimleri
-- ============================================================================

-- PostgreSQL, aynı transaction içinde EKLENEN bir enum değerinin
-- KULLANILMASINA izin vermez ve SQL editörü betiğin tamamını tek transaction
-- olarak çalıştırır — `begin` dışına almak bu yüzden yetmez. Dolayısıyla bu
-- dosyada değer hiçbir yerde enum literali olarak kullanılmaz: karşılaştırmalar
-- `::text` üzerinden yapılır, tetikleyici gövdeleri ise plpgsql olduğu için
-- ancak ÇALIŞMA anında (yani bu transaction commit olduktan sonra) çözülür.
alter type public.bildirim_tur add value if not exists 'KAMERA_HAREKET';

begin;

-- Tetikleyici, `bilet_ac`'ı yeniden yazmak yerine: o gövde uzun ve para yolunun
-- ta kendisi. Bildirim eklemek için onu kopyalamak, ilgisiz otuz satırda harf
-- hatası yapma riskini bedavaya satın almak olurdu.
create or replace function public.kamera_giris_bildirimi() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.notify_yonetici(
    'KAMERA_HAREKET', 'Araç girdi',
    new.plaka || ' — kameradan giriş',
    '/gise/bilet/' || new.id);
  return null;
end $$;

drop trigger if exists kamera_giris_bildirim_tg on public.biletler;
create trigger kamera_giris_bildirim_tg
  after insert on public.biletler
  for each row when (new.giris_kaynak = 'KAMERA')
  execute function public.kamera_giris_bildirimi();

-- Çıkışta kamera bileti KAPATMAZ, yalnızca `cikis_bekliyor_at` damgalar (002).
-- Bildirimin tetiği de o damga: null'dan doluya geçiş, "araç kapıda" demektir.
-- Koşul `when` içinde, gövdede değil — her bilet güncellemesinde fonksiyon
-- çağırmanın anlamı yok.
create or replace function public.kamera_cikis_bildirimi() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.notify_yonetici(
    'KAMERA_HAREKET', 'Araç çıkış yaptı',
    new.plaka || ' — ödeme tahsil edilebilir',
    '/gise/bilet/' || new.id);
  return null;
end $$;

drop trigger if exists kamera_cikis_bildirim_tg on public.biletler;
create trigger kamera_cikis_bildirim_tg
  after update on public.biletler
  for each row
  when (old.cikis_bekliyor_at is null and new.cikis_bekliyor_at is not null)
  execute function public.kamera_cikis_bildirimi();

-- Yeni tür de Yönetici'ye özeldir: RLS (003) ve send-push rol eşleşmesi bu
-- listeden okur, dolayısıyla eksik kalırsa bildirim yanlış kişiye açılır.
create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $$
  -- `p_tur::text`, enum literali değil: bu gövde SQL dilinde olduğu için
  -- yaratılırken doğrulanır ve henüz commit olmamış bir enum değeri orada
  -- kullanılamaz.
  select p_tur::text in (
    'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA','ISTISNA',
    'KAMERA_HAREKET'
  );
$$;

-- -------------------------------------------------------------- grants ---
revoke all on function public.kamera_giris_bildirimi()
  from public, anon, authenticated, service_role;
revoke all on function public.kamera_cikis_bildirimi()
  from public, anon, authenticated, service_role;

-- -------------------------------------------------------------- verify ---
do $$
begin
  if not exists (select 1 from pg_trigger
                  where tgname = 'kamera_giris_bildirim_tg' and not tgisinternal)
     or not exists (select 1 from pg_trigger
                     where tgname = 'kamera_cikis_bildirim_tg' and not tgisinternal) then
    raise exception '019: kamera bildirim tetikleyicileri kurulmadı';
  end if;

  if has_function_privilege('authenticated', 'public.kamera_giris_bildirimi()', 'execute')
     or has_function_privilege('anon', 'public.kamera_cikis_bildirimi()', 'execute') then
    raise exception '019: bildirim fonksiyonları istemciye açık';
  end if;

  -- Enum değeri gerçekten eklendi mi? KATALOGDAN okunur: `enum_range` dizinin
  -- içinde yeni DEĞERİ üretir ve bu transaction'da o da 55P04 verir — oysa
  -- pg_enum.enumlabel sıradan bir metin sütunudur.
  if not exists (
    select 1 from pg_enum e
      join pg_type t on t.oid = e.enumtypid
     where t.typname = 'bildirim_tur' and e.enumlabel = 'KAMERA_HAREKET'
  ) then
    raise exception '019: KAMERA_HAREKET enum değeri eklenmedi';
  end if;
end $$;

commit;
