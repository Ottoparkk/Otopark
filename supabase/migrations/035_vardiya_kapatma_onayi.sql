-- ============================================================================
-- 035  Vardiya kapatma onayı: personelin sayımı Yönetici onayına düşer
-- ============================================================================

begin;

-- ---------------------------------------------------------------- şema ----

-- Yeni değerler bu işlemde YALNIZCA tanımlanır, kullanılmaz. SQL dilindeki
-- `bildirim_yonetici_turu` karşılaştırmayı `::text` üzerinden yapar (019/025
-- deseni), PL/pgSQL gövdelerindeki literaller ise çalışma anında — yani
-- commit sonrasında — çözülür.
alter type public.bildirim_tur add value if not exists 'VARDIYA_KAPATMA';
alter type public.bildirim_tur add value if not exists 'VARDIYA_KARAR';

-- İstek AÇIK vardiyanın üstünde durur; `kapanis_at` null kalır. Kasa hâlâ
-- açıktır çünkü onay gelene kadar kapanmamıştır: `vardiyalar_tek_acik_ux`
-- yeni vardiya açılmasını engellemeye devam eder ve bu arada tahsil edilen
-- nakit doğru vardiyaya yazılır.
alter table public.vardiyalar
  add column if not exists kapatma_talebi_at timestamptz,
  add column if not exists kapatma_talebi_by uuid references public.profiles(id) on delete set null,
  add column if not exists talep_sayilan_kurus integer
    check (talep_sayilan_kurus is null or talep_sayilan_kurus >= 0),
  -- Personelin saydığı ANDA beklenen tutar. Onayda beklenen YENİDEN hesaplanır
  -- (sayımdan sonra tahsilat girmiş olabilir); ikisi farklıysa aradaki para
  -- Yöneticiye gösterilir. Bunu saklamazsak "sayım yanlış" ile "sayımdan sonra
  -- para geldi" birbirinden ayırt edilemez.
  add column if not exists talep_beklenen_kurus integer,
  add column if not exists talep_notlar text;

do $do$
begin
  -- Dört alan birlikte hareket eder: yarısı dolu bir istek okunamaz.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.vardiyalar'::regclass
                    and conname = 'vardiyalar_talep_ck') then
    alter table public.vardiyalar add constraint vardiyalar_talep_ck
      check ((kapatma_talebi_at is null) = (talep_sayilan_kurus is null));
  end if;
end
$do$;

-- İstek yalnızca AÇIK vardiyada anlamlıdır ve her okuma `kapanis_at is null`
-- ile süzer. `vardiya_zorla_kapat` (025) bu sütunları temizlemez: kapanmış
-- satırdaki artık değer hiçbir yerde okunmaz, ve o gövdeyi buraya kopyalamak
-- kopyalamanın kendi riskini getirirdi.
create index if not exists vardiyalar_kapatma_talebi_ix
  on public.vardiyalar (kapatma_talebi_at)
  where kapanis_at is null and kapatma_talebi_at is not null;

-- ------------------------------------------------------------ bildirim ----

