-- ============================================================================
-- 050  Personelin bilet iptali Yönetici onayına düşer
-- ============================================================================

begin;

-- Sahibin isteği (2026-11-07): personel bir bileti İPTAL ETMEMELİ, iptal
-- İSTEMELİ; Yönetici Onay ekranından karar verir. Bugüne kadar (030) personel
-- AÇIK bir bileti sebep yazarak anında iptal ediyordu (Yönetici yalnızca
-- bildirim alıyordu); kapanmış bilet zaten yalnızca Yöneticinindi. Silme hiçbir
-- zaman personele açık değildi (bilet_sil / kayit_sil Yönetici-only).
--
-- Kararlar (sahip):
--   · İstek beklerken bilet AÇIK kalır; ekranda "İptal onayı bekliyor".
--   · Araç bu arada çıkar ya da Yönetici bileti başka yoldan kapatırsa istek
--     düşer (iz kalır) — durum ACIK'tan çıkan her güncellemede, hangi yoldan
--     olursa olsun (tetik).
--   · Onay → bilet personelin sebebiyle iptal edilir (030'un yolu aynen).
--   · Ret → istek silinir, bilet açık kalır; isteyene bildirim gider.
--   · Onay ekranının "Onaylanan / Reddedilen" geçmişi audit_log'dan okunur
--     (bilet_iptal_onay / bilet_iptal_ret) — 035'in vardiya kararları gibi.
--
-- Yeni bildirim türleri bu işlemde YALNIZCA tanımlanır; literal'leri yalnızca
-- PL/pgSQL gövdelerinde geçer ve çalışma anında — commit'ten sonra — çözülür
-- (035'in deseni). `bildirim_yonetici_turu` SQL dilindedir ama karşılaştırmayı
-- `::text` üzerinden yapar, enum değeri kullanmaz.
alter type public.bildirim_tur add value if not exists 'BILET_IPTAL_TALEBI';
alter type public.bildirim_tur add value if not exists 'BILET_IPTAL_KARAR';

-- ---------------------------------------------------------------- şema ----

-- Açık bilet serbestçe güncellenebilir (biletler_immutable_guard yalnızca
-- kapanmış bileti korur, 029). İstemcinin biletler üzerinde yazma yetkisi
-- yok (003: yalnızca SELECT) — bu kolonlar yalnızca RPC'lerle yazılır.
alter table public.biletler
  add column if not exists iptal_talebi_at    timestamptz,
  add column if not exists iptal_talebi_by    uuid references public.profiles(id) on delete set null,
  add column if not exists iptal_talebi_sebep text;

-- Onay ekranının "bekleyen" listesi.
create index if not exists biletler_iptal_talebi_ix
  on public.biletler (iptal_talebi_at)
  where iptal_talebi_at is not null;

-- --------------------------------------------- bildirim_yonetici_turu ----
-- 045'in listesi + BILET_IPTAL_TALEBI (Yöneticiye). BILET_IPTAL_KARAR bilerek
-- YOK: o, isteyen PERSONELE gider (VARDIYA_KARAR gibi).
create or replace function public.bildirim_yonetici_turu(p_tur public.bildirim_tur)
returns boolean
language sql immutable as $fn$
  select p_tur::text in (
    'YENI_UYELIK','ABONMAN_BITIYOR','VARDIYA_FARK','TERK_EDILMIS','DOLULUK',
    'BILET_IPTAL','UCRET_DEGISIKLIGI','PUAN_KULLANIM','KAMERA',
    'KAMERA_HAREKET','VARDIYA_ACIK','ONAY_BEKLIYOR','PLAKA_SUPHE',
    'VARDIYA_KAPATMA','BILET_IPTAL_TALEBI'
  );
$fn$;

-- ----------------------------------------------------------- bilet_iptal ---
--
-- 030'un gövdesi BİREBİR; eklenen tek şey personel dalı (işaretli). Yönetici
-- için hiçbir şey değişmez. İmza aynı, yetkiler create or replace ile korunur
-- (aşağıda yine de açıkça yazılır).

create or replace function public.bilet_iptal(p_bilet_id uuid, p_sebep text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_b       public.biletler;
  v_vardiya uuid;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if coalesce(btrim(p_sebep), '') = '' then
    raise exception 'İptal sebebi zorunludur.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum = 'IPTAL' then
    raise exception 'Bu bilet zaten iptal edilmiş.';
  end if;
  if v_b.durum = 'KAPALI' and not public.is_yonetici() then
    raise exception 'Kapanmış bileti yalnızca Yönetici iptal edebilir.';
  end if;

  -- 050: personel İPTAL ETMEZ, İSTER. Bilet açık kalır; Yönetici Onay'dan
  -- karar verir (bilet_iptal_onayla / bilet_iptal_reddet).
  if not public.is_yonetici() then
    if v_b.iptal_talebi_at is not null then
      raise exception 'Bu bilet için iptal isteği zaten onay bekliyor.';
    end if;
    update public.biletler
       set iptal_talebi_at    = now(),
           iptal_talebi_by    = auth.uid(),
           iptal_talebi_sebep = btrim(p_sebep)
     where id = p_bilet_id;
    perform public.audit('bilet_iptal_talebi', 'biletler', p_bilet_id,
      jsonb_build_object('sebep', btrim(p_sebep), 'plaka', v_b.plaka));
    perform public.notify_yonetici('BILET_IPTAL_TALEBI', 'Bilet iptali onay bekliyor',
      v_b.plaka || ' — ' || btrim(p_sebep), '/finans/onay');
    return;
  end if;

  v_vardiya := public.acik_vardiyam();

  if v_b.durum = 'KAPALI' then
    -- Reverse the money first, while the row is still KAPALI.
    insert into public.tahsilatlar (
      tur, bilet_id, tutar_kurus, yontem, vardiya_id, iptal_of, created_by, aciklama)
    select t.tur, t.bilet_id, -t.tutar_kurus, t.yontem, v_vardiya, t.id, auth.uid(), 'Bilet iptali'
      from public.tahsilatlar t
     where t.bilet_id = p_bilet_id and t.iptal_of is null and t.tutar_kurus > 0;

    -- Name the exact row the immutability guard may let through.
    perform set_config('app.bilet_iptal', p_bilet_id::text, true);
  end if;

  update public.biletler
     set durum = 'IPTAL', iptal_sebep = btrim(p_sebep), iptal_by = auth.uid(), iptal_at = now()
   where id = p_bilet_id;

  -- Points earned or spent on a cancelled stay are reversed, never deleted.
  insert into public.puan_hareketleri (hesap_id, tur, puan, bilet_id, kural_id, created_by, aciklama)
  select ph.hesap_id, 'IPTAL', -ph.puan, ph.bilet_id, ph.kural_id, auth.uid(), 'Bilet iptali'
    from public.puan_hareketleri ph
   where ph.bilet_id = p_bilet_id and ph.tur in ('KAZANIM', 'KULLANIM');

  perform public.audit('bilet_iptal', 'biletler', p_bilet_id,
    jsonb_build_object('sebep', btrim(p_sebep), 'plaka', v_b.plaka,
                       'onceki_durum', v_b.durum, 'tahsil', v_b.tahsil_kurus));
  perform public.notify_yonetici('BILET_IPTAL', 'Bilet iptal edildi',
    v_b.plaka || ' — ' || btrim(p_sebep), '/finans/biletler');
end $$;

-- ---------------------------------------------------- bilet_iptal_onayla ---

create or replace function public.bilet_iptal_onayla(p_bilet_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_b public.biletler;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici iptal isteğine karar verebilir.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.iptal_talebi_at is null or v_b.durum <> 'ACIK' then
    raise exception 'Bu bilet için bekleyen bir iptal isteği yok.';
  end if;

  -- İstek ÖNCE temizlenir: iptal bileti ACIK'tan çıkarınca tetik bekleyen
  -- bir istek görmesin ve onaylanan isteği "düştü" diye yazmasın.
  update public.biletler
     set iptal_talebi_at = null, iptal_talebi_by = null, iptal_talebi_sebep = null
   where id = p_bilet_id;

  -- 030'un iptal yolu aynen (Yönetici dalı): sebep personelin yazdığıdır.
  perform public.bilet_iptal(p_bilet_id, v_b.iptal_talebi_sebep);

  perform public.audit('bilet_iptal_onay', 'biletler', p_bilet_id,
    jsonb_build_object('talep_eden', v_b.iptal_talebi_by,
                       'talep_at', v_b.iptal_talebi_at,
                       'sebep', v_b.iptal_talebi_sebep, 'plaka', v_b.plaka));

  if v_b.iptal_talebi_by is not null then
    perform public.notify_kisi(v_b.iptal_talebi_by, 'BILET_IPTAL_KARAR',
      'Bilet iptal edildi',
      v_b.plaka || ' — iptal isteğiniz onaylandı.', '/gise');
  end if;
end $$;

-- ---------------------------------------------------- bilet_iptal_reddet ---

create or replace function public.bilet_iptal_reddet(p_bilet_id uuid, p_sebep text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_b     public.biletler;
  v_sebep text;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici iptal isteğine karar verebilir.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.iptal_talebi_at is null or v_b.durum <> 'ACIK' then
    raise exception 'Bu bilet için bekleyen bir iptal isteği yok.';
  end if;

  v_sebep := nullif(btrim(p_sebep), '');

  -- Bilet AÇIK kalır: reddedilen bir iptal, içerideki bir araçtır.
  update public.biletler
     set iptal_talebi_at = null, iptal_talebi_by = null, iptal_talebi_sebep = null
   where id = p_bilet_id;

  perform public.audit('bilet_iptal_ret', 'biletler', p_bilet_id,
    jsonb_build_object('talep_eden', v_b.iptal_talebi_by,
                       'talep_at', v_b.iptal_talebi_at,
                       'sebep', v_b.iptal_talebi_sebep,
                       'ret_sebep', v_sebep, 'plaka', v_b.plaka));

  if v_b.iptal_talebi_by is not null then
    perform public.notify_kisi(v_b.iptal_talebi_by, 'BILET_IPTAL_KARAR',
      'Bilet iptal edilmedi',
      v_b.plaka || ' — ' || coalesce(v_sebep, 'iptal isteğiniz reddedildi.'),
      '/gise/bilet/' || p_bilet_id::text);
  end if;
end $$;

-- ------------------------------------------- isteğin düşmesi (tetik) ----
--
-- Bilet ACIK'tan çıktığında (çıkış, tahsilat, Yöneticinin doğrudan iptali,
-- kamera) bekleyen istek anlamını yitirir: temizlenir, iz kalır. Tek tek her
-- çıkış yolunu değiştirmek yerine tek tetik — yeni bir yol eklense de kaçmaz.

create or replace function public.bilet_iptal_talebi_temizle()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.durum = 'ACIK' and new.durum <> 'ACIK' and old.iptal_talebi_at is not null then
    new.iptal_talebi_at    := null;
    new.iptal_talebi_by    := null;
    new.iptal_talebi_sebep := null;
    perform public.audit('bilet_iptal_talebi_dustu', 'biletler', old.id,
      jsonb_build_object('talep_eden', old.iptal_talebi_by,
                         'sebep', old.iptal_talebi_sebep,
                         'yeni_durum', new.durum, 'plaka', old.plaka));
  end if;
  return new;
end $$;

drop trigger if exists bilet_iptal_talebi_temizle_tg on public.biletler;
create trigger bilet_iptal_talebi_temizle_tg
  before update on public.biletler
  for each row execute function public.bilet_iptal_talebi_temizle();

-- -------------------------------------------------------- acik_bilet_ara ---
--
-- Gişe'nin listesi bu fonksiyondan gelir; "İptal onayı bekliyor" çipi için
-- bir kolon eklenir (`iptal_talebi`, en sona). 031'in gövdesi BİREBİR. Dönüş
-- tipi değiştiği için `create or replace` YETMEZ: drop + create. Drop yetkileri
-- de siler ve yeni fonksiyona Supabase anon / authenticated / service_role ile
-- PUBLIC'e kendiliğinden EXECUTE verir (032 / 058 dersi) — yetkiler aşağıda
-- açıkça yeniden kurulur ve doğrulanır.

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
  iptal_talebi boolean
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
         case when b.abonman_id is not null then 0
              else public.ucret_hesapla(b.giris_at, now(), b.tarife_id) end,
         b.plaka_supheli,
         b.giris_by, b.giris_kaynak,
         (b.iptal_talebi_at is not null)
    from public.biletler b
   where b.durum = 'ACIK'
     and (v_q = '' or b.plaka like '%' || v_q || '%'
                   or (length(v_q) >= 3 and right(b.plaka, length(v_q)) = v_q))
   order by
     case when v_q = '' then 2
          when b.plaka = v_q then 0
          when b.plaka like v_q || '%' then 1
          else 2 end,
     b.cikis_bekliyor_at desc nulls last,
     b.giris_at desc
   limit 50;
end $fn$;

-- ---------------------------------------------------------------- yetki ----

revoke all on function public.acik_bilet_ara(text) from public;
revoke all on function public.acik_bilet_ara(text) from anon, authenticated, service_role;
grant execute on function public.acik_bilet_ara(text) to authenticated;

revoke all on function public.bilet_iptal(uuid, text) from public;
revoke all on function public.bilet_iptal(uuid, text) from anon, authenticated, service_role;
grant execute on function public.bilet_iptal(uuid, text) to authenticated;

revoke all on function public.bilet_iptal_onayla(uuid) from public;
revoke all on function public.bilet_iptal_onayla(uuid) from anon, authenticated, service_role;
grant execute on function public.bilet_iptal_onayla(uuid) to authenticated;

revoke all on function public.bilet_iptal_reddet(uuid, text) from public;
revoke all on function public.bilet_iptal_reddet(uuid, text) from anon, authenticated, service_role;
grant execute on function public.bilet_iptal_reddet(uuid, text) to authenticated;

-- Tetik fonksiyonu yalnızca tetikten çalışır; kimse doğrudan çağırmamalı.
revoke all on function public.bilet_iptal_talebi_temizle() from public;
revoke all on function public.bilet_iptal_talebi_temizle() from anon, authenticated, service_role;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  f text;
  r text;
begin
  foreach f in array array['public.bilet_iptal(uuid, text)',
                           'public.bilet_iptal_onayla(uuid)',
                           'public.bilet_iptal_reddet(uuid, text)',
                           'public.acik_bilet_ara(text)'] loop
    if not has_function_privilege('authenticated', f, 'execute') then
      raise exception '050: % authenticated rolüne kapalı', f;
    end if;
    foreach r in array array['anon', 'service_role'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception '050: % % rolüne açık', f, r;
      end if;
    end loop;
    if not exists (select 1 from pg_proc where oid = f::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
      raise exception '050: % SECURITY DEFINER + search_path=public değil', f;
    end if;
  end loop;

  foreach r in array array['anon', 'authenticated', 'service_role'] loop
    if has_function_privilege(r, 'public.bilet_iptal_talebi_temizle()', 'execute') then
      raise exception '050: bilet_iptal_talebi_temizle % rolüne açık', r;
    end if;
  end loop;

  if not exists (select 1 from pg_trigger
                  where tgname = 'bilet_iptal_talebi_temizle_tg'
                    and tgrelid = 'public.biletler'::regclass) then
    raise exception '050: bilet_iptal_talebi_temizle_tg tetiği yok';
  end if;
  -- Aynı adla ikinci bir tanım (farklı imza) bırakılmadı.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'bilet_iptal') <> 1 then
    raise exception '050: bilet_iptal birden çok imzayla tanımlı';
  end if;
end
$do$;

commit;
