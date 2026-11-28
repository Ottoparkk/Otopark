-- =====================================================================
-- 087  Günlük rapor
-- =====================================================================
begin;

-- Sahip 28.11: "bütün gün nasıl geçti" — takvim günü, 00:00-24:00 İstanbul.
-- Vardiya raporunun (086) aynısı, pencere bir gün:
--   * gun_raporu(gun)            — tek günün her şeyi, jsonb
--   * gun_toplamlari(bas, bit)   — liste satırları: gün başına toplam, araç,
--                                   geçen haftanın aynı günü (karşılaştırma)
-- İkisi de yalnızca Yönetici; ikisi de yalnızca okur.
--
-- Toplam kuralı vardiya raporuyla (030/086) aynı: o gün yazılan BÜTÜN
-- tahsilat satırları, ters kayıtlar (negatif) aslını düşürür. Raporlar ekranı
-- (rapor_gunluk, 017) yalnızca onaylananları sayar; Onay boşalınca ikisi tutar.
-- Gece yarısını geçen bir vardiyanın tahsilatları iki güne bölünür; günün
-- vardiya satırı ise vardiyanın kendi bütün toplamını gösterir.

do $$
begin
  if to_regprocedure('public.vardiya_raporu(uuid)') is null then
    raise exception '087: önce 086 çalıştırılmalı.';
  end if;
end $$;

-- ---------------------------------------------------------- gun_raporu --
-- Pencere: [gün 00:00, ertesi gün 00:00) İstanbul. Parçalar 086 ile aynı:
--   toplam    — penceredeki tahsilatlar, yönteme göre; arac = pencerede
--               KAPALI'ya geçen bilet
--   biletler  — pencerede çıkan KAPALI biletler (en çok 500)
--   giris     — pencerede giren
--   islemler  — istisnai işlemler, audit_log'dan (en çok 300)
--   iceride   — bugün: şu an ACIK olan; geçmiş gün: gün sonunda içeride olan
--   onay      — pencerede yazılmış, Onay bekleyen tahsilatlar
--   vardiyalar— güne değen vardiyalar, her biri kendi bütün toplamıyla
-- İleri bir tarih boş rakamlar döner, hata vermez.
create or replace function public.gun_raporu(p_gun date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_bas timestamptz;
  v_bit timestamptz;
  v_iceride integer;
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_gun is null then
    raise exception 'Gün gerekli.';
  end if;

  v_bas := p_gun::timestamp at time zone 'Europe/Istanbul';
  v_bit := v_bas + interval '1 day';

  if now() < v_bit then
    select count(*) into v_iceride from public.biletler where durum = 'ACIK';
  else
    select count(*) into v_iceride
      from public.biletler b
     where b.durum <> 'IPTAL'
       and b.giris_at < v_bit
       and (b.cikis_at is null or b.cikis_at >= v_bit);
  end if;

  return jsonb_build_object(
    'gun', p_gun,

    'toplam', (
      select jsonb_build_object(
        'nakit',  coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'NAKIT'), 0),
        'kart',   coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'KREDI_KARTI'), 0),
        'havale', coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'HAVALE'), 0),
        'toplam', coalesce(sum(t.tutar_kurus), 0),
        'arac', (select count(*) from public.biletler b
                  where b.durum = 'KAPALI' and b.cikis_at >= v_bas and b.cikis_at < v_bit))
        from public.tahsilatlar t
       where t.created_at >= v_bas and t.created_at < v_bit),

    'biletler', coalesce((
      select jsonb_agg(x order by x.cikis_at desc)
        from (select b.id, b.plaka, b.arac_tipi, b.giris_at, b.cikis_at, b.durum,
                     b.ucret_kurus, b.tahsil_kurus, b.odeme_yontemi,
                     b.giris_kaynak, b.cikis_kaynak, b.cikis_by, b.ucretsiz_sebep
                from public.biletler b
               where b.durum = 'KAPALI' and b.cikis_at >= v_bas and b.cikis_at < v_bit
               order by b.cikis_at desc
               limit 500) x), '[]'::jsonb),

    'giris', (
      select jsonb_build_object(
        'toplam', count(*),
        'kamera', count(*) filter (where b.giris_kaynak = 'KAMERA'))
        from public.biletler b
       where b.giris_at >= v_bas and b.giris_at < v_bit),

    'islemler', coalesce((
      select jsonb_agg(x order by x.created_at desc)
        from (select a.actor, a.action, a.row_id, a.detay, a.created_at,
                     (select b.plaka from public.biletler b
                       where a.tablo = 'biletler' and b.id = a.row_id) as plaka
                from public.audit_log a
               where a.created_at >= v_bas and a.created_at < v_bit
                 and a.action in (
                   'bilet_iptal', 'bilet_iptal_talebi', 'bilet_iptal_onay', 'bilet_iptal_ret',
                   'bilet_ucretsiz_cikis', 'bilet_odemesiz_cikis', 'bilet_cikis_geri_alindi',
                   'bilet_kamera_geri_acildi', 'bilet_asim_karar', 'bilet_ucret_degisikligi',
                   'bilet_anlasma', 'kayip_bilet', 'bilet_sil', 'tahsilat_reddet',
                   'vardiya_devir', 'pin_kilit',
                   'odeme_sonrasi_gec_cikis')                                   -- 089
               order by a.created_at desc
               limit 300) x), '[]'::jsonb),

    'iceride', v_iceride,

    'onay', (
      select jsonb_build_object('adet', count(*), 'tutar', coalesce(sum(t.tutar_kurus), 0))
        from public.tahsilatlar t
       where t.durum = 'BEKLIYOR' and t.created_at >= v_bas and t.created_at < v_bit),

    'vardiyalar', coalesce((
      select jsonb_agg(x order by x.acilis_at)
        from (select v.id, v.personel_id,
                     (select p.ad_soyad from public.profiles p where p.id = v.personel_id) as personel_ad,
                     v.acilis_at, v.kapanis_at, v.fark_kurus, v.sayilan_nakit_kurus,
                     (select coalesce(sum(t.tutar_kurus), 0)
                        from public.tahsilatlar t where t.vardiya_id = v.id) as toplam
                from public.vardiyalar v
               where v.acilis_at < v_bit
                 and (v.kapanis_at is null or v.kapanis_at > v_bas)) x), '[]'::jsonb)
  );
