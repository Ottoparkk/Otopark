-- ============================================================================
-- 027  Ödemesiz çıkış ve sonradan tahsil
-- ============================================================================

begin;

-- Araç çıkabilsin ama para sonra alınsın. Kapanmış bilet iki durumda olur:
-- ödemesi alınmış, ya da alınmamış (borç). ARADA BİR DURUM YOK — kısmi ödeme
-- bilerek imkânsız: yarım tahsil edilmiş bir bilet, kasanın ne kadar eksik
-- olduğunu her raporda ayrı ayrı hesaplamak demektir.
--
-- Ciro tarafında hiçbir şey değişmiyor ve bu tesadüf değil: `rapor_ozet` ve
-- `gunluk_ozet` `biletler.tahsil_kurus`'u değil `tahsilatlar`'ı toplar.
-- Ödemesiz çıkış hiç tahsilat satırı yazmaz (ciroya girmez), sonradan alınan
-- para ise ALINDIĞI GÜN satır yazar — çıkış gününe değil. İkisi de doğru.

-- --------------------------------------------------------------- kısıt ----

-- 001'deki kimlik "tahsil = ücret − indirim" idi; ödemesiz çıkış bunu ihlal
-- eder. Gevşetilir ama açık bırakılmaz: ya tamamı alınmıştır ya hiçbiri.
alter table public.biletler drop constraint biletler_tahsil_ck;
alter table public.biletler add constraint biletler_tahsil_ck
  check (durum <> 'KAPALI'
         or tahsil_kurus = 0
         or tahsil_kurus = ucret_kurus - indirim_kurus);

-- --------------------------------------------------------------- guard ----

-- Gövde 002'den birebir; tek fark `app.bilet_tahsil` dalı.
--
-- `app.bilet_iptal`'in aksine bu bir muafiyet DEĞİL, dar bir izin: yalnızca
-- iki kolonun değişmesine göz yumar ve geri kalan her kolonu eski katı
-- karşılaştırmaya bırakır. Tam bypass verilseydi "sonradan tahsil" adı
-- altında kapanmış bir biletin ücreti, plakası, çıkış saati de değişebilirdi.
create or replace function public.biletler_immutable_guard() returns trigger
language plpgsql as $fn$
declare
  v_detach text[] := array[
    'park_yeri_id','vardiya_id','kapatan_vardiya_id','abonman_id',
    'giris_by','cikis_by','iptal_by',
    -- photo paths: nulled by the nightly retention purge, never money
    'giris_foto','cikis_foto'
  ];
  v_old jsonb := to_jsonb(old);
  v_new jsonb := to_jsonb(new);
  v_key text;
begin
  if old.durum = 'ACIK' then
    return new;
  end if;

  if coalesce(current_setting('app.bilet_iptal', true), '') = old.id::text then
    return new;
  end if;

  -- Sonradan tahsil: yalnızca bu iki kolon. Karşılaştırmadan çıkarılır,
  -- kalan her şey aşağıdaki eşitlik kontrolüne girer.
  if coalesce(current_setting('app.bilet_tahsil', true), '') = old.id::text then
    v_old := v_old - 'tahsil_kurus' - 'odeme_yontemi';
    v_new := v_new - 'tahsil_kurus' - 'odeme_yontemi';
  end if;

  foreach v_key in array v_detach loop
    -- Anything other than "this reference became NULL" is a real edit.
    if v_new -> v_key <> 'null'::jsonb and v_new -> v_key is distinct from v_old -> v_key then
      raise exception
        'Kapanmış bilet değiştirilemez (bilet %). Düzeltme için karşı kayıt girin.', old.id;
    end if;
    v_old := v_old - v_key;
    v_new := v_new - v_key;
  end loop;

  if v_old = v_new then
    return new;
  end if;

  raise exception
    'Kapanmış bilet değiştirilemez (bilet %). Düzeltme için karşı kayıt girin.', old.id;
end
$fn$;

-- ---------------------------------------------------------- bilet_kapat ----

-- Yeni parametre SONA eklendi ve varsayılanı `true`: mevcut çağrıların hepsi
-- (istemci, smoke test) hiç değişmeden aynı davranışı görür.
--
-- `create or replace` YETMEZ — parametre listesi değişince PostgreSQL eskisini
-- değiştirmez, yanına AŞIRI YÜKLEME ekler ve altı argümanlı çağrı sessizce
-- eski gövdeye gitmeye devam ederdi. Bu yüzden önce düşürülüyor; düşürme
-- ACL'i de sildiği için grant aşağıda yeniden veriliyor.
drop function if exists public.bilet_kapat(
  uuid, public.odeme_yontemi, integer, text, text, public.kaynak);

