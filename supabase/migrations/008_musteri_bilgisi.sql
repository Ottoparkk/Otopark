-- ============================================================================
-- 008  Müşteri ve araç bilgisi, not, ve liste özeti
--
-- Four optional fields on a ticket: what the car is, who the driver is, how to
-- reach them, and a free note. Filled in at Giriş, correctable at Tahsilat
-- while the car is still inside.
--
-- Plus two columns on the open-ticket list so a row can show a note marker and
-- the fee accrued so far WITHOUT the client pricing anything: the fee comes
-- from `ucret_hesapla`, the same function bilet_kapat uses, so the number in
-- the list, the number on the collect screen and the number actually charged
-- all have one implementation. Fifty rows would otherwise be fifty round
-- trips, each returning a figure the client would have to trust.
--
-- Three rules this migration holds to, in order of how expensive they are to
-- get wrong:
--
--  1. NONE of this may ever cost a ticket. A car in the lot with no record is
--     an unbillable car and an argument at the barrier. So a too-long model
--     name is truncated rather than refused, and every field is nullable with
--     no default — a driver who says nothing still gets a ticket.
--
--  2. The client cannot write these directly. `biletler` has no UPDATE grant
--     (003) and gains none here; editing goes through bilet_musteri_guncelle,
--     which refuses anything that is not still ACIK. That keeps
--     biletler_immutable_guard the single answer to "can this row change".
--
--  3. bilet_ac's parameter list changes, so the old signature is DROPPED, not
--     replaced. `create or replace` with a different parameter list adds an
--     overload and leaves the previous function callable — the 7-argument form
--     would still exist, still work, and silently discard everything below.
--
-- KVKK: a name and a phone number are personal data, protected here by RBAC
-- rather than encryption — the same treatment plates already get. They are
-- readable by staff for open tickets and by Yönetici throughout (003's
-- biletler_select is unchanged), and they are carried by the ticket, so the
-- existing retention story covers them without a new job.
-- ============================================================================

begin;

-- ------------------------------------------------------------- columns ----

alter table public.biletler
  add column if not exists arac_bilgi  text,
  add column if not exists musteri_ad  text,
  add column if not exists musteri_tel text,
  add column if not exists notlar      text;

alter table public.biletler
  drop constraint if exists biletler_arac_bilgi_ck,
  drop constraint if exists biletler_musteri_ad_ck,
  drop constraint if exists biletler_musteri_tel_ck,
  drop constraint if exists biletler_notlar_ck;

alter table public.biletler
  -- The lower bound is what makes '' impossible: blank is stored as NULL, so
  -- "no name" has exactly one representation rather than two.
  add constraint biletler_arac_bilgi_ck
    check (arac_bilgi is null or char_length(arac_bilgi) between 1 and 60),
  add constraint biletler_musteri_ad_ck
    check (musteri_ad is null or char_length(musteri_ad) between 1 and 80),
  -- Byte-identical to abonmanlar.musteri_tel: ten digits, no leading zero,
  -- stored without the country code. Two customer-phone rules in one database
  -- would be one rule too many.
  add constraint biletler_musteri_tel_ck
    check (musteri_tel is null or musteri_tel ~ '^[1-9][0-9]{9}$'),
  add constraint biletler_notlar_ck
    check (notlar is null or char_length(notlar) between 1 and 500);

-- Finding a car by the driver's name is the point of storing it. Trigram would
-- be better for partial matches but needs an extension; these serve the exact
-- and prefix lookups the exit search actually issues.
create index if not exists biletler_musteri_ad_ix  on public.biletler (musteri_ad);
create index if not exists biletler_musteri_tel_ix on public.biletler (musteri_tel);

-- ------------------------------------------------------------- bilet_ac ---
-- See rule 3 above. Dropping takes the grants with it; they are restored at
-- the foot of this file.

