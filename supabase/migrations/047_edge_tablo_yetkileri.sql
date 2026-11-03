-- ============================================================================
-- 047  Edge Function tablo yetkileri yazılı: yeni projede de çalışsın
-- ============================================================================

begin;

-- ------------------------------------------------------------- yetkiler ----

-- kamera-webhook, plaka-oku ve send-push service_role ile bu beş tabloya
-- DOĞRUDAN dokunur (supabase-js `.from(...)`). Şimdiye kadar yetkiyi
-- Supabase'in yeni tablolara otomatik verdiği izin sağlıyordu; 2026-10-30'dan
-- beri yeni tablolar o izni almıyor. Bu dosya o tarihten önce açılmış bir
-- projede HİÇBİR ŞEYİ değiştirmez (izin zaten var, burada geri alınmıyor);
-- sonra açılmış bir projede (birinin kendi kopyası) kamera girişi, plaka
-- okuma ve anlık bildirim bunsuz "permission denied" ile dururdu.
--
-- Tam gereken kadar, fazlası değil — service_role RLS'i atlar, yetki sınırı
-- buradaki listedir:
--   profiles            SELECT          plaka-oku, send-push (rol/durum/tercih)
--   otopark_ayarlari    SELECT          kamera-webhook, plaka-oku (ayarlar)
--   biletler            SELECT          kamera-webhook (açık bilet sayımı)
--   plaka_okuma_log     SELECT, INSERT  okuma sınırı sayımı + her okuma kaydı
--   push_subscriptions  SELECT, DELETE  send-push (aboneler + ölü abonelik)
-- kamera_cihazlari'nın SELECT'i 036'da zaten yazılı. Diğer her yazma işi
-- SECURITY DEFINER RPC'lerden geçer; onların EXECUTE yetkileri ayrıca yazılı.
-- Yeni bir Edge Function bir tabloya doğrudan dokunacaksa yetkisi buraya
-- benzer bir migration ile eklenmeli — PASS 69 listesi de güncellenmeli.
grant select         on public.profiles           to service_role;
grant select         on public.otopark_ayarlari   to service_role;
grant select         on public.biletler           to service_role;
grant select, insert on public.plaka_okuma_log    to service_role;
grant select, delete on public.push_subscriptions to service_role;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
begin
  foreach r in array array[
    'public.profiles:SELECT',
    'public.otopark_ayarlari:SELECT',
    'public.biletler:SELECT',
    'public.plaka_okuma_log:SELECT',
    'public.plaka_okuma_log:INSERT',
    'public.push_subscriptions:SELECT',
    'public.push_subscriptions:DELETE',
    'public.kamera_cihazlari:SELECT'
  ] loop
    if not has_table_privilege('service_role', split_part(r, ':', 1), split_part(r, ':', 2)) then
      raise exception '047: service_role % yetkisi verilemedi — Edge Function''lar çalışmaz', r;
    end if;
  end loop;
end
$do$;

commit;