create or replace function public.bilet_kapat(
  p_bilet_id             uuid,
  p_odeme_yontemi        public.odeme_yontemi default null,
  p_ucret_override_kurus integer default null,
  p_sebep                text default null,
  p_foto                 text default null,
  p_kaynak               public.kaynak default 'MOBIL',
  -- false: araç çıkar, para alınmaz. Bilet borçlu kapanır.
  p_tahsil               boolean default true
) returns table (ucret_kurus integer, indirim_kurus integer, tahsil_kurus integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_b            public.biletler;
  v_cikis        timestamptz := now();
  v_hesaplanan   integer;
  v_ucret        integer;
  v_net          integer;
  v_tahsil       integer;
  v_yontem       public.odeme_yontemi;
  v_vardiya      uuid;
  v_degistirildi boolean := false;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  if p_kaynak = 'KAMERA' then
    raise exception 'Çıkış kaynağı KAMERA olamaz.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception 'Bu bilet zaten kapatılmış veya iptal edilmiş.';
  end if;

  if v_b.abonman_id is not null then
    v_hesaplanan := 0;
  else
    v_hesaplanan := public.ucret_hesapla(v_b.giris_at, v_cikis, v_b.tarife_id);
  end if;
  v_ucret := v_hesaplanan;

  if p_ucret_override_kurus is not null and p_ucret_override_kurus <> v_hesaplanan then
    if p_ucret_override_kurus < 0 then
      raise exception 'Ücret negatif olamaz.';
    end if;
    if coalesce(btrim(p_sebep), '') = '' then
      raise exception 'Ücret değişikliği için sebep zorunludur.';
    end if;
    v_ucret        := p_ucret_override_kurus;
    v_degistirildi := true;
  end if;

  if v_b.indirim_kurus > v_ucret then
    raise exception 'Kullanılan puan ücretten fazla. Önce puan kullanımını geri alın.';
  end if;

  v_net := v_ucret - v_b.indirim_kurus;

  if p_tahsil then
    if v_net > 0 and p_odeme_yontemi is null then
      raise exception 'Ödeme yöntemi zorunludur.';
    end if;
    v_tahsil := v_net;
    v_yontem := p_odeme_yontemi;
  else
    -- Sessizce yok saymak yerine reddediliyor: "ödemesiz çıkış" derken bir
    -- yöntem göndermek, çağıranın ne yaptığını bilmediğinin işaretidir.
    if p_odeme_yontemi is not null then
      raise exception 'Ödemesiz çıkışta ödeme yöntemi olmaz.';
    end if;
    v_tahsil := 0;
    v_yontem := null;
  end if;

  select v.id into v_vardiya from public.vardiyalar v
   where v.personel_id = auth.uid() and v.kapanis_at is null limit 1;

  update public.biletler set
    cikis_at           = v_cikis,
    ucret_kurus        = v_ucret,
    tahsil_kurus       = v_tahsil,
    odeme_yontemi      = v_yontem,
    durum              = 'KAPALI',
    cikis_by           = auth.uid(),
    cikis_kaynak       = p_kaynak,
    cikis_foto         = coalesce(p_foto, v_b.cikis_foto),
    kapatan_vardiya_id = v_vardiya,
    ucret_degistirildi = v_degistirildi,
    ucret_sebep        = case when v_degistirildi then btrim(p_sebep) else v_b.ucret_sebep end
  where id = p_bilet_id;

  -- The cash belongs to whoever was on the till at exit, not at entry.
  if v_tahsil > 0 then
    insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, created_by)
    values ('BILET', p_bilet_id, v_tahsil, v_yontem, v_vardiya, auth.uid());
  end if;

  -- Denetime yazılır, bildirim GÖNDERİLMEZ: bu akış Yönetici'nin kendi
  -- istediği bir yol, ve rutin bir işlem için her seferinde bildirim atmak
  -- bildirimleri okunmaz hâle getirir. İz denetim kaydında duruyor.
  if not p_tahsil and v_net > 0 then
    perform public.audit('bilet_odemesiz_cikis', 'biletler', p_bilet_id,
      jsonb_build_object('plaka', v_b.plaka, 'borc', v_net));
  end if;

  if v_degistirildi then
    perform public.audit('bilet_ucret_degisikligi', 'biletler', p_bilet_id,
      jsonb_build_object('hesaplanan', v_hesaplanan, 'uygulanan', v_ucret,
                         'sebep', btrim(p_sebep), 'plaka', v_b.plaka));
    perform public.notify_yonetici('UCRET_DEGISIKLIGI', 'Ücret değiştirildi',
      v_b.plaka || ' — hesaplanan ' || (v_hesaplanan / 100.0)::numeric(12,2)
        || ' ₺, uygulanan ' || (v_ucret / 100.0)::numeric(12,2) || ' ₺',
      '/gise/bilet/' || p_bilet_id);
  end if;

  return query select v_ucret, v_b.indirim_kurus, v_tahsil;
