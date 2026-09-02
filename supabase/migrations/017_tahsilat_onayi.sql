-- ============================================================================
-- 017  Tahsilat onayı
-- ============================================================================

begin;

do $$
begin
  if not exists (
    select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
     where n.nspname = 'public' and t.typname = 'onay_durum'
  ) then
    create type public.onay_durum as enum ('BEKLIYOR', 'ONAYLANDI', 'REDDEDILDI');
  end if;
end $$;

do $$
begin
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public' and table_name = 'tahsilatlar'
       and column_name = 'durum'
  ) then
    execute 'alter table public.tahsilatlar
               add column durum public.onay_durum not null default ''BEKLIYOR''';
    -- Yalnızca kolon eklendiği anda çalışır: geçmiş tahsilatlar zaten
    -- defterdedir. Koşulsuz olsaydı, migration ikinci kez çalıştırıldığında
    -- bekleyen kuyruğun tamamını sessizce onaylardı.
    execute 'update public.tahsilatlar set durum = ''ONAYLANDI''';
  end if;
end $$;

alter table public.tahsilatlar
  add column if not exists onaylayan uuid references public.profiles(id) on delete set null,
  add column if not exists onay_at   timestamptz,
  add column if not exists onay_notu text;

create index if not exists tahsilatlar_onay_ix
  on public.tahsilatlar (created_at desc) where durum = 'BEKLIYOR';

-- --------------------------------------------------------------- iptal ---
create or replace function public.tahsilat_durum_ata() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_d public.onay_durum;
begin
  if new.iptal_of is not null then
    select t.durum into v_d from public.tahsilatlar t where t.id = new.iptal_of;

    if v_d = 'BEKLIYOR' then
      -- Hiç deftere girmedi; ikisi de girmemeli. Aksi hâlde net sıfır bir
      -- çift kuyrukta karar bekler, yalnızca biri onaylanırsa defter şişerdi.
      update public.tahsilatlar
         set durum     = 'REDDEDILDI',
             onay_notu = coalesce(onay_notu, 'İptal edildi')
       where id = new.iptal_of;
      new.durum     := 'REDDEDILDI';
      new.onay_notu := coalesce(new.onay_notu, 'İptal edildi');
    else
      -- Ters kayıt, defterden tam da aslının içinde bulunduğu anda çıkmalı.
      new.durum := coalesce(v_d, new.durum);
    end if;
  end if;

  -- Çöpten geri alınan 017 ÖNCESİ satırlar `durum` taşımaz: cop_geri_al
  -- jsonb_populate_record kullanır, eksik anahtar NULL olur ve açık NULL
  -- kolon varsayılanına DÜŞMEZ — bu satır olmasa geri alma not-null hatası
  -- verirdi. O satırlar gate'ten önce zaten defterdeydi.
  new.durum := coalesce(new.durum, 'ONAYLANDI');
  return new;
end $$;

drop trigger if exists tahsilat_iptal_durum_tg on public.tahsilatlar;
drop trigger if exists tahsilat_durum_tg on public.tahsilatlar;
create trigger tahsilat_durum_tg
  before insert on public.tahsilatlar
  for each row execute function public.tahsilat_durum_ata();

-- --------------------------------------------------------------- okuma ---
create or replace function public.onay_ozet()
returns table (adet bigint, toplam_kurus bigint)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  return query
  select count(*)::bigint, coalesce(sum(t.tutar_kurus), 0)::bigint
    from public.tahsilatlar t
   where t.durum = 'BEKLIYOR';
end $$;

