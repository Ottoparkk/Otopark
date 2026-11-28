# Oto yıkama Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Yönetici-set wash price in Tarife. Staff switch the wash on a ticket at
Giriş, in the ticket detail (HİZMETLER card) or at Tahsilat. The server adds the
wash to the fee, and İçeride cards show a drop badge on the car box.

**Architecture:** Migration 078 adds `tarifeler.yikama_kurus` and
`biletler.yikama_kurus` / `yikama_at`. One internal SQL function,
`bilet_ucreti(ticket, exit time)`, becomes the single "parking + wash" price.
Every place that priced a ticket before (`bilet_kapat`, `kamera_cikis_bildir`,
`acik_bilet_ara`, and the new preview RPC) calls it. The client only sends
on/off and displays server numbers.

**Tech Stack:** Postgres/Supabase SQL (migrations run by hand); React 19 + TS +
TanStack Query; Node checks in `tests/*.check.mjs`.

**Spec:** `docs/superpowers/specs/2026-11-27-oto-yikama-design.md`

## Global Constraints

- Money is integer kuruş, and the server prices it. The client never sends an amount.
- Migration format: a three-line banner, then `begin;` … `commit;`. Never edit a
  migration that has been run. Never run or depend on `074`.
- New function: `revoke all … from public` **and** `from anon, authenticated,
  service_role`, then grant narrowly, then assert with `has_function_privilege`
  in the migration's own `do $$` block. PASS 41's anon/service_role list must
  stay unchanged.
- UI copy is Turkish. Colours are tokens only. Tap targets ≥ 44 px. No
  horizontal scroll at 360 px. No emoji: use `IconYikama`.
- Tests first: smoke-test PASS blocks before the migration, a Node check before
  client logic.
- Migration before frontend deploy. Every screen is checked in the harness at
  360 / 375 / 430 px and in dark mode before the commit. No Co-Authored-By line.

## Review Focus

1. **The tariff price changes while a washed car is inside:** the ticket keeps
   its locked price (PASS 101).
2. **The wash is removed after points were used:** if `indirim_kurus` would
   exceed the new fee, refuse with the existing points message (PASS 101).
3. **An abonman car with a wash:** the fee is exactly the wash. The list says
   "Ücretsiz + 150 ₺" (PASS 102, check `yikama.check.mjs`).
4. **The camera closes a washed ticket:** the unpaid debt includes the wash (PASS 102).
5. **Giriş switch on, the wash call fails after the ticket opened:** the
   ticket stays open, and the screen says the wash wasn't added. It is never
   silent (Task 4 harness step).

---

### Task 1: Smoke test PASS 100–103 (must fail before 078)

**Files:**
- Modify: `supabase/tests/rls_smoke_test.sql` (new blocks before the final
  `ALL TESTS PASSED` notice, at line ~10660)

**Interfaces:**
- Produces the contract Task 2 must satisfy:
  - `tarife_guncelle(…existing 8 args…, p_yikama_kurus integer default null)`
  - `bilet_yikama(p_bilet_id uuid, p_acik boolean) returns integer`
  - `bilet_ucret_onizle(p_bilet_id uuid) returns integer`
  - `acik_bilet_ara` gains the output column `yikama_kurus integer`

