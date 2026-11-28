-- =====================================================================
-- 082  Süre aşımı onayı
-- =====================================================================
-- Sahibin isteği (27.11.2026): normal bilet ilk kademenin fiyatını (bugün
-- 200 ₺) geçmez. Araç daha uzun kaldıysa bilet bir rapor gösterir — ne
-- kadar kaldı, tarifeye göre ne tutar — ve bir kişi karar verir:
--
--   * "Onayla"            → tarifenin tam fiyatı (asim_karar = 'TAM').
--   * "İlk kademe kalsın" → ilk kademenin fiyatı (asim_karar = 'ILK').
--
--   * Yalnızca KADEMELİ tarifede: "ilk kademe" = kademeler[0]. Süreli ve
--     sabit tarife değişmez. Tavan tarifenin ekranını izler.
--   * Abonman (0) ve anlaşmalı bilet (080, fiyatı zaten bir kişi koydu)
--     etkilenmez. Yıkama (078) her zaman üstüne eklenir.
--   * Personel ve Yönetici karar verir; bir kez. Yönetici her iki kararda
--     haberdar (SURE_ASIMI, 081).
--   * Karar verilmeden kişi çıkış yaptıramaz (bilet_kapat, ödemeli ya da
--     ödemesiz) ve ödeme toplayamaz (bilet_tahsil). Elle ücret (sebepli)
--     ve ücretsiz çıkış kendileri bir karardır.
--   * Kamera karar veremez: bileti ilk kademe fiyatıyla ödemesiz kapatır
--     (054). Ödeme toplanmadan önce karar verilir; kapanmış bilette karar
--     yalnızca ücreti ve karar izini değiştirir (app.bilet_asim istisnası,
--     066'nın app.bilet_ucretsiz deseni) — kendi vardiyası ya da Yönetici,
--     ödeme alınmamışken.
--
-- 080 ve 081 önce koşulmuş olmalı. Smoke test: PASS 108–111.
-- Not: 074 hiç koşulmadı; koruma (biletler_immutable_guard) burada 066'nın
-- koşulmuş sürümünden yeniden yazılır.

begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'biletler'
                    and column_name = 'anlasma_kurus') then
    raise exception '082: 080 koşulmamış — anlasma_kurus yok';
  end if;
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'bildirim_tur' and e.enumlabel = 'SURE_ASIMI') then
    raise exception '082: 081 koşulmamış — SURE_ASIMI yok';
  end if;
end $$;

-- ------------------------------------------------------------- sütunlar ---
alter table public.biletler
  add column if not exists asim_karar text,
  add column if not exists asim_karar_by uuid references public.profiles(id) on delete set null,
  add column if not exists asim_karar_at timestamptz;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'biletler_asim_karar_ck') then
    alter table public.biletler
      add constraint biletler_asim_karar_ck
      check (asim_karar is null or asim_karar in ('TAM', 'ILK'));
  end if;
end $$;

-- ------------------------------------------------------ ilk kademe --------
-- Kademeli tarifenin ilk kademesinin fiyatı; başka tarifede null (tavan yok).
create or replace function public.ilk_kademe_kurus(p_tarife_id uuid)
returns integer
language sql stable set search_path = public as $$
  select case when t.tur::text = 'KADEMELI'
              then (t.kademeler -> 0 ->> 'kurus')::integer end
    from public.tarifeler t
   where t.id = p_tarife_id;
$$;

