-- ============================================================================
-- 032  vardiya_ozetim yetkisi: düşürülen fonksiyona PUBLIC geri gelmişti
-- ============================================================================

begin;

-- 030 dönüş tipini değiştirebilmek için `vardiya_ozetim`i DÜŞÜRDÜ, ve düşürme
-- ACL'i de siler. Yerine yalnızca `grant ... to authenticated` yazıldı — ama
-- PostgreSQL YENİ bir fonksiyona EXECUTE'u PUBLIC'e verir ve `anon` da PUBLIC
-- üyesidir. Sonuç: giriş bile yapmamış bir istemci açık vardiyanın nakit/kart/
-- havale toplamlarını okuyabiliyordu.
--
-- 003'ün toplu revoke döngüsü bunu şemadaki her fonksiyon için bir kez
-- kapatmıştı; düşürülüp yeniden yaratılan HER fonksiyonda o iş yeniden
-- yapılmak zorunda. 029 ve 031 `acik_bilet_ara` için doğru yapıyor, 030
-- burada atladı — smoke test PASS 41a yakaladı.
--
-- 030 DEĞİŞTİRİLMEZ: uygulanmış bir migration'a dokunulmaz (055/056 deseni).
-- `authenticated` revoke listesinde YOK çünkü hemen altında geri veriliyor;
-- kritik olan `public`, onsuz bu satır hiçbir şey kapatmaz.
revoke all on function public.vardiya_ozetim() from public, anon, service_role;
grant execute on function public.vardiya_ozetim() to authenticated;

do $do$
begin
  if has_function_privilege('anon', 'public.vardiya_ozetim()', 'execute')
     or has_function_privilege('service_role', 'public.vardiya_ozetim()', 'execute') then
    raise exception 'DOĞRULAMA: vardiya_ozetim hâlâ istemci dışı rollere açık.';
  end if;
  if not has_function_privilege('authenticated', 'public.vardiya_ozetim()', 'execute') then
    raise exception 'DOĞRULAMA: vardiya_ozetim authenticated rolüne kapalı kaldı.';
  end if;
end
$do$;

commit;
