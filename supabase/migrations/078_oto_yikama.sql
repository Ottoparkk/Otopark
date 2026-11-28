-- =====================================================================
-- 078  Oto yıkama
-- =====================================================================
-- Sahibin isteği (27.11.2026): otoparkta oto yıkama da var. Yönetici
-- yıkama ücretini tarifeye girer; personel bilete yıkamayı Giriş'te, bilet
-- detayında (Hizmetler) ya da Tahsilat'ta ekler. Ücreti sunucu hesaplar.
--
--   * tarifeler.yikama_kurus  — boş = yıkama yok (düğme görünmez).
--   * biletler.yikama_kurus   — eklendiği andaki fiyat, bilete KİLİTLİ: sonraki
--     tarife değişikliği dokunmaz (içerideki araç girdiği fiyatı korur gibi).
--   * biletler.yikama_at      — ne zaman eklendi. Kimin eklediği denetim
--     kaydında: bilete `yikama_by` + `on delete set null` yazmak, kapanmış
--     bilette biletler_immutable_guard'ı tetiklerdi.
--   * bilet_ucreti(bilet, çıkış) — otopark (abonmanda 0) + yıkama. Bileti
--     fiyatlayan her yer bunu çağırır: bilet_kapat, kamera_cikis_bildir,
--     acik_bilet_ara, yeni önizleme ve ücretsiz çıkışın "bağışlanan" tutarı.
--     Ücretsiz çıkış ücreti 0 yazar, yani yıkamayı da bağışlar (sahip onayladı).
--   * Kamera yıkama eklemez; yalnızca insan (bilet_yikama).
-- Smoke test: PASS 100–103.

begin;

-- ------------------------------------------------------------- sütunlar ---
alter table public.tarifeler
  add column if not exists yikama_kurus integer
    check (yikama_kurus is null or yikama_kurus > 0);

alter table public.biletler
  add column if not exists yikama_kurus integer
    check (yikama_kurus is null or yikama_kurus > 0),
  add column if not exists yikama_at timestamptz;

-- ------------------------------------------------------- tek fiyat yeri ---
-- İç fonksiyon: yalnızca SECURITY DEFINER fonksiyonların içinden çağrılır,
-- kimseye yetki verilmez (ücreti istemci değil sunucu hesaplar).
create or replace function public.bilet_ucreti(p_b public.biletler, p_cikis timestamptz)
returns integer
language sql stable set search_path = public as $$
  select (case when p_b.abonman_id is not null then 0
               else public.ucret_hesapla(p_b.giris_at, p_cikis, p_b.tarife_id) end)
         + coalesce(p_b.yikama_kurus, 0);
$$;

-- -------------------------------------------------------- tarife (051) ----
-- 051'in gövdesi birebir + en sonda varsayılanlı `p_yikama_kurus`. İmza
-- değiştiği için eski 8 argümanlı sürüm düşürülür (051 aynı deseni izledi);
-- mevcut 5, 7 ve 8 argümanlı çağrılar aynen çalışır.
drop function if exists public.tarife_guncelle(integer, integer, integer, integer, integer,
                                               public.tarife_tur, integer, jsonb);

