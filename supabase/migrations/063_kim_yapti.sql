-- ============================================================================
-- 063  Kim yaptı: toplayan, onaylayan, kaydeden
-- ============================================================================

begin;

-- Sahip (2026-11-15): her para kaydında kimin yaptığı görünsün — Onay'da
-- "Ödeme toplayan", karar verilince ve Finans'ta "Ödeme toplayan" ile
-- "Onaylayan/Reddeden", kasa kaydında "Kaydeden". Adları yalnızca Yönetici
-- görür (onay_listesi, kasa, audit zaten Yönetici'ye özel).
--
-- Veri çoğunlukla zaten vardı:
--   · tahsilatlar.created_by  = toplayan (her RPC auth.uid() yazar);
--   · tahsilatlar.onaylayan / onay_at = onaylayan ya da reddeden
--     (017 tahsilat_onayla, 028 tahsilat_reddet);
--   · vardiya kapatma ve bilet iptali kararını vereni audit_log.actor tutar
--     (035, 050) — istemci oradan okur, burada değişiklik yok.
-- İki eksik kapatılır:
--   1. onay_listesi onaylayanın adını ve karar anını döndürmüyordu;
--   2. kasa_hareketleri.created_by elle girilen kayıtta hep NULL kalıyordu
--      (istemci tabloya doğrudan yazar, dolduran yoktu); gece işinin düzenli
--      kayıtları da NULL'dı.
-- PASS 81 sınar.

-- ------------------------------------------------------------ onay_listesi --
-- Dönüş tipi değiştiği için düşürülüp yeniden kurulur. Gövde 017'ninkiyle
-- AYNI; yalnızca sona iki sütun eklenir. Eski istemci fazladan sütunları
-- görmezden gelir; yeni istemci 063'ten önce de çalışır (sütun yoksa satır
-- gösterilmez).

drop function if exists public.onay_listesi(public.onay_durum);

create function public.onay_listesi(
  p_durum public.onay_durum default 'BEKLIYOR'
)
returns table (
  id uuid, tur public.tahsilat_tur, tutar_kurus integer,
  yontem public.odeme_yontemi, aciklama text, created_at timestamptz,
  durum public.onay_durum, etiket text, personel text, onay_notu text,
  onaylayan text, onay_at timestamptz
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
         t.onay_notu,
         -- Onaylayan ya da reddeden (aynı sütun; durum hangisi olduğunu
         -- söyler). Ters kaydın kendiliğinden reddettiği satırda NULL.
         o.ad_soyad                       as onaylayan,
         t.onay_at
    from public.tahsilatlar t
    left join public.biletler   b on b.id = t.bilet_id
    left join public.abonmanlar a on a.id = t.abonman_id
    left join public.profiles   p on p.id = t.created_by
    left join public.profiles   o on o.id = t.onaylayan
   where t.durum = p_durum
   order by t.created_at desc
   limit 300;
end $$;

revoke all on function public.onay_listesi(public.onay_durum)
  from public, anon, authenticated, service_role;
grant execute on function public.onay_listesi(public.onay_durum) to authenticated;

-- ------------------------------------------------- kasa kaydının kaydedeni --
-- Oturum açan kişi HER ZAMAN kaydeden olur; istemcinin gönderdiği değer yok
-- sayılır (taklit edilemez). Oturum yoksa (gece işi kasa_tekrar_uygula)
-- gönderilen değer, o da yoksa düzenli kaydın kuralını yazan kişi.
--
-- Tek istisna çöpten geri almadır: cop_geri_al (049) satırı BÜTÜNÜYLE geri
-- yazar ve o satırın kimliğini app.cop_geri_al'a koyar. Geri gelen kayıt ilk
-- kaydedenini korur; geri alan Yönetici audit'te (cop_geri_al) zaten yazılı.

create or replace function public.kasa_hareketi_kaydeden()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('app.cop_geri_al', true), '') = new.id::text then
    return new;
  end if;
  new.created_by := coalesce(
    auth.uid(),
    new.created_by,
    (select r.created_by from public.kasa_tekrar_kurallari r
      where r.id = new.tekrar_kural_id));
  return new;
end $$;

drop trigger if exists kasa_hareketi_kaydeden_tg on public.kasa_hareketleri;
create trigger kasa_hareketi_kaydeden_tg
  before insert on public.kasa_hareketleri
  for each row execute function public.kasa_hareketi_kaydeden();

revoke all on function public.kasa_hareketi_kaydeden()
  from public, anon, authenticated, service_role;

-- Geçmiş düzenli kayıtlar kuralı yazanı alır. Elle girilmiş eski kayıtlarda
-- kimin girdiği hiç yazılmamıştı: NULL kalır, ekran satır göstermez.
update public.kasa_hareketleri h
   set created_by = r.created_by
  from public.kasa_tekrar_kurallari r
 where h.created_by is null
   and h.tekrar_kural_id = r.id
   and r.created_by is not null;

-- ------------------------------------------------------------------ denetim --
do $$
declare
  v_kolon text;
begin
  select string_agg(a, ',' order by n) into v_kolon
    from unnest((select proargnames from pg_proc
                  where oid = 'public.onay_listesi(public.onay_durum)'::regprocedure))
         with ordinality as u(a, n);
  if v_kolon is distinct from
     'p_durum,id,tur,tutar_kurus,yontem,aciklama,created_at,durum,etiket,personel,onay_notu,onaylayan,onay_at' then
    raise exception '063: onay_listesi sütunları beklenmedik: %', v_kolon;
  end if;

  if not has_function_privilege('authenticated', 'public.onay_listesi(public.onay_durum)', 'execute')
     or has_function_privilege('anon', 'public.onay_listesi(public.onay_durum)', 'execute')
     or has_function_privilege('service_role', 'public.onay_listesi(public.onay_durum)', 'execute') then
    raise exception '063: onay_listesi yetkileri yanlış';
  end if;

  if has_function_privilege('anon', 'public.kasa_hareketi_kaydeden()', 'execute')
     or has_function_privilege('authenticated', 'public.kasa_hareketi_kaydeden()', 'execute')
     or has_function_privilege('service_role', 'public.kasa_hareketi_kaydeden()', 'execute') then
    raise exception '063: kasa_hareketi_kaydeden birine açık';
  end if;

  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.kasa_hareketleri'::regclass
                    and tgname = 'kasa_hareketi_kaydeden_tg' and not tgisinternal) then
    raise exception '063: kasa_hareketi_kaydeden_tg tetiği yok';
  end if;
end $$;

commit;
