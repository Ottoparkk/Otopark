-- ============================================================================
-- 029  Plaka şüphesi — düşük güvenli okumayı bilette işaretle
-- ============================================================================

begin;

-- Enum değeri bu işlem İÇİNDE kullanılamaz (55P04). Aşağıda yalnızca plpgsql
-- gövdelerinde geçiyor; onlar ilk çalıştırmada çözülür, migration sırasında
-- değil. Doğrulama bloğu da bilerek bu değere dokunmuyor.
alter type public.bildirim_tur add value if not exists 'PLAKA_SUPHE';

-- ---------------------------------------------------------------- eşik ----

-- AYARDAN okunuyor, sabit değil: doğru sayı ancak plaka_okuma_log biriktikçe
-- bilinir ve onu değiştirmek için ikinci bir migration gerekmemeli.
--
-- Varsayılan 0.90, 0.65 DEĞİL. Sebebi kritik: 0.75'in altındaki okuma zaten
-- KABUL EDİLMİYOR (okumaGuvenilir), operatöre hiç gösterilmiyor ve bilete
-- girmiyor. 0.65'lik bir uyarı hiçbir zaman tetiklenmezdi. Tehlikeli bant
-- "kabul edildi ama emin değiliz" bandıdır: ölçümde yanlış okunan plaka 0.78
-- ile geçmişti, doğru okunanların hepsi 0.85 ve üzerindeydi.
alter table public.otopark_ayarlari
  add column if not exists plaka_supheli_esigi numeric(5,4) not null default 0.90
    check (plaka_supheli_esigi >= 0 and plaka_supheli_esigi <= 1);

-- ---------------------------------------------------------------- bilet ----

alter table public.biletler
  add column if not exists plaka_okuma_id uuid
    references public.plaka_okuma_log(id) on delete set null,
  add column if not exists plaka_supheli boolean not null default false;

create index if not exists biletler_plaka_supheli_ix
  on public.biletler (plaka_supheli) where plaka_supheli;

-- --------------------------------------------------------------- guard ----

