-- ============================================================================
-- 031  Kaydı kim açtı: açık bilet listesi girişi yapanı da taşısın
-- ============================================================================

begin;

-- Kartta "bu aracı kim aldı" yazabilmesi için gereken iki kolon. Kart
-- `acik_bilet_ara`dan besleniyor ve fonksiyon bunları döndürmüyordu; tabloda
-- 001'den beri duruyorlar, eksik olan yalnızca dönüş listesiydi.
--
-- `returns table` değiştiği için `create or replace` YETMEZ — önce düşürmek
-- şart, ve düşürme ACL'i de sildiği için yetki aşağıda yeniden veriliyor
-- (029'un deseni).
--
-- Gövde 029'dan birebir; tek fark dönüş listesine ve select'e eklenen iki
-- kolon.
drop function if exists public.acik_bilet_ara(text);

create or replace function public.acik_bilet_ara(p_q text default null)
returns table (
  id uuid, plaka text, giris_at timestamptz,
  abonman_id uuid, park_yeri_id uuid, cikis_bekliyor_at timestamptz,
  indirim_kurus integer, puan_kullanilan integer, tarife_id uuid,
  gecikmeli_kayit boolean,
  notu_var boolean, ucret_kurus integer,
  plaka_supheli boolean,
  giris_by uuid, giris_kaynak public.kaynak
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
         b.giris_by, b.giris_kaynak
    from public.biletler b
   where b.durum = 'ACIK'
     and (v_q = '' or b.plaka like '%' || v_q || '%'
                   or (length(v_q) >= 3 and right(b.plaka, length(v_q)) = v_q))
   order by
     case when v_q = '' then 2
          when b.plaka = v_q then 0
          when b.plaka like v_q || '%' then 1
          else 2 end,
     b.cikis_bekliyor_at desc nulls last,
     b.giris_at desc
   limit 50;
end $fn$;

revoke all on function public.acik_bilet_ara(text) from public, anon, service_role;
grant execute on function public.acik_bilet_ara(text) to authenticated;

do $do$
begin
  if not exists (
    select 1 from information_schema.routines
     where routine_schema = 'public' and routine_name = 'acik_bilet_ara') then
    raise exception 'DOĞRULAMA: acik_bilet_ara düşürüldü ama yeniden kurulmadı.';
  end if;
  if not has_function_privilege('authenticated', 'public.acik_bilet_ara(text)', 'execute') then
    raise exception 'DOĞRULAMA: acik_bilet_ara yetkisi geri verilmedi.';
  end if;
  -- service_role bu fonksiyona hiç ihtiyaç duymaz; kameranın yolu ayrıdır.
  if has_function_privilege('service_role', 'public.acik_bilet_ara(text)', 'execute')
     or has_function_privilege('anon', 'public.acik_bilet_ara(text)', 'execute') then
    raise exception 'DOĞRULAMA: acik_bilet_ara istemci dışı rollere açık kaldı.';
  end if;
end
$do$;

commit;
