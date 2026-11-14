-- ============================================================================
-- 055  Çözülmemiş kayıt türleri: GIRISTE_ACIK_BILET, ICERIDE_BILETSIZ
-- ============================================================================

begin;

-- 056'nın (tek kapıda köprünün yön ipucu) iki yeni kayıt türü. Ayrı dosyada,
-- çünkü yeni bir enum değeri onu ekleyen transaction içinde KULLANILAMAZ
-- (55P04 dersi, 019/035/053): 056 bu değerlerle kayıt yazar ve doğrular.
--
--   GIRISTE_ACIK_BILET  Köprü aracı tek kapıdan GİRERKEN gördü ama plakanın
--                       eski bir açık bileti var: bugünkü kural onu "çıkış"
--                       sayıp kapatırdı. Eski bilet hayalet olabilir (araç
--                       önceki çıkışında görülmedi) — insan karar verir.
--   ICERIDE_BILETSIZ    Köprü otoparkın İÇİNDE gezen, plakası emin okunan bir
--                       araç gördü ve açık bileti yok. Personel "Giriş aç"la
--                       (istisna_bilet_ac, 056) girişini açabilir.
--
-- Tek kapıda "çıkan araç, açık bileti yok" için yeni tür YOK: mevcut
-- ACIK_BILET_YOK (yon = ORTAK) — metni zaten "Çıkışta açık bilet bulunamadı".

alter type public.istisna_tur add value if not exists 'GIRISTE_ACIK_BILET';
alter type public.istisna_tur add value if not exists 'ICERIDE_BILETSIZ';

commit;
