-- ============================================================================
-- 010  Park yeri seçimi — elle seçilir, kameradan gelen kayıt kendi bulur
-- ============================================================================
--
-- Owner decision (2026-08-27): the operator picks a bay while opening a ticket,
-- and an entry that arrives from the camera — where nobody is standing there to
-- choose — is placed in the first empty one.
--
-- 009 made the bays; this makes them mean something. `biletler.park_yeri_id`
-- has existed since 001 and `bilet_ac` has accepted it since 002, but NOTHING
-- ever validated it: any uuid was written straight into the row, an inactive
-- bay was accepted, and two open tickets could sit on one bay with nothing to
-- stop them. That is the hole this closes.
--
-- FOUR RULES, in the order they matter:
--
-- 1. ONE CAR PER BAY, ENFORCED BY THE DATABASE.
--    `biletler_acik_yer_ux` is a partial unique index over the open tickets,
--    exactly like `biletler_acik_plaka_ux`. The friendly Turkish check inside
--    bilet_ac is for the MESSAGE; the index is what makes the rule true when
--    two operators tap Kaydet in the same second. Closing or cancelling a
--    ticket takes the row out of the index, so the bay frees itself — no
--    counter, no cleanup, nothing to drift.
--
-- 2. A CAMERA TICKET IS NEVER REFUSED OVER A PARKING SPACE.
--    A full lot leaves park_yeri_id NULL and the ticket still opens. A car in
--    the lot with no record is an unbillable car and an argument at the
--    barrier; a car with no bay recorded is a cosmetic gap. Where an operator
--    is present the opposite is true — they chose that bay, so a bay that is
--    taken is REPORTED to them rather than silently swapped for another.
--
-- 3. AUTO-ASSIGN ONLY EVER TAKES A PLAIN BAY.
--    Engelli, şarj, rezerve and bays under a live reservation are skipped, so
--    the automatic path can never spend the one bay somebody is owed. A human
--    may still pick any of them: the subscriber whose bay R-03 is arrives, and
--    the operator is the one who knows that.
--
-- 4. THE DEFINITION OF "FREE" LIVES IN ONE PLACE.
--    `yer_listesi()` computes occupancy, reservation and ordering once.
--    `park_yeri_durumu()` (what the picker draws) and `bos_park_yeri()` (what
--    the camera path takes) are both views over it, so the bay the screen
--    proposes and the bay the server would choose cannot drift apart.
--
-- Idempotency note, and it is the reason bilet_ac gains an up-front replay
-- check: the bay is now READ before the insert, and a retry-on-blip whose
-- first attempt actually succeeded would have found its OWN ticket sitting in
-- the bay it picked and reported "another car is here". Retrying an entry must
-- return the original ticket, not an error about it.
-- ============================================================================

begin;

-- ---------------------------------------------------------- yer_listesi ----

/**
 * Every active bay, annotated with what is standing on it and in what order a
 * human reads them. Rule 4: this is the only definition of "free".
 *
 * SECURITY DEFINER and deliberately NOT granted to anybody. It reads biletler
 * and rezervasyonlar with RLS bypassed, which is safe only because the two
 * wrappers below decide who may see the result — `park_yeri_durumu()` behind
 * is_staff(), `bos_park_yeri()` never leaving the server at all.
 *
 * `rezervasyonlu` follows `yer_mesgul` (009): a reservation counts until it
 * has run out, not just while it is running. Conservative on purpose — the
 * automatic path should leave a spoken-for bay alone, and the operator sees
 * the flag and decides for themselves.
 *
 * Ordering matches lib/yerkodu.ts: P before E before R, then by number, and
 * anything outside the scheme last. The numeric cast sits INSIDE the CASE,
 * because a sibling regex term does not stop the planner evaluating a cast on
 * a row it would have excluded — a hand-typed 'A-9999999999' would overflow
 * int and take the function down with it (009, rule (c)).
 */
