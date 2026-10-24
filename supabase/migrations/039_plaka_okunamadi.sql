-- ============================================================================
-- 039  Okunamayan plaka ve çöken okuma servisi: araç sessizce kaybolmasın
-- ============================================================================

alter type public.istisna_tur add value if not exists 'OKUNAMADI';

begin;

-- 019 dersi: yukarıda eklenen enum değeri bu dosyada HİÇBİR YERDE enum
-- literali olarak çalıştırılmıyor. SQL editörü dosyanın tamamını tek
-- transaction'da koşar; değer yalnızca plpgsql gövdelerinde geçiyor (ilk
-- çağrıda, yani commit'ten sonra çözülür), doğrulama pg_enum'dan okuyor.

-- ----------------------------------------------------------- okunamadı ----

-- Model fotoğrafta bir ARAÇ gördü ama plakasını güvenle okuyamadı. Eskiden
-- kamera-webhook 422 dönüyordu ve tek iz okuma günlüğündeki satırdı: giriş
-- kapısından geçen araç biletsiz içeri giriyor, kimse bunu bilmiyordu.
--
-- Yalnızca GIRIS ve ORTAK şeridi: çıkış kapısında para zaten insanda, araç
-- orada görülüyor. Tek kapıda (037) aracın girdiği mi çıktığı mı bilinmez;
-- kayıt bunu söyler, karar insanındır.
--
-- `istisna_yaz` (002) islem_id'de tekilleştirir ve Yöneticiye her zamanki
-- "Çözülmemiş kayıt" bildirimini gönderir. Köprü 422'yi YENİDEN DENEMEZ, yani
-- bu çağrı bir olay için bir kez gelir.
--
-- Fotoğraf ham yanıtta SAKLANMAZ: köprünün gövdesi `foto_base64` taşır ve
-- her satırı yüzlerce KB yapardı (Çözülmemiş kayıtlar ekranı `*` seçer).
-- Kendi anahtarlarımız SONA yazılır ki gövdedeki aynı adlı bir alan onları
-- ezemesin.
create or replace function public.kamera_okunamadi(
  p_yon      text,
  p_islem_id uuid,
  p_zaman    timestamptz,
  p_tahmin   text    default null,
  p_guven    numeric default null,
  p_ham      jsonb   default null
) returns uuid
language plpgsql security definer set search_path = public as $fn$
declare
  v_yon text := upper(btrim(coalesce(p_yon, '')));
  v_ham jsonb;
begin
  -- is_staff() guard'ı YOK ve olamaz (webhook'ta auth.uid() null). Tersi var:
  -- JWT taşıyan çağıran reddedilir. Asıl sınır grant'tır (037 deseni).
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.';
  end if;
  if v_yon not in ('GIRIS', 'ORTAK') then
    raise exception 'Okunamayan plaka kaydı yalnızca giriş ve tek kapı şeridinde yazılır.';
  end if;
  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;
  if p_zaman is null then
    raise exception 'Kamera kaydı zaman damgası olmadan kabul edilmez.';
  end if;

  v_ham := case when jsonb_typeof(p_ham) = 'object'
                then p_ham - 'foto_base64' else '{}'::jsonb end
        || jsonb_build_object('tahmin', left(nullif(btrim(p_tahmin), ''), 32),
                              'guven', p_guven);

  return public.istisna_yaz('OKUNAMADI', v_yon, null, 'KAMERA', p_islem_id,
                            v_ham, null, p_zaman);
end
$fn$;

-- ------------------------------------------------------ okuma hatası -----

