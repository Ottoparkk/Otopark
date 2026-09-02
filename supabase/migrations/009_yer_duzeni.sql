-- ============================================================================
-- 009  Park yerleri kapasiteden üretilir — P-01 / E-01 / R-01
-- ============================================================================
--
-- Owner decision (2026-08-26): spots are no longer typed in one at a time.
-- Capacity is the input; the layout follows from it, under one naming scheme:
--
--     P-01 …  normal      (tip NORMAL, rezerve false)
--     E-01 …  engelli     (tip ENGELLI)
--     R-01 …  rezerve     (tip NORMAL, rezerve true)
--
-- normal = kapasite − engelli − rezerve, so the three groups always add up to
-- the capacity that occupancy is measured against.
--
-- FIVE RULES, and every one of them exists because of a way this could destroy
-- something the owner cannot get back.
--
-- 1. NOTHING IS EVER DELETED. Shrinking capacity sets is_active = false and
--    stops there. `rezervasyonlar.park_yeri_id` is ON DELETE CASCADE, so a
--    DELETE here would silently take a customer's reserved bay with it, and
--    restoring the spot from Çöp Kutusu would NOT bring the reservation back.
--    Retiring is fully reversible: raise the capacity again and the same rows
--    come back, with their history and their reservations intact.
--
-- 2. AN OCCUPIED BAY IS NEVER TOUCHED. A spot holding an open ticket, or
--    carrying a reservation that has not expired, is skipped and REPORTED by
--    code. Retiring it would hide a parked car from the spot grid (retired
--    spots sit behind "Pasifleri göster"), which is exactly how a car ends up
--    being argued about at the barrier.
--
-- 3. THE SCHEME OWNS ONLY ITS OWN CODES. `^[PER]-<digits>$` is managed;
--    anything else — the sample A-01/B-01/S-01 rows from 005, or a bay someone
--    added by hand — is left completely alone unless the caller explicitly
--    passes p_digerlerini_kapat. A generator that quietly retires a manually
--    created bay is a trap, so that is an opt-in tick, never a default.
--
-- 4. THE CODE FOR SPOT N NEVER CHANGES. Padding is a fixed two digits:
--    P-01 … P-99, then P-100. Padding to the width of the capacity instead
--    would rename P-01 to P-001 the moment the lot passed 99 spots, orphaning
--    every existing row and every ticket that points at one. The cost is
--    lexical ordering past 99, which the client sorts naturally.
--
-- 5. RE-RUNNING IT CHANGES NOTHING. The function is idempotent: asking for the
--    layout you already have inserts nothing, updates nothing and retires
--    nothing. That is what makes it safe to bundle into the settings Save, and
--    it is why "press Kaydet again" is the correct recovery if the settings
--    write lands and this one does not.
-- ============================================================================

begin;

-- --------------------------------------------------------------- helper ----
--
-- "Is this bay spoken for?" — an open ticket, or a reservation that has not
-- run out yet. SECURITY DEFINER because it is called from inside the generator
-- (which already bypasses RLS) and has to give the same answer whoever is
-- signed in; revoked from the client below, since nothing out there needs it.
create or replace function public.yer_mesgul(p_yer_id uuid) returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
           select 1 from public.biletler b
            where b.park_yeri_id = p_yer_id and b.durum = 'ACIK')
      or exists (
           select 1 from public.rezervasyonlar r
            where r.park_yeri_id = p_yer_id
              and (upper(r.gecerlilik) is null or upper(r.gecerlilik) > now()));
$$;

-- ------------------------------------------------------------ generator ----

