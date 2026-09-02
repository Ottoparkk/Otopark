-- ============================================================================
-- 015  Ödeme yöntemine göre dağılım (Nakit / Kredi Kartı / Havale)
-- ============================================================================
--
-- Owner request (2026-08-31): PilotGarage'daki gibi, Net kartında paranın
-- hangi kanaldan geldiği de görünsün.
--
-- ÜÇ NOKTA:
--
-- 1. AYNI İKİ KAYNAK, AYNI TARİH KURALI. Panodaki Net iki yerden gelir:
--    `tahsilatlar` (bilet ve abonman tahsilatı) ve `kasa_hareketleri` (ek
--    gelir ve gider). Bu fonksiyon ikisini de `rapor_ozet` ile BİREBİR aynı
--    tarih ölçütüyle okur — tahsilat `created_at`'in İstanbul tarihi, kasa
--    ise zaten tarih kolonu. Ölçüt ayrışırsa dağılım toplamı tutmaz ve hangi
--    sayının doğru olduğu sorusu cevapsız kalır.
--
-- 2. YÖNTEMSİZ SATIR HİÇBİR KOVAYA GİRMEZ. `yontem` her iki tabloda da
--    nullable (kasa formunda "isteğe bağlı"). O satırlar Net'i oynatır ama
--    burada sayılmaz, dolayısıyla Nakit+KK+Havale toplamı Net'ten KÜÇÜK
--    olabilir. Bu bir hata değil, eksik veridir — uydurup bir kovaya atmak,
--    olmayan bir bilgiyi varmış gibi göstermek olurdu.
--
-- 3. YÖNETİCİ'YE ÖZEL. SECURITY DEFINER olduğu için RLS devre dışı kalır;
--    tek sınır fonksiyonun içindeki `is_yonetici()` kontrolüdür. Personel
--    kasayı ve tahsilat geçmişini zaten göremez, bu kapı da onlara kapalı.
-- ============================================================================

begin;

create or replace function public.yontem_ozet(p_bas date, p_bit date)
returns table (
  yontem      public.odeme_yontemi,
  gelir_kurus bigint,
  gider_kurus bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;

  return query
  select h.yontem,
         coalesce(sum(h.gelir), 0)::bigint,
         coalesce(sum(h.gider), 0)::bigint
    from (
      -- Bilet ve abonman tahsilatı: her zaman gelirdir.
      select t.yontem, t.tutar_kurus as gelir, 0 as gider
        from public.tahsilatlar t
       where (t.created_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit
      union all
      select k.yontem,
             case when k.tur = 'GELIR' then k.tutar_kurus else 0 end,
             case when k.tur = 'GIDER' then k.tutar_kurus else 0 end
        from public.kasa_hareketleri k
       where k.tarih between p_bas and p_bit
    ) h
   where h.yontem is not null
   group by h.yontem;
end $$;

-- 012'nin dersi: `from public` tek başına hiçbir şey kapatmaz.
revoke all on function public.yontem_ozet(date, date)
  from public, anon, authenticated, service_role;
grant execute on function public.yontem_ozet(date, date) to authenticated;

do $$
begin
  if has_function_privilege('anon', 'public.yontem_ozet(date, date)', 'execute')
     or has_function_privilege('service_role', 'public.yontem_ozet(date, date)', 'execute') then
    raise exception '015: yontem_ozet yanlış role açık';
  end if;
  if not has_function_privilege('authenticated', 'public.yontem_ozet(date, date)', 'execute') then
    raise exception '015: yontem_ozet yöneticiye kapalı kaldı';
  end if;
end $$;

commit;