-- ------------------------------------------------------- bilet_ucreti -----
-- 080'in gövdesi birebir; yalnızca son dal: karar 'TAM' değilse tarifenin
-- fiyatı ilk kademede durur. `least` null'u yok sayar: kademesiz tarife
-- olduğu gibi kalır.
create or replace function public.bilet_ucreti(p_b public.biletler, p_cikis timestamptz)
returns integer
language sql stable set search_path = public as $$
  select (case
            when p_b.abonman_id is not null then 0
            when p_b.anlasma_kurus is not null then
              p_b.anlasma_kurus
              + case when p_b.anlasma_fazla_at is not null
                     then public.ucret_hesapla(p_b.anlasma_bitis,
                                               greatest(p_cikis, p_b.anlasma_bitis),
                                               p_b.tarife_id)
                     else 0 end
            when p_b.asim_karar = 'TAM' then
              public.ucret_hesapla(p_b.giris_at, p_cikis, p_b.tarife_id)
            else
              least(public.ucret_hesapla(p_b.giris_at, p_cikis, p_b.tarife_id),
                    public.ilk_kademe_kurus(p_b.tarife_id))
          end)
         + coalesce(p_b.yikama_kurus, 0);
$$;

-- ------------------------------------------------ karar bekliyor mu? ------
-- Tek yerde: çıkış, tahsil ve İçeride listesi aynı soruyu sorar. Elle ücret
-- (ucret_degistirildi) ve ücretsiz çıkış kendileri bir karardır.
create or replace function public.bilet_asim_bekliyor(p_b public.biletler, p_cikis timestamptz)
returns boolean
language sql stable set search_path = public as $$
  select p_b.abonman_id is null
     and p_b.anlasma_kurus is null
     and p_b.asim_karar is null
     and p_b.ucretsiz_sebep is null
     and not coalesce(p_b.ucret_degistirildi, false)
     and coalesce(public.ucret_hesapla(p_b.giris_at, p_cikis, p_b.tarife_id)
                  > public.ilk_kademe_kurus(p_b.tarife_id), false);
$$;

-- ------------------------------------------------------------ rapor -------
-- İlk kademe ve tarifenin tam fiyatı (yalnızca otopark; yıkama ayrı satır).
-- Aşım yoksa satır dönmez. Kapanmış bilet: yalnızca kararı verebilecek
-- olana (kendi vardiyası ya da Yönetici).
create or replace function public.bilet_asim_onizle(p_bilet_id uuid)
returns table (ilk_kurus integer, tam_kurus integer)
language plpgsql stable security definer set search_path = public as $$
declare
  v_b   public.biletler;
  v_ilk integer;
  v_tam integer;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  select * into v_b from public.biletler where id = p_bilet_id;
  if not found or v_b.durum = 'IPTAL'
     or v_b.abonman_id is not null or v_b.anlasma_kurus is not null then
    return;
  end if;
  if v_b.durum <> 'ACIK'
     and not (public.is_yonetici()
              or coalesce(v_b.kapatan_vardiya_id = public.acik_vardiyam(), false)) then
    return;
  end if;
  v_ilk := public.ilk_kademe_kurus(v_b.tarife_id);
  if v_ilk is null then
    return;
  end if;
  v_tam := public.ucret_hesapla(v_b.giris_at, coalesce(v_b.cikis_at, now()), v_b.tarife_id);
  if v_tam <= v_ilk then
    return;
  end if;
  return query select v_ilk, v_tam;
end $$;

