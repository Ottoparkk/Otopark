-- =====================================================================
-- 092  Yönetici personelin ismini düzeltir
-- =====================================================================
begin;

-- Owner 28.11: "İsmi düzenle". 003 yalnızca kişinin KENDİ ismini
-- değiştirmesine izin veriyor (profiles_update_self + ad_soyad kolon
-- yetkisi); isim + PIN ile eklenen personel kendisi hiç giriş yapmadığı için
-- yanlış yazılmış bir ismi düzeltmenin yolu yoktu. Bu fonksiyon o yolu açar:
-- yalnızca Yönetici, herhangi bir profil için (kendisi dahil). Rol, durum ve
-- diğer kolonlara dokunmaz; tablo yetkileri ve RLS olduğu gibi kalır.
--
-- İsim kırpılır, iç boşluklar teke iner; 2–80 karakter (personel-olustur
-- Edge Function'ındaki kuralın aynısı). Eski ve yeni isim audit'e yazılır.
-- Bilet / vardiya kayıtları ismi profiles'tan okur; geçmiş kayıtlar yeni
-- ismi gösterir (kimlik aynı kişi).

create or replace function public.personel_ad_degistir(p_profile_id uuid, p_ad_soyad text)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_yeni text := regexp_replace(btrim(coalesce(p_ad_soyad, '')), '\s+', ' ', 'g');
  v_eski text;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici isim değiştirebilir.';
  end if;
  if char_length(v_yeni) < 2 or char_length(v_yeni) > 80 then
    raise exception 'İsim 2 ile 80 karakter arasında olmalı.';
  end if;

  select p.ad_soyad into v_eski from public.profiles p where p.id = p_profile_id for update;
  if not found then
    raise exception 'Kişi bulunamadı.';
  end if;

  update public.profiles set ad_soyad = v_yeni where id = p_profile_id;

  perform public.audit('personel_ad_degistir', 'profiles', p_profile_id,
                       jsonb_build_object('eski', v_eski, 'yeni', v_yeni));
end
$fn$;

revoke all on function public.personel_ad_degistir(uuid, text) from public;
revoke all on function public.personel_ad_degistir(uuid, text) from anon, authenticated, service_role;
grant execute on function public.personel_ad_degistir(uuid, text) to authenticated;

do $$
begin
  if has_function_privilege('anon', 'public.personel_ad_degistir(uuid, text)', 'execute')
     or has_function_privilege('service_role', 'public.personel_ad_degistir(uuid, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.personel_ad_degistir(uuid, text)', 'execute') then
    raise exception '092: personel_ad_degistir yetkileri yanlış';
  end if;
end $$;

commit;