create or replace function public.yer_listesi()
returns table (
  id            uuid,
  kod           text,
  tip           public.park_yeri_tip,
  rezerve       boolean,
  dolu_plaka    text,
  rezervasyonlu boolean,
  grup          smallint,
  sira          integer
)
language sql
stable
security definer
set search_path = public
as $$
  select q.id, q.kod, q.tip, q.rezerve, q.dolu_plaka, q.rezervasyonlu, q.grup, q.sira
    from (
      select p.id,
             p.kod,
             p.tip,
             p.rezerve,
             (select b.plaka
                from public.biletler b
               where b.park_yeri_id = p.id and b.durum = 'ACIK'
               limit 1)                                        as dolu_plaka,
             exists (select 1
                       from public.rezervasyonlar r
                      where r.park_yeri_id = p.id
                        and (upper(r.gecerlilik) is null
                             or upper(r.gecerlilik) > now()))  as rezervasyonlu,
             (case when p.kod ~ '^P-[0-9]{1,6}$' then 0
                   when p.kod ~ '^E-[0-9]{1,6}$' then 1
                   when p.kod ~ '^R-[0-9]{1,6}$' then 2
                   else 9 end)::smallint                       as grup,
             (case when p.kod ~ '^[PER]-[0-9]{1,6}$'
                   then (substring(p.kod from '[0-9]+$'))::integer
                   else null end)                              as sira
        from public.park_yerleri p
       where p.is_active
    ) q
   order by q.grup, q.sira nulls last, q.kod;
$$;

-- ------------------------------------------------------ park_yeri_durumu ---

/**
 * What the entry screen draws: the bays, and why each one is or is not free.
 *
 * Staff-callable, unlike everything else here. It carries a plate, which
 * Personel may already read for an open ticket (003's biletler_select), and no
 * price, no customer and no history — nothing this widens.
 *
 * The picker needs the OCCUPIED ones too, not just the free ones: a bay shown
 * greyed out with the plate on it answers "why can't I pick P-03" on the spot,
 * where a bay that is simply missing from the list looks like a bug.
 */
