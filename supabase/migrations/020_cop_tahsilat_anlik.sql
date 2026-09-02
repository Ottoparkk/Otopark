-- ============================================================================
-- 020  Çöp anlık görüntüsü tahsilatları da alsın
-- ============================================================================

begin;

-- `cop_yaz` biletler/abonmanlar üzerinde BEFORE DELETE tetikleyicisidir ve
-- tahsilatları `bilet_id` / `abonman_id` üzerinden fotoğraflar. 007'deki iki
-- silme RPC'si ise ÖNCE tahsilatları siliyordu: tetikleyici ateşlediğinde
-- ortada kopyalanacak satır kalmıyor, çöp kaydı `"tahsilatlar": []` ile
-- yazılıyordu. Sonuç sessiz veri kaybıdır — çöpten geri alınan bilet parasız
-- geri gelir ve vardiya toplamı bir daha asla eski hâline dönmez.
--
-- Sıra tersine çevrildi: ÖNCE ana kayıt (tetikleyici çocukları sağlam görür),
-- SONRA tahsilatlar. Silinen ana kayıt yüzünden `bilet_id` NULL'a düşeceği
-- için satırlara artık id'leriyle tutunuluyor.

create or replace function public.bilet_sil(p_bilet_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_b        public.biletler;
  v_vardiya  uuid[];
  v_tahsilat uuid[];
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici silebilir.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;

  -- Every shift whose totals are about to change, collected before the rows go.
  select coalesce(array_agg(distinct t.vardiya_id) filter (where t.vardiya_id is not null), '{}')
    into v_vardiya
    from public.tahsilatlar t where t.bilet_id = p_bilet_id;

  -- Satırların id'leri: ana kayıt silinince `bilet_id` NULL'a düşer ve
  -- `where bilet_id = ...` hiçbir şey bulmaz.
  select coalesce(array_agg(t.id), '{}') into v_tahsilat
    from public.tahsilatlar t where t.bilet_id = p_bilet_id;

  perform public.audit('bilet_sil', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'durum', v_b.durum,
                       'tahsil', v_b.tahsil_kurus));

  delete from public.biletler where id = p_bilet_id;

  delete from public.tahsilatlar where iptal_of = any (v_tahsilat);
  delete from public.tahsilatlar where id = any (v_tahsilat);

  perform public.vardiya_yeniden_hesapla(v) from unnest(v_vardiya) as v;
end $$;

create or replace function public.abonman_sil(p_abonman_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_vardiya  uuid[];
  v_tahsilat uuid[];
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici silebilir.';
  end if;
  if not exists (select 1 from public.abonmanlar where id = p_abonman_id) then
    raise exception 'Abonman bulunamadı.';
  end if;

  select coalesce(array_agg(distinct t.vardiya_id) filter (where t.vardiya_id is not null), '{}')
    into v_vardiya
    from public.tahsilatlar t where t.abonman_id = p_abonman_id;

  select coalesce(array_agg(t.id), '{}') into v_tahsilat
    from public.tahsilatlar t where t.abonman_id = p_abonman_id;

  perform public.audit('abonman_sil', 'abonmanlar', p_abonman_id, null);

  delete from public.abonmanlar where id = p_abonman_id;

  delete from public.tahsilatlar where iptal_of = any (v_tahsilat);
  delete from public.tahsilatlar where id = any (v_tahsilat);

  perform public.vardiya_yeniden_hesapla(v) from unnest(v_vardiya) as v;
end $$;

-- -------------------------------------------------------------- grants ---
-- Aynı imzayla replace edildikleri için ACL korunur; yine de açıkça teyit
-- edilir, çünkü bu iki fonksiyon silmenin TEK yoludur.
do $$
begin
  if not has_function_privilege('authenticated', 'public.bilet_sil(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.abonman_sil(uuid)', 'execute') then
    raise exception '020: silme RPC''lerinin yetkisi düştü';
  end if;
  if has_function_privilege('anon', 'public.bilet_sil(uuid)', 'execute') then
    raise exception '020: bilet_sil anon rolüne açık';
  end if;
end $$;

commit;
