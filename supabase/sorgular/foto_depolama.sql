-- ============================================================================
-- Fotoğraf depolama — salt okunur kontroller (hiçbir şey değiştirmez)
-- ============================================================================
--
-- Her sorguyu ayrı çalıştırın. Ücretsiz planda dosya depolama 1 GB'dır;
-- telefon ve kamera fotoğrafları aynı kovayı (plaka-foto) paylaşır.

-- 1. Kova ne kadar tutuyor (kayıtlara göre)? Bunu panodaki
--    Usage → Storage size ile karşılaştırın. Pano belirgin şekilde FAZLA
--    gösteriyorsa, 043'ten önce SQL ile silinmiş yetim dosyalar vardır: API
--    onları bulamaz, temizlemek için Supabase desteğine yazmak gerekir.
select count(*) as foto,
       round(sum((metadata ->> 'size')::bigint) / 1048576.0, 1) as mb
  from storage.objects
 where bucket_id = 'plaka-foto';

-- 2. Kamera ve telefon ayrı ayrı; ortalama ve en büyük dosya.
select case when name like 'kamera/%' then 'kamera' else 'telefon' end as kaynak,
       count(*) as foto,
       round(avg((metadata ->> 'size')::int) / 1024.0, 1) as ort_kb,
       round(max((metadata ->> 'size')::int) / 1024.0, 1) as en_buyuk_kb,
       round(sum((metadata ->> 'size')::bigint) / 1048576.0, 1) as toplam_mb
  from storage.objects
 where bucket_id = 'plaka-foto'
 group by 1;

-- 3. Saklama süresini aşmış ama hâlâ duran dosya sayısı. Temizlik çalışıyorsa
--    gece işinden sonra 0'a yakın olmalı.
select count(*) as suresi_dolmus
  from storage.objects o
 where o.bucket_id = 'plaka-foto'
   and o.created_at < now() - make_interval(days => coalesce(
         (select a.foto_saklama_gun from public.otopark_ayarlari a where a.id = 1), 30));

-- 4. Gece işi başarılı mı (son 7 gece)?
select start_time, status, left(return_message, 200) as mesaj
  from cron.job_run_details
 where jobid = (select jobid from cron.job where jobname = 'otopark-gunluk')
 order by start_time desc
 limit 7;
