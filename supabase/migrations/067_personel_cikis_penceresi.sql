-- ============================================================================
-- 067  Personel'in Çıkanlar penceresi: son 3 İstanbul günü
-- ============================================================================

begin;

-- Sahip (2026-11-15): Gişe → Çıkanlar tarih süzgecine uyar; Personel iki süzgeç
-- görür, "Bugün" ve "3 gün", ve 3 günden eskisini GÖREMEZ. Sınır burada,
-- Postgres'te — ekran yalnızca seçtirir.
--
-- 003'ün kuralı: Personel kapanmış bileti yalnızca KENDİ AÇIK vardiyasında
-- kapandıysa okur. Vardiya kapanınca (ya da kamera vardiyasızken kapattıysa)
-- Çıkanlar boş kalıyordu. Eklenen tek koşul: KAPALI ve çıkışı son 3 İstanbul
-- günü içinde (bugün + önceki iki gün, ilk günün 00:00'ından; "7 gün"
-- süzgeciyle aynı sayım).
--
-- Yalnızca OKUMA genişler. Tahsil (034), sonradan ücretsiz (066), geri alma
-- (054 / 060) kendi vardiyası koşulunu kendi gövdelerinde denetler — değişmez
-- (75m, sahibin seçimi). İptal bileti genişlemez (yalnızca çıkışlar).
-- Özetler (gunluk_ozet, vardiya_ozetim, raporlar) security definer: etkilenmez.
-- PASS 84 sınar.

drop policy if exists biletler_select on public.biletler;
create policy biletler_select on public.biletler for select to authenticated
  using (
    public.is_yonetici()
    or (public.is_staff()
        and (durum = 'ACIK'
             or kapatan_vardiya_id = public.acik_vardiyam()
             or (durum = 'KAPALI'
                 and cikis_at >= (((now() at time zone 'Europe/Istanbul')::date - 2)::timestamp
                                  at time zone 'Europe/Istanbul'))))
  );

-- Çıkanlar artık çıkış zamanına göre süzer ve sıralar.
create index if not exists biletler_kapali_cikis_ix
  on public.biletler (cikis_at desc) where durum = 'KAPALI';

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  v_ifade text;
begin
  select pg_get_expr(p.polqual, p.polrelid) into v_ifade
    from pg_policy p
   where p.polrelid = 'public.biletler'::regclass and p.polname = 'biletler_select';
  if v_ifade is null then
    raise exception '067: biletler_select politikası yok';
  end if;
  if v_ifade not like '%Europe/Istanbul%' or v_ifade not like '%acik_vardiyam%' then
    raise exception '067: biletler_select beklenen pencereyi taşımıyor: %', v_ifade;
  end if;
  if not exists (select 1 from pg_indexes
                  where schemaname = 'public' and indexname = 'biletler_kapali_cikis_ix') then
    raise exception '067: biletler_kapali_cikis_ix yok';
  end if;
end
$do$;

commit;
