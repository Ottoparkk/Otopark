-- ============================================================================
-- 021  Çöp bayrağı yalnızca geri alınan kaydı susturur
-- ============================================================================

begin;

create or replace function public.cop_yaz() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_ozet text;
  v_ek   jsonb := '{}'::jsonb;
  v_row  jsonb := to_jsonb(old);
begin
  -- Bu KAYIT için mi? Eskiden bayrak boş değilse her silme atlanıyordu ve
  -- bayrak transaction-local olduğu için `cop_geri_al` çağıran bir işlemin
  -- geri kalanında hiçbir şey çöpe düşmüyordu. Üretimde her RPC kendi
  -- transaction'ı olduğu için zararsızdı; aynı transaction içinde geri alıp
  -- sonra bir şey silen ilk yol, sessizce çöp kaydı üretmeyi bırakırdı.
  if coalesce(current_setting('app.cop_geri_al', true), '') = old.id::text then
    return old;
  end if;

  case tg_table_name
    when 'biletler' then
      v_ozet := old.plaka || ' — ' ||
                to_char(old.giris_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI');
      -- Captured BEFORE the delete, while bilet_id still points here.
      select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_ek
        from public.tahsilatlar t where t.bilet_id = old.id;
      v_ek := jsonb_build_object('tahsilatlar', v_ek);

    when 'abonmanlar' then
      v_ozet := old.plaka || ' — abonman';
      select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_ek
        from public.tahsilatlar t where t.abonman_id = old.id;
      v_ek := jsonb_build_object('tahsilatlar', v_ek);

    when 'kasa_hareketleri' then
      v_ozet := coalesce(nullif(btrim(old.aciklama), ''),
                         case when old.tur = 'GELIR' then 'Gelir' else 'Gider' end)
                || ' — ' || (old.tutar_kurus / 100.0)::numeric(12,2) || ' ₺';
    when 'park_yerleri'   then v_ozet := old.kod || ' — park yeri';
    when 'rezervasyonlar' then v_ozet := coalesce(old.plaka, 'Abonman') || ' — rezervasyon';
    when 'hesaplar'       then v_ozet := old.ad || ' — puan hesabı';
    when 'hesap_araclari' then v_ozet := old.plaka || ' — hesap aracı';
    when 'istisnalar'     then v_ozet := coalesce(old.plaka, '(plakasız)') || ' — ' || old.tur;
    when 'tarifeler'      then v_ozet := 'Tarife — ' || (old.ilk_saat_kurus / 100.0)::numeric(12,2) || ' ₺';
    else v_ozet := tg_table_name;
  end case;

  insert into public.cop (tablo, kayit_id, veri, ek, ozet, silen)
  values (tg_table_name, old.id, v_row, v_ek, v_ozet, auth.uid());

  -- Bounded, so the bin cannot grow without limit. Oldest entries fall out and
  -- become unrecoverable — which is why this is 200 and not 20.
  delete from public.cop c
   where c.id in (select id from public.cop order by silindi_at desc offset 200);

  return old;
end $$;

-- -------------------------------------------------------------- verify ---
do $$
begin
  if not exists (select 1 from pg_trigger
                  where tgname = 'cop_biletler' and not tgisinternal) then
    raise exception '021: çöp tetikleyicisi kayboldu';
  end if;
  if has_function_privilege('anon', 'public.cop_yaz()', 'execute')
     or has_function_privilege('authenticated', 'public.cop_yaz()', 'execute') then
    raise exception '021: cop_yaz istemciye açık';
  end if;
end $$;

commit;
