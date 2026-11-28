-- =====================================================================
-- 088  Fiş — giriş ve çıkış fişi
-- =====================================================================
begin;

-- Sahip 22.11 / 28.11: "müşteriyle para yüzünden tartışmayalım". El
-- terminali (Sunmi P2) Chrome'un yazdırma ekranıyla 58 mm fiş basar; fiş
-- yalnızca istenince basılır. Mali değeri yoktur; yasal fiş yazar kasada.
--   * fis_basimlari            — her basım bir satır: kim, ne zaman, hangi tür;
--                                 sıra numarası fişte "TEKRAR BASIM (n)" olur
--   * fis_basildi(bilet, tur)   — basımı yazar, sıra numarasını döner; çıkış
--                                 fişi yalnızca borç kalmamış kapalı bilete
--   * fis_tahmini(bilet, dk[])  — giriş fişindeki "tahmini" ücret, sunucuda,
--                                 tarifenin tam fiyatıyla (gerçek süre kuralı)
-- Fişin içeriği istemcide çizilir; para sunucudan okunur, orada hesaplanmaz.

do $$
begin
  if to_regprocedure('public.gun_raporu(date)') is null then
    raise exception '088: önce 087 çalıştırılmalı.';
  end if;
end $$;

-- -------------------------------------------------------- fis_basimlari --
create table public.fis_basimlari (
  id         uuid primary key default gen_random_uuid(),
  bilet_id   uuid not null references public.biletler(id) on delete cascade,
  tur        text not null check (tur in ('GIRIS', 'CIKIS')),
  basan      uuid references public.profiles(id) on delete set null default auth.uid(),
  -- Giriş fişinde müşterinin söylediği kalış (dakika); yoksa null.
  tahmin_dk  integer check (tahmin_dk is null or tahmin_dk between 1 and 1440),
  created_at timestamptz not null default now()
);
create index fis_basimlari_bilet_ix on public.fis_basimlari (bilet_id, tur, created_at);

-- Yalnızca okunur; yazan tek yol fis_basildi (security definer).
revoke all on public.fis_basimlari from public, anon, authenticated, service_role;
grant select on public.fis_basimlari to authenticated;
alter table public.fis_basimlari enable row level security;

-- Bileti görebilen fişini de görür (067'nin biletler_select kuralı, bilet
-- satırı üzerinden: o politika burada da çalışır). PENDING hiçbir şey görmez.
create policy fis_basimlari_select on public.fis_basimlari for select to authenticated
  using (public.is_staff()
         and exists (select 1 from public.biletler b where b.id = fis_basimlari.bilet_id));

-- --------------------------------------------------------- fis_basildi --
create or replace function public.fis_basildi(p_bilet_id uuid, p_tur text, p_tahmin_dk integer)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_b public.biletler;
  v_n integer;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_tur not in ('GIRIS', 'CIKIS') or p_tur is null then
    raise exception 'Fiş türü GIRIS ya da CIKIS olmalı.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id;
  -- Personel: 067'nin okuma kuralı (açık bilet, kendi vardiyası ya da son 3
  -- İstanbul günü içinde çıkış). Göremediği biletin fişini de basamaz.
  if not found
     or not (public.is_yonetici()
             or v_b.durum = 'ACIK'
             or coalesce(v_b.kapatan_vardiya_id = public.acik_vardiyam(), false)
             or (v_b.durum = 'KAPALI'
                 and v_b.cikis_at >= (((now() at time zone 'Europe/Istanbul')::date - 2)::timestamp
                                      at time zone 'Europe/Istanbul'))) then
    raise exception 'Bilet bulunamadı.';
  end if;

  if p_tur = 'GIRIS' then
    if v_b.durum <> 'ACIK' then
      raise exception 'Giriş fişi yalnızca içerideki araca basılır.';
    end if;
  else
    if v_b.durum <> 'KAPALI' then
      raise exception 'Çıkış fişi araç çıkış yaptıktan sonra basılır.';
    end if;
    -- Borç kalmamış olmalı: ödenmiş (tahsil > 0) ya da ücret − indirim = 0
    -- (ücretsiz çıkış, abonman, ücretsiz süre). Ödenmemişse önce, ücret
    -- henüz kesinleşmediyse (082 süre aşımı) daha da önce karar.
    if v_b.tahsil_kurus = 0 and v_b.ucret_kurus - v_b.indirim_kurus > 0 then
      if public.bilet_asim_bekliyor(v_b, v_b.cikis_at) then
        raise exception 'Önce süre aşımı için karar verin.';
      end if;
      raise exception 'Önce ödeme toplayın.';
    end if;
  end if;

  insert into public.fis_basimlari (bilet_id, tur, basan, tahmin_dk)
  values (v_b.id, p_tur, auth.uid(), case when p_tur = 'GIRIS' then p_tahmin_dk end);

  select count(*) into v_n from public.fis_basimlari
   where bilet_id = v_b.id and tur = p_tur;
  return v_n;
