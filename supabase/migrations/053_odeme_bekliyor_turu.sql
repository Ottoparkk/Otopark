-- ============================================================================
-- 053  Bildirim türleri: ODEME_BEKLIYOR, KAMERA_GERI_ACILDI
-- ============================================================================

begin;

-- 054'ün (kamera bileti kapatır, ödeme sonra toplanır) iki yeni bildirimi.
-- Ayrı dosyada, çünkü yeni bir enum değeri onu ekleyen transaction içinde
-- KULLANILAMAZ (55P04 dersi, 019/035): 054 bu değerleri bildirim yazarken ve
-- doğrularken kullanır.
--
--   ODEME_BEKLIYOR      Kamera bileti ödemesiz kapattı; ödeme toplanacak.
--                       HERKESE gider (Personel + Yönetici) — Yönetici'ye
--                       özel listede (bildirim_yonetici_turu) DEĞİL.
--   KAMERA_GERI_ACILDI  "Araç çıkmadı": kameranın kapattığı bilet geri açıldı.
--                       Yönetici'ye özel (054 listeye ekler).

alter type public.bildirim_tur add value if not exists 'ODEME_BEKLIYOR';
alter type public.bildirim_tur add value if not exists 'KAMERA_GERI_ACILDI';

commit;
