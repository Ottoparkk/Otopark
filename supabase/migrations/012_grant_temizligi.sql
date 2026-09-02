-- ============================================================================
-- 012  EXECUTE temizliği — Supabase'in varsayılan yetkileri
-- ============================================================================
--
-- 009 kendi doğrulama bloğunda patladı:
--
--     ERROR: 009: yer_mesgul istemciye açık
--
-- ve haklıydı. Sebep, 006–011'in hepsinde tekrarlanan tek bir yanlış varsayım:
--
--   `revoke all on function ... from public` YETMEZ.
--
-- İKİ ayrı yol vardır ve ikisi de kapatılmalıdır:
--
--   1. PostgreSQL yeni bir fonksiyona EXECUTE'u PUBLIC'e verir. `from public`
--      bunu kapatır. 058 dersinin (PilotGarage) anlattığı yol budur ve
--      006–011 yalnızca bunu biliyordu.
--
--   2. Supabase, `public` şemasında oluşturulan HER fonksiyon için
--      `anon`, `authenticated` ve `service_role` rollerine **doğrudan**
--      EXECUTE verir (proje kurulumundaki `alter default privileges`).
--      Doğrudan verilen yetki, PUBLIC'ten geri alınınca kalkmaz.
--
-- Bu yüzden `has_function_privilege('authenticated', 'yer_mesgul(uuid)')`
-- revoke'tan hemen SONRA hâlâ true döner. 003 bunu baştan doğru yapmıştı
-- (`from public, anon, authenticated, service_role` ile bütün şemayı süpürür);
-- 006'dan itibaren o liste kısaldı ve hata dört dosya boyunca kopyalandı.
--
-- Bu dosya CANLI VERİTABANINI onarır: 006, 007 ve 008 zaten çalıştırıldı, ve
-- oluşturdukları fonksiyonlar şu anda o üç rolde açık duruyor. 009/010/011
-- henüz çalışmadı — onlar dosya içinde düzeltildi, burada tekrar ele
-- alınmıyor.
--
-- NEDEN SÜPÜRME YOK: 003, `anon`'a bilerek beş fonksiyon verir
-- (is_yonetici, is_staff, acik_vardiyam, normalize_plaka,
-- bildirim_yonetici_turu — sonuncusu ayrıca service_role'a, çünkü send-push
-- alıcının GÜNCEL rolünü yeniden kontrol eder). Kör bir süpürme bunları da
-- kapatır ve giriş ekranını, RLS yardımcılarını ve push'u bozardı. Bu yüzden
-- liste elle sayılıdır: 006/007/008'in YARATTIĞI on dört fonksiyon, ne
-- eksik ne fazla.
--
-- AÇIĞIN BÜYÜKLÜĞÜ, abartmadan: `yer_listesi`/`bos_park_yeri` (010) henüz
-- yok. Şu an açık olanların hepsi SECURITY DEFINER ve içeride `is_staff()` /
-- `is_yonetici()` kontrolü yapıyor, yani rolü NULL olan bir PENDING kullanıcı
-- çağırsa da reddedilir. İki istisna gerçek sızıntıdır ve asıl sebebi budur:
--   • `cop_yaz()` bir trigger fonksiyonu — doğrudan çağrılınca zaten hata
--     verir, zararsız ama yetkisi de durmamalı.
--   • `vardiya_yeniden_hesapla(uuid)` bir vardiyanın toplamlarını yeniden
--     hesaplar ve İÇERİDE ROL KONTROLÜ YOKTUR — tek koruması EXECUTE
--     yetkisiydi ve o yetki açıktı.
-- ============================================================================

begin;

-- --------------------------------------------------------------- 006 -------
revoke all on function public.aktif_tarife()
  from public, anon, authenticated, service_role;
