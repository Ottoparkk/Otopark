-- ============================================================================
-- 046  Giriş saatini düzelt: bilet ekranındaki "Değiştir", araç içerideyken
-- ============================================================================

begin;

-- ------------------------------------------------------------ fonksiyon ----

-- Bilet ekranındaki "Değiştir" plakayı (bilet_plaka_duzelt, 029), ücreti
-- (bilet_kapat'ın elle ücret yolu) ve GİRİŞ SAATİNİ düzeltir. Sonuncusunun
-- yolu yoktu: kamera geç okuduğunda ya da personel girişi sonradan yaptığında
-- bilet yanlış saatten ücretlenir.
--
-- Saati değiştirmek PARADIR — geri almak ücreti artırır, ileri almak düşürür.
-- Bu yüzden elle ücret değişikliğiyle aynı kurallar:
--   · yalnızca aktif personel (is_staff) — sebep zorunlu, iz yazılır ve
--     Yöneticiye "Ücret değişikliği" türünde bildirim gider (yeni tür yok:
--     kullanıcının o tür için seçtiği tercih bunu da kapsar, send-push zaten
--     tanır). Değiştiren Yöneticinin kendisine gitmez (notify_yonetici).
--   · yalnızca AÇIK bilet. Kapanmış biletin parası alınmış, vardiyaya
--     yazılmıştır; geri almanın yolu İptal'dir. biletler_immutable_guard da
--     kapalı satırı zaten korur — hata sebebi burada anlaşılır söylenir.
--   · ileri bir zaman olamaz; bir yıldan eski olamaz (yazım hatası koruması —
--     istemci de aynı sınırı uygular).
--   · kullanılan puan yeni ücreti aşamaz: bilet_kapat çıkışta zaten reddeder
--     ("Önce puan kullanımını geri alın"), sorun kapıda kuyrukla değil burada
--     söylenmeli. Abonmanlı bilette ücret 0'dır, bilet_kapat'taki gibi.
--   · aynı saat zararsızdır: iz ve bildirim yazılmaz (çift basış, yeniden
--     deneme).
--   · kaynak_zaman / gecikmeli_kayit BİLEREK korunur: kameranın olayı ne
--     zaman gördüğü bilgisidir, düzeltilen saat ise audit_log'dadır.
create or replace function public.bilet_giris_duzelt(
  p_bilet_id uuid,
  p_giris_at timestamptz,
  p_sebep    text
) returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_b     public.biletler;
  v_sebep text := left(btrim(coalesce(p_sebep, '')), 200);
  v_ucret integer;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_giris_at is null then
    raise exception 'Giriş saati boş olamaz.';
  end if;
  if p_giris_at > now() then
    raise exception 'Giriş saati ileri bir zaman olamaz.';
  end if;
  if p_giris_at < now() - interval '1 year' then
    raise exception 'Giriş saati bir yıldan eski olamaz.';
  end if;
  if v_sebep = '' then
    raise exception 'Sebep zorunludur — giriş saati değişikliği denetim kaydına yazılır.';
  end if;

  -- Satır kilitlenir: aynı anda çıkış (bilet_kapat) ya da ikinci bir düzeltme
  -- bu okumayla yarışmasın.
  select * into v_b from public.biletler where id = p_bilet_id for update;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception 'Bilet açık değil; giriş saati yalnızca araç içerideyken değiştirilebilir.';
  end if;
  if v_b.giris_at = p_giris_at then
    return;
  end if;

  if v_b.indirim_kurus > 0 then
    v_ucret := case when v_b.abonman_id is not null then 0
                    else public.ucret_hesapla(p_giris_at, now(), v_b.tarife_id) end;
    if v_b.indirim_kurus > v_ucret then
      raise exception 'Kullanılan puan yeni ücretten fazla. Önce puan kullanımını geri alın.';
    end if;
  end if;

  update public.biletler set giris_at = p_giris_at where id = p_bilet_id;

  perform public.audit('bilet_giris_duzeltildi', 'biletler', p_bilet_id,
    jsonb_build_object('eski', v_b.giris_at, 'yeni', p_giris_at,
                       'sebep', v_sebep, 'plaka', v_b.plaka));

  perform public.notify_yonetici('UCRET_DEGISIKLIGI', 'Giriş saati değiştirildi',
    v_b.plaka || ' — '
      || to_char(v_b.giris_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI')
      || ' → '
      || to_char(p_giris_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI')
      || ' — ' || v_sebep,
    '/gise/bilet/' || p_bilet_id);
end
$fn$;

-- -------------------------------------------------------------- yetki -----

-- from public OLMADAN hiçbir şey kapanmaz (012); service_role OLMADAN da (033).
-- Kamera bu kapıyı kullanmaz: saati düzelten bir insan olmalı.
revoke all on function public.bilet_giris_duzelt(uuid, timestamptz, text) from public;
revoke all on function public.bilet_giris_duzelt(uuid, timestamptz, text)
  from anon, authenticated, service_role;
grant execute on function public.bilet_giris_duzelt(uuid, timestamptz, text) to authenticated;

-- ---------------------------------------------------------- doğrulama -----

do $do$
declare
  r text;
begin
  if not has_function_privilege('authenticated',
       'public.bilet_giris_duzelt(uuid, timestamptz, text)', 'execute') then
    raise exception '046: bilet_giris_duzelt authenticated rolüne kapalı — ekran çalışmaz';
  end if;
  foreach r in array array['anon', 'service_role'] loop
    if has_function_privilege(r, 'public.bilet_giris_duzelt(uuid, timestamptz, text)', 'execute') then
      raise exception '046: bilet_giris_duzelt % rolüne açık', r;
    end if;
  end loop;

  if not exists (
    select 1 from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'bilet_giris_duzelt'
       and p.prosecdef
       and p.proconfig @> array['search_path=public']
  ) then
    raise exception '046: bilet_giris_duzelt SECURITY DEFINER + search_path=public değil';
  end if;
end
$do$;

commit;