-- ------------------------------------------------------------ karar -------
-- p_tam: true "Onayla" (tam fiyat), false "İlk kademe kalsın". Bir kez.
create or replace function public.bilet_asim_karar(p_bilet_id uuid, p_tam boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_b     public.biletler;
  v_yeni  public.biletler;
  v_cikis timestamptz;
  v_ilk   integer;
  v_tam   integer;
  v_karar text;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_tam is null then
    raise exception 'Karar seçin.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum = 'IPTAL' then
    raise exception 'Bilet iptal edilmiş.';
  end if;
  if v_b.asim_karar is not null then
    raise exception 'Bu bilet için karar zaten verildi.';
  end if;

  v_cikis := case when v_b.durum = 'ACIK' then now() else v_b.cikis_at end;
  if not public.bilet_asim_bekliyor(v_b, v_cikis) then
    raise exception 'Bu bilette süre aşımı yok.';
  end if;
  v_ilk := public.ilk_kademe_kurus(v_b.tarife_id);
  v_tam := public.ucret_hesapla(v_b.giris_at, v_cikis, v_b.tarife_id);
  v_karar := case when p_tam then 'TAM' else 'ILK' end;

  if v_b.durum = 'ACIK' then
    update public.biletler
       set asim_karar = v_karar, asim_karar_by = auth.uid(), asim_karar_at = now()
     where id = p_bilet_id;
  else
    -- Kapanmış (kameranın ödemesiz kapattığı) bilet: 066'nın kuralı.
    if not (public.is_yonetici()
            or coalesce(v_b.kapatan_vardiya_id = public.acik_vardiyam(), false)) then
      raise exception 'Bu bilete karar verme yetkiniz yok.';
    end if;
    if v_b.tahsil_kurus <> 0
       or exists (select 1 from public.tahsilatlar t
                   where t.bilet_id = p_bilet_id
                     and t.iptal_of is null
                     and t.durum <> 'REDDEDILDI') then
      raise exception 'Bu biletin ödemesi zaten alınmış.';
    end if;

    v_yeni := v_b;
    v_yeni.asim_karar := v_karar;
    perform set_config('app.bilet_asim', p_bilet_id::text, true);
    update public.biletler
       set asim_karar    = v_karar,
           asim_karar_by = auth.uid(),
           asim_karar_at = now(),
           ucret_kurus   = public.bilet_ucreti(v_yeni, v_b.cikis_at)
     where id = p_bilet_id;
    perform set_config('app.bilet_asim', '', true);
  end if;

  perform public.audit('bilet_asim_karar', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'karar', v_karar, 'ilk', v_ilk, 'tam', v_tam));
  perform public.notify_yonetici('SURE_ASIMI', 'Süre aşımı',
    v_b.plaka || case when p_tam
      then ': tam ücret onaylandı — ' || (v_tam / 100.0)::numeric(12,2) || ' ₺'
      else ': ilk kademe ücreti bırakıldı — ' || (v_ilk / 100.0)::numeric(12,2)
           || ' ₺ (tarife ' || (v_tam / 100.0)::numeric(12,2) || ' ₺)' end,
    '/gise/bilet/' || p_bilet_id);
end $$;

