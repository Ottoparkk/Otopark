-- ============================================================================
-- 007  Çöp Kutusu — silme + geri alma
-- ============================================================================
--
-- Owner decision (2026-08-25): every entered record can be deleted, and a
-- deleted record lands in a recycle bin it can be restored from. Money-bearing
-- records delete too, and their collections are REVERSED with them — the owner
-- chose this over the "refuse, cancel instead" alternative.
--
-- THE THREE RULES THIS FILE ENFORCES
--
-- 1. A DELETE CANNOT ESCAPE THE SNAPSHOT. Capture is a BEFORE DELETE trigger,
--    not something each RPC remembers to call. It has to be BEFORE, not AFTER:
--    `tahsilatlar.bilet_id` is ON DELETE SET NULL, so by the time an AFTER
--    trigger ran, the collections belonging to that ticket would already be
--    detached and unfindable. Same transaction either way, so a failed delete
--    rolls the snapshot back with it.
--
-- 2. MONEY NEVER SURVIVES ITS SOURCE. Deleting a ticket deletes its
--    `tahsilatlar` rows — including any counter-entry that reversed one, which
--    `iptal_of` would otherwise leave stranded — and the same for subscription
--    payments. Leaving them would keep the cash in the daily total with
--    nothing explaining it, which is the state that makes a kasa unauditable.
--
-- 3. A COUNTED DRAWER IS A FACT, A COMPUTED TOTAL IS NOT. If the affected
--    shift is already closed, `sayilan_nakit_kurus` (what a human physically
--    counted) is left ALONE and `beklenen_nakit_kurus` / `fark_kurus` are
--    recomputed. Deleting a cash sale after the count legitimately widens the
--    variance — that is the truth, and silently keeping the old figure would
--    hide it. Every such adjustment is written to audit_log.
--
-- WHAT STILL CANNOT BE DELETED, AND WHY IT IS NOT AN OVERSIGHT
--
--   • A tariff any ticket was priced under — `biletler.tarife_id` is ON DELETE
--     RESTRICT in 001, deliberately. An unused tariff version deletes fine.
--   • A profile that has ever held a shift — `vardiyalar.personel_id` is
--     RESTRICT. Staff are disabled, not deleted, so the audit trail keeps a
--     name to point at.
--   • `audit_log` and `puan_hareketleri` are append-only ledgers by design.
-- ============================================================================

begin;

-- ---------------------------------------------------------------- table ----

create table if not exists public.cop (
  id         uuid primary key default gen_random_uuid(),
  tablo      text        not null,
  kayit_id   uuid        not null,
  -- The row exactly as it was, plus whatever had to be deleted alongside it.
  veri       jsonb       not null,
  ek         jsonb       not null default '{}'::jsonb,
  -- Rendered at delete time: the parent rows a label would need may themselves
  -- be gone by the time anyone opens the bin.
  ozet       text        not null,
  silen      uuid        references public.profiles(id) on delete set null,
  silindi_at timestamptz not null default now()
);
create index if not exists cop_tarih_ix on public.cop (silindi_at desc);
create index if not exists cop_kayit_ix on public.cop (tablo, kayit_id);

alter table public.cop enable row level security;

-- Read-only to Yönetici; every write goes through an RPC. No client INSERT
-- path at all, so a forged trash row cannot be used to inject a restore.
drop policy if exists cop_select on public.cop;
create policy cop_select on public.cop for select to authenticated
  using (public.is_yonetici());

grant select on public.cop to authenticated;
revoke insert, update, delete on public.cop from authenticated;

-- ------------------------------------------------------------- capture ----

/**
 * Snapshots a row on its way out, with any dependent rows that are about to
 * be deleted with it.
 *
 * `app.cop_geri_al` suppresses capture during a restore: re-inserting a row
 * does not delete anything, but the delete of a FAILED restore attempt would
 * otherwise write a second trash entry for the same record.
 */
create or replace function public.cop_yaz() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_ozet text;
  v_ek   jsonb := '{}'::jsonb;
  v_row  jsonb := to_jsonb(old);
