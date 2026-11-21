-- ============================================================================
-- 071  Sunucunun reddettiği kamera aracı kart olur, sessizce kaybolmaz
-- ============================================================================

alter type public.istisna_tur add value if not exists 'REDDEDILDI';

begin;

-- 019 / 039 dersi: yukarıda eklenen enum değeri bu dosyada enum literali
-- olarak ÇALIŞTIRILMIYOR (SQL editörü dosyayı tek transaction'da koşar).
-- Yalnızca plpgsql gövdesinde geçer — ilk çağrıda, commit'ten sonra çözülür;
-- doğrulama pg_enum'dan okur.
--
-- Plan 2026-11-17 adım 3 (sahibin cevabı: reddedilen araç personel kartı olur).
-- Eskiden bilet_ac / kamera_cikis_bildir / kamera_tek_kapi bir kamera aracını
-- reddedince (P0001, sınıf 22 ve 23 — rpcHataDurumu) webhook 409 dönüyordu;
-- köprü 409'u kesin cevap sayıp aracı siliyordu ve geriye yalnızca köprü
-- günlüğünde bir satır kalıyordu: eksik tarife, içeride zaten açık bileti
-- olan plaka… Kimse görmüyordu.
--
-- Artık webhook bu reddi kamera_reddedildi ile bir REDDEDILDI kartına yazar
-- (plaka, foto, ret cümlesi) ve 200 + karar ISTISNA döner — diğer bütün kart
-- sonuçları gibi; eski köprüler de aracı teslim edilmiş sayar.
--   · Yalnızca service_role (PASS 41 listesine bu tek ad eklenir).
--   · Aynı olay (islem_id) ikinci kart yazmaz (istisnalar_islem_ux).
--   · Bildirim herkese (ISTISNA personel türü), ama aynı ret cümlesi saatte
--     bir kez: eksik bir tarife her araçta telefonları çaldırmasın. Kartların
--     hepsi yine yazılır.
--   · Şerit uyuşmazlığı ve bozuk gövde kart OLMAZ: araç değil ayar / köprü
--     hatasıdır; Gişe şeridi ve Yönetici uyarısı (070) onları gösterir.
-- PASS 89 sınar.

create or replace function public.kamera_reddedildi(
  p_yon      text,
  p_islem_id uuid,
  p_zaman    timestamptz,
  p_plaka    text,
  p_sebep    text,
  p_ham      jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_sebep text := left(coalesce(nullif(btrim(p_sebep), ''), 'Sebep bildirilmedi.'), 200);
  v_plaka text := nullif(public.normalize_plaka(coalesce(p_plaka, '')), '');
  v_ham   jsonb;
  v_id    uuid;
begin
  -- Webhook'un service anahtarıyla, JWT'siz çağrılır (037 deseni).
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.' using errcode = '42501';
  end if;
  if p_yon is null or p_yon not in ('GIRIS', 'CIKIS', 'ORTAK') then
    raise exception 'Şerit GIRIS, CIKIS veya ORTAK olmalı.';
  end if;
  if p_islem_id is null then
    raise exception 'islem_id gerekli.';
  end if;

  v_ham := (case when jsonb_typeof(p_ham) = 'object' then p_ham else '{}'::jsonb end)
           || jsonb_build_object('ret_sebebi', v_sebep);

  insert into public.istisnalar (tur, yon, plaka, kaynak, islem_id, ham_yanit, kaynak_zaman)
  values ('REDDEDILDI', p_yon, v_plaka, 'KAMERA', p_islem_id, v_ham, p_zaman)
  on conflict (islem_id) where islem_id is not null do nothing
  returning id into v_id;

  if v_id is null then
    -- Aynı olay zaten kayıtlı (köprü yeniden denedi): sessiz kal.
    select i.id into v_id from public.istisnalar i where i.islem_id = p_islem_id;
    return v_id;
  end if;

  if not exists (select 1 from public.istisnalar i
                  where i.tur::text = 'REDDEDILDI' and i.id <> v_id
                    and i.ham_yanit ->> 'ret_sebebi' = v_sebep
                    and i.created_at > now() - interval '60 minutes') then
    perform public.notify_herkes('ISTISNA', 'Çözülmemiş kayıt',
      'Sunucu kaydı reddetti — ' || coalesce(v_plaka, 'plaka yok'),
      '/istisnalar');
  end if;
  return v_id;
end
$fn$;

revoke all on function public.kamera_reddedildi(text, uuid, timestamptz, text, text, jsonb) from public;
revoke all on function public.kamera_reddedildi(text, uuid, timestamptz, text, text, jsonb)
  from anon, authenticated, service_role;
grant execute on function public.kamera_reddedildi(text, uuid, timestamptz, text, text, jsonb)
  to service_role;

do $do$
declare
  f constant text := 'public.kamera_reddedildi(text, uuid, timestamptz, text, text, jsonb)';
begin
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'istisna_tur' and e.enumlabel = 'REDDEDILDI') then
    raise exception '071: istisna_tur REDDEDILDI eklenmedi';
  end if;
  if not exists (select 1 from pg_proc where oid = f::regprocedure
                  and prosecdef and proconfig @> array['search_path=public']) then
    raise exception '071: kamera_reddedildi SECURITY DEFINER + search_path=public değil';
  end if;
  if has_function_privilege('anon', f, 'execute')
     or has_function_privilege('authenticated', f, 'execute')
     or not has_function_privilege('service_role', f, 'execute') then
    raise exception '071: kamera_reddedildi yalnızca service_role olmalı';
  end if;
end
$do$;

commit;
