-- ============================================================================
-- 060  Yanlışlıkla verilen çıkışı geri almak: araç yeniden içeride
-- ============================================================================

begin;

-- ------------------------------------------------------------ fonksiyon ----

-- Sahip (2026-11-15): Gişe'de yanlış araca çıkış verilirse (araç içeride,
-- bileti kapandı) bilet geri açılabilsin — PARASI ALINMIŞ olsa da. Bugüne
-- kadar tek yol 054'ün "Araç çıkmadı"sıydı: yalnızca kameranın kapattığı,
-- parası alınmamış bilet. O yol AYNEN kalır (sebepsiz); bu, sebepli kardeşi.
--
-- Kapanmış bilet değişmez kuralına (biletler_immutable_guard) ikinci BİLİNÇLİ
-- istisna — sahibin kararı. Sınırları 054'le aynı, para kuralı bilet_iptal'le
-- (050) aynı:
--   · Personel yalnızca kendi açık vardiyasında kapanan bileti (okuma yolunda
--     zaten yalnızca onu görür — bilet_tahsil 034'ün kuralı), Yönetici her
--     bileti. Sebep zorunlu; iz kalır, Yönetici bildirim alır.
--   · Para DÜZENLENMEZ: her canlı tahsilata karşı kayıt (iptal_of) yazılır.
--     017'nin tetiği durumu verir — onay bekleyen ödeme ile ters kaydı ikisi
--     de REDDEDILDI olur (Onay'dan düşer, deftere hiç girmez); onaylanmış
--     ödemenin ters kaydı ONAYLANDI doğar. Ters kayıt geri alanın açık
--     vardiyasına yazılır: aynı vardiyada kasa sayımı net sıfır.
--   · Bilet İLK giriş saatiyle yeniden ACIK; ücret gerçek çıkışta yeniden
--     hesaplanır. Çıkışın bütün izleri (ücret değişikliği dahil) temizlenir;
--     eski değerler denetim kaydında.
--   · İçeride aynı plakalı başka bilet varsa reddedilir (054 gibi).
--   · Kameranın kapattığı bilet de buradan açılabilir (ör. "Ödeme topla" ile
--     ödenmiş olan). İzi 054'ün adıyla (bilet_kamera_geri_acildi) yazılır:
--     kamera_cikis_bildir o adı görüp aynı aracı çıkış süresi içinde yeniden
--     KAPATMAZ — araç hâlâ kapıda bekliyor olabilir.
--   · Bildirim türü 054'ün KAMERA_GERI_ACILDI'si (uygulamada etiketi artık
--     "Çıkış geri alındı"): yeni enum değeri YOK, dolayısıyla 053 gibi ayrı
--     bir dosya gerekmez.
create or replace function public.bilet_cikis_geri_al(p_bilet_id uuid, p_sebep text)
returns boolean
language plpgsql security definer set search_path = public as $fn$
declare
  v_b     public.biletler;
  v_sebep text := btrim(coalesce(p_sebep, ''));
  v_iade  integer;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if v_sebep = '' then
    raise exception 'Sebep zorunludur.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;

  if v_b.durum <> 'KAPALI' then
    raise exception 'Yalnızca çıkışı yapılmış bir bilet geri alınabilir.';
  end if;

  -- bilet_tahsil (034) / bilet_kamera_geri_ac (054) ile aynı sınır.
  if not (public.is_yonetici()
          or coalesce(v_b.kapatan_vardiya_id = public.acik_vardiyam(), false)) then
    raise exception 'Bu bileti geri açma yetkiniz yok.';
  end if;

  if exists (select 1 from public.biletler b
              where b.plaka = v_b.plaka and b.durum = 'ACIK') then
    raise exception 'Bu plakayla içeride başka bir bilet var; önce onu iptal edin.';
  end if;

  -- Para önce, satır hâlâ KAPALI iken (bilet_iptal'in sırası). Reddedilmiş
  -- tahsilat zaten "para gelmedi" (028); daha önce ters kaydı yazılmış olan
  -- (bilet bir kez geri alınıp yeniden kapandıysa eskisi) bir daha yazılmaz.
  with ters as (
    insert into public.tahsilatlar (
      tur, bilet_id, tutar_kurus, yontem, vardiya_id, iptal_of, created_by, aciklama)
    select t.tur, t.bilet_id, -t.tutar_kurus, t.yontem, public.acik_vardiyam(), t.id,
           auth.uid(), 'Çıkış geri alındı'
      from public.tahsilatlar t
     where t.bilet_id = p_bilet_id
       and t.iptal_of is null
       and t.tutar_kurus > 0
       and t.durum <> 'REDDEDILDI'
       and not exists (select 1 from public.tahsilatlar r where r.iptal_of = t.id)
    returning tutar_kurus
  )
  select coalesce(-sum(tutar_kurus), 0)::integer into v_iade from ters;

  -- 054'ün dar izni: guard yalnızca BU bilet için geçer.
  perform set_config('app.bilet_geri_ac', p_bilet_id::text, true);
  update public.biletler set
    -- 054 gibi: yanlış kapanıştan sonra yere başka araç girdiyse yer onda
    -- kalır, bu bilet yersiz açılır.
    park_yeri_id       = case
                           when exists (select 1 from public.biletler o
                                         where o.durum = 'ACIK' and o.id <> p_bilet_id
                                           and o.park_yeri_id = v_b.park_yeri_id)
                           then null else v_b.park_yeri_id
                         end,
    durum              = 'ACIK',
    cikis_at           = null,
    ucret_kurus        = 0,
    tahsil_kurus       = 0,
    odeme_yontemi      = null,
    cikis_by           = null,
    cikis_kaynak       = null,
    kapatan_vardiya_id = null,
    cikis_foto         = null,
    cikis_bekliyor_at  = null,
    ucret_degistirildi = false,
    ucret_sebep        = null
  where id = p_bilet_id;
  perform set_config('app.bilet_geri_ac', '', true);

  perform public.audit(
    case when v_b.cikis_kaynak = 'KAMERA' then 'bilet_kamera_geri_acildi'
         else 'bilet_cikis_geri_alindi' end,
    'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'sebep', v_sebep,
                       'cikis_at', v_b.cikis_at, 'cikis_kaynak', v_b.cikis_kaynak,
                       'cikis_by', v_b.cikis_by, 'ucret', v_b.ucret_kurus,
                       'ucret_sebep', v_b.ucret_sebep, 'tahsil', v_b.tahsil_kurus,
                       'yontem', v_b.odeme_yontemi, 'vardiya', v_b.kapatan_vardiya_id,
                       'park_yeri', v_b.park_yeri_id, 'iade', v_iade));
  perform public.notify_yonetici('KAMERA_GERI_ACILDI', 'Çıkış geri alındı',
    v_b.plaka || ' — ' || v_sebep
      || case when v_iade > 0
              then ' · ' || (v_iade / 100.0)::numeric(12,2) || ' ₺ geri alındı'
              else '' end,
    '/gise/bilet/' || p_bilet_id);

  return true;
end
$fn$;

-- -------------------------------------------------------------- yetki -----

-- from public OLMADAN hiçbir şey kapanmaz (012); service_role OLMADAN da (033).
revoke all on function public.bilet_cikis_geri_al(uuid, text) from public;
revoke all on function public.bilet_cikis_geri_al(uuid, text) from anon, authenticated, service_role;
grant execute on function public.bilet_cikis_geri_al(uuid, text) to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  f constant text := 'public.bilet_cikis_geri_al(uuid, text)';
  r text;
begin
  if not has_function_privilege('authenticated', f, 'execute') then
    raise exception '060: bilet_cikis_geri_al authenticated rolüne kapalı — ekran çalışmaz';
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, f, 'execute') then
      raise exception '060: bilet_cikis_geri_al % rolüne açık', r;
    end if;
  end loop;

  if not exists (select 1 from pg_proc where oid = f::regprocedure
                  and prosecdef and proconfig @> array['search_path=public']) then
    raise exception '060: bilet_cikis_geri_al SECURITY DEFINER + search_path=public değil';
  end if;

  -- 054 koşulmuş olmalı: guard'ın app.bilet_geri_ac izni ve bildirim türü.
  if position('app.bilet_geri_ac' in
       pg_get_functiondef('public.biletler_immutable_guard()'::regprocedure)) = 0 then
    raise exception '060: 054 koşulmamış — değişmezlik guard''ında geri açma izni yok';
  end if;
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'bildirim_tur' and e.enumlabel = 'KAMERA_GERI_ACILDI') then
    raise exception '060: 053 koşulmamış — KAMERA_GERI_ACILDI yok';
  end if;
end
$do$;

commit;
