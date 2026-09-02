-- ============================================================================
-- 026  Her ödemenin bir yöntemi olsun
-- ============================================================================

begin;

-- İstemci tarafında her seçici artık Nakit ile açılıyor, yani ELLE yapılan
-- hiçbir ödeme yöntemsiz doğmuyor. Geriye OTOMATİK yollar kalıyor: gece işi
-- kimseye soramaz, yöntemi tanımdan okur. Tanımda NULL varsa kasayı oynatan
-- ama hiçbir kovaya (Nakit/Kart/Havale) girmeyen bir satır yazar — toplam ile
-- kovaların toplamı birbirini tutmaz ve sebebi görünmez.
--
-- GEÇMİŞ SATIRLAR DÜZELTİLMEZ. `tahsilatlar`, `kasa_hareketleri` ve
-- `personel_odemeler` üzerindeki NULL yöntemler o gün gerçekte ne olduğunun
-- kaydıdır; hepsine "nakit" demek veri uydurmaktır. Burada yalnızca BUNDAN
-- SONRA üretilecek ödemelerin kaynağı olan TANIMLAR düzeltilir.

-- ------------------------------------------------------- otomatik maaş ----

update public.profiles
   set maas_yontemi = 'NAKIT'
 where odeme_gunu is not null and maas_yontemi is null;

-- Otomatik ödeme günü olan personelin yöntemi de olmak zorunda. Gün NULL ise
-- yöntem de NULL olabilir — 016'nın bilerek bıraktığı "otomatik ödemeyi
-- kapatabilme" yolu budur ve kapanmamalıdır.
do $do$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.profiles'::regclass
                    and conname = 'profiles_maas_yontemi_ck') then
    alter table public.profiles add constraint profiles_maas_yontemi_ck
      check (odeme_gunu is null or maas_yontemi is not null);
  end if;
end
$do$;

-- Gövde 016'dan birebir; tek fark yöntemin gün doluyken Nakit'e düşmesi.
-- Koşulsuz bir coalesce 016'nın "gün ve yöntem TEMİZLENEBİLİR olmalı"
-- kuralını bozardı: gün silinirken yöntem de silinebilmeye devam ediyor.
create or replace function public.maas_guncelle(
  p_profile uuid,
  p_maas    integer,
  p_gun     smallint default null,
  p_yontem  public.odeme_yontemi default null
) returns void
language plpgsql security definer set search_path = public as $fn$
declare v_yontem public.odeme_yontemi;
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici maaş tanımlayabilir.';
  end if;
  if p_maas is null or p_maas < 0 then
    raise exception 'Maaş sıfır ya da daha büyük olmalı.';
  end if;
  if p_gun is not null and (p_gun < 1 or p_gun > 28) then
    raise exception 'Ödeme günü 1 ile 28 arasında olmalı.';
  end if;

  v_yontem := case when p_gun is not null then coalesce(p_yontem, 'NAKIT')
                   else p_yontem end;

  update public.profiles
     set maas_kurus = p_maas, odeme_gunu = p_gun, maas_yontemi = v_yontem
   where id = p_profile;
  if not found then
    raise exception 'Personel bulunamadı.';
  end if;
  perform public.audit('maas_guncelle', 'profiles', p_profile,
    jsonb_build_object('maas', p_maas, 'gun', p_gun, 'yontem', v_yontem));
end
$fn$;

-- --------------------------------------------------- düzenli kasa kaydı ----

update public.kasa_tekrar_kurallari set yontem = 'NAKIT' where yontem is null;

-- Kural her ay para üretir, dolayısıyla yöntemsiz kural diye bir şey olamaz.
-- Tek yazma yolu aşağıdaki RPC olduğu ve `kasa_tekrar_kurallari` çöp
-- kutusunda BULUNMADIĞI için (007 tetikleyicileri onu kapsamaz) NOT NULL
-- güvenli: eski bir anlık görüntünün geri alınması bu kolona düşemez.
-- `kasa_hareketleri` bilerek dokunulmadan bırakıldı — o çöpte VAR ve
-- geçmişte yöntemsiz satırları meşru olarak duruyor.
alter table public.kasa_tekrar_kurallari alter column yontem set not null;

