-- ============================================================================
-- 059  Araç Girişi'nde giriş saati: elle girişte tarih ve saat seçilir
-- ============================================================================

begin;

-- ------------------------------------------------------------ fonksiyon ----

-- Sahip (2026-11-15): elle açılan girişte tarih ve saat ayarlanabilsin —
-- araç önceden girmiş, kayıt şimdi yapılıyor. Kurallar bilet ekranındaki
-- "Değiştir" ile AYNI (sahibin seçimi), çünkü bu da para: saati geri almak
-- ücreti artırır.
--
-- bilet_ac personel için saati BİLEREK hep sunucudan alır (030: istemci
-- saati sessiz bir eksik-ücret aracı olurdu). O kapı açılmıyor. Bu fonksiyon
-- bugün de mümkün olan iki adımı — bileti aç, sonra "Değiştir"le saatini
-- düzelt (046) — TEK çağrıda yapar:
--   · kurallar kopyalanmaz, çağrılır: plaka, park yeri, abonman, yetki
--     bilet_ac'ta; ileri saat / bir yıl / zorunlu sebep, iz (audit_log) ve
--     Yönetici bildirimi bilet_giris_duzelt'te;
--   · biri reddederse HİÇBİR ŞEY yazılmaz — bilet "şimdi"de açık kalıp
--     yanlış (düşük) ücretlenmez;
--   · yeniden deneme güvenli: aynı islem_id aynı bileti döner (bilet_ac),
--     aynı saat ikinci iz/bildirim yazmaz (bilet_giris_duzelt).
-- Kaynak her zaman MOBIL: kamera bu kapıyı kullanmaz.
create or replace function public.bilet_ac_saatli(
  p_plaka        text,
  p_islem_id     uuid,
  p_foto         text,
  p_park_yeri_id uuid,
  p_arac_bilgi   text,
  p_musteri_ad   text,
  p_musteri_tel  text,
  p_notlar       text,
  p_giris_at     timestamptz,
  p_sebep        text
) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_id uuid;
begin
  v_id := public.bilet_ac(p_plaka, p_islem_id, 'MOBIL', null, p_foto, p_park_yeri_id, null,
                          p_arac_bilgi, p_musteri_ad, p_musteri_tel, p_notlar);
  -- bilet_ac MOBIL için null dönmez (yalnızca kameranın ileri/bayat olayı);
  -- yine de sessizce "açıldı" denmesin.
  if v_id is null then
    raise exception 'Kayıt oluşturulamadı.';
  end if;
  perform public.bilet_giris_duzelt(v_id, p_giris_at, p_sebep);
  return v_id;
end
$fn$;

-- -------------------------------------------------------------- yetki -----

-- from public OLMADAN hiçbir şey kapanmaz (012); service_role OLMADAN da (033).
revoke all on function public.bilet_ac_saatli(text, uuid, text, uuid, text, text, text, text, timestamptz, text)
  from public;
revoke all on function public.bilet_ac_saatli(text, uuid, text, uuid, text, text, text, text, timestamptz, text)
  from anon, authenticated, service_role;
grant execute on function public.bilet_ac_saatli(text, uuid, text, uuid, text, text, text, text, timestamptz, text)
  to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  f constant text := 'public.bilet_ac_saatli(text, uuid, text, uuid, text, text, text, text, timestamptz, text)';
  r text;
begin
  if not has_function_privilege('authenticated', f, 'execute') then
    raise exception '059: bilet_ac_saatli authenticated rolüne kapalı — ekran çalışmaz';
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, f, 'execute') then
      raise exception '059: bilet_ac_saatli % rolüne açık', r;
    end if;
  end loop;

  if not exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'bilet_ac_saatli'
       and p.prosecdef
       and p.proconfig @> array['search_path=public']
  ) then
    raise exception '059: bilet_ac_saatli SECURITY DEFINER + search_path=public değil';
  end if;
end
$do$;

commit;
