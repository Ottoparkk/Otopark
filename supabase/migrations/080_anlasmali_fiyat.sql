-- =====================================================================
-- 080  Anlaşmalı fiyat
-- =====================================================================
-- Sahibin isteği (27.11.2026): bazı müşterilerle belirli bir süre için sabit
-- fiyata anlaşılır ("3 gün 600 ₺", saatlik de olabilir).
--
--   * Personel ve Yönetici kurar; kurulunca / değişince Yönetici haberdar.
--   * Süre aracın GİRİŞİNDEN sayılır: bitiş = giriş + saat.
--   * Süre içinde ücret = anlaşma fiyatı (+ yıkama, 078).
--   * Süre dolunca tarife yine sayar ama ücrete KENDİLİĞİNDEN EKLENMEZ:
--     personel "Fazla süreyi ekle"ye basar (bilet_anlasma_fazla). Basınca
--     fazla süre, anlaşmanın bitişinden çıkışa kadar normal tarifeyle,
--     yeni bir kalış gibi fiyatlanır ve çıkışa kadar saymaya devam eder.
--   * Süre dolunca bir kez herkese bildirim: "<plaka>: anlaşma süresi doldu"
--     (her dakika çalışan iş, 045 deseni).
--   * Abonmanlı araca anlaşma kurulmaz. Süre 1 saat – 90 gün.
--   * Anlaşmayı değiştirmek "fazla süre eklendi" ve "bildirim gitti"
--     işaretlerini sıfırlar (yeni anlaşma, yeni süre).
--   * Puan yalnızca otopark kısmını öder: anlaşma fiyatı (+ eklenen fazla
--     süre); yıkama puanla ödenmez (078 ile aynı kural).
-- 079 (ANLASMA bildirim türü) ve 078 önce koşulmuş olmalı.
-- Smoke test: PASS 104–107.

begin;

do $$
begin
  if to_regprocedure('public.bilet_ucreti(public.biletler, timestamptz)') is null then
    raise exception '080: 078 koşulmamış — bilet_ucreti yok';
  end if;
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'bildirim_tur' and e.enumlabel = 'ANLASMA') then
    raise exception '080: 079 koşulmamış — ANLASMA yok';
  end if;
end $$;

-- ------------------------------------------------------------- sütunlar ---
alter table public.biletler
  add column if not exists anlasma_kurus integer
    check (anlasma_kurus is null or anlasma_kurus > 0),
  add column if not exists anlasma_bitis timestamptz,
  add column if not exists anlasma_fazla_at timestamptz,      -- "Fazla süreyi ekle"
  add column if not exists anlasma_bildirim_at timestamptz;   -- süre doldu bildirimi

-- Her dakikalık iş yalnızca bildirimi bekleyen açık anlaşmalara bakar.
create index if not exists biletler_anlasma_bekleyen_ix
  on public.biletler (anlasma_bitis)
  where durum = 'ACIK' and anlasma_bitis is not null and anlasma_bildirim_at is null;

-- ------------------------------------------------------- tek fiyat yeri ---
-- 078'in fonksiyonu; aynı imza (yetkiler korunur: kimseye açık değil).
-- bilet_kapat, kamera_cikis_bildir, bilet_ucretsiz_cikis, bilet_ucret_onizle
-- ve acik_bilet_ara bunu çağırdığı için anlaşmayı kendiliğinden bilir.
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
            else public.ucret_hesapla(p_b.giris_at, p_cikis, p_b.tarife_id)
          end)
         + coalesce(p_b.yikama_kurus, 0);
$$;