create or replace function public.tarife_guncelle(
  p_ucretsiz_dakika    integer,
  p_ilk_saat_kurus     integer,
  p_sonraki_saat_kurus integer,
  p_gunluk_tavan_kurus integer,
  p_kayip_bilet_kurus  integer,
  p_tur                public.tarife_tur default 'SURELI',
  p_sabit_kurus        integer default 0,
  p_kademeler          jsonb default null,
  p_yikama_kurus       integer default null                       -- 078
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_kesim    timestamptz;
  v_id       uuid;
  v_kademeli boolean := (p_tur::text = 'KADEMELI');
  v_sabit    boolean := (p_tur::text = 'SABIT');
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici tarife değiştirebilir.';
  end if;

  -- Sunucu tarafı sınır: istemcideki doğrulama yalnızca mesaj içindir.
  if v_sabit and coalesce(p_sabit_kurus, 0) <= 0 then
    raise exception 'Sabit tarifede ücret sıfırdan büyük olmalı.';
  end if;
  -- 078: boş = yıkama yok; girilirse sıfırdan büyük.
  if p_yikama_kurus is not null and p_yikama_kurus <= 0 then
    raise exception 'Oto yıkama ücreti sıfırdan büyük olmalı (ya da boş bırakılmalı).';
  end if;
  if v_kademeli and not public.kademeler_gecerli(p_kademeler) then
    raise exception 'Kademe listesi geçersiz: kademeler artan sırada, son kademe 24 saatte bitmeli ve ücretler azalmamalı.';
  end if;

  -- Two concurrent edits must not both close the current row and race to
  -- insert; the partial unique index would refuse the loser with a confusing
  -- error instead of simply serialising.
  perform pg_advisory_xact_lock(hashtext('tarife'));

  select greatest(now(), t.gecerli_baslangic + interval '1 millisecond')
    into v_kesim
    from public.tarifeler t
   where t.gecerli_bitis is null;
  v_kesim := coalesce(v_kesim, now());

  update public.tarifeler set gecerli_bitis = v_kesim
   where gecerli_bitis is null;

  -- Kullanılmayan alanlar sıfırlanır: saklanan ama kullanılmayan bir sayı
  -- ileride "acaba bu mu geçerliydi" sorusunu doğurur (013). Kademe listesi
  -- yalnızca kademeli tarifede yazılır.
  insert into public.tarifeler (
    ucretsiz_dakika, ilk_saat_kurus, sonraki_saat_kurus,
    gunluk_tavan_kurus, kayip_bilet_kurus, tur, sabit_kurus, kademeler,
    gecerli_baslangic, olusturan, yikama_kurus)
  values (
    p_ucretsiz_dakika,
    case when v_sabit or v_kademeli then 0 else p_ilk_saat_kurus end,
    case when v_sabit or v_kademeli then 0 else p_sonraki_saat_kurus end,
    case when v_sabit or v_kademeli then 0 else p_gunluk_tavan_kurus end,
    p_kayip_bilet_kurus,
    p_tur,
    case when v_sabit then p_sabit_kurus else 0 end,
    case when v_kademeli then p_kademeler else null end,
    v_kesim, auth.uid(), p_yikama_kurus)
  returning id into v_id;

  perform public.audit('tarife_guncelle', 'tarifeler', v_id,
    jsonb_build_object('tur', p_tur,
                       'sabit', p_sabit_kurus,
                       'ilk_saat', p_ilk_saat_kurus,
                       'sonraki_saat', p_sonraki_saat_kurus,
                       'gunluk_tavan', p_gunluk_tavan_kurus,
                       'kademeler', case when v_kademeli then p_kademeler end,
                       'yikama', p_yikama_kurus));
  return v_id;
end $$;

-- ------------------------------------------------- yıkama ekle / kaldır ---
-- Personel ve Yönetici, yalnızca bilet AÇIKken. Ekleme: zaten ekliyse aynı
-- fiyat döner (çift dokunuş fiyatı yenilemez). Kaldırma: kullanılmış puan
-- yıkamasız ücretten fazlaysa reddedilir (bilet_kapat'ın kuralı).
create or replace function public.bilet_yikama(p_bilet_id uuid, p_acik boolean)
returns integer
language plpgsql security definer set search_path = public as $$
declare
  v_b     public.biletler;
  v_yeni  public.biletler;
  v_fiyat integer;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception 'Bilet açık değil; yıkama yalnızca araç içerideyken değiştirilebilir.';
  end if;

  if p_acik then
    if v_b.yikama_kurus is not null then
      return v_b.yikama_kurus;
    end if;
    select t.yikama_kurus into v_fiyat
      from public.tarifeler t where t.gecerli_bitis is null;
    if v_fiyat is null then
      raise exception 'Oto yıkama ücreti tarifede tanımlı değil.';
    end if;
    update public.biletler set yikama_kurus = v_fiyat, yikama_at = now()
     where id = p_bilet_id;
  else
    if v_b.yikama_kurus is null then
      return null;
    end if;
    v_yeni := v_b;
    v_yeni.yikama_kurus := null;
    if v_b.indirim_kurus > public.bilet_ucreti(v_yeni, now()) then
      raise exception 'Kullanılan puan ücretten fazla. Önce puan kullanımını geri alın.';
    end if;
    v_fiyat := null;
    update public.biletler set yikama_kurus = null, yikama_at = null
     where id = p_bilet_id;
  end if;

  perform public.audit('bilet_yikama', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'acik', p_acik,
                       'kurus', coalesce(v_fiyat, v_b.yikama_kurus)));
  return v_fiyat;
end $$;

-- ------------------------------------------------- ücret önizlemesi -------
-- Tahsilat ve bilet detayındaki canlı ücret: bilet_kapat'ın kullandığı aynı
-- hesap. Açık olmayan bilet için null (kapanmışın ücreti bilette yazılı).
create or replace function public.bilet_ucret_onizle(p_bilet_id uuid)
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
  return public.bilet_ucreti(v_b, now());
end $$;

-- ------------------------------------------------------ bilet_kapat (030) --
-- 030'un gövdesi birebir; yalnızca ücret satırı bilet_ucreti oldu. Aynı
-- imza: `create or replace` mevcut yetkileri korur.
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

-- --------------------------------------------- kamera_cikis_bildir (054) --
-- 054'ün gövdesi birebir; yalnızca ücret satırı bilet_ucreti oldu. Kamera
-- yıkamalı bileti de ödemesiz kapatır: borç otopark + yıkama.
create or replace function public.kamera_cikis_bildir(
  p_plaka    text,
  p_islem_id uuid,
  p_zaman    timestamptz,
  p_foto     text default null,
  p_ham      jsonb default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plaka    text;
  v_limit_dk integer;
  v_id       uuid;
  v_adaylar  uuid[];
  v_kuyruk   text;
  v_b        public.biletler;
  v_ucret    integer;
  v_net      integer;
  v_vardiya  uuid;
  v_sebep    text;
  v_cikis_dk integer;
begin
  -- 054: yalnızca kamera (eskiden `is_staff() or auth.uid() is null`).
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_zaman is null then
    raise exception 'Kamera kaydı zaman damgası olmadan kabul edilmez.';
  end if;

  v_plaka := public.normalize_plaka(p_plaka);

  -- 054: tek kapının "çıkıştan sonra" süresi (048) burada da aynı çıkışın
  -- penceresidir: tekrar gelen çıkış ve az önce geri açılan bilet.
  select o.kamera_gecikme_limiti_dk, o.tek_kapi_cikis_yoksay_dk
    into v_limit_dk, v_cikis_dk
    from public.otopark_ayarlari o where o.id = 1;
  v_limit_dk := coalesce(v_limit_dk, 720);
  v_cikis_dk := coalesce(v_cikis_dk, 5);

  if p_zaman > now() + interval '5 minutes' then
    perform public.istisna_yaz('GELECEK', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                               p_ham, p_foto, p_zaman);
    return null;
  end if;
  if p_zaman < now() - make_interval(mins => v_limit_dk) then
    perform public.istisna_yaz('BAYAT', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                               p_ham, p_foto, p_zaman);
    return null;
  end if;

  select b.id into v_id from public.biletler b
   where b.durum = 'ACIK' and b.plaka = v_plaka;

  if v_id is null then
    -- 054: aynı çıkış yeniden geldi (iki şeritli CIKIS kapısı: cevap kayboldu
    -- ve köprü tekrar gönderdi, ya da aynı aracın ikinci karesi). Bilet zaten
    -- kameranın kapattığı; "açık bilet yok" kaydı ve uyarısı yanlış olurdu.
    -- Tek kapı bunu 2. adımında zaten yok sayar (048) — aynı pencere.
    select b.id into v_id from public.biletler b
     where b.plaka = v_plaka and b.durum = 'KAPALI' and b.cikis_kaynak = 'KAMERA'
       and p_zaman between b.cikis_at - make_interval(mins => v_cikis_dk)
                       and b.cikis_at + make_interval(mins => v_cikis_dk)
     order by b.cikis_at desc
     limit 1;
    if v_id is not null then
      return v_id;
    end if;

    v_kuyruk := right(v_plaka, 4);
    if length(v_kuyruk) = 4 then
      select array_agg(b.id) into v_adaylar from public.biletler b
       where b.durum = 'ACIK' and right(b.plaka, 4) = v_kuyruk;
    end if;

    if v_adaylar is null or array_length(v_adaylar, 1) is null then
      perform public.istisna_yaz('ACIK_BILET_YOK', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                                 p_ham, p_foto, p_zaman);
      return null;
    end if;
    -- 054: benzer plaka tahmin edilmez — tek aday da olsa insana gider.
    perform public.istisna_yaz('COKLU_ESLESME', 'CIKIS', v_plaka, 'KAMERA', p_islem_id,
                               p_ham, p_foto, p_zaman, v_adaylar);
    return null;
  end if;

  -- 054: bileti kapat (ödemesiz). Ücret 030'un `bilet_kapat` kuralıyla aynı,
  -- yalnızca saat OLAYIN saati.
  select * into v_b from public.biletler where id = v_id for update;
  -- Kilidi beklerken biri bileti kapattı ya da iptal etti: 002'deki gibi
  -- hiçbir şey yazılmaz (ne denetim ne "ödeme bekliyor" bildirimi).
  if v_b.durum <> 'ACIK' then
    return v_id;
  end if;

  -- Kapatılamayan çıkışlar ÖNCE: ucret_hesapla girişten önceki bir çıkışta
  -- hata verir ("Çıkış zamanı girişten önce olamaz") ve tüm olayı düşürürdü.
  if p_zaman < v_b.giris_at then
    v_sebep := 'çıkış saati girişten önce';
  elsif exists (select 1 from public.audit_log a
                 where a.tablo = 'biletler' and a.row_id = v_id
                   and a.action = 'bilet_kamera_geri_acildi'
                   and a.created_at >= p_zaman - make_interval(mins => v_cikis_dk)) then
    -- Personel az önce "Araç çıkmadı" dedi; araç hâlâ kameranın önünde
    -- olabilir. Kamera aynı anda tersini söyleyemez: insan karar verir.
    v_sebep := 'az önce "Araç çıkmadı" denildi';
  else
    -- 078: otopark (abonmanda 0) + oto yıkama, tek yerden.
    v_ucret := public.bilet_ucreti(v_b, p_zaman);
    if v_b.indirim_kurus > v_ucret then
      v_sebep := 'kullanılan puan ücretten fazla';
    end if;
  end if;

  if v_sebep is not null then
    -- Kapatılamaz: eskisi gibi yalnızca damga; insan karar verir.
    update public.biletler
       set cikis_bekliyor_at = p_zaman, cikis_foto = coalesce(cikis_foto, p_foto)
     where id = v_id and durum = 'ACIK';
    perform public.notify_yonetici('KAMERA_HAREKET', 'Araç çıkış yaptı',
      v_b.plaka || ' — bilet kendiliğinden kapatılamadı (' || v_sebep
        || '); çıkışı elle yapın.',
      '/gise/bilet/' || v_id);
    return v_id;
  end if;

  v_net := v_ucret - v_b.indirim_kurus;

  -- Açık kasa vardiyası (030: kasa başına tek). `acik_vardiyam()` burada
  -- kullanılamaz: is_staff() ister, kamerada auth.uid() boştur.
  select v.id into v_vardiya from public.vardiyalar v
   where v.kapanis_at is null
   limit 1;

  update public.biletler set
    cikis_at           = p_zaman,
    ucret_kurus        = v_ucret,
    tahsil_kurus       = 0,
    odeme_yontemi      = null,
    durum              = 'KAPALI',
    cikis_by           = null,
    cikis_kaynak       = 'KAMERA',
    cikis_foto         = coalesce(p_foto, v_b.cikis_foto),
    cikis_bekliyor_at  = p_zaman,
    kapatan_vardiya_id = v_vardiya
  where id = v_id and durum = 'ACIK';

  perform public.audit('bilet_kamera_kapatti', 'biletler', v_id,
    jsonb_build_object('plaka', v_b.plaka, 'ucret', v_ucret, 'borc', v_net,
                       'zaman', p_zaman, 'vardiya', v_vardiya));

  if v_net > 0 then
    if v_vardiya is not null then
      perform public.notify_herkes('ODEME_BEKLIYOR', 'Araç çıktı — ödeme bekliyor',
        v_b.plaka || ' · ' || (v_net / 100.0)::numeric(12,2) || ' ₺',
        '/gise/bilet/' || v_id);
    else
      perform public.notify_yonetici('ODEME_BEKLIYOR', 'Araç çıktı — ödeme bekliyor',
        v_b.plaka || ' · ' || (v_net / 100.0)::numeric(12,2)
          || ' ₺ (açık vardiya yoktu)',
        '/gise/bilet/' || v_id);
    end if;
  end if;

  return v_id;
end $$;

-- ------------------------------------------- bilet_ucretsiz_cikis (066) --
-- 066'nın gövdesi birebir; yalnızca açık biletin "bağışlanan" ücreti
-- bilet_ucreti oldu. Yıkamalı bir araç ücretsiz çıkınca bağışlanan 150 ₺
-- da "ücret değişti" bayrağına ve denetime yazılır (ücretsiz sürede bile).
create or replace function public.bilet_ucretsiz_cikis(
  p_bilet_id uuid,
  p_sebep    public.ucretsiz_sebep,
  p_not      text
) returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_b          public.biletler;
  v_not        text := btrim(coalesce(p_not, ''));
  v_etiket     text;
  v_hesaplanan integer;
  v_ad         text;
  v_sonradan   boolean := false;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_sebep is null then
    raise exception 'Sebep seçin.';
  end if;
  if v_not = '' then
    raise exception 'Not zorunludur.';
  end if;
  if char_length(v_not) > 200 then
    raise exception 'Not en fazla 200 karakter olabilir.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;

  v_etiket := public.ucretsiz_etiket(p_sebep);

  if v_b.durum = 'ACIK' then
    -- Puanla düşülmüş bir ücret "ücretsiz" olamaz: önce puan geri alınır
    -- (müşterinin puanı geri döner), sonra ücretsiz çıkış.
    if v_b.indirim_kurus > 0 then
      raise exception 'Önce kullanılan puanı geri alın.';
    end if;

    -- Bağışlanan ücret: denetime ve "ücret değişti" bayrağına yazılır.
    -- 078: bağışlanan = otopark (abonmanda 0) + oto yıkama.
    v_hesaplanan := public.bilet_ucreti(v_b, now());

    update public.biletler set
      cikis_at           = now(),
      ucret_kurus        = 0,
      tahsil_kurus       = 0,
      odeme_yontemi      = null,
      durum              = 'KAPALI',
      cikis_by           = auth.uid(),
      cikis_kaynak       = 'MOBIL',
      kapatan_vardiya_id = public.acik_vardiyam(),
      ucretsiz_sebep     = p_sebep,
      ucretsiz_not       = v_not,
      ucretsiz_by        = auth.uid(),
      ucretsiz_at        = now(),
      ucret_degistirildi = v_hesaplanan > 0,
      ucret_sebep        = case when v_hesaplanan > 0
                                then 'Ücretsiz çıkış — ' || v_etiket || ': ' || v_not
                                else v_b.ucret_sebep end
    where id = p_bilet_id;

  elsif v_b.durum = 'KAPALI' then
    -- 066: araç çıkmış, ücret borç olarak duruyor. Okuma/tahsil yolundaki
    -- yetkinin aynısı (034): Yönetici ya da bileti kendi açık vardiyasında
    -- kapatan Personel.
    if not (public.is_yonetici()
            or coalesce(v_b.kapatan_vardiya_id = public.acik_vardiyam(), false)) then
      raise exception 'Bu bileti ücretsiz yapma yetkiniz yok.';
    end if;
    if v_b.ucretsiz_sebep is not null then
      raise exception 'Bu bilete zaten ücretsiz çıkış verilmiş.';
    end if;
    -- Kapalı bilette puan geri alınamaz; kısmen puanla ödenmiş bir ücret
    -- "ücretsiz" sayılmaz.
    if v_b.indirim_kurus > 0 then
      raise exception 'Puan kullanılmış bir bilet ücretsiz yapılamaz.';
    end if;
    -- Reddedilen satır sayılmaz (028): red "para gelmedi" demek.
    if v_b.tahsil_kurus <> 0
       or exists (select 1 from public.tahsilatlar t
                   where t.bilet_id = p_bilet_id
                     and t.iptal_of is null
                     and t.durum <> 'REDDEDILDI') then
      raise exception 'Bu biletin ödemesi zaten alınmış.';
    end if;
    if v_b.ucret_kurus - v_b.indirim_kurus <= 0 then
      raise exception 'Bu bilette alınacak ücret yok.';
    end if;

    v_hesaplanan := v_b.ucret_kurus;
    v_sonradan   := true;

    perform set_config('app.bilet_ucretsiz', p_bilet_id::text, true);
    update public.biletler set
      ucret_kurus        = 0,
      ucret_degistirildi = true,
      ucret_sebep        = 'Ücretsiz çıkış — ' || v_etiket || ': ' || v_not,
      ucretsiz_sebep     = p_sebep,
      ucretsiz_not       = v_not,
      ucretsiz_by        = auth.uid(),
      ucretsiz_at        = now()
    where id = p_bilet_id;
    perform set_config('app.bilet_ucretsiz', '', true);

  else
    raise exception 'Bu bilet zaten kapatılmış veya iptal edilmiş.';
  end if;

  -- Ücretsiz kalışa puan kazandırılmaz (030'un abonman kuralıyla aynı
  -- gerekçe): girişte kazanılan puan, bilet_iptal (050) gibi karşı kayıtla
  -- geri alınır — silinmez.
  insert into public.puan_hareketleri (hesap_id, tur, puan, bilet_id, kural_id, created_by, aciklama)
  select ph.hesap_id, 'IPTAL', -ph.puan, ph.bilet_id, ph.kural_id, auth.uid(), 'Ücretsiz çıkış'
    from public.puan_hareketleri ph
   where ph.bilet_id = p_bilet_id and ph.tur = 'KAZANIM';

  perform public.audit('bilet_ucretsiz_cikis', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'sebep', p_sebep, 'not', v_not,
                       'hesaplanan', v_hesaplanan, 'sonradan', v_sonradan));

  -- Yönetici'ye adıyla (notify_yonetici çağıranı atlar: Yönetici kendine
  -- bildirim almaz).
  select ad_soyad into v_ad from public.profiles where id = auth.uid();
  perform public.notify_yonetici('UCRETSIZ_CIKIS', 'Ücretsiz çıkış',
    coalesce(v_ad, 'Bilinmeyen kullanıcı') || ' ücretsiz çıkış verdi: '
      || v_b.plaka || ' · ' || v_etiket || ' — ' || v_not,
    '/gise/bilet/' || p_bilet_id);