revoke all on function public.kayip_bilet_tahsil(text, public.odeme_yontemi, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.tarife_guncelle(integer, integer, integer, integer, integer)
  from public, anon, authenticated, service_role;

grant execute on function public.aktif_tarife() to authenticated;
grant execute on function public.kayip_bilet_tahsil(text, public.odeme_yontemi, uuid)
  to authenticated;
grant execute on function public.tarife_guncelle(integer, integer, integer, integer, integer)
  to authenticated;

-- --------------------------------------------------------------- 007 -------
-- cop_yaz ve vardiya_yeniden_hesapla hiçbir role geri verilmez.
revoke all on function public.cop_yaz()
  from public, anon, authenticated, service_role;
revoke all on function public.vardiya_yeniden_hesapla(uuid)
  from public, anon, authenticated, service_role;

revoke all on function public.bilet_sil(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.abonman_sil(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.tarife_sil(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.kayit_sil(text, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.cop_geri_al(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.cop_kalici_sil(uuid)
  from public, anon, authenticated, service_role;

grant execute on function public.bilet_sil(uuid)       to authenticated;
grant execute on function public.abonman_sil(uuid)     to authenticated;
grant execute on function public.tarife_sil(uuid)      to authenticated;
grant execute on function public.kayit_sil(text, uuid) to authenticated;
grant execute on function public.cop_geri_al(uuid)     to authenticated;
grant execute on function public.cop_kalici_sil(uuid)  to authenticated;

-- --------------------------------------------------------------- 008 -------
revoke all on function
  public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb, text, text, text, text)
  from public, anon, authenticated, service_role;
revoke all on function public.bilet_musteri_guncelle(uuid, text, text, text, text)
  from public, anon, authenticated, service_role;
revoke all on function public.acik_bilet_ara(text)
  from public, anon, authenticated, service_role;

grant execute on function
  public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb, text, text, text, text)
  to authenticated;
-- service_role YALNIZCA burada: kamera bilet açar, başka hiçbir şey yapamaz.
grant execute on function
  public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb, text, text, text, text)
  to service_role;
grant execute on function public.bilet_musteri_guncelle(uuid, text, text, text, text)
  to authenticated;
grant execute on function public.acik_bilet_ara(text) to authenticated;

-- ------------------------------------------------------------- verify ------
do $$
declare
  -- Beklenen son durum. Kapalı olması gereken iki fonksiyon ayrı tutulur,
  -- çünkü onlar `authenticated`'a da kapalıdır.
  v_kapali text[] := array[
    'public.cop_yaz()',
    'public.vardiya_yeniden_hesapla(uuid)'
  ];
  v_personel text[] := array[
    'public.aktif_tarife()',
    'public.kayip_bilet_tahsil(text, public.odeme_yontemi, uuid)',
    'public.tarife_guncelle(integer, integer, integer, integer, integer)',
    'public.bilet_sil(uuid)',
    'public.abonman_sil(uuid)',
    'public.tarife_sil(uuid)',
    'public.kayit_sil(text, uuid)',
    'public.cop_geri_al(uuid)',
    'public.cop_kalici_sil(uuid)',
    'public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb, text, text, text, text)',
    'public.bilet_musteri_guncelle(uuid, text, text, text, text)',
    'public.acik_bilet_ara(text)'
  ];
  v_kamera text :=
    'public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb, text, text, text, text)';
  v_sig text;
begin
  foreach v_sig in array v_kapali loop
    if has_function_privilege('anon', v_sig, 'execute')
       or has_function_privilege('authenticated', v_sig, 'execute')
       or has_function_privilege('service_role', v_sig, 'execute') then
      raise exception '012: % hâlâ bir istemci rolüne açık', v_sig;
    end if;
  end loop;

  foreach v_sig in array v_personel loop
    if has_function_privilege('anon', v_sig, 'execute') then
      raise exception '012: % anon rolüne açık', v_sig;
    end if;
    if not has_function_privilege('authenticated', v_sig, 'execute') then
      raise exception '012: % personele kapalı kaldı', v_sig;
    end if;
    -- Kameranın tek kapısı bilet açmaktır; diğerlerinde service_role kalmaz.
    if v_sig <> v_kamera and has_function_privilege('service_role', v_sig, 'execute') then
      raise exception '012: % kameraya açık', v_sig;
    end if;
  end loop;

  if not has_function_privilege('service_role', v_kamera, 'execute') then
    raise exception '012: bilet_ac kameraya kapandı — kamera webhook''u çalışmaz';
  end if;

  -- 003'ün bilerek açtıkları kapanmamış olmalı: bunlar giriş öncesi ve RLS
  -- yardımcılarıdır, yukarıdaki revoke'lar onlara hiç dokunmaz.
  if not has_function_privilege('anon', 'public.is_staff()', 'execute')
     or not has_function_privilege('service_role',
            'public.bildirim_yonetici_turu(public.bildirim_tur)', 'execute') then
    raise exception '012: 003''ün bilerek verdiği yetkiler kaybolmuş';
  end if;
end $$;

commit;