end $$;

-- --------------------------------------------------------- fis_tahmini --
-- Müşteri "2 saat kalacağım" dedi: o anki fiyat. Gerçek süre kuralı (sahip
-- 28.11): aşım kararı beklenmez, tarifenin tam fiyatı gösterilir; anlaşmalı
-- fiyat süresini aşarsa aşan kısım da (fişte "tahmini" yazar). Yıkama dahil
-- — bilet_ucreti (082) ile aynı hesap, yalnızca kararlar "tam" sayılır.
create or replace function public.fis_tahmini(p_bilet_id uuid, p_dakikalar integer[])
returns table (dakika integer, kurus integer)
language plpgsql stable security definer set search_path = public as $$
declare
  v_b public.biletler;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if coalesce(array_length(p_dakikalar, 1), 0) not between 1 and 6 then
    raise exception 'En çok 6 tahmin.';
  end if;
  select * into v_b from public.biletler where id = p_bilet_id;
  if not found or v_b.durum <> 'ACIK' then
    raise exception 'Tahmin yalnızca içerideki araç için verilir.';
  end if;

  v_b.asim_karar := 'TAM';
  if v_b.anlasma_kurus is not null then
    v_b.anlasma_fazla_at := coalesce(v_b.anlasma_fazla_at, now());
  end if;

  return query
  select d, public.bilet_ucreti(v_b, v_b.giris_at + make_interval(mins => d))
    from unnest(p_dakikalar) as d
   where d between 1 and 1440
   order by d;
end $$;

-- ------------------------------------------------------------- grants --
revoke all on function public.fis_basildi(uuid, text, integer)  from public, anon, authenticated, service_role;
revoke all on function public.fis_tahmini(uuid, integer[])      from public, anon, authenticated, service_role;
grant execute on function public.fis_basildi(uuid, text, integer) to authenticated;
grant execute on function public.fis_tahmini(uuid, integer[])     to authenticated;

do $do$
begin
  if has_function_privilege('anon', 'public.fis_basildi(uuid, text, integer)', 'execute')
     or has_function_privilege('service_role', 'public.fis_basildi(uuid, text, integer)', 'execute')
     or has_function_privilege('anon', 'public.fis_tahmini(uuid, integer[])', 'execute')
     or has_function_privilege('service_role', 'public.fis_tahmini(uuid, integer[])', 'execute') then
    raise exception 'DOĞRULAMA: 088 fonksiyonları istemci dışı rollere açık.';
  end if;
  if not has_function_privilege('authenticated', 'public.fis_basildi(uuid, text, integer)', 'execute')
     or not has_function_privilege('authenticated', 'public.fis_tahmini(uuid, integer[])', 'execute') then
    raise exception 'DOĞRULAMA: 088 fonksiyonları authenticated rolüne kapalı.';
  end if;
  if has_table_privilege('authenticated', 'public.fis_basimlari', 'insert')
     or has_table_privilege('anon', 'public.fis_basimlari', 'select') then
    raise exception 'DOĞRULAMA: fis_basimlari yetkileri fazla.';
  end if;
end
$do$;

commit;
