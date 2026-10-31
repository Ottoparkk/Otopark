-- ============================================================================
-- 044  Okunamayan plakadan tek dokunuşla giriş: istisna_bilet_ac
-- ============================================================================

begin;

-- One tap on an unreadable-plate card (OKUNAMADI): staff type the plate, the
-- entry ticket opens AT THE MOMENT THE CAMERA SAW THE CAR, and the card closes
-- — all in one transaction. Any refusal (bad plate, plate already inside)
-- leaves no ticket and the card open.
--
-- Why staff may not choose the time anywhere else (bilet_ac 030): a later
-- entry time is a silent discount. Here the time is not theirs to choose
-- either: it comes from the istisna row, which only the camera path writes
-- (istisnalar has no client write policy). It is still sanity-checked, the
-- same two ways the camera path is:
--   • a camera clock can drift (that is what GELECEK exists for) → the
--     camera's time is trusted only within [received − delay limit,
--     received + 5 min], else the server's receive time is used; never later
--     than now;
--   • a card left open for longer than the delay limit is refused — the car
--     has most likely left, and a ticket dated days back would be a large
--     wrong charge (same limit that makes a late camera event BAYAT).
--
-- The ticket reuses the event's islem_id: a later camera retry of the SAME
-- event then replays onto this ticket (bilet_ac / kamera_tek_kapi replay by
-- islem_id) instead of opening a second one. bilet_ac itself is unchanged
-- (its 11-arg signature stays — 029) and runs every one of its guards.

create or replace function public.istisna_bilet_ac(p_id uuid, p_plaka text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_ist      public.istisnalar%rowtype;
  v_bilet    uuid;
  v_b        record;
  v_limit_dk integer;
  v_giris    timestamptz;
  v_yer      uuid;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  -- Row lock: two staff tapping the same card at once are serialised; the
  -- second one then finds the ticket and is answered like a repeated tap.
  select * into v_ist from public.istisnalar where id = p_id for update;
  if not found then
    raise exception 'Kayıt bulunamadı.';
  end if;
  if v_ist.tur::text <> 'OKUNAMADI' or v_ist.islem_id is null then
    raise exception 'Bu kayıttan giriş açılamaz.';
  end if;

  -- A ticket already carries this event: a camera retry opened it (041 /
  -- bilet_ac replay), or this is a repeated tap whose answer was lost. That
  -- ticket is never touched; an open card is closed with a note saying so.
  select b.id, b.plaka into v_b from public.biletler b where b.islem_id = v_ist.islem_id;
  if found then
    if v_ist.cozuldu_at is null then
      update public.istisnalar
         set cozuldu_by = auth.uid(), cozuldu_at = now(),
             cozum_notu = 'Kamera bileti zaten açmış: ' || v_b.plaka
       where id = p_id;
    end if;
    return jsonb_build_object(
      'bilet_id', v_b.id, 'plaka', v_b.plaka, 'zaten_vardi', true,
      'yer_kod', (select p.kod from public.park_yerleri p
                    join public.biletler b on b.park_yeri_id = p.id
                   where b.id = v_b.id));
  end if;

  if v_ist.cozuldu_at is not null then
    raise exception 'Bu kayıt zaten kapatılmış.';
  end if;

  -- Entry time: the camera's, when it can be trusted (read the limit exactly
  -- as bilet_ac does).
  select o.kamera_gecikme_limiti_dk into v_limit_dk
    from public.otopark_ayarlari o where o.id = 1;
  v_limit_dk := coalesce(v_limit_dk, 720);

  if v_ist.kaynak_zaman is not null
     and v_ist.kaynak_zaman >= v_ist.alindi_zaman - make_interval(mins => v_limit_dk)
     and v_ist.kaynak_zaman <= v_ist.alindi_zaman + interval '5 minutes' then
    v_giris := v_ist.kaynak_zaman;
  else
    v_giris := v_ist.alindi_zaman;
  end if;
  v_giris := least(v_giris, now());

  if v_giris < now() - make_interval(mins => v_limit_dk) then
    raise exception 'Bu kayıt çok eski; araç büyük olasılıkla çıktı. Gerekirse girişi Giriş ekranından açın.';
  end if;

  -- Spot: the first free one, as a camera ticket gets — staff are not asked
  -- to choose. Same lock key as bilet_ac (030), so the spot read here cannot
  -- be taken before bilet_ac writes it (the lock is re-entrant in this
  -- transaction). Full lot / no layout → NULL, the ticket still opens.
  perform pg_advisory_xact_lock(hashtext('bilet_ac_yer'));
  v_yer := public.bos_park_yeri();

  v_bilet := public.bilet_ac(p_plaka, v_ist.islem_id, 'MOBIL', null, v_ist.foto_path, v_yer);
  if v_bilet is null then
    raise exception 'Bilet açılamadı.';
  end if;

  -- Was it really opened by THIS call? A camera retry of the same event that
  -- committed between the check above and bilet_ac's insert makes bilet_ac
  -- hand back the camera's ticket (unique islem_id). That one must not be
  -- re-dated or claimed.
  select b.plaka, b.giris_by, b.giris_kaynak, b.alindi_zaman into v_b
    from public.biletler b where b.id = v_bilet;
  if v_b.giris_by is distinct from auth.uid()
     or v_b.giris_kaynak::text <> 'MOBIL'
     or v_b.alindi_zaman <> now() then
    update public.istisnalar
       set cozuldu_by = auth.uid(), cozuldu_at = now(),
           cozum_notu = 'Kamera bileti zaten açmış: ' || v_b.plaka
     where id = p_id;
    return jsonb_build_object(
      'bilet_id', v_bilet, 'plaka', v_b.plaka, 'zaten_vardi', true,
      'yer_kod', (select p.kod from public.park_yerleri p
                    join public.biletler b on b.park_yeri_id = p.id
                   where b.id = v_bilet));
  end if;

  -- Re-date the ticket just opened (still ACIK → the immutable guard lets it
  -- through, 029). kaynak_zaman = the time billed from, so the ticket's
  -- "Kameradan gelme … sonradan işlendi" line names it.
  update public.biletler
     set giris_at        = v_giris,
         kaynak_zaman    = v_giris,
         gecikmeli_kayit = (v_giris < now() - interval '2 minutes')
   where id = v_bilet;

  update public.istisnalar
     set cozuldu_by = auth.uid(), cozuldu_at = now(),
         cozum_notu = 'Bilet açıldı: ' || v_b.plaka
   where id = p_id;

  perform public.audit('istisna_bilet_acildi', 'biletler', v_bilet,
    jsonb_build_object('istisna_id', p_id, 'plaka', v_b.plaka, 'giris_at', v_giris));

  return jsonb_build_object(
    'bilet_id', v_bilet, 'plaka', v_b.plaka, 'zaten_vardi', false,
    'yer_kod', (select p.kod from public.park_yerleri p
                  join public.biletler b on b.park_yeri_id = p.id
                 where b.id = v_bilet));
