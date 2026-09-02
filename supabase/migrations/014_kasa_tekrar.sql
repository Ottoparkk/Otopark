-- ============================================================================
-- 014  Düzenli kasa kayıtları (aylık tekrar)
-- ============================================================================
--
-- Owner request (2026-08-31): PilotGarage'daki "Düzenli" özelliğinin aynısı
-- Kasa'ya. Kira, elektrik, temizlik gibi her ay aynı gün tekrarlayan gider
-- (ya da ek gelir) bir kez tanımlanır, sonrasını gece işi yazar.
--
-- PilotGarage'ın deseni birebir izlendi — ORADA HİÇBİR ŞEY DEĞİŞTİRİLMEDİ,
-- yalnızca okundu:
--   • kural satırı `next_run` taşır, gece işi vadesi gelenleri işler,
--   • yakalama döngüsü güvenlik sayacıyla sınırlıdır (cron günlerce durmuş
--     olabilir; sonsuz döngü kasaya para basar),
--   • tekrarın ürettiği satır, kısmi tekil indeks + `on conflict do nothing`
--     ile tekilleşir — asıl koruma budur, `next_run` değil.
--
-- DÖRT KARAR, ve PilotGarage'dan bilerek AYRILDIĞIMIZ yer:
--
-- 1. YALNIZCA AYLIK. PilotGarage haftalık/aylık/yıllık taşır; buradaki gerçek
--    ihtiyaç ayın belirli bir günü tekrarlayan ödemedir ve arayüzü de zaten
--    tek bir gün seçicisidir. Sıklık enum'u eklemek, kullanılmayan iki dalı
--    ve onları sınayacak testleri bugünden taşımak olurdu (YAGNI). `next_run`
--    tarih olduğu için, gerekirse sıklık sonradan tek kolonla eklenebilir.
--
-- 2. GÜN 1–28 İLE SINIRLI. 31'i seçilen bir kural şubatta atlanır, 29'u
--    seçilen dört yılda bir kayar. Sınır kısıtta, arayüzde değil.
--
-- 3. ONAY YOK. PilotGarage'da tekrar işlemleri `ONAYLANDI` doğar çünkü orada
--    bir Onay kuyruğu var; Otopark'ta kasa zaten Yönetici'ye özel ve
--    onaysızdır, dolayısıyla satır doğrudan kasaya yazılır. Kavram olarak
--    aynı yere düşüyoruz: kural bir kez kurulurken onaylanmıştır.
--
-- 4. KURAL KURULURKEN İLK KAYIT DA YAZILIR, ve `next_run` BUGÜNDEN SONRAKİ
--    güne kurulur. Aksi hâlde ayın 5'inde "her ayın 5'i" diyen biri ya bu ayı
--    kaçırır ya da gece işi aynı gideri ikinci kez yazar. İkisi tek RPC'de
--    yapılır: iki ayrı istemci INSERT'i yarıda kalırsa ya öksüz kural ya
--    kuralsız kayıt kalırdı.
-- ============================================================================

begin;

