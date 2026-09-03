-- ============================================================================
-- 030  Vardiya kasaya ait: tek ortak vardiya + seçilen saatte otomatik açılış
-- ============================================================================

begin;

-- ---------------------------------------------------------------- şema ----

-- Otomatik açılan vardiyanın AÇANI YOKTUR. Uydurulmuş bir açan, o gün kasayı
-- kimin devraldığını yanlış gösterirdi; boş bırakmak dürüsttür. Kapatan —
-- yani nakdi sayan — her zaman gerçek bir kişidir ve ayrıca yazılır.
alter table public.vardiyalar alter column personel_id drop not null;

alter table public.vardiyalar
  add column if not exists kapatan_id uuid references public.profiles(id) on delete set null;

alter table public.vardiyalar
  add column if not exists otomatik_acildi boolean not null default false;

do $do$
begin
  -- Elle açılan vardiyanın açanı belli olmak ZORUNDA; boşluk yalnızca
  -- otomatik açılışa aittir.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.vardiyalar'::regclass
                    and conname = 'vardiyalar_acan_ck') then
    alter table public.vardiyalar add constraint vardiyalar_acan_ck
      check (otomatik_acildi or personel_id is not null);
  end if;
end
$do$;

-- Saat null = özellik kapalı. Güvenli varsayılan: bu migration hiçbir kasada
-- kendiliğinden vardiya açmaya başlamaz, Yönetici saati girene kadar bekler.
alter table public.otopark_ayarlari
  add column if not exists vardiya_otomatik_saat time;

-- Otomatik açılan vardiyanın kasasında duran standart para üstü. 0 ile açmak,
-- çekmecede gerçekten para varsa HER kapanışta o tutar kadar sahte fazla
-- üretir ve fark uyarısını gürültüye çevirir — uyarı da böylece işe yaramaz
-- hâle gelirdi. Bu yüzden ayarlanabilir.
alter table public.otopark_ayarlari
  add column if not exists vardiya_acilis_nakit_kurus integer not null default 0
    check (vardiya_acilis_nakit_kurus >= 0);

-- --------------------------------------------------------------- geçiş ----

-- Eski model vardiyayı KİŞİYE bağlıyordu; ortak çekmecede bu, iki personelin
-- tahsilatını iki ayrı vardiyaya bölüp ikisinin de sayımını tutmaz hâle
-- getiriyordu. Açık kalan kişisel vardiyalar burada kapanır.
--
-- SAYIM YAPILMAZ: kimse saymadı. 025'in `vardiyalar_otomatik_sayim_ck`
-- kısıtı da uydurma sayımı reddediyor — kaybı gizleyen bir onarım, onarım
-- değildir. Beklenen tutar ise bir olgudur, yazılır.
update public.vardiyalar v
   set kapanis_at           = now(),
       beklenen_nakit_kurus = v.acilis_nakit_kurus + coalesce(
         (select sum(t.tutar_kurus)::integer from public.tahsilatlar t
           where t.vardiya_id = v.id and t.yontem = 'NAKIT'), 0),
       kapanis_kaynak       = 'OTOMATIK',
       notlar               = coalesce(nullif(btrim(v.notlar), '') || ' · ', '')
                              || 'Model değişikliği (030): vardiya artık kasaya ait.'
 where v.kapanis_at is null;

-- Tek açık vardiya — kişi başına DEĞİL, kasa başına. Sabit ifadeli kısmi
-- indeks: kapsanan satırlarda ifade her zaman true olduğundan en fazla bir
-- satır girebilir.
drop index if exists public.vardiyalar_acik_ux;
create unique index if not exists vardiyalar_tek_acik_ux
  on public.vardiyalar ((kapanis_at is null)) where kapanis_at is null;

-- -------------------------------------------------------- vardiya = kasa --