end
$$;

-- `from public` too: new functions get EXECUTE through PUBLIC, and anon /
-- authenticated are members of it (058).
revoke all on function public.istisna_bilet_ac(uuid, text)
  from public, anon, authenticated, service_role;
grant execute on function public.istisna_bilet_ac(uuid, text) to authenticated;

do $do$
begin
  if to_regprocedure('public.istisna_bilet_ac(uuid, text)') is null then
    raise exception '044: istisna_bilet_ac oluşmadı';
  end if;
  if not exists (select 1 from pg_proc
                  where oid = 'public.istisna_bilet_ac(uuid, text)'::regprocedure
                    and prosecdef and proconfig @> array['search_path=public']) then
    raise exception '044: istisna_bilet_ac SECURITY DEFINER + search_path=public değil';
  end if;
  if not has_function_privilege('authenticated', 'public.istisna_bilet_ac(uuid, text)', 'execute') then
    raise exception '044: istisna_bilet_ac personele kapalı';
  end if;
  if has_function_privilege('public', 'public.istisna_bilet_ac(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.istisna_bilet_ac(uuid, text)', 'execute')
     or has_function_privilege('service_role', 'public.istisna_bilet_ac(uuid, text)', 'execute') then
    raise exception '044: istisna_bilet_ac public/anon/service_role rolüne açık';
  end if;
  -- bilet_ac must still be the one 11-arg function (no overload crept in).
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'bilet_ac') <> 1 then
    raise exception '044: bilet_ac aşırı yüklenmiş — tek imza bekleniyordu';
  end if;
end
$do$;

commit;
