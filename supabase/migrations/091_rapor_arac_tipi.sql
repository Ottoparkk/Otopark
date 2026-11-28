-- =====================================================================
-- 091  Vardiya ve gün raporu: kaldırılmış arac_tipi sütunu
-- =====================================================================
begin;

-- 086 vardiya_raporu ve 087 gun_raporu bilet listesinde b.arac_tipi
-- okuyordu; o sütun 006'da kaldırıldı. PL/pgSQL sorguyu ancak çalışırken
-- denetler: iki rapor da "column b.arac_tipi does not exist" ile düşüyordu
-- (smoke PASS 125 yakaladı). İki fonksiyon aynen yeniden yazılır, yalnızca
-- o sütun çıkar. Ön yüz o alanı okumuyor; değişiklik yok. 086 / 087 çalıştı,
-- onlara dokunulmaz (ileri düzeltme).

do $$
begin
  if to_regprocedure('public.gun_raporu(date)') is null
     or to_regprocedure('public.vardiya_raporu(uuid)') is null then
    raise exception '091: önce 086 ve 087 çalıştırılmalı.';
  end if;
end $$;

-- ------------------------------------------------------ vardiya_raporu --
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
        from (select b.id, b.plaka, b.giris_at, b.cikis_at, b.durum,
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

-- ---------------------------------------------------------- gun_raporu --
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
        from (select b.id, b.plaka, b.giris_at, b.cikis_at, b.durum,
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

-- ---------------------------------------------------------------- yetki --
-- create or replace yetkiyi korur; yine de yeniden verilir ve denetlenir.
revoke all on function public.vardiya_raporu(uuid) from public, anon, authenticated, service_role;
revoke all on function public.gun_raporu(date)     from public, anon, authenticated, service_role;
grant execute on function public.vardiya_raporu(uuid) to authenticated;
grant execute on function public.gun_raporu(date)     to authenticated;

do $do$
declare
  f text;
begin
  foreach f in array array['public.vardiya_raporu(uuid)', 'public.gun_raporu(date)'] loop
    if has_function_privilege('anon', f, 'execute')
       or has_function_privilege('service_role', f, 'execute') then
      raise exception 'DOĞRULAMA: % istemci dışı rollere açık.', f;
    end if;
    if not has_function_privilege('authenticated', f, 'execute') then
      raise exception 'DOĞRULAMA: % authenticated rolüne kapalı.', f;
    end if;
    if position('arac_tipi' in pg_get_functiondef(f::regprocedure)) > 0 then
      raise exception 'DOĞRULAMA: % hâlâ arac_tipi okuyor.', f;
    end if;
  end loop;
end
$do$;

commit;
