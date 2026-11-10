-- ============================================================================
-- 052  "Kapıda" uygulamadan kalktı; kameranın çıkış bildirimi kaldı
-- ============================================================================

begin;

-- Sahibin isteği (2026-11-10): Gişe'deki "Kapıda" rozeti, "N araç çıkış
-- kapısında bekliyor" şeridi ve "Araç çıkmadı" düğmesi kaldırılıyor (yalnızca
-- uygulama). Kameranın "Araç çıkış yaptı — ödeme tahsil edilebilir" bildirimi
-- KALIYOR (019). Sunucuda damga (`biletler.cikis_bekliyor_at`) ve onu yazan
-- `kamera_cikis_bildir` aynen kalır — bildirimin tetiği odur; sütun ve veri
-- silinmez. `bilet_kapida_temizle` (038) de kalır (artık uygulama çağırmıyor;
-- PASS 59 onu sınamaya devam eder).
--
-- Damga artık ekranda görünmediği için iki şey düzeltilir (PASS 74):
--   (a) Açık bilet listesi (`acik_bilet_ara`) damgayı sıralamada KULLANMAZ —
--       aksi hâlde araç görünmez bir sebeple en üstte durur; yanlış bir damga
--       ("Araç çıkmadı" düğmesi yok) onu bütün kalışı boyunca orada tutardı.
--   (b) Çıkış bildirimi yalnızca İLK damgada değil, kamera her YENİ çıkış anı
--       yazdığında gider. Eskiden tetik "boştan doluya" geçişe bakıyordu:
--       aracın kapıda bir an görünmesi (yanlış damga) gerçek çıkışın
--       bildirimini yutardı. Aynı olayın tekrarı (yeniden gönderim, aynı an)
--       damgayı değiştirmez → ikinci bildirim yok.

-- ------------------------------------------------- (a) açık bilet listesi ----
-- 050'nin gövdesi birebir; yalnızca `order by`dan `b.cikis_bekliyor_at desc
-- nulls last` çıktı. Dönüş tipi aynı (uygulama sütunu hâlâ okuyabilir), bu
-- yüzden `create or replace` yeter; yetkiler yine de açıkça yeniden yazılır.

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
   limit 50;
end $fn$;

revoke all on function public.acik_bilet_ara(text) from public;
revoke all on function public.acik_bilet_ara(text) from anon, authenticated, service_role;
grant execute on function public.acik_bilet_ara(text) to authenticated;

-- --------------------------------------------- (b) çıkış bildirimi tetiği ----
-- Fonksiyon (019) aynen; yalnızca tetiğin koşulu: yeni, dolu ve ÖNCEKİNDEN
-- FARKLI bir çıkış anı. `is distinct from` boştan doluya geçişi de kapsar.

drop trigger if exists kamera_cikis_bildirim_tg on public.biletler;
create trigger kamera_cikis_bildirim_tg
  after update on public.biletler
  for each row
  when (new.cikis_bekliyor_at is not null
        and old.cikis_bekliyor_at is distinct from new.cikis_bekliyor_at)
  execute function public.kamera_cikis_bildirimi();

revoke all on function public.kamera_cikis_bildirimi()
  from public, anon, authenticated, service_role;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
begin
  if not has_function_privilege('authenticated', 'public.acik_bilet_ara(text)', 'execute') then
    raise exception '052: acik_bilet_ara authenticated rolüne kapalı';
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, 'public.acik_bilet_ara(text)', 'execute') then
      raise exception '052: acik_bilet_ara % rolüne açık', r;
    end if;
  end loop;
  if not exists (select 1 from pg_proc where oid = 'public.acik_bilet_ara(text)'::regprocedure
                  and prosecdef and proconfig @> array['search_path=public']) then
    raise exception '052: acik_bilet_ara SECURITY DEFINER + search_path=public değil';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'acik_bilet_ara') <> 1 then
    raise exception '052: acik_bilet_ara birden çok imzayla tanımlı';
  end if;

  if not exists (select 1 from pg_trigger
                  where tgname = 'kamera_cikis_bildirim_tg'
                    and tgrelid = 'public.biletler'::regclass and not tgisinternal) then
    raise exception '052: kamera_cikis_bildirim_tg tetiği yok';
  end if;
  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(r, 'public.kamera_cikis_bildirimi()', 'execute') then
      raise exception '052: kamera_cikis_bildirimi % rolüne açık', r;
    end if;
  end loop;
end
$do$;

commit;