end $$;

-- ------------------------------------------------------ gun_toplamlari --
-- Gün listesi: gün başına toplam, kapanan araç ve geçen haftanın aynı
-- günü. Bugün için karşılaştırma aynı saate kadar yapılır (bugün 10:00'da
-- geçen haftanın bütün günüyle kıyaslamak her sabah ▼ gösterirdi).
create or replace function public.gun_toplamlari(p_bas date, p_bit date)
returns table (gun date, toplam_kurus bigint, arac_sayisi bigint, onceki_kurus bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_bas is null or p_bit is null or p_bit < p_bas then
    raise exception 'Bitiş tarihi başlangıçtan önce olamaz.';
  end if;
  if p_bit - p_bas > 61 then
    raise exception 'En çok 62 gün.';
  end if;

  -- generate_series over dates yields TIMESTAMPS — hence the ::date (017).
  return query
  select g.gun,
         (select coalesce(sum(t.tutar_kurus), 0)::bigint
            from public.tahsilatlar t
           where t.created_at >= g.gun_bas and t.created_at < g.gun_bit),
         (select count(*)::bigint
            from public.biletler b
           where b.durum = 'KAPALI' and b.cikis_at >= g.gun_bas and b.cikis_at < g.gun_bit),
         (select coalesce(sum(t.tutar_kurus), 0)::bigint
            from public.tahsilatlar t
           where t.created_at >= g.gun_bas - interval '7 days'
             and t.created_at <  least(g.gun_bit, now()) - interval '7 days')
    from (select s.d::date as gun,
                 s.d::date::timestamp at time zone 'Europe/Istanbul' as gun_bas,
                 (s.d::date + 1)::timestamp at time zone 'Europe/Istanbul' as gun_bit
            from generate_series(p_bas, p_bit, interval '1 day') s(d)) g
   order by g.gun;
end $$;

-- ------------------------------------------------------------- grants --
revoke all on function public.gun_raporu(date)           from public, anon, authenticated, service_role;
revoke all on function public.gun_toplamlari(date, date) from public, anon, authenticated, service_role;
grant execute on function public.gun_raporu(date)           to authenticated;
grant execute on function public.gun_toplamlari(date, date) to authenticated;

do $do$
begin
  if has_function_privilege('anon', 'public.gun_raporu(date)', 'execute')
     or has_function_privilege('service_role', 'public.gun_raporu(date)', 'execute')
     or has_function_privilege('anon', 'public.gun_toplamlari(date, date)', 'execute')
     or has_function_privilege('service_role', 'public.gun_toplamlari(date, date)', 'execute') then
    raise exception 'DOĞRULAMA: 087 fonksiyonları istemci dışı rollere açık.';
  end if;
  if not has_function_privilege('authenticated', 'public.gun_raporu(date)', 'execute')
     or not has_function_privilege('authenticated', 'public.gun_toplamlari(date, date)', 'execute') then
    raise exception 'DOĞRULAMA: 087 fonksiyonları authenticated rolüne kapalı.';
  end if;
end
$do$;

commit;
