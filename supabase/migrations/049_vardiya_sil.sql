-- ============================================================================
-- 049  Eski vardiyayı silme: yalnızca Yönetici, Çöp Kutusu'na
-- ============================================================================

begin;

-- Sahibin isteği (2026-11-07): Yönetici eski (kapanmış) bir vardiyayı
-- silebilmeli; silinen Çöp Kutusu'na düşer ve geri alınabilir.
--
-- Silme YUMUŞAKTIR, çünkü vardiya paraya bağlıdır: `biletler.vardiya_id`,
-- `biletler.kapatan_vardiya_id` ve `tahsilatlar.vardiya_id` hepsi
-- `on delete set null`. Satırı gerçekten silmek o bağları koparır ve geri
-- almak, kapanmış biletleri (değişmezlik kuralı, 029) yeniden bağlamayı
-- gerektirirdi. Bunun yerine satır kalır, `silindi_at` dolar ve RLS onu
-- herkesten gizler — bilet ve tahsilat bağıyla, tutarıyla aynen kalır; kasa,
-- raporlar ve tahsilat onayı hiç oynamaz. Silinen yalnızca vardiyanın kendi
-- sayım kaydıdır (sayılan / fark).
--
-- Çöp Kutusu'ndan "Geri al" bayrağı temizler; "Kalıcı sil" satırı gerçekten
-- siler (her kalıcı silmede olduğu gibi bağlar null'a düşer, tutarlar aynı
-- kalır). Çöp en yeni 200 kaydı tutar (007); çöpten düşen bir vardiya gizli
-- kalır — kullanıcı için kalıcı silinmiş gibidir, para yine değişmez.
--
-- Sunucu tarafında kapanmış vardiyaları LİSTELEYEN fonksiyon yok (hepsi açık
-- vardiyayla ya da verilen bir id ile çalışır; 2026-11-07 tarandı), yani RLS
-- gizlemesi her ekranı kapsar.

-- ---------------------------------------------------------------- şema ----

alter table public.vardiyalar
  add column if not exists silindi_at timestamptz,
  add column if not exists silen uuid references public.profiles(id) on delete set null;

-- 030'un politikası + "silinmemiş". Açık vardiya silinemediği için personelin
-- gördüğü (açık vardiya) hiç değişmez.
drop policy if exists vardiyalar_select on public.vardiyalar;
create policy vardiyalar_select on public.vardiyalar for select to authenticated
  using (silindi_at is null
         and (public.is_yonetici() or (public.is_staff() and kapanis_at is null)));

-- ---------------------------------------------------------- vardiya_sil ----