-- Artık "benim vardiyam" değil, "kasanın açık vardiyası". İsim korunuyor:
-- iki politikada ve beş RPC'de geçiyor, ve tek tanım olması model
-- değişikliğinin tamamını tek yere topluyor.
--
-- `is_staff()` gövdeye GİRDİ ve bu bir GÜVENLİK düzeltmesidir. Eski sorgu
-- personel olmayanı `auth.uid()` eşleşmediği için kendiliğinden eliyordu.
-- Kasaya ait tek satır artık herkes için eşleşeceğinden o örtük filtre
-- kalktı — ve `tahsilatlar_select` politikasında kendi `is_staff()` kontrolü
-- YOKTU, yani PENDING (rolü null) bir kullanıcı açık vardiyanın bütün
-- tahsilatlarını okuyabilir hâle gelirdi.

create or replace function public.acik_vardiyam() returns uuid
language sql stable security definer set search_path = public as $$
  select v.id from public.vardiyalar v
   where public.is_staff() and v.kapanis_at is null
   limit 1;
$$;

-- -------------------------------------------------------------- açma ------

-- Gövde 002'den birebir; tek fark hata metni. Asıl sınır yukarıdaki
-- indekstir: ikinci vardiya artık "senin ikinci vardiyan" değil, KASANIN
-- ikinci vardiyası olduğu için reddedilir.
create or replace function public.vardiya_ac(p_acilis_nakit_kurus integer default 0)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_acilis_nakit_kurus < 0 then
    raise exception 'Açılış nakdi negatif olamaz.';
  end if;

  begin
    insert into public.vardiyalar (personel_id, acilis_nakit_kurus)
    values (auth.uid(), coalesce(p_acilis_nakit_kurus, 0))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'Kasa vardiyası zaten açık. Önce onu kapatın.';
  end;

  perform public.audit('vardiya_ac', 'vardiyalar', v_id, null);
  return v_id;
end $$;

-- ----------------------------------------------------------- kapatma ------

-- Gövde 025'ten birebir; üç fark: (1) vardiya kişiye göre değil kasaya göre
-- bulunur, (2) nakdi SAYAN kişi `kapatan_id`e yazılır — ortak çekmecede açan
-- ile sayan aynı kişi olmak zorunda değil, (3) fark bildirimi sayan kişiyi
-- adlandırır ve artık `coalesce`lidir: `personel_id` null olabildiğinden eski
-- hâli otomatik açılmış bir vardiyada bildirim gövdesini komple NULL yapardı.
create or replace function public.vardiya_kapat(
  p_sayilan_nakit_kurus integer, p_notlar text default null
) returns table (beklenen_kurus integer, sayilan_kurus integer, fark_kurus integer)
language plpgsql security definer set search_path = public as $fn$
declare
  v_v        public.vardiyalar;
  v_nakit    integer;
  v_beklenen integer;
  v_fark     integer;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_sayilan_nakit_kurus is null or p_sayilan_nakit_kurus < 0 then
    raise exception 'Sayılan nakit negatif olamaz.';
  end if;

  select * into v_v from public.vardiyalar
   where kapanis_at is null for update;
  if not found then
    raise exception 'Açık kasa vardiyası yok.';
  end if;

  select coalesce(sum(t.tutar_kurus), 0)::integer into v_nakit
    from public.tahsilatlar t
   where t.vardiya_id = v_v.id and t.yontem = 'NAKIT';

  v_beklenen := v_v.acilis_nakit_kurus + v_nakit;
  v_fark     := p_sayilan_nakit_kurus - v_beklenen;

  update public.vardiyalar
     set kapanis_at           = now(),
         sayilan_nakit_kurus  = p_sayilan_nakit_kurus,
         beklenen_nakit_kurus = v_beklenen,
         fark_kurus           = v_fark,
         kapanis_kaynak       = 'ELLE',
         kapatan_id           = auth.uid(),
         notlar               = nullif(btrim(p_notlar), '')
   where id = v_v.id;

  if v_fark <> 0 then
    perform public.audit('vardiya_fark', 'vardiyalar', v_v.id,
      jsonb_build_object('beklenen', v_beklenen, 'sayilan', p_sayilan_nakit_kurus,
                         'fark', v_fark));
    perform public.notify_yonetici('VARDIYA_FARK', 'Vardiya farkı',
      coalesce((select p.ad_soyad from public.profiles p where p.id = auth.uid()),
               'Personel')
        || ' — fark ' || (v_fark / 100.0)::numeric(12,2) || ' ₺',
      '/finans/vardiyalar');
  end if;

  return query select v_beklenen, p_sayilan_nakit_kurus, v_fark;