-- Okuma servisi CEVAP VEREMEDİ: Anthropic bakiyesi bitti, anahtar
-- geçersizleşti, servis çöktü. Eskiden her araçta 502 dönüyordu ve tek iz
-- okuma günlüğündeki bir satırdı. Köprünün kalp atışı sürdüğü için "kameradan
-- haber yok" uyarısı da susuyordu: BÜTÜN kamera girişleri kimse bilmeden
-- duruyordu.
--
-- İki ayrı iş:
--   · Uyarı — her hatada, her şeritte, ama saatte EN FAZLA bir kez. Danışma
--     kilidi, aynı anda gelen iki hatanın ikisinin de "henüz uyarılmadı"
--     okuyup iki uyarı göndermesini engeller.
--   · Araç başına kayıt — YALNIZCA köprünün son denemesinde
--     (`p_son_gonderim`, köprü 1.2.1'in `x-kamera-son-gonderim` başlığı) ve
--     yalnızca GIRIS/ORTAK şeridinde. Son deneme dışında yazılmaz, çünkü
--     köprü aynı islem_id ile yeniden dener ve kamera_tek_kapi (037) kaydı
--     olan bir islem_id'yi "ISTISNA TEKRAR" diye kısa keser: erken yazılmış
--     bir kayıt, başarılı bir yeniden denemenin biletini engellerdi.
--     Bildirimsiz yazılır (istisna_yaz DEĞİL): bir arıza yüz araç demektir ve
--     yüz bildirim, saatlik tek uyarıyı boğardı.
create or replace function public.kamera_okuma_hatasi(
  p_yon          text,
  p_islem_id     uuid,
  p_zaman        timestamptz,
  p_hata         text,
  p_son_gonderim boolean,
  p_ham          jsonb default null
) returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_yon  text := upper(btrim(coalesce(p_yon, '')));
  v_hata text := left(coalesce(nullif(btrim(p_hata), ''), 'bilinmeyen hata'), 300);
begin
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.';
  end if;
  if v_yon not in ('GIRIS', 'CIKIS', 'ORTAK') then
    raise exception 'Şerit GIRIS, CIKIS ya da ORTAK olmalı.';
  end if;
  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;
  if p_zaman is null then
    raise exception 'Kamera kaydı zaman damgası olmadan kabul edilmez.';
  end if;

  perform pg_advisory_xact_lock(hashtext('kamera_okuma_hatasi'));

  if not exists (
    select 1 from public.notifications n
     where n.tur = 'KAMERA' and n.baslik = 'Plaka okuma çalışmıyor'
       and n.created_at > now() - interval '60 minutes'
  ) then
    perform public.notify_yonetici(
      'KAMERA', 'Plaka okuma çalışmıyor',
      'Kamera fotoğrafları okunamıyor: ' || left(v_hata, 160)
        || '. Anthropic bakiyesini ve ANTHROPIC_API_KEY ayarını kontrol edin; '
        || 'düzelene kadar kameradan gelen araçları elle girin.',
      '/istisnalar');
  end if;

  if coalesce(p_son_gonderim, false) and v_yon in ('GIRIS', 'ORTAK') then
    insert into public.istisnalar (
      tur, yon, plaka, kaynak, islem_id, ham_yanit, foto_path, kaynak_zaman)
    values (
      'OKUNAMADI', v_yon, null, 'KAMERA', p_islem_id,
      case when jsonb_typeof(p_ham) = 'object'
           then p_ham - 'foto_base64' else '{}'::jsonb end
        || jsonb_build_object('hata', v_hata),
      null, p_zaman)
    on conflict (islem_id) where islem_id is not null do nothing;
  end if;
end
$fn$;

-- -------------------------------------------------------------- yetki -----

-- from public OLMADAN hiçbir şey kapanmaz (012); service_role'e AÇIKÇA verilir
-- (033). İstemciye açık olsalardı herkes sahte "okunamadı" kaydı ya da sahte
-- "okuma çalışmıyor" uyarısı üretebilirdi.
revoke all on function public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)
  from public;
revoke all on function public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)
  from anon, authenticated, service_role;
grant execute on function public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)
  to service_role;

revoke all on function public.kamera_okuma_hatasi(text, uuid, timestamptz, text, boolean, jsonb)
  from public;
revoke all on function public.kamera_okuma_hatasi(text, uuid, timestamptz, text, boolean, jsonb)
  from anon, authenticated, service_role;
grant execute on function public.kamera_okuma_hatasi(text, uuid, timestamptz, text, boolean, jsonb)
  to service_role;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  f text;
  r text;
begin
  if not exists (
    select 1 from pg_enum e join pg_type ty on ty.oid = e.enumtypid
     where ty.typname = 'istisna_tur' and e.enumlabel = 'OKUNAMADI'
  ) then
    raise exception '039: OKUNAMADI enum değeri eklenmedi';
  end if;

  -- Tek kapı kaydı yazılabilmeli (037 kısıtı).
  if not exists (
    select 1 from pg_constraint con
     where con.conrelid = 'public.istisnalar'::regclass and con.contype = 'c'
       and pg_get_constraintdef(con.oid) like '%yon%ORTAK%'
  ) then
    raise exception '039: istisnalar.yon kısıtı ORTAK şeridini tanımıyor';
  end if;

  foreach f in array array[
    'public.kamera_okunamadi(text, uuid, timestamptz, text, numeric, jsonb)',
    'public.kamera_okuma_hatasi(text, uuid, timestamptz, text, boolean, jsonb)'
  ] loop
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception '039: % service_role rolüne kapalı — webhook çağıramaz', f;
    end if;
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception '039: % % rolüne açık', f, r;
      end if;
    end loop;
  end loop;

  if (select count(*) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('kamera_okunamadi', 'kamera_okuma_hatasi')
         and p.prosecdef
         and p.proconfig @> array['search_path=public']) <> 2 then
    raise exception '039: fonksiyonlar SECURITY DEFINER + search_path=public değil';
  end if;
end
$do$;

commit;
