-- ============================================================================
-- 011  Aracı başka bir park yerine taşı
-- ============================================================================
--
-- Owner decision (2026-08-27): a car that is already inside can be moved to
-- another bay — on a phone by holding its bay for three seconds and then
-- tapping the empty one, on a desktop by double-clicking it first.
--
-- 010 made the bay real: chosen at Giriş, validated, one car per bay. This is
-- the correction path for it, and without one the field is write-once — a car
-- re-parked because the barrier was blocked, or a bay picked in a hurry, would
-- stay wrong until the car left.
--
-- THREE RULES:
--
-- 1. IT IS A CORRECTION, NOT A MOVEMENT OF MONEY. Only `park_yeri_id`, only
--    while the ticket is ACIK, and nothing else on the row — the fee, the
--    entry time and the plate are untouched, so the arithmetic at exit cannot
--    change no matter how many times a car is moved. A closed ticket is
--    refused here rather than left to biletler_immutable_guard, so the caller
--    is told which of the two states the ticket is in.
--
-- 2. THE TARGET IS VALIDATED EXACTLY AS AT ENTRY, and by the same words: it
--    must exist, be in use, and be empty. It shares `bilet_ac`'s advisory lock
--    key, which is the part that matters — a move and a new entry both write
--    `park_yeri_id` on an open ticket, so serialising them against each other
--    is what stops two cars landing on one bay through different doors.
--    `biletler_acik_yer_ux` (010) is still the guard underneath.
--
-- 3. STAFF, NOT JUST YÖNETİCİ. `is_staff()`, deliberately: Personel already
--    choose the bay at Giriş, and an operator who may set a field but not fix
--    it two minutes later will simply stop setting it. It is the same call
--    `bilet_musteri_guncelle` (008) makes for the same reason. The management
--    controls on that screen — add, edit, retire, delete a bay — stay
--    Yönetici-only in RLS and are untouched here.
--
-- Moving is audited by plate and by both bay codes: it is the one write that
-- changes where the app says a car is, and "it was on P-03 an hour ago" has to
-- be answerable.
-- ============================================================================

begin;

create or replace function public.bilet_yer_degistir(
  p_bilet_id    uuid,
  p_yeni_yer_id uuid
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_b        public.biletler;
  v_kod      text;
  v_aktif    boolean;
  v_plaka    text;
  v_eski_kod text;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;
  if p_yeni_yer_id is null then
    raise exception 'Yeni park yeri seçilmedi.';
  end if;

  -- Everything that can refuse cheaply refuses BEFORE the lock is taken, so a
  -- call that was never going to succeed does not hold the gate behind it.
  select * into v_b from public.biletler where id = p_bilet_id;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_b.durum <> 'ACIK' then
    raise exception
      'Bu bilet kapanmış; park yeri yalnızca araç içerideyken değiştirilebilir.';
  end if;

  -- Already there: a no-op, not an error. Two taps on the same bay and a
  -- retried request are the same event as far as this row is concerned.
  if v_b.park_yeri_id is not distinct from p_yeni_yer_id then
    return;
  end if;

  -- Rule 2: the SAME key bilet_ac uses. A different one would leave the two
  -- writers unserialised against each other, which is the whole race.
  perform pg_advisory_xact_lock(hashtext('bilet_ac_yer'));

  select p.kod, p.is_active into v_kod, v_aktif
    from public.park_yerleri p where p.id = p_yeni_yer_id;
  if v_kod is null then
    raise exception 'Park yeri bulunamadı.';
  end if;
  if not v_aktif then
    raise exception 'Bu park yeri kullanım dışı: %', v_kod;
  end if;

  select b.plaka into v_plaka
    from public.biletler b
   where b.park_yeri_id = p_yeni_yer_id and b.durum = 'ACIK'
   limit 1;
  if v_plaka is not null then
    raise exception 'Bu park yerinde başka bir araç var: % (%). Başka bir yer seçin.',
      v_kod, v_plaka;
  end if;

  -- Read before the update: afterwards the old bay is no longer on the row.
  select p.kod into v_eski_kod
    from public.park_yerleri p where p.id = v_b.park_yeri_id;

  begin
    update public.biletler set park_yeri_id = p_yeni_yer_id where id = p_bilet_id;
  exception when unique_violation then
    -- The lock above should have made this unreachable; it stays because the
    -- index is the rule and a constraint name is not an answer for anybody.
    raise exception 'Bu park yerinde başka bir araç var. Başka bir yer seçin.';
  end;

  perform public.audit('bilet_yer_degistir', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka,
                       'eski_yer', coalesce(v_eski_kod, 'yok'),
                       'yeni_yer', v_kod));
end $$;

-- -------------------------------------------------------------- grants -----
-- İKİ yol birden kapatılmalı, ve `from public` yalnızca birincisini kapatır:
--   1. PostgreSQL yeni fonksiyona EXECUTE'u PUBLIC'e verir (`authenticated` de
--      PUBLIC üyesidir).
--   2. Supabase ayrıca `anon`, `authenticated` ve `service_role` rollerine
--      DOĞRUDAN verir — bu, PUBLIC'ten geri alınınca kalkmaz.
-- 009'un doğrulama bloğu bunu canlıda yakaladı; ayrıntısı 012'de.
--
-- service_role is deliberately NOT granted: a camera reports where a car
-- arrived, it never decides that one should be re-parked.

revoke all on function public.bilet_yer_degistir(uuid, uuid) from public, anon, authenticated, service_role;
grant execute on function public.bilet_yer_degistir(uuid, uuid) to authenticated;

-- ------------------------------------------------------------- verify ------
do $$
begin
  if has_function_privilege('anon', 'public.bilet_yer_degistir(uuid, uuid)', 'execute') then
    raise exception '011: bilet_yer_degistir anon rolüne açık';
  end if;
  if not has_function_privilege('authenticated',
       'public.bilet_yer_degistir(uuid, uuid)', 'execute') then
    raise exception '011: bilet_yer_degistir personele kapalı kaldı';
  end if;
  if has_function_privilege('service_role',
       'public.bilet_yer_degistir(uuid, uuid)', 'execute') then
    raise exception '011: bilet_yer_degistir kameraya açık';
  end if;

  -- Rule 2 leans on 010 having been applied: without the index the lock is the
  -- only thing standing between two cars and one bay.
  if not exists (select 1 from pg_indexes
                  where schemaname = 'public' and indexname = 'biletler_acik_yer_ux') then
    raise exception '011: biletler_acik_yer_ux yok — önce 010 çalıştırılmalı';
  end if;

  -- The client must still have no direct write path to a ticket.
  if has_table_privilege('authenticated', 'public.biletler', 'UPDATE') then
    raise exception '011: authenticated biletler üzerinde UPDATE yetkisi kazanmış';
  end if;
end $$;

commit;