end
$fn$;

-- -------------------------------------------------------------- özet ------

-- Gövde 002'den birebir; iki fark: vardiyanın kasaya göre bulunması ve
-- `otomatik_acildi` sütunu — ekran, açılış nakdini bir insanın mı saydığını
-- yoksa ayardan mı geldiğini söyleyebilmeli. `is_staff()` gövdede zaten var.
--
-- Dönüş tipi değiştiği için `create or replace` YETMEZ, drop şarttır — ve
-- drop ACL'i de siler, o yüzden grant aşağıda yeniden veriliyor.
drop function if exists public.vardiya_ozetim();
create or replace function public.vardiya_ozetim()
returns table (
  vardiya_id uuid, acilis_at timestamptz, acilis_nakit_kurus integer,
  nakit_kurus bigint, kart_kurus bigint, havale_kurus bigint,
  toplam_kurus bigint, bilet_sayisi bigint, otomatik_acildi boolean
)
language plpgsql stable security definer set search_path = public as $$
declare v_v public.vardiyalar;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_v from public.vardiyalar
   where kapanis_at is null;
  if not found then
    return;   -- no open shift: an empty result, not an error
  end if;

  return query
  select v_v.id, v_v.acilis_at, v_v.acilis_nakit_kurus,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'NAKIT'), 0)::bigint,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'KREDI_KARTI'), 0)::bigint,
         coalesce(sum(t.tutar_kurus) filter (where t.yontem = 'HAVALE'), 0)::bigint,
         coalesce(sum(t.tutar_kurus), 0)::bigint,
         count(*) filter (where t.tutar_kurus > 0)::bigint,
         v_v.otomatik_acildi
    from public.tahsilatlar t
   where t.vardiya_id = v_v.id;
end $$;

grant execute on function public.vardiya_ozetim() to authenticated;

-- --------------------------------------------- vardiyayı kullananlar ------

