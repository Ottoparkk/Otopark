-- ============================================================================
-- 022  Çöp kutusu anon rolüne kapalı
-- ============================================================================

begin;

-- Supabase, `public` şemasında yaratılan HER tabloya anon ve authenticated
-- için varsayılan yetki verir. 003 bir süpürme yapar ama yalnızca o an var
-- olan tablolar için; sonradan doğan her tablo kendi revoke'unu taşımak
-- zorundadır. 014 ve 016 bunu yapar, 007 `cop` için unutmuş.
--
-- RLS (cop_select → is_yonetici) sayesinde anon sıfır satır görüyordu, yani
-- sızıntı OLMADI — ama yetki ile politika birbirinin yedeğidir, biri
-- diğerinin yerine geçmez. Bu tabloda silinen biletler, tahsilatlar ve
-- müşteri bilgileri duruyor.
revoke all on public.cop from anon;

-- authenticated'ın SELECT'i 007'den kalır; yazma yolu zaten yok.
grant select on public.cop to authenticated;
revoke insert, update, delete on public.cop from authenticated;

-- -------------------------------------------------------------- verify ---
do $$
begin
  if has_table_privilege('anon', 'public.cop', 'SELECT')
     or has_table_privilege('anon', 'public.cop', 'INSERT')
     or has_table_privilege('anon', 'public.cop', 'UPDATE')
     or has_table_privilege('anon', 'public.cop', 'DELETE') then
    raise exception '022: cop hâlâ anon rolüne açık';
  end if;
  if not has_table_privilege('authenticated', 'public.cop', 'SELECT') then
    raise exception '022: Yöneticinin çöp okuma yetkisi düştü';
  end if;
  if has_table_privilege('authenticated', 'public.cop', 'DELETE') then
    raise exception '022: çöpe doğrudan silme yolu açık';
  end if;
end $$;

commit;