create or replace function public.vardiya_sil(p_vardiya_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_v public.vardiyalar;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici vardiya silebilir.';
  end if;

  select * into v_v from public.vardiyalar where id = p_vardiya_id for update;
  if not found or v_v.silindi_at is not null then
    raise exception 'Vardiya bulunamadı.';
  end if;
  -- Açık vardiya çekmecenin kendisidir; kapatma isteği de yalnızca açık
  -- vardiyada durur (035), yani bu kural ikisini birden kapsar.
  if v_v.kapanis_at is null then
    raise exception 'Açık vardiya silinemez; önce kapatın.';
  end if;

  update public.vardiyalar
     set silindi_at = now(), silen = auth.uid()
   where id = v_v.id;

  insert into public.cop (tablo, kayit_id, veri, ozet, silen)
  values ('vardiyalar', v_v.id, to_jsonb(v_v),
          'Vardiya — ' || to_char(v_v.acilis_at at time zone 'Europe/Istanbul',
                                  'DD.MM.YYYY HH24:MI'),
          auth.uid());

  -- 007'nin sınırı: çöp en yeni 200 kaydı tutar.
  delete from public.cop c
   where c.id in (select id from public.cop order by silindi_at desc offset 200);

  perform public.audit('vardiya_sil', 'vardiyalar', v_v.id,
    jsonb_build_object('acilis_at', v_v.acilis_at, 'kapanis_at', v_v.kapanis_at,
                       'sayilan', v_v.sayilan_nakit_kurus, 'fark', v_v.fark_kurus));
end $$;

revoke all on function public.vardiya_sil(uuid) from public;
revoke all on function public.vardiya_sil(uuid) from anon, authenticated, service_role;
grant execute on function public.vardiya_sil(uuid) to authenticated;

-- ----------------------------------------------------------- cop_geri_al ---
--
-- 010'un gövdesi BİREBİR, yalnızca `vardiyalar` dalı eklendi: satır zaten
-- duruyor, geri almak bayrağı temizlemektir (insert değil).

create or replace function public.cop_geri_al(p_cop_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_c        public.cop;
  v_vardiya  uuid[];
  v_t        jsonb;
  v_yer_dusu boolean := false;   -- 010
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici geri alabilir.';
  end if;

  select * into v_c from public.cop where id = p_cop_id;
  if not found then
    raise exception 'Çöp kaydı bulunamadı.';
  end if;

  perform set_config('app.cop_geri_al', v_c.kayit_id::text, true);

  begin
    case v_c.tablo
      when 'biletler' then
        -- 010, see the note above this function.
        if (v_c.veri ->> 'durum') = 'ACIK'
           and (v_c.veri ->> 'park_yeri_id') is not null
           and exists (select 1 from public.biletler b
                        where b.park_yeri_id = (v_c.veri ->> 'park_yeri_id')::uuid
                          and b.durum = 'ACIK') then
          v_c.veri   := jsonb_set(v_c.veri, '{park_yeri_id}', 'null'::jsonb);
          v_yer_dusu := true;
        end if;
        insert into public.biletler select * from jsonb_populate_record(null::public.biletler, v_c.veri);
      when 'abonmanlar' then
        insert into public.abonmanlar select * from jsonb_populate_record(null::public.abonmanlar, v_c.veri);
      when 'kasa_hareketleri' then
        insert into public.kasa_hareketleri select * from jsonb_populate_record(null::public.kasa_hareketleri, v_c.veri);
      when 'park_yerleri' then
        insert into public.park_yerleri select * from jsonb_populate_record(null::public.park_yerleri, v_c.veri);
      when 'rezervasyonlar' then
        insert into public.rezervasyonlar select * from jsonb_populate_record(null::public.rezervasyonlar, v_c.veri);
      when 'hesaplar' then
        insert into public.hesaplar select * from jsonb_populate_record(null::public.hesaplar, v_c.veri);
      when 'hesap_araclari' then
        insert into public.hesap_araclari select * from jsonb_populate_record(null::public.hesap_araclari, v_c.veri);
      when 'istisnalar' then
        insert into public.istisnalar select * from jsonb_populate_record(null::public.istisnalar, v_c.veri);
      when 'tarifeler' then
        insert into public.tarifeler select * from jsonb_populate_record(null::public.tarifeler, v_c.veri);
      when 'vardiyalar' then
        -- 049: yumuşak silme — satır duruyor, bayrak temizlenir.
        update public.vardiyalar
           set silindi_at = null, silen = null
         where id = v_c.kayit_id and silindi_at is not null;
        if not found then
          raise exception 'Vardiya bulunamadı.';
        end if;
      else
        raise exception 'Bu kayıt türü geri alınamaz: %', v_c.tablo;
    end case;
  exception
    when unique_violation then
      raise exception 'Bu kayıt zaten geri alınmış ya da yerine yenisi eklenmiş.';
    when foreign_key_violation then
      raise exception 'Bu kaydın bağlı olduğu bir kayıt silinmiş; önce onu geri alın.';
  end;

  -- Collections come back with the record they belonged to.
  for v_t in select jsonb_array_elements(coalesce(v_c.ek -> 'tahsilatlar', '[]'::jsonb)) loop
    begin
      insert into public.tahsilatlar
      select * from jsonb_populate_record(null::public.tahsilatlar, v_t);
      v_vardiya := v_vardiya || (v_t ->> 'vardiya_id')::uuid;
    exception when unique_violation then
      null;   -- already restored by an earlier attempt
    end;
  end loop;

  delete from public.cop where id = p_cop_id;

  perform public.audit('cop_geri_al', v_c.tablo, v_c.kayit_id,
    jsonb_build_object('ozet', v_c.ozet, 'park_yeri_dusuruldu', v_yer_dusu));

  perform public.vardiya_yeniden_hesapla(v)
    from unnest(coalesce(v_vardiya, '{}')) as v where v is not null;
end $$;

-- -------------------------------------------------------- cop_kalici_sil ---
--
-- 007'nin gövdesi + `vardiyalar`: çöp kaydıyla birlikte gizli satır da
-- gerçekten silinir. Bilet ve tahsilat bağları null'a düşer (on delete set
-- null; bilet değişmezlik kuralı referansın null'a düşmesine izin verir, 029),
-- tutarlar aynı kalır.

create or replace function public.cop_kalici_sil(p_cop_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_c public.cop;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici silebilir.';
  end if;
  select * into v_c from public.cop where id = p_cop_id;
  if not found then
    raise exception 'Çöp kaydı bulunamadı.';
  end if;
  if v_c.tablo = 'vardiyalar' then
    delete from public.vardiyalar where id = v_c.kayit_id and silindi_at is not null;
    perform public.audit('vardiya_kalici_sil', 'vardiyalar', v_c.kayit_id,
      jsonb_build_object('ozet', v_c.ozet));
  end if;
  delete from public.cop where id = p_cop_id;
end $$;

-- `create or replace` mevcut yetkileri korur; yine de 012'nin hâli açıkça
-- yeniden yazılır ki bu dosya tek başına okunduğunda doğru olsun.
revoke all on function public.cop_geri_al(uuid) from public;
revoke all on function public.cop_geri_al(uuid) from anon, authenticated, service_role;
grant execute on function public.cop_geri_al(uuid) to authenticated;
revoke all on function public.cop_kalici_sil(uuid) from public;
revoke all on function public.cop_kalici_sil(uuid) from anon, authenticated, service_role;
grant execute on function public.cop_kalici_sil(uuid) to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  f text;
  r text;
begin
  foreach f in array array['public.vardiya_sil(uuid)', 'public.cop_geri_al(uuid)',
                           'public.cop_kalici_sil(uuid)'] loop
    if not has_function_privilege('authenticated', f, 'execute') then
      raise exception '049: % authenticated rolüne kapalı', f;
    end if;
    foreach r in array array['anon', 'service_role'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception '049: % % rolüne açık', f, r;
      end if;
    end loop;
  end loop;

  if not exists (select 1 from pg_proc p
                   join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'vardiya_sil'
                    and p.prosecdef
                    and p.proconfig @> array['search_path=public']) then
    raise exception '049: vardiya_sil SECURITY DEFINER + search_path=public değil';
  end if;

  if not exists (select 1 from pg_policies
                  where schemaname = 'public' and tablename = 'vardiyalar'
                    and policyname = 'vardiyalar_select'
                    and qual like '%silindi_at IS NULL%') then
    raise exception '049: vardiyalar_select silinenleri gizlemiyor';
  end if;
end
$do$;

commit;
