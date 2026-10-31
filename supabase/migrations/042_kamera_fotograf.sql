-- ============================================================================
-- 042  Kamera fotoğrafı: olayın biletine, damgasına ya da kaydına bağlanır
-- ============================================================================

begin;

-- Webhook HİÇBİR kamera fotoğrafını saklamıyordu (her RPC çağrısında
-- p_foto null): kameranın açtığı biletin, vurduğu "kapıda" damgasının ve
-- yazdığı her kaydın fotoğrafı yoktu; personel "okunamadı" ya da "benzer
-- plaka" kaydına karar verirken bakacak bir şey bulamıyordu.
--
-- Artık köprü (1.2.3), okuduğu plaka kesitinin sıkıştırılmış bir kopyasını
-- (≤100 KB, telefonun "kanıt" profiliyle aynı mantık: cihaz sıkıştırır, sunucu
-- yalnızca saklar) da gönderir. Webhook KARARDAN SONRA onu `plaka-foto`
-- kovasına `kamera/<islem_id>.jpg` olarak yükler (üzerine yazmadan) ve bu
-- fonksiyonla bağlar. Önce karar, sonra yükleme: yok sayılan ya da reddedilen
-- olayın fotoğrafı hiç yüklenmez, kovada sahipsiz dosya birikmez.
--
-- Saklama süresi değişmedi: gece temizliği (025) yola bakmaz — foto_saklama_gun
-- (1-30) geçmiş her nesneyi siler, biletlerdeki ve kayıtlardaki yolları
-- boşaltır. Kamera fotoğrafları telefonunkilerle aynı süreye tabidir.

-- ------------------------------------------------------------- bağla -----

-- Yalnızca BU olayın yazdığı yere, yalnızca BU olayın yolunu yazar:
--   1. olayın açtığı KAMERA biletinin giris_foto'su (islem_id bilettedir);
--   2. olayın yazdığı KAMERA kaydının foto_path'i (islem_id kayıttadır);
--   3. olayın vurduğu "kapıda" damgasının cikis_foto'su. Damga biletin
--      islem_id'sini değiştirmez, o yüzden bilet + zaman ikilisiyle bulunur:
--      kamera_cikis_bildir cikis_bekliyor_at'e TAM bu olayın zamanını yazar.
-- Üçü birbirinden bağımsızdır: tek kapıda okunamayan ilk denemenin kaydı ve
-- yeniden denemenin açtığı bilet (041) aynı olaydır, ikisi de fotoğrafı alır.
--
-- Hiçbir yol EZİLMEZ (yalnızca boşsa yazılır — ilk fotoğraf kalır) ve
-- kapanmış bilete dokunulmaz: değişmezlik guard'ı (029) dolu bir foto yolunu
-- reddederdi; `durum = 'ACIK'` koşulu guard'a hiç varmamayı garanti eder.
-- Yol olaya BAĞLIDIR: başka bir olayın ya da telefonun fotoğrafı, ya da kova
-- içinde herhangi bir nesne bir satıra iliştirilemez.
--
-- is_staff() guard'ı YOK ve olamaz (webhook'ta auth.uid() null). Tersi var:
-- JWT taşıyan çağıran reddedilir. Asıl sınır grant'tır (037 deseni). Döner:
-- kaç yere bağlandığı (0 = bağlanacak yer yoktu ya da zaten doluydu).
create or replace function public.kamera_foto_bagla(
  p_islem_id uuid,
  p_bilet_id uuid,
  p_zaman    timestamptz,
  p_foto     text
) returns integer
language plpgsql security definer set search_path = public as $fn$
declare
  v_n integer := 0;
  v_k integer;
begin
  if auth.uid() is not null then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_islem_id is null then
    raise exception 'İşlem kimliği zorunludur.';
  end if;
  if p_foto is distinct from ('kamera/' || p_islem_id::text || '.jpg') then
    raise exception 'Fotoğraf yolu bu kamera olayına ait değil.';
  end if;

  update public.biletler
     set giris_foto = p_foto
   where islem_id = p_islem_id and giris_kaynak = 'KAMERA'
     and durum = 'ACIK' and giris_foto is null;
  get diagnostics v_k = row_count;
  v_n := v_n + v_k;

  update public.istisnalar
     set foto_path = p_foto
   where islem_id = p_islem_id and kaynak = 'KAMERA' and foto_path is null;
  get diagnostics v_k = row_count;
  v_n := v_n + v_k;

  if p_bilet_id is not null and p_zaman is not null then
    update public.biletler
       set cikis_foto = p_foto
     where id = p_bilet_id and durum = 'ACIK'
       and cikis_bekliyor_at = p_zaman and cikis_foto is null;
    get diagnostics v_k = row_count;
    v_n := v_n + v_k;
  end if;

  return v_n;
end
$fn$;

-- -------------------------------------------------------------- yetki -----

-- from public OLMADAN hiçbir şey kapanmaz (012); service_role'e AÇIKÇA verilir
-- (033). İstemciye açık olsaydı herkes bir kamera biletine ya da kaydına
-- kovadaki bir nesneyi iliştirmeyi deneyebilirdi.
revoke all on function public.kamera_foto_bagla(uuid, uuid, timestamptz, text) from public;
revoke all on function public.kamera_foto_bagla(uuid, uuid, timestamptz, text)
  from anon, authenticated, service_role;
grant execute on function public.kamera_foto_bagla(uuid, uuid, timestamptz, text)
  to service_role;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
begin
  if not has_function_privilege('service_role',
       'public.kamera_foto_bagla(uuid, uuid, timestamptz, text)', 'execute') then
    raise exception '042: kamera_foto_bagla service_role rolüne kapalı — webhook bağlayamaz';
  end if;
  foreach r in array array['anon', 'authenticated'] loop
    if has_function_privilege(r,
         'public.kamera_foto_bagla(uuid, uuid, timestamptz, text)', 'execute') then
      raise exception '042: kamera_foto_bagla % rolüne açık', r;
    end if;
  end loop;

  if not exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'kamera_foto_bagla'
       and p.prosecdef and p.proconfig @> array['search_path=public']
  ) then
    raise exception '042: kamera_foto_bagla SECURITY DEFINER + search_path=public değil';
  end if;

  -- Fotoğraflar bu kovaya yüklenir; kova yoksa webhook her yüklemede hata
  -- alır ve hiçbir fotoğraf bağlanmaz (araç akışı etkilenmez, ama özellik
  -- sessizce ölür).
  if not exists (select 1 from storage.buckets b
                  where b.id = 'plaka-foto' and b.public = false) then
    raise exception '042: özel plaka-foto kovası yok';
  end if;
end
$do$;

commit;
