-- ============================================================================
-- 057  Bildirim türü: KAMERA_GUNLUK
-- ============================================================================

begin;

-- 058'in (kameranın günlük özeti) bildirim türü. Ayrı dosyada, çünkü yeni bir
-- enum değeri onu ekleyen transaction içinde KULLANILAMAZ (55P04 dersi,
-- 019/035/053/055): 058 bu değerle bildirim yazar ve Yönetici listesine ekler.
--
--   KAMERA_GUNLUK  Gece işi (00:05) bir önceki günü özetler: kameranın açtığı
--                  ve kapattığı biletler, personele düşen kayıtlar. Yönetici'ye
--                  özel; kamera açıkken günde bir kez.

alter type public.bildirim_tur add value if not exists 'KAMERA_GUNLUK';

commit;
