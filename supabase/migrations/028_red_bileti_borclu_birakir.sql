-- ============================================================================
-- 028  Reddedilen tahsilat bileti borçlu bırakır
-- ============================================================================

begin;

-- KARAR: "Reddet" = "bu para alınmadı". Alınmış ama sayılmayacak bir para
-- değil — o başka bir şey olurdu ve müşteriden ikinci kez tahsil etmeye yol
-- açardı. Sahibinin kararı budur ve kod artık bunu söylüyor.
--
-- Bugüne kadar red yalnızca `tahsilatlar.durum`'a dokunuyordu; bilet ise
-- "₺250 tahsil edildi" demeye devam ediyordu. İkisi birbirini tutmuyordu ve
-- hiçbir yer bunu uzlaştırmıyordu. 027'ye kadar zararsızdı, çünkü kapanmış
-- bir bileti tahsil etmenin yolu yoktu; artık var (`bilet_tahsil`) ve o yol
-- biletin kendi sayısına bakıyor — yani reddedilen bir tahsilat, borcu
-- ARAYÜZDEN KURTARILAMAZ hâle getiriyordu.
--
-- VARDİYA SAYIMI BİLEREK DEĞİŞMEDİ: `vardiya_kapat` nakit toplamını durum
-- süzmeden alır ("çekmecede ne varsa o"). Red "para gelmedi" demek olduğuna
-- göre, o vardiyanın sayımının eksik çıkması DOĞRU sonuçtur — aranan sinyal
-- tam olarak odur.

-- Gövde 017'den birebir; tek fark bileti geri alan blok ve `returning`
-- listesine eklenen iki kolon.
create or replace function public.tahsilat_reddet(
  p_ids uuid[], p_sebep text default null
) returns integer
language plpgsql security definer set search_path = public as $fn$
declare
  v_r record;
  v_n integer := 0;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici tahsilat reddedebilir.';
  end if;

  for v_r in
    with u as (
      update public.tahsilatlar
         set durum     = 'REDDEDILDI',
             onaylayan = auth.uid(),
             onay_at   = now(),
             onay_notu = nullif(btrim(coalesce(p_sebep, '')), '')
       where id = any (p_ids) and durum = 'BEKLIYOR'
      returning id, tur, tutar_kurus, bilet_id, iptal_of
    )
    select * from u
  loop
    -- `iptal_of is null`: ters kayıt reddedilirse bilet geri alınmaz, çünkü
    -- ters kaydın işi zaten bir tahsilatı geri almaktı. 017'nin tetikleyicisi
    -- gereği bekleyen bir aslın ters kaydı zaten REDDEDILDI doğar, yani bu
    -- dal pratikte hiç çalışmaz — ama guard ucuz ve niyeti yazıyor.
    --
    -- Bayrak 027'nin dar iznidir: YALNIZCA `tahsil_kurus` ve `odeme_yontemi`
    -- değişebilir, ki geri alırken değiştirdiğimiz de tam olarak bu ikisi.
    -- İşlem-yereldir ve hemen temizlenir; döngüde her bilet için ayrı ayrı
    -- kurulur çünkü guard bileti kimliğiyle eşleştirir.
    if v_r.tur = 'BILET' and v_r.bilet_id is not null and v_r.iptal_of is null then
      perform set_config('app.bilet_tahsil', v_r.bilet_id::text, true);
      update public.biletler
         set tahsil_kurus = 0, odeme_yontemi = null
       where id = v_r.bilet_id and durum = 'KAPALI' and tahsil_kurus <> 0;
      perform set_config('app.bilet_tahsil', '', true);
    end if;

    perform public.audit('tahsilat_reddet', 'tahsilatlar', v_r.id,
      jsonb_build_object('tur', v_r.tur, 'tutar', v_r.tutar_kurus,
                         'sebep', btrim(coalesce(p_sebep, ''))));
    v_n := v_n + 1;
  end loop;

  return v_n;
end
$fn$;

-- ABONMAN tahsilatları bilerek kapsam dışı: onların karşılığı bir bilet değil,
-- abonmanın geçerlilik tarihidir ve orada "geri alma"nın ne demek olduğu ayrı
-- bir karardır. Burada yalnızca biletin sayısı ile tahsilatın durumu arasında
-- açılan çelişki kapatılıyor.

-- --------------------------------------------------------- bilet_tahsil ----

-- Gövde 027'den birebir; tek fark görünürlük kontrolü.
--
-- `security definer` RLS'i atlar, dolayısıyla `is_staff()` tek başına RPC'yi
-- okuma yolundan DAHA GENİŞ yapıyordu: Personel yalnızca kendi açık
-- vardiyasında kapanan bileti görebilir, ama elindeki bir id ile başka
-- vardiyanın biletini tahsil edip parayı kendi vardiyasına yazabiliyordu.
-- Kontrol `biletler_select` politikasının aynısıdır.
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
  if not (public.is_yonetici() or v_b.kapatan_vardiya_id = public.acik_vardiyam()) then
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

  select v.id into v_vardiya from public.vardiyalar v
   where v.personel_id = auth.uid() and v.kapanis_at is null limit 1;

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

-- -------------------------------------------------------------- verify ---
do $do$
begin
  -- Aynı imzayla replace edildiler; yetkiler korunmuş olmalı.
  if not has_function_privilege('authenticated',
        'public.tahsilat_reddet(uuid[], text)', 'execute')
     or not has_function_privilege('authenticated',
        'public.bilet_tahsil(uuid, public.odeme_yontemi)', 'execute') then
    raise exception '028: RPC yetkileri düştü';
  end if;
  if has_function_privilege('anon', 'public.tahsilat_reddet(uuid[], text)', 'execute')
     or has_function_privilege('anon', 'public.bilet_tahsil(uuid, public.odeme_yontemi)', 'execute') then
    raise exception '028: onay/tahsil yolu anon rolüne açık';
  end if;
end
$do$;

commit;