begin
  if coalesce(current_setting('app.cop_geri_al', true), '') <> '' then
    return old;
  end if;

  case tg_table_name
    when 'biletler' then
      v_ozet := old.plaka || ' — ' ||
                to_char(old.giris_at at time zone 'Europe/Istanbul', 'DD.MM.YYYY HH24:MI');
      -- Captured BEFORE the delete, while bilet_id still points here.
      select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_ek
        from public.tahsilatlar t where t.bilet_id = old.id;
      v_ek := jsonb_build_object('tahsilatlar', v_ek);

    when 'abonmanlar' then
      v_ozet := old.plaka || ' — abonman';
      select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) into v_ek
        from public.tahsilatlar t where t.abonman_id = old.id;
      v_ek := jsonb_build_object('tahsilatlar', v_ek);

    when 'kasa_hareketleri' then
      v_ozet := coalesce(nullif(btrim(old.aciklama), ''),
                         case when old.tur = 'GELIR' then 'Gelir' else 'Gider' end)
                || ' — ' || (old.tutar_kurus / 100.0)::numeric(12,2) || ' ₺';
    when 'park_yerleri'   then v_ozet := old.kod || ' — park yeri';
    when 'rezervasyonlar' then v_ozet := coalesce(old.plaka, 'Abonman') || ' — rezervasyon';
    when 'hesaplar'       then v_ozet := old.ad || ' — puan hesabı';
    when 'hesap_araclari' then v_ozet := old.plaka || ' — hesap aracı';
    when 'istisnalar'     then v_ozet := coalesce(old.plaka, '(plakasız)') || ' — ' || old.tur;
    when 'tarifeler'      then v_ozet := 'Tarife — ' || (old.ilk_saat_kurus / 100.0)::numeric(12,2) || ' ₺';
    else v_ozet := tg_table_name;
  end case;

  insert into public.cop (tablo, kayit_id, veri, ek, ozet, silen)
  values (tg_table_name, old.id, v_row, v_ek, v_ozet, auth.uid());

  -- Bounded, so the bin cannot grow without limit. Oldest entries fall out and
  -- become unrecoverable — which is why this is 200 and not 20.
  delete from public.cop c
   where c.id in (select id from public.cop order by silindi_at desc offset 200);

  return old;
end $$;

drop trigger if exists cop_biletler        on public.biletler;
drop trigger if exists cop_abonmanlar      on public.abonmanlar;
drop trigger if exists cop_kasa            on public.kasa_hareketleri;
drop trigger if exists cop_park_yerleri    on public.park_yerleri;
drop trigger if exists cop_rezervasyonlar  on public.rezervasyonlar;
drop trigger if exists cop_hesaplar        on public.hesaplar;
drop trigger if exists cop_hesap_araclari  on public.hesap_araclari;
drop trigger if exists cop_istisnalar      on public.istisnalar;
drop trigger if exists cop_tarifeler       on public.tarifeler;

create trigger cop_biletler       before delete on public.biletler        for each row execute function public.cop_yaz();
create trigger cop_abonmanlar     before delete on public.abonmanlar      for each row execute function public.cop_yaz();
create trigger cop_kasa           before delete on public.kasa_hareketleri for each row execute function public.cop_yaz();
create trigger cop_park_yerleri   before delete on public.park_yerleri    for each row execute function public.cop_yaz();
create trigger cop_rezervasyonlar before delete on public.rezervasyonlar  for each row execute function public.cop_yaz();
create trigger cop_hesaplar       before delete on public.hesaplar        for each row execute function public.cop_yaz();
create trigger cop_hesap_araclari before delete on public.hesap_araclari  for each row execute function public.cop_yaz();
create trigger cop_istisnalar     before delete on public.istisnalar      for each row execute function public.cop_yaz();
create trigger cop_tarifeler      before delete on public.tarifeler       for each row execute function public.cop_yaz();

-- --------------------------------------------------------- shift repair ----