end
$fn$;

-- --------------------------------------------------------- bilet_tahsil ----

-- Ödemesiz çıkmış bir biletin parasını sonradan alır.
--
-- Kapanış bilgilerine DOKUNMAZ: `kapatan_vardiya_id` çıkışı yapan vardiyada
-- kalır, çünkü o kayıt aracın ne zaman çıktığını anlatır. Para ise tahsilat
-- satırının vardiyasına yazılır — yani nakdi kim aldıysa onun sayımına girer.
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

  v_net := v_b.ucret_kurus - v_b.indirim_kurus;
  if v_net <= 0 then
    raise exception 'Bu bilette tahsil edilecek ücret yok.';
  end if;
  if v_b.tahsil_kurus <> 0 then
    raise exception 'Bu biletin ödemesi zaten alınmış.';
  end if;

  -- Bileti kilitledik, ama tahsilat satırı ayrı bir tablo: kasada karşılığı
  -- olmayan ikinci bir satır doğmasın.
  if exists (select 1 from public.tahsilatlar t
              where t.bilet_id = p_bilet_id
                and t.iptal_of is null
                and t.durum <> 'REDDEDILDI') then
    raise exception 'Bu bilet için zaten bir tahsilat kaydı var.';
  end if;

  select v.id into v_vardiya from public.vardiyalar v
   where v.personel_id = auth.uid() and v.kapanis_at is null limit 1;

  -- Bayrak işlem-yereldir ve HEMEN temizlenir: açık bırakılırsa aynı işlem
  -- içindeki başka bir bilet güncellemesi de sessizce muafiyetten yararlanır.
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

-- -------------------------------------------------------------- grants ----

-- bilet_kapat düşürüldüğü için yetkisi de düştü; yeniden veriliyor.
revoke all on function public.bilet_kapat(
  uuid, public.odeme_yontemi, integer, text, text, public.kaynak, boolean)
  from public, anon, service_role;
grant execute on function public.bilet_kapat(
  uuid, public.odeme_yontemi, integer, text, text, public.kaynak, boolean) to authenticated;

revoke all on function public.bilet_tahsil(uuid, public.odeme_yontemi)
  from public, anon, service_role;
grant execute on function public.bilet_tahsil(uuid, public.odeme_yontemi) to authenticated;

-- -------------------------------------------------------------- verify ---
do $do$
begin
  -- Eski imza gerçekten gitti mi? Kalsaydı istemcinin 6 argümanlı çağrısı
  -- eski gövdeye düşer ve ödemesiz çıkış hiç çalışmazdı.
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'bilet_kapat'
                and pg_get_function_identity_arguments(p.oid) not like '%boolean%') then
    raise exception '027: bilet_kapat''ın eski imzası duruyor — aşırı yükleme oluştu';
  end if;

  if not has_function_privilege('authenticated',
        'public.bilet_kapat(uuid, public.odeme_yontemi, integer, text, text,'
        ' public.kaynak, boolean)', 'execute')
     or not has_function_privilege('authenticated',
        'public.bilet_tahsil(uuid, public.odeme_yontemi)', 'execute') then
    raise exception '027: RPC yetkileri verilmedi';
  end if;
  if has_function_privilege('anon', 'public.bilet_tahsil(uuid, public.odeme_yontemi)', 'execute') then
    raise exception '027: bilet_tahsil anon rolüne açık';
  end if;

  -- Kısıt hâlâ kısmi ödemeyi reddetmeli.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.biletler'::regclass
                    and conname = 'biletler_tahsil_ck') then
    raise exception '027: tahsil kısıtı kurulmadı';
  end if;
end
$do$;

commit;