- [ ] **Step 1: Write the PASS blocks.** Copy the role switching and plate
  style from PASS 96–99. Use fresh plates `ZZ100YK1`… that look like no
  other plate in the file (check with the scratchpad `komsu.py`). Read the
  state when checking it; never assume an empty car park.
  - **100 Tariff:** a Personel calling `tarife_guncelle(…, p_yikama_kurus => 15000)`
    raises. A Yönetici setting it gives `(select yikama_kurus from tarifeler
    where gecerli_bitis is null) = 15000`.
  - **101 Switch:** a Personel opens a ticket with `bilet_ac`.
    `bilet_yikama(id, true) = 15000` and `yikama_at` is not null. The Yönetici
    then sets the price to 20000; the ticket's `yikama_kurus` is still 15000,
    and a second `bilet_yikama(id, true)` still returns 15000.
    `bilet_ucret_onizle(id) = ucret_hesapla(giris_at, now(), tarife_id) + 15000`.
    `bilet_yikama(id, false)` returns null, and the preview drops by 15000.
    With `indirim_kurus` forced above the fee without the wash, switching off
    raises `'%puan%'`. Switching on a KAPALI ticket raises `'%açık değil%'`.
    With the tariff price null, switching on raises `'%tarifede tanımlı değil%'`.
    A PENDING user raises `'Yetkiniz yok.'`.
  - **102 Closing:** `bilet_kapat` on a washed ticket returns `ucret_kurus =
    parking + 15000`, and the `tahsilatlar` row has the same `tutar_kurus`. An
    abonman ticket with a wash closes at `ucret_kurus = 15000`.
    `kamera_cikis_bildir` on a washed ticket closes it at parking + 15000 with
    `tahsil_kurus = 0`. `acik_bilet_ara` returns the row's `yikama_kurus =
    15000` and an `ucret_kurus` that includes it.
  - **103 Free exit and grants:** `bilet_ucretsiz_cikis` on a washed open
    ticket gives `ucret_kurus = 0` and no `tahsilatlar` row.
    `has_function_privilege('anon', …)` and `('service_role', …)` are false
    for `bilet_yikama` and `bilet_ucret_onizle`.
    `has_function_privilege('authenticated',
    'public.bilet_ucreti(public.biletler, timestamptz)', 'execute')` is false.
- [ ] **Step 2:** The owner runs the smoke test **without 078** and expects a
  FAIL at PASS 100 (no `p_yikama_kurus` parameter). Hand the file over
  together with 078, saying to run 078 first. The failing run is optional
  because it touches the live DB; the run after 078 is the gate.

### Task 2: Migration 078_oto_yikama.sql

**Files:**
- Create: `supabase/migrations/078_oto_yikama.sql`

**Interfaces:**
- Consumes: the Task 1 contract.
- Produces: the columns `tarifeler.yikama_kurus integer null check (> 0)`,
  `biletler.yikama_kurus integer null check (> 0)` and `biletler.yikama_at
  timestamptz`. **No `yikama_by` column**: an FK with `on delete set null`
  would trip `biletler_immutable_guard` on closed tickets. Who switched it is
  in the audit log.

- [ ] **Step 1: `bilet_ucreti(p_b public.biletler, p_cikis timestamptz)
  returns integer`**, stable and security definer. It returns
  (`0` if `abonman_id`, else `ucret_hesapla(p_b.giris_at, p_cikis,
  p_b.tarife_id)`) + `coalesce(p_b.yikama_kurus, 0)`. Revoke it from
  everyone and grant it to no one.
- [ ] **Step 2: `tarife_guncelle`.** `drop function` the 8-argument signature
  from 051, recreate 051's body word for word plus `p_yikama_kurus integer
  default null` at the end, written into the new version row. Re-grant it to
  `authenticated` only.
- [ ] **Step 3: `bilet_yikama(p_bilet_id uuid, p_acik boolean) returns
  integer`.**
  - It requires `is_staff()`, locks the row `for update`, and needs `durum =
    'ACIK'`. Otherwise it raises `'Bilet açık değil; yıkama yalnızca araç
    içerideyken değiştirilebilir.'`
  - **On:** if the wash is already set, return it unchanged. Otherwise take
    `yikama_kurus` from `aktif_tarife()`; if it's null, raise `'Oto yıkama
    ücreti tarifede tanımlı değil.'` Set `yikama_kurus` and `yikama_at = now()`.
  - **Off:** if `indirim_kurus > bilet_ucreti(row with yikama null, now())`,
    raise `'Kullanılan puan ücretten fazla. Önce puan kullanımını geri alın.'`
    Then set both columns to null.
  - Write `audit('bilet_yikama', 'biletler', id, {plaka, acik, kurus})`.
    Return the new `yikama_kurus`. Grant it to `authenticated`.
- [ ] **Step 4: `bilet_ucret_onizle(p_bilet_id uuid) returns integer`.** It
  requires `is_staff()`. For `ACIK` it returns `bilet_ucreti(b, now())`;
  otherwise null. Grant it to `authenticated`.
- [ ] **Step 5: Re-create the three pricers from their latest bodies, word
  for word.** Only the pricing lines change, to `bilet_ucreti(v_b, …)`:
  - `bilet_kapat`: from `030`, `v_hesaplanan` uses `v_cikis`;
  - `kamera_cikis_bildir`: from `054`, `v_ucret` uses `p_zaman`;
  - `acik_bilet_ara`: from `077`, as a drop + create (the return type
    changes), with `yikama_kurus integer` added as the last column and the fee
    `bilet_ucreti(b, now())`.

  Keep their grants exactly as they were.
- [ ] **Step 6:** Add a `do $$` block with the `has_function_privilege`
  asserts for every function this migration creates or re-creates.
- [ ] **Step 7:** The owner runs 078, then the whole smoke test. Expected:
  `ALL TESTS PASSED (rolled back)`.

### Task 3: Client logic — list fee text (Node check first)

**Files:**
- Create: `src/features/gise/yikama.ts` (`import type` only)
- Create: `tests/yikama.check.mjs`

**Interfaces:**
- Produces:
  - `listeUcretMetni(b: { abonman_id: string | null; ucret_kurus: number;
    indirim_kurus: number; yikama_kurus: number | null }, formatTL: (k: number)
    => string): string`
  - `otoparkKurus(toplamKurus: number, yikamaKurus: number | null): number`.
    It returns `max(0, toplam − yikama)`, for the HİZMETLER "Otopark" row.

- [ ] **Step 1: Write the check.** The `formatTL` stub is `k => k/100 + ' ₺'`.
  - An abonman ticket without a wash gives `'Ücretsiz'`.
  - An abonman ticket with `yikama_kurus` 15000 gives `'Ücretsiz + 150 ₺'`.
  - `ucret_kurus` 35000 with `indirim_kurus` 5000 gives `'300 ₺'`.
  - `indirim_kurus` above `ucret_kurus` gives `'0 ₺'`.
  - `otoparkKurus(35000, 15000) === 20000`,
    `otoparkKurus(20000, null) === 20000` and `otoparkKurus(100, 15000) === 0`.
