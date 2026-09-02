-- ============================================================================
-- 024  Fotoğraf saklama süresi 1-30 gün
-- ============================================================================

begin;

-- Depolama ücretsiz katmanda sınırlı, plaka fotoğrafı ise KVKK kapsamında
-- kişisel veri: kota ile hukuk aynı yöne bakıyor. 001'deki 0-3650 aralığı
-- ikisini de karşılamıyordu — 0 silmeyi tamamen kapatıyor, üst uç on yıllık
-- fotoğraf biriktirmeye izin veriyordu.
--
-- Önce mevcut satır aralığa çekilir, SONRA kısıt konur. Ters sırada kısıt
-- eklenemez ve migration yarıda kalırdı.
update public.otopark_ayarlari
   set foto_saklama_gun = least(greatest(foto_saklama_gun, 1), 30)
 where foto_saklama_gun not between 1 and 30;

-- Kısıt 001'de kolonun içinde tanımlandığı için adı üretilmiştir. Üretilmiş
-- bir ada güvenmek yerine kolonu gerçekten kısıtlayan CHECK katalogdan
-- bulunup düşürülür.
do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.otopark_ayarlari'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) like '%foto_saklama_gun%'
  loop
    execute format('alter table public.otopark_ayarlari drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.otopark_ayarlari
  add constraint otopark_ayarlari_foto_saklama_gun_ck
  check (foto_saklama_gun between 1 and 30);

-- run_gunluk_bakim'daki `if v_saklama > 0` dalı artık ulaşılamaz. Kaldırılmadı:
-- tek yaptığı silmeyi atlamak ve kısıt bir gün gevşetilirse yine doğru davranır.

-- -------------------------------------------------------------- verify ---
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.otopark_ayarlari'::regclass
                    and conname = 'otopark_ayarlari_foto_saklama_gun_ck') then
    raise exception '024: saklama kısıtı kurulmadı';
  end if;
  if exists (select 1 from public.otopark_ayarlari
              where foto_saklama_gun not between 1 and 30) then
    raise exception '024: aralık dışı saklama süresi kaldı';
  end if;
end $$;

commit;
