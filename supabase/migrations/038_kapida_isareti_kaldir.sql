-- ============================================================================
-- 038  Yanlış "Kapıda" işareti: kapıdaki personel kaldırabilir, izi kalır
-- ============================================================================

begin;

-- ------------------------------------------------------------ fonksiyon ----

-- Kamera bir aracı çıkıyor sandığında `cikis_bekliyor_at` damgalanır
-- (kamera_cikis_bildir, 002). Hiçbir şey onu geri almıyordu: yanlış bir damga
-- bilet kapanana kadar listede "Kapıda" diye durur, kapıya bakan personel de
-- çıkmayan bir aracı arar. Tek kapıda (037) bu daha sık: kapıda bekleyen ya
-- da kamerada görünmeye devam eden araç çıkıyor sayılabilir.
--
-- Kaldırmak PARA DEĞİLDİR — ücret, tahsilat, yer, vardiya değişmez — ama
-- bileti değiştirir. Bu yüzden:
--   · yalnızca aktif personel (is_staff: rolü olan ve ACTIVE olan herkes;
--     kapıda çalışan Personel'in kendisi). Bekleyen/devre dışı hesap kaldıramaz.
--   · yalnızca AÇIK bilet. Kapanmış biletin damgası tarihtir; ayrıca
--     biletler_immutable_guard onu zaten korur, ama hata sebebi burada
--     anlaşılır biçimde söylenir.
--   · her kaldırma audit_log'a eski damgasıyla yazılır.
--   · `cikis_foto` BİLEREK korunur: kameranın neyi gördüğünün tek kanıtı.
--   · işaretsiz bilette çağrı zararsızdır (false döner, iz yazmaz) — çift
--     basış ya da iki operatörün aynı anda basması hata üretmesin.
create or replace function public.bilet_kapida_temizle(p_bilet_id uuid) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare
  v_durum text;
  v_eski  timestamptz;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  -- Satır kilitlenir: aynı anda gelen kamera damgası ile kaldırma birbirini
  -- ezmesin, iki kaldırma da tek iz yazsın.
  select b.durum::text, b.cikis_bekliyor_at
    into v_durum, v_eski
    from public.biletler b
   where b.id = p_bilet_id
     for update;

  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_durum <> 'ACIK' then
    raise exception 'Bilet açık değil; kapıda işareti kaldırılamaz.';
  end if;
  if v_eski is null then
    return false;
  end if;

  update public.biletler
     set cikis_bekliyor_at = null
   where id = p_bilet_id;

  perform public.audit('bilet_kapida_temizlendi', 'biletler', p_bilet_id,
                       jsonb_build_object('eski', v_eski));
  return true;
end
$fn$;

-- -------------------------------------------------------------- yetki -----

-- from public OLMADAN hiçbir şey kapanmaz (012); service_role OLMADAN da (033).
-- Kamera bu kapıyı kullanmaz: damgayı vuran o, kaldıran insan olmalı.
revoke all on function public.bilet_kapida_temizle(uuid) from public;
revoke all on function public.bilet_kapida_temizle(uuid) from anon, authenticated, service_role;
grant execute on function public.bilet_kapida_temizle(uuid) to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
begin
  if not has_function_privilege('authenticated',
       'public.bilet_kapida_temizle(uuid)', 'execute') then
    raise exception '038: bilet_kapida_temizle authenticated rolüne kapalı — ekran çalışmaz';
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, 'public.bilet_kapida_temizle(uuid)', 'execute') then
      raise exception '038: bilet_kapida_temizle % rolüne açık', r;
    end if;
  end loop;

  -- Fonksiyon gerçekten SECURITY DEFINER ve arama yolu sabit mi.
  if not exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'bilet_kapida_temizle'
       and p.prosecdef
       and p.proconfig @> array['search_path=public']
  ) then
    raise exception '038: bilet_kapida_temizle SECURITY DEFINER + search_path=public değil';
  end if;
end
$do$;

commit;