-- VARDIYA_KAPATMA Yöneticiye aittir (karar onun). VARDIYA_KARAR ise BİLEREK
-- listede yok: kararı, isteği yapan personel alır — listeye girseydi
-- `notifications_select` onu kendi bildiriminden men ederdi.
--
-- PLAKA_SUPHE de eklendi: 029 enum değerini ekledi ama bu listeye koymayı
-- atlamış. Yalnızca `notify_yonetici` üretiyor, yani bugün kimseden bir şey
-- gizlemez — kapattığı açık, rol DEĞİŞTİKTEN sonra eski satırların Yönetici
-- olmayanda görünür kalması (025'in bu listeyi var etme sebebi).
create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $fn$
  select p_tur::text in (
    'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA','ISTISNA',
    'KAMERA_HAREKET','VARDIYA_ACIK','ONAY_BEKLIYOR','PLAKA_SUPHE',
    'VARDIYA_KAPATMA'
  );
$fn$;

-- Tek kişiye bildirim. Süzgeçleri `notify_yonetici` ile birebir aynı olmalı
-- (pasif hesap, kapalı tercih); iki ayrı kopya zamanla birbirinden ayrılır.
create or replace function public.notify_kisi(
  p_profile_id uuid, p_tur public.bildirim_tur, p_baslik text,
  p_govde text, p_link text default null
) returns void
language sql security definer set search_path = public as $fn$
  insert into public.notifications (profile_id, tur, baslik, govde, link)
  select p.id, p_tur, p_baslik, p_govde, p_link
  from public.profiles p
  where p.id = p_profile_id
    and p.durum = 'ACTIVE'
    and coalesce(p.notif_prefs ->> p_tur::text, 'true') <> 'false';
$fn$;

-- İçeriden çağrılır; istemciye açık olsaydı herkes herkese bildirim
-- yazabilirdi. `from public` şart — yeni fonksiyona EXECUTE önce PUBLIC'e
-- verilir ve `authenticated` de PUBLIC üyesidir (058 dersi).
revoke all on function public.notify_kisi(uuid, public.bildirim_tur, text, text, text)
  from public;
revoke all on function public.notify_kisi(uuid, public.bildirim_tur, text, text, text)
  from anon, authenticated, service_role;

-- ------------------------------------------------------------- kapatma ----

-- Gövde 030'dan; eklenen tek şey personel dalı ve dönüşteki `kapandi`.
-- Dönüş tipi değiştiği için `create or replace` YETMEZ — ve drop ACL'i de
-- siler (032'nin dersi), o yüzden yetkiler aşağıda yeniden kuruluyor.
drop function if exists public.vardiya_kapat(integer, text);
create function public.vardiya_kapat(
  p_sayilan_nakit_kurus integer, p_notlar text default null
) returns table (kapandi boolean, beklenen_kurus integer, sayilan_kurus integer,
                 fark_kurus integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_v        public.vardiyalar;
  v_nakit    integer;
  v_beklenen integer;
  v_fark     integer;
  v_ad       text;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_sayilan_nakit_kurus is null or p_sayilan_nakit_kurus < 0 then
    raise exception 'Sayılan nakit negatif olamaz.';
  end if;

  select * into v_v from public.vardiyalar
   where kapanis_at is null for update;
  if not found then
    raise exception 'Açık kasa vardiyası yok.';
  end if;

  select coalesce(sum(t.tutar_kurus), 0)::integer into v_nakit
    from public.tahsilatlar t
   where t.vardiya_id = v_v.id and t.yontem = 'NAKIT';

  v_beklenen := v_v.acilis_nakit_kurus + v_nakit;
  v_fark     := p_sayilan_nakit_kurus - v_beklenen;

  v_ad := coalesce((select p.ad_soyad from public.profiles p where p.id = auth.uid()),
                   'Personel');

  -- Personel kapatmaz, İSTER. Çekmece Yönetici onaylayana kadar açık kalır;
  -- aynı personel sayımını düzeltip yeniden gönderebilir (satırın üstüne
  -- yazılır, ikinci bir istek doğmaz).
  if not public.is_yonetici() then
    update public.vardiyalar
       set kapatma_talebi_at    = now(),
           kapatma_talebi_by    = auth.uid(),
           talep_sayilan_kurus  = p_sayilan_nakit_kurus,
           talep_beklenen_kurus = v_beklenen,
           talep_notlar         = nullif(btrim(p_notlar), '')
     where id = v_v.id;

    perform public.audit('vardiya_kapatma_talebi', 'vardiyalar', v_v.id,
      jsonb_build_object('beklenen', v_beklenen, 'sayilan', p_sayilan_nakit_kurus,
                         'fark', v_fark));
    -- Farkı bildirimin İÇİNE yazmak şart. Kapanış artık onayda olduğu için
    -- oradaki VARDIYA_FARK satırı `notify_yonetici`nin "çağıranı hariç tut"
    -- kuralına takılır — onaylayan Yöneticinin kendisidir — ve tek Yöneticili
    -- bir kasada fark hiçbir bildirimde görünmezdi. Farkı gören ilk mesaj bu.
    perform public.notify_yonetici('VARDIYA_KAPATMA', 'Vardiya kapatma isteği',
      v_ad || ' — sayılan ' || (p_sayilan_nakit_kurus / 100.0)::numeric(12,2)
        || ' TL, fark ' || (v_fark / 100.0)::numeric(12,2) || ' TL',
      '/finans/onay');

    -- `return query` akışı DURDURMAZ; bu `return` olmasa Yönetici dalı da
    -- çalışır ve vardiya sessizce kapanırdı.
    return query select false, v_beklenen, p_sayilan_nakit_kurus, v_fark;
    return;
  end if;

  -- Yönetici kendi sayımıyla doğrudan kapatır. Bekleyen bir istek varsa
  -- birlikte temizlenir: kapanmış satırda kalan istek hiçbir listede
  -- görünmez ve isteği yapan personel isteğinin ne olduğunu asla öğrenemezdi.
  update public.vardiyalar
     set kapanis_at           = now(),
         sayilan_nakit_kurus  = p_sayilan_nakit_kurus,
         beklenen_nakit_kurus = v_beklenen,
         fark_kurus           = v_fark,
         kapanis_kaynak       = 'ELLE',
         kapatan_id           = auth.uid(),
         notlar               = nullif(btrim(p_notlar), ''),
         kapatma_talebi_at    = null,
         kapatma_talebi_by    = null,
         talep_sayilan_kurus  = null,
         talep_beklenen_kurus = null,
         talep_notlar         = null
   where id = v_v.id;

  if v_v.kapatma_talebi_by is not null and v_v.kapatma_talebi_by <> auth.uid() then
    perform public.notify_kisi(v_v.kapatma_talebi_by, 'VARDIYA_KARAR',
      'Vardiya kapatıldı',
      'Vardiya Yönetici tarafından kendi sayımıyla kapatıldı.', '/vardiya');
  end if;

  if v_fark <> 0 then
    perform public.audit('vardiya_fark', 'vardiyalar', v_v.id,
      jsonb_build_object('beklenen', v_beklenen, 'sayilan', p_sayilan_nakit_kurus,
                         'fark', v_fark));
    perform public.notify_yonetici('VARDIYA_FARK', 'Vardiya farkı',
      v_ad || ' — fark ' || (v_fark / 100.0)::numeric(12,2) || ' TL',
      '/finans/vardiyalar');
  end if;

  return query select true, v_beklenen, p_sayilan_nakit_kurus, v_fark;
end
$fn$;

revoke all on function public.vardiya_kapat(integer, text) from public;
revoke all on function public.vardiya_kapat(integer, text) from anon, service_role;
grant execute on function public.vardiya_kapat(integer, text) to authenticated;

-- --------------------------------------------------------------- karar ----

create or replace function public.vardiya_kapatma_onayla(p_vardiya_id uuid)
returns table (beklenen_kurus integer, sayilan_kurus integer, fark_kurus integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_v        public.vardiyalar;
  v_nakit    integer;
  v_beklenen integer;
  v_fark     integer;
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_v from public.vardiyalar where id = p_vardiya_id for update;
  if not found then
    raise exception 'Vardiya bulunamadı.';
  end if;
  if v_v.kapanis_at is not null then
    raise exception 'Vardiya zaten kapatılmış.';
  end if;
  if v_v.kapatma_talebi_at is null then
    raise exception 'Bu vardiya için kapatma isteği yok.';
  end if;

  -- Beklenen YENİDEN hesaplanır. Sayımdan sonra tahsilat girmişse fark
  -- gerçekten oradadır; isteğin içindeki eski tutarı kullanmak, kasada
  -- olmayan parayı "tutuyor" göstermek olurdu.
  select coalesce(sum(t.tutar_kurus), 0)::integer into v_nakit
    from public.tahsilatlar t
   where t.vardiya_id = v_v.id and t.yontem = 'NAKIT';

  v_beklenen := v_v.acilis_nakit_kurus + v_nakit;
  v_fark     := v_v.talep_sayilan_kurus - v_beklenen;

  update public.vardiyalar
     set kapanis_at           = now(),
         sayilan_nakit_kurus  = v_v.talep_sayilan_kurus,
         beklenen_nakit_kurus = v_beklenen,
         fark_kurus           = v_fark,
         kapanis_kaynak       = 'ELLE',
         -- Kapatan = nakdi SAYAN kişi, onaylayan değil. Onaylayan audit'te.
         kapatan_id           = v_v.kapatma_talebi_by,
         notlar               = v_v.talep_notlar,
         kapatma_talebi_at    = null,
         kapatma_talebi_by    = null,
         talep_sayilan_kurus  = null,
         talep_beklenen_kurus = null,
         talep_notlar         = null
   where id = v_v.id;

  perform public.audit('vardiya_kapatma_onay', 'vardiyalar', v_v.id,
    jsonb_build_object('talep_eden', v_v.kapatma_talebi_by,
                       'beklenen', v_beklenen,
                       'talep_beklenen', v_v.talep_beklenen_kurus,
                       'sayilan', v_v.talep_sayilan_kurus, 'fark', v_fark));

  if v_v.kapatma_talebi_by is not null then
    perform public.notify_kisi(v_v.kapatma_talebi_by, 'VARDIYA_KARAR',
      'Vardiya kapatıldı', 'Kapatma isteğiniz onaylandı.', '/vardiya');
  end if;

  if v_fark <> 0 then
    perform public.notify_yonetici('VARDIYA_FARK', 'Vardiya farkı',
      'Kapanan vardiyada fark ' || (v_fark / 100.0)::numeric(12,2) || ' TL',
      '/finans/vardiyalar');
  end if;

  return query select v_beklenen, v_v.talep_sayilan_kurus, v_fark;
end
$fn$;

revoke all on function public.vardiya_kapatma_onayla(uuid) from public;
revoke all on function public.vardiya_kapatma_onayla(uuid) from anon, service_role;
grant execute on function public.vardiya_kapatma_onayla(uuid) to authenticated;

create or replace function public.vardiya_kapatma_reddet(
  p_vardiya_id uuid, p_sebep text default null
) returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_v     public.vardiyalar;
  v_sebep text;
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_v from public.vardiyalar where id = p_vardiya_id for update;
  if not found then
    raise exception 'Vardiya bulunamadı.';
  end if;
  if v_v.kapanis_at is not null then
    raise exception 'Vardiya zaten kapatılmış.';
  end if;
  if v_v.kapatma_talebi_at is null then
    raise exception 'Bu vardiya için kapatma isteği yok.';
  end if;

  v_sebep := nullif(btrim(p_sebep), '');

  -- Vardiya AÇIK kalır: reddedilen bir sayım, kapanmamış bir çekmecedir.
  -- Personel yeniden sayıp yeniden gönderebilir.
  update public.vardiyalar
     set kapatma_talebi_at    = null,
         kapatma_talebi_by    = null,
         talep_sayilan_kurus  = null,
         talep_beklenen_kurus = null,
         talep_notlar         = null
   where id = v_v.id;

  perform public.audit('vardiya_kapatma_ret', 'vardiyalar', v_v.id,
    jsonb_build_object('talep_eden', v_v.kapatma_talebi_by,
                       'sayilan', v_v.talep_sayilan_kurus, 'sebep', v_sebep));

  if v_v.kapatma_talebi_by is not null then
    perform public.notify_kisi(v_v.kapatma_talebi_by, 'VARDIYA_KARAR',
      'Vardiya kapatılmadı',
      coalesce(v_sebep, 'Kapatma isteğiniz reddedildi. Sayımı tekrarlayın.'),
      '/vardiya');
  end if;
end
$fn$;

revoke all on function public.vardiya_kapatma_reddet(uuid, text) from public;
revoke all on function public.vardiya_kapatma_reddet(uuid, text) from anon, service_role;
grant execute on function public.vardiya_kapatma_reddet(uuid, text) to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  v_fn  text;
  v_rol text;
begin
  foreach v_fn in array array[
    'public.vardiya_kapat(integer, text)',
    'public.vardiya_kapatma_onayla(uuid)',
    'public.vardiya_kapatma_reddet(uuid, text)'
  ] loop
    if not has_function_privilege('authenticated', v_fn, 'execute') then
      raise exception '035: % icin authenticated yetkisi verilemedi', v_fn;
    end if;
    foreach v_rol in array array['anon', 'service_role'] loop
      if has_function_privilege(v_rol, v_fn, 'execute') then
        raise exception '035: % hala % rolune acik', v_fn, v_rol;
      end if;
    end loop;
  end loop;

  v_fn := 'public.notify_kisi(uuid, public.bildirim_tur, text, text, text)';
  foreach v_rol in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(v_rol, v_fn, 'execute') then
      raise exception '035: notify_kisi hala % rolune acik', v_rol;
    end if;
  end loop;
end
$do$;

commit;
