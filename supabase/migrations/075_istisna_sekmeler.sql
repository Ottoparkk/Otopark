-- ============================================================================
-- 075  Çözülmemiş kayıtlar: Bekleyen / Çözülmüş / Kapatılan; personel yalnızca bekleyen
-- ============================================================================

begin;

-- Sahibin isteği 2026-11-23:
--   · Ekranda üç sekme: Bekleyen, Çözülmüş, Kapatılan.
--   · Personel yalnızca Bekleyen'i görür.
--   · Çözülmüş ve Kapatılan'da Yönetici kimin ne yaptığını görür
--     (cozuldu_by, cozuldu_at, cozum_notu — zaten tutuluyor).
--
-- Bugüne kadar tek bir cozuldu_at iki ayrı şeyi işaretliyordu: "Kapat" ile
-- kapatılan kayıt (istisna_coz, uygulama notu hep boş gönderir) ve bir
-- eylemle çözülen kayıt (istisna_bilet_ac / _saatli: "Bilet açıldı…",
-- "Kamera bileti zaten açmış…", "Bilet zaten açık…"; kameranın kendisi:
-- cozuldu_by boş, "Kamera yeniden denedi ve okudu…", "Bilet yeniden açıldı
-- (Araç çıkmadı).").
--
-- 1. istisnalar.kapatildi: yalnızca istisna_coz true yapar.
--    BOŞ GEÇİLEBİLİR, bilerek: Çöp Kutusu (049) silinen kaydı
--    jsonb_populate_record ile geri yükler; bu dosyadan önceki bir kopyada
--    anahtar yoktur ve NOT NULL o geri yüklemeyi bozar. Boş = kapatılmadı.
-- 2. Eski kayıtlar: bir insanın kapattığı ve notu sistem notu olmayan
--    kayıt kapatılmış sayılır.
-- 3. RLS: Yönetici hepsini, personel yalnızca bekleyeni (cozuldu_at boş)
--    okur. Sınır veritabanında; ekranda gizlemek yetmez. Kartı işleyen
--    RPC'ler SECURITY DEFINER olduğundan etkilenmez; rozet sayısı zaten
--    yalnızca bekleyeni sayar.
--
-- 074 (aracın yakın planı) yazıldı ama köprü 1.4.6 ile koşulacak. Bu dosya
-- 074'ün dokunduğu hiçbir şeye dokunmaz: 074'ten ÖNCE koşulabilir.
-- PASS 94 sınar.

-- --------------------------------------------------------------- sütun ----

alter table public.istisnalar
  add column if not exists kapatildi boolean default false;

-- ------------------------------------------------------------ eski kayıt ---

update public.istisnalar
   set kapatildi = true
 where cozuldu_at is not null
   and cozuldu_by is not null
   and kapatildi is not true
   and coalesce(cozum_notu, '') !~ '^(Bilet açıldı|Kamera bileti zaten açmış|Bilet zaten açık|Bilet yeniden açıldı|Kamera yeniden denedi)';

-- ----------------------------------------------------------- istisna_coz --

-- Gövde 002'den BİREBİR; tek ek: kapatildi = true. Aynı imza → create or
-- replace grant'ları korur; yine de aşağıda yeniden kurulup sınanır.
create or replace function public.istisna_coz(p_id uuid, p_not text default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  update public.istisnalar
     set cozuldu_by = auth.uid(), cozuldu_at = now(), cozum_notu = nullif(btrim(p_not), ''),
         kapatildi = true
   where id = p_id and cozuldu_at is null;
end $$;

revoke all on function public.istisna_coz(uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.istisna_coz(uuid, text) to authenticated;

-- ------------------------------------------------------------------ RLS ----

drop policy if exists istisnalar_select on public.istisnalar;
create policy istisnalar_select on public.istisnalar for select to authenticated
  using (public.is_yonetici() or (public.is_staff() and cozuldu_at is null));

-- ------------------------------------------------------------ doğrulama ---

do $$
begin
  if not has_function_privilege('authenticated', 'public.istisna_coz(uuid, text)', 'execute') then
    raise exception '075: istisna_coz authenticated rolüne kapalı';
  end if;
  if has_function_privilege('anon', 'public.istisna_coz(uuid, text)', 'execute')
     or has_function_privilege('service_role', 'public.istisna_coz(uuid, text)', 'execute') then
    raise exception '075: istisna_coz anon / service_role rolüne açık';
  end if;
  if exists (select 1 from public.istisnalar
              where kapatildi is true and (cozuldu_at is null or cozuldu_by is null)) then
    raise exception '075: bekleyen ya da kameranın çözdüğü kayıt kapatılmış işaretlendi';
  end if;
end $$;

commit;