-- ------------------------------------------- koruma (066'dan) -------------
create or replace function public.biletler_immutable_guard() returns trigger
language plpgsql as $fn$
declare
  v_detach text[] := array[
    'park_yeri_id','vardiya_id','kapatan_vardiya_id','abonman_id',
    'giris_by','cikis_by','iptal_by',
    -- 066: ücretsiz çıkışı veren; profil silinirse `on delete set null`
    'ucretsiz_by',
    -- 082: aşım kararını veren
    'asim_karar_by',
    -- photo paths: nulled by the nightly retention purge, never money
    'giris_foto','cikis_foto',
    -- okuma kaydı silinirse referans düşer; para değil
    'plaka_okuma_id'
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

  -- 054: "Araç çıkmadı" — kameranın kapattığı, parası alınmamış bilet.
  if coalesce(current_setting('app.bilet_geri_ac', true), '') = old.id::text then
    return new;
  end if;

  if coalesce(current_setting('app.bilet_tahsil', true), '') = old.id::text then
    v_old := v_old - 'tahsil_kurus' - 'odeme_yontemi';
    v_new := v_new - 'tahsil_kurus' - 'odeme_yontemi';
  end if;

  -- 066: sonradan ücretsiz çıkış — yalnızca ücret ve ücretsiz çıkış izi
  -- değişebilir (koşulları `bilet_ucretsiz_cikis` denetler, app.bilet_tahsil
  -- gibi). Tahsil, yöntem, çıkış bilgileri ve geri kalan her şey değişmez.
  if coalesce(current_setting('app.bilet_ucretsiz', true), '') = old.id::text then
    v_old := v_old - 'ucret_kurus' - 'ucret_degistirildi' - 'ucret_sebep'
                   - 'ucretsiz_sebep' - 'ucretsiz_not' - 'ucretsiz_by' - 'ucretsiz_at';
    v_new := v_new - 'ucret_kurus' - 'ucret_degistirildi' - 'ucret_sebep'
                   - 'ucretsiz_sebep' - 'ucretsiz_not' - 'ucretsiz_by' - 'ucretsiz_at';
  end if;

  -- 082: kapanmış bilette süre aşımı kararı — yalnızca ücret ve karar izi
  -- (koşulları bilet_asim_karar denetler: ödeme alınmamış, kendi vardiyası).
  if coalesce(current_setting('app.bilet_asim', true), '') = old.id::text then
    v_old := v_old - 'ucret_kurus' - 'asim_karar' - 'asim_karar_by' - 'asim_karar_at';
    v_new := v_new - 'ucret_kurus' - 'asim_karar' - 'asim_karar_by' - 'asim_karar_at';
  end if;

  -- 054: kameranın kapattığı biletin çıkış fotoğrafı — yalnızca boşken.
  if coalesce(current_setting('app.kamera_foto', true), '') = old.id::text
     and old.cikis_foto is null then
    v_old := v_old - 'cikis_foto';
    v_new := v_new - 'cikis_foto';
  end if;

  foreach v_key in array v_detach loop
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

-- ------------------------------------------------ bilet_kapat (078) -------
-- 078'in gövdesi birebir + tek denetim: aşım bekliyorsa (elle ücret yoksa)
-- çıkış yok. Aynı imza: yetkiler kalır.
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

  -- 082: ilk kademe aşıldıysa önce bir kişi karar verir. Elle ücret bir karardır.
  if p_ucret_override_kurus is null and public.bilet_asim_bekliyor(v_b, v_cikis) then
    raise exception 'Süre aşımı: önce karar verin.';
  end if;

  -- 078: otopark (abonmanda 0) + oto yıkama, tek yerden.
  v_hesaplanan := public.bilet_ucreti(v_b, v_cikis);
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

  v_vardiya := public.acik_vardiyam();

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

-- ------------------------------------------------ bilet_tahsil (034) ------
-- 034'ün gövdesi birebir + tek denetim: kameranın kapattığı bilette aşım
-- bekliyorsa ödeme toplanmaz. Aynı imza: yetkiler kalır.
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

  -- 082: kamera ilk kademe fiyatıyla kapattı; aşım varsa önce karar.
  if public.bilet_asim_bekliyor(v_b, v_b.cikis_at) then
    raise exception 'Süre aşımı: önce karar verin.';
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

-- ----------------------------------------------- acik_bilet_ara (080) ----
-- 080'in gövdesi birebir + `asim_bekliyor` (İçeride kartındaki "Süre aşımı"
-- etiketi). Dönüş tipi değiştiği için düşürülür.
drop function if exists public.acik_bilet_ara(text);

create function public.acik_bilet_ara(p_q text default null)
returns table (
  id uuid, plaka text, giris_at timestamptz,
  abonman_id uuid, park_yeri_id uuid, cikis_bekliyor_at timestamptz,
  indirim_kurus integer, puan_kullanilan integer, tarife_id uuid,
  gecikmeli_kayit boolean,
  notu_var boolean, ucret_kurus integer,
  plaka_supheli boolean,
  giris_by uuid, giris_kaynak public.kaynak,
  iptal_talebi boolean,
  iceride_goruldu_at timestamptz,                                  -- 077
  yikama_kurus integer,                                            -- 078
  anlasma_bitis timestamptz,                                       -- 080
  anlasma_fazla_at timestamptz,                                    -- 080
  asim_bekliyor boolean                                            -- 082
)
language plpgsql stable security definer set search_path = public as $fn$
declare v_q text := public.normalize_plaka(p_q);
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  return query
  select b.id, b.plaka, b.giris_at,
         b.abonman_id, b.park_yeri_id, b.cikis_bekliyor_at,
         b.indirim_kurus, b.puan_kullanilan, b.tarife_id, b.gecikmeli_kayit,
         (b.notlar is not null),
         public.bilet_ucreti(b, now()),                            -- 078
         b.plaka_supheli,
         b.giris_by, b.giris_kaynak,
         (b.iptal_talebi_at is not null),
         b.iceride_goruldu_at,
         b.yikama_kurus,
         b.anlasma_bitis,
         b.anlasma_fazla_at,
         public.bilet_asim_bekliyor(b, now())                      -- 082
    from public.biletler b
   where b.durum = 'ACIK'
     and (v_q = '' or b.plaka like '%' || v_q || '%'
                   or (length(v_q) >= 3 and right(b.plaka, length(v_q)) = v_q))
   order by
     case when v_q = '' then 2
          when b.plaka = v_q then 0
          when b.plaka like v_q || '%' then 1
          else 2 end,
     b.giris_at desc
   -- Aramasız: hepsi. Yazılı arama: en çok 50.
   limit case when v_q = '' then null else 50 end;
end $fn$;

-- --------------------------------------------- bildirim_yonetici_turu -----
-- Gövde 065'ten BİREBİR; listeye 'SURE_ASIMI' eklendi (Yönetici'ye özel).
create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $fn$
  select p_tur::text in (
    'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA',
    'KAMERA_HAREKET','VARDIYA_ACIK','ONAY_BEKLIYOR','PLAKA_SUPHE',
    'VARDIYA_KAPATMA','BILET_IPTAL_TALEBI','KAMERA_GERI_ACILDI',
    'KAMERA_GUNLUK','YENI_ABONMAN','UCRETSIZ_CIKIS','SURE_ASIMI'
  );