create or replace function public.onay_listesi(
  p_durum public.onay_durum default 'BEKLIYOR'
)
returns table (
  id uuid, tur public.tahsilat_tur, tutar_kurus integer,
  yontem public.odeme_yontemi, aciklama text, created_at timestamptz,
  durum public.onay_durum, etiket text, personel text, onay_notu text
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  return query
  select t.id, t.tur, t.tutar_kurus, t.yontem, t.aciklama, t.created_at, t.durum,
         coalesce(b.plaka, a.plaka, '')   as etiket,
         coalesce(p.ad_soyad, 'Otomatik') as personel,
         t.onay_notu
    from public.tahsilatlar t
    left join public.biletler   b on b.id = t.bilet_id
    left join public.abonmanlar a on a.id = t.abonman_id
    left join public.profiles   p on p.id = t.created_by
   where t.durum = p_durum
   order by t.created_at desc
   limit 300;
end $$;

-- --------------------------------------------------------------- karar ---
-- Tek satır da toplu karar da AYNI yoldan geçer; istemci her zaman dizi
-- gönderir. Tek bir atomik UPDATE olduğu için oku-karar-yaz yarışı hiç
-- doğmaz: eşzamanlı ikinci karar 0 satır günceller. Karara bağlanmış satır
-- hata değil, sessiz atlamadır — tek bayat satır yüzünden bütün partiyi
-- düşürmek kullanıcıyı hiçbir şey karara bağlayamaz hâle getirirdi; dönen
-- sayı kaçının işlendiğini söyler.
drop function if exists public.tahsilat_onayla(uuid);
drop function if exists public.tahsilat_onayla_coklu(uuid[]);
drop function if exists public.tahsilat_reddet(uuid, text);

create or replace function public.tahsilat_onayla(p_ids uuid[]) returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_r record;
  v_n integer := 0;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici tahsilat onaylayabilir.';
  end if;

  for v_r in
    with u as (
      update public.tahsilatlar
         set durum = 'ONAYLANDI', onaylayan = auth.uid(), onay_at = now()
       where id = any (p_ids) and durum = 'BEKLIYOR'
      returning id, tur, tutar_kurus
    )
    select * from u
  loop
    perform public.audit('tahsilat_onayla', 'tahsilatlar', v_r.id,
      jsonb_build_object('tur', v_r.tur, 'tutar', v_r.tutar_kurus));
    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

create or replace function public.tahsilat_reddet(
  p_ids uuid[], p_sebep text default null
) returns integer
language plpgsql security definer set search_path = public as $$
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
      returning id, tur, tutar_kurus
    )
    select * from u
  loop
    perform public.audit('tahsilat_reddet', 'tahsilatlar', v_r.id,
      jsonb_build_object('tur', v_r.tur, 'tutar', v_r.tutar_kurus,
                         'sebep', btrim(coalesce(p_sebep, ''))));
    v_n := v_n + 1;
  end loop;

  return v_n;
end $$;