end
$fn$;

-- ----------------------------------------------- acik_bilet_ara (077) ----
-- 077'nin gövdesi birebir + `yikama_kurus`; ücret bilet_ucreti. Dönüş tipi
-- değiştiği için düşürülür, yeniden yazılır, yetkiler yeniden.
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
  yikama_kurus integer                                             -- 078
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
         b.yikama_kurus
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

-- ---------------------------------------------------------------- yetki ---
revoke all on function public.bilet_ucreti(public.biletler, timestamptz) from public;
revoke all on function public.bilet_ucreti(public.biletler, timestamptz)
  from anon, authenticated, service_role;

revoke all on function
  public.tarife_guncelle(integer, integer, integer, integer, integer,
                         public.tarife_tur, integer, jsonb, integer)
  from public, anon, authenticated, service_role;
grant execute on function
  public.tarife_guncelle(integer, integer, integer, integer, integer,
                         public.tarife_tur, integer, jsonb, integer)
  to authenticated;

revoke all on function public.bilet_yikama(uuid, boolean) from public;
revoke all on function public.bilet_yikama(uuid, boolean) from anon, authenticated, service_role;
grant execute on function public.bilet_yikama(uuid, boolean) to authenticated;

revoke all on function public.bilet_ucret_onizle(uuid) from public;
revoke all on function public.bilet_ucret_onizle(uuid) from anon, authenticated, service_role;
grant execute on function public.bilet_ucret_onizle(uuid) to authenticated;