create table if not exists public.kasa_tekrar_kurallari (
  id          uuid primary key default gen_random_uuid(),
  tur         public.kasa_tur not null,
  tutar_kurus integer not null check (tutar_kurus > 0),
  kategori    text,
  aciklama    text not null default '',
  yontem      public.odeme_yontemi,
  -- Karar 2.
  odeme_gunu  smallint not null check (odeme_gunu between 1 and 28),
  next_run    date not null,
  is_active   boolean not null default true,
  created_by  uuid references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

alter table public.kasa_hareketleri
  add column if not exists tekrar_kural_id uuid
    references public.kasa_tekrar_kurallari(id) on delete set null;

-- Asıl tekilleştirme burada: gece işi iki kez koşsa da, bir kural bir güne
-- yalnızca bir satır yazabilir. `on delete set null` yüzünden kural silinince
-- geçmiş satırlar kasada kalır (para geriye dönük kaybolmamalı) ve indeks
-- onları kısmi koşuluyla görmezden gelir.
create unique index if not exists kasa_tekrar_gun_ux
  on public.kasa_hareketleri (tekrar_kural_id, tarih)
  where tekrar_kural_id is not null;

-- --------------------------------------------------------------- RLS -------
alter table public.kasa_tekrar_kurallari enable row level security;

drop policy if exists kasa_tekrar_all on public.kasa_tekrar_kurallari;
create policy kasa_tekrar_all on public.kasa_tekrar_kurallari for all to authenticated
  using (public.is_yonetici()) with check (public.is_yonetici());

-- Supabase, `public` şemasında YARATILAN her tabloya da anon/authenticated
-- için varsayılan yetki verir (fonksiyonlardaki 012 tuzağının tablo hâli).
-- 003 o süpürmeyi yapar ama yalnızca O AN var olan tablolar için; bu tablo
-- sonradan doğduğu için kendi revoke'unu kendisi taşımak zorunda. Revoke
-- olmadan RLS tek başına yeter gibi görünür — ta ki bir politika gevşeyene
-- kadar; yetki ile politika birbirinin yedeğidir, biri diğerinin yerine
-- geçmez.
revoke all on public.kasa_tekrar_kurallari from anon, authenticated;

-- Yazma RLS'e bırakılır (politika `is_yonetici()`), ama yetkinin kendisi de
-- daraltılır: giriş yapmamış bir istemcinin kural tablosuna hiç işi yok.
grant select, insert, update, delete on public.kasa_tekrar_kurallari to authenticated;

-- ---------------------------------------------------------- kural kur ------
-- Karar 4: kural ve ilk kayıt tek işlemde.
create or replace function public.kasa_tekrar_ekle(
  p_tur      public.kasa_tur,
  p_tutar    integer,
  p_gun      smallint,
  p_kategori text default null,
  p_aciklama text default '',
  p_yontem   public.odeme_yontemi default null,
  -- Bugün de yazılsın mı? Kayıt zaten elle girildiyse istemci false gönderir.
  p_ilk_kayit boolean default true
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_bugun date := (now() at time zone 'Europe/Istanbul')::date;
  v_next  date;
  v_id    uuid;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici düzenli kayıt tanımlayabilir.';
  end if;
  if p_tutar is null or p_tutar <= 0 then
    raise exception 'Tutar sıfırdan büyük olmalı.';
  end if;
  if p_gun is null or p_gun < 1 or p_gun > 28 then
    raise exception 'Tekrar günü 1 ile 28 arasında olmalı.';
  end if;

  -- Kesinlikle bugünden SONRA: bugünün kaydını aşağıda kendimiz yazıyoruz,
  -- gece işi aynı gideri ikinci kez yazmamalı.
  v_next := date_trunc('month', v_bugun)::date + (p_gun - 1);
  if v_next <= v_bugun then
    v_next := (date_trunc('month', v_bugun) + interval '1 month')::date + (p_gun - 1);
  end if;

  insert into public.kasa_tekrar_kurallari
    (tur, tutar_kurus, kategori, aciklama, yontem, odeme_gunu, next_run, created_by)
  values
    (p_tur, p_tutar, nullif(trim(coalesce(p_kategori, '')), ''),
     coalesce(p_aciklama, ''), p_yontem, p_gun, v_next, auth.uid())
  returning id into v_id;

  if p_ilk_kayit then
    insert into public.kasa_hareketleri
      (tur, tutar_kurus, kategori, aciklama, yontem, tarih, tekrar_kural_id, created_by)
    values
      (p_tur, p_tutar, nullif(trim(coalesce(p_kategori, '')), ''),
       coalesce(p_aciklama, ''), p_yontem, v_bugun, v_id, auth.uid());
  end if;

  perform public.audit('kasa_tekrar_ekle', 'kasa_tekrar_kurallari', v_id,
    jsonb_build_object('tur', p_tur, 'tutar', p_tutar, 'gun', p_gun,
                       'next_run', v_next, 'ilk_kayit', p_ilk_kayit));
  return v_id;
end $$;

-- ------------------------------------------------------------ gece işi -----
-- Ayrı bir fonksiyon, `run_gunluk_bakim`'in içine gömmek yerine: o gövde
-- uzun ve bu dosyada tamamını yeniden yazmak, ilgisiz dört adımı kopyalayıp
-- birinde harf hatası yapma riskini bedavaya satın almak olurdu.
create or replace function public.kasa_tekrar_uygula() returns void
language plpgsql security definer set search_path = public as $$
declare
  v_bugun date := (now() at time zone 'Europe/Istanbul')::date;
  v_r     record;
  v_next  date;
  v_kalkan integer;
begin
  for v_r in
    select * from public.kasa_tekrar_kurallari
     where is_active and next_run <= v_bugun
     order by id
  loop
    v_next := v_r.next_run;
    v_kalkan := 0;
    -- Cron günlerce durmuş olabilir; kaçan her dönem yazılır ama sayaç
    -- olmadan bozuk bir `next_run` sonsuz döngüye ve sonsuz gidere dönüşür.
    while v_next <= v_bugun and v_kalkan < 24 loop
      insert into public.kasa_hareketleri
        (tur, tutar_kurus, kategori, aciklama, yontem, tarih, tekrar_kural_id)
      values
        (v_r.tur, v_r.tutar_kurus, v_r.kategori, v_r.aciklama, v_r.yontem,
         v_next, v_r.id)
      on conflict (tekrar_kural_id, tarih) where tekrar_kural_id is not null
        do nothing;

      v_next := (date_trunc('month', v_next) + interval '1 month')::date
                  + (v_r.odeme_gunu - 1);
      v_kalkan := v_kalkan + 1;
    end loop;
    update public.kasa_tekrar_kurallari set next_run = v_next where id = v_r.id;
  end loop;
end $$;

-- -------------------------------------------------------------- grants -----
-- `kasa_tekrar_uygula` içeride rol kontrolü TAŞIYAMAZ: cron'da `auth.uid()`
-- null'dır ve guard her gece patlardı. Tek koruma grant'tır — ve 012'nin
-- dersi gereği `from public` tek başına hiçbir şey kapatmaz.
revoke all on function public.kasa_tekrar_uygula()
  from public, anon, authenticated, service_role;

revoke all on function public.kasa_tekrar_ekle(
  public.kasa_tur, integer, smallint, text, text, public.odeme_yontemi, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.kasa_tekrar_ekle(
  public.kasa_tur, integer, smallint, text, text, public.odeme_yontemi, boolean)
  to authenticated;

-- ---------------------------------------------------------------- cron -----
do $$
begin
  perform cron.unschedule('otopark-kasa-tekrar');
exception when others then null;
end $$;

-- 21:15 UTC = 00:15 İstanbul. Günlük bakımdan (21:05) on dakika sonra:
-- ikisi de aynı anda kilit almaya çalışmasın diye.
select cron.schedule('otopark-kasa-tekrar', '15 21 * * *',
                     $$select public.kasa_tekrar_uygula()$$);

-- ------------------------------------------------------------- verify ------
do $$
begin
  if has_function_privilege('authenticated', 'public.kasa_tekrar_uygula()', 'execute')
     or has_function_privilege('anon', 'public.kasa_tekrar_uygula()', 'execute')
     or has_function_privilege('service_role', 'public.kasa_tekrar_uygula()', 'execute') then
    raise exception '014: kasa_tekrar_uygula istemciye açık';
  end if;
  if not exists (select 1 from pg_indexes
                  where schemaname = 'public' and indexname = 'kasa_tekrar_gun_ux') then
    raise exception '014: tekilleştirme indeksi yok';
  end if;
  if not exists (select 1 from cron.job where jobname = 'otopark-kasa-tekrar') then
    raise exception '014: gece işi kurulmadı';
  end if;
  if has_table_privilege('anon', 'public.kasa_tekrar_kurallari', 'SELECT') then
    raise exception '014: kural tablosu anon rolüne açık';
  end if;
end $$;

commit;