drop function if exists public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb);

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

  begin
    insert into public.biletler (
      islem_id, plaka, giris_at, tarife_id, abonman_id, park_yeri_id,
      vardiya_id, giris_by, giris_kaynak, giris_foto,
      gecikmeli_kayit, kaynak_zaman, alindi_zaman,
      arac_bilgi, musteri_ad, musteri_tel, notlar
    ) values (
      p_islem_id, v_plaka, v_zaman, v_tarife, v_abonman, p_park_yeri_id,
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
    raise;
  end;

  -- No points on a ₺0 stay: subscribers would otherwise farm rewards for
  -- parking they did not pay for.
  if coalesce(v_puan_aktif, false) and v_abonman is null then
    perform public.puan_kazandir(v_id, v_plaka);
  end if;

  return v_id;
end $$;

-- ------------------------------------------------ bilet_musteri_guncelle --

/**
 * Correct the customer details on a ticket that is still open.
 *
 * All three columns are written on every call, so the form that submits them
 * owns the whole set: clearing a field in the UI clears it in the row. A
 * partial-update variant would need a "leave this alone" sentinel, and NULL is
 * already taken — it means "no value", which is precisely what clearing does.
 *
 * ACIK only, and checked HERE rather than left to biletler_immutable_guard:
 * the trigger's message is about closed tickets in general, while a caller on
 * this path deserves to be told which of the two states the ticket is in and
 * that the money has already been taken.
 *
 * is_staff(), not is_yonetici(): the operator at the barrier is the one who
 * typed the name in the first place, and a phone digit fixed at collection is
 * the whole reason this exists. It writes nothing that touches money.
 */
-- If an earlier revision of THIS file was ever applied, the 4-argument form
-- exists and `create or replace` would leave it behind as a live overload.
drop function if exists public.bilet_musteri_guncelle(uuid, text, text, text);

create or replace function public.bilet_musteri_guncelle(
  p_bilet_id    uuid,
  p_arac_bilgi  text default null,
  p_musteri_ad  text default null,
  p_musteri_tel text default null,
  p_notlar      text default null
) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_durum public.bilet_durum;
  v_arac  text;
  v_ad    text;
  v_tel   text;
  v_not   text;
begin
  if not public.is_staff() then
    raise exception 'Yetkiniz yok.';
  end if;

  select b.durum into v_durum from public.biletler b where b.id = p_bilet_id;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;
  if v_durum <> 'ACIK' then
    raise exception
      'Bu bilet kapanmış; müşteri bilgisi yalnızca araç içerideyken düzenlenebilir.';
  end if;

  -- Identical normalisation to bilet_ac, deliberately: a number typed at the
  -- barrier and the same number corrected at the till must store the same way,
  -- or the two paths would disagree about what "already recorded" means.
  v_arac := nullif(btrim(coalesce(p_arac_bilgi, '')), '');
  v_ad   := nullif(btrim(coalesce(p_musteri_ad, '')), '');
  v_tel  := nullif(regexp_replace(coalesce(p_musteri_tel, ''), '[^0-9]', '', 'g'), '');
  if v_tel is not null and v_tel !~ '^[1-9][0-9]{9}$' then
    raise exception 'Geçersiz müşteri numarası: başında 0 olmadan 10 hane girin.';
  end if;
  v_arac := left(v_arac, 60);
  v_ad   := left(v_ad, 80);
  v_not  := left(nullif(btrim(coalesce(p_notlar, '')), ''), 500);

  update public.biletler
     set arac_bilgi  = v_arac,
         musteri_ad  = v_ad,
         musteri_tel = v_tel,
         notlar      = v_not
   where id = p_bilet_id;
end $$;

-- --------------------------------------------------- acik_bilet_ara -------

/**
 * The open-vehicle list, now carrying two derived columns.
 *
 * DROPPED first: `create or replace` cannot change a function's OUT columns,
 * and the parameter list is unchanged, so there is no overload to worry about
 * — only the return type, which Postgres refuses to alter in place.
 *
 * `notu_var` is a boolean rather than the note itself. The row only needs to
 * show a marker, and this list refetches every 30 seconds on a gate phone's
 * mobile data — shipping up to 500 characters per row, fifty rows at a time,
 * to decide whether to draw one icon is the sort of thing that is invisible on
 * wifi and expensive at a barrier. The note is read where it can be acted on.
 *
 * `ucret_kurus` is the fee accrued SO FAR, priced by `ucret_hesapla` — the
 * same function `bilet_kapat` calls. That is the whole reason it is computed
 * here and not in the client: the figure in the list, the figure on the
 * collect screen and the figure actually charged then cannot diverge. A
 * subscriber reads 0, matching what bilet_kapat will do rather than what the
 * tariff would say.
 */
drop function if exists public.acik_bilet_ara(text);

create or replace function public.acik_bilet_ara(p_q text default null)
returns table (
  id uuid, plaka text, giris_at timestamptz,
  abonman_id uuid, park_yeri_id uuid, cikis_bekliyor_at timestamptz,
  indirim_kurus integer, puan_kullanilan integer, tarife_id uuid,
  gecikmeli_kayit boolean,
  notu_var boolean, ucret_kurus integer
)
language plpgsql stable security definer set search_path = public as $$
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
         case when b.abonman_id is not null then 0
              else public.ucret_hesapla(b.giris_at, now(), b.tarife_id) end
    from public.biletler b
   where b.durum = 'ACIK'
     and (v_q = '' or b.plaka like '%' || v_q || '%'
                   or (length(v_q) >= 3 and right(b.plaka, length(v_q)) = v_q))
   order by
     case when v_q = '' then 2
          when b.plaka = v_q then 0
          when b.plaka like v_q || '%' then 1
          else 2 end,
     b.cikis_bekliyor_at desc nulls last,
     b.giris_at desc
   limit 50;
end $$;

-- -------------------------------------------------------------- grants ----
-- İKİ yol birden kapatılmalı, ve `from public` yalnızca birincisini kapatır:
--   1. PostgreSQL yeni fonksiyona EXECUTE'u PUBLIC'e verir (`authenticated` de
--      PUBLIC üyesidir).
--   2. Supabase ayrıca `anon`, `authenticated` ve `service_role` rollerine
--      DOĞRUDAN verir — bu, PUBLIC'ten geri alınınca kalkmaz.
-- 009'un doğrulama bloğu bunu canlıda yakaladı; ayrıntısı 012'de.

revoke all on function
  public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb, text, text, text, text)
  from public, anon, authenticated, service_role;