/**
 * Recomputes a CLOSED shift's expected cash after its collections changed.
 *
 * `sayilan_nakit_kurus` is never touched: it is what a person counted out of a
 * drawer, and no later edit can change what was physically there. The variance
 * moves instead, which is the honest outcome — and it is audited, because a
 * variance that changes after sign-off is exactly what a Yönetici must be able
 * to find later.
 */
create or replace function public.vardiya_yeniden_hesapla(p_vardiya_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_v        public.vardiyalar;
  v_nakit    integer;
  v_beklenen integer;
  v_fark     integer;
begin
  if p_vardiya_id is null then
    return;
  end if;
  select * into v_v from public.vardiyalar where id = p_vardiya_id;
  if not found or v_v.kapanis_at is null then
    return;   -- still open: vardiya_kapat will compute it correctly later
  end if;

  select coalesce(sum(t.tutar_kurus), 0)::integer into v_nakit
    from public.tahsilatlar t
   where t.vardiya_id = v_v.id and t.yontem = 'NAKIT';

  v_beklenen := v_v.acilis_nakit_kurus + v_nakit;
  v_fark     := coalesce(v_v.sayilan_nakit_kurus, 0) - v_beklenen;

  if v_beklenen is distinct from v_v.beklenen_nakit_kurus
     or v_fark is distinct from v_v.fark_kurus then
    update public.vardiyalar
       set beklenen_nakit_kurus = v_beklenen, fark_kurus = v_fark
     where id = v_v.id;

    perform public.audit('vardiya_yeniden_hesap', 'vardiyalar', v_v.id,
      jsonb_build_object('eski_beklenen', v_v.beklenen_nakit_kurus,
                         'yeni_beklenen', v_beklenen,
                         'eski_fark', v_v.fark_kurus, 'yeni_fark', v_fark));
  end if;
end $$;

-- -------------------------------------------------------------- deletes ----

/**
 * Deletes a ticket and everything it collected.
 *
 * Yönetici only. The counter-entry of a cancellation goes with the original —
 * `tahsilatlar.iptal_of` is ON DELETE SET NULL, so deleting only the original
 * would strand a negative row that no longer reverses anything.
 */
create or replace function public.bilet_sil(p_bilet_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_b        public.biletler;
  v_vardiya  uuid[];
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici silebilir.';
  end if;

  select * into v_b from public.biletler where id = p_bilet_id;
  if not found then
    raise exception 'Bilet bulunamadı.';
  end if;

  -- Every shift whose totals are about to change, collected before the rows go.
  select coalesce(array_agg(distinct t.vardiya_id) filter (where t.vardiya_id is not null), '{}')
    into v_vardiya
    from public.tahsilatlar t where t.bilet_id = p_bilet_id;

  perform public.audit('bilet_sil', 'biletler', p_bilet_id,
    jsonb_build_object('plaka', v_b.plaka, 'durum', v_b.durum,
                       'tahsil', v_b.tahsil_kurus));

  -- Counter-entries first: they point AT the rows deleted next.
  delete from public.tahsilatlar
   where iptal_of in (select id from public.tahsilatlar where bilet_id = p_bilet_id);
  delete from public.tahsilatlar where bilet_id = p_bilet_id;

  delete from public.biletler where id = p_bilet_id;

  perform public.vardiya_yeniden_hesapla(v) from unnest(v_vardiya) as v;
end $$;

/** Deletes a subscription and any payment taken for it. */
create or replace function public.abonman_sil(p_abonman_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare v_vardiya uuid[];
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici silebilir.';
  end if;
  if not exists (select 1 from public.abonmanlar where id = p_abonman_id) then
    raise exception 'Abonman bulunamadı.';
  end if;

  select coalesce(array_agg(distinct t.vardiya_id) filter (where t.vardiya_id is not null), '{}')
    into v_vardiya
    from public.tahsilatlar t where t.abonman_id = p_abonman_id;

  perform public.audit('abonman_sil', 'abonmanlar', p_abonman_id, null);

  delete from public.tahsilatlar
   where iptal_of in (select id from public.tahsilatlar where abonman_id = p_abonman_id);
  delete from public.tahsilatlar where abonman_id = p_abonman_id;
  delete from public.abonmanlar where id = p_abonman_id;

  perform public.vardiya_yeniden_hesapla(v) from unnest(v_vardiya) as v;
end $$;

/**
 * Deletes a tariff VERSION.
 *
 * `biletler.tarife_id` is ON DELETE RESTRICT, so a tariff any ticket was
 * priced under refuses at the constraint. That error is caught and re-raised
 * in Turkish, because "violates foreign key constraint" is not a sentence an
 * operator can act on. The single ACTIVE tariff is also refused: deleting it
 * would leave the gate with no price at all.
 */
create or replace function public.tarife_sil(p_tarife_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici silebilir.';
  end if;
  if not exists (select 1 from public.tarifeler where id = p_tarife_id) then
    raise exception 'Tarife bulunamadı.';
  end if;
  if exists (select 1 from public.tarifeler where id = p_tarife_id and gecerli_bitis is null) then
    raise exception 'Geçerli tarife silinemez. Önce yeni bir tarife sürümü oluşturun.';
  end if;

  perform public.audit('tarife_sil', 'tarifeler', p_tarife_id, null);
  begin
    delete from public.tarifeler where id = p_tarife_id;
  exception when foreign_key_violation then
    raise exception 'Bu tarifeyle ücretlendirilmiş biletler var; tarife silinemez.';
  end;
end $$;

/**
 * The plain records: no money hangs off any of these, so one guarded RPC
 * covers them all. The table name is matched against a FIXED allowlist and
 * never interpolated — a caller-supplied identifier reaching `execute` would
 * be an injection surface, and there is no reason to accept one.
 */
create or replace function public.kayit_sil(p_tablo text, p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici silebilir.';
  end if;

  perform public.audit('kayit_sil', p_tablo, p_id, null);

  -- `puan_hareketleri.hesap_id` is ON DELETE CASCADE, and a cascade runs as
  -- the table owner — the REVOKE that makes that ledger append-only for
  -- clients would not stop it. Deleting an account with movements would
  -- therefore destroy a lira-denominated liability record and, because the
  -- movements are not part of the snapshot, restoring the account would not
  -- bring them back. Refuse instead; an account with no history deletes fine.
  if p_tablo = 'hesaplar'
     and exists (select 1 from public.puan_hareketleri where hesap_id = p_id) then
    raise exception 'Puan hareketi olan hesap silinemez. Önce hesabı pasife alın.';
  end if;

  case p_tablo
    when 'kasa_hareketleri' then delete from public.kasa_hareketleri where id = p_id;
    when 'park_yerleri'     then delete from public.park_yerleri     where id = p_id;
    when 'rezervasyonlar'   then delete from public.rezervasyonlar   where id = p_id;
    when 'hesaplar'         then delete from public.hesaplar         where id = p_id;
    when 'hesap_araclari'   then delete from public.hesap_araclari   where id = p_id;
    when 'istisnalar'       then delete from public.istisnalar       where id = p_id;
    else raise exception 'Bu kayıt türü silinemez: %', p_tablo;
  end case;

  if not found then
    raise exception 'Kayıt bulunamadı.';
  end if;
end $$;

-- -------------------------------------------------------------- restore ----

/**
 * Puts a deleted record back, with its original id.
 *
 * The id matters: everything that referenced this row — a ticket's tariff, a
 * collection's ticket — was pointing at that uuid, so restoring under a fresh
 * one would put the row back without reconnecting anything to it.
 *
 * `app.cop_geri_al` is set for the transaction so the capture trigger stays
 * quiet, and so any trigger that fires on INSERT knows this is a restore
 * rather than a new event worth notifying anyone about.
 */
create or replace function public.cop_geri_al(p_cop_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_c       public.cop;
  v_vardiya uuid[];
  v_t       jsonb;
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
    jsonb_build_object('ozet', v_c.ozet));

  perform public.vardiya_yeniden_hesapla(v)
    from unnest(coalesce(v_vardiya, '{}')) as v where v is not null;
end $$;

/** Permanently removes one bin entry. There is no undo past this. */
create or replace function public.cop_kalici_sil(p_cop_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_yonetici() then
    raise exception 'Yalnızca Yönetici silebilir.';
  end if;
  delete from public.cop where id = p_cop_id;
  if not found then
    raise exception 'Çöp kaydı bulunamadı.';
  end if;
end $$;

-- ---------------------------------------------------------------- grants ---
-- İKİ yol birden kapatılmalı, ve `from public` yalnızca birincisini kapatır:
--   1. PostgreSQL yeni fonksiyona EXECUTE'u PUBLIC'e verir (`authenticated` de
--      PUBLIC üyesidir).
--   2. Supabase ayrıca `anon`, `authenticated` ve `service_role` rollerine
--      DOĞRUDAN verir — bu, PUBLIC'ten geri alınınca kalkmaz.
-- 009'un doğrulama bloğu bunu canlıda yakaladı; ayrıntısı 012'de.

revoke all on function public.cop_yaz() from public, anon, authenticated, service_role;
revoke all on function public.vardiya_yeniden_hesapla(uuid) from public, anon, authenticated, service_role;
revoke all on function public.bilet_sil(uuid) from public, anon, authenticated, service_role;
revoke all on function public.abonman_sil(uuid) from public, anon, authenticated, service_role;
revoke all on function public.tarife_sil(uuid) from public, anon, authenticated, service_role;
revoke all on function public.kayit_sil(text, uuid) from public, anon, authenticated, service_role;
revoke all on function public.cop_geri_al(uuid) from public, anon, authenticated, service_role;
revoke all on function public.cop_kalici_sil(uuid) from public, anon, authenticated, service_role;

grant execute on function public.bilet_sil(uuid)        to authenticated;
grant execute on function public.abonman_sil(uuid)      to authenticated;
grant execute on function public.tarife_sil(uuid)       to authenticated;
grant execute on function public.kayit_sil(text, uuid)  to authenticated;
grant execute on function public.cop_geri_al(uuid)      to authenticated;
grant execute on function public.cop_kalici_sil(uuid)   to authenticated;

-- The direct DELETE grants these RPCs replace. Removing them is what makes the
-- RPC the ONLY way out: a client that could still DELETE a row directly would
-- reverse no money, and the shift totals would drift with nothing to show why.
revoke delete on public.rezervasyonlar from authenticated;
revoke delete on public.park_yerleri   from authenticated;
drop policy if exists yerler_delete on public.park_yerleri;
drop policy if exists rezervasyonlar_delete on public.rezervasyonlar;

-- kasa_hareketleri and hesap_araclari were reachable through `for all`
-- policies; those stay (Yönetici-scoped) but the client no longer uses them.
revoke delete on public.kasa_hareketleri from authenticated;
revoke delete on public.hesap_araclari   from authenticated;
revoke delete on public.hesaplar         from authenticated;

-- ------------------------------------------------------------- verify ------
do $$
declare v_n integer;
begin
  -- Every capture trigger present.
  select count(*) into v_n from pg_trigger
   where not tgisinternal and tgname like 'cop\_%';
  if v_n <> 9 then
    raise exception '007: 9 çöp tetikleyicisi bekleniyordu, % bulundu', v_n;
  end if;

  -- The helper must not be client-callable: it rewrites a signed-off shift.
  if has_function_privilege('authenticated', 'public.vardiya_yeniden_hesapla(uuid)', 'execute') then
    raise exception '007: vardiya_yeniden_hesapla istemciye açık';
  end if;

  -- No direct DELETE path may remain on a money-bearing table.
  if has_table_privilege('authenticated', 'public.kasa_hareketleri', 'delete')
     or has_table_privilege('authenticated', 'public.rezervasyonlar', 'delete')
     or has_table_privilege('authenticated', 'public.park_yerleri', 'delete') then
    raise exception '007: doğrudan DELETE yetkisi hâlâ açık';
  end if;
end $$;

commit;
