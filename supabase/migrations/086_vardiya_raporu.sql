-- =====================================================================
-- 086  Vardiya raporu
-- =====================================================================
begin;

-- Sahip 28.11: Personel artık vardiya açmıyor, saymıyor (084/085). Yönetici
-- için Vardiya ekranı bir rapora dönüşüyor: "bu vardiyada ne oldu".
--   * vardiya_raporu(id)        — tek vardiyanın her şeyi, jsonb
--   * vardiya_toplamlari(ids[]) — liste satırları için toplam + araç sayısı
-- İkisi de yalnızca Yönetici; ikisi de yalnızca okur.

do $$
begin
  if to_regprocedure('public.run_vardiya_degisim_hatirlat()') is null then
    raise exception '086: önce 085 çalıştırılmalı.';
  end if;
end $$;

-- ------------------------------------------------------ vardiya_raporu --
-- Pencere: açılıştan kapanışa (açıksa şimdiye). Parçalar:
--   vardiya  — satır + çalışanın adı
--   toplam   — tahsilatlar, yönteme göre. vardiya_ozetim (030) ile aynı
--              kural: vardiyanın BÜTÜN satırları toplanır, ters kayıtlar
--              (negatif) aslını düşürür. arac = bu vardiyada kapanan bilet.
--   biletler — kapatan_vardiya_id = bu vardiya (en çok 500)
--   giris    — giris_at pencere içinde (kamera girişi vardiya taşımaz)
--   islemler — istisnai işlemler, audit_log'dan, pencere içinde (en çok 300)
--   iceride  — kapanış anında içeride olan; açık vardiyada şu an ACIK olan
--   onay     — bu vardiyanın Onay bekleyen tahsilatları
create or replace function public.vardiya_raporu(p_vardiya_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_v   public.vardiyalar;
  v_son timestamptz;
  v_iceride integer;
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_v from public.vardiyalar where id = p_vardiya_id;
  if not found then
    raise exception 'Vardiya bulunamadı.';
  end if;
  v_son := coalesce(v_v.kapanis_at, now());

  if v_v.kapanis_at is null then
    select count(*) into v_iceride from public.biletler where durum = 'ACIK';
  else
    select count(*) into v_iceride
      from public.biletler b
     where b.durum <> 'IPTAL'
       and b.giris_at <= v_v.kapanis_at
       and (b.cikis_at is null or b.cikis_at > v_v.kapanis_at);
  end if;

  return jsonb_build_object(
    'vardiya', to_jsonb(v_v) || jsonb_build_object(
      'personel_ad', (select p.ad_soyad from public.profiles p where p.id = v_v.personel_id)),

    'toplam', (
      select jsonb_build_object(
        'nakit',  coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'NAKIT'), 0),
        'kart',   coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'KREDI_KARTI'), 0),
        'havale', coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'HAVALE'), 0),
        'toplam', coalesce(sum(t.tutar_kurus), 0),
        'arac', (select count(*) from public.biletler b
                  where b.kapatan_vardiya_id = v_v.id and b.durum = 'KAPALI'))
        from public.tahsilatlar t
       where t.vardiya_id = v_v.id),

    'biletler', coalesce((
      select jsonb_agg(x order by x.cikis_at desc)
        from (select b.id, b.plaka, b.arac_tipi, b.giris_at, b.cikis_at, b.durum,
                     b.ucret_kurus, b.tahsil_kurus, b.odeme_yontemi,
                     b.giris_kaynak, b.cikis_kaynak, b.cikis_by, b.ucretsiz_sebep
                from public.biletler b
               where b.kapatan_vardiya_id = v_v.id
               order by b.cikis_at desc nulls last
               limit 500) x), '[]'::jsonb),

    'giris', (
      select jsonb_build_object(
        'toplam', count(*),
        'kamera', count(*) filter (where b.giris_kaynak = 'KAMERA'))
        from public.biletler b
       where b.giris_at >= v_v.acilis_at and b.giris_at <= v_son),

    'islemler', coalesce((
      select jsonb_agg(x order by x.created_at desc)
        from (select a.actor, a.action, a.row_id, a.detay, a.created_at,
                     (select b.plaka from public.biletler b
                       where a.tablo = 'biletler' and b.id = a.row_id) as plaka
                from public.audit_log a
               where a.created_at >= v_v.acilis_at and a.created_at <= v_son
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
       where t.vardiya_id = v_v.id and t.durum = 'BEKLIYOR')
  );
end $$;

-- -------------------------------------------------- vardiya_toplamlari --
-- Vardiyalar listesi: satır başına toplam ve araç sayısı, tek sorguda.
create or replace function public.vardiya_toplamlari(p_ids uuid[])
returns table (vardiya_id uuid, toplam_kurus bigint, arac_sayisi bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  if coalesce(array_length(p_ids, 1), 0) > 200 then
    raise exception 'En çok 200 vardiya.';
  end if;

  return query
  select v.id,
         (select coalesce(sum(t.tutar_kurus), 0)::bigint
            from public.tahsilatlar t where t.vardiya_id = v.id),
         (select count(*)::bigint from public.biletler b
           where b.kapatan_vardiya_id = v.id and b.durum = 'KAPALI')
    from public.vardiyalar v
   where v.id = any (p_ids);
end $$;

-- ------------------------------------------------------------- grants --
revoke all on function public.vardiya_raporu(uuid)       from public, anon, authenticated, service_role;
revoke all on function public.vardiya_toplamlari(uuid[]) from public, anon, authenticated, service_role;
grant execute on function public.vardiya_raporu(uuid)       to authenticated;
grant execute on function public.vardiya_toplamlari(uuid[]) to authenticated;

do $do$
begin
  if has_function_privilege('anon', 'public.vardiya_raporu(uuid)', 'execute')
     or has_function_privilege('service_role', 'public.vardiya_raporu(uuid)', 'execute')
     or has_function_privilege('anon', 'public.vardiya_toplamlari(uuid[])', 'execute')
     or has_function_privilege('service_role', 'public.vardiya_toplamlari(uuid[])', 'execute') then
    raise exception 'DOĞRULAMA: 086 fonksiyonları istemci dışı rollere açık.';
  end if;
  if not has_function_privilege('authenticated', 'public.vardiya_raporu(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.vardiya_toplamlari(uuid[])', 'execute') then
    raise exception 'DOĞRULAMA: 086 fonksiyonları authenticated rolüne kapalı.';
  end if;
end
$do$;

commit;