-- Gövde 027'den birebir; tek fark v_detach'e eklenen kolon.
--
-- `plaka_okuma_id` FK'si `on delete set null` taşıyor, yani bir okuma kaydı
-- silinince bilet satırında UPDATE tetiklenir. Kapanmış bir bilette bu,
-- muafiyet listesinde olmadığı sürece "kapanmış bilet değiştirilemez" hatası
-- verirdi — silme işlemini tökezletir ve sebebi hiç anlaşılmazdı.
create or replace function public.biletler_immutable_guard() returns trigger
language plpgsql as $fn$
declare
  v_detach text[] := array[
    'park_yeri_id','vardiya_id','kapatan_vardiya_id','abonman_id',
    'giris_by','cikis_by','iptal_by',
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

  if coalesce(current_setting('app.bilet_tahsil', true), '') = old.id::text then
    v_old := v_old - 'tahsil_kurus' - 'odeme_yontemi';
    v_new := v_new - 'tahsil_kurus' - 'odeme_yontemi';
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

-- ----------------------------------------------------- okuma_supheli_mi ----

-- Şüphe kararının TEK yeri. Hem operatör yolu hem kamera yolu bunu çağırır;
-- iki kopya zamanla kaçınılmaz olarak ayrışırdı.
--
-- ALT SINIR (0.75) kritik ve ilk sürümde eksikti: bu değerin altındaki okuma
-- `okumaGuvenilir` tarafından zaten BASTIRILIR — operatöre hiç gösterilmez,
-- alan boş kalır ve plakayı insan yazar. Alt sınır olmadan, bastırılmış ama
-- DOĞRU bir okuma (ölçümde 0.65'te tam böyle bir vaka var) operatörün elle
-- yazdığı plakayla eşleşir ve kendi yazdığı plaka için uyarı alır. Yanlış
-- alarmın en gürültülü biçimi tam olarak budur.
--
-- 0.75 burada sabittir çünkü kabul kapısı istemci tarafında (`GUVEN_ESIGI`,
-- _shared/ocr.ts) yaşıyor. Biçimi tutmayan okumalar için oradaki kapı 0.92'dir;
-- burada onu tekrar etmiyoruz — regex'i iki çalışma ortamına kopyalamak, iki
-- kopyanın ayrışması demek olurdu. Kalan boşluk dar: standart dışı bir plakayı
-- (diplomatik/askerî) model 0.75-0.92 arasında doğru okumuş VE operatör aynısını
-- elle yazmış olmalı.
create or replace function public.okuma_supheli_mi(
  p_okuma_id uuid,
  -- null = insan bir şey kabul etmedi (kamera yolu): okumanın kendisi plakadır.
  p_kabul    text default null
) returns boolean
language plpgsql stable security definer set search_path = public as $fn$
declare
  v_guven    numeric;
  v_onerilen text;
  v_esik     numeric;
begin
  select l.guven, l.onerilen into v_guven, v_onerilen
    from public.plaka_okuma_log l where l.id = p_okuma_id;
  if not found or v_guven is null or coalesce(v_onerilen, '') = '' then
    return false;
  end if;

  -- Operatör öneriyi DEĞİŞTİRDİYSE plaka artık onundur, modelin değil.
  if p_kabul is not null and v_onerilen <> public.normalize_plaka(p_kabul) then
    return false;
  end if;

  select o.plaka_supheli_esigi into v_esik
    from public.otopark_ayarlari o where o.id = 1;

  return v_guven >= 0.75 and v_guven < coalesce(v_esik, 0.90);
end
$fn$;

-- Yalnızca içeriden çağrılır. Supabase yeni fonksiyonlara EXECUTE'u PUBLIC'e
-- verir ve `authenticated` de PUBLIC üyesidir — `from public` şart.
revoke all on function public.okuma_supheli_mi(uuid, text)
  from public, anon, authenticated, service_role;

-- ------------------------------------------------------- bilet_okuma_bagla --

-- `bilet_ac` BİLEREK ELLENMEDİ. Parametre eklemek onu düşürüp yeniden
-- yaratmayı gerektirirdi (farklı imza = aşırı yükleme, ve 11 argümanlı mevcut
-- çağrı iki adaya birden uyup "function is not unique" ile patlardı) — para
-- yolundaki tek giriş noktasında alınacak risk değil. Bunun yerine bilet
-- açıldıktan SONRA çağrılan ayrı bir RPC.
--
-- Başarısız olursa rozet çıkmaz; bilet ve para etkilenmez. İstemcide
-- fire-and-forget çağrılır, tam da bu yüzden.
create or replace function public.bilet_okuma_bagla(
  p_bilet_id uuid,
  p_okuma_id uuid,
  p_kabul    text
) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare
  v_b       public.biletler;
  v_guven   numeric;
  v_esik    numeric;
  v_supheli boolean := false;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    return false;
  end if;

  -- Doğruluk kaydını mevcut RPC yazsın: iki yerde aynı mantık istemiyoruz.
  -- SECURITY DEFINER içinden çağrılıyor ama auth.uid() hâlâ çağıranı verir,
  -- yani operator_id doğru kişiye yazılır.
  perform public.plaka_okuma_kabul(p_okuma_id, p_kabul);

  -- Varlık kontrolü kararın ÖNCESİNDE: `plaka_okuma_id` bir FK, ve olmayan
  -- bir kayda işaret eden update kısıtı ihlal ederdi.
  select l.guven into v_guven from public.plaka_okuma_log l where l.id = p_okuma_id;
  if not found then
    return false;
  end if;

  v_supheli := public.okuma_supheli_mi(p_okuma_id, p_kabul);

  -- Yalnızca denetim/bildirim metni için.
  select o.plaka_supheli_esigi into v_esik
    from public.otopark_ayarlari o where o.id = 1;

  update public.biletler
     set plaka_okuma_id = p_okuma_id,
         plaka_supheli  = v_supheli
   where id = p_bilet_id;

  if v_supheli then
    perform public.audit('bilet_plaka_supheli', 'biletler', p_bilet_id,
      jsonb_build_object('plaka', v_b.plaka, 'guven', v_guven, 'esik', v_esik));
    perform public.notify_yonetici('PLAKA_SUPHE', 'Plaka doğru okunmamış olabilir',
      v_b.plaka || ' — okuma güveni %' || round(v_guven * 100) || ', kontrol edilmeli',
      '/gise/bilet/' || p_bilet_id);
  end if;

  return v_supheli;
end
$fn$;

-- ------------------------------------------------------ kamera_okuma_bagla --

-- Kamera yolunun karşılığı, ve asıl ihtiyaç duyan yol BURASI: telefonda
-- operatör plakaya bakıp Onayla'ya basar, kamerada kimse bakmaz. İşaret
-- "kimsenin doğrulamadığı okuma" içindir; yalnızca operatör yolunda çalışsaydı
-- özelliğin amacı tersine dönerdi.
--
-- `p_kabul` YOK ve olmamalı: kamerada bir insan hiçbir şey kabul etmez, okuma
-- doğrudan biletin plakası olur. Aynı sebeple `plaka_okuma_kabul` de
-- çağrılmaz — `kabul_edilen` burada doldurulsaydı her satırda `onerilen` ile
-- birebir aynı olur ve doğruluk ölçümünü sahte bir %100 ile bozardı.
--
-- `is_staff()` GUARD'I YOK ve olamaz: webhook service_role ile çalışır,
-- `auth.uid()` null'dır, guard her çağrıda patlardı. Tek koruma GRANT'tır —
-- bu yüzden aşağıda `from public` dâhil her şeyden geri alınıp yalnızca
-- service_role'e veriliyor ve verify bloğu bunu sınıyor.
create or replace function public.kamera_okuma_bagla(
  p_bilet_id uuid,
  p_okuma_id uuid
) returns boolean
language plpgsql security definer set search_path = public as $fn$
declare
  v_b       public.biletler;
  v_guven   numeric;
  v_supheli boolean;
begin
  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found or v_b.durum <> 'ACIK' then
    return false;
  end if;

  -- FK'yi kırmamak için önce varlık kontrolü (bilet_okuma_bagla ile aynı).
  select l.guven into v_guven from public.plaka_okuma_log l where l.id = p_okuma_id;
  if not found then
    return false;
  end if;

  v_supheli := public.okuma_supheli_mi(p_okuma_id, null);

  update public.biletler
     set plaka_okuma_id = p_okuma_id,
         plaka_supheli  = v_supheli
   where id = p_bilet_id;

  if v_supheli then
    perform public.audit('bilet_plaka_supheli', 'biletler', p_bilet_id,
      jsonb_build_object('plaka', v_b.plaka, 'guven', v_guven, 'kaynak', 'KAMERA'));
    perform public.notify_yonetici('PLAKA_SUPHE', 'Plaka doğru okunmamış olabilir',
      v_b.plaka || ' — kameradan okundu, güven %' || round(v_guven * 100)
        || ', kontrol edilmeli',
      '/gise/bilet/' || p_bilet_id);
  end if;

  return v_supheli;
end
$fn$;

-- ----------------------------------------------------- bilet_plaka_dogrula --

-- "Doğru" — operatör plakayı gözüyle doğruladı, rozet kalkar.
--
-- Yalnızca AÇIK bilette: uyarının amacı aracın çıkışta bulunamamasını
-- önlemek, ve bilet kapandıysa plaka işini zaten yapmıştır. Bu sınır aynı
-- zamanda değişmezlik muafiyetine hiç ihtiyaç duymamamızı sağlıyor —
-- guard `durum = 'ACIK'` satırında zaten serbest bırakıyor.
create or replace function public.bilet_plaka_dogrula(p_bilet_id uuid)
returns void
language plpgsql security definer set search_path = public as $fn$
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
    raise exception 'Yalnızca açık bir bilette plaka doğrulanabilir.';
  end if;
  if not v_b.plaka_supheli then
    return;  -- zaten doğrulanmış: ikinci dokunuş hata değil
  end if;

  update public.biletler set plaka_supheli = false where id = p_bilet_id;

  perform public.audit('bilet_plaka_dogrulandi', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka));
end
$fn$;

-- ------------------------------------------------------ bilet_plaka_duzelt --

-- "Yanlış, düzelt" — plakayı değiştirir ve şüpheyi kaldırır.
--
-- Açık bilette plaka aracın KİMLİĞİdir; ücreti etkilemez, ama çıkışta aracın
-- bulunmasını sağlayan tek alandır. Bu yüzden değişiklik denetime yazılır.
create or replace function public.bilet_plaka_duzelt(p_bilet_id uuid, p_plaka text)
returns text
language plpgsql security definer set search_path = public as $fn$
declare
  v_b     public.biletler;
  v_yeni  text;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  v_yeni := public.normalize_plaka(p_plaka);
  if coalesce(v_yeni, '') = '' then
    raise exception 'Plaka boş olamaz.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception 'Yalnızca açık bir biletin plakası düzeltilebilir.';
  end if;

  if v_yeni = v_b.plaka then
    -- Değişiklik yok ama şüphe kalkmalı: operatör plakaya baktı ve onayladı.
    update public.biletler set plaka_supheli = false where id = p_bilet_id;
    return v_yeni;
  end if;

  begin
    update public.biletler
       set plaka = v_yeni, plaka_supheli = false
     where id = p_bilet_id;
  exception when unique_violation then
    -- biletler_acik_plaka_ux: içeride aynı plakalı başka bir açık bilet var.
    raise exception 'Bu plakayla içeride zaten açık bir bilet var: %', v_yeni;
  end;

  perform public.audit('bilet_plaka_duzeltildi', 'biletler', p_bilet_id,
    jsonb_build_object('eski', v_b.plaka, 'yeni', v_yeni));

  return v_yeni;
end
$fn$;

-- ------------------------------------------------------- acik_bilet_ara ----

-- Liste rozetinin kaynağı. `returns table` değiştiği için `create or replace`
-- YETMEZ — dönüş tipi değişince PostgreSQL reddeder; önce düşürmek şart, ve
-- düşürme ACL'i de sildiği için yetki aşağıda yeniden veriliyor (012 deseni).
--
-- Gövde 008'den birebir; tek fark dönüş listesine ve select'e eklenen kolon.
drop function if exists public.acik_bilet_ara(text);

create or replace function public.acik_bilet_ara(p_q text default null)
returns table (
  id uuid, plaka text, giris_at timestamptz,
  abonman_id uuid, park_yeri_id uuid, cikis_bekliyor_at timestamptz,
  indirim_kurus integer, puan_kullanilan integer, tarife_id uuid,
  gecikmeli_kayit boolean,
  notu_var boolean, ucret_kurus integer,
  plaka_supheli boolean
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
         b.plaka_supheli
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

-- -------------------------------------------------------------- grants ----

-- Supabase yeni fonksiyonlara EXECUTE'u PUBLIC'e verir ve `authenticated` de
-- PUBLIC üyesidir; `from anon, authenticated` TEK BAŞINA hiçbir şey kapatmaz.
revoke all on function public.bilet_okuma_bagla(uuid, uuid, text)
  from public, anon, service_role;
revoke all on function public.bilet_plaka_dogrula(uuid)
  from public, anon, service_role;
revoke all on function public.bilet_plaka_duzelt(uuid, text)
  from public, anon, service_role;

grant execute on function public.bilet_okuma_bagla(uuid, uuid, text) to authenticated;

-- Kamera yolu: is_staff() guard'ı taşıyamadığı için grant TEK korumadır.
revoke all on function public.kamera_okuma_bagla(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.kamera_okuma_bagla(uuid, uuid) to service_role;
grant execute on function public.bilet_plaka_dogrula(uuid)           to authenticated;
grant execute on function public.bilet_plaka_duzelt(uuid, text)      to authenticated;

-- Düşürüldüğü için yetkisi de düştü.
revoke all on function public.acik_bilet_ara(text) from public, anon, service_role;
grant execute on function public.acik_bilet_ara(text) to authenticated;

-- -------------------------------------------------------------- verify ----
do $do$
begin
  if not has_function_privilege('authenticated',
        'public.bilet_okuma_bagla(uuid, uuid, text)', 'execute')
     or not has_function_privilege('authenticated',
        'public.bilet_plaka_dogrula(uuid)', 'execute')
     or not has_function_privilege('authenticated',
        'public.bilet_plaka_duzelt(uuid, text)', 'execute') then
    raise exception '029: RPC yetkileri verilmedi';
  end if;

  if has_function_privilege('anon', 'public.bilet_plaka_duzelt(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.bilet_okuma_bagla(uuid, uuid, text)', 'execute') then
    raise exception '029: plaka RPC''leri anon rolüne açık';
  end if;

  -- Kamera bilet açar ama plaka düzeltemez.
  if has_function_privilege('service_role', 'public.bilet_plaka_duzelt(uuid, text)', 'execute') then
    raise exception '029: plaka düzeltme service_role''e açık';
  end if;

  if not has_function_privilege('authenticated', 'public.acik_bilet_ara(text)', 'execute') then
    raise exception '029: acik_bilet_ara yetkisi düştü — açık biletler listesi boş kalır';
  end if;
  if position('plaka_supheli' in
        pg_get_functiondef('public.acik_bilet_ara(text)'::regprocedure)) = 0 then
    raise exception '029: acik_bilet_ara plaka_supheli döndürmüyor';
  end if;

  -- Kamera RPC'si personele/anon'a açık kalmamalı; grant tek koruma.
  if has_function_privilege('anon', 'public.kamera_okuma_bagla(uuid, uuid)', 'execute')
     or has_function_privilege('authenticated',
          'public.kamera_okuma_bagla(uuid, uuid)', 'execute') then
    raise exception '029: kamera_okuma_bagla istemciye açık — tek koruması grant';
  end if;
  if not has_function_privilege('service_role',
        'public.kamera_okuma_bagla(uuid, uuid)', 'execute') then
    raise exception '029: kamera_okuma_bagla webhook''a kapalı — kamera bileti işaretlenemez';
  end if;
  if has_function_privilege('authenticated', 'public.okuma_supheli_mi(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.okuma_supheli_mi(uuid, text)', 'execute') then
    raise exception '029: okuma_supheli_mi istemciye açık';
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'biletler'
                    and column_name = 'plaka_supheli') then
    raise exception '029: plaka_supheli kolonu eklenmedi';
  end if;

  -- Guard muafiyeti gerçekten eklendi mi? Eklenmemişse bir okuma kaydının
  -- silinmesi kapanmış biletlerde hataya düşerdi.
  if position('plaka_okuma_id' in
        pg_get_functiondef('public.biletler_immutable_guard()'::regprocedure)) = 0 then
    raise exception '029: guard muafiyet listesine plaka_okuma_id eklenmedi';
  end if;
end
$do$;

commit;