- [ ] **Step 2:** Run `node tests/yikama.check.mjs`. Expected: it fails
  (module not found).
- [ ] **Step 3:** Implement `yikama.ts`.
- [ ] **Step 4:** Run it again. Expected: every assertion passes.

### Task 4: UI

**Files:**
- Modify: `src/lib/types.ts`: add `yikama_kurus: number | null` to `Tarife`,
  `Bilet` and `AcikBilet`, and `yikama_at: string | null` to `Bilet`.
- Modify: `src/components/ui/icons.tsx`: add `IconYikama`, a drop:
  `M12 3.5s-6 6.6-6 10.5a6 6 0 0 0 12 0c0-3.9-6-10.5-6-10.5Z` plus the shine
  `M9.3 14.2a2.8 2.8 0 0 0 2.7 2.8`.
- Modify: `src/features/yonetim/api.ts` (the `tarife_guncelle` call: pass
  `p_yikama_kurus`) and `src/features/finans/Tarifeler.tsx`.
  - Add the field "Oto yıkama ücreti (₺)" under Kayıp bilet, with the hint
    "Boş bırakılırsa yıkama düğmesi görünmez."
  - Parse it with the same ₺→kuruş helper as the other fields. Empty → null.
- Modify: `src/features/gise/api.ts`:
  - `useUcretOnizleme` calls `bilet_ucret_onizle({ p_bilet_id })` and drops
    the client abonman shortcut. Its key gets `bilet?.yikama_kurus`.
  - New `useBiletYikama()`: `retry: false`, `{ bilet_id, acik }` →
    `bilet_yikama`. It invalidates `useGiseInvalidate()`, `['bilet', id]` and
    `['ucret', id]`.
  - New `useYikamaUcreti(): number | null`: reads the active tariff's
    `yikama_kurus`, the same query style as the existing tariff reads.
- Modify: `src/features/gise/components.tsx`:
  - `YikamaAnahtari({ acik, kurus, bekliyor, onDegis })`: the switch row from
    the mockup (icon, "Oto yıkama", "+150 ₺", ≥ 44 px).
  - `HizmetlerKarti({ bilet, toplamKurus })`: `BolumBasligi guclu` with the
    title "Hizmetler", an "Otopark" row from `otoparkKurus`, then
    `YikamaAnahtari`.
  - `BiletKart`: a round accent badge with `IconYikama` on the top-left of
    the `IconTile` when `yikama_kurus` is set. The fee text comes from
    `listeUcretMetni`.
- Modify: `src/features/gise/BiletDetay.tsx`: `HizmetlerKarti` goes between
  the fee card and `BiletDetayKarti`. It shows only when the ticket is ACIK
  and (the tariff has a price or the wash is already on).
- Modify: `src/features/gise/Cikis.tsx` (Tahsilat): `YikamaAnahtari` goes
  under the amount card, with the same visibility rule. When the wash is on,
  `BiletDetayKarti` shows "Otopark" and "Oto yıkama" rows.
- Modify: `src/features/gise/Giris.tsx`: `YikamaAnahtari` goes above "Giriş
  Ver" when the tariff has a price. After `bilet_ac` returns an id with the
  switch on, call `bilet_yikama(id, true)`. If that call fails, keep the
  ticket and show the error "Giriş kaydedildi, yıkama eklenemedi: <message>".
- Modify: the scratchpad harness `harness-detay/sahte-supabase.ts` for fake
  RPCs (`bilet_yikama`, `bilet_ucret_onizle`, the tariff with
  `yikama_kurus: 15000`, and a failure mode `?yikama_hata=1`). Add Giriş and
  Tarifeler routes to the harness `main.tsx`.

- [ ] **Step 1:** Run `npm run typecheck`. Expected: no errors.
- [ ] **Step 2: Click through in the harness** at 360 / 375 / 430 px and in
  dark mode:
  - Tarife: save with a price;
  - Giriş: switch on → entry (both RPCs called; check with `window.__rpc`);
  - Giriş with `?yikama_hata=1`: the error shows and the ticket was opened;
  - detail: switch on/off (preview changes);
  - Tahsilat: switch → the amount changes, then collect;
  - list: badge, plus "Ücretsiz + 150 ₺" on an abonman car.

  Send the owner screenshots.
- [ ] **Step 3:** Run `node tests/yikama.check.mjs` and every other
  `tests/*.check.mjs`, then `npm run build`. Expected: all pass.
- [ ] **Step 4: Commit** after the owner's go, with the 078 smoke-test
  results already in.
  - It contains 078, the smoke test, the new and changed `src` files, the
    check, the spec and the plan, plus the waiting Değiştir/Bilet change in
    `BiletDetay.tsx` and `components.tsx`.
  - Order on site: 078 → the smoke test → push.
