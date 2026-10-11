-- ============================================================================
-- Plaka okuma doğruluğu — salt okunur rapor (hiçbir şey değiştirmez)
-- ============================================================================

with l as (
  select * from public.plaka_okuma_log
),
onayli as (
  select * from l where onerilen is not null and kabul_edilen is not null
),
ozet (sira, bolum, detay, sirala) as (
  select 1, 'A. Özet — ' || saglayici,
         format(
           'okuma %s | sağlayıcı hatası %s | okunamadı %s | operatör onaylı %s | doğru %s | yanlış %s | doğruluk %s',
           count(*),
           count(*) filter (where guven is null),
           count(*) filter (where guven is not null and onerilen is null),
           count(*) filter (where kabul_edilen is not null),
           count(*) filter (where onerilen = kabul_edilen),
           count(*) filter (where onerilen <> kabul_edilen),
           coalesce(
             round(
               100.0 * count(*) filter (where onerilen = kabul_edilen)
               / nullif(count(*) filter (where onerilen is not null and kabul_edilen is not null), 0),
               1
             )::text || '%',
             '—'
           )
         ),
         -count(*)::numeric
    from l
   group by saglayici
),
bant (sira, bolum, detay, sirala) as (
  select 2,
         'B. Güven bandı — ' || case
           when guven < 0.50 then '1) 0.50 altı'
           when guven < 0.75 then '2) 0.50–0.75'
           when guven < 0.92 then '3) 0.75–0.92'
           else '4) 0.92 ve üstü'
         end,
         format(
           'onaylı %s | doğru %s | yanlış %s',
           count(*),
           count(*) filter (where onerilen = kabul_edilen),
           count(*) filter (where onerilen <> kabul_edilen)
         ),
         0::numeric
    from onayli
   where guven is not null
   group by 2
),
karakter (sira, bolum, detay, sirala) as (
  select 3, 'C. Karakter karışıklığı',
         format(
           'model "%s" okudu, doğrusu "%s" — %s kez',
           substr(onerilen, i, 1), substr(kabul_edilen, i, 1), count(*)
         ),
         -count(*)::numeric
    from onayli
   cross join lateral generate_series(1, length(onerilen)) as i
   where length(onerilen) = length(kabul_edilen)
     and substr(onerilen, i, 1) <> substr(kabul_edilen, i, 1)
   group by substr(onerilen, i, 1), substr(kabul_edilen, i, 1)
),
yanlis (sira, bolum, detay, sirala) as (
  select 4, 'D. Son yanlış okumalar',
         format(
           '%s → %s | güven %s | %s | %s',
           onerilen, kabul_edilen, coalesce(guven::text, '—'), saglayici,
           to_char(created_at at time zone 'Europe/Istanbul', 'YYYY-MM-DD HH24:MI')
         ),
         row_number() over (order by created_at desc)::numeric
    from onayli
   where onerilen <> kabul_edilen
   order by created_at desc
   limit 40
)
select bolum, detay
  from (
    select * from ozet
    union all select * from bant
    union all select * from karakter
    union all select * from yanlis
  ) t
 order by sira, sirala, bolum;
