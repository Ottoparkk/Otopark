-- ============================================================================
-- 018  Maaş kolonları istemciye kapalı + personel listesi
-- ============================================================================

begin;

-- 003'teki `profiles_select`, biletin kimin açtığını yazabilmek için her aktif
-- personelin birbirinin SATIRINI görmesine izin verir; RLS'in kolon boyutu
-- yoktur. 016 maaşı bu tabloya eklediği anda tablo geneli SELECT, herkesin
-- maaşını herkese açar. Tek çare kolon bazlı grant.
revoke select on public.profiles from anon, authenticated;
grant select (id, ad_soyad, rol, durum, notif_prefs, created_at)
  on public.profiles to authenticated;

create or replace function public.personel_listesi()
returns table (
  id uuid, ad_soyad text, rol public.rol, durum public.kullanici_durum,
  maas_kurus integer, odeme_gunu smallint, maas_yontemi public.odeme_yontemi,
  created_at timestamptz
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  return query
  select p.id, p.ad_soyad, p.rol, p.durum, p.maas_kurus, p.odeme_gunu,
         p.maas_yontemi, p.created_at
    from public.profiles p
   order by p.durum, p.ad_soyad;
end $$;

revoke all on function public.personel_listesi()
  from public, anon, authenticated, service_role;
grant execute on function public.personel_listesi() to authenticated;

-- -------------------------------------------------------------- verify ---
do $$
begin
  if has_column_privilege('authenticated', 'public.profiles', 'maas_kurus', 'SELECT')
     or has_column_privilege('authenticated', 'public.profiles', 'odeme_gunu', 'SELECT')
     or has_column_privilege('authenticated', 'public.profiles', 'maas_yontemi', 'SELECT') then
    raise exception '018: maaş kolonları istemciye açık';
  end if;

  -- Kimlik kolonları açık KALMALI: isim olmadan bilet kartı kimin açtığını
  -- yazamaz, oturum açan kullanıcı kendi rolünü okuyamaz ve uygulama açılmaz.
  if not has_column_privilege('authenticated', 'public.profiles', 'ad_soyad', 'SELECT')
     or not has_column_privilege('authenticated', 'public.profiles', 'rol', 'SELECT')
     or not has_column_privilege('authenticated', 'public.profiles', 'durum', 'SELECT')
     or not has_column_privilege('authenticated', 'public.profiles', 'notif_prefs', 'SELECT') then
    raise exception '018: kimlik kolonları kapandı';
  end if;

  if has_function_privilege('anon', 'public.personel_listesi()', 'execute')
     or has_function_privilege('service_role', 'public.personel_listesi()', 'execute') then
    raise exception '018: personel_listesi fazla açık';
  end if;
  if not has_function_privilege('authenticated', 'public.personel_listesi()', 'execute') then
    raise exception '018: personel_listesi Yöneticiye kapalı';
  end if;
end $$;

commit;
