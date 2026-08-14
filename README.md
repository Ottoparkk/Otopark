# Otopark

A mobile-first PWA for a single paid car park: vehicle entry and exit, duration
and fee calculation, collection, monthly subscriptions, reserved spots and shift
cash counts.

The point is to make the cash changing hands at the gate auditable. An unbilled
hour or a "forgotten" ticket leaves no trace on paper, which makes it an
invisible loss; here every entry, duration and collection becomes a durable
server-side record.

**Status:** database layer and UI are written; `npm run build` is clean. The
migrations have **not been run yet** — no screen counts as tested against real
data until `001` → `005` and then `rls_smoke_test.sql` have been run in the SQL
editor and the result seen. Setup and verification: [SETUP.md](SETUP.md).

---

## Stack

Vite · React · TypeScript · Tailwind v4 · React Router · TanStack Query ·
Supabase (Postgres + Auth + Storage + Edge Functions + pg_cron) ·
vite-plugin-pwa · GitHub Pages

## Roles

| | Yönetici | Personel |
|---|:--:|:--:|
| Open/close a ticket, collect | ✅ | ✅ |
| Live occupancy, today's total | ✅ | ✅ *(aggregate RPC only)* |
| Own shift | ✅ | ✅ |
| Read tariff amounts | ✅ | ✅ *(it's on the sign at the gate anyway)* |
| Historical revenue, reports, kasa, audit log | ✅ | ❌ |
| Subscription **price** | ✅ | ❌ |
| Subscription **validity** | ✅ | ✅ *(boolean RPC)* |
| Points balance **for the plate at the gate** | ✅ | ✅ *(RPC scoped to one plate)* |
| Account list, points history, earn rate | ✅ | ❌ |
| User management, role changes | ✅ | ❌ |

New signups are born `PENDING` with `rol = NULL`, and RLS reads that as **zero
rows in every table**. The client-side route guards exist for UX only — **the
boundary is always RLS and the RPC.**

## The six invariants that live in Postgres

These sit in the database rather than the client, because the client can always
be bypassed:

1. **One open ticket per plate.** A partial unique index; two operators cannot
   both tap "Giriş" for the same car.
2. **One function computes the fee.** The live preview on the exit screen and
   the amount actually charged come from the same function and cannot diverge.
   A client-computed amount is never accepted.
3. **Tariffs are versioned, never edited in place.** A ticket snapshots
   `tarife_id` at entry, so a midday price rise cannot re-price a car that came
   in at 09:00.
4. **A closed ticket is immutable.** Corrections are counter-entries. The only
   exceptions are a deleted parent's reference going NULL, and the KVKK photo
   purge.
5. **A reserved spot cannot be double-booked.** `EXCLUDE USING gist` — a
   database constraint, not a client-side filter.
6. **A points balance is a view over an append-only ledger.** Outstanding points
   are a real lira liability, so they get the same treatment as the till.

Occupancy, revenue and points are **always derived** — a stored counter drifts,
a view cannot.

## Camera

The app works completely with a phone camera; ANPR hardware drops in later with
**no schema change**. `bilet_ac` has carried the source (`MOBIL|KAMERA|MANUEL`)
and an `islem_id` idempotency key since day one.

Two rules were written before any hardware exists, because retrofitting them is
expensive:

- **A camera cannot collect money.** An exit event only marks the ticket as
  waiting at the gate; `bilet_kapat` has no service-role path. Letting a webhook
  mark a ticket closed would book revenue nobody handed over.
- **The clock is read per source.** A camera **must** supply its own timestamp
  (it may have sat in a buffer for hours); a phone **must not** (a skewed client
  clock would silently mis-bill).

## Plate OCR

Off by default; the app runs with no external dependency and no cost. When
enabled, an OCR read is a **suggestion, not a commitment**: it prefills the
field and the operator confirms. A low-confidence read leaves the field empty —
a bad read costs a manual entry, never a wrong charge.

The provider is changed through `otopark_ayarlari` (no migration needed).
`plaka_okuma_log` keeps the suggestion beside what was accepted, so after a
month the real hit rate is **measured**, not argued about.

## Connectivity

Online only. Entry **retries through short drops** (~3 attempts / ~10s), then
fails **visibly**. **Collection never retries** — a silent repeat is how double
charges happen.

An offline queue was deliberately left out: replay conflicts, device clock skew
and two devices queueing the same car added up to a sync engine guarding against
a rare event with a workable manual fallback. `islem_id` is in place, so the
door stays open: adding one later needs no schema change.

## Layout

```
src/styles/index.css  THE DESIGN SYSTEM — every colour is a token here
src/app/              AppShell · route guards · AuthProvider
src/components/ui/    primitives · ConfirmDialog · FormModal · PlakaInput · YontemSecici
src/features/
  auth/               sign in · sign up · reset · pending approval · disabled
  gise/               open tickets · entry · exit · ticket detail   ← where the money flows
  plaka/              camera capture + OCR suggestion
  abonman/            subscription list · detail (collect + renew)
  yerler/             parking spots · reservations
  hesap/              loyalty accounts · account detail (vehicles + ledger)
  istisna/            entry/exit events that could not become a ticket
  vardiya/            shift open/close · cash count
  yonetim/            panel · reports · tariffs · staff · kasa · settings
  settings/           notifications · app settings
src/lib/              money · dates · sure · plaka · aralik · image · rbac · push · errors
supabase/migrations/  001 schema · 002 functions · 003 RLS · 004 cron · 005 seed
supabase/functions/   plaka-oku · kamera-webhook · send-push · _shared
supabase/tests/       rls_smoke_test.sql  ← run in the SQL Editor, rolls itself back
scripts/              generate-icons.mjs (dependency-free PNG encoder)
```

Convention: a **single `api.ts` per feature folder** owns every TanStack Query
hook; screens only lay out, and no component contains fee arithmetic.

## Commands

```bash
npm install
npm run dev        # local development — copy .env.example to .env.local first
npm run build      # tsc --noEmit && vite build — always before a push
npm run icons      # regenerate the PWA icons
```

Without `.env.local` the app throws a Turkish error on boot. That is deliberate:
better to say what is missing than to render a blank page.

## KVKK

A plate is personal data. Photos live in a **private** bucket, are read through
short-lived signed URLs, and are deleted by a nightly job once
`foto_saklama_gun` has passed. Ticket and collection records are kept for
accounting; the photograph is short-lived evidence.