create or replace function public.park_yerleri_uret(
  p_normal            integer,
  p_engelli           integer,
  p_rezerve           integer,
  p_digerlerini_kapat boolean default false
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_grup    record;
  v_desen   text;
  v_n       integer;
  v_kodlar  text[];
  v_eklenen integer := 0;
  v_guncel  integer := 0;
  v_kapanan integer := 0;
  v_atlanan text[]  := '{}';
begin
  if not public.is_yonetici() then
    raise exception 'Park yerlerini yalnızca yönetici düzenleyebilir.';
  end if;

  if p_normal is null or p_engelli is null or p_rezerve is null then
    raise exception 'Yer sayıları boş bırakılamaz.';
  end if;
  if p_normal < 0 or p_engelli < 0 or p_rezerve < 0 then
    raise exception 'Yer sayısı negatif olamaz.';
  end if;
  -- A ceiling, not a guess about lot sizes: the capacity field takes five
  -- digits, and one stray keystroke must not be able to insert 99.999 rows.
  if p_normal + p_engelli + p_rezerve > 2000 then
    raise exception 'Toplam yer sayısı en fazla 2000 olabilir.';
  end if;

  -- Two Yöneticis saving settings in the same moment would interleave the add
  -- and retire passes below and could leave the layout half applied. Same
  -- pattern as every other multi-statement decision in this schema.
  perform pg_advisory_xact_lock(hashtext('park_yerleri_uret'));

  for v_grup in
    select *
      from (values
        ('P', 'NORMAL'::public.park_yeri_tip,  false, p_normal),
        ('E', 'ENGELLI'::public.park_yeri_tip, false, p_engelli),
        ('R', 'NORMAL'::public.park_yeri_tip,  true,  p_rezerve)
      ) as g(onek, tip, rezerve, adet)
  loop
    -- {1,6} bounds the cast below: the numeric part can never overflow int.
    v_desen := '^' || v_grup.onek || '-[0-9]{1,6}$';

    -- (a) whatever is missing from 1..adet
    insert into public.park_yerleri (kod, tip, rezerve)
    select v_grup.onek || '-' || lpad(i::text, 2, '0'), v_grup.tip, v_grup.rezerve
      from generate_series(1, v_grup.adet) as s(i)
    on conflict (kod) do nothing;
    get diagnostics v_n = row_count;
    v_eklenen := v_eklenen + v_n;

    -- (b) rows already inside the range: bring them back and put the type
    --     right. This is how raising the capacity un-retires the exact bays
    --     that lowering it retired, instead of creating new ones beside them.
    update public.park_yerleri p
       set is_active = true, tip = v_grup.tip, rezerve = v_grup.rezerve
     where p.kod in (select v_grup.onek || '-' || lpad(i::text, 2, '0')
                       from generate_series(1, v_grup.adet) as s(i))
       and (p.is_active = false or p.tip <> v_grup.tip or p.rezerve <> v_grup.rezerve);
    get diagnostics v_n = row_count;
    v_guncel := v_guncel + v_n;

    -- (c) rows that fell outside the range. Read the protected ones FIRST —
    --     after the UPDATE they would no longer look active.
    --     The CASE is not decoration: a sibling `kod ~ v_desen` term does not
    --     stop the planner evaluating the cast on a row it would have
    --     excluded, and a hand-typed 'A-9999999999' would then overflow int
    --     and take the whole function down with it.
    --     `not between 1 and adet` rather than `> adet`: a hand-made P-00 is
    --     outside the scheme's range too, and `> adet` would keep it alive for
    --     ever without the generator ever owning it.
    select coalesce(array_agg(p.kod order by p.kod), '{}'::text[])
      into v_kodlar
      from public.park_yerleri p
     where p.is_active
       and case when p.kod ~ v_desen
                then (substring(p.kod from '[0-9]+$'))::integer
                       not between 1 and v_grup.adet
                else false end
       and public.yer_mesgul(p.id);
    v_atlanan := v_atlanan || v_kodlar;

    update public.park_yerleri p
       set is_active = false
     where p.is_active
       and case when p.kod ~ v_desen
                then (substring(p.kod from '[0-9]+$'))::integer
                       not between 1 and v_grup.adet
                else false end
       and not public.yer_mesgul(p.id);
    get diagnostics v_n = row_count;
    v_kapanan := v_kapanan + v_n;
  end loop;

  -- (d) rule 3: only on request, and still never over an occupied bay.
  if p_digerlerini_kapat then
    select coalesce(array_agg(p.kod order by p.kod), '{}'::text[])
      into v_kodlar
      from public.park_yerleri p
     where p.is_active
       and p.kod !~ '^[PER]-[0-9]{1,6}$'
       and public.yer_mesgul(p.id);
    v_atlanan := v_atlanan || v_kodlar;

    update public.park_yerleri p
       set is_active = false
     where p.is_active
       and p.kod !~ '^[PER]-[0-9]{1,6}$'
       and not public.yer_mesgul(p.id);
    get diagnostics v_n = row_count;
    v_kapanan := v_kapanan + v_n;
  end if;

  select count(*) into v_n from public.park_yerleri where is_active;

  -- Layout changes are rare, deliberate, and worth being able to point at
  -- afterwards — including the runs that changed nothing.
  perform public.audit('park_yerleri_uret', 'park_yerleri', null::uuid,
    jsonb_build_object(
      'normal', p_normal, 'engelli', p_engelli, 'rezerve', p_rezerve,
      'digerleri_kapatildi', p_digerlerini_kapat,
      'eklenen', v_eklenen, 'guncellenen', v_guncel,
      'kapanan', v_kapanan, 'atlanan', to_jsonb(v_atlanan)));

  return jsonb_build_object(
    'eklenen',     v_eklenen,
    'guncellenen', v_guncel,
    'kapanan',     v_kapanan,
    'atlanan',     to_jsonb(v_atlanan),
    'aktif',       v_n);
end $$;

-- -------------------------------------------------------------- grants -----
-- İKİ yol birden kapatılmalı, ve `from public` yalnızca birincisini kapatır:
--   1. PostgreSQL yeni fonksiyona EXECUTE'u PUBLIC'e verir (`authenticated` de
--      PUBLIC üyesidir).
--   2. Supabase ayrıca `anon`, `authenticated` ve `service_role` rollerine
--      DOĞRUDAN verir — bu, PUBLIC'ten geri alınınca kalkmaz.
-- 009'un doğrulama bloğu bunu canlıda yakaladı; ayrıntısı 012'de.
revoke all on function public.yer_mesgul(uuid) from public, anon, authenticated, service_role;
revoke all on function
  public.park_yerleri_uret(integer, integer, integer, boolean) from public, anon, authenticated, service_role;
grant execute on function
  public.park_yerleri_uret(integer, integer, integer, boolean) to authenticated;

-- ------------------------------------------------------------- verify ------
do $$
begin
  if has_function_privilege('authenticated', 'public.yer_mesgul(uuid)', 'execute') then
    raise exception '009: yer_mesgul istemciye açık';
  end if;
  if has_function_privilege('anon',
       'public.park_yerleri_uret(integer, integer, integer, boolean)', 'execute') then
    raise exception '009: park_yerleri_uret anon rolüne açık';
  end if;
  if not has_function_privilege('authenticated',
       'public.park_yerleri_uret(integer, integer, integer, boolean)', 'execute') then
    raise exception '009: park_yerleri_uret yöneticiye kapalı kaldı';
  end if;
  -- Rule 1 only holds while there is no DELETE path; 007 revoked it, and this
  -- file depends on that still being true.
  if has_table_privilege('authenticated', 'public.park_yerleri', 'delete') then
    raise exception '009: park_yerleri üzerinde doğrudan DELETE yetkisi var';
  end if;
end $$;

commit;
