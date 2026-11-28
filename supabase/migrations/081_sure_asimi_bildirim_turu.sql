-- ============================================================================
-- 081  Bildirim türü: SURE_ASIMI
-- ============================================================================

begin;

-- 082'nin (süre aşımı onayı) bildirimi. Ayrı dosyada, çünkü yeni bir enum
-- değeri onu ekleyen transaction içinde KULLANILAMAZ (064 deseni).
--
--   SURE_ASIMI  Bir bilette ilk kademe aşıldı ve bir kişi karar verdi:
--               tarifenin tam fiyatı onaylandı ya da ilk kademe bırakıldı.
--               Yalnızca Yönetici'ye; 082 bildirim_yonetici_turu listesine
--               ekler.

alter type public.bildirim_tur add value if not exists 'SURE_ASIMI';

commit;
