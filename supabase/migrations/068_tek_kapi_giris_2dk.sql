-- ============================================================================
-- 068  Tek kapı: giriş yok sayma süresi 3 → 2 dakika
-- ============================================================================

begin;

-- Sahip (2026-11-15), sahada 35 KV 044: personel bileti yazdıktan 3 dakika
-- dolmadan araç çıktı; köprü 1.4.2 net "çıktı" dedi ama kamera_tek_kapi 1a
-- "az önce girdi" (YENI_GIRIS) deyip yok saydı ve bilet açık kaldı.
--
-- Karar: giriş süresi (Otopark ayarları → Tek kapı → Girişten sonra) alt
-- sınırı 3 → 2, varsayılanı 2. Canlı değer hâlâ eski varsayılan 3 ise 2 olur
-- (başka bir değer seçildiyse dokunulmaz). Kameranın açtığı ve elle yazılan
-- bilet AYNI süreye tabidir — elle yazılan bilete ayrı kural yok.
--
-- 037'nin 3 gerekçesi (kadrajda oyalanan aracın yeniden gönderilmesi çıkış
-- sayılır) 1.4.x köprüde zayıfladı: izlenen aracın yeniden gönderimi GIRDI /
-- ICERIDE ipucu taşır ve kapatmaz (056). kamera_tek_kapi değişmez: süreyi
-- her olayda ayardan okur.
--
-- PASS 58c (alt sınır) ve PASS 86 sınar.

alter table public.otopark_ayarlari
  drop constraint if exists otopark_ayarlari_tek_kapi_giris_ck;
alter table public.otopark_ayarlari
  add constraint otopark_ayarlari_tek_kapi_giris_ck
    check (tek_kapi_giris_yoksay_dk between 2 and 60);
alter table public.otopark_ayarlari
  alter column tek_kapi_giris_yoksay_dk set default 2;
update public.otopark_ayarlari
   set tek_kapi_giris_yoksay_dk = 2
 where id = 1 and tek_kapi_giris_yoksay_dk = 3;

-- ---------------------------------------------------------- doğrulama -----

do $do$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.otopark_ayarlari'::regclass
                    and conname = 'otopark_ayarlari_tek_kapi_giris_ck'
                    and pg_get_constraintdef(oid) like '%>= 2%'
                    and pg_get_constraintdef(oid) like '%<= 60%') then
    raise exception '068: giriş süresi aralığı 2-60 olmadı';
  end if;
  if (select column_default from information_schema.columns
       where table_schema = 'public' and table_name = 'otopark_ayarlari'
         and column_name = 'tek_kapi_giris_yoksay_dk') is distinct from '2' then
    raise exception '068: giriş süresinin varsayılanı 2 olmadı';
  end if;
  if exists (select 1 from public.otopark_ayarlari
              where id = 1 and tek_kapi_giris_yoksay_dk = 3) then
    raise exception '068: canlı giriş süresi hâlâ 3';
  end if;
end
$do$;

commit;