-- ------------------------------------------------------------ raporlar ---
create or replace function public.rapor_ozet(p_bas date, p_bit date)
returns table (
  ciro_kurus bigint, bilet_sayisi bigint, ortalama_dakika numeric,
  abonman_giris bigint, saatlik_giris bigint, iptal_sayisi bigint,
  ucret_degisiklik_sayisi bigint, puan_borcu_kurus bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;

  return query
  select
    -- Onaylanmamış tahsilat ciroya girmez.
    (select coalesce(sum(t.tutar_kurus), 0)::bigint from public.tahsilatlar t
      where (t.created_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit
        and t.durum = 'ONAYLANDI'),
    (select count(*)::bigint from public.biletler b
      where b.durum = 'KAPALI'
        and (b.cikis_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    (select round(avg(extract(epoch from (b.cikis_at - b.giris_at)) / 60.0)::numeric, 1)
       from public.biletler b
      where b.durum = 'KAPALI'
        and (b.cikis_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    (select count(*)::bigint from public.biletler b
      where b.abonman_id is not null and b.durum <> 'IPTAL'
        and (b.giris_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    (select count(*)::bigint from public.biletler b
      where b.abonman_id is null and b.durum <> 'IPTAL'
        and (b.giris_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    (select count(*)::bigint from public.biletler b
      where b.durum = 'IPTAL'
        and (b.iptal_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    (select count(*)::bigint from public.biletler b
      where b.ucret_degistirildi
        and (b.cikis_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit),
    -- What the business owes its customers in points, in lira. Invisible
    -- unless a screen shows it, which is why it is in the summary.
    (select coalesce(sum(ph.puan), 0)::bigint
       * coalesce((select k.kurus_per_puan from public.puan_kurallari k
                    where k.gecerli_bitis is null), 0)
       from public.puan_hareketleri ph);
end $$;

create or replace function public.rapor_gunluk(p_bas date, p_bit date)
returns table (
  gun date, ciro_kurus bigint, bilet_sayisi bigint,
  nakit_kurus bigint, kart_kurus bigint, havale_kurus bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_bit < p_bas then
    raise exception 'Bitiş tarihi başlangıçtan önce olamaz.';
  end if;

  -- generate_series over dates yields TIMESTAMPS, which would not match the
  -- `date` result column — hence the explicit cast in the subquery.
  return query
  select g.gun,
         coalesce(sum(t.tutar_kurus), 0)::bigint,
         count(t.id) filter (where t.tutar_kurus > 0)::bigint,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'NAKIT'), 0)::bigint,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'KREDI_KARTI'), 0)::bigint,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'HAVALE'), 0)::bigint
    from (select generate_series(p_bas, p_bit, interval '1 day')::date as gun) g
    left join public.tahsilatlar t
      -- ON, WHERE değil: WHERE'e yazılsaydı tahsilatsız günler listeden düşerdi.
      on (t.created_at at time zone 'Europe/Istanbul')::date = g.gun
     and t.durum = 'ONAYLANDI'
   group by g.gun
   order by g.gun;
end $$;

create or replace function public.yontem_ozet(p_bas date, p_bit date)
returns table (
  yontem      public.odeme_yontemi,
  gelir_kurus bigint,
  gider_kurus bigint
)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yetkiniz yok.';
  end if;

  return query
  select h.yontem,
         coalesce(sum(h.gelir), 0)::bigint,
         coalesce(sum(h.gider), 0)::bigint
    from (
      -- Bilet ve abonman tahsilatı: her zaman gelirdir.
      select t.yontem, t.tutar_kurus as gelir, 0 as gider
        from public.tahsilatlar t
       where (t.created_at at time zone 'Europe/Istanbul')::date between p_bas and p_bit
         and t.durum = 'ONAYLANDI'
      union all
      select k.yontem,
             case when k.tur = 'GELIR' then k.tutar_kurus else 0 end,
             case when k.tur = 'GIDER' then k.tutar_kurus else 0 end
        from public.kasa_hareketleri k
       where k.tarih between p_bas and p_bit
    ) h
   where h.yontem is not null
   group by h.yontem;
end $$;

-- -------------------------------------------------------------- grants ---
revoke all on function public.tahsilat_durum_ata()
  from public, anon, authenticated, service_role;

revoke all on function public.onay_ozet()
  from public, anon, authenticated, service_role;
grant execute on function public.onay_ozet() to authenticated;

revoke all on function public.onay_listesi(public.onay_durum)
  from public, anon, authenticated, service_role;
grant execute on function public.onay_listesi(public.onay_durum) to authenticated;

revoke all on function public.tahsilat_onayla(uuid[])
  from public, anon, authenticated, service_role;
grant execute on function public.tahsilat_onayla(uuid[]) to authenticated;

revoke all on function public.tahsilat_reddet(uuid[], text)
  from public, anon, authenticated, service_role;
grant execute on function public.tahsilat_reddet(uuid[], text) to authenticated;

-- -------------------------------------------------------------- verify ---
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'tahsilatlar'
                    and column_name = 'durum') then
    raise exception '017: durum kolonu yok';
  end if;

  -- `durum`un tek yazma yolu bu dosyadaki RPC'lerdir.
  if has_table_privilege('authenticated', 'public.tahsilatlar', 'INSERT')
     or has_table_privilege('authenticated', 'public.tahsilatlar', 'UPDATE')
     or has_table_privilege('anon', 'public.tahsilatlar', 'SELECT') then
    raise exception '017: tahsilatlar istemciye fazla açık';
  end if;

  if has_function_privilege('authenticated', 'public.tahsilat_durum_ata()', 'execute')
     or has_function_privilege('anon', 'public.onay_ozet()', 'execute')
     or has_function_privilege('anon', 'public.tahsilat_onayla(uuid[])', 'execute')
     or has_function_privilege('service_role', 'public.tahsilat_onayla(uuid[])', 'execute') then
    raise exception '017: onay yolu istemciye fazla açık';
  end if;

  if not has_function_privilege('authenticated', 'public.tahsilat_onayla(uuid[])', 'execute')
     or not has_function_privilege('authenticated', 'public.tahsilat_reddet(uuid[], text)', 'execute')
     or not has_function_privilege('authenticated', 'public.onay_listesi(public.onay_durum)', 'execute') then
    raise exception '017: onay RPC''leri Yöneticiye kapalı';
  end if;

  -- Aynı imzayla replace edilen rapor fonksiyonları ACL'lerini korumalı.
  if not has_function_privilege('authenticated', 'public.rapor_ozet(date, date)', 'execute')
     or not has_function_privilege('authenticated', 'public.rapor_gunluk(date, date)', 'execute')
     or not has_function_privilege('authenticated', 'public.yontem_ozet(date, date)', 'execute') then
    raise exception '017: rapor fonksiyonlarının yetkisi düştü';
  end if;

  if not exists (select 1 from pg_trigger
                  where tgname = 'tahsilat_durum_tg' and not tgisinternal) then
    raise exception '017: iptal tetikleyicisi kurulmadı';
  end if;
end $$;

commit;