-- Gövde 014'ten birebir; tek fark yöntemin Nakit'e düşmesi.
create or replace function public.kasa_tekrar_ekle(
  p_tur      public.kasa_tur,
  p_tutar    integer,
  p_gun      smallint,
  p_kategori text default null,
  p_aciklama text default '',
  p_yontem   public.odeme_yontemi default null,
  p_ilk_kayit boolean default true
) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_bugun  date := (now() at time zone 'Europe/Istanbul')::date;
  v_next   date;
  v_id     uuid;
  v_yontem public.odeme_yontemi := coalesce(p_yontem, 'NAKIT');
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici düzenli kayıt tanımlayabilir.';
  end if;
  if p_tutar is null or p_tutar <= 0 then
    raise exception 'Tutar sıfırdan büyük olmalı.';
  end if;
  if p_gun is null or p_gun < 1 or p_gun > 28 then
    raise exception 'Tekrar günü 1 ile 28 arasında olmalı.';
  end if;

  -- Kesinlikle bugünden SONRA: bugünün kaydını aşağıda kendimiz yazıyoruz,
  -- gece işi aynı gideri ikinci kez yazmamalı.
  v_next := date_trunc('month', v_bugun)::date + (p_gun - 1);
  if v_next <= v_bugun then
    v_next := (date_trunc('month', v_bugun) + interval '1 month')::date + (p_gun - 1);
  end if;

  insert into public.kasa_tekrar_kurallari
    (tur, tutar_kurus, kategori, aciklama, yontem, odeme_gunu, next_run, created_by)
  values
    (p_tur, p_tutar, nullif(trim(coalesce(p_kategori, '')), ''),
     coalesce(p_aciklama, ''), v_yontem, p_gun, v_next, auth.uid())
  returning id into v_id;

  if p_ilk_kayit then
    insert into public.kasa_hareketleri
      (tur, tutar_kurus, kategori, aciklama, yontem, tarih, tekrar_kural_id, created_by)
    values
      (p_tur, p_tutar, nullif(trim(coalesce(p_kategori, '')), ''),
       coalesce(p_aciklama, ''), v_yontem, v_bugun, v_id, auth.uid());
  end if;

  perform public.audit('kasa_tekrar_ekle', 'kasa_tekrar_kurallari', v_id,
    jsonb_build_object('tur', p_tur, 'tutar', p_tutar, 'gun', p_gun,
                       'yontem', v_yontem));
  return v_id;
end
$fn$;

-- -------------------------------------------------------------- verify ---
do $do$
begin
  if exists (select 1 from public.profiles
              where odeme_gunu is not null and maas_yontemi is null) then
    raise exception '026: yöntemsiz otomatik maaş kaldı';
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.profiles'::regclass
                    and conname = 'profiles_maas_yontemi_ck') then
    raise exception '026: maaş yöntemi kısıtı kurulmadı';
  end if;
  if exists (select 1 from public.kasa_tekrar_kurallari where yontem is null) then
    raise exception '026: yöntemsiz düzenli kayıt kuralı kaldı';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'kasa_tekrar_kurallari'
                and column_name = 'yontem' and is_nullable = 'YES') then
    raise exception '026: kural yöntemi hâlâ NULL olabiliyor';
  end if;
  -- Aynı imzayla replace edildiler; yetkileri korunmuş olmalı.
  if not has_function_privilege('authenticated',
        'public.maas_guncelle(uuid, integer, smallint, public.odeme_yontemi)', 'execute')
     or not has_function_privilege('authenticated',
        'public.kasa_tekrar_ekle(public.kasa_tur, integer, smallint, text, text,'
        ' public.odeme_yontemi, boolean)', 'execute') then
    raise exception '026: RPC yetkileri düştü';
  end if;
end
$do$;

commit;
