-- ============================================================================
-- 076  İçeride listesi bütün açık biletleri getirir
-- ============================================================================

begin;

-- Sahip (2026-11-23): `acik_bilet_ara` (052) aramasız listeyi `limit 50` ile
-- kesiyordu, en yeniden eskiye. İçeride 76 araç varken en ESKİ 26'sı —
-- terk edilmiş olabilecek araçlar — Gişe'nin İçeride listesine hiç gelmiyor,
-- başlık da 50 diyordu. Uygulama listeyi artık 25'er çiziyor
-- (src/features/gise/iceride.ts, "Daha fazla göster"); bu yüzden sunucu
-- aramasız listede bütün açık biletleri verir.
--
-- Yazılı aramada sınır 50 olarak KALIR: uygulama bir aramanın sonucunu hiç
-- kesmez (aranan araç düğmenin arkasında kalmasın diye), tek harflik bir
-- arama yavaş cihazda yüzlerce satır çizdirmesin.
--
-- 052'nin gövdesi birebir; yalnızca son satır değişti. Postgres'te
-- `LIMIT NULL` sınırsız demektir. Dönüş tipi ve imza aynı, bu yüzden
-- `create or replace` yeter; yetkiler yine de açıkça yeniden yazılır.
-- 074 ve 075'ten bağımsızdır (sıra: 075, sonra 076). Smoke test: PASS 95.

create or replace function public.acik_bilet_ara(p_q text default null)
returns table (
  id uuid, plaka text, giris_at timestamptz,
  abonman_id uuid, park_yeri_id uuid, cikis_bekliyor_at timestamptz,
  indirim_kurus integer, puan_kullanilan integer, tarife_id uuid,
  gecikmeli_kayit boolean,
  notu_var boolean, ucret_kurus integer,
  plaka_supheli boolean,
  giris_by uuid, giris_kaynak public.kaynak,
  iptal_talebi boolean
)
language plpgsql stable security definer set search_path = public as $fn$
declare v_q text := public.normalize_plaka(p_q);
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  return query
  select b.id, b.plaka, b.giris_at,
         b.abonman_id, b.park_yeri_id, b.cikis_bekliyor_at,
         b.indirim_kurus, b.puan_kullanilan, b.tarife_id, b.gecikmeli_kayit,
         (b.notlar is not null),
         case when b.abonman_id is not null then 0
              else public.ucret_hesapla(b.giris_at, now(), b.tarife_id) end,
         b.plaka_supheli,
         b.giris_by, b.giris_kaynak,
         (b.iptal_talebi_at is not null)
    from public.biletler b
   where b.durum = 'ACIK'
     and (v_q = '' or b.plaka like '%' || v_q || '%'
                   or (length(v_q) >= 3 and right(b.plaka, length(v_q)) = v_q))
   order by
     case when v_q = '' then 2
          when b.plaka = v_q then 0
          when b.plaka like v_q || '%' then 1
          else 2 end,
     b.giris_at desc
   -- Aramasız: hepsi. Yazılı arama: en çok 50.
   limit case when v_q = '' then null else 50 end;
end $fn$;

revoke all on function public.acik_bilet_ara(text) from public;
revoke all on function public.acik_bilet_ara(text) from anon, authenticated, service_role;
grant execute on function public.acik_bilet_ara(text) to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
begin
  if not has_function_privilege('authenticated', 'public.acik_bilet_ara(text)', 'execute') then
    raise exception '076: acik_bilet_ara authenticated rolüne kapalı';
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, 'public.acik_bilet_ara(text)', 'execute') then
      raise exception '076: acik_bilet_ara % rolüne açık', r;
    end if;
  end loop;
  if not exists (select 1 from pg_proc where oid = 'public.acik_bilet_ara(text)'::regprocedure
                  and prosecdef and proconfig @> array['search_path=public']) then
    raise exception '076: acik_bilet_ara SECURITY DEFINER + search_path=public değil';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'acik_bilet_ara') <> 1 then
    raise exception '076: acik_bilet_ara birden çok imzayla tanımlı';
  end if;
end
$do$;

commit;
