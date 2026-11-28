# Anlaşmalı fiyat (agreed price) — plan

## Context
The owner agrees a fixed price with some customers for a set time ("600 ₺ for 3 days").
Owner decisions:
- Personel and Yönetici can both create a deal, and the Yönetici is notified when one is made.
- When the time runs out, the tariff starts counting again. The extra time is **not added automatically**: a person presses a button to add it.
- An expired deal shows a warning on the İçeride card.
- One notification goes to everyone when the time runs out.
- Keep it simple.
- Layout **E**, the budget-app style: a time bar that turns orange when the time is over, with the drop icon kept on Oto yıkama.

This builds on 078 (oto yıkama). 078 is built but **not run**. Nothing from either feature is committed.

**My own calls (not the owner's; the owner can overrule):**
- The deal time counts from the car's entry.
- Extra time is priced with the normal tariff as a new stay starting at the deal's end.
- After "Fazla süreyi ekle", the extra time keeps counting until exit.
- Changing a deal clears the "extra time added" mark and the notification mark.
- The wash is added on top of the deal price.
- An abonman car cannot get a deal.
- Duration is 1 hour to 90 days.
- The Yönetici is notified when a deal is made or changed, not when it is removed.
- The deal can be set from the ticket detail and Tahsilat, not from the Giriş screen.

## Step 0: spec doc
Write `docs/superpowers/specs/2026-11-27-anlasmali-fiyat-design.md`. It covers the Context above, approach E and the rules. Then this plan goes into `docs/superpowers/plans/`.

## Database (tests first)
**Smoke test first:** add PASS 104–107 to `supabase/tests/rls_smoke_test.sql` before the migrations.
- **104, deal set and change:**
  - A pending user is refused.
  - An abonman car is refused.
  - A Personel deal of 60000 kuruş for 72 h gives `anlasma_bitis = giris_at + 72h` and a preview of 60000, plus the wash if any.
  - The Yönetici gets an `ANLASMA` row.
  - A price of 0 or a duration of 0 is refused.
  - A closed ticket is refused.
  - Remove (`p_kurus null`) brings back tariff pricing.
- **105, expiry and extra time:**
  - Move `giris_at` back so the deal is over.
  - The preview is still 60000.
  - `bilet_fazla_onizle` equals `ucret_hesapla(bitis, now())`.
  - `bilet_anlasma_fazla` raises the preview to 60000 + that amount.
  - `bilet_kapat` charges the same, and the tahsilat matches.
  - The camera close charges the deal price only when the extra time was not added.
- **106, cron:**
  - `anlasma_bildirim_gonder()` writes `ANLASMA` rows for Personel and Yönetici with the text "<plaka>: anlaşma süresi doldu", then sets `anlasma_bildirim_at`.
  - A second run sends nothing.
  - `bildirim_yonetici_turu('ANLASMA')` is false.
- **107, points and grants:**
  - `puan_kullan` caps points at the deal price, not the tariff.
  - `has_function_privilege` holds for every new function.
  - The cron function is open to no role.

**`079_anlasma_bildirim_turu.sql`:** only `alter type bildirim_tur add value if not exists 'ANLASMA'`. It is its own file because of the 064 pattern: a new enum value can't be used in the transaction that adds it.

**`080_anlasmali_fiyat.sql`** (banner, `begin`…`commit`):
- **Guard:** if `bilet_ucreti` doesn't exist, raise '080: 078 koşulmamış'.
- **Columns:**
  - `biletler.anlasma_kurus` int, check > 0;
  - `anlasma_bitis` timestamptz;
  - `anlasma_fazla_at` timestamptz;
  - `anlasma_bildirim_at` timestamptz;
  - a partial index on `(anlasma_bitis) where durum='ACIK' and anlasma_bildirim_at is null`.
- **`bilet_ucreti`:** recreated (same signature). It returns abonman → 0; deal → `anlasma_kurus` + (`anlasma_fazla_at` set ? `ucret_hesapla(anlasma_bitis, greatest(p_cikis, anlasma_bitis), tarife)` : 0); else the 078 formula. The wash is added on top as before. `bilet_kapat`, the camera close, free exit, the preview and `acik_bilet_ara` all follow automatically.
- **`bilet_anlasma(p_bilet_id uuid, p_kurus integer, p_saat integer) returns void`:**
  - Staff only, ACIK only, no abonman. A null `p_kurus` removes the deal.
  - `p_saat` must be 1–2160.
  - Refused if `indirim_kurus` is above the new fee (the same rule as the wash).
  - Clears `anlasma_fazla_at` and `anlasma_bildirim_at`.
  - Writes an audit row.
  - Create or change calls `notify_yonetici('ANLASMA', 'Anlaşmalı fiyat', '<plaka> — 600 ₺, 30.11 13:03''e kadar', <ticket link as other ticket notifications use>)`.
- **`bilet_anlasma_fazla(p_bilet_id uuid) returns void`:** ACIK, has a deal, `bitis <= now()`. It sets `anlasma_fazla_at = now()`, does nothing on a second call, and writes an audit row.
- **`bilet_fazla_onizle(p_bilet_id uuid) returns integer`:** `ucret_hesapla(bitis, now(), tarife)` when the deal is over, else 0; null when the ticket is not ACIK.
- **`puan_kullan`:** the 002 body word for word, except the cap line becomes `bilet_ucreti(v_b, now()) - coalesce(v_b.yikama_kurus, 0)`.
- **`acik_bilet_ara`:** the 078 body plus `anlasma_bitis` and `anlasma_fazla_at`. Drop + create + regrant.
- **`anlasma_bildirim_gonder()`:** the `istisna_bildirim_gonder` pattern (045). A try advisory lock, then a loop over ACIK tickets where `anlasma_bitis <= now()` and `anlasma_bildirim_at is null`, `for update skip locked`. Each one gets `notify_herkes('ANLASMA', 'Anlaşma süresi doldu', '<plaka>: anlaşma süresi doldu', link)` and then `anlasma_bildirim_at = now()`. Scheduled with `cron.schedule('otopark-anlasma-bildirim', '* * * * *', …)`.
- **Grants:** revoke from public, anon, authenticated, service_role. Grant only the 3 RPCs to authenticated. A `do $$` block asserts the grants.

## Frontend (Node check first)
- **`tests/anlasma.check.mjs` → `src/features/gise/anlasma.ts`** (type-only imports):
  - `anlasmaBitis(girisIso, sayi, birim: 'saat'|'gun'): Date`
  - `anlasmaDurumu(girisIso, bitisIso, simdiMs): { doldu, yuzde, kalanDk, asimDk }`
  - `anlasmaSaat(sayi, birim): number`
  - Edge cases: exactly at the end, past the end, 0 %, a 1-hour deal, days.
- **`src/lib/types.ts`:**
  - Bilet and AcikBilet get the deal fields.
  - Add `'ANLASMA'` to the notification type union, with the label 'Anlaşmalı fiyat'.
  - Add the same type to `settings/Ayarlar.tsx` (list) and `settings/Bildirimler.tsx` (warn colour).
- **`src/components/ui/primitives.tsx`:** `OranCubugu` gets `tone: 'success' | 'warn'` (tokens only).
- **`src/features/gise/api.ts`:** `useBiletAnlasma`, `useAnlasmaFazla` and `useFazlaOnizleme`. Invalidate the same keys as `useBiletYikama`; retry false.
- **`src/features/gise/components.tsx`:**
  - **`AnlasmaBlogu`, inside `HizmetlerKarti`** (layout E):
    - **No deal:** an IconTile with IconTakvim and "Anlaşmalı fiyat ekle".
    - **Running:** "**Anlaşma 600 ₺** · 3 gün", a green bar, and "1 g 20 sa kaldı · 30.11 13:03'e kadar".
    - **Over:** a warn tile, a full orange bar, "Süre doldu · 2 sa 10 dk aşıldı" and a full-width button "Fazla süreyi ekle: +X".
    - **Extra time added:** "Fazla süre ekleniyor · +X".
    - Tapping the block opens the form.
    - When there is a deal it replaces the "Otopark" row.
    - Time ticks with the screen's existing live clock.
  - **`AnlasmaFormu`** (`FormModal`):
    - Fiyat (₺) and Süre (`Input` + `SegmentedControl` Saat|Gün).
    - "Bitiş: dd.MM HH:mm" in Istanbul time, with a warn line if that time has already passed.
    - Kaydet, plus "Anlaşmayı kaldır" when a deal exists.
  - **`BiletKart`:** an "Anlaşma bitti" warn Chip when the deal is over and no extra time was added.
- **`BiletDetay.tsx`:** show `HizmetlerKarti` whenever the ticket is ACIK and not abonman, or when the wash is available.
- **`Cikis.tsx` (Tahsilat):** gets the deal through the same card. `onDegisti` already clears the override.

## Verification
1. `node tests/anlasma.check.mjs` fails, then passes after the code. All other `tests/*.check.mjs` stay green. Run `npm run build`.
2. **Harness** (`detay-harness`, port 4608): add `&anlasma=yok|var|doldu|eklendi`. Click through detail, Tahsilat, the İçeride list and the form, as Personel and Yönetici, at 360/375/430 px and in dark mode. Check the RPC calls in `window.__rpc`.
3. **At the end of the round, the owner runs:** 078 → 079 → 080, then the whole smoke test, which must end with `ALL TESTS PASSED (rolled back)`. After the owner's go: commit (no co-author line) and push, together with the 078 work.
