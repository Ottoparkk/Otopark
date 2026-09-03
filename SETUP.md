# Otopark — Setup

Steps are ordered by **dependency**: each one relies only on the ones above it.
Run through it once, start to finish, skipping nothing.

> **Why the order matters:** migrations always run BEFORE the frontend deploy.
> If a new frontend selects a column that does not exist yet, PostgREST rejects
> the **entire** query with a 400 — one missing column blanks a whole screen,
> and to the user it looks like their data was deleted.

| # | Step | When |
|---|---|---|
| 1 | Supabase project | start here |
| 2 | Migrations | after 1 |
| 3 | Verification (smoke test + cron) | after 2 — **not skippable** |
| 4 | Local run | optional |
| 5 | GitHub repo and deploy | after 3 |
| 6 | Auth URLs | after 5 (the address comes from there) |
| 7 | First Yönetici | after 6 |
| 8–11 | Edge Functions, push, plate OCR, camera | later, all optional |
| 12 | Pre-launch checklist | before an operator uses it |

---

## 1. Supabase project

1. [supabase.com](https://supabase.com) → new project, region **EU (Frankfurt)**.
2. **Database → Extensions**, enable:
   - `pgcrypto`
   - `btree_gist` — the overlapping reservation/subscription constraints **will
     not install** without it
   - `pg_cron` — nightly jobs and the camera watchdog
   - `pg_net` — Database Webhooks. Without it the `supabase_functions` schema
     does not exist and step 9's webhook cannot be created at all: the push
     notification chain has no way to reach the Edge Function
3. From **Project Settings → API**, note:
   - `Project URL` → `VITE_SUPABASE_URL`
   - `publishable` key → `VITE_SUPABASE_PUBLISHABLE_KEY`
     (public by design; RLS is the security boundary, not this string)
   - Put the `service_role` key **nowhere** — Supabase injects it into Edge
     Functions automatically.

> The free plan allows **two active projects** per organisation. If you already
> have others, putting Otopark on a separate account is not a workaround — it
> is the correct move.

## 2. Migrations

Run these one at a time, in order, in the **SQL Editor**:

| File | What it does |
|---|---|
| `supabase/migrations/001_schema.sql` | Tables, enums, constraints, indexes |
| `supabase/migrations/002_functions.sql` | Fee arithmetic and every RPC that moves money |
| `supabase/migrations/003_rls.sql` | RLS, column grants, function EXECUTE grants, photo bucket |
| `supabase/migrations/004_cron.sql` | Nightly maintenance + camera watchdog |
| `supabase/migrations/005_seed.sql` | Settings row, tariffs, sample parking spots |
| `supabase/migrations/006_arac_tipi_kaldir.sql` | Removes vehicle types — one tariff for every vehicle |
| `supabase/migrations/007_cop_kutusu.sql` | Delete + recycle bin; deleting a record reverses its collections |
| `supabase/migrations/008_musteri_bilgisi.sql` | Vehicle / customer / phone / note on a ticket, editable until it closes |
| `supabase/migrations/009_yer_duzeni.sql` | Spots are generated from the capacity — P-01 / E-01 / R-01 |
| `supabase/migrations/010_yer_secimi.sql` | A bay is chosen at Giriş and validated; a camera entry takes the first free one |
| `supabase/migrations/011_yer_degistir.sql` | A car already inside can be moved to another bay |
| `supabase/migrations/012_grant_temizligi.sql` | Repairs the EXECUTE grants Supabase hands out by default to functions created by 006–008 |
| `supabase/migrations/013_sabit_tarife.sql` | Fixed price per entry as an alternative to the hourly tariff |
| `supabase/migrations/014_kasa_tekrar.sql` | Monthly recurring kasa entries, written by a nightly job |
| `supabase/migrations/015_yontem_ozet.sql` | Nakit / Kredi Kartı / Havale split behind the Finans net panel |
| `supabase/migrations/016_personel_odeme.sql` | Salary, advance and bonus; advance debt is deducted from the next salary |
| `supabase/migrations/017_tahsilat_onayi.sql` | Approval gate: bilet and abonman collections reach Finans only once the Yönetici accepts them |
| `supabase/migrations/018_maas_gizli.sql` | Takes SELECT off the salary columns and moves the roster behind a Yönetici-only RPC |
| `supabase/migrations/019_kamera_bildirimleri.sql` | A notification per camera entry and per camera exit-arrival, on their own preference toggle |
| `supabase/migrations/020_cop_tahsilat_anlik.sql` | Fixes the bin snapshot: a deleted ticket now keeps its collections, so restoring it restores the money |
| `supabase/migrations/021_cop_bayragi.sql` | The restore flag now silences the bin for that one record instead of everything after it |
| `supabase/migrations/022_cop_anon_kapat.sql` | Revokes anon's default privileges on the bin table, which 007 never did |
| `supabase/migrations/023_push_tetikleyici.sql` | Sends push from our own trigger via `pg_net`, instead of a dashboard webhook |
| `supabase/migrations/024_foto_saklama_siniri.sql` | Caps plate-photo retention at 1-30 days (storage quota + KVKK) |
| `supabase/migrations/025_kendini_toparlama.sql` | Auto-closes shifts left open, Yönetici force-close, nudges for forgotten queues |
| `supabase/migrations/026_odeme_yontemi_her_yerde.sql` | Every payment carries a method; automatic salary and recurring rules default to Nakit |
| `supabase/migrations/027_odemesiz_cikis.sql` | Lets a car leave unpaid and the money be collected later, from the ticket detail |
| `supabase/migrations/028_red_bileti_borclu_birakir.sql` | Rejecting a collection returns the ticket to owing, so the debt stays collectable |

`017` changes what "revenue" means, and the split is deliberate: **Ciro, the
daily chart and the payment-method breakdown count approved collections only,
while shift reconciliation counts every collection whatever its state.** The
cash is in the drawer whether or not the owner has accepted it into the books,
so filtering the shift count would invent a discrepancy on every unapproved
shift. Collections written before `017` ran are marked approved — a queue
holding the whole history would be unusable.

**Order is not optional here.** `008` drops and recreates the `bilet_ac` that
`006` creates, so running it first leaves the app unable to open a ticket, and
`010` replaces `008`'s version in place.

After `009`, park spots are produced from **Otopark Ayarları → Kapasite** rather
than typed in one at a time. The sample bays `005` inserted (`A-01`, `B-01`,
`S-01`) are outside the P/E/R scheme and are deliberately left alone; the
settings screen offers a tick to retire them once, and they are never deleted.

After `010`, the operator picks a park yeri while opening a ticket and one is
proposed automatically — the same bay `bos_park_yeri()` would give an entry
arriving from the camera. **`010` refuses to install** if two open tickets are
already sitting on one bay; it names them, because a lot in that state has to be
sorted out before "one car per bay" can be made true.

Until `010` has been run the Park yeri field simply does not appear on the Giriş
screen and entries carry on without a bay — the RPC it calls does not exist yet.
Nothing breaks, but the frontend should not be deployed expecting it.

`011` adds the move gesture on the spot grid: hold an occupied bay for three
seconds (or double-click it on a desktop), then tap the empty one. It is
`is_staff()` — **Personel can move a car**, deliberately, because they are the
ones who choose the bay at Giriş and the ones who re-park a car when the barrier
is blocked. Everything else on that screen — adding, editing, retiring or
deleting a bay, and every reservation control — stays Yönetici-only in RLS.
Before `011` is run the gesture answers "Bu özellik sunucuda henüz etkin değil."
rather than moving anything.

`003`, `004`, `009`, `010` and `011` end with self-verifying `DO` blocks: if a
permission was left open, the migration **raises and stops**. It is not expected
to pass quietly.

`003` explicitly enables RLS on **19 of 19** tables. If the dashboard offers an
"automatic RLS" option, leave it on: it changes nothing for these tables, but a
table added later through the Table Editor without RLS is world-readable to
anyone holding the publishable key.

## 3. Verification — do not skip this

### 3a. RLS and the money math

Paste the **whole** of `supabase/tests/rls_smoke_test.sql` into the SQL Editor
and run it. Everything happens inside one transaction and is **rolled back** at
the end — safe to run against a live project, leaves no data behind.

Expected final line:

```
ALL TESTS PASSED (rolled back)
```

It stops at the first failure with `FAIL: <what broke>`. This file is the proof
for the RBAC boundary, the fee arithmetic and the per-source clock rule. Do not
continue without seeing it green.

### 3b. Did cron actually install

```sql
select jobid, jobname, schedule, active from cron.job;
```

You want `otopark-gunluk` (`5 21 * * *` = 00:05 Istanbul) and `otopark-kamera`
(`*/10 * * * *`). If they are missing, `pg_cron` is not enabled and subscription
expiry, KVKK photo retention and abandoned-vehicle alerts **never run** — which
you would discover weeks later.

### 3c. The dashboard's own audit

Run **Advisors → Security Advisor**. It flags tables without RLS and functions
with a mutable `search_path`. Every function in `002` carries
`set search_path = public`, so it should come back clean.

## 4. Local run (optional)

Copy `.env.example` to `.env.local` and fill in the two values from step 1. With
no such file the app throws a Turkish error on boot — deliberate: a missing
config should say so rather than render a blank page.

```bash
npm install
npm run dev
```

## 5. GitHub repo and deploy

### 5a. Create the repo

Two settings, both load-bearing:

- **Name it `Otopark`** — identical to `base: '/Otopark/'` in `vite.config.ts`.
  Any other name gives you a site that loads nothing.
- **Make it Public** — on the free plan GitHub Pages will not publish from a
  private repo. The build still goes green; the deploy job is what fails.

Create it empty: no README, no .gitignore, no licence.

### 5b. Prepare the local repo

```bash
cd C:\Users\Lrx\Otopark
```

```bash
git init -b main
```

Set the identity **per repo**, before the first commit. Skipping this does not
fail — that is the problem. Git quietly guesses, and the commit is authored by
`unknown <your-global-email>`. GitHub attributes commits by e-mail address, so
the whole history lands under the wrong account, and nothing tells you until
you look at the commit list on the repo page.

(`git config` without `--global` writes to `.git/config`, which is why it comes
after `git init` and not before.)

```bash
git config user.name "Your Name"
```

```bash
git config user.email "your-account-email"
```

> **Switching GitHub accounts?** Windows Credential Manager caches the previous
> one and will silently push as that account. Clear it first, then the browser
> prompt lets you pick:
>
> ```
> cmdkey /delete:git:https://github.com
> ```

### 5c. Push

```bash
git add -A
```

This should stage **98 files** — `node_modules`, `dist` and `.env.local` are
excluded by `.gitignore`.

```bash
git commit -m "Otopark: database layer, Edge Functions and UI"
```

> ⚠ **Replace `YOUR-USERNAME` before running the next line.** Pasted verbatim it
> is accepted without complaint — `git remote add` never contacts GitHub — and
> the placeholder only surfaces at `git push` as an unhelpful
> `The requested URL returned error: 404`. If that happens, fix it with
> `git remote set-url origin …` rather than adding a second remote.

```bash
git remote add origin https://github.com/YOUR-USERNAME/Otopark.git
```

```bash
git push -u origin main
```

### 5d. Repo settings

**Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `VITE_SUPABASE_URL` | Project URL from step 1 |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | publishable key from step 1 |
| `VITE_VAPID_PUBLIC_KEY` | after step 9 — may stay empty for now |

> **Repository secrets, not environment secrets.** The page offers both. These
> are read by the `build` job, which declares no `environment:` — only `deploy`
> does (`github-pages`), and it reads no secrets at all. An environment secret
> is invisible to `build`, so `${{ secrets.VITE_SUPABASE_URL }}` resolves to an
> empty string: green build, successful deploy, blank site.

**Settings → Pages → Source: GitHub Actions**.

> ⚠ **With the secrets missing, the build goes green and the site loads blank.**
> They are compiled INTO the bundle, so `tsc` and `vite build` both complete
> fine and the app throws on boot. A successful deploy serving an empty page is
> this, not a bug in the code.

> ⚠ **Adding the secrets afterwards is not enough on its own — you must
> REBUILD.** "Re-run failed jobs" only re-runs `deploy`, which redeploys the
> artifact the earlier `build` produced without them. Use **Re-run all jobs**,
> or push a commit.
>
> Quickest way to tell which bundle is live: `primitives-*.js` is about
> **277 kB** when the secrets were present and about **73 kB** when they were
> not. `supabase.ts` throws unconditionally on missing env vars, so the
> bundler drops all of supabase-js as unreachable — the size is a reliable
> fingerprint.

### 5e. What runs on push

`deploy.yml`, in order:

1. `npm ci`
2. `npm audit --omit=dev --audit-level=high` — a high-severity production
   dependency stops the deploy rather than shipping to the gate
3. `npm run build`
4. bundle secret scan — `dist/assets` is deliberately included, since that is
   the one place a leaked key would be
5. publish to Pages

Deep links are already handled: `public/404.html` plus the restore script in
`index.html` stop GitHub Pages 404-ing on a refresh at `/Otopark/gise/cikis`.

## 6. Auth URLs

**Authentication → URL Configuration**. Two separate settings on that page:

**Site URL** — one plain address, no wildcard:

```
https://your-username.github.io/Otopark/
```

**Redirect URLs** — a list, not a text box. Each entry goes in through the
**Add URL** button, one at a time. Add these three:

```
https://your-username.github.io/Otopark/**
http://localhost:5173/Otopark/**
http://localhost:5175/Otopark/**
```

> ⚠ **The `/**` matters.** The allowlist compares the WHOLE URL, and the only
> redirect the app sends is `…/Otopark/sifre-sifirla` — the password-reset
> return address. An entry of `…/Otopark/` alone does not cover it, so reset
> links would be refused while everything else kept working. The wildcard also
> covers any route added later.

> ⚠ **Lowercase.** A case mismatch breaks matching silently. A capitalised
> username here cost hours on a sister project.

This section only affects **password reset**. Signup confirmation and normal
sign-in use the Site URL, so you can finish step 7 before coming back to it.

**Email:** Supabase's built-in sender is rate-limited hourly with no delivery
guarantee. Configure your own SMTP under **Project Settings → Auth → SMTP**
before operators start relying on password resets.

## 7. First Yönetici

Signup is open but **gated**: every new account is born `PENDING` with
`rol = NULL`, which RLS reads as "zero rows in every table". Naturally, there is
nobody to approve the first one.

**Do not create this one account by signing up in the app.** Supabase requires
email confirmation by default, and with the unreliable built-in sender you can
end up locked out of an account you cannot confirm.

1. **Authentication → Users → Add user**, with **Auto Confirm User** ticked.
   That insert fires the `on_auth_user_created` trigger, so the `profiles` row
   is created for you.
2. In the SQL Editor, with your own email:

```sql
update public.profiles
   set rol = 'YONETICI', durum = 'ACTIVE'
 where id = (select id from auth.users where email = 'you@example.com');
```

3. Check:

```sql
select p.id, u.email, p.rol, p.durum
  from public.profiles p join auth.users u on u.id = p.id;
```

An account created from the dashboard has a blank name (the dashboard sends no
`ad_soyad`); set it under **Ayarlar** after signing in.

Every account after this one is approved from **Yönetim → Personel**. This is
the only moment a role is assigned outside `set_role()` / `approve_signup()`.

---

Everything up to here is all the app needs to run. Everything below is optional
and off by default.

## 8. Edge Functions

With the Supabase CLI:

```bash
supabase login
supabase link --project-ref <project-ref>
supabase functions deploy plaka-oku
supabase functions deploy kamera-webhook --no-verify-jwt
supabase functions deploy send-push --no-verify-jwt
```

`--no-verify-jwt` is **required** for those two: a camera and a database webhook
cannot present a JWT. Their boundary is the shared secret instead.

Secrets (**Edge Functions → Secrets**):

| Secret | Used by | Note |
|---|---|---|
| `ANTHROPIC_API_KEY` | plaka-oku, kamera-webhook | Only if plate OCR is enabled |
| `ALLOWED_ORIGINS` | both | `https://YOUR-USERNAME.github.io` — `*` if empty |
| `KAMERA_WEBHOOK_SECRET` | kamera-webhook | **At least 16 characters**, random |
| `KAMERA_WEBHOOK_SECRET_ESKI` | kamera-webhook | Only during rotation |
| `PUSH_SECRET` | send-push | At least 16 characters, random |
| `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` / `VAPID_SUBJECT` | send-push | Step 9 |
| `PLATE_RECOGNIZER_TOKEN` | plaka-oku | Only if switching to `ALPR` mode |

To generate a random key:

```bash
openssl rand -base64 32
```

## 9. Web Push

```bash
npx web-push generate-vapid-keys
```

- **Public** key → both the GitHub secret `VITE_VAPID_PUBLIC_KEY` and the
  Supabase secret `VAPID_PUBLIC_KEY` (same value, two places).
- **Private** key → the Supabase secret `VAPID_PRIVATE_KEY` only.
- `VAPID_SUBJECT` → `mailto:you@example.com`.

After adding the GitHub secret you must **redeploy** — the key is baked into the
bundle at build time. Without it, push reports "unsupported" rather than
throwing.

Then point the trigger at the function. Migration `023` installs it; the URL
and the secret are inserted once, by hand, so neither ends up in git:

```sql
insert into public.push_ayar (id, url, gizli)
values (1,
  'https://<project-ref>.supabase.co/functions/v1/send-push',
  '<PUSH_SECRET>')
on conflict (id) do update
  set url = excluded.url, gizli = excluded.gizli, updated_at = now();
```

> The dashboard's **Database → Webhooks** feature does the same job, but it
> needs the `supabase_functions` schema, which some projects never got —
> enabling `pg_net` does not create it. `023` uses `net.http_post` directly and
> avoids the dependency; it also keeps the wiring in the repo rather than in
> dashboard state nobody can review.

On iOS, notifications need **16.4+** and the app installed to the **home
screen**; they do not work in a browser tab.

## 10. Plate OCR (off by default)

The app works completely without plate OCR. To enable it, go to **Yönetim →
Ayarlar**:

Flip **Plaka okuma açık**. That is the whole switch: on = Claude reads the
photo, off = the camera only takes a picture. One photo can only go to one
reader, so there is no "all providers at once" setting to make.

The two columns behind that toggle are still there and are changed with SQL,
not from the screen — they are an escape hatch, not an operator decision:

- `plaka_saglayici`: `KAPALI` / `VLM` (Claude, what the toggle writes) /
  `ALPR` (Plate Recognizer — needs `PLATE_RECOGNIZER_TOKEN`, and their
  published country list does not include Turkey, so it is unverified here).
- `plaka_model`: `claude-haiku-4-5` (default). This field is deliberately free
  text so switching provider needs no migration; the Edge Function validates the
  value against its own allowlist and falls back to the default if it does not
  recognise it.

```sql
update public.otopark_ayarlari
   set plaka_saglayici = 'ALPR' where id = 1;
```

To measure the real hit rate after a month:

```sql
select saglayici,
       count(*) as okuma,
       count(*) filter (where onerilen = kabul_edilen) as dogru,
       round(100.0 * count(*) filter (where onerilen = kabul_edilen) / nullif(count(*),0), 1) as yuzde
  from public.plaka_okuma_log
 where kabul_edilen is not null
 group by saglayici;
```

The provider decision gets **re-made** from this table, not re-argued.

## 11. Camera (once hardware exists)

> ⚠ `kamera-webhook` **has never been tested against real hardware.** Contract
> tests verify the contract, not any vendor's particular behaviour.

1. Turn on **Yönetim → Ayarlar → `kamera_aktif`** (off by default).
2. The camera's target address — one of three, whichever the hardware supports:
   - Header: `x-kamera-secret: <KAMERA_WEBHOOK_SECRET>`
   - HTTP Basic: any username, **password** = the secret
   - URL path: `.../functions/v1/kamera-webhook/<secret>/giris`
3. Direction is **required** and never guessed: `giris`/`cikis` at the end of
   the path, or `?yon=GIRIS`. There is no default, so a misconfigured exit
   camera cannot silently open tickets.
4. **Put the camera's clock on NTP.** This is not housekeeping, it is money: a
   camera an hour off mis-bills every vehicle, silently. The server takes the
   timestamp from the camera because a buffered event can arrive hours late.
5. The URL-path method is the weakest (addresses end up in proxy and server
   logs) — if you use it, rotate the secret more often.

**Rotation without downtime:** put the new secret in `KAMERA_WEBHOOK_SECRET`,
move the old one to `KAMERA_WEBHOOK_SECRET_ESKI`, update the camera, then delete
`_ESKI`. Without this the camera is silently rejected mid-rotation.

## 12. Veritabanı yedeği

Backups live in a **separate private repository**, `otopark-backups`, with the
scheduled job inside it. Nothing about backups sits in this repository.

> That separation is the point. A dump holds plates, customer names and phone
> numbers, salaries and every lira that moved. It must not be in a repository
> that developers clone, that could be made public one day, or whose history
> anyone browses casually — and git history is permanent, so a dump committed
> once cannot be taken back by deleting the file later.

The local copy sits next to this one, in `otopark-backups/`. Its own README
carries the setup, the restore commands, and what the backup deliberately does
not cover (user accounts and plate photos). In short:

- Runs nightly at **01:30 Istanbul**, after this app's own nightly jobs, so
  each dump holds a fully closed day.
- Commits `yedekler/YYYY-MM-DD.tar.gz` — `sema.sql` plus `veri.sql`.
- Needs **one secret on that repository**, `SUPABASE_DB_URL`, and it must be
  an **IPv4 pooler** string (Supabase → Connect → Transaction pooler). The
  direct `db.<ref>.supabase.co` host is IPv6-only and GitHub's runners cannot
  reach it — the dump fails with "Network is unreachable".
- Fails loudly on an empty dump rather than committing a broken backup.

## 13. Pre-launch checklist

- [ ] `rls_smoke_test.sql` → `ALL TESTS PASSED`
- [ ] `cron.job` shows both jobs
- [ ] Security Advisor clean
- [ ] Every role tested by hand: Yönetici, Personel, **and an unapproved PENDING account**
- [ ] Signed in as Personel, typed Yönetici URLs directly → all refused
- [ ] Tariffs set to real prices (**from Yönetim → Tarifeler**, not SQL —
      versioning goes through there)
- [ ] Capacity and car park name entered
- [ ] Sample parking spots deleted or replaced with the real ones
- [ ] SMTP configured; a password reset actually arrived at a real address
- [ ] PWA installed on iOS and Android, camera works on both
- [ ] Connectivity drop tested: a 3-second cut produces **exactly one ticket**;
      airplane mode fails **visibly** (a silent failure or an endless spinner is
      not acceptable)
- [ ] Payment does **not** retry: losing signal mid-collection gives an explicit error
- [ ] The nightly cron fired at 00:05
- [ ] `otopark-backups` deposunda yedek işi bir kez elle çalıştırıldı
      (**Actions → Gecelik yedek → Run workflow**) ve **çıkan dosya boş bir
      projeye geri yüklenerek denendi**
- [ ] `npm audit --omit=dev` clean
- [ ] One full shift run end to end by an actual operator

> **Fiscal receipts (ÖKC):** output from this app is not a legal receipt. Ask
> your **mali müşavir** how cash collection must be documented; this app keeps
> an accounting record, it does not issue fiscal receipts.