-- ------------------------------------------------- anlaşma kur / kaldır ---
-- p_kurus null → kaldır. Kullanılmış puan yeni ücretten fazlaysa reddedilir
-- (bilet_yikama'nın kuralı).
create or replace function public.bilet_anlasma(p_bilet_id uuid, p_kurus integer, p_saat integer)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_b    public.biletler;
  v_yeni public.biletler;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception 'Bilet açık değil; anlaşma yalnızca araç içerideyken değiştirilebilir.';
  end if;
  if v_b.abonman_id is not null then
    raise exception 'Abonmanlı araca anlaşmalı fiyat gerekmez.';
  end if;

  v_yeni := v_b;
  if p_kurus is null then
    if v_b.anlasma_kurus is null then
      return;
    end if;
    v_yeni.anlasma_kurus := null;
    v_yeni.anlasma_bitis := null;
  else
    if p_kurus <= 0 then
      raise exception 'Anlaşma fiyatı sıfırdan büyük olmalı.';
    end if;
    if p_saat is null or p_saat < 1 or p_saat > 2160 then
      raise exception 'Anlaşma süresi 1 saat ile 90 gün arasında olmalı.';
    end if;
    v_yeni.anlasma_kurus := p_kurus;
    v_yeni.anlasma_bitis := v_b.giris_at + make_interval(hours => p_saat);
  end if;
  v_yeni.anlasma_fazla_at := null;
  v_yeni.anlasma_bildirim_at := null;

  if v_b.indirim_kurus > public.bilet_ucreti(v_yeni, now()) then
    raise exception 'Kullanılan puan ücretten fazla. Önce puan kullanımını geri alın.';
  end if;

  update public.biletler
     set anlasma_kurus = v_yeni.anlasma_kurus,
         anlasma_bitis = v_yeni.anlasma_bitis,
         anlasma_fazla_at = null,
         anlasma_bildirim_at = null
   where id = p_bilet_id;

  perform public.audit('bilet_anlasma', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'kurus', p_kurus, 'saat', p_saat,
                       'onceki_kurus', v_b.anlasma_kurus, 'onceki_bitis', v_b.anlasma_bitis));

  if p_kurus is not null then
    perform public.notify_yonetici('ANLASMA', 'Anlaşmalı fiyat',
      v_b.plaka || ' — ' || (p_kurus / 100.0)::numeric(12,2) || ' ₺, '
        || to_char(v_yeni.anlasma_bitis at time zone 'Europe/Istanbul', 'DD.MM HH24:MI')
        || '''e kadar',
      '/gise/bilet/' || p_bilet_id);
  end if;
end $$;

-- ------------------------------------------------- fazla süreyi ekle ------
-- Yalnızca süre dolduktan sonra; ikinci basış bir şey değiştirmez.
create or replace function public.bilet_anlasma_fazla(p_bilet_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_b public.biletler;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception 'Bilet açık değil.';
  end if;
  if v_b.anlasma_kurus is null then
    raise exception 'Bu bilette anlaşma yok.';
  end if;
  if v_b.anlasma_bitis > now() then
    raise exception 'Anlaşma süresi henüz dolmadı.';
  end if;
  if v_b.anlasma_fazla_at is not null then
    return;
  end if;

  update public.biletler set anlasma_fazla_at = now() where id = p_bilet_id;

  perform public.audit('bilet_anlasma_fazla', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'bitis', v_b.anlasma_bitis,
                       'kurus', public.ucret_hesapla(v_b.anlasma_bitis, now(), v_b.tarife_id)));
end $$;

-- ------------------------------------------- fazla süre önizlemesi --------
-- Düğmenin üstündeki tutar. Süre dolmamışsa 0; açık olmayan bilet null.
create or replace function public.bilet_fazla_onizle(p_bilet_id uuid)
returns integer
language plpgsql stable security definer set search_path = public as $$
declare
  v_b public.biletler;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  select * into v_b from public.biletler where id = p_bilet_id;
  if not found or v_b.durum <> 'ACIK' then
    return null;
  end if;
  if v_b.anlasma_kurus is null or v_b.anlasma_bitis > now() then
    return 0;
  end if;
  return public.ucret_hesapla(v_b.anlasma_bitis, now(), v_b.tarife_id);
end $$;

-- ------------------------------------------------------ puan_kullan (002) --
-- 002'nin gövdesi birebir; yalnızca tavan: tarife yerine bilet_ucreti'nin
-- otopark kısmı (anlaşmalı bilette anlaşma fiyatı). Aynı imza: yetkiler kalır.
create or replace function public.puan_kullan(p_bilet_id uuid, p_puan integer)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_b        public.biletler;
  v_kural    public.puan_kurallari;
  v_hesap    uuid;
  v_bakiye   integer;
  v_ucret    integer;
  v_max_puan integer;
  v_indirim  integer;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_puan is null or p_puan <= 0 then
    raise exception 'Kullanılacak puan sıfırdan büyük olmalı.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception 'Kapanmış bilette puan kullanılamaz.';
  end if;
  if v_b.abonman_id is not null then
    raise exception 'Abonman girişinde puan kullanılamaz.';
  end if;
  if v_b.indirim_kurus > 0 then
    raise exception 'Bu bilette zaten puan kullanılmış.';
  end if;

  select * into v_kural from public.puan_kurallari where gecerli_bitis is null;
  if not found or v_kural.kurus_per_puan = 0 then
    raise exception 'Aktif puan kuralı tanımlı değil.';
  end if;

  select h.id into v_hesap
    from public.hesaplar h
    join public.hesap_araclari ha on ha.hesap_id = h.id
   where ha.plaka = v_b.plaka and h.durum = 'AKTIF';
  if not found then
    raise exception 'Bu plakaya bağlı aktif puan hesabı yok.';
  end if;

  perform pg_advisory_xact_lock(hashtext('puan:' || v_b.plaka));

  select coalesce(sum(ph.puan), 0)::integer into v_bakiye
    from public.puan_hareketleri ph where ph.hesap_id = v_hesap;
  if p_puan > v_bakiye then
    raise exception 'Yetersiz puan. Bakiye: %', v_bakiye;
  end if;

  v_ucret := public.bilet_ucreti(v_b, now()) - coalesce(v_b.yikama_kurus, 0);   -- 080
  if v_ucret <= 0 then
    raise exception 'Ücretsiz çıkışta puan kullanılamaz.';
  end if;

  -- Integer division floors, so the discount can never round above the fee.
  v_max_puan := v_ucret / v_kural.kurus_per_puan;
  if p_puan > v_max_puan then
    raise exception 'Bu bilet için en fazla % puan kullanılabilir.', v_max_puan;
  end if;

  v_indirim := p_puan * v_kural.kurus_per_puan;

  insert into public.puan_hareketleri (hesap_id, tur, puan, bilet_id, kural_id, created_by, aciklama)
  values (v_hesap, 'KULLANIM', -p_puan, p_bilet_id, v_kural.id, auth.uid(), 'Çıkışta kullanıldı');

  update public.biletler
     set indirim_kurus = v_indirim, puan_kullanilan = p_puan
   where id = p_bilet_id;

  perform public.audit('puan_kullan', 'biletler', p_bilet_id,
    jsonb_build_object('puan', p_puan, 'kurus', v_indirim, 'plaka', v_b.plaka));
  perform public.notify_yonetici('PUAN_KULLANIM', 'Puan kullanıldı',
    v_b.plaka || ' — ' || p_puan || ' puan', '/yonetim/hesaplar');

  return v_indirim;
end $$;

-- ----------------------------------------------- acik_bilet_ara (078) ----
-- 078'in gövdesi birebir + `anlasma_bitis`, `anlasma_fazla_at` (İçeride
-- kartındaki "Anlaşma bitti" uyarısı). Dönüş tipi değiştiği için düşürülür.
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
  anlasma_fazla_at timestamptz                                     -- 080
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
         b.anlasma_fazla_at
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

-- ------------------------------------------------ süre doldu bildirimi ----
-- 045 deseni: her dakika; `try` kilidi üst üste binen çalışmayı atlatır,
-- `skip locked` iki çalışmanın aynı satıra dokunmasını engeller. Her bilet
-- bir kez: bildirim gidince işaretlenir. Cron'da auth.uid() boş → herkese.
create or replace function public.anlasma_bildirim_gonder() returns void
language plpgsql security definer set search_path = public as $fn$
declare
  r record;
begin
  if not pg_try_advisory_xact_lock(hashtext('anlasma_bildirim_gonder')) then
    return;
  end if;
  for r in
    select b.id, b.plaka
      from public.biletler b
     where b.durum = 'ACIK'
       and b.anlasma_bitis is not null
       and b.anlasma_bitis <= now()
       and b.anlasma_bildirim_at is null
     order by b.anlasma_bitis
     for update skip locked
  loop
    perform public.notify_herkes('ANLASMA', 'Anlaşma süresi doldu',
      r.plaka || ': anlaşma süresi doldu', '/gise/bilet/' || r.id);
    update public.biletler set anlasma_bildirim_at = now() where id = r.id;
  end loop;
end
$fn$;

-- ---------------------------------------------------------------- yetki ---
revoke all on function public.bilet_anlasma(uuid, integer, integer) from public;
revoke all on function public.bilet_anlasma(uuid, integer, integer) from anon, authenticated, service_role;
grant execute on function public.bilet_anlasma(uuid, integer, integer) to authenticated;

revoke all on function public.bilet_anlasma_fazla(uuid) from public;
revoke all on function public.bilet_anlasma_fazla(uuid) from anon, authenticated, service_role;
grant execute on function public.bilet_anlasma_fazla(uuid) to authenticated;

revoke all on function public.bilet_fazla_onizle(uuid) from public;
revoke all on function public.bilet_fazla_onizle(uuid) from anon, authenticated, service_role;
grant execute on function public.bilet_fazla_onizle(uuid) to authenticated;

revoke all on function public.acik_bilet_ara(text) from public;
revoke all on function public.acik_bilet_ara(text) from anon, authenticated, service_role;
grant execute on function public.acik_bilet_ara(text) to authenticated;

revoke all on function public.anlasma_bildirim_gonder()
  from public, anon, authenticated, service_role;

-- ----------------------------------------------------------------- cron ----
-- Aynı ad = varsa yerinde güncellenir.
select cron.schedule('otopark-anlasma-bildirim', '* * * * *',
                     $$select public.anlasma_bildirim_gonder()$$);

do $$
declare
  f text;
begin
  foreach f in array array['public.bilet_anlasma(uuid, integer, integer)',
                           'public.bilet_anlasma_fazla(uuid)',
                           'public.bilet_fazla_onizle(uuid)',
                           'public.acik_bilet_ara(text)',
                           'public.puan_kullan(uuid, integer)'] loop
    if not has_function_privilege('authenticated', f, 'execute')
       or has_function_privilege('anon', f, 'execute')
       or has_function_privilege('service_role', f, 'execute') then
      raise exception '080: % yalnızca authenticated için olmalı', f;
    end if;
  end loop;
  foreach f in array array['public.anlasma_bildirim_gonder()',
                           'public.bilet_ucreti(public.biletler, timestamptz)'] loop
    if has_function_privilege('authenticated', f, 'execute')
       or has_function_privilege('anon', f, 'execute')
       or has_function_privilege('service_role', f, 'execute') then
      raise exception '080: % kimseye açık olmamalı', f;
    end if;
  end loop;
end $$;

commit;
