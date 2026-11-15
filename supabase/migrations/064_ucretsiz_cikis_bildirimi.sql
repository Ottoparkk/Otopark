-- ============================================================================
-- 064  Bildirim türü: UCRETSIZ_CIKIS
-- ============================================================================

begin;

-- 065'in (ücretsiz çıkış: sebep + zorunlu not) yeni bildirimi. Ayrı dosyada,
-- çünkü yeni bir enum değeri onu ekleyen transaction içinde KULLANILAMAZ
-- (55P04 dersi, 019/035/053/061).
--
--   UCRETSIZ_CIKIS  Bir araca ücretsiz çıkış verildi; gövdede verenin adı,
--                   plaka, sebep ve not. Yönetici'ye özel (065
--                   bildirim_yonetici_turu listesine ekler).

alter type public.bildirim_tur add value if not exists 'UCRETSIZ_CIKIS';

commit;