-- Beş RPC de açık vardiyayı KENDİ içinde sorguluyordu — yani 003'teki "tek
-- tanım" yorumu doğru değildi. Hepsi artık `acik_vardiyam()`e çağrı yapıyor;
-- gövdelerin geri kalanı bulundukları migration'dan (010 / 027 / 002 / 028 /
-- 006) birebir kopyalandı.
create or replace function public.bilet_ac(
  p_plaka        text,
  p_islem_id     uuid,
  p_kaynak       public.kaynak default 'MOBIL',
  p_zaman        timestamptz default null,
  p_foto         text default null,
  p_park_yeri_id uuid default null,
  p_ham_yanit    jsonb default null,
  -- Optional metadata. NOT part of any money or identity rule — a ticket must
  -- still open for a car whose driver says nothing.
  p_arac_bilgi   text default null,
  p_musteri_ad   text default null,
  p_musteri_tel  text default null,
  p_notlar       text default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plaka      text;
  v_zaman      timestamptz;
  v_limit_dk   integer;
  v_puan_aktif boolean;
  v_tarife     uuid;
  v_abonman    uuid;
  v_vardiya    uuid;
  v_gecikmeli  boolean := false;
  v_id         uuid;
  v_con        text;
  v_arac       text;
  v_ad         text;
  v_tel        text;
  v_not        text;
  -- 010
  v_yer        uuid;
  v_yer_kod    text;
  v_yer_aktif  boolean;
  v_yer_plaka  text;
  v_yer_hata   text;
begin
  -- Two disjoint callers, and keeping them disjoint is load-bearing:
  --   • staff (a JWT is present)                  → MOBIL/MANUEL, and the time
  --                                                 is ALWAYS the server's
  --   • the webhook (service_role, auth.uid() IS NULL) → KAMERA, the only
  --                                                 caller allowed to supply
  --                                                 p_zaman
  --
  -- `is_staff() OR (uid IS NULL AND KAMERA)` was NOT enough: staff satisfy the
  -- first branch, so they could pass p_kaynak = 'KAMERA' themselves — and that
  -- hands them p_zaman. It is a silent mis-billing tool: record an 08:00
  -- arrival as 13:00 and five billable hours vanish, leaving a ticket that
  -- looks completely ordinary. The source must match WHO is calling, not
  -- merely what the caller claims to be.
  if p_kaynak = 'KAMERA' then
    if auth.uid() is not null then
      raise exception 'Kamera kaynağı istemciden kullanılamaz.';
    end if;
  elsif not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;

  -- ---- 010: replay, decided BEFORE anything is read ----------------------
  -- The insert's unique_violation handler used to be the only replay guard,
  -- and that was enough while nothing was read beforehand. It no longer is:
  -- the bay check below would find the ticket THIS call already created and
  -- report the operator's own car as another one. A retry — from the camera or
  -- from retry-on-blip — must return the original ticket, always.
  select b.id into v_id from public.biletler b where b.islem_id = p_islem_id;
  if v_id is not null then
    return v_id;
  end if;

  v_plaka := public.normalize_plaka(p_plaka);
  if v_plaka !~ '^[A-Z0-9]{2,15}$' then
    raise exception 'Geçersiz plaka: %', coalesce(p_plaka, '(boş)');
  end if;

  -- Blank means absent, not empty string, so a skipped field never has to be
  -- told apart from a cleared one anywhere downstream.
  v_arac := nullif(btrim(coalesce(p_arac_bilgi, '')), '');
  v_ad   := nullif(btrim(coalesce(p_musteri_ad, '')), '');
  -- Digits only: an operator may type "0532 111 22 33" or "+90 532…" and the
  -- stored form is the national ten, exactly as abonmanlar.musteri_tel.
  v_tel  := nullif(regexp_replace(coalesce(p_musteri_tel, ''), '[^0-9]', '', 'g'), '');
  if v_tel is not null and v_tel !~ '^[1-9][0-9]{9}$' then
    raise exception 'Geçersiz müşteri numarası: başında 0 olmadan 10 hane girin.';
  end if;
  -- Truncate rather than raise: these two are cosmetic, and refusing to open a
  -- ticket over a long model name would leave a real car in the lot with no
  -- record at all. The phone above is different — a wrong number is bad data
  -- rather than long data, and the client blocks it before it reaches here.
  v_arac := left(v_arac, 60);
  v_ad   := left(v_ad, 80);
  v_not  := left(nullif(btrim(coalesce(p_notlar, '')), ''), 500);

  if p_kaynak = 'KAMERA' then
    if p_zaman is null then
      raise exception 'Kamera kaydı zaman damgası olmadan kabul edilmez.';
    end if;
    v_zaman := p_zaman;
  else
    v_zaman := now();   -- a client-supplied timestamp is ignored, by design
  end if;

  select o.kamera_gecikme_limiti_dk, o.puan_aktif
    into v_limit_dk, v_puan_aktif
    from public.otopark_ayarlari o where o.id = 1;
  v_limit_dk := coalesce(v_limit_dk, 720);

  -- A clock ahead of ours is not a late event, it is a broken camera.
  if v_zaman > now() + interval '5 minutes' then
    perform public.istisna_yaz('GELECEK', 'GIRIS', v_plaka, p_kaynak, p_islem_id,
                               p_ham_yanit, p_foto, v_zaman);
    return null;
  end if;

  -- Too old to be honest: the car has almost certainly already left, and a
  -- ticket opened now would be fiction that bills someone at exit.
  if v_zaman < now() - make_interval(mins => v_limit_dk) then
    perform public.istisna_yaz('BAYAT', 'GIRIS', v_plaka, p_kaynak, p_islem_id,
                               p_ham_yanit, p_foto, v_zaman);
    return null;
  end if;

  v_gecikmeli := (p_kaynak = 'KAMERA' and v_zaman < now() - interval '2 minutes');

  v_tarife := public.aktif_tarife();
  if v_tarife is null then
    raise exception 'Aktif tarife tanımlı değil.';
  end if;

  -- A valid subscriber enters free; the ticket exists purely as a record.
  select a.id into v_abonman
    from public.abonmanlar a
   where a.plaka = v_plaka and a.durum = 'AKTIF'
     and (now() at time zone 'Europe/Istanbul')::date between a.baslangic and a.bitis
   limit 1;

  -- Kasanın açık vardiyası. Eski `auth.uid() is not null` sarmalayıcısı
  -- düştü: `acik_vardiyam()` personel olmayan çağırana — yani kameranın
  -- service_role'üne — zaten null döndürüyor, davranış birebir aynı.
  v_vardiya := public.acik_vardiyam();

  -- ---- 010: the bay ------------------------------------------------------
  --
  -- Asked here, before the insert, so the operator gets a sentence naming the
  -- bay and the car on it instead of a unique-constraint failure. The index is
  -- still the guard — see the lock below and the handler further down.
  --
  -- The plate is checked first on purpose: a car that is already inside is
  -- the more likely mistake and the more useful thing to be told, and without
  -- this the message would be about the bay its own ticket is sitting in.
  if exists (select 1 from public.biletler b
              where b.plaka = v_plaka and b.durum = 'ACIK') then
    raise exception 'Bu plaka için zaten açık bir bilet var: %', v_plaka;
  end if;

  if p_park_yeri_id is not null or p_kaynak = 'KAMERA' then
    -- Read-decide-write across two statements, so it is serialised the same
    -- way every other multi-statement decision in this schema is. Without it
    -- two entries can both read a bay as free; with it the loser sees the
    -- winner's committed ticket and gets the sentence rather than the index's
    -- error. Only taken when a bay is actually in play.
    --
    -- Deliberately a DIFFERENT key from park_yerleri_uret (009): sharing one
    -- would make every car at the gate wait behind a settings save that can
    -- write two thousand rows. The gap that leaves is one interleaving —
    -- the generator reads a bay as free, this writes a ticket onto it, the
    -- generator then retires it — whose whole cost is a ticket pointing at a
    -- bay the picker no longer lists. Cosmetic, and not worth blocking the
    -- gate for.
    perform pg_advisory_xact_lock(hashtext('bilet_ac_yer'));
  end if;

  if p_park_yeri_id is not null then
    select p.kod, p.is_active into v_yer_kod, v_yer_aktif
      from public.park_yerleri p where p.id = p_park_yeri_id;

    select b.plaka into v_yer_plaka
      from public.biletler b
     where b.park_yeri_id = p_park_yeri_id and b.durum = 'ACIK'
     limit 1;

    if v_yer_kod is null then
      v_yer_hata := 'Park yeri bulunamadı.';
    elsif not v_yer_aktif then
      v_yer_hata := format('Bu park yeri kullanım dışı: %s', v_yer_kod);
    elsif v_yer_plaka is not null then
      v_yer_hata := format('Bu park yerinde başka bir araç var: %s (%s). Başka bir yer seçin.',
                           v_yer_kod, v_yer_plaka);
    end if;

    if v_yer_hata is null then
      v_yer := p_park_yeri_id;
    elsif p_kaynak <> 'KAMERA' then
      -- Rule 2, the operator's half: they picked this bay, so they are told.
      -- Nothing is written, and retrying with the same p_islem_id is safe.
      raise exception '%', v_yer_hata;
    end if;
  end if;

  -- Rule 2, the camera's half: nobody is standing there to choose, so an
  -- unusable bay (or none supplied at all) falls back to the first free one,
  -- and a full lot simply leaves it NULL. The ticket always opens.
  if v_yer is null and p_kaynak = 'KAMERA' then
    v_yer := public.bos_park_yeri();
  end if;
  -- ---- /010 --------------------------------------------------------------

  begin
    insert into public.biletler (
      islem_id, plaka, giris_at, tarife_id, abonman_id, park_yeri_id,
      vardiya_id, giris_by, giris_kaynak, giris_foto,
      gecikmeli_kayit, kaynak_zaman, alindi_zaman,
      arac_bilgi, musteri_ad, musteri_tel, notlar
    ) values (
      p_islem_id, v_plaka, v_zaman, v_tarife, v_abonman, v_yer,
      v_vardiya, auth.uid(), p_kaynak, p_foto,
      v_gecikmeli, case when p_kaynak = 'KAMERA' then p_zaman end, now(),
      v_arac, v_ad, v_tel, v_not
    ) returning id into v_id;
  exception when unique_violation then
    -- Which index fired is decided by LOOKING, not by trusting the diagnostic
    -- string: a row already carrying this islem_id is the definitive proof of
    -- a replay, and it stays correct if an index is ever renamed.
    select b.id into v_id from public.biletler b where b.islem_id = p_islem_id;
    if v_id is not null then
      -- Replay. Every ANPR camera retries a failed POST, and retry-on-blip
      -- retries from the phone: return the original, never a second ticket.
      return v_id;
    end if;

    get stacked diagnostics v_con = constraint_name;
    if v_con = 'biletler_acik_plaka_ux'
       or exists (select 1 from public.biletler b
                   where b.plaka = v_plaka and b.durum = 'ACIK') then
      raise exception 'Bu plaka için zaten açık bir bilet var: %', v_plaka;
    end if;
    -- 010: the advisory lock above should have turned this into the sentence
    -- already, so reaching here means something wrote a ticket outside
    -- bilet_ac. Still worth a Turkish message rather than a constraint name.
    if v_con = 'biletler_acik_yer_ux'
       or (v_yer is not null
           and exists (select 1 from public.biletler b
                        where b.park_yeri_id = v_yer and b.durum = 'ACIK')) then
      raise exception 'Bu park yerinde başka bir araç var. Başka bir yer seçin.';
    end if;
    raise;
  end;

  -- No points on a ₺0 stay: subscribers would otherwise farm rewards for
  -- parking they did not pay for.
  if coalesce(v_puan_aktif, false) and v_abonman is null then
    perform public.puan_kazandir(v_id, v_plaka);
  end if;

  return v_id;
end $$;

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
  if not (public.is_yonetici() or v_b.kapatan_vardiya_id = public.acik_vardiyam()) then
    raise exception 'Bu bileti tahsil etme yetkiniz yok.';
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

create or replace function public.kayip_bilet_tahsil(
  p_plaka         text,
  p_odeme_yontemi public.odeme_yontemi,
  p_islem_id      uuid
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plaka   text;
  v_t       public.tarifeler;
  v_now     timestamptz := now();
  v_vardiya uuid;
  v_id      uuid;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;

  v_plaka := public.normalize_plaka(p_plaka);
  if v_plaka !~ '^[A-Z0-9]{2,15}$' then
    raise exception 'Geçersiz plaka: %', coalesce(p_plaka, '(boş)');
  end if;

  select * into v_t from public.tarifeler where gecerli_bitis is null;
  if not found then
    raise exception 'Aktif tarife tanımlı değil.';
  end if;
  if v_t.kayip_bilet_kurus <= 0 then
    raise exception 'Kayıp bilet ücreti tanımlı değil. Tarifeden belirleyin.';
  end if;

  v_vardiya := public.acik_vardiyam();

  begin
    insert into public.biletler (
      islem_id, plaka, giris_at, cikis_at, tarife_id,
      ucret_kurus, tahsil_kurus, odeme_yontemi, durum,
      vardiya_id, kapatan_vardiya_id, giris_by, cikis_by,
      giris_kaynak, cikis_kaynak, kayip_bilet, alindi_zaman
    ) values (
      p_islem_id, v_plaka, v_now, v_now, v_t.id,
      v_t.kayip_bilet_kurus, v_t.kayip_bilet_kurus, p_odeme_yontemi, 'KAPALI',
      v_vardiya, v_vardiya, auth.uid(), auth.uid(),
      'MANUEL', 'MANUEL', true, v_now
    ) returning id into v_id;
  exception when unique_violation then
    select b.id into v_id from public.biletler b where b.islem_id = p_islem_id;
    if v_id is not null then
      return v_id;   -- replay
    end if;
    raise;
  end;

  insert into public.tahsilatlar (tur, bilet_id, tutar_kurus, yontem, vardiya_id, created_by, aciklama)
  values ('BILET', v_id, v_t.kayip_bilet_kurus, p_odeme_yontemi, v_vardiya, auth.uid(), 'Kayıp bilet');

  perform public.audit('kayip_bilet', 'biletler', v_id,
    jsonb_build_object('plaka', v_plaka, 'tutar', v_t.kayip_bilet_kurus));

  return v_id;
end $$;

-- --------------------------------------------------- otomatik açılış ------

-- Vardiyayı açmayı unutmak sessiz bir kayıptır: tahsilat yazılır ama hiçbir
-- vardiyaya bağlanmaz, dolayısıyla HİÇBİR sayımda görünmez. Seçilen saatte
-- kasa vardiyası kendiliğinden açılır.
--
-- `is_finance`/`is_staff` koruması KONULAMAZ: cron'da `auth.uid()` null'dır
-- ve guard her tikte patlardı. Tek koruma grant'tır — aşağıda PUBLIC'ten de
-- geri alınıyor (058 dersi: `anon, authenticated` tek başına hiçbir şey
-- kapatmaz, çünkü PostgreSQL yeni fonksiyona EXECUTE'u PUBLIC'e verir ve
-- `authenticated` PUBLIC üyesidir).
create or replace function public.run_vardiya_otomatik_ac() returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_saat  time;
  v_nakit integer;
  v_bugun date := (now() at time zone 'Europe/Istanbul')::date;
  v_id    uuid;
begin
  -- Üst üste binen iki tik aynı boşluğu görüp iki vardiya açmaya kalkmasın.
  -- `try_`: sıra biriktirmek yerine tik atlanır, 5 dakika sonra zaten koşar.
  if not pg_try_advisory_xact_lock(hashtext('vardiya_otomatik_ac')) then
    return;
  end if;

  select o.vardiya_otomatik_saat, o.vardiya_acilis_nakit_kurus
    into v_saat, v_nakit
    from public.otopark_ayarlari o where o.id = 1;

  if v_saat is null then
    return;                      -- özellik kapalı
  end if;

  -- EŞİK, pencere değil: gecikmiş ya da kaçmış bir tik günü kaybettirmez,
  -- iş kendi kendini onarır.
  if (now() at time zone 'Europe/Istanbul') < (v_bugun + v_saat) then
    return;
  end if;

  -- Açık vardiya varsa dokunma. Bugün zaten bir vardiya açılıp kapandıysa da
  -- ikincisini AÇMA: gün içinde elle kapatılan bir kasayı cron'un yeniden
  -- açması, sayımı biten çekmeceyi tekrar açık göstermek olurdu.
  if exists (
    select 1 from public.vardiyalar v
     where v.kapanis_at is null
        or (v.acilis_at at time zone 'Europe/Istanbul')::date = v_bugun
  ) then
    return;
  end if;

  begin
    insert into public.vardiyalar (personel_id, acilis_nakit_kurus, otomatik_acildi)
    values (null, coalesce(v_nakit, 0), true)
    returning id into v_id;
  exception when unique_violation then
    return;                      -- bu arada biri elle açtı
  end;

  perform public.audit('vardiya_otomatik_ac', 'vardiyalar', v_id,
    jsonb_build_object('saat', v_saat, 'acilis_nakit', coalesce(v_nakit, 0)));
end
$fn$;

revoke all on function public.run_vardiya_otomatik_ac() from public;
revoke all on function public.run_vardiya_otomatik_ac() from anon, authenticated;

-- ------------------------------------------------------------------ RLS ---

-- Vardiya artık kasaya ait, yani KAPANMIŞ vardiya = işletmenin nakit
-- geçmişi. Personel yalnızca açık vardiyayı görür (üstünde çalıştığı
-- çekmece); geçmiş Yöneticide kalır. Eskiden personel "kendi geçmiş
-- vardiyalarını" görüyordu — o satırlar artık kişisel değil.
drop policy if exists vardiyalar_select on public.vardiyalar;
create policy vardiyalar_select on public.vardiyalar for select to authenticated
  using (public.is_yonetici() or (public.is_staff() and kapanis_at is null));

-- Politika `acik_vardiyam()`in örtük kişi filtresine güveniyordu ve kendi
-- `is_staff()` kontrolü yoktu. Fonksiyona da eklendi; sınırın burada AÇIKÇA
-- durması gerekir, iki katman da tek başına yeterli olmalı.
drop policy if exists tahsilatlar_select on public.tahsilatlar;
create policy tahsilatlar_select on public.tahsilatlar for select to authenticated
  using (public.is_yonetici()
         or (public.is_staff() and vardiya_id = public.acik_vardiyam()));

-- ------------------------------------------------------------- zamanlama --

-- `otopark-vardiya` adı 025'te açık kalan vardiyayı kurtaran işe ait; bu
-- ayrı bir iş. */5: seçilen saatten sonra vardiyanın açılmasını 5 dakikadan
-- fazla bekletme — o boşlukta tahsil edilen nakit hiçbir sayıma girmez.
do $do$
begin
  perform cron.unschedule('otopark-vardiya-ac');
exception when others then null;
end
$do$;

select cron.schedule('otopark-vardiya-ac', '*/5 * * * *',
  $$select public.run_vardiya_otomatik_ac()$$);

-- ------------------------------------------------------------ doğrulama ---

do $do$
begin
  if exists (select 1 from pg_indexes
              where schemaname = 'public' and indexname = 'vardiyalar_acik_ux') then
    raise exception 'DOĞRULAMA: kişi başına açık vardiya indeksi hâlâ duruyor.';
  end if;
  if not exists (select 1 from pg_indexes
                  where schemaname = 'public' and indexname = 'vardiyalar_tek_acik_ux') then
    raise exception 'DOĞRULAMA: kasa başına tek açık vardiya indeksi kurulmadı.';
  end if;
  if (select count(*) from public.vardiyalar where kapanis_at is null) > 1 then
    raise exception 'DOĞRULAMA: birden fazla açık vardiya kaldı.';
  end if;
  if (select a.attnotnull from pg_attribute a
       where a.attrelid = 'public.vardiyalar'::regclass and a.attname = 'personel_id') then
    raise exception 'DOĞRULAMA: personel_id hâlâ NOT NULL — otomatik açılış yazamaz.';
  end if;
  if has_function_privilege('authenticated', 'public.run_vardiya_otomatik_ac()', 'execute')
     or has_function_privilege('anon', 'public.run_vardiya_otomatik_ac()', 'execute') then
    raise exception 'DOĞRULAMA: otomatik açılış işi istemciden çağrılabiliyor.';
  end if;
end
$do$;

commit;
