-- ============================================================================
-- 061  Bildirim türü: YENI_ABONMAN
-- ============================================================================

begin;

-- 062'nin (abonman ödeme günü, Personel ekler) yeni bildirimi. Ayrı dosyada,
-- çünkü yeni bir enum değeri onu ekleyen transaction içinde KULLANILAMAZ
-- (55P04 dersi, 019/035/053).
--
--   YENI_ABONMAN  Yeni abonman eklendi; gövdede ekleyenin adı. Yönetici'ye
--                 özel (062 bildirim_yonetici_turu listesine ekler).

alter type public.bildirim_tur add value if not exists 'YENI_ABONMAN';

commit;
