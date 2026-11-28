-- ============================================================================
-- 079  Bildirim türü: ANLASMA
-- ============================================================================

begin;

-- 080'in (anlaşmalı fiyat) bildirimi. Ayrı dosyada, çünkü yeni bir enum
-- değeri onu ekleyen transaction içinde KULLANILAMAZ (064 deseni).
--
--   ANLASMA  Bir bilete anlaşmalı fiyat kuruldu ya da değişti (Yönetici'ye),
--            ya da anlaşmanın süresi doldu (herkese, bir kez). Herkese açık
--            tür: bildirim_yonetici_turu listesine EKLENMEZ.

alter type public.bildirim_tur add value if not exists 'ANLASMA';

commit;