revoke all on function
  public.bilet_musteri_guncelle(uuid, text, text, text, text) from public, anon, authenticated, service_role;
revoke all on function public.acik_bilet_ara(text) from public, anon, authenticated, service_role;

grant execute on function
  public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb, text, text, text, text)
  to authenticated;
grant execute on function
  public.bilet_musteri_guncelle(uuid, text, text, text, text) to authenticated;
grant execute on function public.acik_bilet_ara(text) to authenticated;

-- The camera webhook runs as service_role with no JWT, which is why bilet_ac
-- tolerates a null auth.uid(). It never sends the four new arguments.
grant execute on function
  public.bilet_ac(text, uuid, public.kaynak, timestamptz, text, uuid, jsonb, text, text, text, text)
  to service_role;

-- -------------------------------------------------------------- verify ----
do $$
declare v_n integer;
begin
  -- Exactly one bilet_ac. Two would mean the drop above missed and the old
  -- 7-argument form is still live, quietly ignoring every new field.
  select count(*) into v_n from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'bilet_ac';
  if v_n <> 1 then
    raise exception '008: bilet_ac % adet (aşırı yükleme?)', v_n;
  end if;

  select count(*) into v_n from information_schema.columns
   where table_schema = 'public' and table_name = 'biletler'
     and column_name in ('arac_bilgi', 'musteri_ad', 'musteri_tel', 'notlar');
  if v_n <> 4 then
    raise exception '008: 4 kolon bekleniyordu, % bulundu', v_n;
  end if;

  -- One of each, for the same reason bilet_ac is checked: an overload left
  -- behind would still be callable and would silently drop the note.
  select count(*) into v_n from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('bilet_musteri_guncelle', 'acik_bilet_ara');
  if v_n <> 2 then
    raise exception '008: bilet_musteri_guncelle/acik_bilet_ara % adet', v_n;
  end if;

  -- The client must not have gained a way around bilet_musteri_guncelle.
  if has_table_privilege('authenticated', 'public.biletler', 'UPDATE') then
    raise exception '008: authenticated biletler üzerinde UPDATE yetkisi kazanmış';
  end if;

  if has_function_privilege('public',
       'public.bilet_musteri_guncelle(uuid, text, text, text, text)', 'EXECUTE') then
    raise exception '008: bilet_musteri_guncelle PUBLIC''e açık kalmış';
  end if;
end $$;

commit;