$fn$;

-- ---------------------------------------------------------------- yetki ---
revoke all on function public.ilk_kademe_kurus(uuid) from public;
revoke all on function public.ilk_kademe_kurus(uuid) from anon, authenticated, service_role;

revoke all on function public.bilet_asim_bekliyor(public.biletler, timestamptz) from public;
revoke all on function public.bilet_asim_bekliyor(public.biletler, timestamptz)
  from anon, authenticated, service_role;

revoke all on function public.bilet_asim_onizle(uuid) from public;
revoke all on function public.bilet_asim_onizle(uuid) from anon, authenticated, service_role;
grant execute on function public.bilet_asim_onizle(uuid) to authenticated;

revoke all on function public.bilet_asim_karar(uuid, boolean) from public;
revoke all on function public.bilet_asim_karar(uuid, boolean) from anon, authenticated, service_role;
grant execute on function public.bilet_asim_karar(uuid, boolean) to authenticated;

revoke all on function public.acik_bilet_ara(text) from public;
revoke all on function public.acik_bilet_ara(text) from anon, authenticated, service_role;
grant execute on function public.acik_bilet_ara(text) to authenticated;

do $$
declare
  f text;
begin
  foreach f in array array['public.bilet_asim_onizle(uuid)',
                           'public.bilet_asim_karar(uuid, boolean)',
                           'public.acik_bilet_ara(text)',
                           'public.bilet_kapat(uuid, public.odeme_yontemi, integer, text, text, public.kaynak, boolean)',
                           'public.bilet_tahsil(uuid, public.odeme_yontemi)'] loop
    if not has_function_privilege('authenticated', f, 'execute')
       or has_function_privilege('anon', f, 'execute')
       or has_function_privilege('service_role', f, 'execute') then
      raise exception '082: % yalnızca authenticated için olmalı', f;
    end if;
  end loop;
  foreach f in array array['public.ilk_kademe_kurus(uuid)',
                           'public.bilet_asim_bekliyor(public.biletler, timestamptz)',
                           'public.bilet_ucreti(public.biletler, timestamptz)'] loop
    if has_function_privilege('authenticated', f, 'execute')
       or has_function_privilege('anon', f, 'execute')
       or has_function_privilege('service_role', f, 'execute') then
      raise exception '082: % kimseye açık olmamalı', f;
    end if;
  end loop;
end $$;

commit;
