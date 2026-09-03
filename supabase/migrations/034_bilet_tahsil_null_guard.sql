-- ============================================================================
-- 034  bilet_tahsil yetki kontrolü: NULL karşılaştırma guard'ı deliyordu
-- ============================================================================

begin;

-- Guard'ın amacı yorumunda yazılı: "okuma yolunda göremediği bir bileti tahsil
-- edememeli". RLS bunu `using (...)` ile yapar ve orada NULL = satır yok, yani
-- güvenlidir. Aynı ifade `if not (...)` içine konunca ÜÇ DEĞERLİ MANTIK ters
-- çalışır:
--
--   is_yonetici()                                    -> false
--   kapatan_vardiya_id = acik_vardiyam()             -> NULL  (bir taraf null)
--   false or NULL                                    -> NULL
--   not NULL                                         -> NULL
--   if NULL then raise                               -> ÇALIŞMAZ
--
-- Yani guard sessizce İZİN VERİYORDU. İki gerçek giriş yolu vardı:
--   (a) açık vardiyası OLMAYAN bir personel — `acik_vardiyam()` null döner ve
--       kişi kapanmış HERHANGİ bir bileti tahsil edebilirdi. RLS o biletleri
--       ona zaten göstermiyor, yani RPC kendi aynası olduğu okuma yolundan
--       daha gevşekti.
--   (b) hiç vardiya açık değilken kapanmış bir bilet (`kapatan_vardiya_id`
--       null) — onu da herkes tahsil edebilirdi.
--
-- `coalesce(..., false)` ikisini birden kapatır: bilinmeyen artık "hayır"
-- demektir. 028'den beri açıktı; 030 ile ilgisi yok, ama 030'un vardiya modeli
-- değişikliği smoke test'i o bölgeye getirdiği için ortaya çıktı.
--
-- Gövde 030'dan birebir; tek fark bu iki satır.
create or replace function public.bilet_tahsil(
  p_bilet_id      uuid,
  p_odeme_yontemi public.odeme_yontemi
) returns integer
language plpgsql security definer set search_path = public as $fn$
declare
  v_b       public.biletler;
  v_net     integer;
  v_vardiya uuid;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_odeme_yontemi is null then
    raise exception 'Ödeme yöntemi zorunludur.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;

  if v_b.durum <> 'KAPALI' then
    raise exception 'Yalnızca çıkışı yapılmış bir bilet tahsil edilebilir.';
  end if;

  -- Okuma yolunda göremediği bir bileti tahsil edememeli. Durum kontrolünden
  -- SONRA: açık bir bileti Personel zaten görebilir, ve onun `kapatan_vardiya_id`
  -- alanı boş olduğu için bu kontrol önce koşsaydı yanlış hatayı verirdi.
  if not (public.is_yonetici()
          or coalesce(v_b.kapatan_vardiya_id = public.acik_vardiyam(), false)) then
    raise exception 'Bu bileti tahsil etme yetkiniz yok.';
  end if;

  v_net := v_b.ucret_kurus - v_b.indirim_kurus;
  if v_net <= 0 then
    raise exception 'Bu bilette tahsil edilecek ücret yok.';
  end if;
  if v_b.tahsil_kurus <> 0 then
    raise exception 'Bu biletin ödemesi zaten alınmış.';
  end if;

  -- Reddedilen satır sayılmaz: red artık "para gelmedi" demek (028), yani o
  -- bilet yeniden tahsil edilebilir olmalı.
  if exists (select 1 from public.tahsilatlar t
              where t.bilet_id = p_bilet_id
                and t.iptal_of is null
                and t.durum <> 'REDDEDILDI') then
    raise exception 'Bu bilet için zaten bir tahsilat kaydı var.';
  end if;

  v_vardiya := public.acik_vardiyam();

  perform set_config('app.bilet_tahsil', p_bilet_id::text, true);
  update public.biletler
     set tahsil_kurus = v_net, odeme_yontemi = p_odeme_yontemi
   where id = p_bilet_id;
  perform set_config('app.bilet_tahsil', '', true);

  insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, created_by)
  values ('BILET', p_bilet_id, v_net, p_odeme_yontemi, v_vardiya, auth.uid());

  perform public.audit('bilet_sonradan_tahsil', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'tutar', v_net, 'yontem', p_odeme_yontemi));

  return v_net;
end
$fn$;

do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'bilet_tahsil';
  if v_src not like '%coalesce(v_b.kapatan_vardiya_id = public.acik_vardiyam(), false)%' then
    raise exception 'DOĞRULAMA: bilet_tahsil guard''ı hâlâ NULL geçirgen.';
  end if;
end
$do$;

commit;