create or replace function public.park_yeri_durumu()
returns table (
  id            uuid,
  kod           text,
  tip           public.park_yeri_tip,
  rezerve       boolean,
  dolu_plaka    text,
  rezervasyonlu boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  return query
    select l.id, l.kod, l.tip, l.rezerve, l.dolu_plaka, l.rezervasyonlu
      from public.yer_listesi() l
     order by l.grup, l.sira nulls last, l.kod;
end $$;

-- --------------------------------------------------------- bos_park_yeri ---

/**
 * The first bay an unattended entry may be placed in, or NULL when there is
 * none. Rule 3: plain NORMAL bays only.
 *
 * Server-internal — no grant, ever. bilet_ac reaches it as the owner of a
 * SECURITY DEFINER function, and nothing on the client needs it: the picker
 * derives the same answer from park_yeri_durumu() with the same predicates
 * (src/lib/yerkodu.ts, ilkBosYer), so the bay the operator sees proposed is the
 * bay the camera would have taken.
 */
create or replace function public.bos_park_yeri()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select l.id
    from public.yer_listesi() l
   where l.dolu_plaka is null
     and not l.rezervasyonlu
     and not l.rezerve
     and l.tip = 'NORMAL'
   order by l.grup, l.sira nulls last, l.kod
   limit 1;
$$;

-- -------------------------------------------------------------- the index --
-- Rule 1. Checked first so the failure is a sentence rather than a constraint
-- name: on a lot that already parked two cars in one bay, the operator needs
-- to know WHICH bays before anything can be fixed.

do $$
declare v_kodlar text;
begin
  select string_agg(p.kod, ', ' order by p.kod) into v_kodlar
    from (select b.park_yeri_id
            from public.biletler b
           where b.durum = 'ACIK' and b.park_yeri_id is not null
           group by b.park_yeri_id
          having count(*) > 1) d
    join public.park_yerleri p on p.id = d.park_yeri_id;

  if v_kodlar is not null then
    raise exception
      '010: şu park yerlerinde birden çok açık bilet var: %. Bunlar kapatılmadan bu göç uygulanamaz.',
      v_kodlar;
  end if;
end $$;

create unique index if not exists biletler_acik_yer_ux
  on public.biletler (park_yeri_id)
  where durum = 'ACIK' and park_yeri_id is not null;

-- ------------------------------------------------------------- bilet_ac ----
--
-- The parameter list is UNCHANGED, so this is a `create or replace` and not a
-- drop: replacing in place keeps the grants 008 gave to `authenticated` and to
-- `service_role` (the camera webhook), and there is no overload to leave
-- behind. Everything outside the two marked blocks is 008's body verbatim.

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

  if auth.uid() is not null then
    select v.id into v_vardiya from public.vardiyalar v
     where v.personel_id = auth.uid() and v.kapanis_at is null limit 1;
  end if;

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

-- ----------------------------------------------------------- cop_geri_al ---
--
-- 007's body verbatim except for the `biletler` branch. An open ticket that
-- was deleted and is being restored may find its bay taken by a car that
-- arrived in the meantime — and rule 1 now refuses that outright, which would
-- turn "restore this ticket" into a dead end over a parking space. The bay
-- reference is dropped instead: the money-bearing row comes back, one car per
-- bay stays true, and the audit entry says the bay was let go.
--
-- 007's own unique_violation message ("already restored, or something took its
-- place") stays for every other collision, including the plate one.

create or replace function public.cop_geri_al(p_cop_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_c        public.cop;
  v_vardiya  uuid[];
  v_t        jsonb;
  v_yer_dusu boolean := false;   -- 010
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici geri alabilir.';
  end if;

  select * into v_c from public.cop where id = p_cop_id;
  if not found then
    raise exception 'Çöp kaydı bulunamadı.';
  end if;

  perform set_config('app.cop_geri_al', v_c.kayit_id::text, true);

  begin
    case v_c.tablo
      when 'biletler' then
        -- 010, see the note above this function.
        if (v_c.veri ->> 'durum') = 'ACIK'
           and (v_c.veri ->> 'park_yeri_id') is not null
           and exists (select 1 from public.biletler b
                        where b.park_yeri_id = (v_c.veri ->> 'park_yeri_id')::uuid
                          and b.durum = 'ACIK') then
          v_c.veri   := jsonb_set(v_c.veri, '{park_yeri_id}', 'null'::jsonb);
          v_yer_dusu := true;
        end if;
        insert into public.biletler select * from jsonb_populate_record(null::public.biletler, v_c.veri);
      when 'abonmanlar' then
        insert into public.abonmanlar select * from jsonb_populate_record(null::public.abonmanlar, v_c.veri);
      when 'kasa_hareketleri' then
        insert into public.kasa_hareketleri select * from jsonb_populate_record(null::public.kasa_hareketleri, v_c.veri);
      when 'park_yerleri' then
        insert into public.park_yerleri select * from jsonb_populate_record(null::public.park_yerleri, v_c.veri);
      when 'rezervasyonlar' then
        insert into public.rezervasyonlar select * from jsonb_populate_record(null::public.rezervasyonlar, v_c.veri);
      when 'hesaplar' then
        insert into public.hesaplar select * from jsonb_populate_record(null::public.hesaplar, v_c.veri);
      when 'hesap_araclari' then
        insert into public.hesap_araclari select * from jsonb_populate_record(null::public.hesap_araclari, v_c.veri);
      when 'istisnalar' then
        insert into public.istisnalar select * from jsonb_populate_record(null::public.istisnalar, v_c.veri);
      when 'tarifeler' then
        insert into public.tarifeler select * from jsonb_populate_record(null::public.tarifeler, v_c.veri);
      else
        raise exception 'Bu kayıt türü geri alınamaz: %', v_c.tablo;
    end case;
  exception
    when unique_violation then
      raise exception 'Bu kayıt zaten geri alınmış ya da yerine yenisi eklenmiş.';
    when foreign_key_violation then
      raise exception 'Bu kaydın bağlı olduğu bir kayıt silinmiş; önce onu geri alın.';
  end;

  -- Collections come back with the record they belonged to.
  for v_t in select jsonb_array_elements(coalesce(v_c.ek -> 'tahsilatlar', '[]'::jsonb)) loop
    begin
      insert into public.tahsilatlar
      select * from jsonb_populate_record(null::public.tahsilatlar, v_t);
      v_vardiya := v_vardiya || (v_t ->> 'vardiya_id')::uuid;
    exception when unique_violation then
      null;   -- already restored by an earlier attempt
    end;
  end loop;

  delete from public.cop where id = p_cop_id;

  perform public.audit('cop_geri_al', v_c.tablo, v_c.kayit_id,
    jsonb_build_object('ozet', v_c.ozet, 'park_yeri_dusuruldu', v_yer_dusu));

  perform public.vardiya_yeniden_hesapla(v)
    from unnest(coalesce(v_vardiya, '{}')) as v where v is not null;
end $$;

-- -------------------------------------------------------------- grants -----
-- İKİ yol birden kapatılmalı, ve `from public` yalnızca birincisini kapatır:
--   1. PostgreSQL yeni fonksiyona EXECUTE'u PUBLIC'e verir (`authenticated` de
--      PUBLIC üyesidir).
--   2. Supabase ayrıca `anon`, `authenticated` ve `service_role` rollerine
--      DOĞRUDAN verir — bu, PUBLIC'ten geri alınınca kalkmaz.
-- 009'un doğrulama bloğu bunu canlıda yakaladı; ayrıntısı 012'de.
--
-- bilet_ac and cop_geri_al were replaced in place, so their 008/007 grants
-- survive untouched and are re-asserted in the verify block rather than
-- re-issued here.

revoke all on function public.yer_listesi() from public, anon, authenticated, service_role;
revoke all on function public.bos_park_yeri() from public, anon, authenticated, service_role;
revoke all on function public.park_yeri_durumu() from public, anon, authenticated, service_role;

grant execute on function public.park_yeri_durumu() to authenticated;

-- ------------------------------------------------------------- verify ------
do $$
declare v_n integer;
begin
  if has_function_privilege('authenticated', 'public.yer_listesi()', 'execute') then
    raise exception '010: yer_listesi istemciye açık';
  end if;
  if has_function_privilege('authenticated', 'public.bos_park_yeri()', 'execute') then
    raise exception '010: bos_park_yeri istemciye açık';
  end if;
  if has_function_privilege('anon', 'public.park_yeri_durumu()', 'execute') then
    raise exception '010: park_yeri_durumu anon rolüne açık';
  end if;
  if not has_function_privilege('authenticated', 'public.park_yeri_durumu()', 'execute') then
    raise exception '010: park_yeri_durumu personele kapalı kaldı';
  end if;

  -- Replacing in place must not have cost bilet_ac its callers: without the
  -- service_role grant the camera webhook stops recording cars, and that is
  -- the sort of failure nobody notices until the numbers look wrong.
  if not has_function_privilege('authenticated',
       'public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb, text, text, text, text)',
       'execute') then
    raise exception '010: bilet_ac authenticated rolüne kapalı';
  end if;
  if not has_function_privilege('service_role',
       'public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb, text, text, text, text)',
       'execute') then
    raise exception '010: bilet_ac service_role (kamera) için kapalı';
  end if;

  -- One bilet_ac. Two would mean the parameter list drifted and an old
  -- overload is still live, opening tickets that skip every check above.
  select count(*) into v_n from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'bilet_ac';
  if v_n <> 1 then
    raise exception '010: bilet_ac % adet (aşırı yükleme?)', v_n;
  end if;

  select count(*) into v_n from pg_indexes
   where schemaname = 'public' and indexname = 'biletler_acik_yer_ux';
  if v_n <> 1 then
    raise exception '010: biletler_acik_yer_ux oluşmadı';
  end if;
end $$;

commit;
