-- ============================================================================
-- 033  Gece işine service_role yetkisi: revoke listesi eksikti
-- ============================================================================

begin;

-- 030 `run_vardiya_otomatik_ac`i `public`, `anon` ve `authenticated`tan geri
-- aldı ama `service_role`ü ATLADI — ve kendi doğrulama bloğu da yalnızca ilk
-- ikisini sınadığı için sessizce geçti. Smoke test PASS 41b yakaladı.
--
-- Sebep PUBLIC üyeliği DEĞİL: Supabase, şemadaki yeni fonksiyonlara
-- `alter default privileges` ile EXECUTE'u anon, authenticated ve service_role
-- rollerine AYRI AYRI verir. Yani `from public` tek başına yetmediği gibi
-- (058 dersi), `from public, anon, authenticated` de yetmez — DÖRDÜ birden
-- yazılmak zorunda. 003'ün toplu döngüsü zaten dördünü sayıyor; yeni fonksiyon
-- ekleyen her migration aynı listeyi tekrarlamalıdır.
--
-- Neden önemli: bu iş günün kasa vardiyasını AÇAR. service_role'e açık
-- kalması, kamera webhook'unun anahtarını ele geçiren birinin vardiyayı
-- istediği anda — açılış nakdi ayardaki tutara sabitlenmiş hâlde —
-- açtırabilmesi demekti.
revoke all on function public.run_vardiya_otomatik_ac()
  from public, anon, authenticated, service_role;

-- 030-033'ün dokunduğu ÜÇ fonksiyonun tamamı doğrulanıyor, üçüncü bir
-- sürprizle karşılaşmamak için.
--
-- `public` listede yok çünkü gerçek bir rol adı değildir ve
-- `has_function_privilege`a verilemez — ama gerek de yok: o fonksiyon
-- PUBLIC'e verilmiş yetkileri de sayar, dolayısıyla PUBLIC açık kalsaydı
-- üç rolün üçü de true dönerdi.
do $do$
declare
  f text;
  r text;
  v_kapali text[] := array['public.run_vardiya_otomatik_ac()'];
  v_acik   text[] := array['public.vardiya_ozetim()', 'public.acik_bilet_ara(text)'];
begin
  foreach f in array v_kapali loop
    foreach r in array array['anon', 'authenticated', 'service_role'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception 'DOĞRULAMA: % hâlâ % rolüne açık.', f, r;
      end if;
    end loop;
  end loop;

  foreach f in array v_acik loop
    if not has_function_privilege('authenticated', f, 'execute') then
      raise exception 'DOĞRULAMA: % authenticated rolüne kapalı kalmış.', f;
    end if;
    foreach r in array array['anon', 'service_role'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception 'DOĞRULAMA: % istemci dışı % rolüne açık.', f, r;
      end if;
    end loop;
  end loop;
end
$do$;

commit;
