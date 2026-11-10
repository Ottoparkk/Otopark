# CLAUDE.md

Guidance for Claude Code (and for people) working on this repository.

**Otopark** — a mobile-first PWA for one paid car park: entry and exit, fee
calculation, collection, subscriptions, reserved spots, shift cash counts, and
an optional camera that reads plates. Turkish product UI; two roles only,
**Yönetici** and **Personel**. Read [README.md](README.md) for the product and
[SETUP.md](SETUP.md) for installing it from zero (Supabase → migrations →
smoke test → GitHub Pages → first Yönetici → optional camera).

## Stack

Vite + React 19 + TypeScript + Tailwind v4 + react-router 8 (`react-router`,
no `-dom`) + TanStack Query v5 + supabase-js. Supabase (Postgres, Auth,
Storage, Edge Functions, pg_cron, pg_net), EU region. GitHub Pages under
`/Otopark/` — the repo must be named `Otopark` (the path is in
`vite.config.ts`, `index.html`, `public/push-sw.js`, `SignIn.tsx`). The camera
bridge is Python, in `tools/kamera-koprusu/`.

## Rules

**Tests first, then the change.**
- Database change: add the new `PASS N` block to
  `supabase/tests/rls_smoke_test.sql` *before* writing the migration, then
  write the migration that makes it pass.
- Client logic (money, selectors, parsers, dates): write a Node check under
  `tests/*.check.mjs` that imports the real file, watch it fail for the right
  reason, then implement. There is no unit-test runner — the checks are plain
  `node tests/x.check.mjs`. A module a check imports must use only
  `import type` from other files (Node cannot resolve the app's extensionless
  imports); pass helpers in as arguments instead (see `src/features/gise/degistir.ts`).
- Bug fix: first a test that reproduces it.
- Pure layout work cannot be tested up front: say so, then verify in a browser
  at 360 / 375 / 430 px and in dark mode.

**Security lives in Postgres, never only in the UI.**
- Personel must not reach what they should not see: RLS policies, `SECURITY
  DEFINER` RPCs that re-check the role, and grants. Hiding a button is never the
  boundary.
- New signups are `PENDING` with `rol = NULL` and see zero rows — keep that
  case tested.
- New function: `revoke all ... from public` **and** `from anon,
  authenticated, service_role`, then grant narrowly, then assert with
  `has_function_privilege` in the migration's own `do $$` block. PASS 41
  compares the whole `anon` / `service_role` function surface with a list.
- New table: write its `grant` lines, `enable row level security` and its
  policies in the same migration. Since 2026-10-30 Supabase gives new tables no
  automatic access, so a table without grants is invisible to the app
  ("permission denied"). An Edge Function that touches a table directly needs
  its own `service_role` grant (see `047`, checked by PASS 69).
- OWASP Top 10 (2025). Never put a secret in a `VITE_*` variable or in git:
  API keys live in Supabase Edge Function secrets.

**Money.**
- Server: integer kuruş or `numeric`; client: integer kuruş, one shared
  formatter (`src/lib/money.ts`). Never float arithmetic.
- The server prices every fee (`ucret_hesapla`); the client only displays it.
- Approved / closed records are immutable (`biletler_immutable_guard`);
  corrections are counter-entries or cancellations, never edits.
  One narrow exception (owner, 054): `bilet_kamera_geri_ac` ("Araç çıkmadı")
  reopens a ticket the **camera** closed while nothing was collected. Keep it
  that narrow — no other reopen path.
- The camera closes a ticket only unpaid (054); collecting is always a
  person (`bilet_tahsil`), and every collection waits in Onay.

**Migrations.**
- Numbered, run by hand in the Supabase SQL editor, in order. There is no
  migration-history table, so never edit a migration that has been run — fix
  forward with a new number.
- File format: a three-line banner (`-- ====`, `-- NNN  Title`, `-- ====`),
  then `begin;` … `commit;`. Explanations go inside, next to the code.
- **Migration before frontend deploy**: PostgREST rejects a whole query that
  names a column that does not exist yet, which blanks a screen.
- After each migration, run the whole smoke test: it must end with
  `ALL TESTS PASSED (rolled back)`. It runs against the live database inside
  one transaction and rolls back, so tests must not assume the car park is
  empty or that a test user still has the role its name suggests — read state
  at the moment you check it.

**UI.**
- Follow *Refactoring UI*. Every colour is a token from `src/styles/index.css`
  (light and dark); no raw hex in components.
- Mobile first; tap targets ≥ 44 px; no horizontal scroll at 360 px.
- Times are shown and entered in Istanbul time (fixed UTC+3), whatever the
  device's zone.

**Working style.**
- Keep it simple (SOLID / DRY / KISS / YAGNI). Small, reviewable changes.
- Don't delete files or data to "clean up" — say what could go and why, and let
  a person decide.
- Never `npm audit fix --force`: it downgrades `vite-plugin-pwa` to a version
  that does not support Vite 8.
- Chat in English is fine; everything the user sees in the product is Turkish.

## Commands

```bash
npm install
npm run dev          # local, needs .env.local (copy .env.example)
npm run typecheck
npm run build        # typecheck + production build
node tests/degistir.check.mjs   # each tests/*.check.mjs the same way
```

Camera bridge tests: see `tools/kamera-koprusu/README.md`.