revoke all on function public.acik_bilet_ara(text) from public;
revoke all on function public.acik_bilet_ara(text) from anon, authenticated, service_role;
grant execute on function public.acik_bilet_ara(text) to authenticated;

do $$
declare
  f_ucret  constant text := 'public.bilet_ucreti(public.biletler, timestamptz)';
  f_tarife constant text := 'public.tarife_guncelle(integer, integer, integer, integer, integer, public.tarife_tur, integer, jsonb, integer)';
  f_yikama constant text := 'public.bilet_yikama(uuid, boolean)';
  f_onizle constant text := 'public.bilet_ucret_onizle(uuid)';
  f_ara    constant text := 'public.acik_bilet_ara(text)';
  f_ucz    constant text := 'public.bilet_ucretsiz_cikis(uuid, public.ucretsiz_sebep, text)';
  f text;
begin
  if has_function_privilege('authenticated', f_ucret, 'execute')
     or has_function_privilege('anon', f_ucret, 'execute')
     or has_function_privilege('service_role', f_ucret, 'execute') then
    raise exception '078: bilet_ucreti kimseye açık olmamalı';
  end if;
  foreach f in array array[f_tarife, f_yikama, f_onizle, f_ara, f_ucz] loop
    if not has_function_privilege('authenticated', f, 'execute')
       or has_function_privilege('anon', f, 'execute')
       or has_function_privilege('service_role', f, 'execute') then
      raise exception '078: % yalnızca authenticated için olmalı', f;
    end if;
  end loop;
  if to_regprocedure('public.tarife_guncelle(integer, integer, integer, integer, integer, public.tarife_tur, integer, jsonb)') is not null then
    raise exception '078: eski tarife_guncelle imzası düşmedi';
  end if;
end $$;

commit;
